TARGET    := todo-app-deploy
PREFIX    := usr/local
BUILDROOT := build/$(PREFIX)/bin
MANROOT   := build/$(PREFIX)/man/man1

# qlfile.lock pins every dependency (109, transitively) to the exact
# release qlot resolved at `qlot install` time. All ros invocations below
# route through `qlot exec` so builds and tests run against that pinned
# set rather than whatever happens to be in the local Quicklisp dist that
# day. Run `qlot install` once (or after editing qlfile) before any of
# these targets; it's not a dependency of them since it's a one-time /
# on-demand step, not something that should silently re-run on every build.

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
	@qlot exec ros dump executable $(TARGET).ros -o $@

build/$(TARGET).md build/todo-app-e2e.md: $(TARGET).ros docs.ros todo-app.asd src/deploy.lisp src/docs.lisp t/e2e.lisp
	@qlot exec ros docs.ros

$(MANROOT)/$(TARGET).1: build/$(TARGET).md $(MANROOT)
	@pandoc -s -t man build/$(TARGET).md -o $@

$(TARGET).tgz: $(BUILDROOT)/$(TARGET)
	@tar zcvf $@ -C build $(shell echo "$(PREFIX)" | cut -d/ -f1)

install: $(TARGET).tgz
	@tar -C / -xzvf $<

test: $(TARGET).ros
	@qlot exec ./$< e2e

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
