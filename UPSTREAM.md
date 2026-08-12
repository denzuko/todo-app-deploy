# Upstream candidates

Most of [FINDINGS.md](FINDINGS.md) is this script being wrong about
libraries that were already behaving correctly and as designed. None of
that is a library bug, and it's worth being precise about the distinction
before forking anything or opening an issue against someone else's project.

Nine of the twelve findings settle that way outright. `cl-migratum-driver-pg`
never existed; the real driver constructor was there all along. SXQL has no
schema-DDL vocabulary and never claimed to. Roswell's automatic call to
`main` is documented behavior, not a surprise the framework owes an
apology for. `uiop:run-program` returns its exit code as the third value by
design. `CREATE ROLE` and `CREATE DOMAIN` have no `IF NOT EXISTS` clause
because PostgreSQL doesn't offer one for either, on purpose. The ambiguous
`id` column reference and the trailing empty migration statement are both
this script's own mistakes in SQL it generated itself. Consfigurator's
`WITH-DEPLOYMENT-REPORT` returning normally regardless of failure is the
same shape of non-bug: report-then-continue is a legitimate design choice
for a configuration-management tool, and it's this script's job, not
Consfigurator's, to decide it wants fail-fast semantics and wrap the call
accordingly. None of the nine is upstream-worthy; each is fixed locally,
and FINDINGS.md covers the fix.

Three findings land differently, and each turns out to be a real gap in
someone else's project rather than this script being wrong.

`3bmd`'s smart-dash extension (used by `commondoc-markdown`, which
`40ants-doc-full` builds on) throws `ESRAP:UNDEFINED-RULE-ERROR: The rule
INLINE is undefined` on a bare `--word` with no space, like a CLI flag
written in running prose. Minimal repro: `(commondoc-markdown::parse-markdown
"--user")` fails; `(commondoc-markdown::parse-markdown "-- user")` (space
after) and `(commondoc-markdown::parse-markdown "-user")` (single hyphen)
both succeed. This is a real bug in `3bmd`'s or `commondoc-markdown`'s
grammar, not a documentation gap like the other two below, and not
something to patch blind here: fixing an ESRAP grammar correctly needs
more familiarity with that grammar's internals than skimming it from the
outside gives. No patch prepared; the minimal repro above is enough to
file an issue quickly whenever that's worth doing. Worked around locally
by wrapping the flag in backticks in FINDINGS.md and in this project's
own docstrings, which is arguably the more correct way to write a CLI
flag in prose anyway, not just a workaround.

Two findings land as pure documentation gaps rather than code bugs.

Spinneret's `*always-quote*` already does the right thing: it exists
specifically to force attribute quoting when Spinneret can't infer it from
the literal text it sees at compile time. The problem is that nothing says
so. The variable isn't mentioned in the README, and its one-line docstring
gives no hint that it has to be set with `setf` before the affected code
compiles, since a `let` around the call site has no effect. That's a real
trap for the next person who hits the same wrong assumption this script
did, and it's a much better-scoped contribution than an issue implying
Spinneret's behavior is wrong: Spinneret solved the problem correctly, it
just never told anyone the solution existed.

Consfigurator's `CFFI-GROVEL` failure on `libacl1-dev` and `libcap-dev`
is the same shape of gap. Loading Consfigurator outside its packaged
`.deb`, whether through Quicklisp or straight from git, needs both native
headers, and neither Installation.rst nor the build output says so before
the grovel step fails. The environment is doing exactly what it's supposed
to; the dependency is just undocumented outside the packaging that already
handles it.

Both patches are prepared and staged in this repo, ready to send rather
than merely proposed.

`upstream-patches/consfigurator/` holds a `git format-patch` and a git
bundle against `doc/native-dependency-note`, adding a short section to
`installation.rst` naming both packages. Consfigurator doesn't take GitHub
pull requests (its `CONTRIBUTING.rst` says so directly); the patch goes to
the `sgo-software-discuss` mailing list via `git send-email`, or as a
publicly hosted branch with a merge request by email. Sending or pushing
either way needs an account with the right credentials, which this
sandbox doesn't carry.

`upstream-patches/spinneret/` holds the same pairing against
`doc/always-quote-attribute-quoting`: a README section on attribute
quoting, and an expanded `*always-quote*` docstring carrying the same
warning inline. This one's a normal GitHub project with the ordinary PR
workflow, verified by loading the edited checkout through ASDF and
confirming both the docstring and the behavior it describes hold up.

Everything else in this repo is homegrown and stays homegrown.
