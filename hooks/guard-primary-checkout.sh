#!/usr/bin/env bash
# preToolUse guard for worktree-based implementation sessions (Copilot CLI).
#
# Implementers start with their cwd in the user's primary checkout and have repeatedly edited it
# before creating their own worktree, then "cleaned up" with `git checkout` there, which can destroy
# the user's own uncommitted work. They have also used `git stash`, whose stack is shared by every
# worktree. Written rules didn't stop either, so this blocks them.
#
# OPT-IN. Copilot CLI's hook payload has no agent id, so the hook cannot tell an implementer from
# the user's own session. It therefore does nothing unless COPILOT_KIT_GUARD=1 is set in the
# environment of the copilot process, e.g.  COPILOT_KIT_GUARD=1 copilot  for a /ship-backlog run.
# With the guard on, ANY edit inside the primary checkout is blocked, yours included.
#
# KNOWN BUG: github/copilot-cli#3874 — a preToolUse denial coming from an agent-scoped hook did not
# take effect in some versions. This is a user-level hook (not agent-scoped), which is the variant
# that should work, but treat the guard as a best-effort safety net, not a guarantee.
#
# Blocks (when enabled):
#   - edit/create on a file inside the primary (main) worktree of its repository
#   - shell `git stash` anywhere
#   - shell commands run from inside the primary worktree that change its files, index or branch
#     (git checkout/switch/reset/restore/clean/commit/merge/rebase/pull/cherry-pick/am/apply,
#     sed -i / perl -i). `git worktree add`, `git fetch`, reads and `gh` stay allowed.
#
# Input (stdin):  {"sessionId":..,"timestamp":..,"cwd":"..","toolName":"bash|powershell|edit|create|..","toolArgs":{..} or "{..}"}
# Deny (stdout):  {"permissionDecision":"deny","permissionDecisionReason":"..."}
set -euo pipefail

[[ "${COPILOT_KIT_GUARD:-}" == "1" ]] || exit 0
command -v jq >/dev/null || exit 0

# Native Windows jq writes CRLF; a stray \r ends up inside every value it prints and breaks path
# and string comparisons. Always strip it.
jqr() { jq "$@" | tr -d '\r'; }

# Forward slashes everywhere, so C:\Users\me\repo and C:/Users/me/repo compare equal.
slashes() { local p="${1//\\//}"; printf '%s' "$p"; }

input="$(cat)"

deny() {
  jq -nc --arg reason "$1" '{permissionDecision: "deny", permissionDecisionReason: $reason}' | tr -d '\r'
  exit 0
}

# toolArgs is documented both as a parsed object and as a JSON string; accept either.
args_json="$(jqr -c '.toolArgs | if type == "string" then (try fromjson catch {}) else (. // {}) end' <<<"$input")"

# Prints the main worktree of the repo containing $1, or nothing if $1 is not in a git repo.
main_worktree() {
  local dir="$1"
  while [[ ! -d "$dir" && "$dir" != "/" && "$dir" != "." && ! "$dir" =~ ^[A-Za-z]:/?$ ]]; do dir="$(dirname "$dir")"; done
  git -C "$dir" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p' | tr -d '\r'
}

inside() { [[ "$1" == "$2" || "$1" == "$2"/* ]]; }

is_abs() { [[ "$1" == /* || "$1" =~ ^[A-Za-z]:/ ]]; }

# Canonical path: forward slashes, `.`/`..` collapsed, symlinks resolved on the longest existing
# prefix (macOS /tmp → /private/tmp), so a not-yet-created `../<repo>-feature-N` doesn't look like
# it is inside the primary checkout. Pure bash — no python needed (Windows has none by default).
real() {
  local p rest="" seg out="" IFS=/
  p="$(slashes "$1")"
  local existing="$p"
  while [[ ! -d "$existing" && "$existing" != "/" && "$existing" != "." && ! "$existing" =~ ^[A-Za-z]:/?$ ]]; do
    rest="/$(basename "$existing")$rest"; existing="$(dirname "$existing")"
  done
  p="$(cd "$existing" 2>/dev/null && pwd -P || printf '%s' "$existing")$rest"
  p="$(slashes "$p")"
  local -a parts=() stack=()
  read -ra parts <<<"$p"
  for seg in "${parts[@]}"; do
    case "$seg" in
      ""|".") ;;
      "..") (( ${#stack[@]} > 0 )) && unset 'stack[${#stack[@]}-1]' ;;
      *) stack+=("$seg") ;;
    esac
  done
  out="${stack[*]}"
  if [[ "$p" == /* ]]; then printf '/%s' "$out"; else printf '%s' "$out"; fi
}

tool="$(jqr -r '.toolName // empty' <<<"$input")"
cwd="$(slashes "$(jqr -r '.cwd // empty' <<<"$input")")"

case "$tool" in
  edit|create|str_replace_editor|str_replace_based_edit_tool)
    path="$(jqr -r '.path // .file_path // .filePath // .filepath // empty' <<<"$args_json")"
    [[ -z "$path" ]] && exit 0
    path="$(slashes "$path")"
    is_abs "$path" || path="$cwd/$path"
    parent="$(dirname "$path")"
    main="$(main_worktree "$parent")"
    [[ -z "$main" ]] && exit 0
    if inside "$(real "$parent")" "$(real "$main")"; then
      deny "Blocked: $path is inside the user's primary checkout ($main). Work only in your own worktree: create it, cd into it, and use paths under it. If you already changed files here, do NOT git checkout them; stop and report."
    fi
    ;;
  bash|powershell)
    cmd="$(jqr -r '.command // empty' <<<"$args_json")"
    if grep -Eq '(^|[^[:alnum:]_-])git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+stash([[:space:]]|$)' <<<"$cmd"; then
      deny "Blocked: git stash. The stash stack is shared by every worktree of this repo, so a pop can take other work than yours. Use a wip commit on your branch, or a throwaway worktree from origin/main for baseline comparisons."
    fi
    [[ -z "$cwd" ]] && exit 0
    main="$(main_worktree "$cwd")"
    [[ -z "$main" ]] && exit 0
    if inside "$(real "$cwd")" "$(real "$main")"; then
      # `cd <worktree> && ...` or `git -C <worktree> ...` runs somewhere else; judge by that target.
      target="$(sed -nE 's/^[[:space:]]*cd[[:space:]]+("([^"]+)"|([^[:space:];&|]+)).*/\2\3/p' <<<"$cmd")"
      [[ -z "$target" ]] && target="$(sed -nE 's/.*git[[:space:]]+-C[[:space:]]+("([^"]+)"|([^[:space:];&|]+)).*/\2\3/p' <<<"$cmd")"
      if [[ -n "$target" ]]; then
        target="${target/#\~/$HOME}"
        target="$(slashes "$target")"
        is_abs "$target" || target="$cwd/$target"
        inside "$(real "$target")" "$(real "$main")" || exit 0
      fi
      if grep -Eq '(^|[;&|[:space:]])git[[:space:]]+(checkout|switch|reset|restore|clean|commit|merge|rebase|pull|cherry-pick|am|apply)([[:space:]]|$)|(^|[;&|[:space:]])(sed|perl)[[:space:]]+(-[a-zA-Z]*i|--in-place)' <<<"$cmd"; then
        deny "Blocked: this command would modify the user's primary checkout ($main), which is your current directory. Create your worktree (git worktree add ...), cd into it, and run it there."
      fi
    fi
    ;;
esac
exit 0
