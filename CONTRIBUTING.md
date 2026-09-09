# Contributing

Thanks for wanting to contribute.
One rule up front:

**Human-authored pull requests targeting `main` must be raised through [`no-mistakes`](https://github.com/kunchenguid/no-mistakes).**
We require this to reduce the maintainer's burden of reviewing and merging contributions.

`no-mistakes` puts a local git proxy in front of your real remote.
Pushing through it runs an AI-driven review/test/lint pipeline in an isolated worktree, forwards the push upstream only after every check passes, and opens a clean PR automatically.

A GitHub Actions check (`Require no-mistakes`) runs on PRs targeting `main` and fails if the body is missing the deterministic signature that no-mistakes writes.
It evaluates every PR opening and body edit independently, so a later edit cannot replace an earlier pending compliance check.
GitHub Actions and Dependabot are exempt so their automation keeps working, but regular contributor PRs without the signature will not be reviewed or merged.

A second check (`pr-communication`) enforces the pull request communication structure shared with the Lalo repos.
Use [`.github/PULL_REQUEST_TEMPLATE.md`](.github/PULL_REQUEST_TEMPLATE.md) verbatim for the required CEO overview, validation, module-boundary decision, and decision-needed sections.
Legacy `Intent`, `Risk Assessment`, and `Testing` headings do not satisfy the communication check.
The two checks read the same body and are satisfied together: the communication check ignores no-mistakes' own `## Pipeline` section, so never drop that section to satisfy it.
The assessment rules are vendored from `lalo-admin`; the local pin always guards that copy against unreviewed changes, and the companion `pr-communication-sot` check compares it with that remote source of truth using only `PR_COMMUNICATION_SOT_TOKEN`.
Firstmate also fails a missing CEO overview or one that is only implementation intent; that extra check is owned by `scripts/pr-communication/firstmateCeoOverview.ts` and does not replace the shared template sections.
The remote comparison fails closed when the credential is missing or rejected, and only network errors, HTTP 408 or 429, and server-side HTTP 5xx responses may fall back to the trusted local pin.

For every no-mistakes run in this repository, author the run intent in the gate-required PR shape before the pipeline publishes the live GitHub body, so the first `github.event.pull_request.body` event already passes `pr-communication`.
Complete [the shared template](.github/PULL_REQUEST_TEMPLATE.md), retaining every task requirement in the technical section and describing only checks actually performed in Validation.
Before starting or resuming pipeline delivery, run [`bin/fm-nm-pr-preflight.sh`](bin/fm-nm-pr-preflight.sh) against that intent file and the explicit GitHub delivery target; its header and `--help` own the command contract.
Pass the returned intent unchanged to `no-mistakes axi run --intent`, and repeat the preflight when the intent, live body, or head changes.
The read-only preflight refuses incomplete intent, reserved pipeline markers, and an incomplete existing live body or stale pipeline head before another delivery action.
For narrative intake, use the exact labelled template bullets in CEO overview and Validation, with prose values free of HTML tags, blockquote markers, fences, and inline code.
Non-comment raw HTML outside `## Pipeline` is refused with its source line; generated Pipeline content stays under the existing machine check and cannot supply narrative fields.
These intake restrictions supplement assessment of the unchanged original body; filtered prose cannot override a refusal from the shared assessors.
On refusal, correct the intent or return the live-body problem to that PR's owner; a local sidecar does not repair a stale live description, and the preflight never changes a PR or manufactures pipeline evidence.
Review the prose against the current task yourself: this is structural validation, not proof that claims are accurate or authorization to edit another lane.
The current pipeline can replace the live description with Intent-shaped text.
Do not rely on a committed `.github/pr-bodies` sidecar because CI grades the live body.
This preflight mitigates Firstmate's intake path; it does not intercept direct CLI use, alter an active run's stored intent, or prevent the upstream publisher from rewriting or truncating the body ([kunchenguid/no-mistakes#995](https://github.com/kunchenguid/no-mistakes/issues/995)).
Hosted checks remain required after every publication.

## Workflow

1. Fork the repo, then clone the parent repo or set your local `origin` back to the parent (`git@github.com:bingb0t5/firstmate.git`).
2. Create a branch and make your changes.
3. Initialize the gate with your fork as the push target: `no-mistakes init --fork-url git@github.com:<you>/firstmate.git` (firstmate expects **no-mistakes v1.46.0+**; without a fork, plain `no-mistakes init` still works for maintainers with push access).
4. Commit your changes.
5. Validate the authored intent and start the gate, using the actual target repository and head owner for your fork:

   ```sh
   intent=$(bin/fm-nm-pr-preflight.sh --intent-file /path/to/intent.md \
     --repo bingb0t5/firstmate --head "YOUR_FORK_OWNER:$(git branch --show-current)") &&
     no-mistakes axi run --intent "$intent"
   ```

6. Run `no-mistakes` to attach to the pipeline, watch findings, authorize auto-fixes, and review ask-user findings as needed.
   Follow the installed no-mistakes version's SKILL.md and live `axi` help for gate mechanics.
7. Once the pipeline passes, it pushes the branch to your fork and opens the PR against the parent repo for you.
   `pr-communication` grades that live GitHub body, so author the required shape before publish as specified above.
   A committed `.github/pr-bodies` sidecar is not what CI reads.
   If a later description edit is needed, replace only the narrative sections.
   Keep no-mistakes' `## Pipeline` section verbatim, including the `Updates from [git push no-mistakes]` signature line and the `<!-- no-mistakes-pipeline-attestation:v1 ... -->` comment, because `Require no-mistakes` reads both from the body and fails when a rewrite deletes them.
   Repeat that check before every branch synchronization and after later description edits.

See the [no-mistakes quick start](https://kunchenguid.github.io/no-mistakes/start-here/quick-start/) for the full first-run walkthrough.

## Repo conventions

- This repo is a template for running a firstmate orchestrator agent.
  `AGENTS.md` is the agent's main job description and names when to load bundled firstmate skills; `CLAUDE.md` is a real `@AGENTS.md` pointer to it, and `.claude/skills` is a symlink to `.agents/skills`.
- Only shared material is tracked: `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, `.tasks.toml`, `.github/workflows/`, `bin/`, `.agents/skills/`, and `skills/`.
  `.agents/skills/` holds agent-loaded skills that assume a live firstmate home and carry `metadata.internal: true` so installers such as [skills.sh](https://skills.sh) hide them from discovery; `skills/` holds standalone, installer-facing public skills with no firstmate dependency (see the README's "Two-tier skill layout").
  Everything personal to one captain's fleet (`.env`, `data/`, `state/`, `config/`, `projects/`, `.no-mistakes/`) is gitignored; never commit it.
  The root `.tasks.toml` is tracked `tasks-axi` config for `data/backlog.md`; compatible `tasks-axi` is the default backend for routine backlog mutations, with the compatibility definition owned by [`docs/configuration.md`](docs/configuration.md) ("Backlog backend").
  A local `config/backlog-backend=manual` opt-out forces firstmate's routine backlog updates to hand-editing and stays gitignored; validated secondmate handoffs still delegate through `tasks-axi mv`.
  A local `config/backend` file explicitly overrides runtime auto-detection for new task endpoints and stays gitignored; spawn-supported values are `tmux` plus experimental `herdr`, `zellij`, `orca`, and `cmux`, while `codex-app` is documented only in `docs/codex-app-backend.md`.
  It does not make `data/` tracked.
- Helper scripts in `bin/` are plain bash.
  Each starts with a usage header comment; keep it accurate when you change behavior.
  Test scripts and helpers in `tests/` are plain bash too.
  `bin/fm-lint.sh` must pass: it is the single owner of the lint definition (the shellcheck file set, config, pinned shellcheck version, and pinned actionlint workflow lint), and both CI and the no-mistakes pre-push gate run its no-argument full-analysis path.
  Its header and `--help` output own the exact local lint modes and flags.
  A malformed `.github/workflows/*.yml`, including a self-broken `ci.yml`, fails that local lint path before merge because a broken workflow cannot report its own breakage.
  It pins one exact shellcheck version and one exact actionlint version and refuses to run under any other.
  Print the shellcheck pin with `bin/fm-lint.sh --required-version` and the actionlint pin with `bin/fm-lint-workflows.sh --required-version`.
  Use `bin/fm-install-shellcheck.sh` and `bin/fm-install-actionlint.sh` to install those exact builds locally; each installer's header owns its destination usage and supported platforms.
- Harness-adapter ownership spans detection in `bin/fm-harness.sh`, launch and hook mechanics in `bin/fm-spawn.sh`, semantic busy sources and trust gates in `bin/fm-busy-lib.sh`, delivery-only rendered guards in `bin/fm-composer-lib.sh`, cleanup in `bin/fm-teardown.sh`, and facts in `.agents/skills/harness-adapters/SKILL.md`; the `firstmate-coding-guidelines` skill owns the validation policy for checks that depend on those harnesses.
- Changes to runtime session backends (`bin/fm-backend.sh`, `bin/backends/`, and the scripts that dispatch through them) keep current setup and limits in the relevant backend guide and active empirical evidence in [`docs/verification/runtime-backends.md`](docs/verification/runtime-backends.md).
- [`docs/documentation-audiences.md`](docs/documentation-audiences.md) and its machine-consumed inventory own prose classification; run `bin/fm-doc-audience-check.sh` after documentation changes.
- In Markdown, put each full sentence on its own line.
- `README.md` stays a concise overview plus pointers: it never carries a wall of inline detail.
  Route detail to the most specific `docs/` file (architecture, configuration, or a backend guide) and link to it instead.

## Development

Tracked changes to firstmate itself - `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, `.tasks.toml`, `.github/workflows/`, `bin/`, `.agents/skills/`, and `skills/` - ship through the `no-mistakes` pipeline on a feature branch and require an explicit merge approval.
Before making any such change, load the agent-only `firstmate-coding-guidelines` skill (`.agents/skills/firstmate-coding-guidelines/SKILL.md`).
It has the knowledge-placement rules that keep `AGENTS.md` from regrowing after each diet pass.
There is no reliable way for `bin/fm-brief.sh`'s scaffold to detect that a task's repo is firstmate itself, so firstmate adds this skill's load line to firstmate-repo briefs by hand.
A crewmate picking up such a brief should load the skill even if the brief predates this instruction.
When supervising live crewmates, keep firstmate's own long validation or build commands in the background so watcher wakes can still be handled.
Crewmate validation follows the installed no-mistakes version's SKILL.md and live `axi` help instead of duplicating gate mechanics in firstmate docs.
Firstmate's wrapper still matters: crewmates route every `ask-user` finding to firstmate, which applies `ask-user-authority`, and crewmates avoid `--yes` because it would bypass that check and any required captain escalation.
`.no-mistakes.yaml` publishes test evidence to the orphan `no-mistakes/evidence` branch, which shares no history with code branches, and pins the gate's lint command to `bin/fm-lint.sh`, matching the Linux CI lint job.
Local no-mistakes Test is intent-targeted and must not re-run every `tests/*.test.sh`; `.github/workflows/ci.yml` owns the broad behavior suite plus platform-specific compatibility lanes.
The pipeline publishes that evidence itself, so never hand-commit `.no-mistakes/` paths onto a feature branch; CI rejects them as tracked personal fleet paths.

Check and test the toolbelt before pushing:

```sh
while IFS= read -r script; do /bin/bash -n "$script" || exit; done < <(bin/fm-lint.sh --list-files)   # syntax-check the shell surface fm-lint.sh will cover (changed files locally, full set in CI/on main)
bin/fm-lint.sh   # lint that shell surface plus GitHub workflows via pinned actionlint; the single owner CI and the no-mistakes gate both run
bin/fm-test-run.sh tests/<subject>.test.sh   # one script (primary local focus path, timed)
bin/fm-test-run.sh --family pure-contract-unit   # ordinary family-scoped local path (serial, timed)
bin/fm-test-run.sh --changed   # conservative changed-file-informed set (never silent full suite)
bin/fm-test-run.sh --proven-isolated --jobs 4   # explicit local parallel of the proven set only (default is serial)
bin/fm-test-run.sh --lane portable-serial   # portable serial remainder (watcher/AFK/tmux/stateful)
bin/fm-test-run.sh --list-lanes   # discover exact lane names, including the current CI serial shards
bin/fm-test-run.sh --check-coverage   # prove portable shards + serial + serial shards + Herdr equal the full inventory
bin/fm-test-run.sh --all   # deliberate complete regression (optional local full walk; not no-mistakes Test)
bin/fm-test-isolation-proof.sh --list   # proven parallel candidate set (Phase 2 owner)
bin/fm-test-isolation-proof.sh --jobs 4 --json /tmp/fm-isolation-proof.json   # re-run concurrent isolation proof only
[ ! -L CLAUDE.md ] && cmp -s CLAUDE.md - <<'EOF'
<!-- Points Claude at AGENTS.md via import; edit AGENTS.md, not this file. -->
@AGENTS.md
EOF
[ "$(readlink .claude/skills)" = "../.agents/skills" ]
tmp=$(mktemp -d) && printf 'done: smoke\n' > "$tmp/smoke.status" && FM_STATE_OVERRIDE="$tmp" FM_SIGNAL_GRACE=1 FM_POLL=1 FM_HEARTBEAT=999999 bin/fm-watch-arm.sh  # watcher re-arm smoke test (prints arm status, then an actionable signal)
```

`bin/fm-test-run.sh` is the single owner of behavior-suite selection, portable CI lane composition, optional local `--jobs` for the proven-isolated set only, per-script timing markers, family totals, the coverage guard, and the optional JSON timing artifact.
Its header and `--help` own the flags, family labels, lanes, and changed-file map; this section only documents the entry points.
`bin/fm-test-isolation-proof.sh` remains the single owner of the Phase 2 concurrent isolation proof and the exact proven candidate set; see `docs/fm-test-isolation-proof.md`.
Portable shard balance evidence lives in `docs/fm-test-portable-shards.md`.
Local no-mistakes Test stays intent-targeted and must not wire `commands.test` to `--all` or a `tests/*.test.sh` walk.
Family selection is the ordinary local path; `--all` is deliberate full regression only.
CI owns broad regression across required portable parallel shards, the portable serial lane's separate-runner shards, the Herdr lane, lint, invariants, the coverage guard, and stock macOS Bash compatibility in [`.github/workflows/ci.yml`](.github/workflows/ci.yml).
Use `bin/fm-test-run.sh --list-lanes` for exact lane names and `--help` for `--jobs` rules and required gate-skip flags when reproducing a lane locally.
Discover tests by listing `tests/*.test.sh`: each is a self-contained bash script named `<subject>.test.sh`, and its header comment describes what it covers, so pass one to `bin/fm-test-run.sh` to focus on a subject with canonical timing output.
A fixture may shorten a production timeout to keep a failure path prompt, but never below what the real work inside that window costs on a loaded machine: a fork, an exec, a lock acquisition, a beacon publication, or a first-poll check.
Where a case's assertion is not about the timeout itself, give that window headroom over the measured loaded cost, and bound the test's own waiting with iteration-counted poll loops, which stretch under load where a wall-clock budget does not.
Tests that need a real optional backend or an explicit opt-in (real herdr/zellij/cmux smoke tests, the live Pi regression) skip themselves and print the tool or environment gate needed to enable them, so the portable suite remains safe on machines without those tools.
The [Herdr backend guide](docs/herdr-backend.md#destructive-lab-safety) owns the lane's isolation boundary, while [runtime backend verification](docs/verification/runtime-backends.md#herdr) owns active empirical evidence; live harness credential tests remain opt-in.

## Questions

Open an issue, or talk to me on [Discord](https://discord.gg/Wsy2NpnZDu).
