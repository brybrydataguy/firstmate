#!/usr/bin/env bash
# Behavior tests for the verified Antigravity CLI (agy) crewmate adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
HARNESS_SH="$ROOT/bin/fm-harness.sh"
BOOTSTRAP_SH="$ROOT/bin/fm-bootstrap.sh"
TMUX_LIB="$ROOT/bin/fm-tmux-lib.sh"
BACKEND_SH="$ROOT/bin/fm-backend.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy-harness)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf "%s\n" "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf "firstmate\n"; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|kill-window) exit 0 ;;
  new-session|new-window)
    [ -z "${FM_FAKE_ENDPOINT_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_ENDPOINT_LOG"
    exit 0
    ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf "%s\n" "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh agy
  cat > "$fakebin/sqlite3" <<'SH'
#!/usr/bin/env bash
[ -n "${FM_AGY_SQLITE_STATE:-}" ] && [ -f "$FM_AGY_SQLITE_STATE" ] || exit 1
cat "$FM_AGY_SQLITE_STATE"
SH
  chmod +x "$fakebin/sqlite3"
  printf "%s\n" "$fakebin"
}

make_spawn_case() {
  local name=$1 explicit_id=${2:-} case_dir home proj wt fakebin launchlog id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id=${explicit_id:-"agy-$name-x1"}
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf "brief for %s\n" "$id" > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf "%s|%s|%s|%s|%s|%s|%s\n" "$case_dir" "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id"
}

run_agy_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 launchlog=$5 id=$6 launch_path
  shift 6
  : > "$launchlog"
  : > "$launchlog.endpoints"
  launch_path=${FM_AGY_TEST_PATH:-$fakebin:$PATH}
  FM_ROOT_OVERRIDE="" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_ENDPOINT_LOG="$launchlog.endpoints" PATH="$launch_path" \
    "$SPAWN" "$id" "$proj" agy --mode no-mistakes --yolo off "$@" 2>&1
}

test_agy_harness_detection() {
  local out
  out=$(ANTIGRAVITY_LS_VERSION=cli-1.1.19 "$HARNESS_SH")
  [ "$out" = "agy" ] || fail "harness detection failed on ANTIGRAVITY_LS_VERSION marker: $out"

  out=$(ANTIGRAVITY_SOURCE_METADATA='{"conversationId":"123"}' "$HARNESS_SH")
  [ "$out" = "agy" ] || fail "harness detection failed on ANTIGRAVITY_SOURCE_METADATA marker: $out"

  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$ROOT/bin/fm-session-lock-lib.sh"
  if fm_harness_process_matches agy agy; then
    fail "worker-only agy was accepted as a primary session-lock owner"
  fi
  if fm_harness_path_name /opt/homebrew/bin/agy >/dev/null; then
    fail "worker-only agy was present in the primary path-identity table"
  fi
  pass "fm-harness detects agy without granting primary session ownership"
}

test_agy_default_model_and_launch_template() {
  local rec case_dir home proj wt fakebin launchlog id out launched meta_file
  rec=$(make_spawn_case default-model)
  IFS="|" read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id")
  assert_contains "$out" "spawned $id harness=agy" "agy spawn did not report success: $out"

  launched=$(cat "$launchlog")
  assert_contains "$launched" "'$fakebin/agy' --dangerously-skip-permissions --model 'gemini-3.7-flash-high' --prompt-interactive" \
    "agy launch command did not match expected template with default model: $launched"
  assert_contains "$launched" "env -u CURSOR_AGENT -u CURSOR_INVOKED_AS" \
    "agy launch did not clear inherited Cursor markers: $launched"
  assert_contains "$launched" "env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS" \
    "agy launch did not clear inherited Claude, Pi, and Grok markers: $launched"

  meta_file="$home/state/$id.meta"
  assert_contains "$(cat "$meta_file")" "model=gemini-3.7-flash-high" "meta file did not record default model: $(cat "$meta_file")"
  pass "fm-spawn: agy defaults to gemini-3.7-flash-high and uses --prompt-interactive"
}

test_agy_effort_flag_handling() {
  local rec case_dir home proj wt fakebin launchlog id out launched

  # 1. Variant model ID with explicit effort: do NOT emit conflicting/redundant --effort
  rec=$(make_spawn_case variant-effort)
  IFS="|" read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id" --model gemini-3.7-flash-high --effort high)
  launched=$(cat "$launchlog")
  assert_contains "$launched" "--model 'gemini-3.7-flash-high'" "launch did not include model: $launched"
  assert_not_contains "$launched" "--effort" "launch command emitted redundant/conflicting --effort for variant model ID"

  # 2. Base model ID with effort: emits --effort <effort>
  rec=$(make_spawn_case base-effort)
  IFS="|" read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id" --model gemini-3.7-flash --effort medium)
  launched=$(cat "$launchlog")
  assert_contains "$launched" "--model 'gemini-3.7-flash' --effort 'medium'" "launch command did not include resolved effort: $launched"

  # 3. Base model ID with unsupported xhigh or max effort: capped to high
  rec=$(make_spawn_case capped-effort)
  IFS="|" read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id" --model gemini-3.7-flash --effort xhigh)
  launched=$(cat "$launchlog")
  assert_contains "$launched" "--model 'gemini-3.7-flash' --effort 'high'" "launch command did not cap xhigh to high: $launched"

  rec=$(make_spawn_case capped-max)
  IFS="|" read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id" --model gemini-3.7-flash --effort max)
  launched=$(cat "$launchlog")
  assert_contains "$launched" "--model 'gemini-3.7-flash' --effort 'high'" "launch command did not cap max to high: $launched"

  rec=$(make_spawn_case implicit-low)
  IFS="|" read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id" --effort low)
  launched=$(cat "$launchlog")
  assert_contains "$launched" "--model 'gemini-3.7-flash-low'" "explicit low effort did not select the low model variant: $launched"
  assert_contains "$(cat "$home/state/$id.meta")" "effort=low" "meta did not retain explicit low effort"

  rec=$(make_spawn_case implicit-medium)
  IFS="|" read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id" --effort medium)
  launched=$(cat "$launchlog")
  assert_contains "$launched" "--model 'gemini-3.7-flash-medium'" "explicit medium effort did not select the medium model variant: $launched"

  rec=$(make_spawn_case conflicting-effort)
  IFS="|" read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id" --model gemini-3.7-flash-high --effort low)
  expect_code 1 $? "a conflicting model variant and effort should be refused"
  assert_contains "$out" "conflicts with requested effort 'low'" "profile conflict refusal was not actionable: $out"
  [ ! -s "$launchlog.endpoints" ] || fail "profile conflict created an endpoint before refusing"
  pass "fm-spawn: agy handles variant model suppression and effort capping appropriately"
}

run_agy_hook() {
  local hooks=$1 event=$2 payload=${3:-'{}'} cmd
  cmd=$(jq -r ".[\"fm-firstmate-busy\"][\"$event\"][0].command" "$hooks")
  [ -n "$cmd" ] && [ "$cmd" != null ] || fail "agy plugin lacks $event"
  printf '%s\n' "$payload" | sh -c "$cmd"
}

test_agy_semantic_busy_lifecycle() {
  local rec case_dir home proj wt fakebin launchlog id out hooks state store conversation transcript db task_state payload updater
  rec=$(make_spawn_case semantic-busy)
  IFS="|" read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id")
  expect_code 0 $? "agy spawn should install semantic lifecycle wiring: $out"
  hooks="$wt/.agents/plugins/fm-firstmate-busy-$id/hooks.json"
  state="$home/state"
  assert_present "$hooks" "agy spawn did not write its isolated lifecycle plugin"
  jq -e . "$hooks" >/dev/null || fail "agy lifecycle plugin is not valid JSON"
  [ "$(fm_busy_classify tmux fake:w agy "$id" "$state")" = "busy fm-spawn" ] \
    || fail "agy launch turn was not seeded busy"
  rm -f "$state/$id.turn-ended"
  store="$case_dir/agy-store"
  conversation=conversation-1
  transcript="$store/brain/$conversation/.system_generated/logs/transcript.jsonl"
  db="$store/conversations/$conversation.db"
  task_state="$case_dir/background-count"
  mkdir -p "$(dirname "$transcript")" "$(dirname "$db")"
  : > "$transcript"
  : > "$db"
  printf '1\n' > "$task_state"
  payload=$(jq -nc --arg conversation "$conversation" --arg transcript "$transcript" \
    '{fullyIdle:false,conversationId:$conversation,transcriptPath:$transcript}')
  ( sleep 1; printf '0\n' > "$task_state" ) &
  updater=$!
  out=$(FM_AGY_SQLITE_STATE="$task_state" run_agy_hook "$hooks" Stop "$payload") \
    || fail "agy active Stop hook failed: $out"
  wait "$updater"
  printf '%s' "$out" | jq -e '.decision == "allow"' >/dev/null \
    || fail "agy active Stop hook did not finish after background completion: $out"
  [ -f "$state/$id.turn-ended" ] || fail "agy background completion did not touch the turn-end notification"
  [ "$(fm_busy_classify tmux fake:w agy "$id" "$state")" = "idle agy-hook" ] \
    || fail "agy background completion did not settle semantic state"
  rm -f "$state/$id.turn-ended"
  out=$(run_agy_hook "$hooks" PreInvocation) || fail "agy PreInvocation hook failed: $out"
  [ "$(fm_busy_classify tmux fake:w agy "$id" "$state")" = "busy agy-hook" ] \
    || fail "agy PreInvocation hook did not reopen semantic state"
  out=$(run_agy_hook "$hooks" Stop '{}') || fail "agy malformed Stop hook failed: $out"
  printf '%s' "$out" | jq -e '.decision == "allow"' >/dev/null \
    || fail "agy malformed Stop hook did not terminate defensively: $out"
  assert_absent "$state/$id.turn-ended" "agy Stop hook published a turn end without fullyIdle true"
  [ "$(fm_busy_classify tmux fake:w agy "$id" "$state")" = "busy agy-hook" ] \
    || fail "agy Stop hook cleared semantic state without fullyIdle true"
  out=$(run_agy_hook "$hooks" Stop '{"fullyIdle":true}') || fail "agy fully-idle Stop hook failed: $out"
  [ -f "$state/$id.turn-ended" ] || fail "agy Stop hook did not touch the turn-end notification"
  [ "$(fm_busy_classify tmux fake:w agy "$id" "$state")" = "idle agy-hook" ] \
    || fail "agy Stop hook did not settle semantic state"
  out=$(run_agy_hook "$hooks" PreInvocation) || fail "agy PreInvocation hook failed: $out"
  printf '%s' "$out" | jq -e 'type == "object"' >/dev/null \
    || fail "agy PreInvocation hook did not return JSON: $out"
  [ "$(fm_busy_classify tmux fake:w agy "$id" "$state")" = "busy agy-hook" ] \
    || fail "agy PreInvocation hook did not open semantic state"
  pass "fm-spawn and fm-busy-lib: agy lifecycle hooks observe background completion"
}

test_agy_manifest_name_accepts_dotted_task_id() {
  local rec case_dir home proj wt fakebin launchlog id out manifest
  rec=$(make_spawn_case dotted-id agy.fix.v1)
  IFS="|" read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id")
  expect_code 0 $? "agy spawn should accept a path-safe dotted task ID: $out"
  manifest="$wt/.agents/plugins/fm-firstmate-busy-$id/plugin.json"
  jq -e '.name == "fm-firstmate-busy"' "$manifest" >/dev/null \
    || fail "agy plugin manifest name is not schema-safe for a dotted task ID: $(cat "$manifest")"
  pass "fm-spawn: agy plugin manifest supports dotted task IDs"
}

test_agy_plugin_collisions_are_refused() {
  local rec case_dir home proj wt fakebin launchlog id out plugin exclude
  rec=$(make_spawn_case plugin-collision)
  IFS="|" read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  plugin="$wt/.agents/plugins/fm-firstmate-busy-$id"
  mkdir -p "$plugin"
  printf 'project-owned\n' > "$plugin/plugin.json"
  exclude=$(git -C "$wt" rev-parse --git-path info/exclude)
  printf '/.agents/plugins/fm-firstmate-busy-%s/\n' "$id" >> "$exclude"
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id")
  expect_code 1 $? "agy spawn should refuse an existing plugin directory"
  assert_contains "$out" "plugin path already exists" "agy collision refusal was not actionable: $out"
  [ "$(cat "$plugin/plugin.json")" = project-owned ] || fail "agy spawn overwrote a project-owned plugin manifest"
  assert_absent "$plugin/hooks.json" "agy spawn wrote hooks into a project-owned plugin directory"
  assert_present "$home/state/$id.meta" "agy plugin collision did not preserve recovery metadata"
  assert_contains "$(cat "$home/state/$id.meta")" "worktree=$wt" "agy recovery metadata omitted the allocated worktree"
  assert_contains "$(cat "$home/state/$id.meta")" "harness=unknown" "agy collision recovery metadata claimed ownership of the colliding plugin"

  rec=$(make_spawn_case plugin-symlink)
  IFS="|" read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  mkdir -p "$wt/.agents/plugins" "$wt/agy-plugin-target"
  printf 'target-owned\n' > "$wt/agy-plugin-target/sentinel"
  plugin="$wt/.agents/plugins/fm-firstmate-busy-$id"
  ln -s ../../agy-plugin-target "$plugin"
  exclude=$(git -C "$wt" rev-parse --git-path info/exclude)
  printf '/.agents/plugins/fm-firstmate-busy-%s\n/agy-plugin-target/\n' "$id" >> "$exclude"
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id")
  expect_code 1 $? "agy spawn should refuse a symlinked plugin directory"
  assert_contains "$out" "plugin path is a symlink" "agy symlink refusal was not actionable: $out"
  [ "$(cat "$wt/agy-plugin-target/sentinel")" = target-owned ] || fail "agy spawn changed the symlink target"
  assert_absent "$wt/agy-plugin-target/plugin.json" "agy spawn followed the plugin symlink for its manifest"
  assert_absent "$wt/agy-plugin-target/hooks.json" "agy spawn followed the plugin symlink for its hooks"
  assert_present "$home/state/$id.meta" "agy plugin symlink refusal did not preserve recovery metadata"
  pass "fm-spawn: agy plugin installation refuses collisions and symlinks"
}

test_agy_post_allocation_failure_preserves_recovery_metadata() {
  local rec case_dir home proj wt fakebin launchlog id out plugin meta
  rec=$(make_spawn_case busy-arm-failure)
  IFS="|" read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  mkdir "$home/state/$id.busy-state.lock"
  out=$(FM_BUSY_LOCK_STALE_SECS=3600 \
    run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id")
  expect_code 1 $? "agy spawn should fail when semantic busy-state arming fails"
  assert_contains "$out" "failed to arm the busy-state contract" \
    "agy busy-state failure was not actionable: $out"
  [ -s "$launchlog.endpoints" ] || fail "agy busy-state failure did not exercise a post-allocation path"
  meta="$home/state/$id.meta"
  assert_present "$meta" "agy busy-state failure did not preserve recovery metadata"
  assert_contains "$(cat "$meta")" "worktree=$wt" \
    "agy busy-state recovery metadata omitted the allocated worktree"
  assert_contains "$(cat "$meta")" "harness=unknown" \
    "agy busy-state recovery metadata claimed an incompletely installed adapter"
  plugin="$wt/.agents/plugins/fm-firstmate-busy-$id"
  [ ! -e "$plugin" ] && [ ! -L "$plugin" ] \
    || fail "agy busy-state failure left a partial plugin installation"
  pass "fm-spawn: post-allocation agy failures preserve recovery metadata"
}

test_agy_missing_binary_refuses_before_endpoint_creation() {
  local rec case_dir home proj wt fakebin launchlog id out
  rec=$(make_spawn_case missing-binary)
  IFS="|" read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  rm -f "$fakebin/agy"
  out=$(FM_AGY_TEST_PATH="$fakebin:/usr/bin:/bin" \
    run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id")
  expect_code 1 $? "missing agy should refuse the spawn"
  assert_contains "$out" "agy executable not found on PATH" "missing binary refusal did not name agy: $out"
  [ ! -s "$launchlog.endpoints" ] || fail "missing agy created an endpoint before refusing"
  assert_absent "$home/state/$id.meta" "missing agy published task metadata"
  pass "fm-spawn: missing agy refuses before endpoint creation"
}

test_agy_refuses_secondmate() {
  local case_dir home fakebin id out
  case_dir="$TMP_ROOT/secondmate"
  home="$case_dir/home"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id=agy-secondmate-x1
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'charter\n' > "$home/data/$id/brief.md"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" agy --secondmate 2>&1)
  expect_code 1 $? "agy should be refused for secondmate work"
  assert_contains "$out" "crewmate/scout adapter only" "agy secondmate refusal did not explain the capability boundary: $out"
  pass "fm-spawn: agy is restricted to crewmate and scout work"
}

test_agy_busy_matching_and_liveness() {
  # shellcheck source=bin/fm-tmux-lib.sh
  . "$TMUX_LIB"

  # Busy samples
  printf "● Bash(ls -la)\n⣾  Loading...\nesc to cancel\n" | fm_busy_lines_match agy || fail "agy busy footer did not match"

  # Idle samples
  if printf "? for shortcuts                                      Gemini 3.7 Flash · high\n" | fm_busy_lines_match agy; then
    fail "agy idle footer falsely matched as busy"
  fi
  if printf "Completed output mentions ⣾ Loading... as ordinary transcript text\n" | fm_busy_lines_match agy; then
    fail "agy transcript text falsely matched as a live delivery-busy footer"
  fi

  # shellcheck source=bin/backends/tmux.sh
  . "$BACKEND_SH"
  fm_backend_source tmux
  tmux() {
    case "$*" in
      *"list-windows"*) printf "dummy\n"; return 0 ;;
      *"#{pane_current_command}"*) printf "%s\n" "$TEST_COMM"; return 0 ;;
    esac
    return 0
  }
  TEST_COMM=agy
  [ "$(fm_backend_tmux_agent_state "firstmate:dummy")" = "alive" ] || fail "tmux agent state did not report alive for agy"

  TEST_COMM=/opt/homebrew/bin/agy
  [ "$(fm_backend_tmux_agent_state "firstmate:dummy")" = "alive" ] || fail "tmux agent state did not report alive for full path agy"
  pass "fm-tmux-lib and tmux backend: agy busy signature and liveness detection verified"
}

test_agy_crew_dispatch_validation() {
  local case_dir home config out
  case_dir="$TMP_ROOT/dispatch-val"
  home="$case_dir/home"
  config="$home/config"
  mkdir -p "$config"

  # Valid agy profile in crew-dispatch.json
  printf "%s\n" '{"default":{"harness":"agy","model":"gemini-3.7-flash-high","effort":"high"}}' > "$config/crew-dispatch.json"
  out=$(FM_HOME="$home" "$BOOTSTRAP_SH" 2>&1)
  assert_not_contains "$out" "CREW_DISPATCH: invalid" "crew-dispatch was rejected"

  printf "%s\n" '{"default":{"harness":"agy","model":"gemini-3.7-flash","effort":"xhigh"}}' > "$config/crew-dispatch.json"
  out=$(FM_HOME="$home" "$BOOTSTRAP_SH" 2>&1)
  assert_not_contains "$out" "CREW_DISPATCH: invalid" "crew-dispatch rejected an effort that agy caps to high"

  # Invalid effort for agy
  printf "%s\n" '{"default":{"harness":"agy","effort":"bad-effort"}}' > "$config/crew-dispatch.json"
  out=$(FM_HOME="$home" "$BOOTSTRAP_SH" 2>&1)
  assert_contains "$out" "CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: agy:bad-effort" \
    "bootstrap did not reject invalid agy effort: $out"
  pass "fm-bootstrap: validates agy harness and accepted efforts in crew-dispatch.json"
}

test_agy_harness_detection
test_agy_default_model_and_launch_template
test_agy_effort_flag_handling
test_agy_semantic_busy_lifecycle
test_agy_manifest_name_accepts_dotted_task_id
test_agy_plugin_collisions_are_refused
test_agy_post_allocation_failure_preserves_recovery_metadata
test_agy_missing_binary_refuses_before_endpoint_creation
test_agy_refuses_secondmate
test_agy_busy_matching_and_liveness
test_agy_crew_dispatch_validation
