#!/usr/bin/env bash

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

fm_task_process_scope_token_valid() {
  case "${1-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
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

fm_task_process_scope_record_value() {
  local path=$1 key=$2
  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); value=$0} END {print value}' "$path"
}

fm_task_process_scope_record_read() {
  local state=$1 id=$2 expected_token=$3 path version status token leader_pid leader_identity pgid identity_value
  path=$(fm_task_process_scope_path "$state" "$id") || return 1
  if [ ! -f "$path" ] || [ -L "$path" ]; then
    echo "error: task $id has no trustworthy process-scope record at $path" >&2
    return 1
  fi
  version=$(fm_task_process_scope_record_value "$path" version)
  status=$(fm_task_process_scope_record_value "$path" status)
  token=$(fm_task_process_scope_record_value "$path" token)
  leader_pid=$(fm_task_process_scope_record_value "$path" leader_pid)
  leader_identity=$(fm_task_process_scope_record_value "$path" leader_identity)
  pgid=$(fm_task_process_scope_record_value "$path" pgid)
  if [ "$version" != 1 ] || ! fm_task_process_scope_token_valid "$token" \
     || [ "$token" != "$expected_token" ]; then
    echo "error: task $id has a stale or malformed process-scope record at $path" >&2
    return 1
  fi
  case "$status" in
    empty)
      FM_TASK_PROCESS_SCOPE_STATUS=empty
      FM_TASK_PROCESS_SCOPE_TOKEN=$token
      FM_TASK_PROCESS_SCOPE_PATH=$path
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
  case "$leader_pid" in
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
  if [ "$leader_pid" -le 1 ] || [ "$pgid" -le 1 ] || [ "$leader_pid" != "$pgid" ]; then
    echo "error: task $id has a malformed process-scope record at $path" >&2
    return 1
  fi
  case "$leader_identity" in
    starttime=*)
      identity_value=${leader_identity#starttime=}
      case "$identity_value" in ''|*[!0-9]*) identity_value= ;; esac
      ;;
    lstart=*)
      identity_value=${leader_identity#lstart=}
      case "$identity_value" in ''|*[!A-Za-z0-9_:.-]*) identity_value= ;; esac
      ;;
    *) identity_value= ;;
  esac
  if [ -z "$identity_value" ]; then
      echo "error: task $id has a malformed process-scope record at $path" >&2
      return 1
  fi
  FM_TASK_PROCESS_SCOPE_STATUS=active
  FM_TASK_PROCESS_SCOPE_TOKEN=$token
  FM_TASK_PROCESS_SCOPE_PATH=$path
  FM_TASK_PROCESS_SCOPE_LEADER_PID=$leader_pid
  FM_TASK_PROCESS_SCOPE_LEADER_IDENTITY=$leader_identity
  FM_TASK_PROCESS_SCOPE_PGID=$pgid
}

fm_task_process_scope_snapshot() {
  local token=$1 pgid=$2 use_group=$3
  local output line pid current_pgid current_stat rest identity pids="" failed=0
  output=$(LC_ALL=C ps eww -axo pid=,pgid=,stat=,command= 2>/dev/null) || return 1
  while IFS= read -r line; do
    line=${line#"${line%%[![:space:]]*}"}
    pid=${line%%[[:space:]]*}
    rest=${line#"$pid"}
    rest=${rest#"${rest%%[![:space:]]*}"}
    current_pgid=${rest%%[[:space:]]*}
    rest=${rest#"$current_pgid"}
    rest=${rest#"${rest%%[![:space:]]*}"}
    current_stat=${rest%%[[:space:]]*}
    rest=${rest#"$current_stat"}
    case "$pid:$current_pgid" in *[!0-9:]*|:*) continue ;; esac
    case "$current_stat" in *Z*) continue ;; esac
    if [ "$use_group" = 1 ] && [ "$current_pgid" = "$pgid" ]; then
      :
    else
      case " $rest " in
        *" FM_TASK_PROCESS_SCOPE_TOKEN=$token "*) ;;
        *) continue ;;
      esac
    fi
    [ "$pid" != "$$" ] || continue
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
  local path=$1 token=$2 tmp
  tmp=$(umask 077; mktemp "${path%/*}/.${path##*/}.XXXXXX") || return 1
  if {
      printf 'version=1\n'
      printf 'status=empty\n'
      printf 'token=%s\n' "$token"
    } > "$tmp" && chmod 0600 "$tmp" && mv -f -- "$tmp" "$path"; then
    return 0
  fi
  rm -f -- "$tmp" 2>/dev/null || true
  return 1
}

fm_task_process_scope_create_empty() {
  local state=$1 id=$2 token=$3 path tmp
  fm_task_process_scope_token_valid "$token" || return 1
  path=$(fm_task_process_scope_path "$state" "$id") || return 1
  [ ! -e "$path" ] && [ ! -L "$path" ] || return 1
  tmp=$(umask 077; mktemp "${path%/*}/.${path##*/}.XXXXXX") || return 1
  if {
      printf 'version=1\n'
      printf 'status=empty\n'
      printf 'token=%s\n' "$token"
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
  local own_pgid scope_group_trusted=0
  case "$max_passes" in ''|*[!0-9]*|0) max_passes=3 ;; esac
  fm_task_process_scope_token_valid "$expected_token" || {
    echo "error: task $id has no valid launch generation for process-scope cleanup" >&2
    return 1
  }
  fm_task_process_scope_record_read "$state" "$id" "$expected_token" || return 1
  [ "$FM_TASK_PROCESS_SCOPE_STATUS" = active ] || return 0
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
  if kill -0 "$FM_TASK_PROCESS_SCOPE_LEADER_PID" 2>/dev/null \
     && ! fm_task_process_identity_matches "$FM_TASK_PROCESS_SCOPE_LEADER_PID" "$FM_TASK_PROCESS_SCOPE_LEADER_IDENTITY"; then
    echo "error: task $id process-scope leader identity changed; refusing to signal a reused process group" >&2
    return 1
  fi
  if fm_task_process_identity_matches \
      "$FM_TASK_PROCESS_SCOPE_LEADER_PID" "$FM_TASK_PROCESS_SCOPE_LEADER_IDENTITY"; then
    scope_group_trusted=1
  fi
  while [ "$pass" -le "$max_passes" ]; do
    snapshot=$(fm_task_process_scope_snapshot \
      "$FM_TASK_PROCESS_SCOPE_TOKEN" "$FM_TASK_PROCESS_SCOPE_PGID" \
      "$scope_group_trusted") || {
      echo "error: cannot inspect the complete process scope for task $id" >&2
      return 1
    }
    [ -n "$snapshot" ] || {
      fm_task_process_scope_mark_empty "$FM_TASK_PROCESS_SCOPE_PATH" "$FM_TASK_PROCESS_SCOPE_TOKEN" || {
        echo "error: could not publish the empty process scope for task $id" >&2
        return 1
      }
      return 0
    }
    echo "lifecycle: reaping $label process scope for $id: $(printf '%s\n' "$snapshot" | cut -f1 | tr '\n' ' ')" >&2
    current=$(fm_task_process_scope_snapshot \
      "$FM_TASK_PROCESS_SCOPE_TOKEN" "$FM_TASK_PROCESS_SCOPE_PGID" \
      "$scope_group_trusted") || return 1
    while IFS=$'\t' read -r pid identity; do
      [ -n "$pid" ] || continue
      fm_task_process_scope_snapshot_contains "$current" "$pid" "$identity" \
        && fm_task_process_identity_matches "$pid" "$identity" \
        && kill -TERM "$pid" 2>/dev/null || true
    done <<EOF
$snapshot
EOF
    sleep 1
    current=$(fm_task_process_scope_snapshot \
      "$FM_TASK_PROCESS_SCOPE_TOKEN" "$FM_TASK_PROCESS_SCOPE_PGID" \
      "$scope_group_trusted") || return 1
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
  snapshot=$(fm_task_process_scope_snapshot \
    "$FM_TASK_PROCESS_SCOPE_TOKEN" "$FM_TASK_PROCESS_SCOPE_PGID" \
    "$scope_group_trusted") || return 1
  if [ -n "$snapshot" ]; then
    echo "error: task $id process scope remains live after $max_passes reap attempts" >&2
    return 1
  fi
  fm_task_process_scope_mark_empty "$FM_TASK_PROCESS_SCOPE_PATH" "$FM_TASK_PROCESS_SCOPE_TOKEN"
}

fm_task_process_scope_remove_empty() {
  local state=$1 id=$2 expected_token=$3
  fm_task_process_scope_record_read "$state" "$id" "$expected_token" || return 1
  [ "$FM_TASK_PROCESS_SCOPE_STATUS" = empty ] || return 1
  rm -f -- "$FM_TASK_PROCESS_SCOPE_PATH"
}
