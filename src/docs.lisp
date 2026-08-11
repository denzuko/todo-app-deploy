;;;; src/docs.lisp -- todo-app documentation sections
;;;;
;;;; Loaded as the :TODO-APP/DOCS ASDF system, separate from the core
;;;; :TODO-APP/DEPLOY system so a production deploy (or a `ros dump
;;;; executable` static binary) never has to pull in 40ants-doc just to
;;;; provision a stack. docs.ros loads this system and renders it to
;;;; Markdown.

(defpackage :todo-app/docs
  (:use :cl :40ants-doc :todo-app/deploy :todo-app/e2e))

(in-package :todo-app/docs)

(defsection @todo-app-deploy (:title "todo-app-deploy")
  "This deploys a small to-do list app: PostgREST serving PL/pgSQL functions
   straight to the browser, styled with Tailwind and wired up with HTMX and
   Alpine.js, running on rootless Podman quadlets behind HAProxy.

   The interesting part isn't the app. It's that almost none of what gets
   written to disk or sent to the database is a hand-typed string. The
   quadlet units, the SQL schema and grants, and the HTML the database
   itself serves are all built from small in-memory representations and
   then serialized: SXQL for the schema DDL, a couple of local helper
   functions for the GRANT/CREATE ROLE statements SXQL doesn't cover,
   Spinneret for the HTML fragments, and CINIX-WRITE-STRING (a small
   from-scratch serializer, since cl-inix itself only reads INI files) for
   the quadlet units. The idea is the same one SXQL and Spinneret already
   follow: build a structure, then render it, instead of concatenating
   text by hand. The generated SQL itself goes through the same discipline
   one level further out: RUN-MIGRATIONS wraps it in a RAM-MIGRATION served
   by a RAM-PROVIDER and applies it through cl-migratum's real
   postmodern-postgresql driver, using cl-migratum for real rather than as
   a name attached to a driver that never existed.

   System state (ZFS datasets, the service account, quadlet files, the
   HAProxy vhost) is provisioned by TODO-APP-HOST, a Consfigurator DEFHOST
   deploying over a :LOCAL connection. Consfigurator's own property
   library has no ZFS, Podman-quadlet, or HAProxy vocabulary, so those are
   small custom DEFPROPs (ZFS-DATASET-MOUNTED, ROOTLESS-SERVICE-ACCOUNT,
   DB-SECRET-FILE, IMAGES-PULLED, QUADLETS-ACTIVATED) written the same way
   Consfigurator's own bundled properties are: a :DESC, a :CHECK, and an
   :APPLY. Where Consfigurator does have a fitting built-in
   (FILE:HAS-CONTENT for the quadlet and HAProxy files,
   SYSTEMD:LINGERING-ENABLED for the service account, SERVICE:RELOADED
   wrapped in ON-CHANGE for the HAProxy reload), TODO-APP-HOST uses that
   instead of reinventing it.

   DEPLOY-APP runs TODO-APP-HOST and is the place to start reading. Once
   it's deployed, TODO-APP/E2E validates the result."

  (@provisioning section)
  (@quadlets section)
  (@database section)
  (deploy-app function))

(defsection @provisioning (:title "ZFS, the service account, and secrets")
  "Before any container can start, the host needs: two ZFS datasets (one
   for the service account's home, one for Postgres's data directory), a
   rootless system account with systemd linger enabled so its session
   keeps running without anyone logged in, a database password generated
   once and kept around for the life of the data volume, and the two
   container images already sitting in that account's own rootless image
   store. Each of these is a Consfigurator property in TODO-APP-HOST's
   property list, applied in order, each with its own :CHECK so a redeploy
   only touches what's actually missing."
  (*home-mountpoint* variable)
  (*data-mountpoint* variable)
  (*secrets-path* variable)
  (zfs-dataset-mounted function)
  (rootless-service-account function)
  (db-secret-file function)
  (images-pulled function))

(defsection @quadlets (:title "Quadlet units via cinix, applied through Consfigurator")
  "The three systemd quadlet units (the Postgres container, the PostgREST
   container, and the network they share) are each built as a small alist
   of sections and key/value pairs, the same shape cl-inix:read hands back
   when it parses an INI file. CINIX-WRITE-STRING turns that shape back
   into text, and TODO-APP-HOST writes the result with Consfigurator's own
   FILE:HAS-CONTENT rather than a hand-rolled file write. Nothing here
   hand-assembles a unit file as one long string, and nothing here
   reimplements what Consfigurator's file property already does correctly.
   QUADLETS-ACTIVATED reloads the service user's --user systemd daemon and
   restarts both containers once the unit files are in place; Consfigurator
   has no built-in property that targets a different account's --user
   session through `machinectl shell`, so that one stays custom."
  (cinix-write-string function)
  (postgres-quadlet-sections function)
  (postgrest-quadlet-sections function)
  (todo-network-quadlet-sections function)
  (quadlets-activated function)
  (haproxy-vhost-config function))

(defsection @database (:title "Schema, grants, and the HTML the database serves")
  "The migration is built once, as a list of statements, and joined at the
   end. Table and schema creation goes through SXQL. GRANT and CREATE ROLE
   don't have SXQL support, so SQL-GRANT and SQL-CREATE-ROLE fill that gap
   the same way CINIX-WRITE-STRING fills it for quadlets. The two HTML
   fragments PL/pgSQL serves back to the browser (the page shell and the
   per-item row) are Spinneret templates rather than string
   concatenation; the one exception is the to-do checkbox's `checked`
   attribute, which has to stay a raw placeholder because only Postgres,
   not Spinneret, knows at request time whether a given row is done.

   RUN-MIGRATIONS doesn't execute BUILD-MIGRATION-SQL's output directly.
   It wraps that string in a RAM-MIGRATION served by a RAM-PROVIDER, and
   only then does cl-migratum's real postmodern-postgresql driver apply it.
   Nothing lands on disk first; the tradeoff against a file-based provider
   is that there's no discrete up/down file left behind for a SAST or
   attestation step to later scan and sign, only cl-migratum's own applied-
   migration row in the database. NEXT-MIGRATION-ID exists because the
   obvious id source, a 14-digit timestamp, collides when two migrations
   get built in the same wall-clock second, which a fast redeploy can
   genuinely do; deriving the id from the driver's own history instead
   can't collide regardless of timing."
  (generate-index-html-template function)
  (generate-render-todo-html-template function)
  (escape-pg-string-literal function)
  (sql-create-domain function)
  (sql-create-role function)
  (sql-grant function)
  (sql-grant-execute function)
  (build-migration-sql function)
  (ram-migration class)
  (ram-provider class)
  (make-ram-provider function)
  (make-ram-migration function)
  (next-migration-id function)
  (run-migrations function))

(defsection @todo-app-e2e (:title "todo-app-deploy e2e")
  "Post-deploy validation for the stack TODO-APP/DEPLOY:DEPLOY-APP brings up,
   written against the deployed result rather than against
   TODO-APP/DEPLOY's own generator functions; those don't have a separate
   pre-deploy unit-test suite yet. This suite shells out the same way BATS
   would for the systemd/ZFS/file-permission checks, but the runner, the
   assertions, and the HTTP/DB checks are plain Common Lisp: DEXADOR
   against the live HAProxy-fronted URL, POSTMODERN against the live
   schema, no bats anywhere in the loop.

   RUN-E2E runs the whole suite and prints a FiveAM report."
  (*service-user* variable)
  (unit-active-p function)
  (zfs-dataset-mountpoint function)
  (read-db-password function)
  (latest-todo-id function)
  (run-e2e function))

