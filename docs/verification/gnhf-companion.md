# GNHF companion integration verification

Audience: maintainer verification.

This record holds reusable version-scoped evidence for GNHF's CLI shape and for the
bounded-execution contract `.agents/skills/gnhf-companion/SKILL.md` depends on.
That skill owns the operating procedure; `tests/fm-gnhf-companion-skill.test.sh` is the
portable regression pinning the trigger/loading contract and, when `gnhf` is installed,
guarding against silent flag drift in the installed CLI.

Verified on 2026-08-24 on Linux with `gnhf` 0.1.45 installed (`npm install -g gnhf`).

```sh
$ gnhf --version
0.1.45
```

## Bounded smoke: completion, stop condition, and preserved history

Run in a disposable scratch repository (never a real project), with `--current-branch`
exactly as the skill requires, one bounded iteration, and an observable `--stop-when`
condition:

```sh
$ git init && git commit --allow-empty -q -m "baseline commit"   # baseline.txt committed
$ gnhf --agent claude --current-branch --max-iterations 2 --max-tokens 200000 \
    --prevent-sleep off \
    --stop-when "smoke-result.txt exists in the repo root containing exactly the text: gnhf smoke ok" \
    "Create a file named smoke-result.txt ... Do not modify baseline.txt or any other file. ..."
```

Result: exit 0.

```
gnhf stopped
claude ran for 23s before: stop condition met

iterations      1 total       1 good       0 failed
tokens          53K in        1K out
branch diff     1 commit      +1           -0
files           1 added       0 updated    0 deleted
```

Post-run repo state confirmed the required properties:

- Stayed on `main` (`--current-branch` honored; no `gnhf/` branch created).
- Exactly one new commit (`gnhf 1: ...`), the prior `baseline commit` untouched -
  preserved history, not rewritten.
- `smoke-result.txt` contained exactly `gnhf smoke ok\n` (verified with `xxd`).
- `git status --short` was empty after the run - clean, reviewable working tree.
- `.gnhf/` (run notes and debug log) was not tracked by `git ls-files`, matching the
  upstream README's "Local run metadata" claim.

## Bounded smoke: abort on an unmet prerequisite is not papered over

Same scratch repo, one bounded iteration, a prompt with a stated hard prerequisite that is
not met:

```sh
$ gnhf --agent claude --current-branch --max-iterations 1 --max-tokens 200000 \
    --prevent-sleep off \
    --stop-when "a file named prereq-confirmed.txt exists containing the word confirmed" \
    "This task has a hard prerequisite that is NOT met: required-prereq-input.txt must
     already exist with real prior content. It does not. Do not create it yourself.
     Verify it is absent, then report this iteration as a failure. Make no file changes."
```

Result: exit 0 (GNHF's own process exit, not the iteration's outcome).

```
gnhf stopped
claude ran for 30s before: max iterations reached (1)

iterations      1 total       0 good       1 failed
tokens          70K in        2K out
branch diff     0 commits     +0           -0
files           0 added       0 updated    0 deleted
```

No commit was created, no file was left behind, and `git status --short` stayed empty:
GNHF rolled the failed iteration back rather than fabricating success, exactly as
`gnhf-companion`'s "Stops must actually stop" rule requires the crewmate to trust.

## CLI flags the skill's brief contract depends on

```sh
$ gnhf --help | grep -E -- '--agent|--max-iterations|--max-tokens|--max-rate-limit-wait|--stop-when|--current-branch|--worktree|--push'
```

Confirmed present on 0.1.45: `--agent`, `--max-iterations`, `--max-tokens`,
`--max-rate-limit-wait`, `--stop-when`, `--current-branch`, `--worktree`, `--push`.
`tests/fm-gnhf-companion-skill.test.sh`'s `test_gnhf_help_flags_live` re-checks this same
list on any machine with `gnhf` installed and self-skips otherwise, so a future GNHF
release that renames or drops one of these flags fails that test instead of silently
drifting from the skill's documented contract.
