<!--
Copy to docs/reviews/{prefix}{N}-codex-audit.md and fill in.
The verbatim audit goes in section 2; the CRITICAL SYNTHESIS goes in docs/HANDOFF.md
(or this repo's session log), not here. The autonomous SessionEnd runner generates
files in this shape automatically.
-->

# External Audit — {Codex CLI | autonomous runner | cloud} (verbatim source, read CRITICALLY)

> External review of {files / commit range} captured {YYYY-MM-DD}.
> **Do NOT assume this is correct.** External reviewers can be wrong or
> over/under-state a risk. The critical synthesis — agree, dispute, act — belongs
> in the session log, written by the next session.

---

## 1. Metadata

- **Session:** {session id / ticket}
- **Reviewed:** {commit range `base..head`, or "uncommitted working tree @ branch"}
- **Reviewer:** {model id / tool}
- **Overall verdict:** APPROVE | APPROVE-WITH-NITS | NEEDS-CHANGES | BLOCK

## 2. Verbatim audit

{The external agent's output, unedited except ASCII normalization.}

## 3. Actionable items (reviewer's own list, if provided)

1. {finding} — [CRITICAL|HIGH|MEDIUM|LOW] — {file:line} — {suggested fix}
