---
name: issue-tracker
description: Track features, bugs, refactorings, security issues, and chores as GitHub Issues in the current project, labelled by kind and moved through an approval/deploy state machine. Invoke when (a) the user asks for an audit/review of the codebase to find bugs, security issues, or refactoring opportunities — every finding becomes a GitHub issue; (b) you propose multi-step work or items from a code-review sweep that should be tracked; or (c) the user says "log this", "track this", "plan for this", "open an issue", "create an issue", "audit the code", "look for bugs", "find security issues", "look for refactorings", "review the code", or references an existing item like "go ahead with issue 102", "approve issue 47", "close issue 12", "what's the status of issue 12".
---

# issue-tracker

A reusable convention for tracking work items as **GitHub Issues** in any project, via the `gh` CLI. One issue per work item; GitHub's numbering, open/closed state, and `gh issue list` are the only index — no local files. Labels carry kind and status; the lifecycle is a state machine gated by the user's approval to implement. By default an approved issue is built on a branch and merged straight into `main` — no PR; projects that opt into PRs (`PRs: on` under `## Branching`, or the Complex strategy) add a second gate, approval to deploy. Work items only — planning docs (architecture decisions, RFCs) live elsewhere.

The bar for filing: **would the user want to find this again next week?** Don't file trivial inline fixes being applied right now — chat is enough. On an audit/review request, every finding becomes an issue; never just dump findings into chat.

## Prerequisite: `gh` and labels

Everything runs through `gh`. Assume the repo has a GitHub remote and `gh auth status` is healthy; if either is missing, **halt and tell the user** — don't fall back to a local file tracker.

**Always read issues/PRs with explicit `--json` fields.** Bare `gh issue view N` (and `gh pr view` without `--json`) queries the deprecated Projects-classic `projectCards` GraphQL field and fails on some repos/gh versions. Standard forms: `gh issue view N --json number,title,body,labels,comments` and `gh pr view <pr> --json number,title,body,comments,reviews`.

The tracker relies on a fixed label set. Priority is optional and three-valued: `priority:high`, no label (normal), `priority:low` — the implementer works high → untagged → low, and only the user (or an explicit instruction) assigns priority. Size is optional and two-valued: `size:small` (a contained change — one file or a handful, no design judgement left) or `size:large` (multi-file, new abstractions, or anything that touches persistence/auth/concurrency); no label means large. The planner assigns it when filing; the user can relabel before approving; `/ship-backlog` uses it to suggest the implementer's model (`size:small` → Sonnet 5, otherwise Opus 5; any rework → Opus 5 regardless). Any agent that files issues runs this block (or just the missing labels) before its first `gh issue create` in a fresh repo — filing against a missing label fails loudly. `--force` makes it idempotent: it updates color/description if the label already exists.

```bash
# kind — exactly one per issue
gh label create "kind:feature"   -c "#1d76db" -d "new capability"               --force
gh label create "kind:bug"       -c "#d73a4a" -d "incorrect behaviour"          --force
gh label create "kind:security"  -c "#b60205" -d "vuln / data exposure"         --force
gh label create "kind:refactor"  -c "#5319e7" -d "behaviour-preserving cleanup" --force
gh label create "kind:chore"     -c "#0e8a16" -d "docs / deps / tooling"        --force

# status — exactly one per issue; the state machine
gh label create "status:proposed"         -c "#fbca04" -d "filed, awaiting approval to implement"  --force
gh label create "status:approved"         -c "#0e8a16" -d "approved for implementation"            --force
gh label create "status:in-progress"      -c "#1d76db" -d "implementer is working it"              --force
gh label create "status:in-review"        -c "#5319e7" -d "PR open, awaiting the user's merge to main (PR projects only)" --force
gh label create "status:change-requested" -c "#e99695" -d "reviewer wants changes; implementer reworks it" --force

# priority — OPTIONAL, at most one per issue; no priority label means normal
gh label create "priority:high" -c "#d93f0b" -d "implementer takes these before untagged work" --force
gh label create "priority:low"  -c "#c2e0c6" -d "implementer takes these after untagged work"  --force

# size — OPTIONAL, at most one per issue; no size label means large. Drives the suggested model in /ship-backlog.
gh label create "size:small" -c "#bfdadc" -d "contained change; ship-backlog suggests Sonnet for the implementer" --force
gh label create "size:large" -c "#0052cc" -d "multi-file / design-heavy; ship-backlog suggests Opus for the implementer" --force

# security-audit verdict — OPT-IN, skip in the default bootstrap. Only projects with pre-merge audits
# enabled (a `## Security audit` section in the project instructions file (`AGENTS.md` or `CLAUDE.md`) saying `PR audit: on`) use these; the
# security-auditor agent creates them itself on first use. They sit on the PR in PR projects and on
# the issue in no-PR projects (the default), at most one per change; absence = not audited. The truth
# (audited HEAD SHA) lives in the auditor's verdict comment; the implementer strips the label when
# pushing new commits, since it applied to the previous HEAD.
gh label create "security-audit:pass"    -c "#0e8a16" -d "security-auditor reviewed this change's head; no blocking findings" --force
gh label create "security-audit:blocked" -c "#b60205" -d "security-auditor found blockers; findings are in the comments"    --force
```

## The state machine

Every issue carries exactly one `kind:*` label for its whole life and exactly one `status:*` label at a time; GitHub's open/closed state is the terminal stage.

**Default — no PRs.** The project's `## Branching` says `Simple:` without a `PRs: on` line. The implementer merges the verified branch into `main` itself; the merge commit's `Closes #N` closes the issue, and the implementer then strips the status label (closed + no `status:*` = shipped).

```
proposed ──approve──▶ approved ──pick up──▶ in-progress ──merge to main──▶ closed (shipped)
   │                                            ▲                              │
   └──▶ closed (not planned)                    └──── change-requested ◀───────┘  (user reopens + comments)
```

**PR projects.** `## Branching` has `PRs: on`, or the strategy is `Complex:`. The implementer opens a PR and the user merges it.

```
proposed ──approve──▶ approved ──pick up──▶ in-progress ──PR ready──▶ in-review ──merge PR──▶ closed (shipped)
   │                                            ▲                        │
   └──▶ closed (not planned)                    └── change-requested ◀───┘
```

Gates, owned by the user:

1. **Approval to implement** — the user relabels `status:proposed` → `status:approved`. Until then the implementer doesn't touch it. In the default mode this is the only gate: an approved issue ships to `main` as soon as the build is green and its acceptance criteria are verified, and the push deploys per the project's `## Deploy` section.
2. **Approval to deploy** (PR projects only) — the user reviews the PR, lets CI run, and **merges it to `main`**; the merge auto-closes the issue via `Closes #N` in the PR body. The implementer never merges a PR.

The **rework loop** runs through `status:change-requested`. PR projects: the user comments what's wrong (on the PR or the issue) and relabels `status:in-review` → `status:change-requested`; the implementer reworks **on the existing branch and PR** — never a new PR — and relabels back to `status:in-review`. Default mode: the user reopens the shipped issue, comments what's wrong, and adds `status:change-requested`; the implementer fixes on a fresh branch from `main` and merges again with `Closes #N`. The **security-auditor** agent may also relabel to `status:change-requested` when it blocks a change *before* it merges — the one non-user transition; that rework happens on the still-existing branch. The loop can run any number of times.

## Filing an issue

Title: imperative, concise, no `kind` prefix (the label carries it). Body: the per-kind template below. Agents file `status:proposed` unless the user chose `status:approved` as the session default when the planner asked at startup, or said so for the turn; nothing but the user's say-so moves an issue to `status:approved`.

```bash
gh issue create \
  --title "csv export of watchlist" \
  --label "kind:feature" --label "status:proposed" \
  --body "$(cat <<'EOF'
<body per the kind's template>
EOF
)"
```

`gh issue create` prints the new issue's URL — capture the number to report back (and for downstream `Depends on:` lines).

## Body templates

No frontmatter — labels carry kind/status, and GitHub tracks created/author/number. Plain markdown.

### `kind:feature`

```markdown
## Goal
1–2 sentences. What changes about the system in plain language.

## Deliverables
Bulleted list of concrete artifacts. Name file paths, package versions, endpoint shapes, column types. Drop fenced code blocks for literal content (config schemas, JSON shapes, env files, expected responses).

## Acceptance criteria
Bulleted, each independently verifiable. Cover happy path, at least one edge case, and the failure mode. "Code is clean" / "tests pass" / "the feature works" are NOT acceptance criteria.

## Out of scope
Optional. Explicit cuts so the implementer doesn't expand scope.

## Notes
Optional. Non-obvious context, deferred follow-ups, philosophical posture. Leave out if there's nothing to say.
```

The template scales — one bullet per section for a small feature, many for a big one. Past ~10 deliverables, split into multiple feature issues linked by `Depends on:`.

### `kind:bug` / `kind:security` / `kind:refactor`

```markdown
## Problem
One paragraph. Observable symptom, where it bites, who it affects.

## Evidence
File paths with line numbers, short code excerpts where useful (3–5 lines max).

## Suggested fix
Concrete change — usually one or two specific edits. Name the function, the column, the parameter.

## Alternatives considered
(Optional, only when the call wasn't obvious.)
```

### `kind:chore`

A single short paragraph: the package + version bump, the doc file, the config tweak.

## Dependencies

For hard prerequisites only (the schema must exist before the endpoint that queries it), not soft ordering preferences. Near the top of the dependent's body:

```markdown
Depends on: #45, #46
```

Default mode: a dependency merges to `main` the moment it's built, so the dependent simply branches from `main` after it — a chain builds back-to-back in one session. PR projects: the dependent doesn't wait for the dependency's PR to *merge* — the implementer stacks the dependent's branch on the dependency's branch and opens a stacked PR, so the feature builds and gets tested as a whole; the user merges the stacked PRs in dependency order **with merge commits, not squash** (a squash-merged parent makes the retargeted child PR re-show the parent's diff). Only an unbuilt dependency blocks: that one goes first (number order usually handles it).

## Audit flow

On an audit/review request ("audit the code", "look for bugs", "find security issues"):

1. Do the analysis — spend the cycles for a real list, not a token sample.
2. Preview the findings in chat as a numbered list (kind, area, one-line summary each) so the user can prune or retitle before anything is filed. Use provisional numbers (1, 2, 3…) — GitHub assigns real ones on creation.
3. On confirmation, batch-create with `gh issue create`, each labelled `kind:*` + `status:proposed`.
4. Report the assigned numbers ("filed 8 findings as #24–#31") so the user can approve the ones they want.

## Lifecycle operations (cheat sheet)

"Relabel" always means remove the old `status:*` and add the new one — an issue never carries two status labels:

```bash
# override the planner's size call before approving (optional)
gh issue edit N --remove-label "size:small" --add-label "size:large"

# approve for implementation (the user's call; you may only on explicit instruction)
gh issue edit N --remove-label "status:proposed" --add-label "status:approved"

# implementer picks it up
gh issue edit N --remove-label "status:approved" --add-label "status:in-progress"

# DEFAULT (no PRs): implementer verifies, posts the evidence on the issue, then merges the
# branch into main from a detached worktree — the push closes the issue via Closes #N
gh issue comment N --body "Verification: <commands run, exit status, test counts>"
git worktree add --detach ../<repo>-impl-main origin/main
git -C ../<repo>-impl-main merge --no-ff <kind>/N-<slug> -m "<title> (Closes #N)"
git -C ../<repo>-impl-main push origin HEAD:main
gh issue edit N --remove-label "status:in-progress"        # closed + no status label = shipped

# PR PROJECTS: implementer opens the PR (linking the issue so the merge auto-closes it), then relabels
gh pr create --base main --head <branch> --title "<title>" \
  --body "Closes #N

<what shipped, how verified>"
gh issue edit N --remove-label "status:in-progress" --add-label "status:in-review"

# reviewer wants changes — PR projects: comment on the PR, then relabel
# (the USER does this — or the security-auditor agent, on a blocking finding)
gh pr comment <pr> --body "the export is missing the header row when the list is empty"
gh issue edit N --remove-label "status:in-review" --add-label "status:change-requested"
# reviewer wants changes — default mode: reopen the shipped issue, comment, label
gh issue reopen N
gh issue comment N --body "the export is missing the header row when the list is empty"
gh issue edit N --add-label "status:change-requested"

# implementer picks up the rework: relabel, read the feedback, fix — on the EXISTING branch when
# it still exists (PR projects, or an audit block before the merge), otherwise on a fresh branch
# from main — then ship it again the same way as the first time
gh issue edit N --remove-label "status:change-requested" --add-label "status:in-progress"
gh issue view N --json comments
gh pr view <pr> --json comments,reviews                                              # PR projects
gh issue edit N --remove-label "status:in-progress" --add-label "status:in-review"   # PR projects only

# abandon / shelve: close as not-planned with a reason ("completed" if it shipped some other way)
gh issue close N --reason "not planned" --comment "superseded by #13"

# reopen
gh issue reopen N
```

- **Never delete an issue.** Closed (optionally not-planned) is the archive — losing context is worse than carrying a closed row.
- **Done = closed by `Closes #N` landing on `main`** — the implementer's merge commit (default) or the user's PR merge. On the happy path nobody closes by hand. Manual close is for abandoning, not for shipping.

## Looking up / listing

```bash
# the implementer's queue: reworks first, then new work; within each stream
# priority:high first, untagged next, priority:low last, then lowest number
PRIO='sort_by([(if ([.labels[].name] | index("priority:high")) != null then 0 elif ([.labels[].name] | index("priority:low")) != null then 2 else 1 end), .number])'
gh issue list --label "status:change-requested" --state open --json number,title,labels --jq "$PRIO"
gh issue list --label "status:approved"         --state open --json number,title,labels --jq "$PRIO"

# anything else in flight: same shape with any status label
gh issue list --state open --label "status:in-review"

# read one (explicit fields — see Prerequisite)
gh issue view N --json number,title,body,labels,comments
```

When the user says **"go ahead with issue 102"**: view it with the fields above, summarise the relevant sections (Goal/Deliverables or Problem/Suggested fix), then hand to the implementer. If the number doesn't resolve, report *"no issue 102 in this repo"*.
