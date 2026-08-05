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
| 6 | Spinneret's `*always-quote*` fixes the quoting problem but is undiscoverable and its `LET`-doesn't-work compile-time behavior is undocumented | **candidate docs PR, not a bug report** | Spinneret already solved this; the actual gap is that `*always-quote*` isn't mentioned in the README at all, and its one-line docstring doesn't warn that binding it dynamically around a call site silently does nothing. A documentation PR (README section + expanded docstring) is a much better-scoped contribution than an issue implying Spinneret's behavior is wrong |
| 7 | `CREATE ROLE` not idempotent | this script's schema | none — not a library issue, Postgres has never had `CREATE ROLE IF NOT EXISTS` in the general case by design |
| 8 | `CREATE DOMAIN` not idempotent | this script's schema | none, same reasoning as #7 |
| 9 | Ambiguous `id` column reference | this script's schema | none — correct PL/pgSQL behavior, this script's naming mistake |
| 10 | Trailing empty statement | this script | none |
| — | Consfigurator `CFFI-GROVEL` failure on ACL/capabilities headers | environment, not a bug | not upstream-worthy as filed; could be a docs PR noting the native dependency on `libacl1-dev`/`libcap-dev` isn't mentioned anywhere in Consfigurator's own install docs, which is genuinely useful to know before reaching for it |

## Net: two forkable items, both documentation patches, neither a code change

Both real bugs found in third-party code turned out, on closer reading of
the actual source, not to be bugs at all — Consfigurator's grovel
dependency is a legitimate (if undocumented) system requirement, and
Spinneret already ships the fix for the quoting issue. That distinction
matters for how these get filed: neither is "please change this behavior,"
both are "please tell people about this before they lose an hour to it."

- **Consfigurator** — `git.spwhitton.name/consfigurator` does not accept
  GitHub pull requests (see its `CONTRIBUTING.rst`); patches go to the
  `sgo-software-discuss` mailing list via `git-send-email`, or as a
  publicly-hosted branch with an email asking for a merge. Patch prepared
  and committed on `doc/native-dependency-note`, `git format-patch` output
  and a git bundle both in `upstream-patches/consfigurator/`. Ready to send
  with `git send-email --to=spwhitton@spwhitton.name
  --subject-prefix="PATCH consfigurator"
  upstream-patches/consfigurator/*.patch`, or to push as a fork branch and
  email asking for a merge instead. Needs an account with the right
  credentials to actually send/push.
- **Spinneret** — a normal GitHub project, no `CONTRIBUTING.rst` found,
  ordinary PR workflow. Patch prepared and committed on
  `doc/always-quote-attribute-quoting` against a fresh clone of
  `ruricolist/spinneret`, verified by loading the edited checkout through
  ASDF and confirming both the docstring and the behavior it describes
  still work. `git format-patch` output and a git bundle both in
  `upstream-patches/spinneret/`. Ready to push to a fork and open as a PR.

Everything else in this repo is homegrown and stays homegrown.
