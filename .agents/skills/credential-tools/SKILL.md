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

- `bin/fm-coolify-env.sh` is the credential-blind transport for an exact Coolify env mutation requested by the active ship worker; firstmate invokes it and sees only `ok:` or a value-free error, while the worker and selected delivery path continue to own the project change.
- `bin/fm-beanz-manifest.sh` regenerates the beanz credential index README from validated assignment keys, file names, built-in metadata, and sidecars without emitting credential values.

Do not use credential access as a reason for firstmate to originate project work or bypass worker delegation.
Invoke `bin/fm-coolify-env.sh` only for the exact service, key, and source requested by the active ship worker after its delivery path is resolved.

Never source or dot a credential file.
Never pass a secret on a command line where it could reach `ps` or shell history.
Never print anything derived from a credential value, including parse samples or shape descriptions.
When a task needs a secret operation that has no guarded tool yet, stop and ship the tool first.

Mechanics and flags live in each script's header and `--help`.
