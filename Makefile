CC = xcrun clang
CFLAGS = -fobjc-arc -Wall -Wextra -Werror -Wno-deprecated-declarations -O2 -mmacosx-version-min=15.0
LDLIBS = -framework Foundation -framework CoreFoundation -lncurses
SOURCES = src/lnpctl.m src/LNPArchive.m src/LNPUI.m

.PHONY: all test clean
all: build/lnpctl

build/lnpctl: $(SOURCES) src/LNPArchive.h src/LNPUI.h
	mkdir -p build
	$(CC) $(CFLAGS) $(SOURCES) $(LDLIBS) -o $@

build/archive-test: tests/archive_harness.m src/LNPArchive.m src/LNPArchive.h
	mkdir -p build
	$(CC) $(CFLAGS) tests/archive_harness.m src/LNPArchive.m -framework Foundation -framework CoreFoundation -o $@

build/tui-harness: tests/tui_harness.m src/LNPUI.m src/LNPUI.h
	mkdir -p build
	$(CC) $(CFLAGS) tests/tui_harness.m src/LNPUI.m $(LDLIBS) -o $@

build/cli-harness: tests/cli_harness.m $(SOURCES) src/LNPArchive.h src/LNPUI.h
	mkdir -p build
	$(CC) $(CFLAGS) tests/cli_harness.m src/LNPArchive.m src/LNPUI.m $(LDLIBS) -o $@

test: build/lnpctl build/archive-test build/tui-harness build/cli-harness
	python3 tests/test_archive.py build/archive-test
	python3 tests/test_tui.py build/tui-harness
	python3 tests/test_cli.py build/cli-harness

clean:
	rm -f build/lnpctl build/archive-test build/tui-harness build/cli-harness
