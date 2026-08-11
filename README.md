# todo-app-deploy

A Roswell/Consfigurator deploy of a small PostgREST + HTMX + Alpine.js
to-do list app on rootless Podman quadlets behind HAProxy. The point isn't
the app. It's that every layer of it (systemd units, SQL schema, HTML) gets
generated from a small in-memory representation instead of hand-typed
strings, the same way a compiler works from an AST rather than concatenating
text.

Almost everything in this repo exists because building it surfaced real bugs
in the assumptions behind it: some in this script, some genuine footguns in
the libraries it leans on. See [FINDINGS.md](FINDINGS.md) for the full list.
Each one was caught by running the thing against a live Roswell install and
a live PostgreSQL instance, not by code review alone.

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
  neither is documented as a Consfigurator dependency anywhere upstream
  (see UPSTREAM.md), so it's called out here explicitly.
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
`defhost` over a `:local` connection. See FINDINGS.md for why it wasn't
loading at first, and @provisioning/@quadlets in `src/docs.lisp`'s
40ants-doc sections for how the properties are actually built.

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

`docs.ros` currently fails on a real bug in `40ants-doc-full`'s own
markdown renderer, unrelated to this repo's code; see finding 12 in
[FINDINGS.md](FINDINGS.md).

Both `deploy` and `e2e` are dispatched from a single `main (&rest argv)` in
`todo-app-deploy.ros`'s own throwaway wrapper package. Roswell calls `main`
automatically after loading the script; it isn't invoked explicitly in the
file itself.

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

## Upstream

Two documentation patches came out of building this. See
[UPSTREAM.md](UPSTREAM.md) for the reasoning, and
[`upstream-patches/`](upstream-patches/) for the ready-to-send
`.patch` files and git bundles against Consfigurator and Spinneret.
