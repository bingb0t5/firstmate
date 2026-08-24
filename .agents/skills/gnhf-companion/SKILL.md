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

The crewmate's task worktree isolates its filesystem writes from every other worker's
working directory, so GNHF cannot directly collide with another worker's in-progress
files. This does not serialize overlapping scopes across tasks; ordinary branch review
and reconciliation still apply when separately spawned workers touch the same subsystem.

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
  bound, and pass an explicit task-sized `--max-rate-limit-wait <duration>` on every
  invocation rather than leaving its 24-hour default in effect. When re-invoking to resume
  an existing run, see "No new supervision surface" below: `--max-iterations` is cumulative
  across a resume and must be raised each call, while `--max-tokens` is not.
- **`GNHF_TELEMETRY=0`.** By default GNHF reports aggregate usage telemetry to a hard-coded
  third-party host on every run: the agent name, run mode, final status, iteration, success,
  failure and commit counts, token totals, duration, and which flags were set. Prompt text,
  repository paths, and branch names are not included. Set `GNHF_TELEMETRY=0` in the
  environment for firstmate-driven invocations (`GNHF_TELEMETRY=0 gnhf ...`, or export it
  before the crewmate's invocation) rather than relying on GNHF's default-on behavior.
- **Clean tree before every invocation.** GNHF refuses to start on a dirty working tree,
  on both its resume and its fresh-run path, and its check is `git status --porcelain` with
  default untracked reporting - so an untracked build artifact or coverage file blocks it
  exactly as an uncommitted edit does. A freshly spawned task worktree satisfies this for
  the first invocation, but the precondition applies to every later one too: Companion
  mode's own between-slice review runs the task's real verification and may hand off to
  ordinary manual work, either of which can leave scratch notes or interim artifacts
  behind. Preserve user changes, commit intentional task changes, and safely remove only
  disposable artifacts so `git status --porcelain` is empty before invoking GNHF again,
  or the next slice dies with "Working tree is not clean" on a self-inflicted precondition
  rather than on anything about the task.
- **`--current-branch`, never `--worktree`.** The crewmate's task worktree from `fm-spawn`
  is already the isolated worker copy; GNHF's own `--worktree` mode exists to isolate
  *multiple* GNHF runs inside one shared checkout, which would nest a second, redundant
  isolation boundary inside the first and GNHF itself refuses to combine with
  `--current-branch`. Run GNHF on the crewmate's own current branch instead.
- **`--push` only in direct-PR mode.** GNHF's `--push` is permitted only when the task is
  already on the direct-PR delivery path and that path authorizes the worker to push.
  Omit it in `no-mistakes` mode, where the pipeline alone owns push, and in `local-only`
  mode. Also omit it for any direct-PR task still under review.
- **No `&`, no `nohup`, no detached backgrounding.** Run GNHF as an ordinary foreground
  command inside the crewmate's own turn. See "No new supervision surface" below for why
  this is sufficient and required.
- **A reviewable branch.** GNHF's incremental per-iteration commits already produce one;
  preserve all branch history that predates the invocation, and do not rewrite or drop it.
  Nothing else is required beyond the crewmate's own normal report of branch state.
- **Stops must actually stop.** GNHF aborts immediately on a permanent agent error, and
  that abort is mechanical. Its no-op handling is not: GNHF only *asks* its inner agent, in
  the iteration prompt, to report a no-op iteration as `success=false` so the run can halt,
  and never verifies the claim. If the agent instead reports success with nothing staged,
  GNHF's commit step finds no staged diff and silently makes no commit, yet still counts the
  iteration as good and resets the consecutive-failure counter to zero - so a misreporting
  agent can quietly burn the entire `--max-iterations` budget doing nothing and still exit
  0. Treat the iteration and token caps, plus the crewmate's own diff inspection, as the
  only mechanical bound on a no-op spin. The crewmate must never relaunch GNHF with a raised
  failure tolerance or a reworded prompt to push through a real abort; a GNHF abort is the
  crewmate's own `blocked:` or `needs-decision:` trigger, carrying the printed run log path
  as evidence.

## Agent selection

GNHF's own `--agent` (the inner coding agent GNHF repeatedly invokes) is a crewmate
harness/model choice like any other, so resolve it through the routing precedence AGENTS.md
section 4 already defines: an explicit per-task captain override, then the best-fit
configured rule in `config/crew-dispatch.json` (resolved through `quota-array-dispatch`
when more than one candidate matches), then this home's own current standing preference,
then the static crewmate harness. Section 4's own boundary applies unchanged at every step:
preserve the captain's strongest-reasoning class rather than silently downgrading it solely
to conserve quota, and stop and report if that class cannot proceed. Do not default to
GNHF's own `~/.gnhf/config.yml` agent without checking it agrees with what that precedence
resolves to, and do not hard-code which agents GNHF supports - its `--agent` roster comes
from the installed `gnhf --help` and its own README "Agents" table, discovered live as
shown above, never a roster pinned in this file.

That precedence names a firstmate harness, which is not the same set as GNHF's `--agent`
roster, so the value it resolves to is a candidate rather than the flag's value. Pass
`--agent` only a name present in GNHF's own live-discovered roster: GNHF validates the flag
fail-closed and exits non-zero on an unknown name, so a firstmate-verified harness GNHF does
not implement natively makes the run die on a configuration mismatch rather than on anything
about the task. When the resolved candidate has no direct match in that roster, do not
invent or assume an `acp:<target>` mapping for it. Fall back instead to the highest-precedence
candidate from that same resolution which is both a firstmate-verified harness and present
in GNHF's discovered roster, under the same anti-downgrade boundary; if no candidate
satisfies both, stop and report rather than guessing.

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
multi-turn loop invoke GNHF again on a later turn for a longer overall span. Verify the
acting harness's own limit rather than assuming one; a harness with no documented cap needs
no such splitting.

Re-invoking is not automatically a resume. Verified against the installed gnhf 0.1.45,
`--current-branch` resume is keyed to a byte-identical prompt string: gnhf hashes the whole
prompt to derive the run id, so a reworded prompt - even one differing only by a trailing
space - silently starts a brand-new run with a fresh iteration and token budget and none of
the accumulated `notes.md` context, and reports no error when it does. To get a true resume
across a crewmate's own turns, re-invoke with the exact same prompt string, unchanged. A
crewmate that cannot guarantee a byte-identical re-invocation must instead treat each
invocation as its own fresh bounded run and account for cumulative iterations and tokens
across those calls itself. In Companion mode this is not a defect: each steered slice is
already intentionally a fresh bounded run by design, since new instructions mean a new
bounded scope, so firstmate should size each slice's caps knowing that slice receives its
own full budget rather than a continuously draining shared one.

The two caps behave differently across a true resume, so a resuming crewmate must raise one
of them by hand. `--max-iterations` carries forward cumulatively: gnhf restores the prior
run's last iteration number as the starting count and checks it against whatever
`--max-iterations` the new invocation passes, before doing any work. So re-issuing a
byte-identical command with an unchanged cap aborts instantly with the same
`max iterations reached (n)` summary, zero new iterations, and zero tokens - output that is
indistinguishable from a legitimate cap stop, forever. When resuming to make further
progress, raise `--max-iterations` on each successive call above the count the prior call
already reached. `--max-tokens` needs no such adjustment: token totals reset to a fresh
zero-based per-invocation budget on every call, resume or not.

## Companion review before delivery

Before treating any GNHF-driven branch as ready, whether reviewing between Companion slices
or at a Hands-Off task's own `done:`:

1. Inspect branch, status, commits, changed files, and diff - never GNHF's summary alone.
   To catch the silent no-op spin above, measure each invocation's real progress yourself:
   capture `git rev-parse HEAD` immediately *before* invoking GNHF, and once it exits count
   only the commits that invocation actually added, with
   `git rev-list --count <pre-invocation-head>..HEAD`. Compare that against the same
   invocation's own reported good-iteration count; "N good iterations" having added fewer
   than N commits means iterations were counted good without committing anything, which is a
   stop-and-investigate signal rather than evidence of progress. Never compare against
   GNHF's own printed `branch diff N commits` figure: it is computed from the run's original
   base commit, so on any resumed invocation it still includes every earlier invocation's
   commits and would report a clean-looking all-clear for a run that did nothing this time.
   The printed `iterations N total` is cumulative for the same reason, while the good/failed
   tally resets each invocation - so those two figures are not on a common base either.
2. Read GNHF's `notes.md` and debug log as claims, not evidence.
3. Run the task's own real verification: tests, lint, build, or domain-specific checks.
4. Compare the result against current intent and the task's stop condition.
5. Decide: continue with another bounded GNHF slice, hand off to ordinary manual work, or
   proceed to the task's selected delivery path (AGENTS.md section 7) exactly as any other
   crewmate task - GNHF changes nothing about which path applies or who approves it.
