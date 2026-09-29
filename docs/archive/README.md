# Docs archive

Frozen, not deleted. Completed one-shot handoffs, spent mission prompts,
and closed phase reports move here (via `git mv`, history preserved) once
their work has shipped and no live doc links to them.

- Each batch lives under `YYYY-MM/` for the month it was archived.
- Dated one-off evidence freezes (drills, certification runs, screenshot
  sets proving a fix) live under `evidence/YYYY-MM-DD-<slug>/`, each with a
  README naming the commit, the producing command, and the verdict. They
  are never edited after commit; a correction is a new dated directory.
  Placement and ownership rules: [`../INDEX.md`](../INDEX.md).
- The freshness gate (`scripts/ci/check-docs-freshness.sh`) excludes this
  tree: archived docs are point-in-time records by design.
- To revive a doc, `git mv` it back and link it from a live index or guide;
  the gate picks it up as a linked (fresh) file again.
