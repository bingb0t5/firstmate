---
name: gnhf-companion
description: >-
  Agent-only procedure for using the installed GNHF tool (good night, have fun) as a
  bounded, explicitly selected execution technique inside one crewmate's own isolated
  task worktree. Use before briefing a crewmate to run GNHF in Hands-Off or Companion
  mode, before authoring or steering a GNHF-driven task, and before treating its branch
  as ready for delivery. Owns mode selection, the required prompt/cap/stop-condition
  contract, the worktree and merge-authority boundary, why GNHF is never armed as a
  process-event source, and how its completion reaches Firstmate's existing status,
  steering, validation, and merge-authority contracts unchanged.
user-invocable: false
metadata:
  internal: true
---

# gnhf-companion

GNHF ("good night, have fun") is an installed CLI, not a firstmate script: `gnhf --help` and
the skill the npm package ships at its own `skills/gnhf/SKILL.md` are the version-matched
authority on its flags, modes, and agent roster. Discover the installed copy rather than
trusting any flag list below past a version bump:

```sh
gnhf --help
gnhf_root="$(dirname "$(dirname "$(readlink -f "$(command -v gnhf)")")")"
cat "$gnhf_root/skills/gnhf/SKILL.md"
```

GNHF repeatedly invokes one coding agent (`--agent`) until a natural-language `--stop-when`
condition is met or a cap is hit, committing each successful iteration and rolling back each
failed one. It is a bounded execution technique, not a new class of firstmate-managed entity.

## Placement: a crewmate technique, never a firstmate primary action

Firstmate remains the orchestrator. GNHF executes one bounded scope inside a genuine
isolated worker copy - the crewmate's own task worktree from `bin/fm-spawn.sh` - and only
a crewmate already inside that worktree may invoke it. AGENTS.md hard rule 1 (never write
to a project) forbids firstmate's own primary session from running `gnhf` against a
project directly, and nothing here creates an exception: firstmate's role is to brief,
steer, and review a crewmate that chooses to use GNHF, exactly as it briefs, steers, and
reviews any other crewmate.

Because a task worktree is already exclusive to the crewmate that owns it (`fm-spawn`'s
isolation assertion), no GNHF run can overlap a different worker owning the same scope
without a second worktree pointed at the same task existing in the first place, which the
spawn contract already prevents. Nothing new needs to detect that overlap.

## GNHF never grants authority

GNHF completion is not firstmate acceptance. A `--stop-when` match only means the worker
stopped. Before any `done:` line, the crewmate independently compares the branch to current
intent and re-verifies with real checks; before delivery, firstmate applies the task's
selected delivery path exactly as it would for any other crewmate (AGENTS.md section 7).
GNHF grants no merge authority, no approval authority, no security-sensitive authority, and
no permission to skip or answer around `no-mistakes`: an ask-user finding surfaced through a
GNHF-driven task still escalates through `ask-user-authority`, and a red or gated pipeline
is never treated as done because a GNHF iteration reported success.

## Mode selection

Firstmate chooses the mode once, at brief-authoring time, the same tier as choosing the
task's delivery mode. Both modes ride the existing crewmate spawn, status, steering,
validation, and merge-authority contracts unchanged; GNHF only changes how the crewmate
spends its own foreground turns.

### Hands-Off

Use when the task is bounded and the stop condition is verifiable evidence, not judgment.
Author one precise brief with the required contract below, spawn the crewmate as normal,
and wait for its ordinary `done:` / `blocked:` / `needs-decision:` status - no incremental
steering is expected. The crewmate itself intervenes early only for a hard failure, runaway
scope, destructive behavior, or an impossible prerequisite, exactly as it would while
working without GNHF.

### Companion

Use when the task is uncertain, exploratory, or likely to need course correction. Brief the
crewmate to run GNHF in small bounded slices (a low `--max-iterations` per invocation)
and report `working:` between slices through the ordinary status protocol. Firstmate
reviews the branch after each slice the same way it reviews any worker's partial progress,
then steers the next slice's prompt through ordinary `fm-send` - never mid-invocation, only
between bounded GNHF calls, so a steer can never race GNHF's own iteration commit or
rollback. Treat GNHF's own `notes.md` and exit summary as claims, not evidence; inspect
`git status`, `git log`, and the diff before deciding whether to continue.

Signals worth steering on, adapted from GNHF's own skill:

| Signal | Action |
| --- | --- |
| Real blocker found | Stop, or relaunch with blocker-specific instructions |
| Good partial slice | Let it continue, or tighten the next stop condition |
| Skipped requested research | Relaunch with research as the explicit first deliverable |
| Unrelated files changed | Stop and review before continuing |
| Success claimed without verification | Review immediately; relaunch only with an evidence-based stop condition |
| Reviewer or captain finds a blocking issue | Relaunch with that finding as the sole bounded correction |

## Required brief contract

Every GNHF invocation a crewmate is briefed to run must satisfy all of the following;
author it into the task's own `{TASK}` brief content, not as a separate scaffold flag -
there is no dedicated `fm-brief.sh` flag for this and none is needed.

- **Outcome-based prompt.** State one concrete objective, explicit non-goals, and what
  "preserve user changes" means for this task (do not touch files outside the stated
  surface). Never accept a vague prompt like "keep improving this."
- **Observable stop condition.** Pass `--stop-when "<evidence-based condition>"`. Bad:
  "looks good." Good: "the target test suite passes and no file outside `src/foo/` changed."
- **Explicit caps.** Pass `--max-iterations <n>` and `--max-tokens <n>` sized to the task.
  GNHF has no direct wall-clock flag; treat the iteration and token caps as the runtime
  bound, and set `--max-rate-limit-wait` explicitly rather than leaving its 24h default when
  the task needs a tighter window.
- **Clean starting state.** GNHF itself refuses a dirty working tree; a freshly spawned
  task worktree already starts clean, so this is satisfied by the ordinary spawn contract
  as long as GNHF is the first thing the crewmate runs there.
- **`--current-branch`, never `--worktree`.** The crewmate's task worktree from `fm-spawn`
  is already the isolated worker copy; GNHF's own `--worktree` mode exists to isolate
  *multiple* GNHF runs inside one shared checkout, which would nest a second, redundant
  isolation boundary inside the first and GNHF itself refuses to combine with
  `--current-branch`. Run GNHF on the crewmate's own current branch instead.
- **`--push` only when the task's own delivery mode already pushes.** GNHF's `--push` is a
  crewmate decision under the ordinary delivery contract (`no-mistakes` or `direct-PR`), not
  a GNHF default; omit it for `local-only` tasks and for any task still under review.
- **No `&`, no `nohup`, no detached backgrounding.** Run GNHF as an ordinary foreground
  command inside the crewmate's own turn. See "No new supervision surface" below for why
  this is sufficient and required.
- **A reviewable branch.** GNHF's incremental per-iteration commits already produce one;
  nothing extra is required beyond the crewmate's own normal report of branch state.
- **Stops must actually stop.** GNHF already treats a complete no-op iteration as a failure
  counting toward its own consecutive-failure abort, and aborts immediately on a permanent
  agent error. The crewmate must never relaunch GNHF with a raised failure tolerance or a
  reworded prompt to push through a real abort; a GNHF abort is the crewmate's own
  `blocked:` or `needs-decision:` trigger, carrying the printed run log path as evidence.

## Agent selection

Pick GNHF's own `--agent` (the inner coding agent GNHF repeatedly invokes) under the same
standing preference that already governs crewmate harness/model selection - never a model
as strong as firstmate's own primary (`data/captain.md`, "Model and runtime"; standing
routing in `config/crew-dispatch.json`, resolved through `quota-array-dispatch` when more
than one candidate matches). Do not default to GNHF's own `~/.gnhf/config.yml` agent
without checking it agrees with that preference, and do not hard-code which agents GNHF
supports - its `--agent` roster comes from the installed `gnhf --help` and its own README
"Agents" table, discovered live as shown above, never a roster pinned in this file.

## No new supervision surface

`bin/fm-procevent.sh` (see `process-event-sources`) is scoped to sources this firstmate
*home* owns and blocks on, with no per-project working-directory concept: arming it to run
`gnhf` would make firstmate's own background runner the actor executing a project-mutating
command, which is exactly what hard rule 1 forbids. GNHF is therefore never registered as a
process-event source, and none of process-event-sources' arming or wake-handling commands
apply to it.

Instead, GNHF rides the worker path that already exists: a crewmate occupying its own
foreground turn on a long-running command is not a new situation - it is what a crewmate
already does for a build, a test suite, or a `no-mistakes` run - and firstmate's existing
per-task supervision (stale-wake detection, `bin/fm-crew-state.sh`, the crewmate's own
status file) already covers it without any GNHF-specific change. Completion reaches
firstmate the same way any other crewmate turn's completion does: the crewmate's own next
status append.

A crewmate's own harness can itself bound a single foreground tool call (for example,
Claude Code's own Bash tool caps one call at 10 minutes). This is a property of the acting
harness, not of GNHF or of firstmate's supervision, and it is not a license to reach for
shell backgrounding: size `--max-iterations`/`--max-tokens` so one invocation comfortably
fits inside the acting harness's own foreground budget, and let the crewmate's own
multi-turn loop invoke GNHF again with `--current-branch` (which resumes automatically) on
a later turn for a longer overall span. Verify the acting harness's own limit rather than
assuming one; a harness with no documented cap needs no such splitting.

## Companion review before delivery

Before treating any GNHF-driven branch as ready, whether reviewing between Companion slices
or at a Hands-Off task's own `done:`:

1. Inspect branch, status, commits, changed files, and diff - never GNHF's summary alone.
2. Read GNHF's `notes.md` and debug log as claims, not evidence.
3. Run the task's own real verification: tests, lint, build, or domain-specific checks.
4. Compare the result against current intent and the task's stop condition.
5. Decide: continue with another bounded GNHF slice, hand off to ordinary manual work, or
   proceed to the task's selected delivery path (AGENTS.md section 7) exactly as any other
   crewmate task - GNHF changes nothing about which path applies or who approves it.
