# shellcheck shell=bash
# Shared fast-forward machinery for firstmate self-sync.
# Usage: . bin/fm-ff-lib.sh   (after FM_ROOT and FM_HOME are set)
#
# This is the one implementation of "advance a firstmate checkout to a base by a
# clean fast-forward, never forcing, merging, or stashing" used by every sync
# path:
#   - /updatefirstmate (bin/fm-update.sh) pulls from origin: base_mode "origin".
#   - the local-HEAD secondmate sync (bin/fm-spawn.sh on launch, bin/fm-bootstrap.sh
#     on startup) follows the PRIMARY checkout's current default-branch commit:
#     base_mode is that local commit, with NO fetch and no origin dependency.
#
# It also owns the one upstream-into-fork reconciliation that runs BEFORE the
# origin fast-forward when a home follows a personal fork; see the
# "upstream -> fork reconciliation" section below. Only /updatefirstmate calls
# it, so no startup or spawn sync path ever pushes anything.
#
# A linked-worktree secondmate home already holds the primary's commit in the
# shared object store, so its local-HEAD sync is a purely local fast-forward that
# never touches the network. A standalone clone moves through that path only when
# it already has the target; otherwise it is skipped until the origin path updates it.
# A tracked-files fast-forward never touches the gitignored operational dirs
# (data/, state/, config/, projects/, .no-mistakes/), so it cannot disturb a
# secondmate's backlog, projects, or in-flight work.
# The seeded .fm-secondmate-home identity marker is gitignored too; the local
# sync tolerates only that marker during the one-time upgrade of pre-ignore
# linked-worktree homes.
# Homes are leased at a detached HEAD on the
# default branch, so the fast-forward advances HEAD only and never moves the
# shared default branch or any other worktree's checkout.

SUB_HOME_MARKER="${SUB_HOME_MARKER:-.fm-secondmate-home}"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-secondmate-registry-lib.sh"

# --- helpers ---------------------------------------------------------------

first_line() {
  printf '%s\n' "$1" | sed -n '1s/[[:space:]]\{1,\}/ /g;1p'
}

default_branch() {
  local dir=$1 ref branch
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

# Resolve the PRIMARY checkout's current default-branch commit - the local-HEAD
# sync target every secondmate follows. Reads the default branch *ref* rather than
# HEAD, so even a primary stranded on a feature branch (the worktree tangle of
# section 8) still yields the true default-branch tip instead of propagating a
# stray feature branch to the fleet. Echoes the commit SHA, or returns 1.
primary_head_commit() {
  local root=$1 default
  default=$(default_branch "$root") || return 1
  git -C "$root" rev-parse --verify --quiet "refs/heads/$default^{commit}" 2>/dev/null || return 1
}

resolve_path() {
  # Resolve to a canonical absolute path, falling back to the literal input
  # when the directory does not exist (so callers can still dedup/skip on it).
  ( cd "$1" 2>/dev/null && pwd -P ) || printf '%s\n' "$1"
}

resolved_existing_dir() {
  local path=$1
  [ -d "$path" ] || return 1
  cd "$path" && pwd -P
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

VALIDATED_HOME=""
VALIDATION_ERROR=""

validate_operational_dirs() {
  local abs_home=$1 abs_active_home=$2 abs_root=$3 name dir abs_dir
  for name in data state config projects; do
    dir="$abs_home/$name"
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      VALIDATION_ERROR="secondmate $name directory must resolve inside the secondmate home"
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P) || {
        VALIDATION_ERROR="secondmate $name directory cannot be resolved"
        return 1
      }
    elif [ -e "$dir" ]; then
      VALIDATION_ERROR="secondmate $name path is not a directory"
      return 1
    else
      abs_dir="$abs_home/$name"
    fi
    if ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      VALIDATION_ERROR="secondmate $name directory must resolve inside the secondmate home"
      return 1
    fi
    if [ "$abs_dir" = "$abs_active_home" ] || path_is_ancestor_of "$abs_active_home" "$abs_dir"; then
      VALIDATION_ERROR="secondmate $name directory cannot be inside the active firstmate home"
      return 1
    fi
    if [ "$abs_dir" = "$abs_root" ] || path_is_ancestor_of "$abs_root" "$abs_dir"; then
      VALIDATION_ERROR="secondmate $name directory cannot be inside the firstmate repo"
      return 1
    fi
  done
}

validate_secondmate_home() {
  local id=$1 home=$2 abs_home abs_active_home abs_root marker_id
  VALIDATED_HOME=""
  VALIDATION_ERROR=""
  abs_home=$(resolved_existing_dir "$home") || {
    VALIDATION_ERROR="not a directory"
    return 1
  }
  abs_active_home=$(resolved_existing_dir "$FM_HOME") || {
    VALIDATION_ERROR="active firstmate home is not a directory"
    return 1
  }
  abs_root=$(resolved_existing_dir "$FM_ROOT") || {
    VALIDATION_ERROR="firstmate repo is not a directory"
    return 1
  }
  if [ "$abs_home" = "/" ]; then
    VALIDATION_ERROR="secondmate home cannot be the filesystem root"
    return 1
  fi
  if [ "$abs_home" = "$abs_active_home" ]; then
    VALIDATION_ERROR="secondmate home cannot be the active firstmate home"
    return 1
  fi
  if [ "$abs_home" = "$abs_root" ]; then
    VALIDATION_ERROR="secondmate home cannot be the firstmate repo"
    return 1
  fi
  if path_is_ancestor_of "$abs_active_home" "$abs_home"; then
    VALIDATION_ERROR="secondmate home cannot be inside the active firstmate home"
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_home"; then
    VALIDATION_ERROR="secondmate home cannot be inside the firstmate repo"
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_active_home"; then
    VALIDATION_ERROR="secondmate home cannot be an ancestor of the active firstmate home"
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_root"; then
    VALIDATION_ERROR="secondmate home cannot be an ancestor of the firstmate repo"
    return 1
  fi
  validate_operational_dirs "$abs_home" "$abs_active_home" "$abs_root" || return 1
  if [ -L "$abs_home/$SUB_HOME_MARKER" ]; then
    VALIDATION_ERROR="secondmate marker must not be a symlink"
    return 1
  fi
  if [ ! -f "$abs_home/$SUB_HOME_MARKER" ]; then
    VALIDATION_ERROR="not a seeded secondmate home"
    return 1
  fi
  marker_id=$(cat "$abs_home/$SUB_HOME_MARKER" 2>/dev/null || true)
  if [ "$marker_id" != "$id" ]; then
    VALIDATION_ERROR="marked for secondmate ${marker_id:-unknown}, expected $id"
    return 1
  fi
  if [ ! -f "$abs_home/AGENTS.md" ]; then
    VALIDATION_ERROR="not a firstmate home (missing AGENTS.md)"
    return 1
  fi
  if [ ! -d "$abs_home/bin" ]; then
    VALIDATION_ERROR="not a firstmate home (missing bin/)"
    return 1
  fi
  VALIDATED_HOME="$abs_home"
}

# A single fetch refreshes every worktree that shares an object store, so fetch
# each distinct git-common-dir at most once. Used ONLY by the origin base mode;
# the local-HEAD sync never fetches.
FETCHED=""
fetch_once() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  if [ -n "$common" ]; then
    case " $FETCHED " in
      *" $common "*) return 0 ;;
    esac
  fi
  if git -C "$dir" fetch origin --prune --quiet 2>/dev/null; then
    [ -n "$common" ] && FETCHED="$FETCHED $common"
    return 0
  fi
  return 1
}

# --- upstream -> fork reconciliation ---------------------------------------
# A home may follow a personal FORK as `origin` (the reviewable landing lane for
# its own custom commits) while an authoritative UPSTREAM repository stays the
# source of shared firstmate changes. In that topology the home cannot simply
# fast-forward to upstream: its custom commits live on the fork, and only the
# fork's merged head is what the home should run. So `/updatefirstmate` first
# lands upstream's default branch on the fork by a fast-forward push, and only
# then runs the ordinary origin fast-forward of the home itself.
#
# Everything here is fast-forward or nothing. There is no force, no lease, no
# refspec `+`, no merge, no rebase, and no rewrite: the push carries the exact
# upstream commit to `refs/heads/<default>` on `origin` and lets the receiving
# repository refuse it when it would not be a fast-forward. Real divergence -
# both sides carrying commits the other lacks - is a human merge decision made
# in the fork's own review lane, so it is refused and reported, never guessed
# at. Ambiguous topology (an unconfigured or self-referential upstream remote, a
# non-remote value, a mismatched upstream default branch, a missing branch on
# either side) is refused for the same reason.
#
# A refusal is a reported skip, exactly like every other skip in this library:
# the home's own guarded fast-forward still runs afterwards and can still
# advance the home to the fork's own head, because that advance is independently
# ff-only and never reconciles the fork.

# The configured upstream remote NAME for this home, or non-zero when the
# fork topology is not configured. Reads the first non-empty, non-comment line
# of <config-dir>/upstream-remote; an absent, empty, or comment-only file means
# the classic single-remote update, so nothing is ever pushed by default.
fm_upstream_remote_name() {  # <config-dir>
  local file=$1/upstream-remote line trimmed
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$trimmed" ] || continue
    case "$trimmed" in '#'*) continue ;; esac
    printf '%s\n' "$trimmed"
    return 0
  done < "$file"
  return 1
}

git_local_repository_identity() {
  local dir=$1 path=$2 resolved
  case "$path" in
    /*) ;;
    *) path=$dir/$path ;;
  esac
  resolved=$(resolved_existing_dir "$path") || return 1
  printf 'local:%s\n' "$resolved"
}

git_network_repository_identity() {
  local host=$1 port=$2 path=$3
  host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
  while [ "${path#/}" != "$path" ]; do path=${path#/}; done
  while [ "${path%/}" != "$path" ]; do path=${path%/}; done
  case "$path" in *.git) path=${path%.git} ;; esac
  [ -n "$host" ] && [ -n "$path" ] || return 1
  case "$path" in *\?*|*\#*) return 1 ;; esac
  if [ -n "$port" ]; then
    printf 'network:%s:%s/%s\n' "$host" "$port" "$path"
  else
    printf 'network:%s/%s\n' "$host" "$path"
  fi
}

git_repository_identity() {
  local dir=$1 url=$2 rest scheme authority hostport host port path
  case "$url" in
    file://*)
      rest=${url#file://}
      case "$rest" in
        /*) path=$rest ;;
        localhost/*) path=/${rest#localhost/} ;;
        *) return 1 ;;
      esac
      case "$path" in *%*|*\?*|*\#*) return 1 ;; esac
      git_local_repository_identity "$dir" "$path"
      ;;
    *://*)
      scheme=${url%%://*}
      case "$scheme" in http|https|ssh|git) ;; *) return 1 ;; esac
      rest=${url#*://}
      authority=${rest%%/*}
      [ "$authority" != "$rest" ] || return 1
      path=${rest#*/}
      hostport=${authority##*@}
      port=""
      case "$hostport" in
        \[*\]:*)
          host=${hostport%%]*}
          host=${host#\[}
          port=${hostport#*]:}
          ;;
        \[*\])
          host=${hostport#\[}
          host=${host%\]}
          ;;
        *:*)
          host=${hostport%%:*}
          port=${hostport#*:}
          case "$port" in *:*) return 1 ;; esac
          ;;
        *) host=$hostport ;;
      esac
      case "$scheme:$port" in
        http:80|https:443|ssh:22|git:9418) port="" ;;
      esac
      git_network_repository_identity "$host" "$port" "$path"
      ;;
    ./*|../*|/*)
      git_local_repository_identity "$dir" "$url"
      ;;
    *:*)
      hostport=${url%%:*}
      path=${url#*:}
      host=${hostport##*@}
      git_network_repository_identity "$host" "" "$path"
      ;;
    *)
      git_local_repository_identity "$dir" "$url"
      ;;
  esac
}

remote_advertised_default_branch() {
  local dir=$1 remote=$2 out branch
  out=$(git -C "$dir" ls-remote --symref "$remote" HEAD 2>/dev/null) || return 1
  branch=$(printf '%s\n' "$out" |
    sed -n 's/^ref: refs\/heads\/\([^[:space:]]*\)[[:space:]]\{1,\}HEAD$/\1/p')
  [ -n "$branch" ] || return 1
  case "$branch" in *$'\n'*) return 1 ;; esac
  git check-ref-format --branch "$branch" >/dev/null 2>&1 || return 1
  printf '%s\n' "$branch"
}

upstream_sync_refuse() {
  echo "upstream-sync: refused: $1"
}

# Land the configured upstream's default branch on this home's fork by a
# fast-forward push. The one printed line IS the contract, in the same
# "<label>: <outcome>" shape every other target here uses:
#   upstream-sync: not configured
#   upstream-sync: already current
#   upstream-sync: fork ahead of <remote>/<branch> by <n> commit(s)
#   upstream-sync: synced origin/<branch> <before>..<after> from <remote>/<branch>
#   upstream-sync: refused: <reason>
# Always returns 0: like every other target here, an unsafe or ambiguous state
# is a reported skip rather than a failed run.
sync_upstream_into_fork() {  # <repo-dir> <config-dir>
  local dir=$1 config_dir=$2
  local remote default origin_default upstream_default remote_head
  local upstream_urls origin_urls origin_push_urls upstream_url origin_url origin_push_url
  local upstream_identity origin_identity origin_push_identity
  local upstream_rev origin_rev before after ahead out

  if ! remote=$(fm_upstream_remote_name "$config_dir"); then
    echo "upstream-sync: not configured"
    return 0
  fi

  # The value names one configured git remote. A URL, a path, or several tokens
  # is ambiguous topology: refuse rather than guess which repository to push to.
  case "$remote" in
    *[[:space:]]*)
      upstream_sync_refuse "upstream value '$remote' must be a single git remote name"
      return 0
      ;;
    -*|*/*|*:*)
      upstream_sync_refuse "upstream value '$remote' must name a configured git remote, not a URL or path"
      return 0
      ;;
  esac

  if [ ! -d "$dir" ] || ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    upstream_sync_refuse "firstmate repo is not a git repo"
    return 0
  fi
  if [ "$remote" = origin ]; then
    upstream_sync_refuse "upstream remote '$remote' is the fork remote origin"
    return 0
  fi
  if ! upstream_urls=$(git -C "$dir" remote get-url --all "$remote" 2>/dev/null); then
    upstream_sync_refuse "upstream remote '$remote' is not configured"
    return 0
  fi
  case "$upstream_urls" in
    *$'\n'*)
      upstream_sync_refuse "upstream remote '$remote' has multiple fetch URLs"
      return 0
      ;;
  esac
  upstream_url=$upstream_urls
  if ! origin_urls=$(git -C "$dir" remote get-url --all origin 2>/dev/null); then
    upstream_sync_refuse "no origin remote to land '$remote' on"
    return 0
  fi
  case "$origin_urls" in
    *$'\n'*)
      upstream_sync_refuse "origin has multiple fetch URLs"
      return 0
      ;;
  esac
  origin_url=$origin_urls
  if ! origin_push_urls=$(git -C "$dir" remote get-url --push --all origin 2>/dev/null); then
    upstream_sync_refuse "cannot determine origin push destination"
    return 0
  fi
  case "$origin_push_urls" in
    *$'\n'*)
      upstream_sync_refuse "origin has multiple push destinations"
      return 0
      ;;
  esac
  origin_push_url=$origin_push_urls

  if ! upstream_identity=$(git_repository_identity "$dir" "$upstream_url"); then
    upstream_sync_refuse "cannot determine repository identity for upstream remote '$remote'"
    return 0
  fi
  if ! origin_identity=$(git_repository_identity "$dir" "$origin_url"); then
    upstream_sync_refuse "cannot determine repository identity for origin"
    return 0
  fi
  if ! origin_push_identity=$(git_repository_identity "$dir" "$origin_push_url"); then
    upstream_sync_refuse "cannot determine repository identity for origin push destination"
    return 0
  fi
  if [ "$origin_push_identity" != "$origin_identity" ]; then
    upstream_sync_refuse "origin push destination is not its fetch repository"
    return 0
  fi
  if [ "$upstream_identity" = "$origin_identity" ]; then
    upstream_sync_refuse "upstream remote '$remote' and origin are the same repository"
    return 0
  fi

  default=$(default_branch "$dir") || {
    upstream_sync_refuse "cannot determine the default branch"
    return 0
  }

  if ! origin_default=$(remote_advertised_default_branch "$dir" origin); then
    upstream_sync_refuse "cannot determine origin advertised default branch"
    return 0
  fi
  remote_head=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$remote_head" ] && [ "${remote_head#origin/}" != "$origin_default" ]; then
    upstream_sync_refuse "cached origin default branch ${remote_head#origin/} does not match advertised default branch $origin_default"
    return 0
  fi
  if [ "$default" != "$origin_default" ]; then
    upstream_sync_refuse "origin default branch $origin_default does not match local default branch $default"
    return 0
  fi
  if ! upstream_default=$(remote_advertised_default_branch "$dir" "$remote"); then
    upstream_sync_refuse "cannot determine '$remote' advertised default branch"
    return 0
  fi
  remote_head=$(git -C "$dir" symbolic-ref --quiet --short "refs/remotes/$remote/HEAD" 2>/dev/null || true)
  if [ -n "$remote_head" ] && [ "${remote_head#"$remote"/}" != "$upstream_default" ]; then
    upstream_sync_refuse "cached '$remote' default branch ${remote_head#"$remote"/} does not match advertised default branch $upstream_default"
    return 0
  fi
  if [ "$upstream_default" != "$origin_default" ]; then
    upstream_sync_refuse "'$remote' default branch $upstream_default does not match origin default branch $origin_default"
    return 0
  fi

  if ! fetch_once "$dir"; then
    upstream_sync_refuse "fetch from origin failed"
    return 0
  fi
  if ! git -C "$dir" fetch "$remote" --prune --quiet 2>/dev/null; then
    upstream_sync_refuse "fetch from '$remote' failed"
    return 0
  fi

  if ! upstream_rev=$(git -C "$dir" rev-parse --verify --quiet "refs/remotes/$remote/$default^{commit}"); then
    upstream_sync_refuse "'$remote' has no $default branch"
    return 0
  fi
  if ! origin_rev=$(git -C "$dir" rev-parse --verify --quiet "refs/remotes/origin/$default^{commit}"); then
    upstream_sync_refuse "origin has no $default branch"
    return 0
  fi

  if [ "$upstream_rev" = "$origin_rev" ]; then
    echo "upstream-sync: already current"
    return 0
  fi
  # The fork already contains upstream plus its own merged custom commits.
  # There is nothing to push, and the home still advances to that custom head.
  if git -C "$dir" merge-base --is-ancestor "$upstream_rev" "$origin_rev" 2>/dev/null; then
    ahead=$(git -C "$dir" rev-list --count "$upstream_rev..$origin_rev" 2>/dev/null || true)
    echo "upstream-sync: fork ahead of $remote/$default by ${ahead:-?} commit(s)"
    return 0
  fi
  # Both sides hold commits the other lacks. Reconciling that needs a merge in
  # the fork's review lane; a fast-forward push cannot express it and a forced
  # one would replace the fork's history, so refuse and report.
  if ! git -C "$dir" merge-base --is-ancestor "$origin_rev" "$upstream_rev" 2>/dev/null; then
    upstream_sync_refuse "origin/$default and $remote/$default have diverged; land $remote/$default in the fork with a merge"
    return 0
  fi

  before=$(git -C "$dir" rev-parse --short "$origin_rev")
  after=$(git -C "$dir" rev-parse --short "$upstream_rev")
  # No force, no lease, no leading '+': the receiving repository is what refuses
  # a non-fast-forward, so a topology that changed under us cannot be overwritten.
  if ! out=$(git -C "$dir" push origin "$upstream_rev:refs/heads/$default" 2>&1); then
    upstream_sync_refuse "fast-forward push of $remote/$default onto origin/$default failed: $(first_line "$out")"
    return 0
  fi
  # Refresh origin/<default> so the home's own fast-forward sees the landed
  # commit; fetch_once already marked this object store, so nothing else refetches.
  git -C "$dir" fetch origin --prune --quiet 2>/dev/null || true
  echo "upstream-sync: synced origin/$default $before..$after from $remote/$default"
  return 0
}

# Which watched instruction paths changed between HEAD and BASE (comma list).
# These are the files a running agent actually reads or runs: its instructions
# (AGENTS.md, which CLAUDE.md imports via @AGENTS.md), its agent-loaded skills
# (.agents/skills/), and its tooling (bin/). Public skills/ is installer-facing
# and intentionally not part of this watched instruction surface.
changed_instr() {
  local dir=$1 base=$2 p out=""
  for p in AGENTS.md bin .agents/skills; do
    if ! git -C "$dir" diff --quiet HEAD "$base" -- "$p" 2>/dev/null; then
      out="$out${out:+, }$p"
    fi
  done
  printf '%s' "$out"
}

dirty_status() {
  local dir=$1 ignore_seed_marker=${2:-no}
  if [ "$ignore_seed_marker" = yes ]; then
    git -C "$dir" status --porcelain 2>/dev/null | awk -v marker="?? $SUB_HOME_MARKER" '$0 != marker { print; exit }'
  else
    git -C "$dir" status --porcelain 2>/dev/null | head -1
  fi
}

# List this home's LIVE secondmate direct reports from state/<id>.meta records.
# The meta file is the liveness signal; data/secondmates.md is only the fallback
# for durable fields such as home= when an older/incomplete meta lacks them.
# Output is pipe-delimited: id|home|window|meta-file.
live_secondmate_meta_records() {
  local state=$1 registry=${2:-} meta id home window
  [ -d "$state" ] || return 0
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    grep -q '^kind=secondmate$' "$meta" 2>/dev/null || continue
    id=$(basename "$meta" .meta)
    home=$(grep '^home=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    if [ -z "$home" ] && [ -n "$registry" ]; then
      home=$(secondmate_registry_field "$registry" "$id" home || true)
    fi
    window=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    printf '%s|%s|%s|%s\n' "$id" "$home" "$window" "$meta"
  done
}

# Fast-forward one target to a base. Prints its status line. Sets globals for the
# caller:
#   FF_STATUS = updated|current|skipped
#   FF_INSTR  = comma list of changed instruction paths (only when updated)
#
# base_mode selects where the fast-forward base comes from:
#   origin       - fetch origin and advance to origin/<default> (the /updatefirstmate
#                  path); requires an origin remote and network reachability.
#   <commit-ish> - advance to that LOCAL commit with NO fetch and no origin
#                  dependency (the local-HEAD secondmate sync). The commit must
#                  already exist in the target's object store, which it always does
#                  for a worktree of this same repo; a standalone clone that lacks
#                  it is skipped rather than fetched.
# Guards are identical in both modes: ff-only (never force/merge/stash); skip a
# dirty, diverged, or wrong-branch target and leave its work untouched.
FF_STATUS=""
FF_INSTR=""
ff_target() {
  local dir=$1 label=$2 base_mode=$3 allow_detached=${4:-no} ignore_seed_marker=${5:-no}
  FF_STATUS="skipped"
  FF_INSTR=""

  if [ ! -d "$dir" ]; then
    echo "$label: skipped: not a directory"
    return 0
  fi
  if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "$label: skipped: not a git repo"
    return 0
  fi

  local default base cur instr local_rev base_rev before after out
  default=$(default_branch "$dir") || {
    echo "$label: skipped: cannot determine default branch"
    return 0
  }

  # Resolve the fast-forward base from base_mode (see header).
  if [ "$base_mode" = origin ]; then
    if ! git -C "$dir" remote get-url origin >/dev/null 2>&1; then
      echo "$label: skipped: no origin remote"
      return 0
    fi
    if ! fetch_once "$dir"; then
      echo "$label: skipped: fetch failed"
      return 0
    fi
    base="origin/$default"
  else
    base="$base_mode"
  fi

  if ! git -C "$dir" rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
    echo "$label: skipped: $base does not exist"
    return 0
  fi

  cur=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || echo "")
  if [ -z "$cur" ] && [ "$allow_detached" != yes ]; then
    echo "$label: skipped: detached HEAD, expected $default"
    return 0
  fi
  if [ -n "$cur" ] && [ "$cur" != "$default" ]; then
    echo "$label: skipped: on $cur, expected $default"
    return 0
  fi

  if [ -n "$(dirty_status "$dir" "$ignore_seed_marker")" ]; then
    echo "$label: skipped: dirty working tree"
    return 0
  fi

  local_rev=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || {
    echo "$label: skipped: cannot read HEAD"
    return 0
  }
  base_rev=$(git -C "$dir" rev-parse "$base" 2>/dev/null) || {
    echo "$label: skipped: cannot read $base"
    return 0
  }
  if [ "$local_rev" = "$base_rev" ]; then
    FF_STATUS="current"
    echo "$label: already current"
    return 0
  fi
  if ! git -C "$dir" merge-base --is-ancestor HEAD "$base" 2>/dev/null; then
    echo "$label: skipped: diverged from $base"
    return 0
  fi

  instr=$(changed_instr "$dir" "$base")
  before=$(git -C "$dir" rev-parse --short HEAD)
  if ! out=$(git -C "$dir" merge --ff-only "$base" 2>&1); then
    echo "$label: skipped: fast-forward failed: $(first_line "$out")"
    return 0
  fi
  after=$(git -C "$dir" rev-parse --short HEAD)
  FF_STATUS="updated"
  FF_INSTR="$instr"
  if [ -n "$instr" ]; then
    echo "$label: updated $before..$after (instructions changed: $instr)"
  else
    echo "$label: updated $before..$after"
  fi
  return 0
}

# Sweep accumulators. The caller resets both before a sweep and reads
# FF_NUDGE_WINDOWS after.
FF_NUDGE_WINDOWS=""
FF_SEEN_HOMES=""

# Validate and fast-forward one secondmate home, accumulating its stable
# fm-<id> task selector into FF_NUDGE_WINDOWS when it should be live-converged.
# Args:
#   id home window base_mode nudge_requires_instr
# A home is nudged only when it ACTUALLY advanced (FF_STATUS=updated) and has a
# live window. With nudge_requires_instr=yes the advance must also have changed
# the instruction surface (FF_INSTR non-empty): an already-current home, or one
# whose only change was non-instruction tracked files, is left undisturbed. The
# firstmate repo itself (FM_ROOT) is never processed as its own secondmate, and
# each resolved home is processed at most once.
process_secondmate() {
  local id=$1 home=$2 window=${3:-} base_mode=$4 nudge_requires_instr=${5:-no} home_real fm_root_real
  [ -n "$id" ] || return 0
  [ -n "$home" ] || return 0
  fm_root_real=$(resolve_path "$FM_ROOT")
  home_real=$(resolve_path "$home")
  [ "$home_real" != "$fm_root_real" ] || return 0
  if ! validate_secondmate_home "$id" "$home"; then
    echo "secondmate $id: skipped: unsafe home: $VALIDATION_ERROR"
    return 0
  fi
  home_real="$VALIDATED_HOME"
  case " $FF_SEEN_HOMES " in
    *" $home_real "*) return 0 ;;
  esac
  FF_SEEN_HOMES="$FF_SEEN_HOMES $home_real"

  ff_target "$home_real" "secondmate $id" "$base_mode" yes yes
  if [ "$FF_STATUS" = "updated" ] && [ -n "$window" ]; then
    if [ "$nudge_requires_instr" = yes ] && [ -z "$FF_INSTR" ]; then
      return 0
    fi
    FF_NUDGE_WINDOWS="$FF_NUDGE_WINDOWS fm-$id"
    if [ "$nudge_requires_instr" = yes ] && [ -n "$FF_INSTR" ] \
      && type fm_ff_after_instruction_update >/dev/null 2>&1; then
      fm_ff_after_instruction_update "$id" "$home_real" "$window" "$FF_INSTR"
    fi
  fi
}

# Sweep this home's LIVE secondmate direct reports - state/<id>.meta files with
# kind=secondmate - fast-forwarding each to base_mode. Passes base_mode and
# nudge_requires_instr through to process_secondmate. Accumulates into
# FF_NUDGE_WINDOWS / FF_SEEN_HOMES, which the caller resets before and reads after.
# The registry argument is only for home= fallback on older or incomplete meta records.
sweep_live_secondmate_metas() {
  local state=$1 base_mode=$2 nudge_requires_instr=${3:-no} registry=${4:-$FM_HOME/data/secondmates.md} id home window meta
  [ -d "$state" ] || return 0
  while IFS='|' read -r id home window meta; do
    if grep -q '^remote_host=.' "$meta" 2>/dev/null; then continue; fi
    process_secondmate "$id" "$home" "$window" "$base_mode" "$nudge_requires_instr"
  done < <(live_secondmate_meta_records "$state" "$registry")
}
