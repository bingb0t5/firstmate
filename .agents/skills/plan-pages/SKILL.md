---
name: plan-pages
description: Use the existing plans-axi DevPlans tool for captain-facing artifacts that need to be read later, referred to, or ruled on.
user-invocable: false
metadata:
  internal: true
---

# DevPlans pages

Use a DevPlans page instead of a chat artifact whenever the captain will read the result later, refer back to it, or make a decision from it.

The installed `plans-axi` package ships the authoritative page contract and skill at `$(npm root -g)/plans-axi/skills/plan-pages/SKILL.md`.
Do not recreate, fork, or hand-write that contract, HTML, or server index.
The Cursor Core Repos installer command is `npm install -g https://github.com/bingb0t5/lalo-plan-pages`.

For a command that needs DevPlans credentials, load the private config into that command's subprocess only:

```sh
(
  set -a
  # shellcheck source=/dev/null
  . "${FM_HOME:?}/config/devplans.env"
  set +a
  exec plans-axi publish <content.json|page.html>
)
```

Use the existing CLI:

```text
plans-axi new --kind <design-proposal|plan|update|report|comparison> --title "..."
plans-axi check <content.json|page.html>
plans-axi publish <content.json|page.html>
```

`plans-axi publish` prints the page URL after checking it.
The DevPlans server owns the index and history.
Never print or commit `LALO_PLANS_UPLOAD_KEY` or any value from `config/devplans.env`.

Keep `lavish-axi` for live interactive review only.
