# Native Linux FuturaTerm. Requires gtk4, libvterm, cairo, pango (Omarchy/Arch).
CC ?= gcc
PREFIX ?= /usr/local
BIN := futuraterm-linux

CORE_SRC := src/util.c src/path.c src/session.c src/split.c src/layout.c \
	src/remote.c src/prefs.c src/command.c src/model.c src/control.c src/sel.c \
	src/desktop.c
CORE_HDR := src/util.h src/path.h src/session.h src/split.h src/layout.h \
	src/remote.h src/prefs.h src/command.h src/model.h src/control.h src/sel.h \
	src/desktop.h
GUI_SRC := src/app.c src/term.c
SRC := $(GUI_SRC) $(CORE_SRC)

TESTS := tests/test_session tests/test_path tests/test_split tests/test_layout \
	tests/test_remote tests/test_prefs tests/test_control tests/test_model tests/test_sel \
	tests/test_folder tests/test_desktop

PKGS := gtk4 vterm cairo pangocairo
CFLAGS ?= -O2 -Wall -Wextra -Wno-unused-parameter
CFLAGS += -I src
GUI_CFLAGS := $(CFLAGS) $(shell pkg-config --cflags $(PKGS) 2>/dev/null)
GUI_LDFLAGS := $(shell pkg-config --libs $(PKGS) 2>/dev/null) -lutil
CORE_CFLAGS := -O2 -Wall -Wextra -I src

.PHONY: all test clean install

all: $(BIN)

$(BIN): $(SRC) $(CORE_HDR) src/term.h
	$(CC) $(GUI_CFLAGS) -o $@ $(SRC) $(GUI_LDFLAGS)

tests/test_session: tests/test_session.c src/session.c src/session.h
	$(CC) $(CORE_CFLAGS) -o $@ tests/test_session.c src/session.c

tests/test_path: tests/test_path.c src/path.c src/util.c src/path.h src/util.h
	$(CC) $(CORE_CFLAGS) -o $@ tests/test_path.c src/path.c src/util.c

tests/test_split: tests/test_split.c src/split.c src/util.c src/split.h src/util.h
	$(CC) $(CORE_CFLAGS) -o $@ tests/test_split.c src/split.c src/util.c

tests/test_layout: tests/test_layout.c src/layout.c src/split.c src/path.c src/util.c
	$(CC) $(CORE_CFLAGS) -o $@ tests/test_layout.c src/layout.c src/split.c src/path.c src/util.c

tests/test_remote: tests/test_remote.c src/remote.c src/path.c src/util.c
	$(CC) $(CORE_CFLAGS) -o $@ tests/test_remote.c src/remote.c src/path.c src/util.c

tests/test_prefs: tests/test_prefs.c src/prefs.c src/command.c src/util.c
	$(CC) $(CORE_CFLAGS) -o $@ tests/test_prefs.c src/prefs.c src/command.c src/util.c

tests/test_control: tests/test_control.c $(CORE_SRC)
	$(CC) $(CORE_CFLAGS) -o $@ tests/test_control.c $(CORE_SRC)

tests/test_model: tests/test_model.c $(CORE_SRC)
	$(CC) $(CORE_CFLAGS) -o $@ tests/test_model.c $(CORE_SRC)

tests/test_sel: tests/test_sel.c src/sel.c src/command.c src/util.c src/sel.h src/command.h
	$(CC) $(CORE_CFLAGS) -o $@ tests/test_sel.c src/sel.c src/command.c src/util.c

tests/test_folder: tests/test_folder.c $(CORE_SRC)
	$(CC) $(CORE_CFLAGS) -o $@ tests/test_folder.c $(CORE_SRC)

tests/test_desktop: tests/test_desktop.c src/desktop.c src/command.c src/util.c
	$(CC) $(CORE_CFLAGS) -o $@ tests/test_desktop.c src/desktop.c src/command.c src/util.c

test: $(TESTS)
	@for t in $(TESTS); do echo "== $$t"; ./$$t || exit 1; done

clean:
	rm -f $(BIN) $(TESTS)

install: $(BIN)
	install -d $(DESTDIR)$(PREFIX)/bin
	install -d $(DESTDIR)$(PREFIX)/share/applications
	install -d $(DESTDIR)$(PREFIX)/share/icons/hicolor/256x256/apps
	install -m 755 $(BIN) $(DESTDIR)$(PREFIX)/bin/futuraterm
	install -m 644 share/applications/com.davidsolheim.futuraterm.desktop \
		$(DESTDIR)$(PREFIX)/share/applications/
	install -m 644 share/icons/hicolor/256x256/apps/com.davidsolheim.futuraterm.png \
		$(DESTDIR)$(PREFIX)/share/icons/hicolor/256x256/apps/
