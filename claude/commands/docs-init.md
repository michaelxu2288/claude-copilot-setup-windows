---
description: Enable the per-project docs wiki — scaffold docs-wiki/ (Karpathy KB model) and add per-project CLAUDE.md lines
---

The user is opting THIS project into the docs wiki system. Do the following, then stop and
summarize. Everything stays inside the current project root — never touch files outside it.

1. **Locate the project root** (current working directory / `$CLAUDE_PROJECT_DIR`). If a
   `docs-wiki/` already exists, do NOT clobber it — report that the wiki is already enabled,
   skip scaffolding, and just make sure the CLAUDE.md lines from step 3 are present.

2. **Scaffold the Karpathy-model knowledge base under `docs-wiki/`:**
   - `docs-wiki/README.md` — the index / doc-map. Seed it with: a one-line purpose; a
     short "How this wiki works" note (raw sources in `raw/` are LLM-compiled into linked
     concept articles in `wiki/` using `[[wikilinks]]` + backlinks; the wiki is the LLM's to
     maintain, humans rarely edit by hand; it is a valid Obsidian vault); and empty
     `## Articles` and `## Raw sources` index sections to be filled as content grows.
   - `docs-wiki/raw/README.md` — explains `raw/` holds ingested sources (articles, papers,
     repo notes, datasets, images) each with a light summary.
   - `docs-wiki/wiki/README.md` — explains `wiki/` holds compiled, cross-linked concept
     articles distilled from `raw/` and from session work.
   - `docs-wiki/images/.gitkeep` — local images referenced by articles live here.
   - `docs-wiki/.backups/.gitkeep` — timestamped snapshots written by `/docs-sync` before edits.

3. **Add per-project docs lines to the project's own `./CLAUDE.md`** (create it if missing;
   if it exists, append this as a clearly-marked new section — do not rewrite the file):

   ```
   ## Docs wiki (enabled)

   This project uses a local docs wiki at `./docs-wiki/` (Karpathy LLM-KB model: raw sources
   compiled into linked `.md` concept articles). Adhere to it:
   - Before substantial work, dispatch the read-only **docs-scout** subagent to pull cited
     prior context from `docs-wiki/` — don't re-derive what the wiki already knows.
   - After good work / a milestone, run **/docs-sync** to fork **docs-writer** subagent(s)
     and file the session's durable new knowledge back into `docs-wiki/`.
   - Drop source material (articles, papers, notes, images) into `docs-wiki/raw/` for the
     wiki to compile. Ask the wiki questions with **/docs-ask**.
   - The wiki is the LLM's to maintain — humans rarely edit it by hand. View it in Obsidian.
   ```

4. **Report** what you created and remind the user they can now: drop sources into
   `docs-wiki/raw/`, run `/docs-sync` after good work, and query with `/docs-ask`.

Never create `docs-wiki/` anywhere except the current project root.
