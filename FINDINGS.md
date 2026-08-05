# Findings

Ten real bugs, found by actually installing Roswell and standing up a live
PostgreSQL instance rather than by reading the code. None of these showed up
in review; several are the kind of thing that would pass a code review
cleanly and then break in production on the second deploy. Grouped by cause,
in the order they surfaced.

## Wrong or fictional library APIs

**1. `cl-migratum-driver-pg` doesn't exist.**
The real system is `cl-migratum.driver.postmodern-postgresql`, and its API
is a `(provider connection-spec)` driver constructor built around a
*provider* that discovers migrations — not a bare function you hand a
generated SQL string to. Confirmed by listing `cl-migratum`'s actual ASDF
systems and reading its source directly rather than trusting the name.

**2. `sxql:create-schema` and `sxql:make-sql-keyword` don't exist.**
Confirmed by enumerating every external symbol SXQL exports: there is no
schema-DDL vocabulary in SXQL at all, and the function for a raw SQL literal
in a column default is `sxql:make-sql-symbol`, not `make-sql-keyword`. Both
were silently accepted by the reader as valid-looking function calls right
up until the code path that used them actually ran.

**3. SXQL's `:default nil` on a `NOT NULL` column means "no default
clause," not "false."**
```lisp
(done :type 'boolean :not-null t :default nil)
```
compiles to `done BOOLEAN NOT NULL` with no `DEFAULT` at all. Any `INSERT`
that didn't explicitly set `done` — which `api.add_todo` didn't — failed
with a not-null violation. The fix is `:default :false`, which SXQL compiles
to the literal `DEFAULT false`.

## Wrong assumptions about tool behavior

**4. Roswell automatically calls `(apply 'main *argv*)` in `cl-user` after
loading any script.**
This isn't opt-in. A script that defines its own `cl-user:main` and doesn't
call it itself still gets it called, by Roswell, after `load` finishes. A
script that defines a *differently-named* entry point and calls that
explicitly instead still gets Roswell's automatic call afterward — against
an undefined `MAIN`, which errors. Confirmed with a two-line repro script
before touching the real deploy script.

**5. `uiop:run-program`'s exit code is its third return value when `:output
nil`, not its primary one.**
```lisp
(zerop (uiop:run-program cmd :output nil :error-output nil
                          :ignore-error-status t))
```
crashes with a `TYPE-ERROR` (`NIL is not of type NUMBER`), because the
primary value in that call shape is `NIL`. The exit code needs
`(nth-value 2 ...)`. This shape is used all over the Consfigurator- and
UIOP-based scripting style in this codebase; it's an easy one to get wrong
consistently, in every function that uses it, without noticing, because the
call *looks* like it returns the exit code.

**6. Spinneret decides whether to quote an HTML attribute value from the
literal string it's given at compile time — and that decision, unlike most
things gated by a special variable, can't be overridden with a runtime
`LET`.**
This script generates HTML templates that PostgreSQL's own `format()` fills
in at request time, with Spinneret only ever seeing the placeholder text
(`"%s"`) at generation time. Since `"%s"` has no whitespace, Spinneret
omits the surrounding quotes:
```html
<span class=%s>%s</span>
```
which is syntactically valid HTML *for that literal string*, and silently
broken HTML the instant PostgreSQL substitutes in a value that contains a
space — exactly what happens for a completed to-do item, whose class value
is `line-through text-gray-400`. Nothing in the pipeline errors; the browser
just gets a malformed tag and a bogus extra attribute.

Spinneret already has the fix: `spinneret:*always-quote*`, a documented,
exported, tested special variable that does exactly this. The first attempt
to use it didn't work —
```lisp
(let ((spinneret:*always-quote* t))
  (spinneret:with-html-string ...))
```
still produced unquoted output — because the quoting decision happens at
*macroexpansion* time, when the `defun` containing the template is
compiled, not at runtime when it's called. A `LET` around the call site is
silently a no-op; only a top-level `(setf spinneret:*always-quote* t)`
evaluated *before* the template-generating functions are compiled actually
works. Nothing about that surprised the reader until it was tested — the
variable's docstring ("Add quotes to all attributes.") gives no hint that
`LET` won't do what it looks like it should do.

A related, separate issue in the same template: Spinneret treats the Lisp
keyword `:disabled` as HTML5's native boolean `disabled` attribute, so
```lisp
(:button ::disabled "!taskInput.trim()" ...)
```
collapses to a bare `disabled` — Alpine.js's `:disabled="expr"` binding is
discarded entirely, with no warning that the value was ever thrown away.
Pipe-quoting the attribute name as `:|:disabled|` sidesteps the collision
(it's a different literal name than `disabled`), and combined with
`*always-quote*` set at load time, produces the fully correct
`:disabled="!taskInput.trim()"`.

One placeholder in this script's per-row template genuinely can't be
expressed through Spinneret's declarative macros at all, and this isn't
a Spinneret shortcoming: the checkbox's `checked` state is an HTML5 boolean
attribute, whose presence Spinneret can only decide from a Lisp-level
true/false value at generation time — and whether a given row is done isn't
known until PostgreSQL resolves it at request time. That one input stays a
hand-written `:raw` placeholder for that reason; every other element in
both templates is ordinary declarative Spinneret markup.

## Idempotency bugs in the schema itself

These three predate every session working on this script — present since
the very first draft, never exercised until an actual second deploy against
a live database was attempted.

**7. `CREATE ROLE web_anon NOLOGIN` has no `IF NOT EXISTS`, and roles are
cluster-level, not database-level.**
Dropping and recreating the *database* doesn't drop the role. On a real
target — where the whole point of the ZFS-backed data volume is that it
*doesn't* get dropped between deploys — a bare `CREATE ROLE` fails with a
duplicate-object error on every redeploy after the first. Fixed with the
standard idiom:
```sql
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'web_anon')
  THEN CREATE ROLE web_anon NOLOGIN;
  END IF;
END $$
```

**8. `CREATE DOMAIN api.html AS text` has the same problem.**
PostgreSQL's `CREATE DOMAIN` has no `IF NOT EXISTS` clause either, and
`CREATE SCHEMA IF NOT EXISTS` leaves an existing schema's contents —
including this domain — untouched on redeploy. Same fix shape, checking
`pg_catalog.pg_type` joined to `pg_catalog.pg_namespace` (domains are
stored as types, not in a dedicated catalog).

**9. `toggle_todo` and `delete_todo` both had an ambiguous column
reference.**
```sql
UPDATE api.todos SET done = NOT done WHERE id = toggle_todo.id
```
The function's own parameter is named `id`. The right-hand side
(`toggle_todo.id`) is a real, if old-fashioned, way to disambiguate a
PL/pgSQL parameter from a column of the same name — but the bare `id` on
the left is still ambiguous between the table column and the parameter, and
PostgreSQL rejects the whole statement rather than guessing. This one
wasn't redeploy-specific: it broke on the very first call, on a freshly
migrated, otherwise-correct schema. Fixed by qualifying both sides:
`WHERE api.todos.id = toggle_todo.id`.

## Minor

**10. A trailing statement separator sent one empty query per migration.**
The join between generated statements placed the driver's `--;;` separator
after every element including the last, so the driver's split produced one
trailing empty piece, sent to Postgres as an empty query (a harmless
`WARNING`, not an error, but worth cleaning up). Fixed by moving the
separator inside a `~^` directive so it only prints between elements.

## What was actually a fictional Consfigurator dependency

Separately from the ten items above: the script originally used
Consfigurator (`defhost`/`defproperty`/`deploy`) for the provisioning
layer. Loading it in a clean environment reproduced a `CFFI-GROVEL` failure
on its ACL and POSIX-capabilities native bindings — the exact failure mode
this org's `dps-meta` project had already hit and walked away from twice.
Installing the first missing header (`libacl1-dev`) just uncovered the
next one (`libcap-dev`), which is the shape of problem that doesn't end at
one `apt-get install`. Consfigurator was dropped from the deploy path
entirely; the properties it declared were already just wrapping
`uiop:run-program` calls underneath, so they're now plain functions calling
`uiop:run-program` directly, with no change in behavior and one fewer
fragile system-level dependency.
