---
name: credential-tools
description: >-
  Agent-only reference for credential-touching firstmate operations. Load before
  invoking bin/fm-coolify-env.sh, bin/fm-beanz-manifest.sh, or any future tool
  that reads beanz credential files or calls an API with secrets. Never source
  credential files; never pass secrets on argv; never print anything derived from
  a secret value.
user-invocable: false
metadata:
  internal: true
---

# credential-tools

Load this before any credential-touching firstmate operation.

Use the guarded tools in `bin/`:

- `bin/fm-coolify-env.sh` sets Coolify application env vars; firstmate only sees `ok:` or a value-free error.
- `bin/fm-beanz-manifest.sh` regenerates the beanz credential index README from file names and sidecar metadata.

Never source or dot a credential file.
Never pass a secret on a command line where it could reach `ps` or shell history.
Never print anything derived from a credential value, including parse samples or shape descriptions.
When a task needs a secret operation that has no guarded tool yet, stop and ship the tool first.

Mechanics and flags live in each script's header and `--help`.
