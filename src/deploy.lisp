;;;; src/deploy.lisp -- todo-app/deploy core package
;;;;
;;;; Loaded as the :TODO-APP/DEPLOY ASDF system. Everything that actually
;;;; provisions and deploys the stack lives here: the Consfigurator
;;;; properties and DEFHOST, the SXQL/Spinneret schema and HTML builders,
;;;; the cl-migratum wiring, and DEPLOY-APP itself. todo-app-deploy.ros is
;;;; a thin command wrapper around this system, not the other way around;
;;;; see todo-app.asd for the system definition and t/e2e.lisp for the
;;;; post-deploy validation suite.

(defpackage :todo-app/deploy
  (:use :cl :sxql)
  (:import-from :spinneret :with-html-string)
  (:import-from :consfigurator
                :defprop :defhost :deploy :run :mrun :stripln
                :remote-exists-p :write-remote-file :on-change)
  (:import-from :consfigurator.property.file
                :has-content :containing-directory-exists)
  (:import-from :consfigurator.property.systemd :lingering-enabled)
  (:import-from :consfigurator.property.service :reloaded)
  (:export :*service-user* :*home-mountpoint* :*data-mountpoint*
           :*secrets-path* :*haproxy-fqdn* :*home-dataset* :*data-dataset*
           :*home-dataset-keyfile* :*data-dataset-keyfile*
           :deploy-app
           :zfs-encryption-key :zfs-dataset-mounted :rootless-service-account
           :db-secret-file
           :images-pulled :quadlets-activated
           :cinix-write-string :postgres-quadlet-sections
           :postgrest-quadlet-sections :todo-network-quadlet-sections
           :haproxy-vhost-config
           :generate-index-html-template :generate-render-todo-html-template
           :escape-pg-string-literal
           :sql-create-schema :sql-create-domain :sql-create-role :sql-grant :sql-grant-execute
           :build-migration-sql :ram-migration :ram-provider
           :make-ram-provider :make-ram-migration :next-migration-id
           :run-migrations))

(in-package :todo-app/deploy)

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
(defparameter *home-dataset-keyfile* "/etc/zfs-keys/todo-app-users.key"
  "Raw ZFS encryption key for *HOME-DATASET*. Lives outside any ZFS
   dataset it protects; a dataset can't supply its own decryption key
   from inside itself.")
(defparameter *data-dataset* "storage/containers/todo-app")
(defparameter *data-mountpoint* "/srv/todo-app"
  "PostgreSQL data directory, backed by *DATA-DATASET*.")
(defparameter *data-dataset-keyfile* "/etc/zfs-keys/todo-app-containers.key"
  "Raw ZFS encryption key for *DATA-DATASET*. A separate key from
   *HOME-DATASET-KEYFILE*; the two datasets don't share one.")
(defparameter *secrets-path* "/var/lib/todo-app/.env/pgpass"
  "Generated once and left alone on redeploy. The postgres data volume's
   password can't be rotated out from under it on every run.")
(defparameter *haproxy-vhost-name* "todo-app")
(defparameter *haproxy-fqdn* "todo.dapla.net")

(defprop zfs-encryption-key :posix (path)
  "Generate a raw 32-byte ZFS encryption key at PATH via `openssl rand`,
   once, left alone on redeploy. Losing this key after the dataset it
   protects holds real data means losing the data, so regenerating it
   isn't something a redeploy should ever do casually."
  (:desc (format nil "ZFS encryption key at ~A" path))
  (:check (remote-exists-p path))
  (:apply
   (containing-directory-exists path)
   (let ((key (stripln (mrun "openssl" "rand" "-hex" "32"))))
     (write-remote-file path key :mode #o600))))

(defun zfs-create-command (dataset mountpoint keyfile)
  "The `zfs create` command line for DATASET at MOUNTPOINT: with
   AES-256-GCM encryption keyed from KEYFILE when given, plain otherwise."
  (if keyfile
      (format nil "zfs create -o mountpoint=~A -o encryption=aes-256-gcm -o keyformat=raw -o keylocation=file://~A ~A"
              mountpoint keyfile dataset)
      (format nil "zfs create -o mountpoint=~A ~A" mountpoint dataset)))

(defprop zfs-dataset-mounted :posix (dataset mountpoint &optional keyfile)
  "Ensure DATASET exists, mounted at MOUNTPOINT. When KEYFILE is given,
   the dataset is created with AES-256-GCM native encryption keyed from
   that file (raw format, not an interactive passphrase, so an
   unattended deploy never blocks on a prompt). If the dataset already
   exists but isn't mounted, the state a reboot leaves an encrypted
   dataset in when the key wasn't auto-loaded by zfs-mount-generator,
   the key gets loaded and the dataset mounted rather than assuming
   existence alone means nothing further is needed."
  (:desc (format nil "ZFS dataset ~A mounted at ~A~:[~; (encrypted)~]"
                  dataset mountpoint keyfile))
  (:check
   (multiple-value-bind (out err exit)
       (run :may-fail (format nil "zfs get -H -o value mounted ~A" dataset))
     (declare (ignore err))
     (and (zerop exit) (string= "yes" (stripln out)))))
  (:apply
   (if (zerop (mrun :for-exit (format nil "zfs list -H -o name ~A" dataset)))
       (progn
         (when keyfile (mrun (format nil "zfs load-key ~A" dataset)))
         (mrun (format nil "zfs mount ~A" dataset)))
       (mrun (zfs-create-command dataset mountpoint keyfile)))))

(defprop rootless-service-account :posix (username home)
  "Ensure a system account USERNAME exists with home directory HOME,
   without creating that directory.
   CONSFIGURATOR.PROPERTY.USER:HAS-ACCOUNT always passes useradd -m; this
   account's home is ZFS-backed and provisioned by ZFS-DATASET-MOUNTED
   earlier in the host's property list, so -m would collide with a
   directory that's already there."
  (:desc (format nil "System account ~A at ~A" username home))
  (:check (zerop (mrun :for-exit "id" username)))
  (:apply (mrun "useradd" "--system" "--no-create-home"
                "--home-dir" home username)))

(defprop db-secret-file :posix (path user)
  "Generate the postgres password once via `openssl rand -hex 32` and
   persist it at PATH, mode 0600, owned by USER. Left alone on redeploy;
   the postgres data volume's password can't be rotated out from under it
   on every run.

   Found while working on ZFS-ENCRYPTION-KEY: WRITE-REMOTE-FILE has no
   directory-creation logic of its own (confirmed by reading
   CONNECTION-WRITE-FILE's :LOCAL method directly, not assumed), so this
   always needed CONTAINING-DIRECTORY-EXISTS for PATH's .env/ subdirectory
   and never had it. Never actually hit in testing because every prior
   deploy attempt failed earlier, at the ZFS step, in every environment
   this was run in."
  (:desc (format nil "DB secret at ~A" path))
  (:check (remote-exists-p path))
  (:apply
   (containing-directory-exists path)
   (let ((pass (stripln (mrun "openssl" "rand" "-hex" "32"))))
     (write-remote-file
      path
      (format nil "POSTGRES_PASSWORD=~A~%PGRST_DB_URI=postgres://postgres:~A@todo-postgres:5432/tododb~%"
              pass pass)
      :mode #o600)
     (mrun "chown" (format nil "~A:~A" user user) path))))

(defprop images-pulled :posix (user &rest images)
  "Pull IMAGES into USER's rootless Podman image store via `machinectl
   shell`, since the image store belongs to the service user's own login
   session, not the connection Consfigurator is deploying through."
  (:desc (format nil "Podman images pulled for ~A" user))
  (:check
   (every (lambda (image)
            (zerop (mrun :for-exit
                    (format nil "machinectl shell ~A@ -- podman image exists ~A"
                            user image))))
          images))
  (:apply
   (dolist (image images)
     (mrun (format nil "machinectl shell ~A@ -- podman pull ~A" user image)))))

(defun cinix-write-string (sections)
  "Serialize an alist of (section-name . ((key . value) ...)), the same
   shape cl-inix:read produces from an INI file, into INI/systemd unit-file
   text. cl-inix itself is read-only (dps-meta uses it in-process to parse
   .git/config in place of a uiop:run-program fork), so this is the write-side
   counterpart, playing the role for the quadlet AST that SXQL's `yield`
   plays for SQL and Spinneret's `with-html-string` plays for HTML. Keys may
   repeat within a section (multiple Environment= lines, for instance) since
   each section is an ordered list of conses, not a hash."
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

(defun haproxy-vhost-config ()
  "HAProxy vhost text terminating TLS for *HAPROXY-FQDN* and backending to
   PostgREST on loopback; containers never see the public interface
   directly."
  (format nil "frontend ~A_fe
  bind *:443 ssl crt /etc/haproxy/certs/dapla_stack.pem
  acl host_~A hdr(host) -i ~A
  use_backend ~A_be if host_~A

backend ~A_be
  server todo-postgrest 127.0.0.1:3000 check
"
          *haproxy-vhost-name* *haproxy-vhost-name* *haproxy-fqdn*
          *haproxy-vhost-name* *haproxy-vhost-name* *haproxy-vhost-name*))

(defprop quadlets-activated :posix (user)
  "Reload USER's user-scope systemd daemon and restart the postgres and
   postgrest quadlet-generated services, picking up whatever changed in
   the unit files above. Consfigurator's own SYSTEMD:DAEMON-RELOADED and
   SYSTEMD:RESTARTED act on the connection's own systemd instance; there's
   no built-in way to target a different account's --user session reached
   through `machinectl shell`, so this stays a small custom property
   rather than a fictional dependency on one that doesn't exist."
  (:desc (format nil "Quadlets activated for ~A" user))
  (:apply
   (mrun (format nil "machinectl shell ~A@ -- systemctl --user daemon-reload" user))
   (mrun (format nil "machinectl shell ~A@ -- systemctl --user restart postgres postgrest"
                 user))))

(defhost todo-app-host (:deploy (:local))
  "The todo-app stack's host: two AES-256-GCM-encrypted ZFS datasets,
   the rootless service account and its linger, the generated DB secret,
   pulled images, the three quadlet units, and the HAProxy vhost, applied
   in dependency order. Each dataset's encryption key is generated before
   the dataset itself, since ZFS-DATASET-MOUNTED needs the key file to
   already exist to create an encrypted dataset. Quadlet activation runs
   before the HAProxy reload only because that's the more natural read
   order, not because it's required: HAProxy's `check` directive already
   monitors backend health on its own, so a reload against a
   not-yet-listening PostgREST is a normal transient down state, not a
   failure condition. DEPLOY-APP below runs this, then hands off to
   RUN-MIGRATIONS for the database layer, which is unrelated to
   Consfigurator and stays exactly as it was."
  (zfs-encryption-key *home-dataset-keyfile*)
  (zfs-encryption-key *data-dataset-keyfile*)
  (zfs-dataset-mounted *home-dataset* *home-mountpoint* *home-dataset-keyfile*)
  (zfs-dataset-mounted *data-dataset* *data-mountpoint* *data-dataset-keyfile*)
  (rootless-service-account *service-user* *home-mountpoint*)
  (lingering-enabled *service-user*)
  (db-secret-file *secrets-path* *service-user*)
  (images-pulled *service-user*
                  "docker.io/library/postgres:16-alpine"
                  "docker.io/postgrest/postgrest:v12.0.2")
  (has-content
   (format nil "~A/.config/containers/systemd/todo-net.network" *home-mountpoint*)
   (cinix-write-string (todo-network-quadlet-sections)))
  (has-content
   (format nil "~A/.config/containers/systemd/postgres.container" *home-mountpoint*)
   (cinix-write-string (postgres-quadlet-sections)))
  (has-content
   (format nil "~A/.config/containers/systemd/postgrest.container" *home-mountpoint*)
   (cinix-write-string (postgrest-quadlet-sections)))
  (quadlets-activated *service-user*)
  (on-change
      (has-content (format nil "/etc/haproxy/conf.d/~A.cfg" *haproxy-vhost-name*)
                    (haproxy-vhost-config))
    (reloaded "haproxy")))

(defun generate-index-html-template ()
  "Generate the index page shell via Spinneret. The `%s` inside the todo-list
   is PostgreSQL's own format() substitution syntax, not Lisp's `~A`. This
   string is only ever read by PostgreSQL's format() at request time, after
   Lisp's own format has already finished substituting the whole template
   into the SQL body. The Add button's Alpine `:disabled=\"expr\"` binding
   needs the attribute name pipe-quoted as :|:disabled|. Spinneret treats
   the plain keyword :DISABLED as HTML5's native boolean attribute of the
   same name, and a value passed there collapses to a bare `disabled`,
   silently dropping the whole Alpine binding with no warning that it
   happened. SPINNERET:*ALWAYS-QUOTE* is set at the top of this file, before
   this function is compiled, and that setting is what keeps that
   attribute's value, and every attribute value in
   GENERATE-RENDER-TODO-HTML-TEMPLATE below, properly quoted even though the
   literal placeholder text Spinneret sees at generation time never itself
   contains whitespace."
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
   from a Lisp-level true/false value at generation time, and whether a
   given row is done isn't known until PostgreSQL's format() resolves it at
   request time. That's a genuine boundary between the two templating
   systems rather than anything Spinneret does wrong, so that one input
   stays a hand-written :RAW placeholder; every other element here is
   ordinary Spinneret markup. Placeholder order is li id, checked, hx-patch
   id, hx-target id, span class, span content, hx-delete id, hx-target id:
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
   vocabulary at all (CREATE-SCHEMA isn't a function it exports), so this
   is the same kind of small structured builder as SQL-CREATE-ROLE and
   SQL-GRANT below it, not a hand-typed literal wrapped in an unrelated
   function name."
  (format nil "CREATE SCHEMA IF NOT EXISTS ~A" name))

(defun sql-create-domain (schema name base-type)
  "Emit an idempotent domain-creation statement, for the same reason
   SQL-CREATE-ROLE needs one: PostgreSQL's CREATE DOMAIN has no IF NOT
   EXISTS clause, and CREATE SCHEMA IF NOT EXISTS leaves an existing
   schema's contents (including this domain) untouched on redeploy, so
   a bare CREATE DOMAIN fails with a duplicate-object error on every
   redeploy after the first. Domains are stored as types, so the existence
   check joins pg_type to pg_namespace rather than querying a dedicated
   pg_domains catalog."
  (format nil "DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_catalog.pg_type t JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace WHERE t.typname = '~A' AND n.nspname = '~A') THEN CREATE DOMAIN ~A.~A AS ~A; END IF; END $$"
          name schema schema name base-type))

(defun sql-create-role (name)
  "Emit an idempotent role-creation statement. Unlike CREATE SCHEMA and
   CREATE TABLE, PostgreSQL's CREATE ROLE has no IF NOT EXISTS clause at
   all, and roles live at the cluster level, not the database level: a
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
   could scan and sign; nothing here writes the generated SQL to disk."
  (make-instance 'ram-migration
                 :id id :description description :kind :sql :applied nil
                 :up-content up-sql :down-content down-sql))

(defun next-migration-id (driver)
  "A monotonic id derived from DRIVER's own applied-migration history rather
   than the clock. A 14-digit YYYYMMDDHHMMSS timestamp, the id scheme
   CL-MIGRATUM.UTIL:MAKE-MIGRATION-ID itself uses, collides when two
   migrations are built inside the same wall-clock second, which a fast
   redeploy (or two e2e runs back to back) can genuinely do; reading the
   driver's own latest id back and incrementing it can't collide regardless
   of timing."
  (let ((latest (cl-migratum.core:latest-migration driver)))
    (if latest (1+ (cl-migratum.core:migration-id latest)) 1)))

(defun run-migrations (database user password host)
  "Build a RAM-PROVIDER holding one RAM-MIGRATION, the current
   BUILD-MIGRATION-SQL output, and apply it via cl-migratum's real
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

(defun deploy-app ()
  "Provision the whole stack via TODO-APP-HOST (Consfigurator, :local
   connection: ZFS datasets, service account, linger, secret, images,
   quadlets, HAProxy), then apply the database migration once PostgreSQL
   is up. Migrations stay outside Consfigurator; cl-migratum's own driver
   already handles that layer for real, and folding it into a Consfigurator
   property would just be re-wrapping a tool that doesn't need wrapping.

   TODO-APP-HOST is generated by DEFHOST's own :DEPLOY clause, and that
   generated function wraps property application in Consfigurator's
   WITH-DEPLOYMENT-REPORT, which prints a per-property pass/fail report and
   then returns normally regardless of whether anything failed; it never
   surfaces failure back to the caller. The only place that information
   actually exists is the CONSFIGURATOR::SKIPPED-PROPERTIES condition each
   failed property signals internally, which WITH-DEPLOYMENT-REPORT's own
   handler-bind catches to build that report but doesn't re-signal or
   return. Since that inner handler never transfers control, the same
   condition keeps propagating outward, so a HANDLER-BIND wrapped around
   the call here sees it too. This is what makes running migrations
   against a host that failed to provision an explicit refusal instead of
   a silent, confusing failure three steps later."
  (format t "~&--> Provisioning via Consfigurator (TODO-APP-HOST)...~%")
  (let ((provisioning-failed nil))
    (handler-bind ((consfigurator::skipped-properties
                     (lambda (c) (declare (ignore c))
                       (setf provisioning-failed t))))
      (todo-app-host))
    (when provisioning-failed
      (error "TODO-APP-HOST provisioning reported failed properties (see ~
              the per-property report above). Refusing to proceed to ~
              database migrations against a host that may not be fully ~
              provisioned.")))

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

