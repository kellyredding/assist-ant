BINARY  := assist-ant
SRC     := src/assist_ant.cr

PREFIX       ?= $(HOME)/.assist-ant
BINDIR       ?= $(PREFIX)/bin
LOCAL_BINDIR ?= $(HOME)/.local/bin

.PHONY: all dev build test lint format check install clean

all: build

dev:
	@mkdir -p build
	crystal build -o build/$(BINARY) $(SRC)

build:
	@mkdir -p build
	crystal build --release --no-debug -o build/$(BINARY) $(SRC)

test:
	crystal spec

lint:
	crystal tool format --check src spec

format:
	crystal tool format src spec

check: lint dev test

install: build
	@mkdir -p $(BINDIR) $(LOCAL_BINDIR)
	install -m 0755 build/$(BINARY) $(BINDIR)/$(BINARY)
	ln -sf $(BINDIR)/$(BINARY) $(LOCAL_BINDIR)/$(BINARY)
	# Seed/refresh the workspace SessionStart hook (idempotent; skips when the
	# workspace symlink is absent, so it's harmless on non-agent machines).
	-$(LOCAL_BINDIR)/$(BINARY) install-hooks

clean:
	rm -rf build
