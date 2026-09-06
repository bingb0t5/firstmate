# Host-health episode model

`bin/host-health-episode/` is the tracked, offline implementation of the accepted host-health episode model.
It classifies already-normalized observations, persists episode state, and emits at most one typed notification intent.
It is not a live watcher and does not read host metrics, credentials, senders, schedules, or network.

The executable contract is the package's standard-library tests, mutation runner, and bounded enumerator.
Run them from `bin/host-health-episode/` with `python3 -m unittest discover -s tests`, `python3 mutation_runner.py`, and `python3 enumerate_sequences.py`.
`tests/host-health-episode.test.sh` is the Firstmate suite entry that drives those same commands.

Deployment manifests under `bin/host-health-episode/deployment-manifests/` are non-activating instructions and evidence only.
Both keep `activation.permitted` false and `candidate_sha256` null.
They do not authorize canary, install, restart, or any live-host action.
The historical installed baseline they name is `912f99b4433cef07522c81b874e50c7b82b5560d1777495cf53ae20043e7a668`.
