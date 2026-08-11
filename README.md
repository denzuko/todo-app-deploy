# todo-app-deploy

A single Roswell script that stands up a small PostgREST + HTMX + Alpine.js
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

The script bootstraps its own Lisp dependencies on first run, falling back
to Ultralisp only for whichever systems aren't already in the local
Quicklisp dist:

```
consfigurator sxql spinneret cl-inix 40ants-doc fiveam dexador postmodern
cl-migratum cl-migratum.driver.postmodern-postgresql
```

Consfigurator drives the actual provisioning: ZFS datasets, the service
account, the generated secret, pulled images, the quadlet unit files, and
the HAProxy vhost are all Consfigurator properties applied to a single
`defhost` over a `:local` connection. See FINDINGS.md for why it wasn't
loading at first, and @provisioning/@quadlets in the script's own
40ants-doc sections for how the properties are actually built.

## Usage

```sh
chmod +x todo-app-deploy.ros

# deploy
./todo-app-deploy.ros

# validate an existing deploy: FiveAM, no bats anywhere in the loop
./todo-app-deploy.ros e2e
```

Both subcommands are dispatched from a single `cl-user:main (&rest argv)`.
Roswell calls this automatically after loading the script, which is a
different convention than the file structure suggests at first glance. See
FINDINGS.md if that surprises you. It surprised me too.

## Layout

Everything lives in one file, in three packages:

- `todo-app-deploy`: the deploy logic itself.
- `todo-app-deploy.e2e`: a FiveAM suite that validates a live deploy.
  It checks ZFS mountpoints, linger, quadlet unit state, the HAProxy-fronted
  URL over real HTTP via Dexador, the schema and grants via Postmodern, and
  a full add-toggle-delete round trip through the actual API.
- `cl-user`: just the Roswell entry point.

Both `todo-app-deploy` and `todo-app-deploy.e2e` are documented as
[40ants-doc](https://40ants.com/doc/) sections (`@todo-app-deploy`,
`@todo-app-e2e`) rather than block comments. Read those first if you want
the narrative version of what's below.

## License

BSD 3-Clause. See [LICENSE](LICENSE).

## Upstream

Two documentation patches came out of building this. See
[UPSTREAM.md](UPSTREAM.md) for the reasoning, and
[`upstream-patches/`](upstream-patches/) for the ready-to-send
`.patch` files and git bundles against Consfigurator and Spinneret.
