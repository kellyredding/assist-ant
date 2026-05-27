.PHONY: all check build dev test lint format install clean \
        cli-build cli-dev cli-test cli-lint cli-install cli-clean \
        app-build app-release app-install app-uninstall app-clean

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

cli-install:
	$(MAKE) -C tools/assist-ant install

cli-clean:
	$(MAKE) -C tools/assist-ant clean

# --- Swift app ---

app-build:
	$(MAKE) -C AssistAntApp build

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
check: cli-lint cli-test cli-build
install: cli-install app-install
clean: cli-clean app-clean
