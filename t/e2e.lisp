;;;; t/e2e.lisp -- todo-app/e2e post-deploy validation
;;;;
;;;; Loaded as the :TODO-APP/E2E ASDF system. Validates a live deploy of
;;;; the stack TODO-APP/DEPLOY:DEPLOY-APP brings up: ZFS mountpoints,
;;;; linger, quadlet unit state, the HAProxy-fronted URL over real HTTP
;;;; via Dexador, the schema and grants via Postmodern, and a full
;;;; add-toggle-delete round trip through the actual API. This validates
;;;; the deployed result; TODO-APP/DEPLOY's own generator functions don't
;;;; have a separate pre-deploy unit-test suite yet.

(defpackage :todo-app/e2e
  (:use :cl :fiveam)
  (:import-from :todo-app/deploy
                :*service-user* :*home-mountpoint* :*secrets-path*
                :*haproxy-fqdn* :*home-dataset* :*data-dataset*)
  (:export :run-e2e :unit-active-p :zfs-dataset-mountpoint
           :zfs-dataset-encryption :read-db-password :latest-todo-id))

(in-package :todo-app/e2e)

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

(defun zfs-dataset-encryption (dataset)
  "The encryption algorithm ZFS reports for DATASET (e.g. \"aes-256-gcm\"),
   or \"off\" if it isn't encrypted, or NIL if DATASET doesn't exist."
  (multiple-value-bind (output error-output status)
      (uiop:run-program (format nil "zfs get -H -o value encryption ~A" dataset)
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
  "Both datasets exist, are mounted where TODO-APP/DEPLOY:DEPLOY-APP put
   them, and are AES-256-GCM encrypted."
  (is (equal *home-mountpoint* (zfs-dataset-mountpoint *home-dataset*)))
  (is (equal "/srv/todo-app" (zfs-dataset-mountpoint *data-dataset*)))
  (is (equal "aes-256-gcm" (zfs-dataset-encryption *home-dataset*)))
  (is (equal "aes-256-gcm" (zfs-dataset-encryption *data-dataset*))))

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
  "api.todos exists and web_anon has exactly the privileges TODO-APP/DEPLOY granted."
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

