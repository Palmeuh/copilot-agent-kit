# copilot-agent-kit

A GitHub-Issues-driven agent workflow for the **GitHub Copilot CLI**, ported from `claude-agent-kit`. Work items are GitHub Issues (labelled by kind, status, priority and size); a planner files them, you approve them, and an implementer builds each approved issue in its own git worktree and merges it to `main` (or opens a PR, per project settings). `/ship-backlog` drains the approved queue **one issue at a time**.

## What's in it

| Path | What |
|---|---|
| `skills/issue-tracker/` | Labels, the status state machine, body templates and the `gh` commands. The source of truth the agents defer to. |
| `skills/ship-backlog/` | The sequential queue drain. Invoked as `/ship-backlog` (a skill, not a custom command). |
| `agents/planner.agent.md` | Slices a brief into feature issues. Never writes code. |
| `agents/implementer.agent.md` | Builds and ships one approved issue in its own worktree. |
| `agents/security-auditor.agent.md` | Optional pre-merge, diff-scoped security review. |
| `agents/explorer.agent.md` | Read-only "where is X" locator. |
| `scripts/backlog-queue.sh` | Deterministic queue bookkeeping (dependency order, priority, cycle check, stale worktrees). Needs `gh`, `jq`, `git`. |
| `hooks/` | Optional `preToolUse` guard that keeps sessions out of your primary checkout. Off unless `COPILOT_KIT_GUARD=1`. |

## Install

```bash
./install.sh
```

This symlinks everything into `~/.copilot/` (or `$COPILOT_HOME`): `agents/`, `skills/`, `hooks/`, `scripts/`. Re-running is safe. On Windows, Git Bash's `ln -s` silently copies unless you run it with `MSYS=winsymlinks:nativestrict` (needs Developer Mode); if it copied, re-run `install.sh` after every change to the repo.

Requirements: `gh` (authenticated), `jq`, `git`, and a bash (Git Bash on Windows).

Per project, add these sections to `AGENTS.md` (or `CLAUDE.md` / `.github/copilot-instructions.md`); the queue script and agents read them:

```markdown
## Branching
Simple: feature worktree per issue; implementer merges each into main directly (no PRs).
<!-- optional second line: PRs: on -->

## Deploy
Push to main auto-deploys via GitHub Actions.

## Security audit
PR audit: on
```

## Usage

```
copilot                       # start a session (pick Opus 5 with /model for planning and big issues)
/agent                        # browse and select an agent: planner, implementer, ...
/issue-tracker                # load the tracker conventions explicitly (also auto-selected by description)
/ship-backlog                 # drain the approved queue, one issue at a time
/ship-backlog 3 --kind=bug    # at most 3 issues, bugs only
/ship-backlog --plan          # show the order, do nothing
/ship-backlog --size=small    # only size:small (run this pass on Sonnet 5)
/model                        # switch model between passes
```

Typical flow:

1. `/agent planner`, describe a feature. It asks whether to file as `status:proposed` or `status:approved`, then files issues.
2. You relabel the ones you want built to `status:approved` (or tell the planner to file them approved).
3. `/ship-backlog`. For each issue: worktree → build → verify → (audit) → merge to `main` with `Closes #N`.
4. Review the merge commits. To request changes, reopen the issue, comment, and add `status:change-requested`; the next `/ship-backlog` picks it up first.

### Models

Only Opus 5 and Sonnet 5 are assumed. `size:small` issues suggest Sonnet 5; `size:large`, unlabelled issues and every rework suggest Opus 5. To actually use Sonnet for the small ones, run two passes: `/model` Sonnet → `/ship-backlog --size=small`, then `/model` Opus → `/ship-backlog`.

### The primary-checkout guard

`COPILOT_KIT_GUARD=1 copilot` turns on `hooks/guard-primary-checkout.sh`. It denies edits inside your primary checkout, `git stash`, and git commands that modify the primary checkout. Because Copilot's hook payload has no agent id, the guard cannot tell the implementer from you, so **it blocks your own edits in the primary checkout too** while it's on. Use it for `/ship-backlog` sessions only. The hook needs `jq`; on Windows it runs through Git Bash.

## Differences from claude-agent-kit

- **Sequential.** No orchestrator, no parallel waves, no memory/CPU-sized batches, no `--watch`/`--parallel`/`--serial`. One issue is finished and merged before the next starts. Dropped with it: the `orchestrator` and `recovery` agents.
- **Stale worktrees with unpushed work** are reported to you instead of handed to a recovery agent.
- **`/ship-backlog` is a skill**, not a slash command file; the implementer integrates its own branch (there is no separate integration step in the driver, except for orphans of an interrupted run).
- **No per-agent model pinning.** Agent files carry a commented-out `model:` line (see below); the model per issue is a suggestion you apply with `/model`, or the driver applies if your client's subagent tool accepts a model.
- **Tool names** are Copilot's aliases (`read`, `edit`, `search`, `execute`, `agent`). Claude-only tools (`AskUserQuestion`, `Task*`, `ScheduleWakeup`, `Cron*`) are gone; agents ask questions in chat.
- **The guard hook** is opt-in via an env var (see above) instead of scoped to subagents.
- `backlog-queue.sh` reads `AGENTS.md` → `CLAUDE.md` → `.github/copilot-instructions.md` (first one that has a `## Branching` or `## Security audit` section) instead of only `CLAUDE.md`. Its `memory`/`cpu` output is ignored by the sequential driver.

## Unverified

Written from the Copilot docs without being run against a live Copilot CLI session. Check these first:

1. **`~/.copilot/agents/` as the user-level agent directory.** The docs I could fetch confirm `.agent.md` files, their frontmatter, and repo-level use, but not the user-level path. If `/agent` doesn't list the agents after install, copy them to `.github/agents/` in the project instead.
2. **Whether a per-agent `model:` is honoured in the CLI, and the exact model name string** (e.g. `Claude Opus 5` vs an id). The `model:` lines in the agent files are commented out for that reason; uncomment them once you know the accepted value. Your org's model policy decides what actually runs regardless.
3. **Custom slash commands.** The CLI appears to have none, so `/ship-backlog` is a **skill** invoked by name (`/ship-backlog`, per the skills docs). If the slash form doesn't resolve, say "run the ship-backlog skill".
4. **Subagent support and model override** through the `agent` tool. The skills fall back to `/agent <name>` in the same session, or following the implementer's steps directly, when it's missing.
5. **Hook details.** Config location `~/.copilot/hooks/*.json` and the `preToolUse` input/deny format come from the docs, but `toolArgs` is described both as an object and as a JSON string (the guard accepts both), and the argument name for `edit`/`create` (`path`) is inferred. The guard was tested against synthetic payloads only. There is also an open bug, [github/copilot-cli#3874](https://github.com/github/copilot-cli/issues/3874), about `preToolUse` denials from agent-scoped hooks not taking effect; this kit's hook is user-level, but confirm a denial actually blocks before you rely on it.
6. **`gh`/label/issue commands and `backlog-queue.sh`** are carried over from the source kit; only the instructions-file lookup in the script changed, and it was syntax-checked (`bash -n`) but not run against a real repo.
