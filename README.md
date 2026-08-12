# todo-app-deploy

A Roswell/Consfigurator deploy of a small PostgREST + HTMX + Alpine.js
to-do list app on rootless Podman quadlets behind HAProxy. The point isn't
the app. It's that every layer of it (systemd units, SQL schema, HTML) gets
generated from a small in-memory representation instead of hand-typed
strings, the same way a compiler works from an AST rather than concatenating
text.

## What it builds

- Two ZFS datasets, a rootless systemd-user service account with linger
  enabled, and a generated database password persisted under that account's
  home, each provisioned as a Consfigurator property (custom where no
  built-in fits, Consfigurator's own where one does) rather than a
  hand-rolled shell-out.
- Three Podman quadlet units (Postgres, PostgREST, a shared network),
  serialized from an in-memory `(section . ((key . value) ...))`
  representation rather than a heredoc. It's the same shape `cl-inix:read`
  returns from parsing an INI file, with a small hand-written writer
  (`cinix-write-string`) playing the write-side counterpart.
- An HAProxy vhost terminating TLS and backending to PostgREST on loopback.
- A Postgres schema, roles, and grants, built with SXQL where SXQL actually
  covers the statement type, and a couple of small structured builders
  (`sql-create-schema`, `sql-create-role`, `sql-grant`, `sql-grant-execute`)
  where it doesn't.
- Two HTML templates (the page shell, the per-row fragment) built with
  Spinneret, each carrying PostgreSQL's own `format()` placeholders for the
  data that isn't known until request time.
- The whole migration applied through cl-migratum's real
  `postmodern-postgresql` driver, against a from-scratch in-memory
  `ram-provider`/`ram-migration` pair. Nothing hits disk as a migration
  file.

## Requirements

- [Roswell](https://github.com/roswell/roswell)
- `libacl1-dev` and `libcap-dev` on the machine that loads this script.
  Consfigurator's `CFFI-GROVEL` step needs both native headers to build;
  neither is documented as a Consfigurator dependency anywhere upstream,
  so it's called out here explicitly. A doc patch for this is prepared
  in [`upstream-patches/consfigurator/`](upstream-patches/consfigurator/).
- A target host with `zfs`, `podman` (rootless, quadlet-capable systemd),
  `haproxy`, and `machinectl`. This is written for a specific home-lab
  style stack, not a generic cloud target.
- A reachable PostgreSQL server for the migration step.

Both `.ros` entry points bootstrap their Lisp dependencies on first run,
falling back to Ultralisp only for whichever systems aren't already in the
local Quicklisp dist:

```
consfigurator sxql spinneret cl-inix 40ants-doc fiveam dexador postmodern
cl-migratum cl-migratum.driver.postmodern-postgresql
```

Consfigurator drives the actual provisioning: ZFS datasets, the service
account, the generated secret, pulled images, the quadlet unit files, and
the HAProxy vhost are all Consfigurator properties applied to a single
`defhost` over a `:local` connection. See @provisioning/@quadlets in
`src/docs.lisp`'s 40ants-doc sections for how the properties are actually
built.

## Usage

```sh
chmod +x todo-app-deploy.ros docs.ros

# deploy
./todo-app-deploy.ros

# validate an existing deploy: FiveAM, no bats anywhere in the loop
./todo-app-deploy.ros e2e

# render the 40ants-doc sections to build/*.md
./docs.ros
```

Both `deploy` and `e2e` are dispatched from a single `main (&rest argv)` in
`todo-app-deploy.ros`'s own throwaway wrapper package. Roswell calls `main`
automatically after loading the script; it isn't invoked explicitly in the
file itself.

## Runbook

Everything below assumes the variables in `src/deploy.lisp`
(`*service-user*`, `*home-mountpoint*`, `*data-mountpoint*`,
`*haproxy-vhost-name*`) at their current values: service account
`todo-app`, home `/var/lib/todo-app`, data `/srv/todo-app`, HAProxy vhost
name `todo-app`. Adjust if those have changed.

**Is it up?**

```sh
machinectl shell todo-app@ -- systemctl --user status postgres postgrest
systemctl status haproxy
```

**Logs.** Both containers log through their quadlet-generated units, in
the service user's own journal:

```sh
machinectl shell todo-app@ -- journalctl --user -u postgres -u postgrest -f
```

**Restart the app containers** (does not touch ZFS, the account, or
HAProxy):

```sh
machinectl shell todo-app@ -- systemctl --user restart postgres postgrest
```

**Redeploy.** `./todo-app-deploy.ros` is idempotent; rerunning it only
touches whatever Consfigurator's `:check` clauses find missing or changed
(new quadlet content, a modified HAProxy vhost) and leaves the rest alone.
It will not regenerate the database secret; see below if that's actually
what's needed.

**Validate a deploy** without redeploying:

```sh
./todo-app-deploy.ros e2e
```

**Database access**, via the running container (peer auth inside the
container, no password needed for this path):

```sh
machinectl shell todo-app@ -- podman exec -it todo-postgres \
  psql -U postgres -d tododb
```

To read the generated password itself (needed for any external
connection, e.g. through `PGRST_DB_URI`):

```sh
cat /var/lib/todo-app/.env/pgpass
```

**Rotating the database password.** `db-secret-file`'s whole point is
leaving the secret alone on redeploy, so this is a deliberate manual
procedure, not something a redeploy will ever do for you:

```sh
machinectl shell todo-app@ -- systemctl --user stop postgres postgrest
NEW_PASS=$(openssl rand -hex 32)
machinectl shell todo-app@ -- \
  podman exec todo-postgres psql -U postgres -c \
  "ALTER USER postgres WITH PASSWORD '$NEW_PASS'"
# then edit /var/lib/todo-app/.env/pgpass to match $NEW_PASS in both
# POSTGRES_PASSWORD and PGRST_DB_URI, before restarting:
machinectl shell todo-app@ -- systemctl --user start postgres postgrest
```

**Common failure modes:**

- `deploy-app` aborts with "TODO-APP-HOST provisioning reported failed
  properties": read the per-property report immediately above the error;
  Consfigurator names exactly which property failed and why.
- Quadlet changes not taking effect: `systemctl --user daemon-reload`
  needs to run in the service user's session after any unit file changes,
  which `quadlets-activated` already does as part of a normal deploy, but
  is easy to forget after a manual edit.
- `loginctl show-user todo-app --property=Linger` should say `yes`; if
  the service user's systemd session isn't surviving reboots, this is
  the first thing to check.

## Decommission

Destructive and, past the ZFS step, not reversible without a separate
backup. Stop before destroy, least-destructive first:

```sh
# 1. Stop the app
machinectl shell todo-app@ -- systemctl --user stop postgres postgrest

# 2. Remove the quadlet unit files and reload
rm /var/lib/todo-app/.config/containers/systemd/{postgres.container,postgrest.container,todo-net.network}
machinectl shell todo-app@ -- systemctl --user daemon-reload

# 3. Remove the HAProxy vhost and reload
rm /etc/haproxy/conf.d/todo-app.cfg
systemctl reload haproxy

# 4. Disable linger and remove the service account
loginctl disable-linger todo-app
userdel todo-app

# 5. Destroy the ZFS datasets -- irreversible, takes the database and
#    the generated secret with it. Confirm there's nothing worth keeping
#    (a pg_dump, a snapshot) before this step.
zfs destroy storage/containers/todo-app
zfs destroy storage/users/todo-app
```

Podman images pulled into the service user's rootless store are removed
along with the account in step 4; nothing separate to clean up there.

## Layout

`:todo-app` is the umbrella ASDF namespace, defined in
[`todo-app.asd`](todo-app.asd) and empty except for existing so its
slash-named subsystems can load at all (both ASDF and Quicklisp resolve a
system named `todo-app/deploy` by first locating `todo-app` itself). A
future component (a webapp, a CLI, whatever) would add `todo-app/<name>`
alongside the three below without renaming anything already here:

- [`src/deploy.lisp`](src/deploy.lisp) (`:todo-app/deploy`): the deploy
  logic itself; everything documented in @provisioning, @quadlets, and
  @database.
- [`t/e2e.lisp`](t/e2e.lisp) (`:todo-app/e2e`): a FiveAM suite that
  validates a live deploy. It checks ZFS mountpoints, linger, quadlet unit
  state, the HAProxy-fronted URL over real HTTP via Dexador, the schema
  and grants via Postmodern, and a full add-toggle-delete round trip
  through the actual API.
- [`src/docs.lisp`](src/docs.lisp) (`:todo-app/docs`): the 40ants-doc
  sections, kept in their own system so a production deploy (or a `ros
  dump executable` static binary) never has to pull in 40ants-doc just to
  provision a stack.

`todo-app-deploy.ros` and `docs.ros` are thin command wrappers: each loads
`todo-app.asd`, quickloads what it needs, and dispatches into the real
systems above. Neither carries any deploy or documentation logic itself.

`@todo-app-deploy` and `@todo-app-e2e` are the two top-level 40ants-doc
sections, rendered by `docs.ros`. Read those first if you want the
narrative version of what's below.

## License

BSD 3-Clause. See [LICENSE](LICENSE).

## Build, test, dist

```sh
ros init myapp        # not needed here (this repo already exists), but
                      # this is the standard project-start sequence
ros install qlot      # once, to get the qlot CLI
qlot add <dep>         # adds a dependency to qlfile and pins it in
                      # qlfile.lock; already done for everything this
                      # repo needs, only relevant when adding a new one
make                  # doc + todo-app-deploy.tgz
make test             # runs ./todo-app-deploy.ros e2e against a live
                      # deploy; nothing to validate without one
make install          # tar -C / -x the built tgz
make clean            # remove build/
```

`qlfile.lock` pins every dependency (109, transitively) to the exact
release `qlot add`/`qlot install` resolved. `ros dump executable`
(verified: it builds and runs correctly against this project's full
dependency tree, Consfigurator's native bindings included) works
directly, no extra setup at invocation time beyond having run `qlot add`
against the project once.

## Upstream

Two documentation patches are prepared and ready to send, in
[`upstream-patches/`](upstream-patches/) as both `.patch` files and git
bundles:

- **Consfigurator**: notes that `libacl1-dev`/`libcap-dev` are real build
  dependencies of its `CFFI-GROVEL` step, undocumented anywhere upstream.
  Consfigurator doesn't take GitHub pull requests; this goes to the
  `sgo-software-discuss` mailing list via `git send-email`, or as a
  publicly hosted branch with a merge request by email.
- **Spinneret**: documents `spinneret:*always-quote*`'s compile-time-only
  behavior (`let`-binding it around a call site is a silent no-op; it has
  to be `setf` before the affected code compiles). Ordinary GitHub PR
  workflow.

One further bug, unpatched: `3bmd`'s smart-dash extension (used by
`commondoc-markdown`, which `40ants-doc-full` builds on) breaks on a bare
`--word` with no space, throwing `ESRAP:UNDEFINED-RULE-ERROR`. Minimal
repro: `(commondoc-markdown::parse-markdown "--user")` fails,
`"-- user"` and `"-user"` both succeed. Worked around locally by wrapping
CLI flags in backticks in this project's own docstrings (the correct way
to write one in prose regardless). No patch prepared; fixing an ESRAP
grammar correctly needs more familiarity with it than skimming it from
the outside gives.
