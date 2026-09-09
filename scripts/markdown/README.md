# Delivery Markdown parser

`parser.mjs` is a generated, offline bundle of the pinned `mdast-util-from-markdown` CommonMark parser with GitHub-flavored Markdown extensions.
`package-lock.json` pins its transitive dependencies; `LICENSES.txt` contains the bundled packages' licenses.
Regenerate from this directory with `npm ci --ignore-scripts --no-audit --no-fund` followed by `npm run build`.
Neither preflight nor tests require an npm install or network access.

Delivery evidence is classified by its original source offsets in the Markdown tree.
Only top-level paragraphs and the canonical HTML attestation comment can supply evidence.
The ordinary CommonMark tree excludes occurrences nested in Markdown list, quote, code, heading, and table nodes.
This is not HTML ancestry validation: raw HTML containers separated by blank lines can leave evidence as top-level Markdown siblings.
A second parse of the same unchanged source disables only the `htmlFlow` construct so an attestation comment cannot interrupt a surrounding inline-code span.
Inline HTML remains enabled, preserving the comment as an opaque node and preventing its JSON backticks from becoming Markdown syntax.
This additional classification enforces the intake's explicit refusal of backtick-enclosed evidence even when CommonMark's HTML block precedence would interrupt that quoting.
Parser fence tokens also identify unterminated examples; intake refuses later evidence after an unclosed fence even if an outdent ends its Markdown list container.
Both parses must accept the actual occurrence; neither provides reconstructed evidence bytes.
The original first-delimiter extraction and JSON validation remain in `check-pr-delivery.ts`.

`pr-delivery-narrative.ts` supplies an additional narrative-only input to the pinned assessors; its intake format is documented in [CONTRIBUTING.md](../../CONTRIBUTING.md).
It masks Pipeline sections before narrative evaluation and preserves source positions for field eligibility and HTML diagnostics.
Both the unchanged original body and the eligible narrative fields must pass the pinned assessors; filtering cannot authorize an original body that those assessors reject.
The narrative HTML refusal does not change the existing machine parser or reject its accepted HTML-wrapped Pipeline evidence.
