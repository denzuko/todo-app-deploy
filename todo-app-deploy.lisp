#!/bin/sh
#|-*- mode:lisp -*-|#
#|
exec ros -Q -- $0 "$@"
|#

(in-package :cl-user)

(let ((needed '(:sxql :spinneret :cl-inix :40ants-doc :fiveam :dexador
                :postmodern :cl-migratum
                :cl-migratum.driver.postmodern-postgresql)))
  (unless (every #'ql-dist:find-system (mapcar #'string-downcase needed))
    (ql-dist:install-dist "http://dist.ultralisp.org/" :prompt nil))
  (ql:quickload needed :silent t))

(defpackage :todo-app-deploy
  (:use :cl :sxql)
  (:import-from :spinneret :with-html-string)
  (:import-from :40ants-doc :defsection)
  (:export :*service-user* :*home-mountpoint* :*secrets-path* :*haproxy-fqdn*
           :*home-dataset* :*data-dataset* :deploy))

(in-package :todo-app-deploy)

(setf spinneret:*always-quote* t)

(defparameter *app-name* "todo-app"
  "Name used across ZFS datasets, the service account, and the HAProxy vhost.")
(defparameter *service-user* "todo-app"
  "Rootless system account the quadlets run under; all container ops go
   through `machinectl shell` against this user, never `sudo -u`.")
(defparameter *home-dataset* "storage/users/todo-app")
(defparameter *home-mountpoint* "/var/lib/todo-app"
  "Service account home, backed by *HOME-DATASET*; holds the quadlet units
   and the persisted DB secret.")
(defparameter *data-dataset* "storage/containers/todo-app")
(defparameter *data-mountpoint* "/srv/todo-app"
  "PostgreSQL data directory, backed by *DATA-DATASET*.")
(defparameter *secrets-path* "/var/lib/todo-app/.env/pgpass"
  "Generated once and left alone on redeploy — the postgres data volume's
   password can't be rotated out from under it on every run.")
(defparameter *haproxy-vhost-name* "todo-app")
(defparameter *haproxy-fqdn* "todo.dapla.net")

(defun write-file-string (path content)
  "Write CONTENT to PATH, creating parent directories as needed. Consfigurator
   is a deployment tool you run against a host, not a library to link into a
   general-purpose script — it doesn't belong in this image, and its native
   groveled bindings (ACL, POSIX capabilities) are exactly the kind of
   fragile system-header dependency that got it rejected from dps-meta for
   the same reason. The properties below are the same idempotent,
   sequentially-applied checks Consfigurator's DSL would express, just as
   plain functions calling UIOP directly — which is what they were already
   doing underneath every `:apply` clause."
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output
                            :if-exists :supersede
                            :if-does-not-exist :create)
    (write-string content out)))

(defun zfs-dataset-mounted (dataset mountpoint)
  "Create DATASET with the given MOUNTPOINT if it doesn't already exist.
   UIOP:RUN-PROGRAM's exit code is its third return value when :OUTPUT is
   NIL, not its primary one — NTH-VALUE 2 here, not a bare ZEROP."
  (unless (zerop (nth-value 2
                   (uiop:run-program
                    (format nil "zfs list -H -o name ~A" dataset)
                    :output nil :error-output nil :ignore-error-status t)))
    (uiop:run-program (format nil "zfs create -o mountpoint=~A ~A"
                               mountpoint dataset)
                       :output t)))

(defun todo-app-home-dataset ()
  "Provision *HOME-DATASET*, ahead of the service account that will live on it."
  (zfs-dataset-mounted *home-dataset* *home-mountpoint*))

(defun todo-app-data-dataset ()
  "Provision *DATA-DATASET* for the postgres container's data directory."
  (zfs-dataset-mounted *data-dataset* *data-mountpoint*))

(defun todo-app-service-account ()
  "Create the rootless *SERVICE-USER* system account with its home on the
   ZFS dataset, and enable + verify systemd linger so its user session
   survives without an active login."
  (unless (zerop (nth-value 2
                   (uiop:run-program
                    (format nil "id ~A" *service-user*)
                    :output nil :error-output nil :ignore-error-status t)))
    (uiop:run-program
     (format nil "useradd --system --no-create-home --home-dir ~A ~A"
             *home-mountpoint* *service-user*)
     :output t))
  (uiop:run-program (format nil "loginctl enable-linger ~A" *service-user*)
                     :output t)
  (let ((linger (uiop:run-program
                 (format nil "loginctl show-user ~A --property=Linger"
                         *service-user*)
                 :output '(:string :stripped t))))
    (unless (string= linger "Linger=yes")
      (error "Linger not enabled for ~A after loginctl call (got ~S)"
             *service-user* linger))))

(defun todo-app-db-secret ()
  "Generate the postgres password once via `openssl rand -hex 32` and persist
   it under the ZFS-backed service account home (mode 0600), rather than the
   /dev/shm mktemp namespace used for one-shot bootstrap secrets elsewhere —
   this one has to survive container restarts across the data volume's
   lifetime."
  (ensure-directories-exist (format nil "~A/.env/" *home-mountpoint*))
  (unless (uiop:file-exists-p *secrets-path*)
    (let ((pass (string-trim '(#\Newline)
                  (uiop:run-program "openssl rand -hex 32"
                                     :output '(:string :stripped t)))))
      (write-file-string *secrets-path*
        (format nil "POSTGRES_PASSWORD=~A~%PGRST_DB_URI=postgres://postgres:~A@todo-postgres:5432/tododb~%"
                pass pass))
      (uiop:run-program (format nil "chmod 0600 ~A" *secrets-path*) :output t)
      (uiop:run-program (format nil "chown ~A:~A ~A"
                                 *service-user* *service-user* *secrets-path*)
                         :output t))))

(defun todo-app-images-pulled ()
  "Pull both container images into the rootless store via `machinectl shell`,
   since the store belongs to the service user's session, not the deploying
   user's."
  (dolist (image '("docker.io/library/postgres:16-alpine"
                    "docker.io/postgrest/postgrest:v12.0.2"))
    (uiop:run-program
     (format nil "machinectl shell ~A@ -- podman pull ~A" *service-user* image)
     :output t)))

(defun cinix-write-string (sections)
  "Serialize an alist of (section-name . ((key . value) ...)) — the same
   shape cl-inix:read produces from an INI file — into INI/systemd unit-file
   text. cl-inix itself is read-only (dps-meta uses it in-process to parse
   .git/config in place of a uiop:run-program fork), so this is the write-side
   counterpart, playing the role for the quadlet AST that SXQL's `yield`
   plays for SQL and Spinneret's `with-html-string` plays for HTML. Keys may
   repeat within a section — e.g. multiple Environment= lines — since each
   section is an ordered list of conses, not a hash."
  (with-output-to-string (s)
    (dolist (section sections)
      (format s "[~A]~%" (car section))
      (dolist (kv (cdr section))
        (format s "~A=~A~%" (car kv) (cdr kv)))
      (format s "~%"))))

(defun postgres-quadlet-sections ()
  "Cinix AST for postgres.container: %h EnvironmentFile for the generated
   secret, ZFS-backed volume, WantedBy=default.target."
  `(("Unit" . (("Description" . "PostgreSQL Database Container")))
    ("Container" . (("Image" . "docker.io/library/postgres:16-alpine")
                     ("ContainerName" . "todo-postgres")
                     ("EnvironmentFile" . "%h/.env/pgpass")
                     ("Environment" . "POSTGRES_DB=tododb")
                     ("Environment" . "POSTGRES_USER=postgres")
                     ("Volume" . ,(format nil "~A:/var/lib/postgresql/data"
                                           *data-mountpoint*))
                     ("Network" . "todo-net.network")))
    ("Service" . (("Restart" . "always")))
    ("Install" . (("WantedBy" . "default.target")))))

(defun postgrest-quadlet-sections ()
  "Cinix AST for postgrest.container: binds to 127.0.0.1 only, since HAProxy
   owns the public interface and terminates TLS."
  `(("Unit" . (("Description" . "PostgREST API Server")
               ("After" . "postgres.service")))
    ("Container" . (("Image" . "docker.io/postgrest/postgrest:v12.0.2")
                     ("ContainerName" . "todo-postgrest")
                     ("EnvironmentFile" . "%h/.env/pgpass")
                     ("Environment" . "PGRST_DB_SCHEMA=api")
                     ("Environment" . "PGRST_DB_ANON_ROLE=web_anon")
                     ("Environment" . "PGRST_MEDIA_TYPES_CUSTOM=text/html")
                     ("PublishPort" . "127.0.0.1:3000:3000")
                     ("Network" . "todo-net.network")))
    ("Service" . (("Restart" . "always")))
    ("Install" . (("WantedBy" . "default.target")))))

(defun todo-network-quadlet-sections ()
  "Cinix AST for todo-net.network."
  '(("Network" . (("NetworkName" . "todo-net")))))

(defun postgres-quadlet ()
  "Write postgres.container from POSTGRES-QUADLET-SECTIONS via cinix-write-string."
  (let ((unit-file (format nil "~A/.config/containers/systemd/postgres.container"
                            *home-mountpoint*)))
    (write-file-string unit-file (cinix-write-string (postgres-quadlet-sections)))))

(defun postgrest-quadlet ()
  "Write postgrest.container from POSTGREST-QUADLET-SECTIONS via cinix-write-string."
  (let ((unit-file (format nil "~A/.config/containers/systemd/postgrest.container"
                            *home-mountpoint*)))
    (write-file-string unit-file (cinix-write-string (postgrest-quadlet-sections)))))

(defun todo-network-quadlet ()
  "Write todo-net.network from TODO-NETWORK-QUADLET-SECTIONS via cinix-write-string."
  (let ((unit-file (format nil "~A/.config/containers/systemd/todo-net.network"
                            *home-mountpoint*)))
    (write-file-string unit-file (cinix-write-string (todo-network-quadlet-sections)))))

(defun todo-app-haproxy-vhost ()
  "Terminate TLS for *HAPROXY-FQDN* and backend to PostgREST on loopback;
   containers never see the public interface directly."
  (write-file-string
   (format nil "/etc/haproxy/conf.d/~A.cfg" *haproxy-vhost-name*)
   (format nil "frontend ~A_fe
  bind *:443 ssl crt /etc/haproxy/certs/dapla_stack.pem
  acl host_~A hdr(host) -i ~A
  use_backend ~A_be if host_~A

backend ~A_be
  server todo-postgrest 127.0.0.1:3000 check
"
           *haproxy-vhost-name* *haproxy-vhost-name* *haproxy-fqdn*
           *haproxy-vhost-name* *haproxy-vhost-name* *haproxy-vhost-name*))
  (uiop:run-program "systemctl reload haproxy" :output t))

(defun generate-index-html-template ()
  "Generate the index page shell via Spinneret. The `%s` inside the todo-list
   is PostgreSQL's own format() substitution syntax, not Lisp's `~A` — this
   string is only ever read by PostgreSQL's format() at request time, after
   Lisp's own format has already finished substituting the whole template
   into the SQL body. The Add button's Alpine `:disabled=\"expr\"` binding
   needs the attribute name pipe-quoted as :|:disabled| — Spinneret treats
   the plain keyword :DISABLED as HTML5's native boolean attribute of the
   same name, and a value passed there collapses to a bare `disabled`,
   silently dropping the whole Alpine binding with no warning that it
   happened. SPINNERET:*ALWAYS-QUOTE* is set at the top of this file, before
   this function is compiled, which is what keeps that attribute's value —
   and every attribute value in GENERATE-RENDER-TODO-HTML-TEMPLATE below —
   properly quoted even though the literal placeholder text Spinneret sees
   at generation time never itself contains whitespace."
  (spinneret:with-html-string
    (:doctype)
    (:html :lang "en"
      (:head
        (:meta :charset "UTF-8")
        (:meta :name "viewport" :content "width=device-width, initial-scale=1.0")
        (:title "PostgREST + HTMX + Alpine.js")
        (:script :src "https://unpkg.com/htmx.org@1.9.10")
        (:script :defer t :src "https://unpkg.com/alpinejs@3.x.x/dist/cdn.min.js")
        (:script :src "https://cdn.tailwindcss.com"))
      (:body :class "bg-gray-100 min-h-screen py-10 px-4"
        (:div :class "max-w-md mx-auto bg-white rounded-xl shadow-md p-6" :x-data "{ taskInput: '' }"
          (:h1 :class "text-2xl font-bold text-gray-900 mb-6 text-center" "To-Do List")
          (:form :hx-post "/rpc/add_todo"
                 :hx-target "#todo-list"
                 :hx-swap "afterbegin"
                 :|@htmx:after-request| "taskInput = ''"
                 :class "flex gap-2 mb-6"
            (:input :type "text"
                    :name "task"
                    :x-model "taskInput"
                    :placeholder "What needs to be done?"
                    :required t
                    :class "flex-1 px-4 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-indigo-500")
            (:button :type "submit"
                     :|:disabled| "!taskInput.trim()"
                     :class "px-4 py-2 bg-indigo-600 text-white rounded-lg hover:bg-indigo-700 disabled:opacity-50 transition"
                     "Add"))
          (:ul :id "todo-list" :class "space-y-3"
            (:raw "%s")))))))

(defun generate-render-todo-html-template ()
  "Generate the per-todo <li> fragment via Spinneret. The checkbox's
   `checked` state is the one piece of this template Spinneret can't
   express declaratively: every other attribute here is a plain string
   value, always quoted correctly thanks to *ALWAYS-QUOTE*, but `checked`
   is an HTML5 boolean attribute whose presence Spinneret can only decide
   from a Lisp-level true/false value at generation time — and whether a
   given row is done isn't known until PostgreSQL's format() resolves it at
   request time. That's a genuine boundary between the two templating
   systems rather than anything Spinneret does wrong, so that one input
   stays a hand-written :RAW placeholder; every other element here is
   ordinary Spinneret markup. Placeholder order: li id, checked, hx-patch
   id, hx-target id, span class, span content, hx-delete id, hx-target id —
   eight `%s` total, matching the eight arguments render_todo passes to
   PostgreSQL's format()."
  (spinneret:with-html-string
    (:li :id "todo-%s"
         :class "flex items-center justify-between p-3 bg-gray-50 rounded border border-gray-200"
      (:div :class "flex items-center gap-3"
        (:raw "<input type=\"checkbox\" %s hx-patch=\"/rpc/toggle_todo?id=%s\" hx-target=\"#todo-%s\" hx-swap=\"outerHTML\" class=\"h-5 w-5 text-indigo-600 rounded focus:ring-indigo-500 cursor-pointer\">")
        (:span :class "%s" "%s"))
      (:button :hx-delete "/rpc/delete_todo?id=%s"
               :hx-target "#todo-%s"
               :hx-swap "outerHTML text"
               :class "text-red-500 hover:text-red-700 font-medium text-sm"
        "Delete"))))

(defun escape-pg-string-literal (text)
  "Double any single quotes in TEXT so it can be embedded as a PostgreSQL
   single-quoted string literal."
  (uiop:frob-substrings text '("'") "''"))

(defun sql-create-schema (name)
  "Emit a CREATE SCHEMA IF NOT EXISTS statement. SXQL has no schema-DDL
   vocabulary at all — CREATE-SCHEMA isn't a function it exports — so this
   is the same kind of small structured builder as SQL-CREATE-ROLE and
   SQL-GRANT below it, not a hand-typed literal wrapped in an unrelated
   function name."
  (format nil "CREATE SCHEMA IF NOT EXISTS ~A" name))

(defun sql-create-domain (schema name base-type)
  "Emit an idempotent domain-creation statement, for the same reason
   SQL-CREATE-ROLE needs one: PostgreSQL's CREATE DOMAIN has no IF NOT
   EXISTS clause, and CREATE SCHEMA IF NOT EXISTS leaves an existing
   schema's contents — including this domain — untouched on redeploy, so
   a bare CREATE DOMAIN fails with a duplicate-object error on every
   redeploy after the first. Domains are stored as types, so the existence
   check joins pg_type to pg_namespace rather than querying a dedicated
   pg_domains catalog."
  (format nil "DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_catalog.pg_type t JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace WHERE t.typname = '~A' AND n.nspname = '~A') THEN CREATE DOMAIN ~A.~A AS ~A; END IF; END $$"
          name schema schema name base-type))

(defun sql-create-role (name)
  "Emit an idempotent role-creation statement. Unlike CREATE SCHEMA and
   CREATE TABLE, PostgreSQL's CREATE ROLE has no IF NOT EXISTS clause at
   all, and roles live at the cluster level, not the database level — a
   dropped-and-recreated database doesn't drop the role with it. Wrapping
   it in a DO block that checks pg_roles first is the standard idiom for
   making it safe to run on every deploy, which this migration is designed
   to be; a bare CREATE ROLE would fail with a duplicate-object error on
   every redeploy after the first, against the very persistent data volume
   this whole stack is built to keep."
  (format nil "DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '~A') THEN CREATE ROLE ~A NOLOGIN; END IF; END $$"
          name name))

(defun sql-grant (privileges on to)
  "Emit a GRANT <privileges> ON <on> TO <to> statement from a list of
   privilege strings."
  (format nil "GRANT ~{~A~^, ~} ON ~A TO ~A" privileges on to))

(defun sql-grant-execute (function-signature to)
  "Emit a GRANT EXECUTE ON FUNCTION <function-signature> TO <to> statement."
  (format nil "GRANT EXECUTE ON FUNCTION ~A TO ~A" function-signature to))

(defun build-migration-sql ()
  "Assemble the entire DB migration schema and PL/pgSQL procedures using
   SXQL for DDL, the SQL-* helpers for DCL, and Spinneret for the embedded
   HTML fragments."
  (let ((index-html-template (generate-index-html-template))
        (render-todo-html-template (generate-render-todo-html-template)))
    (format nil "~{~A;~%~^--;;~%~}"
     (list
      (sql-create-schema "api")

      (sql-create-domain "api" "html" "text")

      (yield
       (create-table (:api.todos :if-not-exists t)
         ((id :type 'serial :primary-key t)
          (task :type 'text :not-null t)
          (done :type 'boolean :not-null t :default :false)
          (created_at :type 'timestamptz :default (make-sql-symbol "NOW()")))))

      (sql-create-role "web_anon")
      (sql-grant '("USAGE") "SCHEMA api" "web_anon")
      (sql-grant '("SELECT" "INSERT" "UPDATE" "DELETE") "api.todos" "web_anon")
      (sql-grant '("USAGE" "SELECT") "ALL SEQUENCES IN SCHEMA api" "web_anon")

      (format nil "CREATE OR REPLACE FUNCTION api.render_todo(p_todo api.todos)
RETURNS api.html AS $$
BEGIN
    RETURN format('~A',
        p_todo.id,
        CASE WHEN p_todo.done THEN 'checked' ELSE '' END,
        p_todo.id,
        p_todo.id,
        CASE WHEN p_todo.done THEN 'line-through text-gray-400' ELSE 'text-gray-800' END,
        p_todo.task,
        p_todo.id,
        p_todo.id
    );
END;
$$ LANGUAGE plpgsql STABLE"
              (escape-pg-string-literal render-todo-html-template))

      (format nil "CREATE OR REPLACE FUNCTION api.index()
RETURNS api.html AS $$
DECLARE
    v_todo_list text := '';
    v_rec record;
BEGIN
    FOR v_rec IN SELECT * FROM api.todos ORDER BY id DESC LOOP
        v_todo_list := v_todo_list || api.render_todo(v_rec);
    END LOOP;

    RETURN format('~A', v_todo_list);
END;
$$ LANGUAGE plpgsql STABLE"
              (escape-pg-string-literal index-html-template))

      "CREATE OR REPLACE FUNCTION api.add_todo(task text)
RETURNS api.html AS $$
DECLARE
    v_new_todo api.todos;
BEGIN
    INSERT INTO api.todos (task) VALUES (task) RETURNING * INTO v_new_todo;
    RETURN api.render_todo(v_new_todo);
END;
$$ LANGUAGE plpgsql VOLATILE"

      "CREATE OR REPLACE FUNCTION api.toggle_todo(id integer)
RETURNS api.html AS $$
DECLARE
    v_todo api.todos;
BEGIN
    UPDATE api.todos SET done = NOT done WHERE api.todos.id = toggle_todo.id RETURNING * INTO v_todo;
    RETURN api.render_todo(v_todo);
END;
$$ LANGUAGE plpgsql VOLATILE"

      "CREATE OR REPLACE FUNCTION api.delete_todo(id integer)
RETURNS api.html AS $$
BEGIN
    DELETE FROM api.todos WHERE api.todos.id = delete_todo.id;
    RETURN '';
END;
$$ LANGUAGE plpgsql VOLATILE"

      (sql-grant-execute "api.index()" "web_anon")
      (sql-grant-execute "api.add_todo(text)" "web_anon")
      (sql-grant-execute "api.toggle_todo(integer)" "web_anon")
      (sql-grant-execute "api.delete_todo(integer)" "web_anon")))))

(defclass ram-migration (cl-migratum.core:base-migration)
  ((up-content :initarg :up-content :initform "" :reader migration-up-content)
   (down-content :initarg :down-content :initform "" :reader migration-down-content))
  (:documentation "A CL-MIGRATUM migration whose SQL lives in a Lisp string
   instead of an up/down file pair on disk."))

(defmethod cl-migratum.core:migration-load ((direction (eql :up)) (migration ram-migration))
  (migration-up-content migration))

(defmethod cl-migratum.core:migration-load ((direction (eql :down)) (migration ram-migration))
  (migration-down-content migration))

(defclass ram-provider (cl-migratum.core:base-provider)
  ((migrations :initarg :migrations :initform nil :accessor provider-migrations))
  (:documentation "A CL-MIGRATUM provider whose migration list is supplied
   directly rather than discovered by scanning a directory."))

(defmethod cl-migratum.core:provider-list-migrations ((provider ram-provider) &key)
  (provider-migrations provider))

(defun make-ram-provider (migrations)
  (make-instance 'ram-provider :name "ram" :initialized t :migrations migrations))

(defun make-ram-migration (id description up-sql
                            &optional (down-sql "-- desired-state migration; no reversible down script"))
  "BUILD-MIGRATION-SQL is idempotent (CREATE OR REPLACE, IF NOT EXISTS
   throughout), so re-applying the current desired state as a new migration
   each deploy is safe; there's no reversible down script for a full-state
   reapplication, so the down side is a documented no-op rather than a
   destructive DROP SCHEMA that would take user data with it. Trading the
   local-path provider for this one drops the file a SAST/attestation step
   could scan and sign — nothing here writes the generated SQL to disk."
  (make-instance 'ram-migration
                 :id id :description description :kind :sql :applied nil
                 :up-content up-sql :down-content down-sql))

(defun next-migration-id (driver)
  "A monotonic id derived from DRIVER's own applied-migration history rather
   than the clock. A 14-digit YYYYMMDDHHMMSS timestamp — the id scheme
   CL-MIGRATUM.UTIL:MAKE-MIGRATION-ID itself uses — collides when two
   migrations are built inside the same wall-clock second, which a fast
   redeploy (or two e2e runs back to back) can genuinely do; reading the
   driver's own latest id back and incrementing it can't collide regardless
   of timing."
  (let ((latest (cl-migratum.core:latest-migration driver)))
    (if latest (1+ (cl-migratum.core:migration-id latest)) 1)))

(defun run-migrations (database user password host)
  "Build a RAM-PROVIDER holding one RAM-MIGRATION — the current
   BUILD-MIGRATION-SQL output — and apply it via cl-migratum's real
   postmodern-postgresql driver. cl-migratum.driver.pg, assumed for a while
   early on, never existed; the real system is
   CL-MIGRATUM.DRIVER.POSTMODERN-POSTGRESQL. A short-lived probe driver
   reads the applied-migration history first so NEXT-MIGRATION-ID has
   something to increment before the real driver connects and applies."
  (let* ((probe-provider (make-ram-provider nil))
         (probe-driver (cl-migratum.driver.postmodern-postgresql:make-driver
                        probe-provider
                        (list :database database :user-name user
                              :password password :host host))))
    (cl-migratum.core:driver-init probe-driver)
    (let ((id (next-migration-id probe-driver)))
      (cl-migratum.core:driver-shutdown probe-driver)
      (let* ((migration (make-ram-migration id "todo_app_schema" (build-migration-sql)))
             (provider (make-ram-provider (list migration)))
             (driver (cl-migratum.driver.postmodern-postgresql:make-driver
                      provider
                      (list :database database :user-name user
                            :password password :host host))))
        (cl-migratum.core:driver-init driver)
        (cl-migratum.core:apply-pending driver)
        (cl-migratum.core:driver-shutdown driver)))))

(defun deploy ()
  "Execute system deployment and database initialization in sequence.
   Datasets before the account that lives on them, account+linger before
   secrets/images/quadlets, HAProxy last since it depends on the backend
   already listening."
  (format t "~&--> Provisioning ZFS datasets, service account, secrets, quadlets, and HAProxy vhost...~%")
  (todo-app-home-dataset)
  (todo-app-data-dataset)
  (todo-app-service-account)
  (todo-app-db-secret)
  (todo-app-images-pulled)
  (todo-network-quadlet)
  (postgres-quadlet)
  (postgrest-quadlet)
  (todo-app-haproxy-vhost)

  (format t "~&--> Reloading systemd user daemon in ~A's session (via machinectl)...~%" *service-user*)
  (uiop:run-program
   (format nil "machinectl shell ~A@ -- systemctl --user daemon-reload" *service-user*)
   :output t)
  (uiop:run-program
   (format nil "machinectl shell ~A@ -- systemctl --user restart postgres postgrest"
           *service-user*)
   :output t)

  (format t "~&--> Waiting for PostgreSQL readiness...~%")
  (sleep 3)

  (format t "~&--> Writing and applying database migrations built with SXQL & Spinneret...~%")
  (let* ((secrets (uiop:read-file-string *secrets-path*))
         (pass (second (uiop:split-string
                         (first (remove-if-not
                                 (lambda (l) (uiop:string-prefix-p "POSTGRES_PASSWORD=" l))
                                 (uiop:split-string secrets :separator '(#\Newline))))
                         :separator '(#\=)))))
    (run-migrations "tododb" "postgres" pass "localhost"))

  (format t "~&--> Application ready! Visit https://~A/rpc/index~%" *haproxy-fqdn*))

(defsection @todo-app-deploy (:title "todo-app-deploy")
  "This deploys a small to-do list app: PostgREST serving PL/pgSQL functions
   straight to the browser, styled with Tailwind and wired up with HTMX and
   Alpine.js, running on rootless Podman quadlets behind HAProxy.

   The interesting part isn't the app — it's that almost none of what gets
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
   one level further out: RUN-MIGRATIONS writes it to a timestamped file
   pair before applying it, rather than running a string straight from
   memory, using cl-migratum for real rather than as a name attached to a
   driver that never existed.

   System state — ZFS datasets, the service account, quadlet files, the
   HAProxy vhost — is asserted with plain idempotent functions calling
   UIOP directly, not a deployment tool linked into this image. Consfigurator
   is meant to be run against a host, not embedded as a library; its
   groveled native bindings are exactly the fragile dependency this stays
   away from.

   DEPLOY runs the whole thing in order, and is the place to start reading.
   Once it's deployed, TODO-APP-DEPLOY.E2E validates the result."

  (@provisioning section)
  (@quadlets section)
  (@database section)
  (deploy function))

(defsection @provisioning (:title "ZFS, the service account, and secrets")
  "Before any container can start, the host needs: two ZFS datasets (one
   for the service account's home, one for Postgres's data directory), a
   rootless system account with systemd linger enabled so its session
   keeps running without anyone logged in, a database password generated
   once and kept around for the life of the data volume, and the two
   container images already sitting in that account's own rootless image
   store. Each of these is a plain function DEPLOY calls in sequence, doing
   its own idempotence check before touching anything."
  (*home-mountpoint* variable)
  (*data-mountpoint* variable)
  (*secrets-path* variable)
  (write-file-string function)
  (zfs-dataset-mounted function)
  (todo-app-home-dataset function)
  (todo-app-data-dataset function)
  (todo-app-service-account function)
  (todo-app-db-secret function)
  (todo-app-images-pulled function))

(defsection @quadlets (:title "Quadlet units via cinix")
  "The three systemd quadlet units — the Postgres container, the PostgREST
   container, and the network they share — are each built as a small alist
   of sections and key/value pairs, the same shape cl-inix:read hands back
   when it parses an INI file. CINIX-WRITE-STRING turns that shape back
   into text. Nothing here hand-assembles a unit file as one long string."
  (cinix-write-string function)
  (postgres-quadlet-sections function)
  (postgrest-quadlet-sections function)
  (todo-network-quadlet-sections function)
  (postgres-quadlet function)
  (postgrest-quadlet function)
  (todo-network-quadlet function)
  (todo-app-haproxy-vhost function))

(defsection @database (:title "Schema, grants, and the HTML the database serves")
  "The migration is built once, as a list of statements, and joined at the
   end. Table and schema creation goes through SXQL. GRANT and CREATE ROLE
   don't have SXQL support, so SQL-GRANT and SQL-CREATE-ROLE fill that gap
   the same way CINIX-WRITE-STRING fills it for quadlets. The two HTML
   fragments PL/pgSQL serves back to the browser — the page shell and the
   per-item row — are Spinneret templates rather than string
   concatenation; the one exception is the to-do checkbox's `checked`
   attribute, which has to stay a raw placeholder because only Postgres,
   not Spinneret, knows at request time whether a given row is done.

   RUN-MIGRATIONS doesn't execute BUILD-MIGRATION-SQL's output directly —
   it wraps that string in a RAM-MIGRATION served by a RAM-PROVIDER, and
   only then does cl-migratum's real postmodern-postgresql driver apply it.
   Nothing lands on disk first; the tradeoff against a file-based provider
   is that there's no discrete up/down file left behind for a SAST or
   attestation step to later scan and sign, only cl-migratum's own applied-
   migration row in the database. NEXT-MIGRATION-ID exists because the
   obvious id source — a 14-digit timestamp — collides when two migrations
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

(defpackage :todo-app-deploy.e2e
  (:use :cl :fiveam)
  (:import-from :todo-app-deploy
                :*service-user* :*home-mountpoint* :*secrets-path*
                :*haproxy-fqdn* :*home-dataset* :*data-dataset*)
  (:import-from :40ants-doc :defsection)
  (:export :run-e2e))

(in-package :todo-app-deploy.e2e)

(defun machinectl-shell (command)
  "Run COMMAND inside *SERVICE-USER*'s session via machinectl shell and
   return its trimmed stdout."
  (string-trim '(#\Newline #\Space)
    (uiop:run-program
     (format nil "machinectl shell ~A@ -- ~A" *service-user* command)
     :output '(:string :stripped t)
     :ignore-error-status t)))

(defun unit-active-p (unit)
  "True if UNIT is active in *SERVICE-USER*'s user-scope systemd."
  (string= (machinectl-shell (format nil "systemctl --user is-active ~A" unit))
           "active"))

(defun zfs-dataset-mountpoint (dataset)
  "The mountpoint ZFS reports for DATASET, or NIL if it doesn't exist."
  (multiple-value-bind (output error-output status)
      (uiop:run-program (format nil "zfs get -H -o value mountpoint ~A" dataset)
                         :output '(:string :stripped t)
                         :ignore-error-status t)
    (declare (ignore error-output))
    (and (zerop status) output)))

(defun file-mode (path)
  "PATH's permission bits as an octal string, e.g. \"600\"."
  (string-trim '(#\Newline)
    (uiop:run-program (format nil "stat -c %a ~A" path)
                       :output '(:string :stripped t))))

(defun read-db-password ()
  "Read POSTGRES_PASSWORD back out of the generated secret file."
  (let* ((contents (uiop:read-file-string *secrets-path*))
         (line (find "POSTGRES_PASSWORD=" (uiop:split-string contents :separator '(#\Newline))
                     :test #'uiop:string-prefix-p)))
    (second (uiop:split-string line :separator '(#\=)))))

(def-suite todo-app-e2e
  :description "Post-deploy validation for the todo-app quadlet stack.")

(in-suite todo-app-e2e)

(test zfs-datasets-mounted
  "Both datasets exist and are mounted where TODO-APP-DEPLOY:DEPLOY put them."
  (is (equal *home-mountpoint* (zfs-dataset-mountpoint *home-dataset*)))
  (is (equal "/srv/todo-app" (zfs-dataset-mountpoint *data-dataset*))))

(test service-account-lingering
  "The rootless service account exists and has linger enabled."
  (is (zerop (nth-value 2 (uiop:run-program (format nil "id ~A" *service-user*)
                                             :ignore-error-status t))))
  (is (search "Linger=yes"
              (uiop:run-program
               (format nil "loginctl show-user ~A --property=Linger" *service-user*)
               :output '(:string :stripped t)))))

(test secret-file-permissions
  "The generated DB password is present, owned by the service account, mode 0600."
  (is (uiop:file-exists-p *secrets-path*))
  (is (equal "600" (file-mode *secrets-path*)))
  (is (plusp (length (read-db-password)))))

(test quadlets-active
  "postgres.service and postgrest.service are both active under the
   service account's user-scope systemd."
  (is-true (unit-active-p "postgres"))
  (is-true (unit-active-p "postgrest")))

(test haproxy-vhost-routes
  "The public HAProxy-fronted URL serves the to-do app over TLS."
  (multiple-value-bind (body status)
      (dex:get (format nil "https://~A/rpc/index" *haproxy-fqdn*))
    (is (= 200 status))
    (is (search "To-Do List" body))))

(test schema-and-grants
  "api.todos exists and web_anon has exactly the privileges TODO-APP-DEPLOY granted."
  (postmodern:with-connection (list "tododb" "postgres" (read-db-password) "localhost")
    (is-true (postmodern:query
              "select exists (select 1 from information_schema.tables
                 where table_schema = 'api' and table_name = 'todos')"
              :single))
    (is (equal '("SELECT" "INSERT" "UPDATE" "DELETE")
               (sort (postmodern:query
                      "select privilege_type from information_schema.role_table_grants
                        where table_schema = 'api' and table_name = 'todos'
                          and grantee = 'web_anon'"
                      :column)
                     #'string<)))))

(defun latest-todo-id (task)
  "The id Postgres assigned to the most recently inserted row matching TASK.
   Used to recover the id after an HTTP add_todo call rather than parsing it
   back out of the returned HTML fragment."
  (postmodern:with-connection (list "tododb" "postgres" (read-db-password) "localhost")
    (postmodern:query "select id from api.todos where task = $1 order by id desc limit 1"
                       task :single)))

(test add-toggle-delete-round-trip
  "A todo created through the live API can be toggled and deleted through it."
  (let* ((base (format nil "https://~A/rpc" *haproxy-fqdn*))
         (task (format nil "e2e round trip ~A" (get-universal-time)))
         (created (dex:post (format nil "~A/add_todo" base)
                             :content (list (cons "task" task))))
         (id (latest-todo-id task)))
    (is (search task created))
    (is (integerp id))
    (multiple-value-bind (toggled toggled-status)
        (dex:patch (format nil "~A/toggle_todo?id=~A" base id))
      (is (= 200 toggled-status))
      (is (search "line-through" toggled)))
    (multiple-value-bind (deleted-body deleted-status)
        (dex:delete (format nil "~A/delete_todo?id=~A" base id))
      (declare (ignore deleted-body))
      (is (= 200 deleted-status)))))

(defun run-e2e ()
  "Run the full TODO-APP-E2E suite and print a FiveAM report."
  (run! 'todo-app-e2e))

(defsection @todo-app-e2e (:title "todo-app-deploy e2e")
  "Post-deploy validation for the stack TODO-APP-DEPLOY:DEPLOY brings up,
   written against the deployed result rather than against its own
   generator functions — those get their own pre-deploy FiveAM specs
   separately. This suite shells out the same way BATS would for the
   systemd/ZFS/file-permission checks, but the runner, the assertions, and
   the HTTP/DB checks are plain Common Lisp: DEXADOR against the live
   HAProxy-fronted URL, POSTMODERN against the live schema, no bats
   anywhere in the loop.

   RUN-E2E runs the whole suite and prints a FiveAM report."
  (*service-user* variable)
  (unit-active-p function)
  (zfs-dataset-mountpoint function)
  (read-db-password function)
  (latest-todo-id function)
  (run-e2e function))

(in-package :cl-user)

(defun main (&rest argv)
  "Entry point for `./todo-app-deploy.lisp [e2e]`. Roswell calls this
   automatically after loading the script — it isn't invoked explicitly
   here — so this has to be CL-USER::MAIN specifically, taking &REST ARGV,
   per Roswell's own script convention; TODO-APP-DEPLOY:DEPLOY underneath
   is a distinct, differently-shaped, differently-named function this
   dispatches to — differently-named so there's only ever one thing in
   this file called MAIN. With no arguments, deploys the stack. With
   `e2e`, runs TODO-APP-DEPLOY.E2E:RUN-E2E against whatever's already
   deployed instead."
  (unless (member "e2e" argv :test #'string=)
    (return-from main (todo-app-deploy:deploy)))
  (todo-app-deploy.e2e:run-e2e))
