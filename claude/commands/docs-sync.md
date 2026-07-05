---
description: Fork several docs-writer subagents to compile this session's durable knowledge into docs-wiki/
---

Reconcile the durable knowledge from the CURRENT session into this project's `docs-wiki/`.

**Precondition:** the project must have a `docs-wiki/` directory. If it does not, tell the
user the wiki isn't enabled here (run `/docs-init` first) and STOP — do not create it.

1. **Snapshot first (undo net).** `docs-wiki/` may not be under git. Copy the current
   `docs-wiki/` (excluding `.backups/`) into `docs-wiki/.backups/<UTC-timestamp>/`. Prune to
   the 10 most recent snapshots.

2. **Triage the session.** List the DURABLE, doc-worthy knowledge ONLY: passing/failing
   proofs with reusable conclusions; confirmed or corrected configs / commands / paths;
   resolved contradictions; status changes; new traps or runbooks; new durable facts; new
   source material to compile into `wiki/`. Ignore ephemeral narration, reverted dead-ends,
   secrets, and speculation. If nothing is durable, say so and STOP — a no-op is a correct,
   common outcome.

3. **Partition into disjoint slices** so parallel writers never edit the same file — e.g. one
   slice per target file / concept article / raw source. Aim for 2-4 slices (fewer if there is
   little to write).

4. **Fork the writers.** Launch one **docs-writer** subagent PER SLICE, IN PARALLEL (multiple
   Agent/Task calls in a SINGLE message). Give each writer: the specific durable facts for its
   slice, the exact file(s) it owns, and the instruction to edit ONLY those files — surgical
   increment; compile `raw/` -> `wiki/` with `[[wikilinks]]`/backlinks; update the `README.md`
   index; honor the authority hierarchy; never commit/delete/wholesale-rewrite; date entries
   with today's date.

5. **Collect + report.** Merge the writers' CHANGE REPORTs into one summary: FILES CHANGED,
   WHAT WAS CAPTURED, DELIBERATELY SKIPPED, CONTRADICTIONS RESOLVED. Remind the user the edits
   are uncommitted local changes to review, and where the snapshot is.

Only ever write inside `docs-wiki/`. Never commit or push. The only deletions allowed are
pruning old snapshots under `docs-wiki/.backups/`.
