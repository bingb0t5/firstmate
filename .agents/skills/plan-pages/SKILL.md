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
