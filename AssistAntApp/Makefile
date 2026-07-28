SCHEME         := AssistAntApp
DERIVED_DATA   := build
CONFIG_DEBUG   := Debug
CONFIG_RELEASE := Release

APP_NAME       := Assist Ant
USER_APPS_DIR  := $(HOME)/Applications
BUILT_APP      := $(DERIVED_DATA)/Build/Products/$(CONFIG_DEBUG)/$(APP_NAME).app
USER_APP_LINK  := $(USER_APPS_DIR)/$(APP_NAME).app

.PHONY: all generate validate-js verify-text-entry build release install \
        uninstall clean smoke smoke-items smoke-keystroke check

all: build

generate:
	xcodegen generate

# Syntax-check the JavaScript that ships inside the app — standalone
# Resources/*.js plus JS embedded in Swift """ literals marked with a
# `// js-validate` comment. xcodebuild treats embedded JS as opaque
# string data, so this gate catches syntax errors that would otherwise
# compile clean and only fail at runtime in the WebView.
validate-js:
	node scripts/validate-js.mjs

# Prove the JavaScript text-entry matcher agrees with the Swift one, by running
# the shipped literal against the same fixture table KeystrokeSmoke reads.
# validate-js only proves the literal parses; two matchers that both parse are
# still free to disagree, and this is what stops them.
verify-text-entry:
	node scripts/verify-text-entry.mjs

build: generate validate-js verify-text-entry
	xcodebuild \
	  -project AssistAntApp.xcodeproj \
	  -scheme $(SCHEME) \
	  -configuration $(CONFIG_DEBUG) \
	  -derivedDataPath $(DERIVED_DATA) \
	  build

# Sandboxed smoke checks: build the standalone tools and run them. No app
# launch — each runs as its own process.
smoke: smoke-items smoke-keystroke

# Runs against an in-memory DB + temp file.
smoke-items: generate
	xcodebuild \
	  -project AssistAntApp.xcodeproj \
	  -scheme ItemsSmoke \
	  -configuration $(CONFIG_DEBUG) \
	  -derivedDataPath $(DERIVED_DATA) \
	  build
	DYLD_FRAMEWORK_PATH="$(DERIVED_DATA)/Build/Products/$(CONFIG_DEBUG)/PackageFrameworks" \
	  "$(DERIVED_DATA)/Build/Products/$(CONFIG_DEBUG)/ItemsSmoke"

# The text-entry keystroke model: the matcher, the key-name mapping both ways,
# and the keybindings writer against a real file in a temp directory. Reads
# fixtures/text-entry-cases.json, the table the JavaScript side must also agree
# with. No framework path needed — this one links nothing but Foundation.
smoke-keystroke: generate
	xcodebuild \
	  -project AssistAntApp.xcodeproj \
	  -scheme KeystrokeSmoke \
	  -configuration $(CONFIG_DEBUG) \
	  -derivedDataPath $(DERIVED_DATA) \
	  build
	"$(DERIVED_DATA)/Build/Products/$(CONFIG_DEBUG)/KeystrokeSmoke"

# Build the app and run the smoke check — the pre-commit gate.
check: build smoke

release: generate validate-js
	xcodebuild \
	  -project AssistAntApp.xcodeproj \
	  -scheme $(SCHEME) \
	  -configuration $(CONFIG_RELEASE) \
	  -derivedDataPath $(DERIVED_DATA) \
	  build

# Symlink the built .app into ~/Applications so it's discoverable
# by Spotlight, Launchpad, and `open -a "Assist Ant"`. ~/Applications
# is per-user and Spotlight indexes through symlinks — Launch
# Services registers the underlying bundle, so bundle ID stays
# consistent.
install: build
	@mkdir -p "$(USER_APPS_DIR)"
	ln -sfn "$(CURDIR)/$(BUILT_APP)" "$(USER_APP_LINK)"
	@echo "Linked $(USER_APP_LINK) -> $(CURDIR)/$(BUILT_APP)"
	@# Re-register with Launch Services so Spotlight picks it up
	@# immediately (otherwise it can take a few minutes to index).
	/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
	  -f -R "$(USER_APP_LINK)" || true

uninstall:
	rm -f "$(USER_APP_LINK)"
	@echo "Removed $(USER_APP_LINK)"

clean:
	-xcodebuild \
	  -project AssistAntApp.xcodeproj \
	  -scheme $(SCHEME) \
	  -configuration $(CONFIG_DEBUG) \
	  -derivedDataPath $(DERIVED_DATA) \
	  clean
	rm -rf $(DERIVED_DATA)
