# docs/reviews/

External review records. One file per reviewed session:
`{prefix}{N}-codex-audit.md` (prefix from `lifecycle.config.json`).

- Written by the autonomous SessionEnd runner (wrapping verbatim `codex exec review`
  output), by a manual local Codex CLI run, or by a cloud reviewer.
- The file is the **raw external input** under a skeptic preamble; the **critical
  synthesis** (agree / dispute / act) is written by the NEXT session into the repo's
  session log (HANDOFF), never into the review file.
- Tracked records: never paste a secret/token value — cite `file:line`.
