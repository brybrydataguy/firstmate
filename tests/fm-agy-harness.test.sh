#!/usr/bin/env bash
# Behavior tests for the verified Antigravity CLI (agy) crewmate adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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
  has-session|new-session|new-window|kill-window) exit 0 ;;
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
  printf "%s\n" "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin launchlog id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="agy-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf "brief for %s\n" "$id" > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf "%s|%s|%s|%s|%s|%s|%s\n" "$case_dir" "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id"
}

run_agy_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 launchlog=$5 id=$6
  shift 6
  : > "$launchlog"
  FM_ROOT_OVERRIDE="" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
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
  printf "agy\n" | grep -qE "$FM_HARNESS_RE" || fail "FM_HARNESS_RE did not match agy"
  printf "foo-agy-bar\n" | grep -qE "$FM_HARNESS_RE" || fail "FM_HARNESS_RE did not match *agy*"
  pass "fm-harness and session-lock: detects agy markers and process identity"
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
  assert_contains "$launched" "agy --dangerously-skip-permissions --model 'gemini-3.7-flash-high' --prompt-interactive" \
    "agy launch command did not match expected template with default model: $launched"

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
  assert_no_grep "\-\effort" "$launchlog" "launch command emitted redundant/conflicting --effort for variant model ID"

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
  pass "fm-spawn: agy handles variant model suppression and effort capping appropriately"
}

test_agy_busy_matching_and_liveness() {
  # shellcheck source=bin/fm-tmux-lib.sh
  . "$TMUX_LIB"

  # Busy samples
  printf "● Bash(ls -la)\n⣾  Loading...\nesc to cancel\n" | fm_busy_lines_match agy || fail "agy busy lines did not match"
  printf "Thought for 4s\n⣽  Thinking...\nesc to cancel\n" | fm_busy_lines_match agy || fail "agy thinking lines did not match"

  # Idle samples
  if printf "? for shortcuts                                      Gemini 3.7 Flash · high\n" | fm_busy_lines_match agy; then
    fail "agy idle footer falsely matched as busy"
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
test_agy_busy_matching_and_liveness
test_agy_crew_dispatch_validation
