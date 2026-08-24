# GNHF companion integration verification

Audience: maintainer verification.

This record holds reusable version-scoped evidence for GNHF's CLI shape and for the
bounded-execution contract `.agents/skills/gnhf-companion/SKILL.md` depends on.
That skill owns the operating procedure; `tests/fm-gnhf-companion-skill.test.sh` parses its
declarative frontmatter and, when `gnhf` is installed, guards against silent flag drift in
the installed CLI.

Verified on 2026-08-24 on Linux with `gnhf` 0.1.45 installed (`npm install -g gnhf`).

```sh
$ gnhf --version
0.1.45
```

## Bounded smoke setup

The setup was identical before both runs:

```sh
$ mkdir gnhf-smoke-repo && cd gnhf-smoke-repo
$ git init -q
$ git config user.email "smoke@example.com"
$ git config user.name "GNHF Smoke"
$ printf 'baseline file, do not touch\n' > baseline.txt
$ git add baseline.txt
$ git commit -q -m "baseline commit"
```

## Bounded smoke: completion and stop condition

Verified 2026-08-24 in the disposable scratch repository:

```sh
$ gnhf --agent claude --current-branch --max-iterations 2 --max-tokens 200000 \
    --max-rate-limit-wait 10m --prevent-sleep off \
    --stop-when "smoke-result.txt exists in the repo root containing exactly the text: gnhf smoke ok" \
    "Create a file named smoke-result.txt in the repo root containing exactly the text: gnhf smoke ok (with a trailing newline). Do not modify baseline.txt or any other file. Commit the change. Stop only when smoke-result.txt exists with that exact content."
```

Exit 0. Summary:

```text
gnhf stopped
claude ran for 18s before: stop condition met
iterations 1 total 1 good 0 failed
tokens 69K in 919 out
branch diff 1 commit +1 -0
files 1 added 0 updated 0 deleted
```

Post-run verification:

```text
$ git branch --show-current -> main (stayed on --current-branch, no gnhf/ branch)
$ git log --oneline -> 3e5d1d6 gnhf 1: Created smoke-result.txt ...
8c75eef baseline commit (prior history preserved)
$ git status --short -> (empty; clean working tree)
$ cat smoke-result.txt -> gnhf smoke ok
$ xxd smoke-result.txt | tail -1 -> 00000000: 676e 6866 2073 6d6f 6b65 206f 6b0a gnhf smoke ok.
$ cat baseline.txt -> baseline file, do not touch (untouched)
$ git diff --stat 8c75eef..HEAD -> smoke-result.txt | 1 +, 1 file changed, 1 insertion(+)
$ git ls-files .gnhf -> (empty; .gnhf/ run metadata left untracked)
```

## Bounded smoke: abort on an unmet prerequisite is not papered over

Verified 2026-08-24 in the same repository, continuing on the same branch:

```sh
$ gnhf --agent claude --current-branch --max-iterations 1 --max-tokens 200000 \
    --max-rate-limit-wait 10m --prevent-sleep off \
    --stop-when "a file named prereq-confirmed.txt exists containing the word confirmed" \
    "This task has a hard prerequisite that is NOT met: a file named required-prereq-input.txt must already exist in the repo root with real prior content for you to read and act on. It does not exist. Do not create it yourself and do not fabricate its content. Verify it is absent, then report this iteration as a failure describing the missing prerequisite. Make no file changes."
```

Exit 0 (GNHF's own process exit, not the iteration's outcome). Summary:

```text
gnhf stopped
claude ran for 22s before: max iterations reached (1)
iterations 1 total 0 good 1 failed
tokens 70K in 1K out
branch diff 0 commits +0 -0
files 0 added 0 updated 0 deleted
```

Post-run verification:

```text
$ git status --short -> (empty; clean)
$ git log --oneline -> unchanged from Run 1 (no new commit) - GNHF rolled the failed iteration back rather than fabricating success.
```

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
