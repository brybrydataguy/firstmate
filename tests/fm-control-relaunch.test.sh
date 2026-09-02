#!/usr/bin/env bash
# fm-control.sh relaunch: the transactional replace-the-agent verb.
#
# Relaunch is the only control verb that changes durable records, so these
# tests pin the transaction itself, hermetically (stubbed session provider, no
# real agent):
#   1. A same-harness relaunch keeps every identity axis and reuses the SAME
#      endpoint and worktree - it replaces an agent, it never forks a task.
#   2. A harness switch is one ordinary relaunch: the record follows, the
#      previous harness's per-task wiring is cleared, and profile axes chosen
#      for the old harness do not silently carry to the new one.
#   3. The progress note is required where the replacement needs it, lands in
#      the instructions the replacement reads, and never rewrites a charter.
#   4. A refusal before the agent is stopped changes nothing.
#   5. A launch failure after the agent is stopped keeps the prior record,
#      reports the concrete state, and preserves the work.
#   6. fm-spawn --relaunch refuses on its own: a live agent, a contradicting
#      flag, an extra positional, or a backend that cannot prove the previous
#      agent exited.
#   7. After a host reboot, a proved prior-boot process scope is retired
#      without signaling, then ordinary relaunch guards still apply.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-task-process-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-trace-context-lib.sh"

CONTROL="$ROOT/bin/fm-control.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
X_LINK="$ROOT/bin/fm-x-link.sh"
# fm_test_tmproot's own cleanup trap fires when its command substitution exits,
# so recreate the root before resolving it and clean it up from this file's trap.
TMP_ROOT=$(fm_test_tmproot fm-control-relaunch)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
TASK_TMPS=()
SCOPE_SLEEPERS=()

relaunch_cleanup() {
  local d pid
  for pid in "${SCOPE_SLEEPERS[@]:-}"; do
    kill -KILL "$pid" 2>/dev/null || true
  done
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  rm -rf "$TMP_ROOT"
}
trap relaunch_cleanup EXIT

# The same lifecycle-modelling tmux stub as tests/fm-control.test.sh: the
# harness's exit command stops the agent, and a launch-brief literal starts the
# harness named in `becomes`.
make_tmux_stub() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit)
          printf 'zsh' > "$D/command"
          [ -z "${FM_FAKE_EXIT_TRANSPORT_FAIL_AFTER_STOP:-}" ] || exit 1
          ;;
        *'encode launch-brief'*)
          cat "$D/becomes" > "$D/command"
          [ -z "${FM_FAKE_LAUNCH_TRANSPORT_FAIL_AFTER_START:-}" ] || exit 1
          ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
      case "$payload" in
        'export GOTMPDIR='*)
          if [ -n "${FM_FAKE_TRACE_PREPARE:-}" ]; then
            : > "$FM_FAKE_TRACE_PREPARE"
            while [ ! -e "$FM_FAKE_META_WRITER_READY" ]; do /bin/sleep 0.01; done
          fi
          ;;
        'export TRACEPARENT='*)
          [ -z "${FM_FAKE_TRACE_EXPORTED:-}" ] || : > "$FM_FAKE_TRACE_EXPORTED"
          ;;
      esac
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*)
          if [ -n "${FM_FAKE_CWD_RACE_READY:-}" ]; then
            : > "$FM_FAKE_CWD_RACE_READY"
            /bin/sleep 1
          fi
          cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  cat > "$fb/unshare" <<'SH'
#!/usr/bin/env bash
set -u
while [ "$#" -gt 0 ]; do
  case "$1" in
    --user|--map-current-user|--pid|--fork|--kill-child=SIGKILL|--mount-proc) shift ;;
    --) shift; break ;;
    *) break ;;
  esac
done
if [ "${1:-}" = /bin/sh ] && [ "${2:-}" = -c ] \
   && [ "${3:-}" = '[ "$$" -eq 1 ]' ]; then
  exit 0
fi
exec "$@"
SH
  chmod +x "$fb/unshare"
  fm_fake_exit0 "$fb" agy jq
}

# new_case <name> [id] -> echoes a case dir with a live claude ship task.
new_case() {
  local id=${2:-t1} dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  make_tmux_stub "$dir"
  printf '%s\n' "$dir"
}

# add_ship_task <case-dir> <id> [harness]
add_ship_task() {
  local dir=$1 id=$2 harness=${3:-claude}
  local home="$dir/home" proj="$dir/proj" wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  printf '# brief for %s\n\nDo the thing.\n' "$id" > "$home/data/$id/brief.md"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=$harness"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
    echo "spawn_gen=test-$id"
    echo "process_scope_token=test-$id"
  } > "$home/state/$id.meta"
  {
    echo "version=2"
    echo "status=empty"
    echo "token=test-$id"
    echo "containment=pid-namespace"
  } > "$home/state/$id.process-scope"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$wt" > "$dir/fake/cwd"
  TASK_TMPS+=("/tmp/fm-$id")
}

run_control() {  # <case-dir> <args...>
  local dir=$1; shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    FM_TASK_PROCESS_SCOPE_START_ATTEMPTS=0 \
    FM_REAL_GIT="${FM_REAL_GIT:-}" FM_FAKE_GIT_FAILURE="${FM_FAKE_GIT_FAILURE:-}" \
    FM_REAL_MV="${FM_REAL_MV:-}" FM_FAKE_COMPLETE_JOURNAL_MV_FAIL="${FM_FAKE_COMPLETE_JOURNAL_MV_FAIL:-}" \
    FM_FAKE_META_PUBLISH_MV_FAIL="${FM_FAKE_META_PUBLISH_MV_FAIL:-}" \
    FM_FAKE_TRACE_PREPARE="${FM_FAKE_TRACE_PREPARE:-}" \
    FM_FAKE_META_WRITER_READY="${FM_FAKE_META_WRITER_READY:-}" \
    FM_FAKE_TRACE_EXPORTED="${FM_FAKE_TRACE_EXPORTED:-}" \
    "$CONTROL" "$@" 2>&1
}

run_spawn() {  # <case-dir> <args...>
  local dir=$1; shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    FM_TASK_PROCESS_SCOPE_START_ATTEMPTS=0 \
    "$SPAWN" "$@" 2>&1
}

meta_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.meta" | tail -1 | cut -d= -f2-
}

journal_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.control-relaunch" | tail -1 | cut -d= -f2-
}

make_git_failure_stub() {  # <case-dir>
  cat > "$1/fakebin/git" <<'SH'
#!/usr/bin/env bash
case "${FM_FAKE_GIT_FAILURE:-}:$*" in
  head:*' rev-parse --verify HEAD'|head:*' symbolic-ref -q HEAD') exit 128 ;;
  status:*' status --porcelain') exit 128 ;;
esac
exec "$FM_REAL_GIT" "$@"
SH
  chmod +x "$1/fakebin/git"
}

make_mv_failure_stub() {  # <case-dir>
  cat > "$1/fakebin/mv" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_FAKE_COMPLETE_JOURNAL_MV_FAIL:-}" ]; then
  for path in "$@"; do
    if [ -f "$path" ] && grep -Fqx 'phase=complete' "$path"; then
      exit 1
    fi
  done
fi
if [ -n "${FM_FAKE_META_PUBLISH_MV_FAIL:-}" ]; then
  for path in "$@"; do
    [ "$path" != "$FM_FAKE_META_PUBLISH_MV_FAIL" ] || exit 1
  done
fi
source_path=
target_path=
for path in "$@"; do
  source_path=$target_path
  target_path=$path
done
if [ -n "${FM_FAKE_META_WRITER_TARGET:-}" ] \
   && [ "$target_path" = "$FM_FAKE_META_WRITER_TARGET" ] \
   && grep -q '^x_request=' "$source_path" 2>/dev/null; then
  : > "$FM_FAKE_META_WRITER_READY"
  while [ ! -e "$FM_FAKE_META_WRITER_RELEASE" ]; do /bin/sleep 0.01; done
fi
exec "$FM_REAL_MV" "$@"
SH
  chmod +x "$1/fakebin/mv"
}

make_rm_failure_stub() {  # <case-dir>
  cat > "$1/fakebin/rm" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ -n "${FM_FAKE_RM_FAIL_PATH:-}" ] && [ "$arg" = "$FM_FAKE_RM_FAIL_PATH" ]; then
    exit 1
  fi
done
exec "$FM_REAL_RM" "$@"
SH
  chmod +x "$1/fakebin/rm"
}

SCOPE_BOOT_TIME=1700000000

unset_boot_overlays() {
  unset FM_TASK_PROCESS_BOOT_GENERATION FM_TASK_PROCESS_BOOT_GENERATION_FILE
  unset FM_TASK_PROCESS_BOOT_TIME FM_TASK_PROCESS_BOOT_TIME_FILE
}

set_boot_overlays() {
  export FM_TASK_PROCESS_BOOT_GENERATION=${1:-boot-now}
  export FM_TASK_PROCESS_BOOT_TIME=${2:-$SCOPE_BOOT_TIME}
}

scope_lstart_at() {
  local epoch=$1 out
  if out=$(LC_ALL=C date -j -r "$epoch" +"%a_%b_%d_%T_%Y" 2>/dev/null); then
    printf 'lstart=%s\n' "$out"
    return 0
  fi
  out=$(LC_ALL=C date -d "@$epoch" +"%a_%b_%d_%T_%Y") || return 1
  printf 'lstart=%s\n' "$out"
}

start_scope_sleeper() {
  python3 - <<'PY' &
import os
os.setpgrp()
os.execv("/bin/sleep", ["sleep", "300"])
PY
  SCOPE_SLEEPER_PID=$!
  SCOPE_SLEEPERS+=("$SCOPE_SLEEPER_PID")
  local attempts=0 pgid=
  while [ "$attempts" -lt 50 ]; do
    pgid=$(ps -o pgid= -p "$SCOPE_SLEEPER_PID" 2>/dev/null | tr -d '[:space:]')
    [ "$pgid" = "$SCOPE_SLEEPER_PID" ] && break
    /bin/sleep 0.02
    attempts=$((attempts + 1))
  done
  [ "$pgid" = "$SCOPE_SLEEPER_PID" ] \
    || fail "scope sleeper did not enter its own process group"
}

assert_scope_sleeper_alive() {
  kill -0 "$SCOPE_SLEEPER_PID" 2>/dev/null \
    || fail "reused process $SCOPE_SLEEPER_PID was signaled"
}

write_active_reused_scope() {
  local dir=$1 id=$2 identity=$3 boot_gen=${4-}
  local pid=$SCOPE_SLEEPER_PID token=test-$id
  {
    printf 'version=2\n'
    printf 'status=active\n'
    printf 'token=%s\n' "$token"
    printf 'containment=process-group\n'
    printf 'anchor_pid=%s\n' "$pid"
    printf 'anchor_identity=%s\n' "$identity"
    printf 'agent_pid=%s\n' "$pid"
    printf 'agent_identity=%s\n' "$identity"
    printf 'endpoint_pid=3\n'
    printf 'endpoint_identity=%s\n' "$identity"
    printf 'pgid=%s\n' "$pid"
    [ -z "$boot_gen" ] || printf 'boot_generation=%s\n' "$boot_gen"
  } > "$dir/home/state/$id.process-scope"
}

prepare_dead_relaunch() {
  local dir=$1 id=$2
  printf 'zsh' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  printf '%s' "$dir/wt" > "$dir/fake/cwd"
}

assert_scope_empty() {
  local path=$1 id=$2
  grep -qx 'status=empty' "$path" || fail "process scope was not retired to empty"
  grep -qx "token=test-$id" "$path" || fail "empty process scope lost its token"
  grep -qx 'endpoint_pid=3' "$path" || fail "empty process scope lost its endpoint binding"
  grep -q '^anchor_pid=' "$path" && fail "empty process scope retained an active anchor"
}

# --- 1. same-harness relaunch -----------------------------------------------

test_same_harness_relaunch_keeps_identity_and_reuses_the_endpoint() {
  local dir out rc gen_before gen_after
  dir=$(new_case same rl1)
  add_ship_task "$dir" rl1 claude
  gen_before=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" rl1)
  printf 'busy_gen=%s\n' "$gen_before" >> "$dir/home/state/rl1.meta"
  out=$(run_control "$dir" rl1 relaunch --note "stopped mid-refactor"); rc=$?
  expect_code 0 "$rc" "a same-harness relaunch should succeed"$'\n'"$out"
  assert_contains "$out" "relaunched rl1 harness=claude from=claude" "the outcome should name the transition"
  [ "$(meta_field "$dir" rl1 window)" = "fmses:fm-rl1" ] \
    || fail "the endpoint must be reused, not recreated"
  [ "$(meta_field "$dir" rl1 worktree)" = "$dir/wt" ] \
    || fail "the worktree must be reused, not reallocated"
  [ "$(meta_field "$dir" rl1 kind)" = ship ] || fail "kind must survive the relaunch"
  [ "$(meta_field "$dir" rl1 project)" = "$dir/proj" ] || fail "project must survive the relaunch"
  gen_after=$(meta_field "$dir" rl1 busy_gen)
  [ -n "$gen_after" ] && [ "$gen_after" != "$gen_before" ] \
    || fail "a relaunch must arm a fresh busy generation, got '$gen_after'"
  [ "$(journal_field "$dir" rl1 phase)" = complete ] \
    || fail "the transaction journal should end complete"
  assert_grep "/exit" "$dir/fake/literal" "the previous agent should have been exited"
  assert_grep "encode launch-brief" "$dir/fake/literal" "the replacement should have been launched"
  pass "fm-control relaunch: a same-harness relaunch replaces the agent in the same endpoint and worktree"
}

test_relaunch_preserves_durable_task_metadata() {
  local dir out rc
  dir=$(new_case durable-meta rl19)
  add_ship_task "$dir" rl19 claude
  {
    printf '%s\n' 'pr=https://github.com/example/repo/pull/19'
    printf '%s\n' 'pr_head=feature/relaunch'
    printf '%s\n' 'x_request=request-19'
    printf '%s\n' 'decisions_reviewed=1'
  } >> "$dir/home/state/rl19.meta"

  out=$(run_control "$dir" rl19 relaunch --note "continuing review work"); rc=$?
  expect_code 0 "$rc" "relaunch should preserve durable metadata"$'\n'"$out"
  [ "$(meta_field "$dir" rl19 pr)" = "https://github.com/example/repo/pull/19" ] \
    || fail "the task PR must survive relaunch"
  [ "$(meta_field "$dir" rl19 pr_head)" = "feature/relaunch" ] \
    || fail "the task PR head must survive relaunch"
  [ "$(meta_field "$dir" rl19 x_request)" = "request-19" ] \
    || fail "the task X request must survive relaunch"
  [ "$(meta_field "$dir" rl19 decisions_reviewed)" = 1 ] \
    || fail "the task decision state must survive relaunch"
  pass "fm-control relaunch: durable task metadata survives replacement launch publication"
}

test_relaunch_serializes_concurrent_durable_metadata_publication() {
  local dir control_pid link_pid rc i=0 traceparent prepare ready exported release
  dir=$(new_case metadata-race rl28)
  add_ship_task "$dir" rl28 claude
  printf '%s\n' "$$" > "$dir/home/state/.lock"
  printf '%s on\n' "$$" > "$dir/home/state/.trace-context-effective"
  make_mv_failure_stub "$dir"
  prepare="$dir/trace-prepare"
  ready="$dir/meta-writer-ready"
  exported="$dir/trace-exported"
  release="$dir/meta-writer-release"
  FM_REAL_MV=$(command -v mv) \
    FM_FAKE_TRACE_PREPARE="$prepare" \
    FM_FAKE_META_WRITER_READY="$ready" \
    FM_FAKE_TRACE_EXPORTED="$exported" \
    run_control "$dir" rl28 relaunch --note "continue after publication" > "$dir/control.out" &
  control_pid=$!
  while [ ! -e "$prepare" ] && [ "$i" -lt 200 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$prepare" ] || {
    kill "$control_pid" 2>/dev/null || true
    wait "$control_pid" 2>/dev/null || true
    fail "relaunch did not reach trace delivery"
  }
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_REAL_MV="$(command -v mv)" \
    FM_FAKE_META_WRITER_TARGET="$dir/home/state/rl28.meta" \
    FM_FAKE_META_WRITER_READY="$ready" \
    FM_FAKE_META_WRITER_RELEASE="$release" \
    "$X_LINK" rl28 request-28 --carry-count 1 --carry-ts 1700000000 \
      --carry-platform x --carry-max 280 > "$dir/link.out" 2>&1 &
  link_pid=$!
  i=0
  while { [ ! -e "$ready" ] || [ ! -e "$exported" ]; } && [ "$i" -lt 200 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$ready" ] && [ -e "$exported" ] || {
    : > "$release"
    kill "$link_pid" "$control_pid" 2>/dev/null || true
    wait "$link_pid" 2>/dev/null || true
    wait "$control_pid" 2>/dev/null || true
    fail "trace publication did not overlap the concurrent metadata writer"
  }
  : > "$release"
  wait "$link_pid"; rc=$?
  expect_code 0 "$rc" "concurrent X metadata publication should serialize"$'\n'"$(cat "$dir/link.out")"
  wait "$control_pid"; rc=$?
  expect_code 0 "$rc" "relaunch should complete after serialized metadata publication"$'\n'"$(cat "$dir/control.out")"
  [ "$(meta_field "$dir" rl28 x_request)" = request-28 ] \
    || fail "relaunch erased metadata published concurrently through the X interface"
  [ "$(meta_field "$dir" rl28 x_followups)" = 1 ] \
    || fail "relaunch erased the concurrent follow-up count"
  traceparent=$(meta_field "$dir" rl28 traceparent)
  fm_trace_context_valid "$traceparent" \
    || fail "concurrent metadata publication erased the replacement's trace carrier"
  pass "fm-control relaunch: trace and concurrent task metadata publications serialize"
}

test_disabled_relaunch_clears_prior_trace_context() {
  local dir out rc
  dir=$(new_case trace-off rl33)
  add_ship_task "$dir" rl33 claude
  printf '%s\n' 'traceparent=00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01' \
    >> "$dir/home/state/rl33.meta"
  printf '%s\n' "$$" > "$dir/home/state/.lock"
  printf '%s off\n' "$$" > "$dir/home/state/.trace-context-effective"

  out=$(run_control "$dir" rl33 relaunch --note "crossing trace boundary"); rc=$?
  expect_code 0 "$rc" "disabled relaunch should succeed"$'\n'"$out"
  [ -z "$(meta_field "$dir" rl33 traceparent)" ] \
    || fail "disabled relaunch must remove the prior trace carrier from metadata"
  grep -q '^unset TRACEPARENT; .*claude' "$dir/fake/literal" \
    || fail "disabled relaunch must clear the pane carrier before replacement launch"
  ! grep -q '^export TRACEPARENT=' "$dir/fake/literal" \
    || fail "disabled relaunch must not export a replacement trace carrier"
  pass "fm-control relaunch: disabling tracing clears metadata and pane context"
}

test_relaunch_appends_the_progress_note_to_the_instructions() {
  local dir out rc brief
  dir=$(new_case note rl2)
  add_ship_task "$dir" rl2 claude
  out=$(run_control "$dir" rl2 relaunch --note "reproduced the crash in parser.go"); rc=$?
  expect_code 0 "$rc" "relaunch should succeed"$'\n'"$out"
  brief="$dir/home/data/rl2/brief.md"
  assert_grep "Do the thing." "$brief" "the original instructions must survive"
  assert_grep "## Progress note" "$brief" "the note should be a dated section in the instructions"
  assert_grep "reproduced the crash in parser.go" "$brief" "the note text should reach the replacement"
  assert_grep "reproduced the crash in parser.go" "$dir/home/state/rl2.control-relaunch.note" \
    "the note should also be preserved beside the transaction record"
  pass "fm-control relaunch: the progress note lands in the instructions the replacement reads"
}

test_relaunch_requires_a_note_for_a_ship_task() {
  local dir out rc before
  dir=$(new_case nonote rl3)
  add_ship_task "$dir" rl3 claude
  before=$(cat "$dir/home/data/rl3/brief.md")
  out=$(run_control "$dir" rl3 relaunch); rc=$?
  expect_code 1 "$rc" "a ship relaunch without a note should refuse"
  assert_contains "$out" "requires --note" "the refusal should name the missing note"
  [ "$(cat "$dir/home/data/rl3/brief.md")" = "$before" ] \
    || fail "a refused relaunch must not touch the instructions"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "a refused relaunch must send nothing"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch must not stop the agent"
  pass "fm-control relaunch: a ship task refuses without the progress note its replacement needs"
}

# --- 2. harness switch -------------------------------------------------------

test_harness_switch_moves_the_record_and_clears_prior_wiring() {
  local dir out rc
  dir=$(new_case switch rl4)
  add_ship_task "$dir" rl4 claude
  # Wiring the previous claude incarnation left in the worktree.
  mkdir -p "$dir/wt/.claude"
  printf '{"hooks":{}}\n' > "$dir/wt/.claude/settings.local.json"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" rl4 relaunch --harness codex --note "switching runtime"); rc=$?
  expect_code 0 "$rc" "a harness switch should succeed"$'\n'"$out"
  assert_contains "$out" "harness=codex from=claude" "the outcome should name both harnesses"
  [ "$(meta_field "$dir" rl4 harness)" = codex ] || fail "the record should follow the switch"
  [ ! -e "$dir/wt/.claude/settings.local.json" ] \
    || fail "the previous harness's per-task wiring must be cleared on a switch"
  assert_grep "codex" "$dir/fake/literal" "the replacement launch should be the new harness"
  [ "$(journal_field "$dir" rl4 from_harness)" = claude ] || fail "the journal should record the origin harness"
  [ "$(journal_field "$dir" rl4 to_harness)" = codex ] || fail "the journal should record the target harness"
  pass "fm-control relaunch: switching harness is one ordinary relaunch, and the old wiring goes with the old agent"
}

test_agy_harness_switch_removes_the_plugin_directory() {
  local dir plugin out rc
  dir=$(new_case agy-switch rl36)
  add_ship_task "$dir" rl36 agy
  printf 'agy' > "$dir/fake/command"
  plugin="$dir/wt/.agents/plugins/fm-firstmate-busy-rl36"
  mkdir -p "$plugin"
  printf '%s\n' '{"name":"fm-firstmate-busy-rl36"}' > "$plugin/plugin.json"
  printf '%s\n' '{"fm-firstmate-busy":{}}' > "$plugin/hooks.json"
  printf 'claude' > "$dir/fake/becomes"
  out=$(run_control "$dir" rl36 relaunch --harness claude --note "switching runtime"); rc=$?
  expect_code 0 "$rc" "switching away from agy should succeed"$'\n'"$out"
  [ ! -e "$plugin" ] || fail "switching away from agy left its plugin directory behind"
  pass "fm-control relaunch: agy plugin wiring retires with its agent"
}

test_scoped_harness_switch_to_agy() {
  local dir plugin out rc
  dir=$(new_case agy-target rl38)
  add_ship_task "$dir" rl38 claude
  printf 'agy' > "$dir/fake/becomes"
  out=$(run_control "$dir" rl38 relaunch --harness agy --note "switching runtime"); rc=$?
  expect_code 0 "$rc" "a scoped worker should relaunch onto agy"$'\n'"$out"
  plugin="$dir/wt/.agents/plugins/fm-firstmate-busy-rl38"
  [ -d "$plugin" ] || fail "scoped relaunch onto agy did not install its plugin"
  [ "$(meta_field "$dir" rl38 harness)" = agy ] \
    || fail "scoped relaunch onto agy did not publish the replacement harness"
  pass "fm-control relaunch: scoped workers can transition safely onto agy"
}

test_unscoped_harness_switch_to_agy_refuses_before_exit() {
  local dir out rc
  dir=$(new_case unscoped-agy-target rl39)
  add_ship_task "$dir" rl39 claude
  awk -F= '$1 != "process_scope_token"' "$dir/home/state/rl39.meta" \
    > "$dir/home/state/rl39.meta.tmp"
  mv "$dir/home/state/rl39.meta.tmp" "$dir/home/state/rl39.meta"
  rm -f "$dir/home/state/rl39.process-scope"
  printf 'agy' > "$dir/fake/becomes"
  out=$(run_control "$dir" rl39 relaunch --harness agy --note "switching runtime"); rc=$?
  expect_code 1 "$rc" "an unscoped prior worker must not transition onto agy"
  assert_contains "$out" "predates durable worker process scopes" \
    "unscoped agy transition refusal did not name the missing ownership proof"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "unscoped agy transition stopped the current agent before refusing"
  [ ! -e "$dir/wt/.agents/plugins/fm-firstmate-busy-rl39" ] \
    || fail "unscoped agy transition wrote plugin wiring before refusing"
  pass "fm-control relaunch: unscoped agy transitions fail before mutation"
}

test_portable_scope_harness_switch_to_agy_refuses_before_exit() {
  local dir out rc
  dir=$(new_case portable-agy-target rl40)
  add_ship_task "$dir" rl40 claude
  sed 's/^containment=pid-namespace$/containment=process-group/' \
    "$dir/home/state/rl40.process-scope" > "$dir/home/state/rl40.process-scope.tmp"
  mv "$dir/home/state/rl40.process-scope.tmp" "$dir/home/state/rl40.process-scope"
  printf 'agy' > "$dir/fake/becomes"
  out=$(run_control "$dir" rl40 relaunch --harness agy --note "switching runtime"); rc=$?
  expect_code 1 "$rc" "a portable prior worker must not enter an agy worktree transition"
  assert_contains "$out" "lacks PID namespace containment" \
    "portable agy transition refusal did not name the missing containment proof"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "portable agy transition stopped the current agent before refusing"
  [ ! -e "$dir/wt/.agents/plugins/fm-firstmate-busy-rl40" ] \
    || fail "portable agy transition wrote plugin wiring before refusing"
  pass "fm-control relaunch: portable agy transitions fail before mutation"
}

test_agy_relaunch_reaps_the_prior_process_scope() {
  local dir plugin out rc pid pgid attempts=0 token=test-rl37
  dir=$(new_case agy-scope rl37)
  add_ship_task "$dir" rl37 agy
  printf 'agy' > "$dir/fake/command"
  plugin="$dir/wt/.agents/plugins/fm-firstmate-busy-rl37"
  mkdir -p "$plugin"
  printf '%s\n' '{"name":"fm-firstmate-busy"}' > "$plugin/plugin.json"
  printf '%s\n' '{"fm-firstmate-busy":{}}' > "$plugin/hooks.json"
  FM_TASK_PROCESS_SCOPE_TOKEN="$token" python3 - <<'PY' &
import os

os.setpgrp()
os.chdir("/tmp")
os.execv("/bin/sleep", ["sleep", "300"])
PY
  pid=$!
  while [ "$attempts" -lt 50 ]; do
    pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    [ "$pgid" = "$pid" ] && break
    /bin/sleep 0.02
    attempts=$((attempts + 1))
  done
  [ "$pgid" = "$pid" ] || fail "agy relaunch scope fixture did not enter its own process group"
  {
    printf 'version=1\n'
    printf 'status=active\n'
    printf 'token=%s\n' "$token"
    printf 'containment=pid-namespace\n'
    printf 'leader_pid=%s\n' "$pid"
    printf 'leader_identity=%s\n' "$(fm_task_process_identity "$pid")"
    printf 'pgid=%s\n' "$pid"
  } > "$dir/home/state/rl37.process-scope"
  printf 'claude' > "$dir/fake/becomes"

  out=$(run_control "$dir" rl37 relaunch --harness claude --note "switching runtime"); rc=$?
  if [ "$rc" -ne 0 ]; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
  expect_code 0 "$rc" "switching away from agy should reap its process scope"$'\n'"$out"
  wait "$pid" 2>/dev/null || true
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "agy relaunch left a detached task process alive"
  fi
  [ ! -e "$plugin" ] || fail "agy relaunch did not retire wiring after quiescence"
  [ -e "$dir/home/state/rl37.process-scope" ] \
    || fail "agy relaunch did not retain the scope for its verified replacement worker"
  pass "fm-control relaunch: agy process scope is empty before replacement transition"
}

test_harness_switch_does_not_carry_the_old_profile_axes() {
  local dir out rc
  dir=$(new_case profile rl5)
  add_ship_task "$dir" rl5 claude
  sed 's/^model=default$/model=opus/; s/^effort=default$/effort=xhigh/' \
    "$dir/home/state/rl5.meta" > "$dir/home/state/rl5.meta.tmp"
  mv "$dir/home/state/rl5.meta.tmp" "$dir/home/state/rl5.meta"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" rl5 relaunch --harness codex --note "switching runtime"); rc=$?
  expect_code 0 "$rc" "a harness switch should succeed"$'\n'"$out"
  [ "$(meta_field "$dir" rl5 model)" = default ] \
    || fail "a model chosen for the old harness must not carry to a different one"
  [ "$(meta_field "$dir" rl5 effort)" = default ] \
    || fail "an effort chosen for the old harness must not carry to a different one"
  pass "fm-control relaunch: a harness switch resets model and effort unless they are named too"
}

test_harness_switch_resolves_a_prefixed_recorded_harness() {
  local dir out rc auth
  dir=$(new_case prefixcontrol rl32)
  add_ship_task "$dir" rl32 grok-2
  printf 'grok-2' > "$dir/fake/command"
  mkdir -p "$dir/grokhome/hooks/fm-turn-end.d"
  printf 'fm.abcdefabcdef\n' > "$dir/home/state/rl32.grok-turnend-token"
  auth="$dir/grokhome/hooks/fm-turn-end.d/fm.abcdefabcdef"
  printf '%s\n' "$dir/home/state/rl32.turn-ended" > "$auth"
  printf 'token=fm.abcdefabcdef\n' > "$dir/wt/.fm-grok-turnend"

  out=$(run_control "$dir" rl32 relaunch --harness claude --note "switching runtime"); rc=$?
  expect_code 0 "$rc" "relaunch should resolve a prefixed recorded harness"$'\n'"$out"
  [ "$(sed -n '1p' "$dir/fake/literal")" = /exit ] \
    || fail "relaunch should stop a grok-prefixed task with grok's exit command"
  [ "$(meta_field "$dir" rl32 harness)" = claude ] \
    || fail "relaunch should publish the explicitly selected replacement harness"
  [ "$(journal_field "$dir" rl32 from_harness)" = grok-2 ] \
    || fail "relaunch should retain the recorded harness basename in its provenance"
  assert_contains "$out" "harness=claude from=grok-2" \
    "relaunch should report the recorded-to-selected harness transition"
  [ ! -e "$auth" ] && [ ! -e "$dir/home/state/rl32.grok-turnend-token" ] \
    && [ ! -e "$dir/wt/.fm-grok-turnend" ] \
    || fail "relaunch should retire wiring owned by the prefixed prior harness"
  pass "fm-control relaunch: a prefixed recorded harness can switch adapters transactionally"
}

test_prefixed_recorded_harness_requires_explicit_replacement() {
  local dir out rc meta brief
  dir=$(new_case prefixrefuse rl34)
  add_ship_task "$dir" rl34 grok-2
  printf 'grok-2' > "$dir/fake/command"
  meta="$dir/home/state/rl34.meta"
  brief="$dir/home/data/rl34/brief.md"
  cp "$meta" "$dir/meta.before"
  cp "$brief" "$dir/brief.before"

  out=$(run_control "$dir" rl34 relaunch --note "continue safely"); rc=$?
  expect_code 1 "$rc" "implicit relaunch from a prefixed command should refuse"
  assert_contains "$out" "original launch command cannot be reconstructed from its recorded basename" \
    "the refusal should name the missing launch identity"
  assert_contains "$out" "would substitute the canonical adapter 'grok'" \
    "the refusal should name the unsafe substitution"
  assert_contains "$out" "Pass an explicit --harness" \
    "the refusal should name the deliberate replacement path"
  cmp -s "$meta" "$dir/meta.before" \
    || fail "a refused prefixed relaunch must leave metadata byte-identical"
  cmp -s "$brief" "$dir/brief.before" \
    || fail "a refused prefixed relaunch must leave instructions byte-identical"
  [ "$(cat "$dir/fake/command")" = grok-2 ] \
    || fail "a refused prefixed relaunch must leave the original agent alive"
  [ -z "$(cat "$dir/fake/literal")" ] && [ -z "$(cat "$dir/fake/keys")" ] \
    || fail "a refused prefixed relaunch must deliver no lifecycle input"
  [ ! -e "$dir/home/state/rl34.control-relaunch" ] \
    || fail "a refused prefixed relaunch must not create a durable journal"
  pass "fm-control relaunch: a prefixed command requires an explicit replacement harness"
}

test_same_harness_relaunch_keeps_the_profile_axes() {
  local dir out rc
  dir=$(new_case keepprofile rl6)
  add_ship_task "$dir" rl6 claude
  sed 's/^model=default$/model=opus/; s/^effort=default$/effort=high/' \
    "$dir/home/state/rl6.meta" > "$dir/home/state/rl6.meta.tmp"
  mv "$dir/home/state/rl6.meta.tmp" "$dir/home/state/rl6.meta"
  out=$(run_control "$dir" rl6 relaunch --note "same runtime"); rc=$?
  expect_code 0 "$rc" "a same-harness relaunch should succeed"$'\n'"$out"
  [ "$(meta_field "$dir" rl6 model)" = opus ] || fail "the model should carry across a same-harness relaunch"
  [ "$(meta_field "$dir" rl6 effort)" = high ] || fail "the effort should carry across a same-harness relaunch"
  pass "fm-control relaunch: a same-harness relaunch keeps the profile axes it was running with"
}

test_explicit_model_wins_over_the_recorded_one() {
  local dir out rc
  dir=$(new_case explicit rl7)
  add_ship_task "$dir" rl7 claude
  out=$(run_control "$dir" rl7 relaunch --model sonnet --effort low --note "dialling down"); rc=$?
  expect_code 0 "$rc" "relaunch with explicit axes should succeed"$'\n'"$out"
  [ "$(meta_field "$dir" rl7 model)" = sonnet ] || fail "an explicit model should be recorded"
  [ "$(meta_field "$dir" rl7 effort)" = low ] || fail "an explicit effort should be recorded"
  pass "fm-control relaunch: explicit model and effort win over the recorded ones"
}

test_relaunch_onto_an_unverified_harness_is_refused() {
  local dir out rc
  dir=$(new_case badharness rl8)
  add_ship_task "$dir" rl8 claude
  out=$(run_control "$dir" rl8 relaunch --harness someagent --note "x"); rc=$?
  expect_code 1 "$rc" "an unverified target harness should refuse"
  assert_contains "$out" "not a verified harness" "the refusal should name the unverified adapter"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch must not stop the agent"
  pass "fm-control relaunch: refuses to relaunch onto an adapter with no verified mechanics"
}

test_prior_harness_turnend_registry_entry_is_cleared() {
  local dir auth
  dir=$(new_case grokauth rl9)
  add_ship_task "$dir" rl9 grok
  mkdir -p "$dir/grokhome/hooks/fm-turn-end.d"
  printf 'fm.abcdefabcdef\n' > "$dir/home/state/rl9.grok-turnend-token"
  auth="$dir/grokhome/hooks/fm-turn-end.d/fm.abcdefabcdef"
  printf '%s\n' "$dir/home/state/rl9.turn-ended" > "$auth"
  printf 'grok' > "$dir/fake/command"
  printf 'grok' > "$dir/fake/becomes"
  run_control "$dir" rl9 relaunch --note "restart on the same runtime" >/dev/null
  [ ! -e "$auth" ] \
    || fail "the previous incarnation's turn-end registry entry must not outlive it"
  pass "fm-control relaunch: the retired incarnation's global turn-end token is revoked"
}

test_wiring_removal_failure_refuses_before_replacement_arm() {
  local dir hook out rc real_rm
  dir=$(new_case wiring-failure rl29)
  add_ship_task "$dir" rl29 claude
  hook="$dir/wt/.claude/settings.local.json"
  mkdir -p "${hook%/*}"
  printf '{}\n' > "$hook"
  real_rm=$(command -v rm)
  make_rm_failure_stub "$dir"
  out=$(FM_REAL_RM="$real_rm" FM_FAKE_RM_FAIL_PATH="$hook" \
    run_control "$dir" rl29 relaunch --note "retry after wiring cleanup"); rc=$?
  expect_code 1 "$rc" "an undeletable prior hook must fail closed"$'\n'"$out"
  assert_contains "$out" "could not retire claude wiring" \
    "the failure should identify prior wiring cleanup"
  [ -e "$hook" ] || fail "the fixture should retain the undeletable prior hook"
  assert_no_grep "encode launch-brief" "$dir/fake/literal" \
    "replacement launch must not be armed after wiring cleanup fails"
  [ "$(journal_field "$dir" rl29 phase)" = failed:launching ] \
    || fail "the transaction should record the partial launch failure"
  [ "$(journal_field "$dir" rl29 rollback)" = prior-record-kept ] \
    || fail "unpublished rollback should retain the live durable record"
  pass "fm-control relaunch: wiring cleanup failure refuses replacement arming"
}

test_turnend_auth_paths_are_owned_by_the_control_adapter() {
  local dir state grok_path kimi_path token_path
  dir=$(fm_test_tmproot fm-control-auth)
  state="$dir/state"
  mkdir -p "$state"
  printf 'fm.111111111111\n' > "$state/x.grok-turnend-token"
  printf 'fm.222222222222\n' > "$state/x.kimi-turnend-token"
  token_path=$(fm_control_harness_turnend_token_path grok "$state" x)
  [ "$token_path" = "$state/x.grok-turnend-token" ] \
    || fail "the grok token path should be computed without reading it"
  grok_path=$(GROK_HOME="$dir/gh" fm_control_harness_turnend_auth_path grok fm.111111111111)
  [ "$grok_path" = "$dir/gh/hooks/fm-turn-end.d/fm.111111111111" ] \
    || fail "grok's registry path should resolve under GROK_HOME, got '$grok_path'"
  kimi_path=$(HOME="$dir/kh" fm_control_harness_turnend_auth_path kimi fm.222222222222)
  [ "$kimi_path" = "$dir/kh/.kimi-code/fm-turn-end.d/fm.222222222222" ] \
    || fail "kimi's registry path should resolve under the home store, got '$kimi_path'"
  grok_path=$(GROK_HOME="$dir/gh" fm_control_harness_turnend_auth_path grok 'not a token/../..')
  [ -z "$grok_path" ] || fail "a malformed token must resolve to no path, got '$grok_path'"
  pass "fm-control-lib: one owner resolves each harness's turn-end registry entry, and refuses a malformed token"
}

test_secondmate_relaunch_picks_up_the_configured_harness_pin() {
  local dir home out rc
  dir=$(new_case smpin sm3)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'codex some-model high\n' > "$home/config/secondmate-harness"
  mkdir -p "$home/data/sm3"
  printf '# secondmate brief\n' > "$home/data/sm3/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm3\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-sm3"
    echo "endpoint_task_id=sm3"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/sm3.meta"
  printf '%s\n' "fm-sm3" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" sm3 relaunch); rc=$?
  expect_code 0 "$rc" "a configured secondmate harness should relaunch"$'\n'"$out"
  [ "$(journal_field "$dir" sm3 to_harness)" = codex ] \
    || fail "a secondmate relaunch should pick up the configured harness pin, got '$(journal_field "$dir" sm3 to_harness)'"
  [ "$(journal_field "$dir" sm3 to_model)" = some-model ] \
    || fail "the configured model token should come with the pin"
  [ "$(journal_field "$dir" sm3 to_effort)" = high ] \
    || fail "the configured effort token should come with the pin"
  assert_not_contains "$out" "not a verified harness" "codex is a verified harness"
  pass "fm-control relaunch: a secondmate relaunch re-resolves its durable configured harness pin"
}

test_secondmate_relaunch_ignores_invalid_configured_effort_before_stop() {
  local dir home out rc
  dir=$(new_case invalid-effort sm6)
  home="$dir/home"
  mkdir -p "$home/config" "$home/data/sm6"
  printf 'codex some-model impossible\n' > "$home/config/secondmate-harness"
  printf '# secondmate brief\n' > "$home/data/sm6/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm6\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-sm6"
    echo "endpoint_task_id=sm6"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/sm6.meta"
  printf '%s\n' "fm-sm6" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" sm6 relaunch); rc=$?
  expect_code 0 "$rc" "an invalid configured effort should be ignored before stop"$'\n'"$out"
  assert_contains "$out" "effort token 'impossible'" \
    "relaunch should surface the same warning as a normal secondmate spawn"
  [ "$(journal_field "$dir" sm6 to_effort)" = default ] \
    || fail "invalid configured effort should normalize to default"
  pass "fm-control relaunch: invalid configured effort is ignored before stop"
}

# muse is a verified adapter, but only for crewmates and scouts: it has no
# primary supervision protocol, so bin/fm-spawn.sh refuses it for a secondmate.
# That refusal alone is not enough here, because the launch owner is reached
# only AFTER the running agent has been stopped - a secondmate would be left
# with no agent at all. The control plane asks the same capability question
# before it touches anything, so the refusal lands while the agent is still up.
test_secondmate_relaunch_onto_a_crewmate_only_adapter_refuses_before_stop() {
  local dir home out rc
  dir=$(new_case smkind sm7)
  home="$dir/home"
  mkdir -p "$home/config" "$home/data/sm7"
  printf '# secondmate brief\n' > "$home/data/sm7/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm7\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-sm7"
    echo "endpoint_task_id=sm7"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/sm7.meta"
  printf '%s\n' "fm-sm7" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  out=$(run_control "$dir" sm7 relaunch --harness muse); rc=$?
  expect_code 1 "$rc" "a crewmate-only adapter should refuse a secondmate relaunch"
  assert_contains "$out" "not verified to run a secondmate task" \
    "the refusal should name the kind the adapter cannot run"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "the refusal must land before the running agent is stopped"
  [ "$(meta_field "$dir" sm7 harness)" = claude ] \
    || fail "a refused relaunch must leave the durable record on the recorded harness"
  pass "fm-control relaunch: an adapter unverified for this task kind refuses before the agent is stopped"
}

test_explicit_secondmate_harness_ignores_configured_profile_axes() {
  local dir home out rc
  dir=$(new_case smexplicit sm4)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'claude opus high\n' > "$home/config/secondmate-harness"
  mkdir -p "$home/data/sm4"
  printf '# secondmate brief\n' > "$home/data/sm4/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm4\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-sm4"
    echo "endpoint_task_id=sm4"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=opus"
    echo "effort=high"
    echo "home=$dir/smhome"
  } > "$home/state/sm4.meta"
  printf '%s\n' "fm-sm4" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" sm4 relaunch --harness codex); rc=$?
  expect_code 0 "$rc" "an explicit secondmate harness should relaunch"$'\n'"$out"
  [ "$(meta_field "$dir" sm4 model)" = default ] \
    || fail "an explicit secondmate harness must not inherit the configured model"
  [ "$(meta_field "$dir" sm4 effort)" = default ] \
    || fail "an explicit secondmate harness must not inherit the configured effort"
  pass "fm-control relaunch: explicit secondmate harness resets unnamed profile axes"
}

test_ship_relaunch_ignores_the_crew_harness_config() {
  local dir out
  dir=$(new_case crewcfg rl20)
  add_ship_task "$dir" rl20 claude
  mkdir -p "$dir/home/config"
  printf 'codex\n' > "$dir/home/config/crew-harness"
  out=$(run_control "$dir" rl20 relaunch --note "same worker, same runtime")
  assert_contains "$out" "harness=claude from=claude" \
    "a ship relaunch must keep its recorded harness rather than re-reading crew config"
  [ "$(meta_field "$dir" rl20 harness)" = claude ] \
    || fail "a ship relaunch must not silently move onto the configured crew harness"
  pass "fm-control relaunch: a ship task keeps its recorded harness instead of re-reading crew config"
}

test_spawn_relaunch_without_a_harness_reuses_the_recorded_one() {
  local dir out
  dir=$(new_case spawnharness rl21)
  add_ship_task "$dir" rl21 claude
  mkdir -p "$dir/home/config"
  printf 'codex\n' > "$dir/home/config/crew-harness"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl21 --relaunch)
  [ "$(meta_field "$dir" rl21 harness)" = claude ] \
    || fail "fm-spawn --relaunch without --harness must reuse the recorded harness, got '$(meta_field "$dir" rl21 harness)'"
  assert_contains "$out" "spawned rl21 harness=claude" "the launch should report the recorded harness"
  pass "fm-spawn --relaunch: with no explicit harness it reuses the task's recorded one, never the crew default"
}

# fm-spawn arms per-task wiring on harness PREFIXES, because a raw command with
# no declared --raw-harness identity records its command basename rather than
# the exact adapter name. Retirement must resolve the same way, or a task recorded as
# `grok-2` would have its turn-end token and hook pointer armed and never
# retired - leaving a registry entry that outlives the agent that owned it.
test_prefixed_prior_harness_wiring_is_still_retired() {
  local dir auth
  dir=$(new_case prefixwiring rl30)
  add_ship_task "$dir" rl30 grok-2
  mkdir -p "$dir/grokhome/hooks/fm-turn-end.d"
  printf 'fm.abcdefabcdef\n' > "$dir/home/state/rl30.grok-turnend-token"
  auth="$dir/grokhome/hooks/fm-turn-end.d/fm.abcdefabcdef"
  printf '%s\n' "$dir/home/state/rl30.turn-ended" > "$auth"
  printf 'token=fm.abcdefabcdef\n' > "$dir/wt/.fm-grok-turnend"
  printf 'zsh' > "$dir/fake/command"
  run_spawn "$dir" rl30 --relaunch --harness claude >/dev/null
  [ ! -e "$auth" ] \
    || fail "a prefixed prior harness must still have its turn-end registry entry revoked"
  [ ! -e "$dir/home/state/rl30.grok-turnend-token" ] \
    || fail "a prefixed prior harness must still have its private token retired"
  [ ! -e "$dir/wt/.fm-grok-turnend" ] \
    || fail "a prefixed prior harness must still have its worktree hook pointer removed"
  pass "fm-spawn --relaunch: wiring armed under a prefixed harness name is still retired"
}

# muse installs no hook; its busy source is its own session event log, bound to
# the pane by two firstmate-owned sidecars. Relaunching AWAY from muse must
# retire that binding, or a retired incarnation's session pin outlives the agent
# that produced it.
test_muse_session_binding_is_retired_on_a_harness_switch() {
  local dir
  dir=$(new_case musewiring rl31)
  add_ship_task "$dir" rl31 muse
  printf 'sessions_root=/nonexistent\nworkspace_root=%s\nbinding_id=1.2.3\n' "$dir/wt" \
    > "$dir/home/state/rl31.muse-session"
  printf '/nonexistent/session.jsonl\n' > "$dir/home/state/rl31.muse-session-current"
  printf 'zsh' > "$dir/fake/command"
  run_spawn "$dir" rl31 --relaunch --harness claude >/dev/null
  [ ! -e "$dir/home/state/rl31.muse-session" ] \
    || fail "the retired muse incarnation's session binding must not outlive it"
  [ ! -e "$dir/home/state/rl31.muse-session-current" ] \
    || fail "the retired muse incarnation's resolved session pin must not outlive it"
  pass "fm-spawn --relaunch: switching away from muse retires its session binding"
}

test_cursor_session_binding_is_retired_on_a_harness_switch() {
  local dir
  dir=$(new_case cursorwiring rl35)
  add_ship_task "$dir" rl35 cursor
  printf 'workspace=%s\nprior_conversation=old-conversation\n' "$dir/wt" \
    > "$dir/home/state/rl35.cursor-session"
  printf 'zsh' > "$dir/fake/command"
  run_spawn "$dir" rl35 --relaunch --harness claude >/dev/null
  [ ! -e "$dir/home/state/rl35.cursor-session" ] \
    || fail "the retired cursor incarnation's session binding must not outlive it"
  pass "fm-spawn --relaunch: switching away from cursor retires its session binding"
}

# --- 3 and 4. refusals before the agent is touched ---------------------------

test_missing_worktree_refuses_before_stopping_anything() {
  local dir out rc
  dir=$(new_case nowt rl10)
  add_ship_task "$dir" rl10 claude
  rm -rf "$dir/wt"
  out=$(run_control "$dir" rl10 relaunch --note "x"); rc=$?
  expect_code 1 "$rc" "a missing worktree should refuse"
  assert_contains "$out" "recorded worktree" "the refusal should name the missing local copy"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch must not stop the agent"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "a refused relaunch must send nothing"
  pass "fm-control relaunch: an unaccountable local copy refuses before the agent is touched"
}

test_missing_instructions_refuse_before_stopping_anything() {
  local dir out rc
  dir=$(new_case nobrief rl11)
  add_ship_task "$dir" rl11 claude
  rm -f "$dir/home/data/rl11/brief.md"
  out=$(run_control "$dir" rl11 relaunch --note "x"); rc=$?
  expect_code 1 "$rc" "missing instructions should refuse"
  assert_contains "$out" "no instructions" "the refusal should name the missing instructions"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch must not stop the agent"
  pass "fm-control relaunch: a worker with nothing to work from is never launched"
}

test_checkpoint_refusal_leaves_the_record_byte_identical() {
  local dir before after
  dir=$(new_case bytes rl12)
  add_ship_task "$dir" rl12 claude
  before=$(cat "$dir/home/state/rl12.meta")
  rm -rf "$dir/wt/.git"
  run_control "$dir" rl12 relaunch --note "x" >/dev/null 2>&1
  after=$(cat "$dir/home/state/rl12.meta")
  [ "$before" = "$after" ] || fail "a refused relaunch must leave the durable record byte-identical"
  pass "fm-control relaunch: a refusal before the agent is stopped leaves the durable record untouched"
}

test_checkpoint_refuses_uninspectable_head_and_status() {
  local dir out rc real_git
  real_git=$(command -v git)

  dir=$(new_case badhead rl22)
  add_ship_task "$dir" rl22 claude
  make_git_failure_stub "$dir"
  out=$(FM_REAL_GIT="$real_git" FM_FAKE_GIT_FAILURE=head \
    run_control "$dir" rl22 relaunch --note "x"); rc=$?
  expect_code 1 "$rc" "an uninspectable HEAD should refuse"
  assert_contains "$out" "HEAD cannot be inspected" "the refusal should name the failed HEAD proof"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "HEAD inspection failure must not stop the agent"

  dir=$(new_case badstatus rl23)
  add_ship_task "$dir" rl23 claude
  make_git_failure_stub "$dir"
  out=$(FM_REAL_GIT="$real_git" FM_FAKE_GIT_FAILURE=status \
    run_control "$dir" rl23 relaunch --note "x"); rc=$?
  expect_code 1 "$rc" "an uninspectable worktree status should refuse"
  assert_contains "$out" "status cannot be inspected" "the refusal should name the failed dirty-state proof"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "status inspection failure must not stop the agent"
  pass "fm-control relaunch: checkpoint inspection failures refuse before stopping"
}

# --- 5. failure after the agent is stopped -----------------------------------

test_launch_failure_keeps_the_prior_record_and_reports_it() {
  local dir out rc before
  dir=$(new_case rollback rl13)
  add_ship_task "$dir" rl13 claude
  before=$(cat "$dir/home/state/rl13.meta")
  # The endpoint's shell is not in the recorded worktree, so the launch owner
  # refuses AFTER the previous agent has already been stopped.
  printf '%s' "$dir/proj" > "$dir/fake/cwd"
  out=$(run_control "$dir" rl13 relaunch --harness codex --note "carry this forward"); rc=$?
  expect_code 1 "$rc" "a failed launch should fail closed"$'\n'"$out"
  assert_contains "$out" "no agent is running" "the failure should say no agent is running"
  assert_contains "$out" "$dir/wt" "the failure should say where the work is preserved"
  [ "$(cat "$dir/home/state/rl13.meta")" = "$before" ] \
    || fail "a failed launch must keep the prior durable record"
  [ "$(journal_field "$dir" rl13 phase)" = "failed:launching" ] \
    || fail "the journal should record the failed phase, got '$(journal_field "$dir" rl13 phase)'"
  [ "$(journal_field "$dir" rl13 rollback)" = "prior-record-kept" ] \
    || fail "the journal should record what the rollback did"
  assert_grep "carry this forward" "$dir/home/data/rl13/brief.md" \
    "the progress note must survive so a later recovery still has it"
  pass "fm-control relaunch: a launch failure after the stop keeps the prior record and reports the real state"
}

test_prepublication_failure_keeps_concurrent_durable_metadata() {
  local dir control_pid link_out rc i=0
  dir=$(new_case rollback-race rl30)
  add_ship_task "$dir" rl30 claude
  printf '%s' "$dir/proj" > "$dir/fake/cwd"
  FM_FAKE_CWD_RACE_READY="$dir/cwd-race-ready" \
    run_control "$dir" rl30 relaunch --harness codex --note "preserve concurrent metadata" \
      > "$dir/control.out" &
  control_pid=$!
  while [ ! -e "$dir/cwd-race-ready" ] && [ "$i" -lt 200 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$dir/cwd-race-ready" ] || {
    kill "$control_pid" 2>/dev/null || true
    wait "$control_pid" 2>/dev/null || true
    fail "relaunch did not reach its pre-publication endpoint check"
  }
  link_out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    "$X_LINK" rl30 request-30 --carry-count 2 --carry-ts 1700000000 \
      --carry-platform x --carry-max 280 2>&1); rc=$?
  expect_code 0 "$rc" "concurrent durable metadata publication should succeed"$'\n'"$link_out"
  wait "$control_pid"; rc=$?
  expect_code 1 "$rc" "the staged pre-publication launch failure should fail closed"
  [ "$(meta_field "$dir" rl30 x_request)" = request-30 ] \
    || fail "rollback erased the concurrent X request"
  [ "$(meta_field "$dir" rl30 x_followups)" = 2 ] \
    || fail "rollback erased the concurrent follow-up count"
  [ "$(journal_field "$dir" rl30 rollback)" = prior-record-kept ] \
    || fail "pre-publication rollback should leave the live record untouched"
  pass "fm-control relaunch: unpublished rollback keeps concurrent durable metadata"
}

test_post_publication_launch_failure_keeps_the_new_record() {
  local dir out rc
  dir=$(new_case published rl24)
  add_ship_task "$dir" rl24 claude
  printf 'codex' > "$dir/fake/becomes"
  out=$(FM_FAKE_LAUNCH_TRANSPORT_FAIL_AFTER_START=1 \
    run_control "$dir" rl24 relaunch --harness codex --note "keep the published record"); rc=$?
  expect_code 1 "$rc" "a post-publication launch failure should fail closed"$'\n'"$out"
  [ "$(meta_field "$dir" rl24 harness)" = codex ] \
    || fail "a published replacement record must not be rewritten to the prior harness"
  [ -n "$(meta_field "$dir" rl24 control_relaunch_tx)" ] \
    || fail "the published replacement record should identify its relaunch transaction"
  [ "$(journal_field "$dir" rl24 rollback)" = none-new-record-kept ] \
    || fail "the journal should record that the published replacement record was kept"
  pass "fm-control relaunch: post-publication failure keeps the new durable record"
}

test_stop_transport_failure_reconciles_a_dead_agent() {
  local dir out rc
  dir=$(new_case stopfail rl25)
  add_ship_task "$dir" rl25 claude
  out=$(FM_FAKE_EXIT_TRANSPORT_FAIL_AFTER_STOP=1 \
    run_control "$dir" rl25 relaunch --note "preserve this after stop"); rc=$?
  expect_code 1 "$rc" "a stop transport failure should fail closed"$'\n'"$out"
  [ "$(cat "$dir/fake/command")" = zsh ] || fail "the fixture should stop the old agent before reporting transport failure"
  [ "$(journal_field "$dir" rl25 phase)" = failed:stopping ] \
    || fail "the journal should retain the pre-stop phase on a partial stop"
  [ "$(journal_field "$dir" rl25 rollback)" = prior-record-kept-agent-dead ] \
    || fail "rollback should reconcile the observed dead agent"
  assert_contains "$out" "no agent is running" "the failure should report the reconciled dead state"
  assert_grep "preserve this after stop" "$dir/home/data/rl25/brief.md" \
    "the progress note should survive once the old agent has stopped"
  pass "fm-control relaunch: partial stop reconciles actual agent state"
}

test_complete_journal_failure_rolls_back_from_durable_phase() {
  local dir out rc real_mv
  dir=$(new_case completejournal rl27)
  add_ship_task "$dir" rl27 claude
  printf 'codex' > "$dir/fake/becomes"
  real_mv=$(command -v mv)
  make_mv_failure_stub "$dir"
  out=$(FM_REAL_MV="$real_mv" FM_FAKE_COMPLETE_JOURNAL_MV_FAIL=1 \
    run_control "$dir" rl27 relaunch --harness codex --note "keep durable phase honest"); rc=$?
  expect_code 1 "$rc" "a failed complete journal replacement should fail closed"$'\n'"$out"
  [ "$(journal_field "$dir" rl27 phase)" = failed:launching ] \
    || fail "rollback should start from the last durable launching phase"
  [ "$(journal_field "$dir" rl27 rollback)" = none-new-agent-confirmed ] \
    || fail "rollback should retain the confirmed-running replacement"
  [ "$(meta_field "$dir" rl27 harness)" = codex ] \
    || fail "journal failure must not rewrite the published replacement record"
  assert_contains "$out" "replacement is running" \
    "journal failure should report the confirmed-running replacement"
  assert_not_contains "$out" "no running agent could be confirmed" \
    "journal failure should not contradict the confirmed agent state"
  pass "fm-control relaunch: failed journal replacement preserves durable phase"
}

test_prepublication_abort_retires_replacement_wiring_and_busy_state() {
  local dir out rc real_mv meta
  dir=$(new_case prepublishcleanup rl28)
  add_ship_task "$dir" rl28 claude
  meta="$dir/home/state/rl28.meta"
  real_mv=$(command -v mv)
  make_mv_failure_stub "$dir"
  out=$(FM_REAL_MV="$real_mv" FM_FAKE_META_PUBLISH_MV_FAIL="$meta" \
    run_control "$dir" rl28 relaunch --note "clean partial replacement state"); rc=$?
  expect_code 1 "$rc" "a failed metadata publication should fail closed"$'\n'"$out"
  [ "$(meta_field "$dir" rl28 harness)" = claude ] \
    || fail "a failed publication should retain the prior durable record"
  [ ! -e "$dir/wt/.claude/settings.local.json" ] \
    || fail "an aborted replacement should remove its harness wiring"
  [ ! -e "$dir/home/state/rl28.busy-gen" ] \
    || fail "an aborted replacement should retire its busy generation"
  [ ! -e "$dir/home/state/rl28.busy-state" ] \
    || fail "an aborted replacement should remove its seeded busy record"
  [ "$(journal_field "$dir" rl28 rollback)" = prior-record-kept ] \
    || fail "the journal should record the unpublished replacement rollback"
  pass "fm-spawn relaunch: prepublication abort removes replacement state"
}

test_journal_records_the_checkpoint_it_proved() {
  local dir head
  dir=$(new_case journal rl14)
  add_ship_task "$dir" rl14 claude
  printf 'scratch\n' > "$dir/wt/uncommitted.txt"
  head=$(git -C "$dir/wt" rev-parse HEAD)
  run_control "$dir" rl14 relaunch --note "keeping the scratch file" >/dev/null
  [ "$(journal_field "$dir" rl14 worktree_head)" = "$head" ] \
    || fail "the checkpoint should record the head it preserved"
  [ "$(journal_field "$dir" rl14 worktree_dirty)" = yes ] \
    || fail "the checkpoint should record that uncommitted work was present"
  [ -f "$dir/wt/uncommitted.txt" ] || fail "uncommitted work must survive a relaunch"
  pass "fm-control relaunch: the checkpoint records the exact unlanded work it preserved"
}

# --- secondmate child-work safety -------------------------------------------

test_secondmate_relaunch_checkpoints_child_work_and_spares_the_charter() {
  local dir home out rc
  dir=$(new_case sm sm1)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'claude\n' > "$home/config/secondmate-harness"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm1\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# charter\n' > "$dir/smhome/data/charter.md"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  printf 'window=x:fm-c1\n' > "$dir/smhome/state/c1.meta"
  printf 'window=x:fm-c2\n' > "$dir/smhome/state/c2.meta"
  {
    echo "window=fmses:fm-sm1"
    echo "endpoint_task_id=sm1"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
    echo "projects="
  } > "$home/state/sm1.meta"
  printf '%s\n' "fm-sm1" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  # No --note: a secondmate reconciles its own home's records at startup, so
  # the note is optional there.
  out=$(run_control "$dir" sm1 relaunch); rc=$?
  expect_code 0 "$rc" "a checkpointed secondmate should relaunch"$'\n'"$out"
  [ "$(journal_field "$dir" sm1 children)" = 2 ] \
    || fail "the checkpoint must account for the secondmate's child work, got '$(journal_field "$dir" sm1 children)'"
  assert_not_contains "$out" "requires --note" "a secondmate relaunch must not demand a progress note"
  [ "$(cat "$dir/smhome/data/charter.md")" = "# charter" ] \
    || fail "a secondmate's standing charter must never be rewritten by a relaunch"
  assert_present "$dir/smhome/state/c1.meta" "child records must survive the relaunch"
  assert_present "$dir/smhome/state/c2.meta" "child records must survive the relaunch"
  pass "fm-control relaunch: a secondmate's child work is accounted for and its charter is left alone"
}

test_secondmate_relaunch_refuses_an_unmarked_home() {
  local dir home out rc
  dir=$(new_case smbad sm2)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'claude\n' > "$home/config/secondmate-harness"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state"
  printf 'someone-else\n' > "$dir/smhome/.fm-secondmate-home"
  {
    echo "window=fmses:fm-sm2"
    echo "endpoint_task_id=sm2"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
  } > "$home/state/sm2.meta"
  printf '%s\n' "fm-sm2" > "$dir/fake/windows"
  out=$(run_control "$dir" sm2 relaunch); rc=$?
  expect_code 1 "$rc" "a home marked for another secondmate should refuse"
  assert_contains "$out" "not marked as its own seeded secondmate home" \
    "the refusal should name the identity mismatch"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch must not stop the agent"
  pass "fm-control relaunch: a secondmate home that is not this secondmate's is refused"
}

test_secondmate_checkpoint_refuses_unreadable_child_state() {
  local dir home out rc
  dir=$(new_case smchildren sm5)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'claude\n' > "$home/config/secondmate-harness"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state/bad.meta"
  printf 'sm5\n' > "$dir/smhome/.fm-secondmate-home"
  {
    echo "window=fmses:fm-sm5"
    echo "endpoint_task_id=sm5"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "home=$dir/smhome"
  } > "$home/state/sm5.meta"
  printf '%s\n' "fm-sm5" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  out=$(run_control "$dir" sm5 relaunch); rc=$?
  expect_code 1 "$rc" "a non-readable child record should refuse"
  assert_contains "$out" "not a readable regular file" "the refusal should name the unreadable child record"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "child record failure must not stop the secondmate"
  rmdir "$dir/smhome/state/bad.meta"
  cat > "$dir/fakebin/find" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$dir/fakebin/find"
  out=$(run_control "$dir" sm5 relaunch); rc=$?
  expect_code 1 "$rc" "failed child-state traversal should refuse"
  assert_contains "$out" "child records cannot be traversed" \
    "the refusal should preserve a find traversal failure"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "child traversal failure must not stop the secondmate"
  pass "fm-control relaunch: unreadable and untraversable child state fails checkpoint"
}

test_concurrent_relaunch_is_refused() {
  local dir out rc lock holder i
  dir=$(new_case lock rl19)
  add_ship_task "$dir" rl19 claude
  lock="$dir/home/state/.control-rl19.lock"
  # A live holder of this task's control lock, taken through the same lock
  # library fm-control uses.
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    sleep 30
  ) &
  holder=$!
  i=0
  while [ ! -e "$lock" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$lock" ] || { kill "$holder" 2>/dev/null; fail "could not stage a held control lock"; }
  out=$(run_control "$dir" rl19 relaunch --note "concurrent"); rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  expect_code 1 "$rc" "a second concurrent control action should refuse"
  assert_contains "$out" "another lifecycle action is already running" \
    "the refusal should name the concurrent action"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "a refused concurrent relaunch must not stop the agent"
  pass "fm-control relaunch: two control actions on one task serialize instead of interleaving"
}

# shellcheck disable=SC2031
test_direct_spawn_relaunch_participates_in_the_lifecycle_lock() {
  local dir out rc lock holder i=0
  dir=$(new_case spawnlock rl26)
  add_ship_task "$dir" rl26 claude
  printf 'zsh' > "$dir/fake/command"
  lock="$dir/home/state/.control-rl26.lock"
  (
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    sleep 30
  ) &
  holder=$!
  while [ ! -e "$lock" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$lock" ] || fail "could not stage the lifecycle lock"
  out=$(run_spawn "$dir" rl26 --relaunch --harness claude); rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  expect_code 1 "$rc" "direct relaunch spawn should refuse a held lifecycle lock"
  assert_contains "$out" "another lifecycle action is already running" \
    "direct relaunch spawn should name lifecycle contention"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "contended direct relaunch spawn must deliver no launch bytes"
  pass "fm-spawn relaunch: direct entry participates in lifecycle serialization"
}

# shellcheck disable=SC2031
test_promotion_participates_in_the_lifecycle_lock_before_metadata_resolution() {
  local dir out rc lock holder i=0
  dir=$(new_case promotelock rl29)
  add_ship_task "$dir" rl29 claude
  lock="$dir/home/state/.control-rl29.lock"
  (
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    sleep 30
  ) &
  holder=$!
  while [ ! -e "$lock" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$lock" ] || fail "could not stage the promotion lifecycle lock"
  out=$(FM_HOME="$dir/home" "$PROMOTE" rl29 --mode direct-PR --yolo on 2>&1); rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  expect_code 1 "$rc" "promotion should refuse a concurrent lifecycle action"
  assert_contains "$out" "another lifecycle action is already running" \
    "promotion should lock before interpreting the task metadata"
  [ "$(meta_field "$dir" rl29 kind)" = ship ] \
    || fail "a contended promotion must leave task metadata unchanged"
  pass "fm-promote: promotion participates in lifecycle serialization"
}

# --- 6. fm-spawn --relaunch's own refusals -----------------------------------

test_spawn_relaunch_refuses_a_live_agent() {
  local dir out rc
  dir=$(new_case live rl15)
  add_ship_task "$dir" rl15 claude
  out=$(run_spawn "$dir" rl15 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "relaunching into a live endpoint should refuse"
  assert_contains "$out" "positively agent-free endpoint" "the refusal should demand an agent-free endpoint"
  assert_contains "$out" "fm-control.sh rl15 exit" "the refusal should point at the way to stop it"
  pass "fm-spawn --relaunch: refuses to launch a second agent into a live endpoint"
}

test_spawn_relaunch_refuses_contradicting_flags() {
  local dir out rc
  dir=$(new_case flags rl16)
  add_ship_task "$dir" rl16 claude
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl16 --relaunch --backend herdr); rc=$?
  expect_code 1 "$rc" "--backend should be refused alongside --relaunch"
  assert_contains "$out" "recorded backend" "the refusal should name the recorded backend rule"
  out=$(run_spawn "$dir" rl16 --relaunch --scout); rc=$?
  expect_code 1 "$rc" "--scout should be refused alongside --relaunch"
  assert_contains "$out" "recorded kind" "the refusal should name the recorded kind rule"
  out=$(run_spawn "$dir" rl16 "$dir/proj" --relaunch); rc=$?
  expect_code 1 "$rc" "a project positional should be refused alongside --relaunch"
  assert_contains "$out" "takes the task id only" "the refusal should name the positional rule"
  pass "fm-spawn --relaunch: every identity axis comes from the record, and a contradicting flag refuses"
}

test_spawn_relaunch_refuses_an_unrecorded_task() {
  local dir out rc
  dir=$(new_case norecord rl17)
  add_ship_task "$dir" rl17 claude
  out=$(run_spawn "$dir" nosuchtask --relaunch); rc=$?
  expect_code 1 "$rc" "an unrecorded task should refuse"
  assert_contains "$out" "needs an existing task record" "the refusal should name the missing record"
  pass "fm-spawn --relaunch: an unrecorded task is refused"
}

test_spawn_relaunch_refuses_a_pane_outside_the_worktree() {
  local dir out rc
  dir=$(new_case wrongcwd rl18)
  add_ship_task "$dir" rl18 claude
  printf 'zsh' > "$dir/fake/command"
  printf '%s' "$dir/proj" > "$dir/fake/cwd"
  out=$(run_spawn "$dir" rl18 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "a pane outside the worktree should refuse"
  assert_contains "$out" "not its recorded worktree" "the refusal should name the wrong location"
  pass "fm-spawn --relaunch: refuses to start a replacement outside the copy holding the work"
}

# --- 7. prior-boot process-scope recovery -----------------------------------

test_pre_reboot_relaunch_does_not_signal_a_reused_pid() {
  local dir out rc identity
  dir=$(new_case reboot-relaunch rl50)
  add_ship_task "$dir" rl50 claude
  prepare_dead_relaunch "$dir" rl50
  start_scope_sleeper
  identity=$(fm_task_process_identity "$SCOPE_SLEEPER_PID") \
    || fail "could not read the reused process identity"
  write_active_reused_scope "$dir" rl50 "$identity" boot-prior
  set_boot_overlays boot-now
  out=$(run_control "$dir" rl50 relaunch --note "resume after reboot"); rc=$?
  unset_boot_overlays
  expect_code 0 "$rc" "a proved prior-boot scope should let relaunch proceed"$'\n'"$out"
  assert_contains "$out" "relaunched rl50" "prior-boot relaunch should replace the agent"
  assert_scope_sleeper_alive
  assert_scope_empty "$dir/home/state/rl50.process-scope" rl50
  pass "fm-control relaunch: a proved prior-boot scope retires without signaling a reused pid"
}

test_pre_reboot_spawn_relaunch_does_not_signal_a_reused_pid() {
  local dir out rc identity
  dir=$(new_case reboot-spawn rl51)
  add_ship_task "$dir" rl51 claude
  prepare_dead_relaunch "$dir" rl51
  start_scope_sleeper
  identity=$(fm_task_process_identity "$SCOPE_SLEEPER_PID") \
    || fail "could not read the reused process identity"
  write_active_reused_scope "$dir" rl51 "$identity" boot-prior
  set_boot_overlays boot-now
  out=$(run_spawn "$dir" rl51 --relaunch --harness claude); rc=$?
  unset_boot_overlays
  expect_code 0 "$rc" "spawn --relaunch should retire a proved prior-boot scope"$'\n'"$out"
  assert_scope_sleeper_alive
  assert_scope_empty "$dir/home/state/rl51.process-scope" rl51
  pass "fm-spawn --relaunch: a proved prior-boot scope retires without signaling a reused pid"
}

test_current_boot_identity_mismatch_still_refuses() {
  local dir out rc before
  dir=$(new_case current-boot-mismatch rl52)
  add_ship_task "$dir" rl52 claude
  prepare_dead_relaunch "$dir" rl52
  start_scope_sleeper
  write_active_reused_scope "$dir" rl52 "$(scope_lstart_at $((SCOPE_BOOT_TIME - 3600)))" boot-now
  before=$(cat "$dir/home/state/rl52.process-scope")
  set_boot_overlays boot-now
  out=$(run_spawn "$dir" rl52 --relaunch --harness claude); rc=$?
  unset_boot_overlays
  expect_code 1 "$rc" "current-boot identity mismatch must still refuse"
  assert_contains "$out" "process-scope anchor is gone or changed" \
    "current-boot mismatch should keep the unowned-group refusal"
  assert_scope_sleeper_alive
  [ "$(cat "$dir/home/state/rl52.process-scope")" = "$before" ] \
    || fail "current-boot mismatch mutated the process-scope record"
  pass "fm-spawn --relaunch: current-boot identity mismatch still refuses without mutation"
}

test_legacy_darwin_pre_boot_lstart_relaunches() {
  local dir out rc
  dir=$(new_case legacy-pre-boot rl53)
  add_ship_task "$dir" rl53 claude
  prepare_dead_relaunch "$dir" rl53
  start_scope_sleeper
  write_active_reused_scope "$dir" rl53 "$(scope_lstart_at $((SCOPE_BOOT_TIME - 3600)))"
  set_boot_overlays boot-now
  out=$(run_spawn "$dir" rl53 --relaunch --harness claude); rc=$?
  unset_boot_overlays
  expect_code 0 "$rc" "legacy Darwin lstart before boot should recover"$'\n'"$out"
  assert_scope_sleeper_alive
  assert_scope_empty "$dir/home/state/rl53.process-scope" rl53
  pass "fm-spawn --relaunch: legacy Darwin lstart before boot retires without signaling"
}

test_legacy_equal_lstart_refuses() {
  local dir out rc before
  dir=$(new_case legacy-equal rl54)
  add_ship_task "$dir" rl54 claude
  prepare_dead_relaunch "$dir" rl54
  start_scope_sleeper
  write_active_reused_scope "$dir" rl54 "$(scope_lstart_at "$SCOPE_BOOT_TIME")"
  before=$(cat "$dir/home/state/rl54.process-scope")
  set_boot_overlays boot-now
  out=$(run_spawn "$dir" rl54 --relaunch --harness claude); rc=$?
  unset_boot_overlays
  expect_code 1 "$rc" "lstart equal to boot time must refuse"
  assert_contains "$out" "process-scope anchor is gone or changed" \
    "equal lstart should keep the unowned-group refusal"
  assert_scope_sleeper_alive
  [ "$(cat "$dir/home/state/rl54.process-scope")" = "$before" ] \
    || fail "equal lstart mutated the process-scope record"
  pass "fm-spawn --relaunch: lstart equal to boot time still refuses"
}

test_legacy_after_lstart_refuses() {
  local dir out rc before
  dir=$(new_case legacy-after rl55)
  add_ship_task "$dir" rl55 claude
  prepare_dead_relaunch "$dir" rl55
  start_scope_sleeper
  write_active_reused_scope "$dir" rl55 "$(scope_lstart_at $((SCOPE_BOOT_TIME + 60)))"
  before=$(cat "$dir/home/state/rl55.process-scope")
  set_boot_overlays boot-now
  out=$(run_spawn "$dir" rl55 --relaunch --harness claude); rc=$?
  unset_boot_overlays
  expect_code 1 "$rc" "lstart after boot time must refuse"
  assert_contains "$out" "process-scope anchor is gone or changed" \
    "later lstart should keep the unowned-group refusal"
  assert_scope_sleeper_alive
  [ "$(cat "$dir/home/state/rl55.process-scope")" = "$before" ] \
    || fail "later lstart mutated the process-scope record"
  pass "fm-spawn --relaunch: lstart after boot time still refuses"
}

test_legacy_unparseable_lstart_refuses() {
  local dir out rc before
  dir=$(new_case legacy-unparseable rl56)
  add_ship_task "$dir" rl56 claude
  prepare_dead_relaunch "$dir" rl56
  start_scope_sleeper
  write_active_reused_scope "$dir" rl56 "lstart=not-a-timestamp"
  before=$(cat "$dir/home/state/rl56.process-scope")
  set_boot_overlays boot-now
  out=$(run_spawn "$dir" rl56 --relaunch --harness claude); rc=$?
  unset_boot_overlays
  expect_code 1 "$rc" "unparseable lstart must refuse"
  assert_contains "$out" "process-scope anchor is gone or changed" \
    "unparseable lstart should keep the unowned-group refusal"
  assert_scope_sleeper_alive
  [ "$(cat "$dir/home/state/rl56.process-scope")" = "$before" ] \
    || fail "unparseable lstart mutated the process-scope record"
  pass "fm-spawn --relaunch: unparseable lstart still refuses"
}

test_portable_boot_generation_mismatch_relaunches() {
  local dir out rc
  dir=$(new_case portable-mismatch rl57)
  add_ship_task "$dir" rl57 claude
  prepare_dead_relaunch "$dir" rl57
  start_scope_sleeper
  write_active_reused_scope "$dir" rl57 "$(scope_lstart_at $((SCOPE_BOOT_TIME + 60)))" boot-prior
  set_boot_overlays boot-now
  out=$(run_spawn "$dir" rl57 --relaunch --harness claude); rc=$?
  unset_boot_overlays
  expect_code 0 "$rc" "portable boot-generation mismatch should recover even when lstart is after boot"$'\n'"$out"
  assert_scope_sleeper_alive
  assert_scope_empty "$dir/home/state/rl57.process-scope" rl57
  pass "fm-spawn --relaunch: portable boot-generation mismatch retires without signaling"
}

test_matching_boot_generation_refuses_even_with_pre_boot_lstart() {
  local dir out rc before
  dir=$(new_case matching-generation rl58)
  add_ship_task "$dir" rl58 claude
  prepare_dead_relaunch "$dir" rl58
  start_scope_sleeper
  write_active_reused_scope "$dir" rl58 "$(scope_lstart_at $((SCOPE_BOOT_TIME - 3600)))" boot-now
  before=$(cat "$dir/home/state/rl58.process-scope")
  set_boot_overlays boot-now
  out=$(run_spawn "$dir" rl58 --relaunch --harness claude); rc=$?
  unset_boot_overlays
  expect_code 1 "$rc" "matching boot generation must refuse even if lstart predates boot"
  assert_contains "$out" "process-scope anchor is gone or changed" \
    "matching generation should keep the unowned-group refusal"
  assert_scope_sleeper_alive
  [ "$(cat "$dir/home/state/rl58.process-scope")" = "$before" ] \
    || fail "matching generation mutated the process-scope record"
  pass "fm-spawn --relaunch: matching boot generation still refuses"
}

test_missing_boot_generation_without_legacy_refuses() {
  local dir out rc before
  dir=$(new_case missing-generation rl59)
  add_ship_task "$dir" rl59 claude
  prepare_dead_relaunch "$dir" rl59
  start_scope_sleeper
  write_active_reused_scope "$dir" rl59 "starttime=12345"
  before=$(cat "$dir/home/state/rl59.process-scope")
  set_boot_overlays boot-now
  out=$(run_spawn "$dir" rl59 --relaunch --harness claude); rc=$?
  unset_boot_overlays
  expect_code 1 "$rc" "missing boot generation without Darwin lstart must refuse"
  assert_contains "$out" "process-scope anchor is gone or changed" \
    "Linux-style starttime without a generation should keep the refusal"
  assert_scope_sleeper_alive
  [ "$(cat "$dir/home/state/rl59.process-scope")" = "$before" ] \
    || fail "missing generation mutated the process-scope record"
  pass "fm-spawn --relaunch: missing boot generation without legacy proof still refuses"
}

test_unreadable_boot_generation_uses_legacy_when_lstart_predates() {
  local dir out rc
  dir=$(new_case unreadable-legacy rl60)
  add_ship_task "$dir" rl60 claude
  prepare_dead_relaunch "$dir" rl60
  start_scope_sleeper
  write_active_reused_scope "$dir" rl60 "$(scope_lstart_at $((SCOPE_BOOT_TIME - 3600)))" boot-prior
  export FM_TASK_PROCESS_BOOT_GENERATION=
  export FM_TASK_PROCESS_BOOT_TIME=$SCOPE_BOOT_TIME
  out=$(run_spawn "$dir" rl60 --relaunch --harness claude); rc=$?
  unset_boot_overlays
  expect_code 0 "$rc" "unreadable generation should still recover through legacy Darwin proof"$'\n'"$out"
  assert_scope_sleeper_alive
  assert_scope_empty "$dir/home/state/rl60.process-scope" rl60
  pass "fm-spawn --relaunch: unreadable boot generation still recovers through legacy proof"
}

test_unreadable_boot_generation_without_legacy_refuses() {
  local dir out rc before
  dir=$(new_case unreadable-nolegacy rl61)
  add_ship_task "$dir" rl61 claude
  prepare_dead_relaunch "$dir" rl61
  start_scope_sleeper
  write_active_reused_scope "$dir" rl61 "starttime=12345" boot-prior
  before=$(cat "$dir/home/state/rl61.process-scope")
  export FM_TASK_PROCESS_BOOT_GENERATION=
  export FM_TASK_PROCESS_BOOT_TIME=$SCOPE_BOOT_TIME
  out=$(run_spawn "$dir" rl61 --relaunch --harness claude); rc=$?
  unset_boot_overlays
  expect_code 1 "$rc" "unreadable generation without legacy proof must refuse"
  assert_contains "$out" "process-scope anchor is gone or changed" \
    "unreadable generation without lstart should keep the refusal"
  assert_scope_sleeper_alive
  [ "$(cat "$dir/home/state/rl61.process-scope")" = "$before" ] \
    || fail "unreadable generation mutated the process-scope record"
  pass "fm-spawn --relaunch: unreadable boot generation without legacy proof still refuses"
}

test_empty_scope_relaunch_is_idempotent() {
  local dir out rc before
  dir=$(new_case empty-idempotent rl62)
  add_ship_task "$dir" rl62 claude
  prepare_dead_relaunch "$dir" rl62
  before=$(cat "$dir/home/state/rl62.process-scope")
  set_boot_overlays boot-now
  out=$(run_spawn "$dir" rl62 --relaunch --harness claude); rc=$?
  unset_boot_overlays
  expect_code 0 "$rc" "an already-empty scope should relaunch"$'\n'"$out"
  [ "$(cat "$dir/home/state/rl62.process-scope")" = "$before" ] \
    || fail "empty-scope relaunch mutated the already-empty process-scope record"
  pass "fm-spawn --relaunch: an already-empty process scope remains idempotent"
}

test_clock_ambiguous_boot_time_refuses() {
  local dir out rc before
  dir=$(new_case clock-ambiguous rl67)
  add_ship_task "$dir" rl67 claude
  prepare_dead_relaunch "$dir" rl67
  start_scope_sleeper
  write_active_reused_scope "$dir" rl67 "$(scope_lstart_at $((SCOPE_BOOT_TIME - 3600)))"
  before=$(cat "$dir/home/state/rl67.process-scope")
  unset FM_TASK_PROCESS_BOOT_GENERATION FM_TASK_PROCESS_BOOT_GENERATION_FILE
  export FM_TASK_PROCESS_BOOT_TIME=
  out=$(run_spawn "$dir" rl67 --relaunch --harness claude); rc=$?
  unset_boot_overlays
  expect_code 1 "$rc" "an unreadable boot time must refuse legacy Darwin proof"
  assert_contains "$out" "process-scope anchor is gone or changed" \
    "clock-ambiguous boot time should keep the unowned-group refusal"
  assert_scope_sleeper_alive
  [ "$(cat "$dir/home/state/rl67.process-scope")" = "$before" ] \
    || fail "clock-ambiguous boot time mutated the process-scope record"
  pass "fm-spawn --relaunch: unreadable boot time still refuses without mutation"
}

test_mixed_identity_without_generation_refuses() {
  local dir out rc before pid token
  dir=$(new_case mixed-identity rl68)
  add_ship_task "$dir" rl68 claude
  prepare_dead_relaunch "$dir" rl68
  start_scope_sleeper
  pid=$SCOPE_SLEEPER_PID
  token=test-rl68
  {
    printf 'version=2\n'
    printf 'status=active\n'
    printf 'token=%s\n' "$token"
    printf 'containment=process-group\n'
    printf 'anchor_pid=%s\n' "$pid"
    printf 'anchor_identity=%s\n' "$(scope_lstart_at $((SCOPE_BOOT_TIME - 3600)))"
    printf 'agent_pid=%s\n' "$pid"
    printf 'agent_identity=starttime=12345\n'
    printf 'endpoint_pid=3\n'
    printf 'endpoint_identity=starttime=12345\n'
    printf 'pgid=%s\n' "$pid"
  } > "$dir/home/state/rl68.process-scope"
  before=$(cat "$dir/home/state/rl68.process-scope")
  set_boot_overlays boot-now
  out=$(run_spawn "$dir" rl68 --relaunch --harness claude); rc=$?
  unset_boot_overlays
  expect_code 1 "$rc" "mixed lstart/starttime identities without a generation must refuse"
  assert_contains "$out" "process-scope anchor is gone or changed" \
    "mixed identities should keep the unowned-group refusal"
  assert_scope_sleeper_alive
  [ "$(cat "$dir/home/state/rl68.process-scope")" = "$before" ] \
    || fail "mixed identities mutated the process-scope record"
  pass "fm-spawn --relaunch: mixed identities without a generation still refuse"
}

test_contradictory_process_scope_records_refuse_without_mutation() {
  local dir out rc before identity pid token

  dir=$(new_case duplicate-generation rl69)
  add_ship_task "$dir" rl69 claude
  prepare_dead_relaunch "$dir" rl69
  start_scope_sleeper
  identity=$(fm_task_process_identity "$SCOPE_SLEEPER_PID") \
    || fail "could not read the reused process identity"
  write_active_reused_scope "$dir" rl69 "$identity" boot-prior
  printf 'boot_generation=other-prior\n' >> "$dir/home/state/rl69.process-scope"
  before=$(cat "$dir/home/state/rl69.process-scope")
  set_boot_overlays boot-now
  out=$(run_spawn "$dir" rl69 --relaunch --harness claude); rc=$?
  unset_boot_overlays
  expect_code 1 "$rc" "duplicate boot-generation fields must refuse"
  assert_contains "$out" "malformed process-scope record" \
    "duplicate boot-generation refusal should name the malformed record"
  [ "$(cat "$dir/home/state/rl69.process-scope")" = "$before" ] \
    || fail "duplicate boot-generation refusal mutated the process-scope record"
  assert_scope_sleeper_alive

  dir=$(new_case legacy-generation rl70)
  add_ship_task "$dir" rl70 claude
  prepare_dead_relaunch "$dir" rl70
  start_scope_sleeper
  pid=$SCOPE_SLEEPER_PID
  token=test-rl70
  identity=$(scope_lstart_at $((SCOPE_BOOT_TIME - 3600)))
  {
    printf 'version=1\n'
    printf 'status=active\n'
    printf 'token=%s\n' "$token"
    printf 'containment=process-group\n'
    printf 'leader_pid=%s\n' "$pid"
    printf 'leader_identity=%s\n' "$identity"
    printf 'pgid=%s\n' "$pid"
    printf 'boot_generation=boot-prior\n'
  } > "$dir/home/state/rl70.process-scope"
  before=$(cat "$dir/home/state/rl70.process-scope")
  set_boot_overlays boot-now
  out=$(run_spawn "$dir" rl70 --relaunch --harness claude); rc=$?
  unset_boot_overlays
  expect_code 1 "$rc" "version 1 records with boot generation must refuse"
  assert_contains "$out" "malformed process-scope record" \
    "legacy boot-generation refusal should name the malformed record"
  [ "$(cat "$dir/home/state/rl70.process-scope")" = "$before" ] \
    || fail "legacy boot-generation refusal mutated the process-scope record"
  assert_scope_sleeper_alive

  dir=$(new_case empty-generation rl71)
  add_ship_task "$dir" rl71 claude
  prepare_dead_relaunch "$dir" rl71
  printf 'boot_generation=\n' >> "$dir/home/state/rl71.process-scope"
  before=$(cat "$dir/home/state/rl71.process-scope")
  set_boot_overlays boot-now
  out=$(run_spawn "$dir" rl71 --relaunch --harness claude); rc=$?
  unset_boot_overlays
  expect_code 1 "$rc" "empty records with an empty boot-generation field must refuse"
  assert_contains "$out" "malformed process-scope record" \
    "empty boot-generation refusal should name the malformed record"
  [ "$(cat "$dir/home/state/rl71.process-scope")" = "$before" ] \
    || fail "empty boot-generation refusal mutated the process-scope record"

  dir=$(new_case legacy-modern-fields rl73)
  add_ship_task "$dir" rl73 claude
  prepare_dead_relaunch "$dir" rl73
  start_scope_sleeper
  pid=$SCOPE_SLEEPER_PID
  token=test-rl73
  identity=$(scope_lstart_at $((SCOPE_BOOT_TIME - 3600)))
  {
    printf 'version=1\n'
    printf 'status=active\n'
    printf 'token=%s\n' "$token"
    printf 'containment=process-group\n'
    printf 'leader_pid=%s\n' "$pid"
    printf 'leader_identity=%s\n' "$identity"
    printf 'anchor_pid=%s\n' "$pid"
    printf 'anchor_identity=starttime=999\n'
    printf 'agent_pid=%s\n' "$pid"
    printf 'agent_identity=starttime=999\n'
    printf 'pgid=%s\n' "$pid"
  } > "$dir/home/state/rl73.process-scope"
  before=$(cat "$dir/home/state/rl73.process-scope")
  set_boot_overlays boot-now
  out=$(run_spawn "$dir" rl73 --relaunch --harness claude); rc=$?
  unset_boot_overlays
  expect_code 1 "$rc" "version 1 records with version 2 identity fields must refuse"
  assert_contains "$out" "malformed process-scope record" \
    "mixed-schema legacy refusal should name the malformed record"
  [ "$(cat "$dir/home/state/rl73.process-scope")" = "$before" ] \
    || fail "mixed-schema legacy refusal mutated the process-scope record"
  assert_scope_sleeper_alive

  dir=$(new_case active-legacy-fields rl74)
  add_ship_task "$dir" rl74 claude
  prepare_dead_relaunch "$dir" rl74
  start_scope_sleeper
  identity=$(fm_task_process_identity "$SCOPE_SLEEPER_PID") \
    || fail "could not read the reused process identity"
  write_active_reused_scope "$dir" rl74 "$identity" boot-prior
  printf 'leader_pid=%s\nleader_identity=%s\n' \
    "$SCOPE_SLEEPER_PID" "$identity" >> "$dir/home/state/rl74.process-scope"
  before=$(cat "$dir/home/state/rl74.process-scope")
  set_boot_overlays boot-now
  out=$(run_spawn "$dir" rl74 --relaunch --harness claude); rc=$?
  unset_boot_overlays
  expect_code 1 "$rc" "version 2 active records with legacy identity fields must refuse"
  assert_contains "$out" "malformed process-scope record" \
    "mixed-schema modern refusal should name the malformed record"
  [ "$(cat "$dir/home/state/rl74.process-scope")" = "$before" ] \
    || fail "mixed-schema modern refusal mutated the process-scope record"
  assert_scope_sleeper_alive

  dir=$(new_case empty-active-fields rl75)
  add_ship_task "$dir" rl75 claude
  prepare_dead_relaunch "$dir" rl75
  printf 'anchor_pid=22\nanchor_identity=starttime=999\n' \
    >> "$dir/home/state/rl75.process-scope"
  before=$(cat "$dir/home/state/rl75.process-scope")
  set_boot_overlays boot-now
  out=$(run_spawn "$dir" rl75 --relaunch --harness claude); rc=$?
  unset_boot_overlays
  expect_code 1 "$rc" "empty records with active identity fields must refuse"
  assert_contains "$out" "malformed process-scope record" \
    "empty active-field refusal should name the malformed record"
  [ "$(cat "$dir/home/state/rl75.process-scope")" = "$before" ] \
    || fail "empty active-field refusal mutated the process-scope record"

  dir=$(new_case unknown-generation-key rl76)
  add_ship_task "$dir" rl76 claude
  prepare_dead_relaunch "$dir" rl76
  start_scope_sleeper
  pid=$SCOPE_SLEEPER_PID
  token=test-rl76
  identity=$(scope_lstart_at $((SCOPE_BOOT_TIME - 3600)))
  {
    printf 'version=1\n'
    printf 'status=active\n'
    printf 'token=%s\n' "$token"
    printf 'containment=process-group\n'
    printf 'leader_pid=%s\n' "$pid"
    printf 'leader_identity=%s\n' "$identity"
    printf 'pgid=%s\n' "$pid"
    printf ' boot_generation=boot-now\n'
  } > "$dir/home/state/rl76.process-scope"
  before=$(cat "$dir/home/state/rl76.process-scope")
  set_boot_overlays boot-now
  out=$(run_spawn "$dir" rl76 --relaunch --harness claude); rc=$?
  unset_boot_overlays
  expect_code 1 "$rc" "unknown process-scope keys must refuse"
  assert_contains "$out" "malformed process-scope record" \
    "unknown-key refusal should name the malformed record"
  [ "$(cat "$dir/home/state/rl76.process-scope")" = "$before" ] \
    || fail "unknown-key refusal mutated the process-scope record"
  assert_scope_sleeper_alive

  dir=$(new_case malformed-record-line rl77)
  add_ship_task "$dir" rl77 claude
  prepare_dead_relaunch "$dir" rl77
  printf 'not-a-process-scope-field\n' >> "$dir/home/state/rl77.process-scope"
  before=$(cat "$dir/home/state/rl77.process-scope")
  set_boot_overlays boot-now
  out=$(run_spawn "$dir" rl77 --relaunch --harness claude); rc=$?
  unset_boot_overlays
  expect_code 1 "$rc" "malformed nonempty process-scope lines must refuse"
  assert_contains "$out" "malformed process-scope record" \
    "malformed-line refusal should name the malformed record"
  [ "$(cat "$dir/home/state/rl77.process-scope")" = "$before" ] \
    || fail "malformed-line refusal mutated the process-scope record"
  pass "fm-spawn --relaunch: contradictory process-scope schemas refuse without mutation"
}

test_scope_launch_preserves_token_for_escaped_descendants() {
  local dir record token launch wrapper_pid escaped_pid attempts status
  dir=$(new_case escaped-descendant rl72)
  record="$dir/home/state/rl72.process-scope"
  token=test-rl72
  fm_task_process_scope_create_empty "$dir/home/state" rl72 "$token" process-group \
    || fail "could not create the escaped-descendant process scope"
  cat > "$dir/escape.py" <<'PY'
import os
import sys
import time

if os.fork() != 0:
    os._exit(0)
os.setsid()
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(str(os.getpid()))
time.sleep(300)
PY
  launch="python3 $dir/escape.py $dir/escaped.pid"
  python3 - "$ROOT/bin/fm-task-process-launch.sh" "$record" "$token" "$launch" <<'PY' &
import os
import sys

pid = os.fork()
if pid == 0:
    os.setpgrp()
    os.execv(sys.argv[1], [sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[3], sys.argv[4], "-"])
os.waitpid(pid, 0)
PY
  wrapper_pid=$!
  SCOPE_SLEEPERS+=("$wrapper_pid")
  attempts=0
  while [ "$attempts" -lt 100 ]; do
    [ -s "$dir/escaped.pid" ] && break
    /bin/sleep 0.02
    attempts=$((attempts + 1))
  done
  [ -s "$dir/escaped.pid" ] || fail "escaped descendant did not start"
  escaped_pid=$(cat "$dir/escaped.pid")
  SCOPE_SLEEPERS+=("$escaped_pid")
  /bin/sleep 0.3
  kill -0 "$escaped_pid" 2>/dev/null || fail "escaped descendant exited unexpectedly"
  status=$(fm_task_process_scope_record_value "$record" status)
  [ "$status" = active ] \
    || fail "process scope became empty while its escaped token-bound descendant was alive"
  kill -TERM "$escaped_pid" 2>/dev/null || true
  wait "$wrapper_pid" 2>/dev/null || fail "scope launcher failed after its descendant exited"
  status=$(fm_task_process_scope_record_value "$record" status)
  [ "$status" = empty ] || fail "process scope did not become empty after its descendant exited"
  pass "process-scope launch retains token ownership across escaped descendants"
}

test_pre_reboot_spawn_relaunch_still_requires_an_agent_free_endpoint() {
  local dir out rc before
  dir=$(new_case reboot-live rl63)
  add_ship_task "$dir" rl63 claude
  printf 'claude' > "$dir/fake/command"
  printf '%s' "$dir/wt" > "$dir/fake/cwd"
  start_scope_sleeper
  write_active_reused_scope "$dir" rl63 "$(scope_lstart_at $((SCOPE_BOOT_TIME - 3600)))" boot-prior
  before=$(cat "$dir/home/state/rl63.process-scope")
  set_boot_overlays boot-now
  out=$(run_spawn "$dir" rl63 --relaunch --harness claude); rc=$?
  unset_boot_overlays
  expect_code 1 "$rc" "a live agent must still refuse even with a proved prior-boot scope"
  assert_contains "$out" "positively agent-free endpoint" \
    "agent-presence should block independently of prior-boot recovery"
  assert_scope_sleeper_alive
  [ "$(cat "$dir/home/state/rl63.process-scope")" = "$before" ] \
    || fail "agent-presence refusal mutated the prior-boot process-scope record"
  pass "fm-spawn --relaunch: agent-presence still blocks independently of prior-boot recovery"
}

test_pre_reboot_spawn_relaunch_still_requires_the_recorded_worktree() {
  local dir out rc before
  dir=$(new_case reboot-cwd rl64)
  add_ship_task "$dir" rl64 claude
  printf 'zsh' > "$dir/fake/command"
  printf '%s' "$dir/proj" > "$dir/fake/cwd"
  start_scope_sleeper
  write_active_reused_scope "$dir" rl64 "$(scope_lstart_at $((SCOPE_BOOT_TIME - 3600)))" boot-prior
  before=$(cat "$dir/home/state/rl64.process-scope")
  set_boot_overlays boot-now
  out=$(run_spawn "$dir" rl64 --relaunch --harness claude); rc=$?
  unset_boot_overlays
  expect_code 1 "$rc" "a pane outside the worktree must still refuse even with a proved prior-boot scope"
  assert_contains "$out" "not its recorded worktree" \
    "cwd should block independently of prior-boot recovery"
  assert_scope_sleeper_alive
  [ "$(cat "$dir/home/state/rl64.process-scope")" = "$before" ] \
    || fail "cwd refusal mutated the prior-boot process-scope record"
  pass "fm-spawn --relaunch: endpoint cwd still blocks independently of prior-boot recovery"
}

test_pre_reboot_symlinked_scope_refuses_without_mutation() {
  local dir out rc
  dir=$(new_case reboot-symlink rl65)
  add_ship_task "$dir" rl65 claude
  prepare_dead_relaunch "$dir" rl65
  start_scope_sleeper
  write_active_reused_scope "$dir" rl65 "$(scope_lstart_at $((SCOPE_BOOT_TIME - 3600)))" boot-prior
  mv "$dir/home/state/rl65.process-scope" "$dir/home/state/rl65.process-scope.real"
  ln -s "$dir/home/state/rl65.process-scope.real" "$dir/home/state/rl65.process-scope"
  set_boot_overlays boot-now
  out=$(run_spawn "$dir" rl65 --relaunch --harness claude); rc=$?
  unset_boot_overlays
  expect_code 1 "$rc" "a symlinked process-scope record must refuse"
  [ -L "$dir/home/state/rl65.process-scope" ] \
    || fail "symlink refusal replaced the process-scope symlink"
  grep -qx 'status=active' "$dir/home/state/rl65.process-scope.real" \
    || fail "symlink refusal mutated the backing process-scope record"
  assert_scope_sleeper_alive
  pass "fm-spawn --relaunch: a symlinked process-scope record still refuses without mutation"
}

test_pre_reboot_token_mismatch_refuses_without_mutation() {
  local dir out rc before
  dir=$(new_case reboot-token rl66)
  add_ship_task "$dir" rl66 claude
  prepare_dead_relaunch "$dir" rl66
  start_scope_sleeper
  write_active_reused_scope "$dir" rl66 "$(scope_lstart_at $((SCOPE_BOOT_TIME - 3600)))" boot-prior
  sed 's/^token=test-rl66$/token=other-token/' \
    "$dir/home/state/rl66.process-scope" > "$dir/home/state/rl66.process-scope.tmp"
  mv "$dir/home/state/rl66.process-scope.tmp" "$dir/home/state/rl66.process-scope"
  before=$(cat "$dir/home/state/rl66.process-scope")
  set_boot_overlays boot-now
  out=$(run_spawn "$dir" rl66 --relaunch --harness claude); rc=$?
  unset_boot_overlays
  expect_code 1 "$rc" "a token-mismatched process-scope record must refuse"
  assert_contains "$out" "stale or malformed process-scope record" \
    "token mismatch should keep the existing record refusal"
  [ "$(cat "$dir/home/state/rl66.process-scope")" = "$before" ] \
    || fail "token mismatch mutated the process-scope record"
  assert_scope_sleeper_alive
  pass "fm-spawn --relaunch: a token-mismatched process-scope record still refuses without mutation"
}

test_same_harness_relaunch_keeps_identity_and_reuses_the_endpoint
test_relaunch_preserves_durable_task_metadata
test_relaunch_serializes_concurrent_durable_metadata_publication
test_disabled_relaunch_clears_prior_trace_context
test_relaunch_appends_the_progress_note_to_the_instructions
test_relaunch_requires_a_note_for_a_ship_task
test_harness_switch_moves_the_record_and_clears_prior_wiring
test_agy_harness_switch_removes_the_plugin_directory
test_scoped_harness_switch_to_agy
test_unscoped_harness_switch_to_agy_refuses_before_exit
test_portable_scope_harness_switch_to_agy_refuses_before_exit
test_agy_relaunch_reaps_the_prior_process_scope
test_harness_switch_does_not_carry_the_old_profile_axes
test_harness_switch_resolves_a_prefixed_recorded_harness
test_prefixed_recorded_harness_requires_explicit_replacement
test_same_harness_relaunch_keeps_the_profile_axes
test_explicit_model_wins_over_the_recorded_one
test_relaunch_onto_an_unverified_harness_is_refused
test_prior_harness_turnend_registry_entry_is_cleared
test_wiring_removal_failure_refuses_before_replacement_arm
test_turnend_auth_paths_are_owned_by_the_control_adapter
test_secondmate_relaunch_picks_up_the_configured_harness_pin
test_secondmate_relaunch_ignores_invalid_configured_effort_before_stop
test_secondmate_relaunch_onto_a_crewmate_only_adapter_refuses_before_stop
test_explicit_secondmate_harness_ignores_configured_profile_axes
test_ship_relaunch_ignores_the_crew_harness_config
test_spawn_relaunch_without_a_harness_reuses_the_recorded_one
test_prefixed_prior_harness_wiring_is_still_retired
test_muse_session_binding_is_retired_on_a_harness_switch
test_cursor_session_binding_is_retired_on_a_harness_switch
test_missing_worktree_refuses_before_stopping_anything
test_missing_instructions_refuse_before_stopping_anything
test_checkpoint_refusal_leaves_the_record_byte_identical
test_checkpoint_refuses_uninspectable_head_and_status
test_launch_failure_keeps_the_prior_record_and_reports_it
test_prepublication_failure_keeps_concurrent_durable_metadata
test_post_publication_launch_failure_keeps_the_new_record
test_stop_transport_failure_reconciles_a_dead_agent
test_complete_journal_failure_rolls_back_from_durable_phase
test_prepublication_abort_retires_replacement_wiring_and_busy_state
test_journal_records_the_checkpoint_it_proved
test_secondmate_relaunch_checkpoints_child_work_and_spares_the_charter
test_secondmate_relaunch_refuses_an_unmarked_home
test_secondmate_checkpoint_refuses_unreadable_child_state
test_concurrent_relaunch_is_refused
test_direct_spawn_relaunch_participates_in_the_lifecycle_lock
test_promotion_participates_in_the_lifecycle_lock_before_metadata_resolution
test_spawn_relaunch_refuses_a_live_agent
test_spawn_relaunch_refuses_contradicting_flags
test_spawn_relaunch_refuses_an_unrecorded_task
test_spawn_relaunch_refuses_a_pane_outside_the_worktree
test_pre_reboot_relaunch_does_not_signal_a_reused_pid
test_pre_reboot_spawn_relaunch_does_not_signal_a_reused_pid
test_current_boot_identity_mismatch_still_refuses
test_legacy_darwin_pre_boot_lstart_relaunches
test_legacy_equal_lstart_refuses
test_legacy_after_lstart_refuses
test_legacy_unparseable_lstart_refuses
test_portable_boot_generation_mismatch_relaunches
test_matching_boot_generation_refuses_even_with_pre_boot_lstart
test_missing_boot_generation_without_legacy_refuses
test_unreadable_boot_generation_uses_legacy_when_lstart_predates
test_unreadable_boot_generation_without_legacy_refuses
test_empty_scope_relaunch_is_idempotent
test_pre_reboot_spawn_relaunch_still_requires_an_agent_free_endpoint
test_pre_reboot_spawn_relaunch_still_requires_the_recorded_worktree
test_pre_reboot_symlinked_scope_refuses_without_mutation
test_pre_reboot_token_mismatch_refuses_without_mutation
test_clock_ambiguous_boot_time_refuses
test_mixed_identity_without_generation_refuses
test_contradictory_process_scope_records_refuse_without_mutation
test_scope_launch_preserves_token_for_escaped_descendants
