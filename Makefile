TARGET    := todo-app-deploy
PREFIX    := usr/local
BUILDROOT := build/$(PREFIX)/bin
MANROOT   := build/$(PREFIX)/man/man1

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

doc: $(MANROOT)/$(TARGET).1

clean:
	@-rm -Rf build

distclean: clean
	@-rm -f $(TARGET).tgz .*.swp
