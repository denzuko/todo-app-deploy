# todo-app-deploy

Roswell/Consfigurator deployment automation for a PostgREST + HTMX +
Alpine.js to-do list application, running on rootless Podman quadlets
behind HAProxy. Every generated artifact (systemd unit files, SQL schema,
HTML) is produced from an in-memory representation rather than composed
as literal text, following the same construct-then-render model a
compiler uses when emitting output from an abstract syntax tree.

## System Components

- Two AES-256-GCM natively encrypted ZFS datasets, each keyed from a raw
  key file generated once and stored outside the dataset it protects; a
  rootless systemd-user service account with linger enabled; and a
  generated database credential persisted under that account's home
  directory. Each component is provisioned as a Consfigurator property: a
  custom property where no built-in equivalent exists, a built-in
  Consfigurator property where one does, rather than an ad hoc shell
  invocation.
- Three Podman quadlet units (PostgreSQL, PostgREST, and a shared
  network), serialized from an in-memory
  `(section . ((key . value) ...))` representation. This is the same
  structural shape `cl-inix:read` returns when parsing an INI file;
  `cinix-write-string` serves as its write-side counterpart.
- An HAProxy virtual host terminating TLS and proxying to PostgREST over
  loopback.
- A PostgreSQL schema, roles, and grants, constructed with SXQL where
  SXQL supports the statement type, and with purpose-built structured
  generators (`sql-create-schema`, `sql-create-role`, `sql-grant`,
  `sql-grant-execute`) where it does not.
- Two HTML templates (the page shell and the per-row fragment),
  constructed with Spinneret, each embedding PostgreSQL's own `format()`
  placeholders for data not known until request time.
- The database migration, applied through cl-migratum's
  `postmodern-postgresql` driver against an in-memory
  `ram-provider`/`ram-migration` pair. No migration artifact is written
  to disk.

## Requirements

- [Roswell](https://github.com/roswell/roswell)
- `libacl1-dev` and `libcap-dev`, present on the host that loads this
  deployment. Consfigurator's `CFFI-GROVEL` build step requires both
  native headers; neither is documented as a Consfigurator dependency
  upstream.
- A target host providing `zfs`, `podman` (rootless, quadlet-capable
  systemd), `haproxy`, and `machinectl`. This deployment targets a
  specific home-lab infrastructure profile, not a generic cloud
  environment.
- A reachable PostgreSQL server for the migration step.

Both `.ros` entry points resolve their Lisp dependencies on first
invocation, falling back to Ultralisp for any system not already present
in the local Quicklisp distribution:

```
consfigurator sxql spinneret cl-inix 40ants-doc fiveam dexador postmodern
cl-migratum cl-migratum.driver.postmodern-postgresql
```

Consfigurator performs all provisioning. ZFS datasets, the service
account, the generated secret, pulled container images, the quadlet unit
files, and the HAProxy virtual host are Consfigurator properties applied
to a single `defhost` over a `:local` connection. The `@provisioning` and
`@quadlets` 40ants-doc sections in `src/docs.lisp` document how each
property is constructed.

## Usage

```sh
chmod +x todo-app-deploy.ros docs.ros

# deploy
./todo-app-deploy.ros

# validate an existing deployment (FiveAM; no external test framework)
./todo-app-deploy.ros e2e

# render the 40ants-doc sections to build/*.md
./docs.ros
```

The `deploy` and `e2e` operations are dispatched from a single
`main (&rest argv)` function in a throwaway wrapper package local to
`todo-app-deploy.ros`. Roswell invokes `main` automatically after loading
the script; the file does not invoke it explicitly.

## Runbook

The commands in this section assume the configuration variables defined
in `src/deploy.lisp` (`*service-user*`, `*home-mountpoint*`,
`*data-mountpoint*`, `*haproxy-vhost-name*`) hold their current values:
service account `todo-app`; home directory `/var/lib/todo-app`; data
directory `/srv/todo-app`; HAProxy virtual host name `todo-app`. Adjust
the commands accordingly if these values change.

**Service status.**

```sh
machinectl shell todo-app@ -- systemctl --user status postgres postgrest
systemctl status haproxy
```

**Logs.** Both containers log through their quadlet-generated units, into
the service account's own journal.

```sh
machinectl shell todo-app@ -- journalctl --user -u postgres -u postgrest -f
```

**Restarting the application containers.** Does not affect ZFS state, the
service account, or the HAProxy configuration.

```sh
machinectl shell todo-app@ -- systemctl --user restart postgres postgrest
```

**Redeployment.** `./todo-app-deploy.ros` is idempotent. Re-execution
applies only the changes Consfigurator's `:check` clauses identify as
missing or altered (updated quadlet content, a modified HAProxy virtual
host) and leaves the remainder unchanged. Redeployment does not
regenerate the database credential; see Password Rotation below for that
procedure.

**Deployment validation**, without redeploying:

```sh
./todo-app-deploy.ros e2e
```

**Database access**, through the running container (peer authentication
inside the container; no credential required for this path):

```sh
machinectl shell todo-app@ -- podman exec -it todo-postgres \
  psql -U postgres -d tododb
```

To read the generated credential itself (required for any external
connection, e.g. through `PGRST_DB_URI`):

```sh
cat /var/lib/todo-app/.env/pgpass
```

**Password rotation.** `db-secret-file` is designed to leave the
credential unchanged across redeployments; rotation is therefore a
deliberate manual procedure, not an automated one:

```sh
machinectl shell todo-app@ -- systemctl --user stop postgres postgrest
NEW_PASS=$(openssl rand -hex 32)
machinectl shell todo-app@ -- \
  podman exec todo-postgres psql -U postgres -c \
  "ALTER USER postgres WITH PASSWORD '$NEW_PASS'"
# Update /var/lib/todo-app/.env/pgpass to match $NEW_PASS in both
# POSTGRES_PASSWORD and PGRST_DB_URI before restarting:
machinectl shell todo-app@ -- systemctl --user start postgres postgrest
```

**Known failure modes.**

- `deploy-app` aborts with "TODO-APP-HOST provisioning reported failed
  properties": the per-property report preceding the error identifies
  the specific failed property and its cause.
- Quadlet changes not taking effect: `systemctl --user daemon-reload`
  must run in the service account's session following any unit file
  modification. A normal deployment performs this automatically via
  `quadlets-activated`; a manual edit does not.
- `loginctl show-user todo-app --property=Linger` is expected to report
  `yes`. If the service account's systemd session does not persist
  across reboots, this setting should be checked first.

**Replication to rsync.net.** Both ZFS datasets warrant off-host
replication: `storage/containers/todo-app` holds the production
database; `storage/users/todo-app` holds the generated credential
required to bring a restored database back into a usable state without
regenerating a password PostgreSQL no longer recognizes.

rsync.net's native `zfs send`/`zfs receive` support requires a
["zfs send capable" account](https://www.rsync.net/products/zfsintro.html),
distinct from the standard rsync-only tier. That account provides SSH
access and an assigned zpool name, discoverable via `zfs list` after
authentication.

Initial full replication, performed once per dataset:

```sh
zfs snapshot storage/users/todo-app@initial
zfs snapshot storage/containers/todo-app@initial

zfs send -w -p storage/users/todo-app@initial | \
  ssh youraccount@youraccount.rsync.net zfs receive -Fu data1/todo-app-users
zfs send -w -p storage/containers/todo-app@initial | \
  ssh youraccount@youraccount.rsync.net zfs receive -Fu data1/todo-app-containers
```

`data1` denotes the pool name rsync.net assigns to the account. `-w`
(raw send) transmits the still-encrypted on-disk blocks without
decryption; the destination never receives, requires, or can use the
encryption key. `-p` carries dataset properties, including `mountpoint`,
so a restore does not require them to be set manually. On the receiving
side, `-u` keeps the remote copy unmounted, consistent with its role as
a backup target rather than a live secondary. `-F` rolls the destination
forward on each incremental and is included from the initial send for
consistency.

Incremental replication, scheduled:

```sh
#!/bin/sh
# /usr/local/sbin/replicate-todo-app.sh
set -eu
HOST="youraccount@youraccount.rsync.net"
TS=$(date +%Y%m%d%H%M%S)

replicate() {
  src="$1"; dst="$2"
  prev=$(zfs list -t snapshot -H -o name -s creation "$src" | tail -1)
  zfs snapshot "${src}@${TS}"
  if [ -n "$prev" ]; then
    zfs send -w -i "$prev" "${src}@${TS}" | ssh "$HOST" zfs receive -Fu "$dst"
  else
    zfs send -w -p "${src}@${TS}" | ssh "$HOST" zfs receive -Fu "$dst"
  fi
}

replicate storage/users/todo-app      data1/todo-app-users
replicate storage/containers/todo-app data1/todo-app-containers
```

Scheduled execution, via systemd timer:

```
# /etc/systemd/system/todo-app-replicate.timer
[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
```

paired with a `.service` unit whose `ExecStart` invokes the script above.

Both datasets are created with AES-256-GCM native ZFS encryption
(`zfs-encryption-key` generates a raw key per dataset at
`/etc/zfs-keys/todo-app-{users,containers}.key`, mode 0600, prior to
`zfs-dataset-mounted` executing `zfs create`), a precondition for the raw
sends described above. A plain `zfs send` of an unlocked encrypted
dataset decrypts the data to construct the stream; only `-w` preserves
encryption end to end, including at rest on rsync.net, not only in
transit over SSH.

The encryption key files are consequently the most critical component to
back up, independent of the ZFS replication described above. Loss of
`/etc/zfs-keys/` after either dataset holds production data renders both
the local and the replicated copy unrecoverable by design. The keys
should be stored outside both encrypted datasets and independent of
rsync.net: a password manager, a second offline copy, or whatever a
given key-management policy requires. This deployment generates the
keys; it does not provide a mechanism for storing a second copy.

**Recovery**, onto a new or repaired host, after
[Requirements](#requirements) are satisfied, the two key files are restored to
`/etc/zfs-keys/` from their independent backup location (not from
rsync.net), and prior to executing `todo-app-deploy.ros`:

```sh
ssh youraccount@youraccount.rsync.net zfs list -t snapshot data1/todo-app-users
ssh youraccount@youraccount.rsync.net zfs list -t snapshot data1/todo-app-containers
# select the snapshot to restore, then:
ssh youraccount@youraccount.rsync.net zfs send -w data1/todo-app-users@SNAP | \
  zfs receive storage/users/todo-app
ssh youraccount@youraccount.rsync.net zfs send -w data1/todo-app-containers@SNAP | \
  zfs receive storage/containers/todo-app
```

`-w` is required for the same reason as replication: the data stored on
rsync.net exists only as a raw, still-encrypted stream, and a
raw-received dataset can only be raw-sent onward; rsync.net holds no key
with which to decrypt it. The result is a dataset present on the local
host in an encrypted, locked state, not yet mounted.

If the original send omitted `-p`, the mountpoints require explicit
configuration so Consfigurator locates them correctly:

```sh
zfs set mountpoint=/var/lib/todo-app storage/users/todo-app
zfs set mountpoint=/srv/todo-app storage/containers/todo-app
```

`./todo-app-deploy.ros` is then executed normally, with the restored key
files already in place. `zfs-dataset-mounted`'s `:check` identifies both
datasets as present but not mounted, the exact state a restore produces,
and its `:apply` loads the key and mounts the dataset rather than
attempting `zfs create` over the restored data. The service account,
linger configuration, quadlets, and HAProxy virtual host are recreated;
the PostgreSQL container starts against the restored data directory
rather than an empty one. `./todo-app-deploy.ros e2e` validates the
result; the `psql` command above confirms the restored data directly.

## Decommission

Destructive, and past the ZFS step, not reversible without a separate
backup. Steps are ordered least-destructive first.

```sh
# 1. Stop the application.
machinectl shell todo-app@ -- systemctl --user stop postgres postgrest

# 2. Remove the quadlet unit files and reload.
rm /var/lib/todo-app/.config/containers/systemd/{postgres.container,postgrest.container,todo-net.network}
machinectl shell todo-app@ -- systemctl --user daemon-reload

# 3. Remove the HAProxy virtual host and reload.
rm /etc/haproxy/conf.d/todo-app.cfg
systemctl reload haproxy

# 4. Disable linger and remove the service account.
loginctl disable-linger todo-app
userdel todo-app

# 5. Destroy the ZFS datasets. Irreversible; removes the database and
#    the generated credential. Confirm a recovery point exists (a
#    pg_dump, a snapshot, a current rsync.net replica) before proceeding.
zfs destroy storage/containers/todo-app
zfs destroy storage/users/todo-app

# 6. Remove the encryption keys. Perform only after step 5 has
#    completed successfully; the keys are inert without the datasets
#    they protect, but should not be removed before the destroy is
#    confirmed.
rm /etc/zfs-keys/todo-app-users.key /etc/zfs-keys/todo-app-containers.key
```

Podman images pulled into the service account's rootless store are
removed with the account in step 4; no separate cleanup is required.

Decommissioning the local deployment does not affect a copy replicated
to rsync.net. That copy requires separate deletion if it is not intended
to outlive the local deployment.

## Layout

`:todo-app` is the umbrella ASDF namespace, defined in
[`todo-app.asd`](todo-app.asd). It has no components of its own; it
exists because ASDF and Quicklisp both resolve a slash-named subsystem
such as `todo-app/deploy` by first locating `todo-app` itself. A future
component (a web application, a CLI) would be added as
`todo-app/<name>` alongside the three below, without requiring any
renaming of existing components.

- [`src/deploy.lisp`](src/deploy.lisp) (`:todo-app/deploy`): the deploy
  logic itself, documented in the `@provisioning`, `@quadlets`, and
  `@database` sections.
- [`t/e2e.lisp`](t/e2e.lisp) (`:todo-app/e2e`): a FiveAM suite validating
  a live deployment. It verifies ZFS mountpoints and encryption, linger,
  quadlet unit state, the HAProxy-fronted URL over HTTP via Dexador, the
  schema and grants via Postmodern, and a full add-toggle-delete cycle
  through the application API.
- [`src/docs.lisp`](src/docs.lisp) (`:todo-app/docs`): the 40ants-doc
  sections, held in a separate system so a production deployment, or a
  `ros dump executable` static binary, does not require 40ants-doc as a
  dependency to provision a stack.

`todo-app-deploy.ros` and `docs.ros` are thin command wrappers: each
loads `todo-app.asd`, resolves its dependencies, and dispatches into the
systems listed above. Neither file contains deployment or documentation
logic of its own.

`@todo-app-deploy` and `@todo-app-e2e` are the two top-level 40ants-doc
sections, rendered by `docs.ros`. They provide the narrative
documentation corresponding to this layout.

## License

BSD 3-Clause. See [LICENSE](LICENSE).

## Build, Test, Distribution

```sh
ros init myapp        # standard project-initialization sequence; not
                      # required here, as this repository already exists
ros install qlot      # once, to obtain the qlot CLI
qlot add <dep>         # adds a dependency to qlfile and pins it in
                      # qlfile.lock; already performed for every
                      # dependency this repository requires, relevant
                      # only when adding a new one
make                  # builds documentation and todo-app-deploy.tgz
make test             # runs ./todo-app-deploy.ros e2e against a live
                      # deployment; requires one to validate
make install          # extracts the built tgz to /
make clean            # removes build/
```

`qlfile.lock` pins every dependency, 109 transitively, to the exact
release resolved by `qlot add`/`qlot install`. `ros dump executable`
produces a working static binary against this project's full dependency
tree, including Consfigurator's native bindings, requiring no additional
setup at invocation time beyond a prior `qlot add` against the project.
