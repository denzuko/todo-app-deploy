TARGET    := todo-app-deploy
PREFIX    := usr/local
BUILDROOT := build/$(PREFIX)/bin
MANROOT   := build/$(PREFIX)/man/man1

# qlfile.lock pins every dependency (109, transitively) to the exact
# release qlot resolved when it was written (`qlot add <dep>` for each
# one, or `qlot install` after a manual qlfile edit). Setting
# QUICKLISP_HOME=.qlot/ is what actually activates that pinned set --
# `.qlot/` sitting in the directory does nothing on its own, ros doesn't
# auto-detect it. All recipes below export it for that reason. Run
# `qlot add <dep>` (or `qlot install` after editing qlfile) once, before
# any of these targets; it's not a dependency of them since it's a
# one-time / on-demand step, not something that should silently re-run on
# every build.
export QUICKLISP_HOME := .qlot/

# `test` runs the post-deploy TODO-APP/E2E suite against a LIVE deploy --
# it is not a build-time unit test, and has nothing to validate without a
# target host that's already been deployed to. It's excluded from `all`
# for that reason; run it explicitly once something is actually deployed.
all: doc $(TARGET).tgz

$(BUILDROOT):
	@mkdir -p $@

$(MANROOT):
	@mkdir -p $@

$(BUILDROOT)/$(TARGET): $(TARGET).ros $(BUILDROOT)
	@ros dump executable $(TARGET).ros -o $@

build/$(TARGET).md build/todo-app-e2e.md: $(TARGET).ros docs.ros todo-app.asd src/deploy.lisp src/docs.lisp t/e2e.lisp
	@ros docs.ros

$(MANROOT)/$(TARGET).1: build/$(TARGET).md $(MANROOT)
	@pandoc -s -t man build/$(TARGET).md -o $@

$(TARGET).tgz: $(BUILDROOT)/$(TARGET)
	@tar zcvf $@ -C build $(shell echo "$(PREFIX)" | cut -d/ -f1)

install: $(TARGET).tgz
	@tar -C / -xzvf $<

test: $(TARGET).ros
	@./$< e2e

# `make doc` currently fails: docs.ros hits a real bug in
# 40ants-doc-full's own markdown renderer, unrelated to this repo's code.
# See finding 12 in FINDINGS.md. Left wired up as-is rather than papered
# over, since the rest of docs.ros (loading :todo-app/docs, walking the
# section tree, writing to build/) is correct and this is the kind of
# thing an upstream dependency bump is more likely to fix than a
# workaround here would.
doc: $(MANROOT)/$(TARGET).1

clean:
	@-rm -Rf build

distclean: clean
	@-rm -f $(TARGET).tgz .*.swp
