# Upstream candidates

Most of [FINDINGS.md](FINDINGS.md) is this script being wrong about
libraries that were already behaving correctly and as designed — not bugs
in the libraries themselves. Worth being precise about that distinction
before forking anything or opening issues against someone else's project.

| # | Finding | Whose bug | Action |
|---|---|---|---|
| 1 | `cl-migratum-driver-pg` doesn't exist | this script | none — fixed locally |
| 2 | `sxql:create-schema`/`make-sql-keyword` don't exist | this script | possible feature request to SXQL for schema DDL, not a bug report |
| 3 | SXQL `:default nil` means "omit," not "false" | this script (arguably a documentation gap in SXQL) | maybe a docs PR — `:default` semantics aren't obvious from the README |
| 4 | Roswell auto-calls `main` after loading a script | this script's wrong assumption | none — Roswell is correct and documented, I just hadn't read it closely enough |
| 5 | `uiop:run-program` exit code is the third value | this script | none — UIOP is correct, worth a note in whatever internal style guide covers this pattern |
| 6 | Spinneret's attribute quoting is decided at generation time | **candidate real issue** | open an issue describing the multi-stage-template failure mode; a PR isn't obviously right since "always quote" has its own tradeoffs (verbosity, and Spinneret may have reasons for the current behavior) — issue first, PR only if maintainers want one |
| 7 | `CREATE ROLE` not idempotent | this script's schema | none — not a library issue, Postgres has never had `CREATE ROLE IF NOT EXISTS` in the general case by design |
| 8 | `CREATE DOMAIN` not idempotent | this script's schema | none, same reasoning as #7 |
| 9 | Ambiguous `id` column reference | this script's schema | none — correct PL/pgSQL behavior, this script's naming mistake |
| 10 | Trailing empty statement | this script | none |
| — | Consfigurator `CFFI-GROVEL` failure on ACL/capabilities headers | environment, not a bug | not upstream-worthy as filed; could be a docs PR noting the native dependency on `libacl1-dev`/`libcap-dev` isn't mentioned anywhere in Consfigurator's own install docs, which is genuinely useful to know before reaching for it |

## Net: two forkable items

- **Spinneret** — open an issue first (#6). A repro is already in
  FINDINGS.md; it's a two-line `with-html-string` call.
- **Consfigurator** — a docs PR noting the grovel dependencies, not a code
  fix. Low priority, easy, and saves someone else the same hour of
  `apt-get install` whack-a-mole.

Everything else in this repo is homegrown and stays homegrown.
