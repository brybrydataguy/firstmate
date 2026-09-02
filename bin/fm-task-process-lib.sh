#!/usr/bin/env bash

# Durable process-scope record and cleanup owner for verified ship and scout workers.
# `state/<id>.meta` binds the record through `process_scope_token=`, and the
# matching `state/<id>.process-scope` is a private versioned record with one of
# two states: `active` carries containment, ownership-anchor, agent-process,
# process-group identities, and a portable `boot_generation=` binding when the
# host exposes one, while `empty` carries containment, the token, and an
# optional endpoint identity retained from the active scope.
# Version 1 empty records contain version, status, and token, with optional
# containment; active records additionally require leader_pid, leader_identity,
# and pgid. Version 2 empty records permit an optional paired endpoint identity;
# active records instead require paired anchor and agent identities plus pgid,
# and permit optional containment, paired endpoint identity, and boot generation.
# Writers publish each state atomically and readers reject symlinks, malformed
# fields, duplicate owned fields, owned fields outside the exact version/state
# schema, stale tokens, changed process identities, and an owned group that has
# moved, so no lifecycle operation signals processes from an unproved scope.
# Snapshot excludes the lifecycle shell, so an inherited token cannot select
# the quiesce process for signaling.
# Quiesce may retire an active scope to empty without signaling only when it
# proves that scope predates the current host boot, so none of its processes
# can still exist: a well-formed recorded `boot_generation=` that differs from
# the current host generation, or a legacy Darwin `lstart=` identity whose
# timezone provenance is unchanged since capture and whose absolute start is
# strictly earlier than the current boot time. Matching, missing, or unreadable
# boot-generation evidence keeps the current refusal unless that legacy proof
# applies. Equal, later, ambiguous, or unparseable timestamps, changed or
# unproved timezone provenance, mixed or non-`lstart=` identities,
# current-boot identity mismatch,
# a missing PID, an agent-free endpoint, elapsed time, branch cleanliness, and
# process-name guesses never prove prior-boot safety and never authorize a
# signal. Repeated quiesce on empty is idempotent. Overlay sources for tests
# and recovery: `FM_TASK_PROCESS_BOOT_GENERATION` or
# `FM_TASK_PROCESS_BOOT_GENERATION_FILE` replace the host generation,
# `FM_TASK_PROCESS_BOOT_TIME` or `FM_TASK_PROCESS_BOOT_TIME_FILE` replace the
# host boot time, `FM_TASK_PROCESS_TIMEZONE_CHANGE_TIME` replaces the latest
# timezone-provenance change time, and `FM_TASK_PROCESS_PROC_ROOT` remains the
# `/proc` identity overlay; a set overlay is exclusive and does not fall through
# to the host.
# `fm-task-process-launch.sh` produces the record and retains the ownership
# anchor until the agent and every scoped descendant are gone.
# Lifecycle callers quiesce the scope before relaunch or worktree removal;
# PID-namespace containment is an additional explicit gate for transitions that
# cannot safely rely on portable process-group ownership alone.

fm_task_process_scope_path() {
  printf '%s/%s.process-scope\n' "$1" "$2"
}

fm_task_process_scope_meta_token() {
  local meta=$1 token
  token=$(fm_task_process_scope_record_value "$meta" process_scope_token)
  [ -n "$token" ] || token=$(fm_task_process_scope_record_value "$meta" spawn_gen)
  fm_task_process_scope_token_valid "$token" || return 1
  printf '%s\n' "$token"
}

fm_task_process_scope_meta_token_explicit() {
  local meta=$1 token
  token=$(fm_task_process_scope_record_value "$meta" process_scope_token)
  [ -n "$token" ] || return 0
  fm_task_process_scope_token_valid "$token" || {
    echo "error: task metadata has a malformed process-scope token" >&2
    return 1
  }
  printf '%s\n' "$token"
}

fm_task_process_scope_token_valid() {
  case "${1-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

fm_task_process_enclosure_validate() {
  local enclosure=$1
  [ "$enclosure" != - ] || return 0
  case "$enclosure" in
    /*) ;;
    *) return 1 ;;
  esac
  [ -x "$enclosure" ] || return 1
  "$enclosure" --user --map-current-user --pid --fork \
    --kill-child=SIGKILL --mount-proc -- /bin/sh -c '[ "$$" -eq 1 ]' \
    >/dev/null 2>&1
}

fm_task_process_enclosure_resolve() {
  local enclosure enclosure_dir enclosure_name
  enclosure=$(command -v unshare 2>/dev/null) || {
    printf '%s\n' -
    return 0
  }
  case "$enclosure" in
    /*) ;;
    *)
      printf '%s\n' -
      return 0
      ;;
  esac
  enclosure_dir=${enclosure%/*}
  enclosure_name=${enclosure##*/}
  enclosure_dir=$(cd "$enclosure_dir" 2>/dev/null && pwd -P) || return 1
  enclosure=$enclosure_dir/$enclosure_name
  fm_task_process_enclosure_validate "$enclosure" || {
    printf '%s\n' -
    return 0
  }
  printf '%s\n' "$enclosure"
}

fm_task_process_enclosure_containment() {
  local enclosure=$1
  if [ "$enclosure" = - ]; then
    printf '%s\n' process-group
    return 0
  fi
  fm_task_process_enclosure_validate "$enclosure" || return 1
  printf '%s\n' pid-namespace
}

fm_task_process_identity() {
  local pid=$1 proc_root=${FM_TASK_PROCESS_PROC_ROOT:-/proc} stat_line value starttime
  local -a stat_fields
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -r "$proc_root/$pid/stat" ]; then
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 1
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${#stat_fields[@]}" -ge 20 ] || return 1
    starttime=${stat_fields[19]}
    case "$starttime" in ''|*[!0-9]*) return 1 ;; esac
    printf 'starttime=%s\n' "$starttime"
    return 0
  fi
  value=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || return 1
  value=$(printf '%s' "$value" | awk '{$1=$1; print}')
  [ -n "$value" ] || return 1
  case "$value" in *$'\n'*|*$'\r'*) return 1 ;; esac
  value=$(printf '%s' "$value" | tr '[:space:]' '_')
  printf 'lstart=%s\n' "$value"
}

fm_task_process_identity_matches() {
  local current
  current=$(fm_task_process_identity "$1") || return 1
  [ "$current" = "$2" ]
}

fm_task_process_recorded_identity_valid() {
  local pid=$1 identity=$2 value
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" -gt 1 ] || return 1
  case "$identity" in
    starttime=*)
      value=${identity#starttime=}
      case "$value" in ''|*[!0-9]*) return 1 ;; esac
      ;;
    lstart=*)
      value=${identity#lstart=}
      case "$value" in ''|*[!A-Za-z0-9_:.-]*) return 1 ;; esac
      ;;
    *) return 1 ;;
  esac
}

fm_task_process_boot_generation_valid() {
  case "${1-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}

fm_task_process_boot_time_valid() {
  case "${1-}" in
    ''|*[!0-9]*|0*) return 1 ;;
  esac
}

fm_task_process_text_file_valid() {
  local path=$1 bytes
  bytes=$(LC_ALL=C od -An -v -t u1 < "$path" 2>/dev/null) || return 1
  LC_ALL=C awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i != 9 && $i != 10 && $i != 13 && ($i < 32 || $i > 126)) exit 1
      }
    }
  ' <<EOF
$bytes
EOF
}

fm_task_process_read_single_line_file() {
  local path=$1 value
  [ -n "$path" ] && [ -f "$path" ] && [ ! -L "$path" ] || return 1
  fm_task_process_text_file_valid "$path" || return 1
  value=$(cat "$path" 2>/dev/null) || return 1
  value=${value%$'\n'}
  case "$value" in *$'\n'*|*$'\r'*) return 1 ;; esac
  printf '%s\n' "$value"
}

fm_task_process_current_boot_generation() {
  local value path proc_root
  if [ "${FM_TASK_PROCESS_BOOT_GENERATION+x}" = x ]; then
    value=$FM_TASK_PROCESS_BOOT_GENERATION
    fm_task_process_boot_generation_valid "$value" || return 1
    printf '%s\n' "$value"
    return 0
  fi
  if [ "${FM_TASK_PROCESS_BOOT_GENERATION_FILE+x}" = x ]; then
    value=$(fm_task_process_read_single_line_file "$FM_TASK_PROCESS_BOOT_GENERATION_FILE") || return 1
    fm_task_process_boot_generation_valid "$value" || return 1
    printf '%s\n' "$value"
    return 0
  fi
  proc_root=${FM_TASK_PROCESS_PROC_ROOT:-/proc}
  path=$proc_root/sys/kernel/random/boot_id
  if [ -e "$path" ] || [ -L "$path" ]; then
    if value=$(fm_task_process_read_single_line_file "$path"); then
      fm_task_process_boot_generation_valid "$value" || return 1
      printf '%s\n' "$value"
      return 0
    fi
    [ "${FM_TASK_PROCESS_PROC_ROOT+x}" = x ] && return 1
  elif [ "${FM_TASK_PROCESS_PROC_ROOT+x}" = x ]; then
    return 1
  fi
  value=$(sysctl -n kern.bootsessionuuid 2>/dev/null) || return 1
  value=${value%$'\n'}
  case "$value" in *$'\n'*|*$'\r'*) return 1 ;; esac
  fm_task_process_boot_generation_valid "$value" || return 1
  printf '%s\n' "$value"
}

fm_task_process_current_boot_time() {
  local value path proc_root
  if [ "${FM_TASK_PROCESS_BOOT_TIME+x}" = x ]; then
    value=$FM_TASK_PROCESS_BOOT_TIME
    fm_task_process_boot_time_valid "$value" || return 1
    printf '%s\n' "$value"
    return 0
  fi
  if [ "${FM_TASK_PROCESS_BOOT_TIME_FILE+x}" = x ]; then
    value=$(fm_task_process_read_single_line_file "$FM_TASK_PROCESS_BOOT_TIME_FILE") || return 1
    fm_task_process_boot_time_valid "$value" || return 1
    printf '%s\n' "$value"
    return 0
  fi
  proc_root=${FM_TASK_PROCESS_PROC_ROOT:-/proc}
  path=$proc_root/stat
  if [ -f "$path" ] && [ ! -L "$path" ]; then
    fm_task_process_text_file_valid "$path" || return 1
    value=$(awk '$1 == "btime" && $2 ~ /^[1-9][0-9]*$/ {print $2; exit}' "$path")
    if [ -n "$value" ]; then
      fm_task_process_boot_time_valid "$value" || return 1
      printf '%s\n' "$value"
      return 0
    fi
    [ "${FM_TASK_PROCESS_PROC_ROOT+x}" = x ] && return 1
  elif [ "${FM_TASK_PROCESS_PROC_ROOT+x}" = x ]; then
    return 1
  fi
  value=$(sysctl -n kern.boottime 2>/dev/null) || return 1
  value=$(printf '%s\n' "$value" | awk -F'[=,]' '/sec/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')
  fm_task_process_boot_time_valid "$value" || return 1
  printf '%s\n' "$value"
}

fm_task_process_file_change_time() {
  local path=$1 follow=$2 value modified changed
  if [ "$follow" = 1 ]; then
    value=$(stat -L -f '%m %c' "$path" 2>/dev/null) \
      || value=$(stat -L -c '%Y %Z' -- "$path" 2>/dev/null) \
      || return 1
  else
    value=$(stat -f '%m %c' "$path" 2>/dev/null) \
      || value=$(stat -c '%Y %Z' -- "$path" 2>/dev/null) \
      || return 1
  fi
  read -r modified changed <<EOF
$value
EOF
  fm_task_process_boot_time_valid "$modified" || return 1
  fm_task_process_boot_time_valid "$changed" || return 1
  if [ "$modified" -gt "$changed" ]; then
    printf '%s\n' "$modified"
  else
    printf '%s\n' "$changed"
  fi
}

fm_task_process_timezone_change_time() {
  local path link_change target_change
  if [ "${FM_TASK_PROCESS_TIMEZONE_CHANGE_TIME+x}" = x ]; then
    fm_task_process_boot_time_valid "$FM_TASK_PROCESS_TIMEZONE_CHANGE_TIME" || return 1
    printf '%s\n' "$FM_TASK_PROCESS_TIMEZONE_CHANGE_TIME"
    return 0
  fi
  [ "${TZ+x}" != x ] || return 1
  path=/etc/localtime
  [ -e "$path" ] || [ -L "$path" ] || return 1
  link_change=$(fm_task_process_file_change_time "$path" 0) || return 1
  target_change=$(fm_task_process_file_change_time "$path" 1) || return 1
  if [ "$link_change" -gt "$target_change" ]; then
    printf '%s\n' "$link_change"
  else
    printf '%s\n' "$target_change"
  fi
}

fm_task_process_epoch_lstart() {
  local epoch=$1 value
  value=$(LC_ALL=C date -r "$epoch" +'%a_%b_%d_%T_%Y' 2>/dev/null) \
    || value=$(LC_ALL=C date -d "@$epoch" +'%a_%b_%d_%T_%Y' 2>/dev/null) \
    || return 1
  printf 'lstart=%s\n' "$value"
}

fm_task_process_timezone_offset_seconds() {
  local epoch=$1 value sign hours minutes offset
  value=$(LC_ALL=C date -r "$epoch" +%z 2>/dev/null) \
    || value=$(LC_ALL=C date -d "@$epoch" +%z 2>/dev/null) \
    || return 1
  case "$value" in
    [+-][0-2][0-9][0-5][0-9]) ;;
    *) return 1 ;;
  esac
  sign=${value:0:1}
  hours=${value:1:2}
  minutes=${value:3:2}
  offset=$((10#$hours * 3600 + 10#$minutes * 60))
  if [ "$sign" = - ]; then
    offset=$((-offset))
  fi
  printf '%s\n' "$offset"
}

fm_task_process_lstart_epoch_unique() {
  local identity=$1 epoch=$2 base_offset delta probe offset known candidate rendered matches=0
  local -a offsets=()
  base_offset=$(fm_task_process_timezone_offset_seconds "$epoch") || return 1
  delta=-172800
  while [ "$delta" -le 172800 ]; do
    probe=$((epoch + delta))
    offset=$(fm_task_process_timezone_offset_seconds "$probe") || return 1
    for known in "${offsets[@]}"; do
      [ "$known" != "$offset" ] || break
    done
    if [ "${known-}" != "$offset" ]; then
      offsets+=("$offset")
    fi
    known=
    delta=$((delta + 21600))
  done
  for offset in "${offsets[@]}"; do
    candidate=$((epoch + base_offset - offset))
    rendered=$(fm_task_process_epoch_lstart "$candidate") || return 1
    if [ "$rendered" = "$identity" ]; then
      matches=$((matches + 1))
    fi
  done
  [ "$matches" -eq 1 ]
}

fm_task_process_lstart_epoch() {
  local identity=$1 raw weekday month day time year padded extra epoch normalized
  case "$identity" in
    lstart=*) raw=${identity#lstart=} ;;
    *) return 1 ;;
  esac
  raw=${raw//_/ }
  extra=
  IFS=' ' read -r weekday month day time year extra <<EOF
$raw
EOF
  [ -z "${extra:-}" ] || return 1
  case "$weekday" in Sun|Mon|Tue|Wed|Thu|Fri|Sat) ;; *) return 1 ;; esac
  case "$month" in
    Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) ;;
    *) return 1 ;;
  esac
  case "$day" in
    [1-9]|0[1-9]|[12][0-9]|3[01]) ;;
    *) return 1 ;;
  esac
  case "$time" in
    [0-2][0-9]:[0-5][0-9]:[0-5][0-9]) ;;
    *) return 1 ;;
  esac
  case "$year" in
    [12][0-9][0-9][0-9]) ;;
    *) return 1 ;;
  esac
  case "$day" in
    [1-9]) padded=0$day ;;
    *) padded=$day ;;
  esac
  epoch=$(LC_ALL=C date -j -f '%a %b %d %T %Y' \
    "$weekday $month $padded $time $year" +%s 2>/dev/null) \
    || epoch=$(LC_ALL=C date -d "$weekday $month $padded $time $year" +%s 2>/dev/null) \
    || return 1
  fm_task_process_boot_time_valid "$epoch" || return 1
  normalized="lstart=${weekday}_${month}_${padded}_${time}_${year}"
  [ "$(fm_task_process_epoch_lstart "$epoch")" = "$normalized" ] || return 1
  fm_task_process_lstart_epoch_unique "$normalized" "$epoch" || return 1
  printf '%s\n' "$epoch"
}

fm_task_process_legacy_prior_boot_proven() {
  local current_boot timezone_change_before timezone_change_after anchor_epoch agent_epoch
  current_boot=$(fm_task_process_current_boot_time) || return 1
  timezone_change_before=$(fm_task_process_timezone_change_time) || return 1
  [ "$timezone_change_before" -le "$current_boot" ] || return 1
  case "$FM_TASK_PROCESS_SCOPE_ANCHOR_IDENTITY" in
    lstart=*) ;;
    *) return 1 ;;
  esac
  anchor_epoch=$(fm_task_process_lstart_epoch "$FM_TASK_PROCESS_SCOPE_ANCHOR_IDENTITY") || return 1
  [ "$timezone_change_before" -le "$anchor_epoch" ] || return 1
  [ "$anchor_epoch" -lt "$current_boot" ] || return 1
  case "$FM_TASK_PROCESS_SCOPE_AGENT_IDENTITY" in
    lstart=*)
      agent_epoch=$(fm_task_process_lstart_epoch "$FM_TASK_PROCESS_SCOPE_AGENT_IDENTITY") || return 1
      [ "$timezone_change_before" -le "$agent_epoch" ] || return 1
      [ "$agent_epoch" -lt "$current_boot" ] || return 1
      ;;
    *) return 1 ;;
  esac
  timezone_change_after=$(fm_task_process_timezone_change_time) || return 1
  [ "$timezone_change_after" = "$timezone_change_before" ] || return 1
  return 0
}

fm_task_process_scope_prior_boot_proven() {
  local recorded_generation current_generation
  recorded_generation=${FM_TASK_PROCESS_SCOPE_BOOT_GENERATION-}
  if [ -n "$recorded_generation" ]; then
    fm_task_process_boot_generation_valid "$recorded_generation" || return 1
    if current_generation=$(fm_task_process_current_boot_generation); then
      [ "$current_generation" != "$recorded_generation" ] || return 1
      return 0
    fi
  fi
  fm_task_process_legacy_prior_boot_proven
}

fm_task_process_pgid() {
  local value
  value=$(LC_ALL=C ps -p "$1" -o pgid= 2>/dev/null) || return 1
  value=${value//[[:space:]]/}
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$value"
}

fm_task_process_parent_pid() {
  local value
  value=$(LC_ALL=C ps -p "$1" -o ppid= 2>/dev/null) || return 1
  value=${value//[[:space:]]/}
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$value"
}

fm_task_process_scope_record_value() {
  local path=$1 key=$2
  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); value=$0} END {print value}' "$path"
}

fm_task_process_scope_record_schema_valid() {
  local version=$1 status=$2 fields=$3 allowed required field
  local -a field_list
  case "$version:$status" in
    1:empty)
      allowed='version status token containment'
      required='version status token'
      ;;
    1:active)
      allowed='version status token containment leader_pid leader_identity pgid'
      required='version status token leader_pid leader_identity pgid'
      ;;
    2:empty)
      allowed='version status token containment endpoint_pid endpoint_identity'
      required='version status token'
      ;;
    2:active)
      allowed='version status token containment anchor_pid anchor_identity agent_pid agent_identity endpoint_pid endpoint_identity pgid boot_generation'
      required='version status token anchor_pid anchor_identity agent_pid agent_identity pgid'
      ;;
    *) return 1 ;;
  esac
  read -r -a field_list <<< "$fields"
  for field in "${field_list[@]}"; do
    case " $allowed " in *" $field "*) ;; *) return 1 ;; esac
  done
  for field in $required; do
    case " $fields " in *" $field "*) ;; *) return 1 ;; esac
  done
}

fm_task_process_scope_record_read() {
  local state=$1 id=$2 expected_token=$3 path record line key value
  local version='' status='' token='' containment='' leader_pid='' leader_identity=''
  local boot_generation=''
  local anchor_pid anchor_identity agent_pid agent_identity endpoint_pid endpoint_identity
  local pgid identity_value legacy=0 owned_keys=''
  path=$(fm_task_process_scope_path "$state" "$id") || return 1
  if [ ! -f "$path" ] || [ -L "$path" ]; then
    echo "error: task $id has no trustworthy process-scope record at $path" >&2
    return 1
  fi
  fm_task_process_text_file_valid "$path" || {
    echo "error: task $id has a malformed process-scope record at $path" >&2
    return 1
  }
  record=$(cat "$path" 2>/dev/null) || {
    echo "error: task $id has no readable process-scope record at $path" >&2
    return 1
  }
  anchor_pid=
  anchor_identity=
  agent_pid=
  agent_identity=
  endpoint_pid=
  endpoint_identity=
  pgid=
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      *=*) ;;
      *)
        echo "error: task $id has a malformed process-scope record at $path" >&2
        return 1
        ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      version|status|token|containment|leader_pid|leader_identity|anchor_pid|anchor_identity|agent_pid|agent_identity|endpoint_pid|endpoint_identity|pgid|boot_generation)
        case " $owned_keys " in
          *" $key "*)
            echo "error: task $id has a malformed process-scope record at $path" >&2
            return 1
            ;;
        esac
        owned_keys="$owned_keys $key"
        ;;
      *)
        echo "error: task $id has a malformed process-scope record at $path" >&2
        return 1
        ;;
    esac
    case "$key" in
      version) version=$value ;;
      status) status=$value ;;
      token) token=$value ;;
      containment) containment=$value ;;
      leader_pid) leader_pid=$value ;;
      leader_identity) leader_identity=$value ;;
      anchor_pid) anchor_pid=$value ;;
      anchor_identity) anchor_identity=$value ;;
      agent_pid) agent_pid=$value ;;
      agent_identity) agent_identity=$value ;;
      endpoint_pid) endpoint_pid=$value ;;
      endpoint_identity) endpoint_identity=$value ;;
      pgid) pgid=$value ;;
      boot_generation) boot_generation=$value ;;
    esac
  done <<EOF
$record
EOF
  case "$version" in 1|2) ;; *) version= ;; esac
  if [ -z "$version" ] || ! fm_task_process_scope_token_valid "$token" \
     || [ "$token" != "$expected_token" ]; then
    echo "error: task $id has a stale or malformed process-scope record at $path" >&2
    return 1
  fi
  if ! fm_task_process_scope_record_schema_valid \
      "$version" "$status" "$owned_keys"; then
    echo "error: task $id has a malformed process-scope record at $path" >&2
    return 1
  fi
  case " $owned_keys " in
    *' boot_generation '*)
      fm_task_process_boot_generation_valid "$boot_generation" || {
        echo "error: task $id has a malformed process-scope record at $path" >&2
        return 1
      }
      ;;
  esac
  case " $owned_keys " in
    *' containment '*)
      case "$containment" in
        pid-namespace|process-group|unknown) ;;
        *)
          echo "error: task $id has a malformed process-scope record at $path" >&2
          return 1
          ;;
      esac
      ;;
    *) containment=unknown ;;
  esac
  case " $owned_keys " in
    *' endpoint_pid '*)
      case " $owned_keys " in *' endpoint_identity '*) ;; *)
        echo "error: task $id has a malformed process-scope record at $path" >&2
        return 1
        ;;
      esac
      ;;
    *' endpoint_identity '*)
      echo "error: task $id has a malformed process-scope record at $path" >&2
      return 1
      ;;
  esac
  case " $owned_keys " in
    *' endpoint_pid '*)
      fm_task_process_recorded_identity_valid "$endpoint_pid" "$endpoint_identity" || {
        echo "error: task $id has a malformed process-scope record at $path" >&2
        return 1
      }
      ;;
  esac
  case "$status" in
    empty)
      FM_TASK_PROCESS_SCOPE_STATUS=empty
      FM_TASK_PROCESS_SCOPE_VERSION=$version
      FM_TASK_PROCESS_SCOPE_TOKEN=$token
      FM_TASK_PROCESS_SCOPE_CONTAINMENT=$containment
      FM_TASK_PROCESS_SCOPE_PATH=$path
      FM_TASK_PROCESS_SCOPE_LEGACY=0
      FM_TASK_PROCESS_SCOPE_ANCHOR_PID=
      FM_TASK_PROCESS_SCOPE_ANCHOR_IDENTITY=
      FM_TASK_PROCESS_SCOPE_AGENT_PID=
      FM_TASK_PROCESS_SCOPE_AGENT_IDENTITY=
      FM_TASK_PROCESS_SCOPE_ENDPOINT_PID=$endpoint_pid
      FM_TASK_PROCESS_SCOPE_ENDPOINT_IDENTITY=$endpoint_identity
      FM_TASK_PROCESS_SCOPE_BOOT_GENERATION=$boot_generation
      FM_TASK_PROCESS_SCOPE_LEADER_PID=
      FM_TASK_PROCESS_SCOPE_LEADER_IDENTITY=
      FM_TASK_PROCESS_SCOPE_PGID=
      return 0
      ;;
    active) ;;
    *)
      echo "error: task $id has a malformed process-scope record at $path" >&2
      return 1
      ;;
  esac
  if [ "$version" = 1 ]; then
    anchor_pid=$leader_pid
    anchor_identity=$leader_identity
    agent_pid=$leader_pid
    agent_identity=$leader_identity
    legacy=1
  else
    :
  fi
  case "$anchor_pid" in
    ''|*[!0-9]*)
      echo "error: task $id has a malformed process-scope record at $path" >&2
      return 1
      ;;
  esac
  case "$pgid" in
    ''|*[!0-9]*)
      echo "error: task $id has a malformed process-scope record at $path" >&2
      return 1
      ;;
  esac
  if [ "$anchor_pid" -le 1 ] || [ "$pgid" -le 1 ] || [ "$anchor_pid" != "$pgid" ]; then
    echo "error: task $id has a malformed process-scope record at $path" >&2
    return 1
  fi
  case "$anchor_identity" in
    starttime=*)
      identity_value=${anchor_identity#starttime=}
      case "$identity_value" in ''|*[!0-9]*) identity_value= ;; esac
      ;;
    lstart=*)
      identity_value=${anchor_identity#lstart=}
      case "$identity_value" in ''|*[!A-Za-z0-9_:.-]*) identity_value= ;; esac
      ;;
    *) identity_value= ;;
  esac
  if [ -z "$identity_value" ]; then
      echo "error: task $id has a malformed process-scope record at $path" >&2
      return 1
  fi
  case "$agent_pid" in
    ''|*[!0-9]*) identity_value= ;;
    *)
      case "$agent_identity" in
        starttime=*)
          identity_value=${agent_identity#starttime=}
          case "$identity_value" in ''|*[!0-9]*) identity_value= ;; esac
          ;;
        lstart=*)
          identity_value=${agent_identity#lstart=}
          case "$identity_value" in ''|*[!A-Za-z0-9_:.-]*) identity_value= ;; esac
          ;;
        *) identity_value= ;;
      esac
      ;;
  esac
  if [ -z "$identity_value" ] || [ "$agent_pid" -le 1 ]; then
    echo "error: task $id has a malformed process-scope record at $path" >&2
    return 1
  fi
  FM_TASK_PROCESS_SCOPE_STATUS=active
  # shellcheck disable=SC2034 # Public record-reader output retained for callers.
  FM_TASK_PROCESS_SCOPE_VERSION=$version
  FM_TASK_PROCESS_SCOPE_TOKEN=$token
  FM_TASK_PROCESS_SCOPE_CONTAINMENT=$containment
  FM_TASK_PROCESS_SCOPE_PATH=$path
  FM_TASK_PROCESS_SCOPE_LEGACY=$legacy
  FM_TASK_PROCESS_SCOPE_ANCHOR_PID=$anchor_pid
  FM_TASK_PROCESS_SCOPE_ANCHOR_IDENTITY=$anchor_identity
  FM_TASK_PROCESS_SCOPE_AGENT_PID=$agent_pid
  FM_TASK_PROCESS_SCOPE_AGENT_IDENTITY=$agent_identity
  FM_TASK_PROCESS_SCOPE_ENDPOINT_PID=$endpoint_pid
  FM_TASK_PROCESS_SCOPE_ENDPOINT_IDENTITY=$endpoint_identity
  FM_TASK_PROCESS_SCOPE_BOOT_GENERATION=$boot_generation
  # shellcheck disable=SC2034 # Backward-compatible alias for the anchor PID.
  FM_TASK_PROCESS_SCOPE_LEADER_PID=$anchor_pid
  # shellcheck disable=SC2034 # Backward-compatible alias for the anchor identity.
  FM_TASK_PROCESS_SCOPE_LEADER_IDENTITY=$anchor_identity
  FM_TASK_PROCESS_SCOPE_PGID=$pgid
}

fm_task_process_scope_snapshot() {
  local token=$1 pgid=$2 use_group=$3 excluded_pid=${4:-$$} exclude_descendants=${5:-0}
  local output line pid current_ppid current_pgid current_stat rest identity pids="" failed=0
  local scanner_pid=${BASHPID:-$$} excluded_pids excluded_trees changed
  output=$(LC_ALL=C ps axeww \
    -o pid= -o ppid= -o pgid= -o stat= -o command= 2>/dev/null) || return 1
  # $$ is the lifecycle shell even inside snapshot command substitution;
  # BASHPID is the substitution itself. Exclude both so an inherited worker
  # token cannot select the quiesce process for signaling.
  excluded_pids=" $scanner_pid $$ "
  excluded_trees=" $scanner_pid $$ "
  case "$excluded_pid" in
    *[!0-9]*|'') ;;
    *)
      excluded_pids="$excluded_pids$excluded_pid "
      [ "$exclude_descendants" != 1 ] || excluded_trees="$excluded_trees$excluded_pid "
      ;;
  esac
  changed=1
  while [ "$changed" = 1 ]; do
    changed=0
    while IFS= read -r line; do
      line=${line#"${line%%[![:space:]]*}"}
      pid=${line%%[[:space:]]*}
      rest=${line#"$pid"}
      rest=${rest#"${rest%%[![:space:]]*}"}
      current_ppid=${rest%%[[:space:]]*}
      case "$pid:$current_ppid" in *[!0-9:]*|:*|*:) continue ;; esac
      case "$excluded_pids" in *" $pid "*) continue ;; esac
      case "$excluded_trees" in
        *" $current_ppid "*)
          excluded_pids="$excluded_pids$pid "
          excluded_trees="$excluded_trees$pid "
          changed=1
          ;;
      esac
    done <<EOF
$output
EOF
  done
  while IFS= read -r line; do
    line=${line#"${line%%[![:space:]]*}"}
    pid=${line%%[[:space:]]*}
    rest=${line#"$pid"}
    rest=${rest#"${rest%%[![:space:]]*}"}
    current_ppid=${rest%%[[:space:]]*}
    rest=${rest#"$current_ppid"}
    rest=${rest#"${rest%%[![:space:]]*}"}
    current_pgid=${rest%%[[:space:]]*}
    rest=${rest#"$current_pgid"}
    rest=${rest#"${rest%%[![:space:]]*}"}
    current_stat=${rest%%[[:space:]]*}
    rest=${rest#"$current_stat"}
    case "$pid:$current_ppid:$current_pgid" in *[!0-9:]*|:*|*::*|*:) continue ;; esac
    case "$current_stat" in *Z*) continue ;; esac
    case "$excluded_pids" in *" $pid "*) continue ;; esac
    if [ "$use_group" = 1 ] && [ "$current_pgid" = "$pgid" ]; then
      :
    else
      case " $rest " in
        *" FM_TASK_PROCESS_SCOPE_TOKEN=$token "*) ;;
        *) continue ;;
      esac
    fi
    if identity=$(fm_task_process_identity "$pid"); then
      pids="$pids
$pid	$identity"
    elif kill -0 "$pid" 2>/dev/null; then
      failed=1
    fi
  done <<EOF
$output
EOF
  [ "$failed" -eq 0 ] || return 1
  printf '%b\n' "$pids" | awk 'NF == 2 && $1 ~ /^[0-9]+$/ {print $1 "\t" $2}' | sort -n -k1,1
}

fm_task_process_scope_snapshot_contains() {
  local snapshot=$1 wanted_pid=$2 wanted_identity=$3 pid identity
  while IFS=$'\t' read -r pid identity; do
    [ "$pid" = "$wanted_pid" ] && [ "$identity" = "$wanted_identity" ] && return 0
  done <<EOF
$snapshot
EOF
  return 1
}

fm_task_process_scope_mark_empty() {
  local path=$1 token=$2 containment=$3 endpoint_pid=${4:-} endpoint_identity=${5:-} tmp
  case "$containment" in pid-namespace|process-group|unknown) ;; *) return 1 ;; esac
  if [ -n "$endpoint_pid" ] || [ -n "$endpoint_identity" ]; then
    fm_task_process_recorded_identity_valid "$endpoint_pid" "$endpoint_identity" || return 1
  fi
  tmp=$(umask 077; mktemp "${path%/*}/.${path##*/}.XXXXXX") || return 1
  if {
      printf 'version=2\n'
      printf 'status=empty\n'
      printf 'token=%s\n' "$token"
      printf 'containment=%s\n' "$containment"
      [ -z "$endpoint_pid" ] || printf 'endpoint_pid=%s\n' "$endpoint_pid"
      [ -z "$endpoint_identity" ] || printf 'endpoint_identity=%s\n' "$endpoint_identity"
    } > "$tmp" && chmod 0600 "$tmp" && mv -f -- "$tmp" "$path"; then
    return 0
  fi
  rm -f -- "$tmp" 2>/dev/null || true
  return 1
}

fm_task_process_scope_create_empty() {
  local state=$1 id=$2 token=$3 containment=$4 path tmp
  fm_task_process_scope_token_valid "$token" || return 1
  case "$containment" in pid-namespace|process-group) ;; *) return 1 ;; esac
  path=$(fm_task_process_scope_path "$state" "$id") || return 1
  [ ! -e "$path" ] && [ ! -L "$path" ] || return 1
  tmp=$(umask 077; mktemp "${path%/*}/.${path##*/}.XXXXXX") || return 1
  if {
      printf 'version=2\n'
      printf 'status=empty\n'
      printf 'token=%s\n' "$token"
      printf 'containment=%s\n' "$containment"
    } > "$tmp" && chmod 0600 "$tmp" && ln "$tmp" "$path"; then
    rm -f -- "$tmp"
    return 0
  fi
  rm -f -- "$tmp" 2>/dev/null || true
  return 1
}

fm_task_process_scope_quiesce() {
  local state=$1 id=$2 expected_token=$3 label=${4:-task} snapshot current pid identity
  local pass=1 max_passes=${FM_TASK_PROCESS_SCOPE_REAP_PASSES:-3}
  local own_pgid anchor_pgid excluded_pid=- exclude_descendants=0
  case "$max_passes" in ''|*[!0-9]*|0) max_passes=3 ;; esac
  fm_task_process_scope_token_valid "$expected_token" || {
    echo "error: task $id has no valid launch generation for process-scope cleanup" >&2
    return 1
  }
  fm_task_process_scope_record_read "$state" "$id" "$expected_token" || return 1
  [ "$FM_TASK_PROCESS_SCOPE_STATUS" = active ] || return 0
  if fm_task_process_scope_prior_boot_proven; then
    fm_task_process_scope_mark_empty "$FM_TASK_PROCESS_SCOPE_PATH" "$FM_TASK_PROCESS_SCOPE_TOKEN" \
      "$FM_TASK_PROCESS_SCOPE_CONTAINMENT" "$FM_TASK_PROCESS_SCOPE_ENDPOINT_PID" \
      "$FM_TASK_PROCESS_SCOPE_ENDPOINT_IDENTITY" || {
      echo "error: could not publish the empty process scope for task $id" >&2
      return 1
    }
    return 0
  fi
  own_pgid=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d '[:space:]') || {
    echo "error: cannot inspect the lifecycle command's process group for task $id" >&2
    return 1
  }
  case "$own_pgid" in ''|*[!0-9]*)
    echo "error: cannot inspect the lifecycle command's process group for task $id" >&2
    return 1
    ;;
  esac
  if [ "$FM_TASK_PROCESS_SCOPE_PGID" = "$own_pgid" ]; then
    echo "error: refusing to signal the lifecycle command's own process group for task $id" >&2
    return 1
  fi
  if ! fm_task_process_identity_matches \
      "$FM_TASK_PROCESS_SCOPE_ANCHOR_PID" "$FM_TASK_PROCESS_SCOPE_ANCHOR_IDENTITY"; then
    echo "error: task $id process-scope anchor is gone or changed; refusing to signal an unowned process group" >&2
    return 1
  fi
  anchor_pgid=$(fm_task_process_pgid "$FM_TASK_PROCESS_SCOPE_ANCHOR_PID") || {
    echo "error: cannot inspect task $id process-scope anchor group" >&2
    return 1
  }
  if [ "$anchor_pgid" != "$FM_TASK_PROCESS_SCOPE_PGID" ]; then
    echo "error: task $id process-scope anchor left its recorded process group" >&2
    return 1
  fi
  [ "$FM_TASK_PROCESS_SCOPE_LEGACY" = 1 ] \
    || {
      excluded_pid=$FM_TASK_PROCESS_SCOPE_ANCHOR_PID
    }
  while [ "$pass" -le "$max_passes" ]; do
    if [ "$FM_TASK_PROCESS_SCOPE_LEGACY" != 1 ]; then
      if fm_task_process_identity_matches \
          "$FM_TASK_PROCESS_SCOPE_AGENT_PID" "$FM_TASK_PROCESS_SCOPE_AGENT_IDENTITY"; then
        exclude_descendants=0
      else
        exclude_descendants=1
      fi
    fi
    snapshot=$(fm_task_process_scope_snapshot \
      "$FM_TASK_PROCESS_SCOPE_TOKEN" "$FM_TASK_PROCESS_SCOPE_PGID" \
      1 "$excluded_pid" "$exclude_descendants") || {
      echo "error: cannot inspect the complete process scope for task $id" >&2
      return 1
    }
    [ -n "$snapshot" ] || {
      if [ "$FM_TASK_PROCESS_SCOPE_LEGACY" != 1 ]; then
        fm_task_process_scope_wait_empty "$state" "$id" "$expected_token"
        return $?
      fi
      fm_task_process_scope_mark_empty "$FM_TASK_PROCESS_SCOPE_PATH" "$FM_TASK_PROCESS_SCOPE_TOKEN" \
        "$FM_TASK_PROCESS_SCOPE_CONTAINMENT" "$FM_TASK_PROCESS_SCOPE_ENDPOINT_PID" \
        "$FM_TASK_PROCESS_SCOPE_ENDPOINT_IDENTITY" || {
        echo "error: could not publish the empty process scope for task $id" >&2
        return 1
      }
      return 0
    }
    echo "lifecycle: reaping $label process scope for $id: $(printf '%s\n' "$snapshot" | cut -f1 | tr '\n' ' ')" >&2
    current=$(fm_task_process_scope_snapshot \
      "$FM_TASK_PROCESS_SCOPE_TOKEN" "$FM_TASK_PROCESS_SCOPE_PGID" \
      1 "$excluded_pid" "$exclude_descendants") || return 1
    while IFS=$'\t' read -r pid identity; do
      [ -n "$pid" ] || continue
      fm_task_process_scope_snapshot_contains "$current" "$pid" "$identity" \
        && fm_task_process_identity_matches "$pid" "$identity" \
        && kill -TERM "$pid" 2>/dev/null || true
    done <<EOF
$snapshot
EOF
    sleep 1
    if [ "$FM_TASK_PROCESS_SCOPE_LEGACY" != 1 ] \
       && fm_task_process_identity_matches \
         "$FM_TASK_PROCESS_SCOPE_AGENT_PID" "$FM_TASK_PROCESS_SCOPE_AGENT_IDENTITY"; then
      exclude_descendants=0
    elif [ "$FM_TASK_PROCESS_SCOPE_LEGACY" != 1 ]; then
      exclude_descendants=1
    fi
    current=$(fm_task_process_scope_snapshot \
      "$FM_TASK_PROCESS_SCOPE_TOKEN" "$FM_TASK_PROCESS_SCOPE_PGID" \
      1 "$excluded_pid" "$exclude_descendants") || return 1
    while IFS=$'\t' read -r pid identity; do
      [ -n "$pid" ] || continue
      fm_task_process_scope_snapshot_contains "$current" "$pid" "$identity" \
        && fm_task_process_identity_matches "$pid" "$identity" \
        && kill -KILL "$pid" 2>/dev/null || true
    done <<EOF
$snapshot
EOF
    pass=$((pass + 1))
  done
  if [ "$FM_TASK_PROCESS_SCOPE_LEGACY" != 1 ] \
     && fm_task_process_identity_matches \
       "$FM_TASK_PROCESS_SCOPE_AGENT_PID" "$FM_TASK_PROCESS_SCOPE_AGENT_IDENTITY"; then
    exclude_descendants=0
  elif [ "$FM_TASK_PROCESS_SCOPE_LEGACY" != 1 ]; then
    exclude_descendants=1
  fi
  snapshot=$(fm_task_process_scope_snapshot \
    "$FM_TASK_PROCESS_SCOPE_TOKEN" "$FM_TASK_PROCESS_SCOPE_PGID" \
    1 "$excluded_pid" "$exclude_descendants") || return 1
  if [ -n "$snapshot" ]; then
    echo "error: task $id process scope remains live after $max_passes reap attempts" >&2
    return 1
  fi
  if [ "$FM_TASK_PROCESS_SCOPE_LEGACY" != 1 ]; then
    fm_task_process_scope_wait_empty "$state" "$id" "$expected_token"
    return $?
  fi
  fm_task_process_scope_mark_empty "$FM_TASK_PROCESS_SCOPE_PATH" "$FM_TASK_PROCESS_SCOPE_TOKEN" \
    "$FM_TASK_PROCESS_SCOPE_CONTAINMENT" "$FM_TASK_PROCESS_SCOPE_ENDPOINT_PID" \
    "$FM_TASK_PROCESS_SCOPE_ENDPOINT_IDENTITY"
}

fm_task_process_scope_require_pid_namespace() {
  local state=$1 id=$2 expected_token=$3 purpose=${4:-lifecycle transition}
  fm_task_process_scope_record_read "$state" "$id" "$expected_token" || return 1
  [ "$FM_TASK_PROCESS_SCOPE_CONTAINMENT" = pid-namespace ] || {
    echo "error: task $id cannot perform $purpose because its worker process scope lacks PID namespace containment on this host" >&2
    return 1
  }
}

fm_task_process_scope_wait_empty() {
  local state=$1 id=$2 expected_token=$3 attempt=0 anchor_pgid
  local attempts=${FM_TASK_PROCESS_SCOPE_EMPTY_ATTEMPTS:-100}
  local interval=${FM_TASK_PROCESS_SCOPE_EMPTY_INTERVAL:-0.02}
  case "$attempts" in ''|*[!0-9]*) attempts=100 ;; esac
  while [ "$attempt" -lt "$attempts" ]; do
    fm_task_process_scope_record_read "$state" "$id" "$expected_token" || return 1
    [ "$FM_TASK_PROCESS_SCOPE_STATUS" = empty ] && return 0
    if ! fm_task_process_identity_matches \
        "$FM_TASK_PROCESS_SCOPE_ANCHOR_PID" "$FM_TASK_PROCESS_SCOPE_ANCHOR_IDENTITY"; then
      echo "error: task $id process-scope anchor exited before publishing an empty scope" >&2
      return 1
    fi
    anchor_pgid=$(fm_task_process_pgid "$FM_TASK_PROCESS_SCOPE_ANCHOR_PID") || return 1
    if [ "$anchor_pgid" != "$FM_TASK_PROCESS_SCOPE_PGID" ]; then
      echo "error: task $id process-scope anchor left its recorded process group before retirement" >&2
      return 1
    fi
    sleep "$interval"
    attempt=$((attempt + 1))
  done
  echo "error: task $id process-scope anchor did not publish an empty scope" >&2
  return 1
}

fm_task_process_scope_remove_empty() {
  local state=$1 id=$2 expected_token=$3
  fm_task_process_scope_record_read "$state" "$id" "$expected_token" || return 1
  [ "$FM_TASK_PROCESS_SCOPE_STATUS" = empty ] || return 1
  rm -f -- "$FM_TASK_PROCESS_SCOPE_PATH"
}
