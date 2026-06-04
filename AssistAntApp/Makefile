SCHEME         := AssistAntApp
DERIVED_DATA   := build
CONFIG_DEBUG   := Debug
CONFIG_RELEASE := Release

APP_NAME       := Assist Ant
USER_APPS_DIR  := $(HOME)/Applications
BUILT_APP      := $(DERIVED_DATA)/Build/Products/$(CONFIG_DEBUG)/$(APP_NAME).app
USER_APP_LINK  := $(USER_APPS_DIR)/$(APP_NAME).app

.PHONY: all generate build release install uninstall clean

all: build

generate:
	xcodegen generate

build: generate
	xcodebuild \
	  -project AssistAntApp.xcodeproj \
	  -scheme $(SCHEME) \
	  -configuration $(CONFIG_DEBUG) \
	  -derivedDataPath $(DERIVED_DATA) \
	  build

release: generate
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
