# Native Linux FuturaTerm. Requires gtk4, libvterm, cairo, pango (Omarchy/Arch).
CC ?= gcc
PREFIX ?= /usr/local
BIN := futuraterm-linux
SRC := src/app.c src/term.c src/session.c
TEST_BIN := tests/test_session

PKGS := gtk4 vterm cairo pangocairo
CFLAGS ?= -O2 -Wall -Wextra -Wno-unused-parameter
CFLAGS += -I src $(shell pkg-config --cflags $(PKGS))
LDFLAGS += $(shell pkg-config --libs $(PKGS)) -lutil

.PHONY: all test clean install

all: $(BIN)

$(BIN): $(SRC) src/session.h src/term.h src/session.c src/term.c src/app.c
	$(CC) $(CFLAGS) -o $@ $(SRC) $(LDFLAGS)

$(TEST_BIN): tests/test_session.c src/session.c src/session.h
	$(CC) -O2 -Wall -Wextra -o $@ tests/test_session.c src/session.c

test: $(TEST_BIN)
	./$(TEST_BIN)

clean:
	rm -f $(BIN) $(TEST_BIN)

install: $(BIN)
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 755 $(BIN) $(DESTDIR)$(PREFIX)/bin/$(BIN)
