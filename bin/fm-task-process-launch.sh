#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/fm-task-process-lib.sh"

[ "$#" -eq 4 ] || exit 2
record=$1
token=$2
prior_token=$3
launch=$4
state=${record%/*}
name=${record##*/}
id=${name%.process-scope}
if [ "$prior_token" = - ]; then
  [ ! -e "$record" ] && [ ! -L "$record" ] || exit 1
else
  fm_task_process_scope_record_read "$state" "$id" "$prior_token" || exit 1
  [ "$FM_TASK_PROCESS_SCOPE_STATUS" = empty ] || exit 1
fi
pid=$$
pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]') || exit 1
case "$pgid" in ''|*[!0-9]*|0|1) exit 1 ;; esac
[ "$pgid" = "$pid" ] || {
  echo "error: agy launch did not receive an isolated foreground process group" >&2
  exit 1
}
identity=$(fm_task_process_identity "$pid") || exit 1
fm_task_process_scope_token_valid "$token" || exit 1
tmp=$(umask 077; mktemp "$state/.$name.XXXXXX") || exit 1
scope_launch_cleanup() {
  [ -z "${tmp:-}" ] || rm -f -- "$tmp" 2>/dev/null || true
}
trap scope_launch_cleanup EXIT
{
  printf 'version=1\n'
  printf 'status=active\n'
  printf 'token=%s\n' "$token"
  printf 'leader_pid=%s\n' "$pid"
  printf 'leader_identity=%s\n' "$identity"
  printf 'pgid=%s\n' "$pgid"
} > "$tmp"
chmod 0600 "$tmp"
mv -f -- "$tmp" "$record"
tmp=
trap - EXIT
export FM_TASK_PROCESS_SCOPE_TOKEN=$token
exec /bin/sh -c "$launch"
