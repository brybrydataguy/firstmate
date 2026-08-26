#!/usr/bin/env bash
# Tests for bin/fm-update.sh: fast-forward-only self-update of a running
# firstmate repo and every registered secondmate home.
#
# The guarantees under test mirror fm-fleet-sync.sh and prime directive #3:
#   - The running firstmate repo (on its default branch) fast-forwards from
#     origin; a leased secondmate home (detached HEAD on the default branch)
#     fast-forwards the same way.
#   - FAST-FORWARD ONLY: a dirty, diverged, offline, or wrong-branch target is
#     skipped and reported, never forced or stashed, so unlanded work survives.
#   - The update is a single-parent fast-forward (never a merge commit) and a
#     fast-forward of one worktree never disturbs another worktree's checkout
#     or the shared default branch.
#   - The caller-action summary is correct: reread-firstmate flips to yes only
#     when the instruction surface (AGENTS.md / bin / .agents/skills) changed, and
#     nudge-secondmates lists exactly the live secondmates that advanced.
#   - Secondmate homes resolve from both state/<id>.meta and the
#     data/secondmates.md registry, deduped, and the firstmate repo is never
#     re-processed as one of its own secondmates.
#   - FORK TOPOLOGY (config/upstream-remote): the authoritative upstream's
#     default branch lands on the personal fork by a FAST-FORWARD PUSH before
#     the home advances, the home then fast-forwards to the fork's merged
#     custom head, and real divergence, ambiguous remote topology, or an
#     unconfigured upstream is refused and reported with both published
#     branches left exactly where they were.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UPDATE="$ROOT/bin/fm-update.sh"

# Deterministic, isolated git identity for fixture commits.
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-update-tests)

# Build a fresh world: a bare origin seeded with one commit, a firstmate repo
# clone checked out on main, and a home dir with state/ and data/. Echoes the
# world dir. Files seeded: AGENTS.md, README.md, bin/tool.sh, and an internal skill note.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data"
  # Fresh watcher beacon keeps fm-guard quiet.
  touch "$w/home/state/.last-watcher-beat"

  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null

  printf 'v1\n' > "$w/seed/AGENTS.md"
  printf 'r1\n' > "$w/seed/README.md"
  mkdir -p "$w/seed/bin" "$w/seed/.agents/skills"
  printf 'echo a\n' > "$w/seed/bin/tool.sh"
  printf 's1\n' > "$w/seed/.agents/skills/note.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main

  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true

  printf '%s\n' "$w"
}

# Add a secondmate home as a DETACHED worktree of the firstmate repo (matching
# how treehouse leases a secondmate home), plus its state meta. Args: world id.
add_sm() {
  local w=$1 id=$2
  git -C "$w/main" worktree add -q --detach "$w/$id" main
  {
    printf 'window=main:fm-%s\n' "$id"
    printf 'kind=secondmate\n'
    printf 'home=%s/%s\n' "$w" "$id"
  } > "$w/home/state/$id.meta"
  printf '%s\n' "$id" > "$w/$id/.fm-secondmate-home"
}

# Advance origin by one commit. mode=instr changes the instruction surface
# (AGENTS.md, bin, .agents/skills) plus README; mode=readme changes only README.
bump_origin() {
  local w=$1 mode=$2
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'r-%s\n' "$mode" >> "$w/seed/README.md"
  if [ "$mode" = instr ]; then
    printf 'v2\n' > "$w/seed/AGENTS.md"
    printf 'echo b\n' > "$w/seed/bin/tool.sh"
    printf 's2\n' > "$w/seed/.agents/skills/note.md"
  fi
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "bump-$mode"
  git -C "$w/seed" push -q origin main
}

run_update() {
  local w=$1
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>/dev/null
}

# --- fork-topology fixtures ------------------------------------------------
# A world where the running home follows a personal FORK as `origin` while an
# authoritative UPSTREAM repository stays the source of shared changes. Both
# published repos are bare, so every assertion below reads real remote refs
# rather than a local mirror of them. Layout:
#   upstream.git   authoritative upstream (bare)
#   fork.git       personal fork, the home's origin (bare)
#   upstream-seed  clone used to advance upstream
#   fork-seed      clone used to advance the fork with custom work
#   main           the running firstmate repo: origin=fork.git, upstream=upstream.git
#   home/config/upstream-remote  names the upstream remote
new_fork_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data" "$w/home/config"
  touch "$w/home/state/.last-watcher-beat"

  git init -q --bare "$w/upstream.git"
  git -C "$w/upstream.git" symbolic-ref HEAD refs/heads/main
  git init -q --bare "$w/fork.git"
  git -C "$w/fork.git" symbolic-ref HEAD refs/heads/main

  git clone -q "$w/upstream.git" "$w/upstream-seed" 2>/dev/null
  printf 'v1\n' > "$w/upstream-seed/AGENTS.md"
  printf 'r1\n' > "$w/upstream-seed/README.md"
  mkdir -p "$w/upstream-seed/bin" "$w/upstream-seed/.agents/skills"
  printf 'echo a\n' > "$w/upstream-seed/bin/tool.sh"
  printf 's1\n' > "$w/upstream-seed/.agents/skills/note.md"
  git -C "$w/upstream-seed" add -A
  git -C "$w/upstream-seed" commit -qm c1
  git -C "$w/upstream-seed" push -q origin main
  # The fork starts as a faithful copy of upstream, exactly like a fresh fork.
  git -C "$w/upstream-seed" push -q "$w/fork.git" main

  git clone -q "$w/fork.git" "$w/fork-seed" 2>/dev/null
  git clone -q "$w/fork.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true
  git -C "$w/main" remote add upstream "$w/upstream.git"
  printf 'upstream\n' > "$w/home/config/upstream-remote"

  printf '%s\n' "$w"
}

# Advance the authoritative upstream by one commit that changes the watched
# instruction surface, so every fork test also exercises the reread signal.
# <note> keeps repeat calls in one world distinct commits.
bump_upstream() {
  local w=$1 note=$2
  git -C "$w/upstream-seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'u-%s\n' "$note" >> "$w/upstream-seed/README.md"
  printf 'v-%s\n' "$note" > "$w/upstream-seed/AGENTS.md"
  printf 'echo %s\n' "$note" > "$w/upstream-seed/bin/tool.sh"
  git -C "$w/upstream-seed" add -A
  git -C "$w/upstream-seed" commit -qm "upstream-$note"
  git -C "$w/upstream-seed" push -q origin main
}

# Land one custom commit on the fork - the captain's own reviewed change.
bump_fork() {
  local w=$1 note=$2
  git -C "$w/fork-seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'custom-%s\n' "$note" >> "$w/fork-seed/README.md"
  printf 'custom-%s\n' "$note" > "$w/fork-seed/.agents/skills/note.md"
  git -C "$w/fork-seed" add -A
  git -C "$w/fork-seed" commit -qm "fork-$note"
  git -C "$w/fork-seed" push -q origin main
}

published_head() {  # <bare-repo> -> the commit its main branch publishes
  git -C "$1" rev-parse refs/heads/main
}

# --- T1: main + secondmate behind, instruction change; FF, not a merge ------
# Combines the former T1 (fast-forward + reread + nudge signalling) and T2
# (the advance is a single-parent fast-forward, never a merge commit) into one
# world so both contracts are proven against the same update run.
test_updates_main_and_secondmate() {
  local w out
  w=$(new_world t1)
  add_sm "$w" sm1
  bump_origin "$w" instr

  out=$(run_update "$w")

  # A classic single-remote home has no config dir at all and stays unchanged.
  assert_contains "$out" "upstream-sync: not configured" "no fork topology configured"
  assert_contains "$out" "firstmate: updated " "firstmate fast-forwarded"
  assert_contains "$out" "secondmate sm1: updated " "secondmate fast-forwarded"
  assert_contains "$out" "reread-firstmate: yes" "instruction change triggers reread"
  assert_contains "$out" "nudge-secondmates: fm-sm1" "updated secondmate is nudged"

  # Fast-forward landed: HEAD == origin/main on both targets.
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(git -C "$w/main" rev-parse origin/main)" ] \
    || fail "firstmate HEAD not at origin/main"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$(git -C "$w/sm1" rev-parse origin/main)" ] \
    || fail "secondmate HEAD not at origin/main"
  # Firstmate stays on its default branch; secondmate stays detached.
  [ "$(git -C "$w/main" symbolic-ref --short HEAD 2>/dev/null)" = "main" ] \
    || fail "firstmate left its default branch"
  git -C "$w/sm1" symbolic-ref -q HEAD >/dev/null \
    && fail "secondmate worktree is no longer detached"
  # A fast-forwarded tip has exactly one parent; a merge commit would have two.
  [ "$(git -C "$w/main" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "firstmate tip is not a single-parent fast-forward"
  [ "$(git -C "$w/sm1" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "secondmate tip is not a single-parent fast-forward"
  pass "T1 main + secondmate fast-forward (single-parent), reread + nudge signalled"
}

# --- T3: README-only change does not trigger a reread ----------------------
test_reread_gate_is_instruction_only() {
  local w out
  w=$(new_world t3)
  add_sm "$w" sm1
  bump_origin "$w" readme

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate still advanced"
  assert_contains "$out" "reread-firstmate: no" "non-instruction change skips reread"
  # The secondmate still advanced, so it is still nudged (update-based nudge).
  assert_contains "$out" "nudge-secondmates: fm-sm1" "advanced secondmate still nudged"
  pass "T3 reread gates on instruction surface, nudge on advancement"
}

# --- T4: dirty secondmate is skipped, its edit preserved -------------------
test_dirty_secondmate_skipped() {
  local w out
  w=$(new_world t4)
  add_sm "$w" sm1
  bump_origin "$w" instr
  printf 'uncommitted local edit\n' >> "$w/sm1/AGENTS.md"

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: dirty working tree" "dirty home skipped"
  assert_not_contains "$out" "fm-sm1" "skipped secondmate is not nudged"
  grep -q 'uncommitted local edit' "$w/sm1/AGENTS.md" \
    || fail "dirty edit was discarded"
  pass "T4 dirty secondmate skipped, local edit preserved"
}

# --- T5: diverged secondmate is skipped, its commit preserved --------------
test_diverged_secondmate_skipped() {
  local w out before
  w=$(new_world t5)
  add_sm "$w" sm1
  # Local commit on the secondmate's detached HEAD makes it diverge from origin.
  printf 'fork work\n' > "$w/sm1/AGENTS.md"
  git -C "$w/sm1" add -A
  git -C "$w/sm1" commit -qm local-work
  before=$(git -C "$w/sm1" rev-parse HEAD)
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: diverged from origin/main" "diverged home skipped"
  assert_not_contains "$out" "fm-sm1" "diverged secondmate is not nudged"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$before" ] \
    || fail "diverged secondmate HEAD moved (unlanded work at risk)"
  pass "T5 diverged secondmate skipped, local commit preserved"
}

# --- T6: idempotent; second run reports already current --------------------
test_idempotent_already_current() {
  local w out
  w=$(new_world t6)
  add_sm "$w" sm1
  bump_origin "$w" instr
  run_update "$w" >/dev/null   # first run advances both

  out=$(run_update "$w")       # second run: nothing to do

  assert_contains "$out" "firstmate: already current" "firstmate already current"
  assert_contains "$out" "secondmate sm1: already current" "secondmate already current"
  assert_contains "$out" "reread-firstmate: no" "no reread when nothing changed"
  assert_contains "$out" "nudge-secondmates: none" "no nudge when nothing advanced"
  pass "T6 idempotent: a second run is a no-op"
}

# --- T7: registry backstop + dedup + self-exclusion, one world -------------
# One world carries every secondmate-resolution edge at once:
#   reg1 - registered in secondmates.md only, NO live meta (registry backstop);
#   sm1  - present in BOTH meta and the registry (must be processed exactly once);
#   selfish - a bogus registry line pointing the firstmate repo at itself.
# Asserts: reg1 advances but is NOT nudged (no live metadata); sm1 advances,
# is processed once, and IS nudged; the firstmate repo is never re-processed.
test_registry_backstop_dedup_and_self_exclusion() {
  local w out count
  w=$(new_world t7)
  add_sm "$w" sm1
  git -C "$w/main" worktree add -q --detach "$w/reg1" main
  printf 'reg1\n' > "$w/reg1/.fm-secondmate-home"
  {
    printf -- '- reg1 - domain supervisor (home: %s/reg1; scope: things; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- sm1 - dup (home: %s/sm1; scope: x; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- selfish - self (home: %s/main; scope: x; projects: p; added 2026-06-23)\n' "$w"
  } > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate reg1: updated " "registry-only secondmate fast-forwarded"
  assert_contains "$out" "secondmate sm1: updated " "meta+registry secondmate fast-forwarded"
  count=$(printf '%s\n' "$out" | grep -c '^secondmate sm1:' || true)
  [ "$count" -eq 1 ] || fail "secondmate sm1 processed $count times, expected 1 (dedup across meta+registry)"
  assert_not_contains "$out" "secondmate selfish" "firstmate repo re-processed as its own secondmate"
  # sm1 has live metadata, so it is nudged; reg1 has none, so it is not. Pin the
  # nudge line exactly and confirm reg1 is absent from it (not from the whole
  # output, where 'secondmate reg1: updated' legitimately appears).
  local nudge_line
  nudge_line=$(printf '%s\n' "$out" | grep '^nudge-secondmates:')
  assert_contains "$nudge_line" "fm-sm1" "live-meta secondmate is nudged"
  assert_not_contains "$nudge_line" "reg1" "registry-only secondmate without live metadata is not nudged"
  pass "T7 registry backstop resolves, dedups meta+registry, excludes the firstmate repo"
}

# --- T9: firstmate repo on a feature branch is skipped ---------------------
test_firstmate_wrong_branch_skipped() {
  local w out before
  w=$(new_world t9)
  bump_origin "$w" instr
  # Simulate firstmate mid-shipping its own change: not on the default branch.
  git -C "$w/main" checkout -q -b feature/wip
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: on feature/wip, expected main" "off-default firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "skipped firstmate HEAD moved"
  pass "T9 firstmate off its default branch is skipped, not forced"
}

test_firstmate_detached_head_skipped() {
  local w out before
  w=$(new_world t10)
  bump_origin "$w" instr
  git -C "$w/main" checkout -q --detach HEAD
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: detached HEAD, expected main" "detached firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when detached firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "detached firstmate HEAD moved"
  pass "T10 firstmate detached HEAD is skipped"
}

test_unsafe_secondmate_home_skipped_before_git_update() {
  local w out bad before
  w=$(new_world t11)
  bad="$w/home/projects/bad"
  mkdir -p "$w/home/projects"
  git clone -q "$w/origin.git" "$bad"
  printf 'bad\n' > "$bad/.fm-secondmate-home"
  before=$(git -C "$bad" rev-parse HEAD)
  printf -- '- bad - bad home (home: %s; scope: x; projects: p; added 2026-06-23)\n' \
    "$bad" > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate bad: skipped: unsafe home: secondmate home cannot be inside the active firstmate home" \
    "unsafe project-like home skipped"
  assert_contains "$out" "nudge-secondmates: none" "unsafe home is not nudged"
  [ "$(git -C "$bad" rev-parse HEAD)" = "$before" ] \
    || fail "unsafe secondmate home HEAD moved"
  pass "T11 unsafe secondmate home is not fast-forwarded"
}

# --- F1: clean upstream advance lands on the fork, then on the home --------
test_fork_upstream_advance_lands_on_fork_then_home() {
  local w out fork_before upstream_head home_head
  w=$(new_fork_world f1)
  fork_before=$(published_head "$w/fork.git")
  bump_upstream "$w" one
  upstream_head=$(published_head "$w/upstream.git")

  out=$(run_update "$w")

  assert_contains "$out" "upstream-sync: synced origin/main " "upstream landed on the fork"
  assert_contains "$out" " from upstream/main" "the sync names its upstream source"
  [ "$(published_head "$w/fork.git")" = "$upstream_head" ] \
    || fail "fork main did not receive the upstream commit"
  # The fork advanced by a fast-forward: its previous tip is still reachable.
  git -C "$w/main" merge-base --is-ancestor "$fork_before" "$upstream_head" \
    || fail "fork main was not advanced by a fast-forward"

  assert_contains "$out" "firstmate: updated " "home advanced after the fork sync"
  assert_contains "$out" "reread-firstmate: yes" "instruction change triggers reread"
  home_head=$(git -C "$w/main" rev-parse HEAD)
  [ "$home_head" = "$upstream_head" ] || fail "home HEAD is not the fork's landed commit"
  [ "$(git -C "$w/main" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "home tip is not a single-parent fast-forward"
  pass "F1 upstream advance fast-forward-pushes to the fork, then the home advances"
}

# --- F2: fork-only custom advance needs no push and still reaches the home --
test_fork_only_custom_advance_reaches_home() {
  local w out upstream_before fork_head
  w=$(new_fork_world f2)
  upstream_before=$(published_head "$w/upstream.git")
  bump_fork "$w" one
  fork_head=$(published_head "$w/fork.git")

  out=$(run_update "$w")

  assert_contains "$out" "upstream-sync: fork ahead of upstream/main by 1 commit(s)" \
    "fork carrying merged custom work needs no push"
  [ "$(published_head "$w/upstream.git")" = "$upstream_before" ] \
    || fail "the authoritative upstream was written to"
  assert_contains "$out" "firstmate: updated " "home advanced to the custom head"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$fork_head" ] \
    || fail "home HEAD is not the fork's custom head"
  pass "F2 fork-only custom advance pushes nothing and still lands on the home"
}

# --- F3: a second run is a no-op on both the fork and the home -------------
test_fork_idempotent_already_current() {
  local w out fork_after
  w=$(new_fork_world f3)
  bump_upstream "$w" one
  run_update "$w" >/dev/null
  fork_after=$(published_head "$w/fork.git")

  out=$(run_update "$w")

  assert_contains "$out" "upstream-sync: already current" "fork already carries upstream"
  assert_contains "$out" "firstmate: already current" "home already current"
  assert_contains "$out" "reread-firstmate: no" "no reread when nothing changed"
  assert_contains "$out" "nudge-secondmates: none" "no nudge when nothing advanced"
  [ "$(published_head "$w/fork.git")" = "$fork_after" ] \
    || fail "an already-current run moved the fork"
  pass "F3 fork-aware update is idempotent"
}

# --- F4: real divergence is refused, both published branches untouched -----
test_fork_upstream_divergence_refused() {
  local w out fork_before upstream_before
  w=$(new_fork_world f4)
  bump_upstream "$w" one
  bump_fork "$w" one
  fork_before=$(published_head "$w/fork.git")
  upstream_before=$(published_head "$w/upstream.git")

  out=$(run_update "$w")

  assert_contains "$out" "upstream-sync: refused: origin/main and upstream/main have diverged" \
    "divergence is refused rather than reconciled"
  # Nothing was forced and no history was replaced on either side.
  [ "$(published_head "$w/fork.git")" = "$fork_before" ] \
    || fail "the fork was rewritten despite divergence"
  [ "$(published_head "$w/upstream.git")" = "$upstream_before" ] \
    || fail "the authoritative upstream was rewritten despite divergence"
  # The home's own advance stays independently safe: it still fast-forwards to
  # the fork's head, which is what this home is meant to run.
  assert_contains "$out" "firstmate: updated " "home still advances to its fork head"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$fork_before" ] \
    || fail "home HEAD is not the fork head after a refused reconciliation"
  pass "F4 upstream/fork divergence is refused with both published branches intact"
}

# --- F5: local dirty and unlanded work still block the home's own advance ---
test_fork_local_dirty_and_unlanded_refused() {
  local w out upstream_head before
  w=$(new_fork_world f5)
  bump_upstream "$w" one
  upstream_head=$(published_head "$w/upstream.git")
  printf 'uncommitted local edit\n' >> "$w/main/AGENTS.md"

  out=$(run_update "$w")

  assert_contains "$out" "upstream-sync: synced origin/main " "fork reconciliation still lands"
  assert_contains "$out" "firstmate: skipped: dirty working tree" "dirty home is skipped"
  assert_contains "$out" "reread-firstmate: no" "a skipped home triggers no reread"
  grep -q 'uncommitted local edit' "$w/main/AGENTS.md" || fail "dirty edit was discarded"

  # Now the unlanded-commit case on the same world: commit the edit so the home
  # holds work the fork does not, and confirm it is still never overwritten.
  git -C "$w/main" add -A
  git -C "$w/main" commit -qm local-unlanded
  before=$(git -C "$w/main" rev-parse HEAD)
  [ "$before" != "$upstream_head" ] || fail "fixture did not create unlanded local work"

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: diverged from origin/main" "unlanded home is skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] || fail "unlanded local commit was discarded"
  pass "F5 dirty and unlanded local work still refuse the home advance"
}

# --- F6: secondmates converge on the landed fork head ----------------------
test_fork_secondmate_propagation() {
  local w out upstream_head nudge_line
  w=$(new_fork_world f6)
  add_sm "$w" sm1
  bump_upstream "$w" one
  upstream_head=$(published_head "$w/upstream.git")

  out=$(run_update "$w")

  assert_contains "$out" "upstream-sync: synced origin/main " "upstream landed on the fork"
  assert_contains "$out" "secondmate sm1: updated " "secondmate advanced"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$upstream_head" ] \
    || fail "secondmate HEAD is not the fork's landed commit"
  git -C "$w/sm1" symbolic-ref -q HEAD >/dev/null \
    && fail "secondmate worktree is no longer detached"
  nudge_line=$(printf '%s\n' "$out" | grep '^nudge-secondmates:')
  assert_contains "$nudge_line" "fm-sm1" "advanced secondmate is nudged"
  pass "F6 secondmates converge on the commit landed in the fork"
}

# --- F7: ambiguous remote topology is refused, never guessed ---------------
# Each case leaves the home free to keep following its own origin, so a bad
# upstream declaration degrades to the classic single-remote update instead of
# pushing somewhere unintended.
test_fork_ambiguous_topology_refused() {
  local w out fork_before sink_before
  w=$(new_fork_world f7)
  bump_fork "$w" one

  printf 'nosuch\n' > "$w/home/config/upstream-remote"
  out=$(run_update "$w")
  assert_contains "$out" "upstream-sync: refused: upstream remote 'nosuch' is not configured" \
    "an unconfigured upstream remote is refused"
  assert_contains "$out" "firstmate: updated " "the home still follows its own origin"

  printf 'origin\n' > "$w/home/config/upstream-remote"
  out=$(run_update "$w")
  assert_contains "$out" "upstream-sync: refused: upstream remote 'origin' is the fork remote origin" \
    "origin cannot be its own upstream"

  printf 'https://example.invalid/x/firstmate\n' > "$w/home/config/upstream-remote"
  out=$(run_update "$w")
  assert_contains "$out" "must name a configured git remote, not a URL or path" \
    "a URL is refused instead of being fetched"

  printf 'upstream extra\n' > "$w/home/config/upstream-remote"
  out=$(run_update "$w")
  assert_contains "$out" "must be a single git remote name" "a multi-token value is refused"

  git -C "$w/main" remote add twin "file://$w/fork.git"
  printf 'twin\n' > "$w/home/config/upstream-remote"
  out=$(run_update "$w")
  assert_contains "$out" "upstream-sync: refused: upstream remote 'twin' and origin are the same repository" \
    "an upstream that is the fork itself is refused"

  w=$(new_fork_world f7-push)
  git init -q --bare "$w/sink.git"
  git -C "$w/sink.git" symbolic-ref HEAD refs/heads/main
  git -C "$w/upstream-seed" push -q "$w/sink.git" main
  bump_upstream "$w" one
  fork_before=$(published_head "$w/fork.git")
  sink_before=$(published_head "$w/sink.git")
  git -C "$w/main" remote set-url --add --push origin "$w/sink.git"
  out=$(run_update "$w")
  assert_contains "$out" "upstream-sync: refused: origin push destination is not its fetch repository" \
    "a distinct origin push destination is refused"
  [ "$(published_head "$w/fork.git")" = "$fork_before" ] || fail "the fork moved through a mismatched push destination"
  [ "$(published_head "$w/sink.git")" = "$sink_before" ] || fail "a mismatched push destination received upstream"

  git -C "$w/main" remote set-url --add --push origin "$w/fork.git"
  out=$(run_update "$w")
  assert_contains "$out" "upstream-sync: refused: origin has multiple push destinations" \
    "multiple origin push destinations are refused"
  [ "$(published_head "$w/fork.git")" = "$fork_before" ] || fail "the fork moved through multiple push destinations"
  [ "$(published_head "$w/sink.git")" = "$sink_before" ] || fail "one of multiple push destinations received upstream"
  pass "F7 ambiguous upstream topology is refused rather than guessed"
}

# --- F8: a mismatched upstream default branch is refused -------------------
test_fork_upstream_default_branch_mismatch_refused() {
  local w out fork_before
  w=$(new_fork_world f8)
  git -C "$w/main" fetch -q upstream
  git -C "$w/main" remote set-head upstream main >/dev/null 2>&1
  bump_upstream "$w" one
  git -C "$w/upstream-seed" checkout -q -b trunk
  printf 'trunk\n' >> "$w/upstream-seed/README.md"
  git -C "$w/upstream-seed" add -A
  git -C "$w/upstream-seed" commit -qm trunk-work
  git -C "$w/upstream-seed" push -q origin trunk
  git -C "$w/upstream.git" symbolic-ref HEAD refs/heads/trunk
  fork_before=$(published_head "$w/fork.git")

  out=$(run_update "$w")

  assert_contains "$out" "upstream-sync: refused: cached 'upstream' default branch main does not match advertised default branch trunk" \
    "a stale cached upstream default branch is refused"
  [ "$(published_head "$w/fork.git")" = "$fork_before" ] || fail "the fork moved on a topology mismatch"
  pass "F8 a mismatched upstream default branch is refused"
}

# --- F9: the fork lane ships inert; opting out never pushes ----------------
test_fork_topology_off_by_default_never_pushes() {
  local w out fork_before
  w=$(new_fork_world f9)
  # A comment-only file is as unconfigured as an absent one.
  printf '# no upstream configured yet\n\n' > "$w/home/config/upstream-remote"
  fork_before=$(published_head "$w/fork.git")
  bump_upstream "$w" one

  out=$(run_update "$w")

  assert_contains "$out" "upstream-sync: not configured" "an unset upstream reports itself"
  [ "$(published_head "$w/fork.git")" = "$fork_before" ] \
    || fail "an unconfigured home pushed to its fork"
  assert_contains "$out" "firstmate: already current" "home follows only its own origin"

  rm -f "$w/home/config/upstream-remote"
  out=$(run_update "$w")
  assert_contains "$out" "upstream-sync: not configured" "an absent config file reports itself"
  [ "$(published_head "$w/fork.git")" = "$fork_before" ] \
    || fail "a home with no config pushed to its fork"
  pass "F9 the fork lane is inert until configured and never pushes by default"
}

test_updates_main_and_secondmate
test_reread_gate_is_instruction_only
test_dirty_secondmate_skipped
test_diverged_secondmate_skipped
test_idempotent_already_current
test_registry_backstop_dedup_and_self_exclusion
test_firstmate_wrong_branch_skipped
test_firstmate_detached_head_skipped
test_unsafe_secondmate_home_skipped_before_git_update
test_fork_upstream_advance_lands_on_fork_then_home
test_fork_only_custom_advance_reaches_home
test_fork_idempotent_already_current
test_fork_upstream_divergence_refused
test_fork_local_dirty_and_unlanded_refused
test_fork_secondmate_propagation
test_fork_ambiguous_topology_refused
test_fork_upstream_default_branch_mismatch_refused
test_fork_topology_off_by_default_never_pushes

echo "# all fm-update tests passed"
