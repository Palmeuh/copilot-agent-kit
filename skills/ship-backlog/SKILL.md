---
name: ship-backlog
description: Drain the approved GitHub-issue queue (`status:approved` plus `status:change-requested` reworks) one issue at a time, in dependency and priority order, each in its own git worktree via the implementer agent, merging each verified branch straight into main (or develop in Complex projects). Use when the user says "ship the backlog", "drain the queue", "build the approved issues", or runs `/ship-backlog`. Sequential only — one issue is finished and integrated before the next starts.
---

# Ship Backlog

Work the **approved GitHub-issue queue** (`status:approved`, after any `status:change-requested` reworks) in dependency order, **one issue at a time**. Each issue is built by the `implementer` agent in its own worktree, verified, and integrated before the next one starts — **by default straight into `main`** (no PRs: the merge commit's `Closes #N` closes the issue and the push deploys), or into `develop` in Complex projects, where the implementer also opens the PR to `main` that the user merges. In projects that opt into audits, each branch is security-reviewed by the `security-auditor` agent before it merges. The run's output is a set of issues merged to `main` (default) or a stack of PRs awaiting the user's merge (PR projects: `PRs: on`, or Complex).

The bookkeeping — queue, built set, cycle check, pick order, orphans, stale worktrees — is computed by `~/.copilot/scripts/backlog-queue.sh` as one JSON document. The work itself lives in the implementer (one issue, one fresh context). The run **ends when the queue drains**; new approvals need a new run.

You are the **driver**. You do not write code yourself; you pick, hand off, check the result, and keep the log.

## Arguments

The text after `/ship-backlog` may contain (any order, all optional):

- A bare integer (e.g. `3`) — max number of issues to ship this run.
- `--plan` or `--dry-run` — print the order and stop. Do not invoke the implementer.
- `--kind=feature` (repeatable) — limit the queue to specific `kind`s. Example: `--kind=feature --kind=chore`.
- `--size=small` or `--size=large` — limit the queue to one size tier (see "Model guidance": this is how you run the cheap tier and the strong tier as two passes). Reworks count as `large`.
- `--audit` / `--no-audit` — force the pre-merge security audit on or off for this run. **Audits are opt-in per project**: the default is on only if the project's instructions file (`AGENTS.md`, else `CLAUDE.md` or `.github/copilot-instructions.md`) has a `## Security audit` section saying `PR audit: on`. `--no-audit` wins over everything.
- No arguments → ship every available approved issue, then exit.

## Model guidance

Only two models are assumed to be available: **Sonnet 5** and **Opus 5**. The queue script prints a suggested `model` per issue:

| condition | model |
|---|---|
| stream is **rework** (`status:change-requested`) | Opus 5 — the cheaper tier already fell short once; a second miss costs the user another review round |
| `size:small` | Sonnet 5 |
| `size:large` or no `size:*` label | Opus 5 |

Copilot CLI does not let this skill switch the session's model, and whether a per-agent `model:` or a subagent model override is honoured depends on your client version. So:

1. If the `agent` tool (subagents) is available **and** lets you pass a model, spawn the implementer with the issue's suggested model.
2. Otherwise the implementer runs on whatever the session is on. **Start the session on Opus 5** (`copilot --model <opus-5>` or `/model`) — the safe default — and say once at the start that `size:small` issues will run on Opus too.
3. To actually use Sonnet for the small ones, run two passes: `/model` → Sonnet 5, `/ship-backlog --size=small`; then `/model` → Opus 5, `/ship-backlog` for the rest (reworks and large). Dependencies still resolve across passes, because a dependency merged in pass one counts as built in pass two. Mention this option in the plan output when the queue mixes sizes.

Record the model each issue was *actually* run on in the run log (`#45 → sonnet (size:small)`), and note when it differs from the suggestion. The `security-auditor` should always get the strongest allowed model.

## Setup checks

Before doing anything:

1. **`gh` is healthy.** Run `gh auth status` and confirm a GitHub remote exists. If not, halt: *"this project's tracker is GitHub Issues; `gh` isn't authenticated / no GitHub remote. Fix that first."*
2. **Settle the mode from the project instructions file** (the queue script reads the same declarations, but you announce them):
   - `## Branching` — `Simple:` alone is the **default mode**: each verified branch is merged into `main`, no PRs. `Simple:` plus a `PRs: on` line: the implementer opens PRs and the user merges. `Complex:`: merges go into `develop`; PRs to `main` are for the user. **No section → halt** and ask the user to declare one; don't guess.
   - `## Security audit` — audits run only if it says `PR audit: on` or the user passed `--audit`; `--no-audit` wins over everything.
   Announce it in one line: *"mode: Simple, no PRs, audits off (project default)"*.
3. **Run the queue script** from the repo root and keep its output — it is the only source of queue truth:
   ```bash
   ~/.copilot/scripts/backlog-queue.sh --serial [--kind=K]...
   ```
   Apply `--size=` yourself by filtering the script's issues (`size` field; reworks are treated as large). Halt on `cycle` non-null: *"dependency cycle detected: 45 → 46 → 45. Fix the issues and re-run."* If `reworks` and `approved` are both empty, say *"nothing to ship — no reworks and no approved issues. New issues are filed `status:proposed`; approve the ones you want shipped."* and exit.
4. **Complex only — converge `develop` with `main`.** Hotfixes and abandoned branches make develop drift from main; bring main's history in before building on it, from the develop worktree (create it if absent: `git fetch origin && git worktree add ../<repo>-impl-develop develop`):
   ```bash
   cd ../<repo>-impl-develop && git pull --ff-only
   git merge --no-ff origin/main -m "merge main into develop" && git push
   ```
   On conflict: `git merge --abort`, record "develop needs manual convergence," continue.
5. **Reconcile the wreckage of an interrupted earlier run.** Skip nothing here: a crashed session leaves things the loop would trip over.
   - **`leftovers`** — a `../<repo>-impl-main` (or, outside Complex, `impl-develop`) worktree a crashed run failed to remove. It is detached and disposable: `git worktree remove --force <path>` and move on. Without this, `git worktree add` in the integration step fails on the path.
   - **`stale`** with `recover: false` — a feature worktree that is clean and fully pushed. Nothing on disk that origin lacks, so `git worktree remove <path>` is pure bookkeeping.
   - **`stale`** with `recover: true` — uncommitted changes, unpushed commits, or a branch origin has never seen. **Do not remove or reset these.** There is no recovery agent in this kit: list each one (issue, path, `dirty`/`pushed`/`ahead`) and ask the user whether to push it as a `wip/` branch, let the implementer continue in it, or discard it. Leave those issues alone until they answer.
   - **`orphans`** — `status:in-progress` issues whose pushed branch tip is not in the integration target: a previous run stopped between "branch pushed" and the merge. Integrate each **serially**, issue-number order, per "Integration" below (audit first when audits are on; a `security-audit:pass` whose `Audited HEAD` matches the branch tip counts). On conflict: abort the merge, leave the issue at `status:in-progress`, tell the user.

There is **no dirty-tree check**: nothing in this run touches the user's primary checkout — the implementer works in its own worktrees and merges from a detached one. And there is **no deploy-cadence question**: in the default mode every merge to `main` is a deploy (per `## Deploy`); in PR projects the user's merge is.

## The queue — what the script computes

`backlog-queue.sh` prints one JSON document. These are its rules, so you can sanity-check the output and explain the plan; never recompute them by hand:

- **Two streams.** `reworks` = open `status:change-requested`; `approved` = open `status:approved`. `--kind=` filters both. Each issue carries `kind`, `size`, `priority`, `stream`, `depends_on` (parsed from the `Depends on: #M` line in the body) and a suggested `model`.
- **Pick order.** Reworks first, then new work; within each stream `priority:high`, then untagged, then `priority:low`, then lowest number.
- **`built`.** Every distinct dependency is checked directly with `gh issue view`. Default mode: built = **closed** (merged to main). PR projects: built = closed, **or** open with a pushed branch the dependent can stack on.
- **Available** = all reworks + approved issues whose every dependency is built; `blocked` lists the rest with the missing numbers. Recomputed on every run of the script — an issue you shipped this run is built and unblocks its dependents *within the same run*.
- **`cycle`** — non-null means halt.
- **`wave`** — with `--serial` this is at most one issue: the next pick. (Ignore `memory` and `cpu`; they only matter for parallel runs.)
- **`orphans`, `stale`, `leftovers`** — debris from an interrupted run (setup check 5).
- **`mode`** — `strategy`, `prs`, `audit`, `target` as read from the instructions file.

If `wave` is empty but `approved` is not, halt with: *"N approved issues remain, but each depends on an issue that hasn't been built yet (still `status:proposed`/`status:approved`, or excluded by the filter). Blocked: <list from `blocked`>."*

## `--plan` / `--dry-run` mode

Print the order the loop *would* attempt, in plain text, from the script's output. Do not invoke the implementer:

```
backlog plan (4 approved issues, filter: none, mode: Simple, no PRs):

  1. #45 feature  csv export of watchlist            sonnet  (deps: —)
  2. #48 bug      polling doesn't restart after re-ask opus   (deps: —)
  3. #46 feature  notes textarea on detail page      sonnet  (deps: #45 — after #45 merges this run)
  4. #47 feature  notes search on list               opus    (deps: #45 — after #45 merges this run)
```

Show the build order and the suggested model per issue. A dependent follows a dependency built earlier in the same run (in PR projects: "stacks on #45 this run"), so the whole chain is reachable in one pass; only flag a dependency that won't be built this run (unapproved, or excluded by the filter). If sizes are mixed, mention the two-pass option from "Model guidance". Then stop.

## The loop

Repeat until the queue is empty, the limit is hit, or something halts:

1. **Pick.** Run the queue script with `--serial`; `wave[0]` is the pick (apply `--size=` to it). Empty → leave the loop (queue exhausted, or all-blocked — `blocked` says which) and go to the final report.
2. **Check limit.** If an integer N was given and you've already shipped N, exit ("limit reached").
3. **Announce** in one line: `iteration K: shipping #NNN <title> (<model>)`.
4. **Hand the issue to the implementer.** Preferably as a subagent through the `agent` tool (`agent: implementer`) so the issue gets a fresh context; if your client has no subagents, switch with `/agent implementer` and continue in that session, or as a last resort follow `implementer.agent.md` yourself in the current session. Prompt template:

   > Implement issue **#NNN** (stream: **<new | rework>**) as part of a `/ship-backlog` run (iteration K). The project's mode is **<Simple, no PRs | Simple with PRs | Complex>**; audits are **<on | off>**.
   >
   > - If **new**: the issue is `status:approved` — relabel `status:in-progress`, build and verify on your branch per your normal flow.
   > - If **rework**: the issue is `status:change-requested` — run your **rework flow**: read the feedback (issue comments; PR comments/reviews in PR projects), fix on the existing branch if it still exists, else on a fresh one from `origin/main`; no new PR, no force-push.
   > - **Work this one issue only, then stop.** Integrate it yourself per your "Shipping" section (audit first if audits are on, then merge; Simple with PRs: open the PR; Complex: merge into develop and open the PR to `main`) and return.
   > - **Stacking (PR projects only):** this issue `Depends on:` #MMM, built earlier this run but not merged (branch `<kind>/MMM-<slug>`) — branch from that branch and base your PR on it. *(Omit in the default mode and for independent issues.)*
   > - Load the project instructions file yourself. Refactors need no confirmation — approval is approval.
   > - Follow your "Isolation and process hygiene" rules to the letter: create your worktree and `cd` into it before any edit, never touch the primary checkout, **never `git stash`**, run tests in the foreground under `timeout`, and kill every process you start before reporting.
   > - When done, return a one-paragraph summary: branch name, merge SHA or PR URL, what was verified, audit verdict, any deferred items.
   > - If you have to halt (red flag), return what you saw and the 2–3 options you'd propose.

5. **Read the result.** Parse the implementer's summary into one of:
   - **merged** (default mode / Complex-develop) or **PR opened / updated** — finished work. Confirm it on GitHub rather than trusting the summary: `git fetch origin` and check that the merge commit is on `origin/<target>` (`git log origin/<target> --oneline -5`) and that the issue is closed or relabelled as expected (`gh issue view N --json state,labels`). If it isn't, treat it as halted.
   - **audit-blocked** — the auditor relabelled the issue `status:change-requested`. It re-enters the rework stream: the next pick will be this issue as a rework (on Opus). **Cap: 2 audit rounds per issue per run.** If round 2 still blocks, stop looping that issue: leave it `status:change-requested` for the user, record it as "audit-blocked," and continue with other issues (its dependents stay blocked this run).
   - **halted** — the implementer hit a red flag and did not finish (issue likely `status:in-progress`). Exit the loop. Do not power through. Surface it to the user.
   - **abandoned** — the user chose to close the issue as not-planned via the implementer's red-flag flow. Continue the loop.
6. **Append to the run log** (in memory, surfaced at the end):
   - `#NNN <title> — merged to main (abc1234), sonnet, audit: PASS` / `#NNN <title> — PR #<pr> opened (abc1234), opus, audit: PASS (round 2)` or
   - `#NNN <title> — AUDIT-BLOCKED after round 2: <one-line headline>` or
   - `#NNN <title> — HALTED: <one-line reason>`
7. **Loop.** Re-run the script; the issue you just shipped is now built and its dependents show up as available.

Never start the next issue on a red target: the implementer halts on a red baseline, which is the correct outcome — surface it, don't retry.

**Never end the run between an audit PASS and the merge.** If the run is interrupted anyway, the next run's orphan reconciliation repairs it — but don't rely on that.

## Integration (orphans and reference)

Normally the implementer integrates its own branch. The blocks below are what it does, and what you do for an **orphan** found in setup check 5. One branch at a time, in issue-number order, from a worktree that is never the user's primary checkout.

**Default — Simple, no PRs → merge into `main`** from a detached worktree:

```bash
git fetch origin
git worktree add --detach ../<repo>-impl-main origin/main
cd ../<repo>-impl-main
git merge --no-ff <kind>/N-<slug> -m "<issue title> (Closes #N)"
git push origin HEAD:main                                   # non-fast-forward: fetch, reset --hard origin/main, redo the merge, push
gh issue edit N --remove-label "status:in-progress"         # the push closed the issue; closed + no status label = shipped
git branch -d <kind>/N-<slug>                               # HEAD here contains it, so -d is a real merged check
git push origin --delete <kind>/N-<slug>                    # the branch has served its purpose
cd ../<repo> && git worktree remove ../<repo>-impl-main
```

On a merge conflict: `git merge --abort`, leave the issue at `status:in-progress` with its branch, record it as "needs manual integration," and continue; its dependents stay blocked this run.

**Complex → merge into `develop`, relabel:**

```bash
cd ../<repo>-impl-develop && git pull --ff-only
git merge --no-ff <kind>/N-<slug> -m "merge <kind>/N-<slug> into develop" && git push
git merge-base --is-ancestor <kind>/N-<slug> HEAD              # invariant check
gh issue edit N --remove-label "status:in-progress" --add-label "status:in-review"
```

On conflict: `git merge --abort`, leave the issue at `status:in-progress`, record it as "needs manual integration." The PR to `main` the implementer opened is the user's promotion request.

**Simple with `PRs: on` → nothing to integrate.** The implementer opened the PR and relabelled `status:in-review`.

## End-of-run sweep

Before the final report, leave the machine and repo tidy. Stray branches, worktrees and processes pile up across runs and mislead the next run's reconciliation.

1. **Worktrees.** List every worktree of the repo (`git worktree list`). Remove each one whose HEAD is already in the integration target and that has no tracked changes and no untracked files outside `node_modules`, `generated` and `dist` (`git worktree remove --force`). Leave anything with real uncommitted or unmerged work, and name it in the report.
2. **Branches.** Delete local branches already merged into the target (`git merge-base --is-ancestor <b> origin/<target>` → `git branch -d <b>`), and remote feature branches in the same state (`git push origin --delete <b>`). Keep unmerged branches that belong to an issue still in flight; list any other unmerged branch in the report and don't delete it.
3. **Processes.** Look for dev servers, `vite`, `tsx watch`, `vitest` and headless browsers whose command line points at a worktree that no longer exists. Kill those. Don't touch processes running from the primary checkout; those may be the user's. List them instead.
4. **Primary checkout.** `git pull --ff-only` in the user's checkout so it holds what was shipped. If it has diverged (the user's own unpushed commits) or has tracked changes, don't rebase, stash or reset. Report it and leave the choice to the user.

## Final report

Default mode:

```
merged to main (each merge deployed and closed its issue):
  #45 csv export of watchlist            → a1b2c3d  sonnet  audit: PASS
  #46 notes textarea on detail page      → e4f5g6h  opus    audit: PASS (round 2, rework on opus)
  #47 notes search on list               → i9j0k1l  sonnet  audit: PASS

audit-blocked (left at status:change-requested, branch kept):
  #48 file attachment upload             → feature/48-file-upload — path traversal in download
      handler still reproducible after round 2; findings are on the issue.

needs manual integration (left at status:in-progress):
  #53 saved filters                      → feature/53-saved-filters — merge conflict with #52

needs your decision (stale worktrees with unpushed work):
  #54 → ../myapp-feature-54-… (dirty, not pushed)

incidental security issues filed by the auditor (status:proposed): #51

halted at #49 polling doesn't restart after re-ask
  reason: <one-line reason from the implementer>
  options proposed: <bullet list>

not attempted (1): #50

next step: review the merge commits above — each issue carries a Verification comment.
Reopen an issue with a comment + status:change-requested if something needs to change.
```

PR projects replace the first block with `PRs opened (awaiting your review + merge to main)` rows (`→ PR #120  (a1b2c3d)  sonnet  audit: PASS  [stacked on #45]`) and end with *"test the whole feature on dev (Complex) or the tip branch, then merge the stacked PRs to main IN ORDER — #45 first, then #46, #47 — as merge commits, not squashes. Each merge deploys and closes its issue."*

Omit the audit columns/sections when audits were off for this run — and say so, plus whether that was the project default or a flag ("run was unaudited — this project has no `## Security audit` section"). If the model an issue ran on differed from the suggestion (see "Model guidance"), say so.

## Halt vs stop

The driver **halts** (clean exit, surface to the user) on:

- The implementer returned a red-flag halt.
- Dependency cycle detected before the loop.
- All approved issues are blocked (no available pick, queue non-empty).
- The limit argument is satisfied, or the queue drained.

The driver **never**:

- Auto-fixes the implementer's halt cause.
- Merges a PR. In PR projects the user's merge is the deploy gate. In the default mode the only thing merged is a branch an implementer reported verified, only after a passing audit where audits are on.
- Reorders the queue around a halted issue.
- Re-invokes the same implementer with extra hints. One try per issue per run (an audit-block rework is the one designed exception).
- Touches a stale worktree that holds unpushed work without asking the user.

## What this skill does NOT do

- Does not write code itself. All work is in the implementer.
- Does not plan or file new issues. If the queue is empty, exit — don't call the planner.
- Does not approve issues. It only drains `status:approved`; the user owns approval.
- Does not merge PRs, run deploy scripts, or trigger prod workflows. In the default mode the merge into `main` *is* the ship and whatever CI does on push is the deploy.
- Does not run parallel waves, watch for new approvals, or recover aborted parallel runs (those belong to `claude-agent-kit`). Re-run `/ship-backlog` after approving more issues.
- Does not run if `gh` is unhealthy, there's no GitHub remote, or the project instructions file has no `## Branching` section.

## Worked example

User: `/ship-backlog 4 --kind=feature` in a default-mode project (Simple, no PRs, audits off).

Setup:
- Approved open: 45 (feature, size:small), 46 (feature, deps #45), 47 (feature, deps #45), 48 (bug), 52 (feature, priority:high). Closed: 44.
- Filter `--kind=feature` narrows to {45, 46, 47, 52}. Limit is 4. No cycles.

Iteration 1: `wave[0]` = #52 (independent, `priority:high`). Hand it to the implementer; it merges `feature/52-…` into main (jkl3456) and the issue closes.
Iteration 2: re-run the script — `wave[0]` = #45. Merged (abc1234). #45 is now closed, so #46 and #47 are available.
Iteration 3: #46, branching from `origin/main` (which now contains #45). Merged (def5678).
Iteration 4: #47. Merged (ghi9012). Limit (4) reached → exit.

In a PR project the same run ends with four open PRs instead, #46 and #47 stacked on #45's branch, and the user tests the chain on dev (Complex) or #47's tip branch before merging in order.

```
merged to main (each merge deployed and closed its issue):
  #52 saved filters               → jkl3456  opus
  #45 csv export of watchlist     → abc1234  sonnet
  #46 notes textarea              → def5678  sonnet
  #47 notes search                → ghi9012  sonnet

next step: review the merge commits; reopen an issue with a comment + status:change-requested
if something needs to change.
```

## Implementation notes

You have file reading, search, the shell (for the queue script, `gh`, `git`), and — if your client has it — the `agent` tool. The loop is a straightforward for-each. Don't overengineer:

- The queue script is the single source of queue truth: run it at setup and after every issue. Never recompute the built set, the cycle check or the pick order by hand.
- Stream the one-line `iteration K: shipping #NNN <title> (<model>)` before each hand-off.
- When the queue drains, exit with the final report. No polling, no sleeping, no scheduled wake-ups.
- Resist being "helpful" beyond the loop. If something feels off, halt and ask.
