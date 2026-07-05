---
description: Ask a question against this project's docs-wiki via the read-only docs-scout agent
argument-hint: <question>
---

Answer a question using ONLY this project's `docs-wiki/` knowledge base.

**Precondition:** if there is no `docs-wiki/` in the project, tell the user the wiki isn't
enabled here (run `/docs-init` first) and STOP.

1. Dispatch the read-only **docs-scout** subagent with a detailed request built from the
   user's question below. Give it the topic, the exact question(s), and what the answer is
   for. Let it deep-read `docs-wiki/` in its own isolated context and return a cited synthesis
   (EVIDENCE / CONFIDENCE / GAPS).

   Question: $ARGUMENTS

2. Relay docs-scout's answer WITH its citations (`file -> ## section`). If it returns GAPS,
   NEEDS CLARIFICATION, or DISABLED, surface that to the user rather than papering over it.

3. If docs-scout proposes contradictions/fixes, or if the answer itself is worth keeping,
   offer to file it back into the wiki via `/docs-sync` (the Karpathy "file outputs back into
   the knowledge base" loop).
