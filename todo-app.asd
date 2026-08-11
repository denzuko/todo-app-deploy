;;;; todo-app.asd
;;;;
;;;; :TODO-APP is the umbrella namespace. Each component of this project
;;;; is a subsystem under it (:todo-app/deploy, :todo-app/docs,
;;;; :todo-app/e2e); a future component -- a webapp, a CLI, whatever --
;;;; would add :todo-app/<name> here without renaming anything that
;;;; already exists.
;;;;
;;;; :TODO-APP itself has no components of its own. ASDF's slash-named
;;;; subsystem convention requires this system to exist regardless: every
;;;; :todo-app/<x> system implicitly depends on it, and both ASDF and
;;;; Quicklisp resolve :todo-app/<x> by first locating :todo-app's own
;;;; .asd file. Skipping this definition isn't optional shorthand: without
;;;; it, loading any :todo-app/<x> system fails outright.

(asdf:defsystem :todo-app)

(asdf:defsystem :todo-app/deploy
  :description "Roswell/Consfigurator deploy of a PostgREST+HTMX+Alpine.js
to-do app on rootless Podman quadlets behind HAProxy."
  :license "BSD-3-Clause"
  :depends-on (:sxql :spinneret :cl-inix :consfigurator :postmodern
               :cl-migratum :cl-migratum.driver.postmodern-postgresql)
  :components ((:file "src/deploy"))
  :in-order-to ((asdf:test-op (asdf:test-op :todo-app/e2e))))

(asdf:defsystem :todo-app/docs
  :depends-on (:todo-app/deploy :todo-app/e2e :40ants-doc :40ants-doc-full)
  :components ((:file "src/docs")))

(asdf:defsystem :todo-app/e2e
  :depends-on (:todo-app/deploy :fiveam :dexador :postmodern)
  :components ((:file "t/e2e"))
  :perform (asdf:test-op (op c)
             (uiop:symbol-call :fiveam :run! :todo-app-e2e)))
