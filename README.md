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
  so it's called out here explicitly.
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

## Playbook: replication and recovery

Both ZFS datasets (`storage/users/todo-app`, home to the generated secret;
`storage/containers/todo-app`, the Postgres data directory) are worth
replicating off-host; the second one is the actual database, the first
one is what lets a restore stand back up without regenerating a password
Postgres no longer recognizes.

rsync.net's native `zfs send`/`zfs receive` support needs a
["zfs send capable" account](https://www.rsync.net/products/zfsintro.html)
specifically, not their ordinary rsync-only tier. Once that's set up you
get SSH access and your own zpool name, found with `zfs list` after
logging in.

**Initial full replication**, once per dataset:

```sh
zfs snapshot storage/users/todo-app@initial
zfs snapshot storage/containers/todo-app@initial

zfs send -w -p storage/users/todo-app@initial | \
  ssh youraccount@youraccount.rsync.net zfs receive -Fu data1/todo-app-users
zfs send -w -p storage/containers/todo-app@initial | \
  ssh youraccount@youraccount.rsync.net zfs receive -Fu data1/todo-app-containers
```

`data1` is a stand-in for whatever pool name rsync.net actually assigns.
`-w` (raw) sends the still-encrypted on-disk blocks exactly as they sit
locally, without ever decrypting them to build the stream; rsync.net
never needs, sees, or can use the encryption key, they just hold opaque
encrypted blocks. `-p` carries the rest of the dataset's properties
(`mountpoint` included) across, so a restore doesn't need them set by
hand. On receive, `-u` keeps the remote copy unmounted, since it's a
backup target, not a second live copy; `-F` rolls the destination
forward to match on every subsequent incremental, so it's included from
the first send too rather than added later.

**Incremental replication**, on a schedule:

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

Run on a timer rather than by hand:

```
# /etc/systemd/system/todo-app-replicate.timer
[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
```

with a matching `.service` unit whose `ExecStart` is the script above.

Both datasets are created with AES-256-GCM native ZFS encryption
(`zfs-encryption-key` generates a raw key per dataset at
`/etc/zfs-keys/todo-app-{users,containers}.key`, mode 0600, before
`zfs-dataset-mounted` ever runs `zfs create`), which is what makes the
raw sends above possible in the first place. Without `-w`, a plain
`zfs send` of an unlocked encrypted dataset decrypts the data to build
the stream; only `-w` keeps it encrypted end to end, at rest on
rsync.net and not just in transit over SSH.

This makes the key files themselves the single most important thing to
get backed up, separately from the ZFS replication above: losing
`/etc/zfs-keys/` after `storage/users/todo-app` or
`storage/containers/todo-app` holds real data means the data (local
*and* replicated to rsync.net) is unrecoverable, full stop, by design.
Back them up somewhere that isn't itself inside either encrypted
dataset and isn't rsync.net alone: a password manager, a second offline
copy, whatever the actual key-management policy calls for. This project
generates the keys; it doesn't solve where a second copy of them lives.

**Recovery**, onto a fresh or repaired host, after
[Requirements](#requirements) are met, the two key files are restored to
`/etc/zfs-keys/` from wherever they're actually backed up (not from
rsync.net; see above), and before running `todo-app-deploy.ros`:

```sh
ssh youraccount@youraccount.rsync.net zfs list -t snapshot data1/todo-app-users
ssh youraccount@youraccount.rsync.net zfs list -t snapshot data1/todo-app-containers
# pick the snapshot to restore from, then:
ssh youraccount@youraccount.rsync.net zfs send -w data1/todo-app-users@SNAP | \
  zfs receive storage/users/todo-app
ssh youraccount@youraccount.rsync.net zfs send -w data1/todo-app-containers@SNAP | \
  zfs receive storage/containers/todo-app
```

`-w` here for the same reason as replication: what's stored on rsync.net
is itself a raw, still-encrypted stream (that's the whole point of
sending it that way), and a dataset that was raw-received can only be
raw-sent onward; there's no key on rsync.net's end to decrypt it with
even if a plain send were attempted. The result is a dataset that
exists locally but is encrypted and locked, not yet mounted.

If the original send didn't carry `-p`, set the mountpoints explicitly
so Consfigurator finds them where it expects:

```sh
zfs set mountpoint=/var/lib/todo-app storage/users/todo-app
zfs set mountpoint=/srv/todo-app storage/containers/todo-app
```

Then run `./todo-app-deploy.ros` as normal, with the restored key files
already in place. `zfs-dataset-mounted`'s `:check` finds both datasets
present but not yet mounted, exactly the state a restore leaves them in,
and its `:apply` loads the key and mounts rather than trying to
`zfs create` over the restored data; the service account, linger,
quadlets, and HAProxy vhost all get recreated fresh, and the Postgres
container starts against the restored data directory rather than an
empty one. Validate with
`./todo-app-deploy.ros e2e`, and spot-check the actual data with the
`psql` command from the Runbook above before considering the restore
done.

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
#    (a pg_dump, a snapshot, a current rsync.net replica) before this
#    step.
zfs destroy storage/containers/todo-app
zfs destroy storage/users/todo-app

# 6. Remove the encryption keys -- only after step 5 actually succeeded;
#    they're useless without the datasets they unlock, but keep them
#    until the destroy is confirmed rather than deleting both at once.
rm /etc/zfs-keys/todo-app-users.key /etc/zfs-keys/todo-app-containers.key
```

Podman images pulled into the service user's rootless store are removed
along with the account in step 4; nothing separate to clean up there.

If a copy of this stack was replicated to rsync.net, decommissioning it
locally doesn't touch that remote copy; delete it there separately if
it's not meant to outlive the local deploy.

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
