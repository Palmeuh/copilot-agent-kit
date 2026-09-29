#!/usr/bin/env bash
# backlog-queue.sh — the deterministic bookkeeping behind /ship-backlog.
#
# Run from a project checkout. Reads the GitHub-issue queue with `gh`, the branching
# and audit declarations from the project instructions file (AGENTS.md, else CLAUDE.md, else .github/copilot-instructions.md), and the host's free memory, then prints ONE
# JSON document the caller acts on. Read-only: never writes to GitHub or the repo
# (the only git side effect is `git fetch origin --prune`).
#
# usage: backlog-queue.sh [--kind=K]... [--parallel N | --serial] [--footprint-mb N] [--cores-per-agent N] [--limit N]
#
#   --kind=K          keep only issues labelled kind:K (repeatable)
#   --parallel N      cap the wave at N issues (further capped by memory and CPU)
#   --serial          wave of one
#   --footprint-mb N  RAM one implementer needs at build+test time (default 2500 for .NET; ~1000 for Node)
#   --cores-per-agent N  CPU cores one implementer's build+test needs (default 2)
#   --limit N         gh list page size (default 1000)
#
# Output shape:
#   mode      { strategy: simple|complex|null, prs: bool, audit: bool, target: main|develop|null }
#   reworks   open status:change-requested issues, in pick order
#   approved  open status:approved issues (after --kind filter), with depends_on
#   built     dependency numbers that count as built (see "built" rule in the ship-backlog skill)
#   blocked   approved issues whose dependencies are not all built, with the missing numbers
#   cycle     null, or the issue numbers caught in a Depends-on cycle (halt if non-null)
#   wave      the issues to spawn next: reworks first, then available new work, priority then
#             number order, mutually independent, capped by --parallel/--serial, memory and CPU
#   memory    { os, available_mb, footprint_mb, cap }
#   cpu       { cores, cores_per_agent, cap }
#   orphans   status:in-progress issues whose pushed branch tip is not in mode.target
#   stale     feature worktrees still on disk (../<repo>-<kind>-N-<slug>) with per-tree facts:
#             issue, branch, dirty (ignoring node_modules/generated/dist), pushed, ahead (commits
#             origin lacks), merged (tip already in mode.target), recover (true when something
#             would be lost by removing it) — an interrupted run's unfinished work
#   leftovers integration worktrees a crashed run failed to remove (impl-main; impl-develop
#             only outside Complex, where it is persistent by design)
set -euo pipefail

KINDS=()
PARALLEL=""
SERIAL=0
FOOTPRINT_MB=2500
CORES_PER_AGENT=2
LIMIT=1000

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kind=*) KINDS+=("${1#--kind=}") ;;
    --parallel) PARALLEL="$2"; shift ;;
    --parallel=*) PARALLEL="${1#--parallel=}" ;;
    --serial) SERIAL=1 ;;
    --footprint-mb) FOOTPRINT_MB="$2"; shift ;;
    --footprint-mb=*) FOOTPRINT_MB="${1#--footprint-mb=}" ;;
    --cores-per-agent) CORES_PER_AGENT="$2"; shift ;;
    --cores-per-agent=*) CORES_PER_AGENT="${1#--cores-per-agent=}" ;;
    --limit) LIMIT="$2"; shift ;;
    -h|--help) sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "backlog-queue: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

for tool in gh jq git; do
  command -v "$tool" >/dev/null || { echo "backlog-queue: $tool not found" >&2; exit 2; }
done
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "backlog-queue: not inside a git repository" >&2; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ---------------------------------------------------------------------------------------
# Mode: read the project instructions declarations (AGENTS.md, else CLAUDE.md, else .github/copilot-instructions.md) instead of guessing from repo state.
# ---------------------------------------------------------------------------------------
section() {  # section <heading-regex> <file> — body of one ## section
  awk -v h="$1" '$0 ~ "^## " h {f=1; next} /^## /{f=0} f' "$2"
}

strategy=null
prs=false
audit=false
target=null
INSTRUCTIONS=""
for f in AGENTS.md CLAUDE.md .github/copilot-instructions.md; do
  if [[ -f "$f" ]] && grep -qE '^## (Branching|Security audit)' "$f"; then INSTRUCTIONS="$f"; break; fi
done
if [[ -n "$INSTRUCTIONS" ]]; then
  branching="$(section 'Branching' "$INSTRUCTIONS")"
  if grep -qiE '^[[:space:]]*Complex:' <<<"$branching"; then
    strategy='"complex"'; prs=true; target='"develop"'
  elif grep -qiE '^[[:space:]]*Simple:' <<<"$branching"; then
    strategy='"simple"'; target='"main"'
    if grep -qiE '^[[:space:]]*PRs:[[:space:]]*on' <<<"$branching"; then prs=true; target=null; fi
  fi
  if grep -qiE '^[[:space:]]*PR audit:[[:space:]]*on' <<<"$(section 'Security audit' "$INSTRUCTIONS")"; then audit=true; fi
fi

# ---------------------------------------------------------------------------------------
# Queue: three lists, explicit --limit so nothing is silently truncated at gh's default 30.
# ---------------------------------------------------------------------------------------
git fetch origin --prune --quiet

gh issue list --label "status:change-requested" --state open --limit "$LIMIT" --json number,title,labels,body > "$tmp/reworks.json"
gh issue list --label "status:approved"         --state open --limit "$LIMIT" --json number,title,labels,body > "$tmp/approved.json"
gh issue list --label "status:in-progress"      --state open --limit "$LIMIT" --json number,title,labels      > "$tmp/inprogress.json"

kinds_json="$(printf '%s\n' "${KINDS[@]+"${KINDS[@]}"}" | jq -R . | jq -sc 'map(select(length > 0))')"

# Normalise one issue: kind/size/priority from labels, depends_on from the body, model per
# the ship-backlog "Model selection" table (rework → opus, size:small → sonnet, else opus).
NORMALISE='
def label_val($p): [ .labels[].name | select(startswith($p)) | ltrimstr($p) ] | .[0];
def prio_rank: if .priority == "high" then 0 elif .priority == "low" then 2 else 1 end;
def depends_on:
  [ (.body // "") | split("\n")[]
    | select(test("^[ \\t]*depends on:"; "i"))
    | scan("#(\\d+)") | .[0] | tonumber ] | unique;
def normalise($stream):
  { number, title,
    kind:     label_val("kind:"),
    size:     (label_val("size:") // "large"),
    priority: label_val("priority:"),
    stream:   $stream,
    depends_on: (if $stream == "new" then depends_on else [] end) }
  | .model = (if .stream == "rework" then "opus" elif .size == "small" then "sonnet" else "opus" end);
def pick_order: sort_by([prio_rank, .number]);
def kind_ok($kinds): ($kinds | length) == 0 or (.kind as $k | $kinds | index($k) != null);
'

jq -c --argjson kinds "$kinds_json" "$NORMALISE"'
  [ .[] | normalise("rework") | select(kind_ok($kinds)) ] | pick_order' "$tmp/reworks.json" > "$tmp/reworks.n.json"
jq -c --argjson kinds "$kinds_json" "$NORMALISE"'
  [ .[] | normalise("new") | select(kind_ok($kinds)) ] | pick_order' "$tmp/approved.json" > "$tmp/approved.n.json"

# ---------------------------------------------------------------------------------------
# Built set: check every distinct dependency directly with `gh issue view` — never from a
# truncated list. Default (no-PR) mode: built = closed. PR modes: built = closed, or open
# with a pushed branch the dependent can stack on.
# ---------------------------------------------------------------------------------------
branch_for() {  # branch_for <issue-number> — remote branch(es) named <kind>/N-<slug>
  git for-each-ref --format='%(refname:short)' "refs/remotes/origin/*/$1-*" | sed 's#^origin/##'
}

deps=()   # bash 3.2 (macOS) has no mapfile
while IFS= read -r d; do [[ -n "$d" ]] && deps+=("$d"); done \
  < <(jq -r '[ .[] | .depends_on[] ] | unique | .[]' "$tmp/approved.n.json")
: > "$tmp/built.txt"
for m in "${deps[@]+"${deps[@]}"}"; do
  view="$(gh issue view "$m" --json number,state,labels 2>/dev/null || echo '{}')"
  state="$(jq -r '.state // "MISSING"' <<<"$view")"
  status="$(jq -r '[ .labels[]?.name | select(startswith("status:")) ] | .[0] // ""' <<<"$view")"
  if [[ "$state" == "CLOSED" ]]; then
    echo "$m" >> "$tmp/built.txt"
  elif [[ "$prs" == true && "$state" == "OPEN" ]]; then
    case "$status" in
      status:in-review|status:change-requested|status:in-progress)
        [[ -n "$(branch_for "$m")" ]] && echo "$m" >> "$tmp/built.txt" ;;
    esac
  fi
done
built_json="$(jq -Rsc 'split("\n") | map(select(length > 0) | tonumber) | unique' "$tmp/built.txt")"

# ---------------------------------------------------------------------------------------
# Orphans: in-progress issues with a pushed branch whose tip is not in the integration target
# (an interrupted run stopped between "branch pushed" and the caller's merge).
# ---------------------------------------------------------------------------------------
: > "$tmp/orphans.jsonl"
if [[ "$target" != null ]]; then
  t="$(jq -r . <<<"$target")"
  if git rev-parse --verify --quiet "origin/$t" >/dev/null; then
    while IFS=$'\t' read -r n title; do
      [[ -z "$n" ]] && continue
      while IFS= read -r br; do
        [[ -z "$br" ]] && continue
        if ! git merge-base --is-ancestor "origin/$br" "origin/$t"; then
          jq -nc --argjson n "$n" --arg title "$title" --arg branch "$br" --arg target "$t" \
            '{number: $n, title: $title, branch: $branch, target: $target}' >> "$tmp/orphans.jsonl"
        fi
      done < <(branch_for "$n")
    done < <(jq -r '.[] | [.number, .title] | @tsv' "$tmp/inprogress.json")
  fi
fi
orphans_json="$(jq -sc '.' "$tmp/orphans.jsonl")"

# ---------------------------------------------------------------------------------------
# Stale worktrees: an aborted run (Ctrl-C, OOM, crash) leaves ../<repo>-<kind>-N-<slug> on
# disk with whatever the implementer had done. The pushed/orphan path above only sees work
# that reached origin; this lists what is still only on disk so the caller can route it
# to recovery instead of leaving the issue stuck at status:in-progress forever.
# ---------------------------------------------------------------------------------------
toplevel="$(git rev-parse --show-toplevel)"
repo="$(basename "$toplevel")"
parent="$(dirname "$toplevel")"
: > "$tmp/stale.jsonl"
: > "$tmp/leftovers.jsonl"
wt_path=""; wt_branch=""; wt_detached=0
emit_worktree() {
  [[ -z "$wt_path" || "$wt_path" == "$toplevel" ]] && return
  local base="${wt_path#"$parent"/}"
  case "$base" in
    "$repo-impl-main")
      jq -nc --arg path "$wt_path" --arg role "impl-main" '{path: $path, role: $role}' >> "$tmp/leftovers.jsonl" ;;
    "$repo-impl-develop")
      [[ "$strategy" != '"complex"' ]] && jq -nc --arg path "$wt_path" --arg role "impl-develop" '{path: $path, role: $role}' >> "$tmp/leftovers.jsonl" ;;
    "$repo"-*)
      local n branch dirty pushed ahead merged base_ref
      branch="${wt_branch#refs/heads/}"
      n="$(sed -nE 's#^[^/]+/([0-9]+)-.*#\1#p' <<<"$branch")"
      [[ -z "$n" ]] && return
      # Build output (node_modules symlinks, generated clients, dist) is not work worth recovering.
      dirty=false
      # `status --porcelain` prefixes each path with "XY " (2 status chars + space); cut it so the
      # path anchors at column 1, then drop build output at any depth (foo/node_modules/… included).
      [[ -n "$(git -C "$wt_path" status --porcelain 2>/dev/null \
               | cut -c4- | grep -v -E '(^|/)(node_modules|generated|dist)(/|$)')" ]] && dirty=true
      base_ref="origin/main"; [[ "$target" != null ]] && base_ref="origin/$(jq -r . <<<"$target")"
      # A tip already in the target is shipped work: after the merge the remote branch is deleted,
      # so "not pushed" alone must not flag it for recovery.
      merged=false; git merge-base --is-ancestor "$branch" "$base_ref" 2>/dev/null && merged=true
      if git rev-parse --verify --quiet "origin/$branch" >/dev/null; then
        pushed=true; ahead="$(git rev-list --count "origin/$branch..$branch" 2>/dev/null || echo 0)"
      else
        pushed=false
        ahead="$(git rev-list --count "$base_ref..$branch" 2>/dev/null || echo 0)"
      fi
      jq -nc --argjson n "$n" --arg path "$wt_path" --arg branch "$branch" \
        --argjson dirty "$dirty" --argjson pushed "$pushed" --argjson ahead "$ahead" --argjson merged "$merged" \
        '{number: $n, path: $path, branch: $branch, dirty: $dirty, pushed: $pushed, ahead: $ahead, merged: $merged,
          recover: ($dirty or (($merged | not) and (($pushed | not) or $ahead > 0)))}' >> "$tmp/stale.jsonl" ;;
  esac
}
while IFS= read -r line; do
  case "$line" in
    "worktree "*) emit_worktree; wt_path="${line#worktree }"; wt_branch=""; wt_detached=0 ;;
    "branch "*)   wt_branch="${line#branch }" ;;
    detached)     wt_detached=1 ;;
    "")           emit_worktree; wt_path="" ;;
  esac
done < <(git worktree list --porcelain)
emit_worktree
stale_json="$(jq -sc 'sort_by(.number)' "$tmp/stale.jsonl")"
leftovers_json="$(jq -sc '.' "$tmp/leftovers.jsonl")"

# ---------------------------------------------------------------------------------------
# Memory: measured, not guessed. cap = available / footprint, never below 1.
# ---------------------------------------------------------------------------------------
os="$(uname -s)"
available_mb=null
case "$os" in
  Linux)
    if command -v free >/dev/null; then available_mb="$(free -m | awk '/^Mem:/{print $7}')"; fi ;;
  Darwin)
    page="$(sysctl -n hw.pagesize)"
    pages="$(vm_stat | awk '/Pages (free|inactive|speculative):/{gsub("\\.","",$NF); s+=$NF} END{print s+0}')"
    available_mb=$(( pages * page / 1024 / 1024 )) ;;
esac
if [[ "$available_mb" == null ]]; then mem_cap=null; else mem_cap=$(( available_mb / FOOTPRINT_MB )); (( mem_cap < 1 )) && mem_cap=1; fi

# CPU: every implementer runs a full build + multi-worker test suite. Oversubscribing the cores
# doesn't fail loudly like OOM — it makes timing-sensitive tests flake and test runs hang, which
# stalls the whole wave (12 agents on 12 cores reached load ~195). cap = cores / cores-per-agent.
case "$os" in
  Darwin) cores="$(sysctl -n hw.ncpu)" ;;
  *)      cores="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 0)" ;;
esac
if (( cores > 0 )); then cpu_cap=$(( cores / CORES_PER_AGENT )); (( cpu_cap < 1 )) && cpu_cap=1; else cpu_cap=null; fi

# ---------------------------------------------------------------------------------------
# Cycle check, availability, wave.
# ---------------------------------------------------------------------------------------
jq -nc \
  --slurpfile reworks "$tmp/reworks.n.json" \
  --slurpfile approved "$tmp/approved.n.json" \
  --argjson built "$built_json" \
  --argjson orphans "$orphans_json" --argjson stale "$stale_json" --argjson leftovers "$leftovers_json" \
  --argjson strategy "$strategy" --argjson prs "$prs" --argjson audit "$audit" --argjson target "$target" \
  --arg os "$os" --argjson available_mb "$available_mb" --argjson footprint_mb "$FOOTPRINT_MB" --argjson mem_cap "$mem_cap" \
  --argjson cores "${cores:-0}" --argjson cores_per_agent "$CORES_PER_AGENT" --argjson cpu_cap "$cpu_cap" \
  --arg parallel "$PARALLEL" --argjson serial "$SERIAL" '
  ($reworks[0]) as $reworks | ($approved[0]) as $approved
  | ($reworks + $approved) as $open
  | ($open | map(.number)) as $open_ids

  # Kahn: peel nodes whose in-set deps are done; whatever remains is a cycle.
  | ( { rem: [ $open[] | { n: .number, d: [ .depends_on[] | select(IN($open_ids[])) ] } ], done: [], stuck: false }
      | until((.rem | length) == 0 or .stuck;
          .done as $done
          | ([ .rem[] | select(((.d - $done) | length) == 0) | .n ]) as $ready
          | if ($ready | length) == 0 then .stuck = true
            else .done += $ready | .rem |= map(select(.n | IN($ready[]) | not)) end)
      | if (.rem | length) > 0 then [ .rem[].n ] else null end ) as $cycle

  | ([ $approved[] | select(all(.depends_on[]; IN($built[]))) ]) as $available_new
  | ([ $approved[] | select(all(.depends_on[]; IN($built[])) | not)
        | { number, title, missing: [ .depends_on[] | select(IN($built[]) | not) ] } ]) as $blocked

  # Mutually independent wave, in pick order: reworks, then available new work.
  | ( reduce ($reworks + $available_new)[] as $x ([];
        if any(.[]; .number as $w | $x.depends_on | index($w) != null)
           or any(.[]; .depends_on | index($x.number) != null)
        then . else . + [$x] end) ) as $indep
  | ( [ (if $serial == 1 then 1 else empty end),
        (if $parallel != "" then ($parallel | tonumber) else empty end),
        (if $mem_cap != null then $mem_cap else empty end),
        (if $cpu_cap != null then $cpu_cap else empty end) ] | min ) as $cap
  | ( if $cap == null then $indep else $indep[:$cap] end ) as $wave

  | { mode: { strategy: $strategy, prs: $prs, audit: $audit, target: $target },
      reworks: $reworks,
      approved: $approved,
      built: $built,
      blocked: $blocked,
      cycle: $cycle,
      wave: $wave,
      memory: { os: $os, available_mb: $available_mb, footprint_mb: $footprint_mb, cap: $mem_cap },
      cpu: { cores: $cores, cores_per_agent: $cores_per_agent, cap: $cpu_cap },
      orphans: $orphans,
      stale: $stale,
      leftovers: $leftovers }'
