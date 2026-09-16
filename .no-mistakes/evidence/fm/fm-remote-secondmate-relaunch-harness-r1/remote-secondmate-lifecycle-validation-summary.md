# Remote secondmate lifecycle validation

Date: 2026-09-16

## Executed targeted integration interface

```sh
bash tests/fm-remote-secondmate-lifecycle-e2e.test.sh
```

Result: exit 0 (`ALL TESTS PASSED`).

The executable fixture drives `fm-spawn.sh`, `fm-on.sh`, and `fm-remote-secondmate-control.sh` across a disposable parent and remote home. Its remote Herdr command is a deterministic fixture, so this is supplemental integration evidence, not live-product evidence.

Relevant observed assertions passed:

- A backend kill that returns success while the remote agent remains alive does not print `stopped` and produces the unconfirmed-exit failure.
- A confirmed stop removes browser lifecycle ownership before a changed-profile relaunch, and the new profile becomes alive.
- A browser finalization failure prevents a `stopped` report while retaining ownership evidence.

Full executable transcript: `remote-secondmate-lifecycle-e2e-transcript.txt`.

## Live-product boundary

The installed `herdr` CLI was detected, but this isolated worktree has no configured disposable remote secondmate route. Driving the real lifecycle would require provisioning an SSH-reachable remote Firstmate home and launching an actual agent, which is unavailable and outside this test phase's authority. No live scenario is claimed.
