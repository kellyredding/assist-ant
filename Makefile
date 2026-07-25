.PHONY: all check build dev test lint format install clean \
        cli-build cli-dev cli-test cli-lint cli-format cli-install cli-clean \
        app-build app-smoke app-release app-install app-uninstall app-clean

all: cli-build app-build

# --- Crystal CLI ---

cli-build:
	$(MAKE) -C tools/assist-ant build

cli-dev:
	$(MAKE) -C tools/assist-ant dev

cli-test:
	$(MAKE) -C tools/assist-ant test

cli-lint:
	$(MAKE) -C tools/assist-ant lint

cli-format:
	$(MAKE) -C tools/assist-ant format

cli-install:
	$(MAKE) -C tools/assist-ant install

cli-clean:
	$(MAKE) -C tools/assist-ant clean

# --- Swift app ---

app-build:
	$(MAKE) -C AssistAntApp build

app-smoke:
	$(MAKE) -C AssistAntApp smoke

app-release:
	$(MAKE) -C AssistAntApp release

app-install:
	$(MAKE) -C AssistAntApp install

app-uninstall:
	$(MAKE) -C AssistAntApp uninstall

app-clean:
	$(MAKE) -C AssistAntApp clean

# --- Aggregates ---

build: cli-build app-build
install: cli-install app-install
clean: cli-clean app-clean

# CLI-only. The app has no counterpart for these, so they delegate straight
# through to the Crystal CLI — the app's own gate is `make -C AssistAntApp
# check` (build + smoke), which is where the JavaScript syntax gate runs.
check: cli-lint cli-test cli-build
dev: cli-dev
test: cli-test
lint: cli-lint
format: cli-format
