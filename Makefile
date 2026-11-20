APP_NAME   := Ration
BUNDLE_ID  := io.github.lancscoder.ration
VERSION    := $(shell cat VERSION)
# `make release` sets RELEASE=true: only release builds update themselves in place.
RELEASE    ?= false
SIGNING_KEY ?= $(HOME)/.config/ration/update-signing-key
ZIP         = $(BUILD_DIR)/$(APP_NAME)-$(VERSION).zip
REPO       := lancscoder/ration
BUILD_NUM  := $(shell git rev-list --count HEAD 2>/dev/null || echo 1)

BUILD_DIR  := build
APP_DIR    := $(BUILD_DIR)/$(APP_NAME).app
BIN        := .build/release/$(APP_NAME)
HOOK_BIN   := .build/release/ration-hook
INSTALL_DIR := $(HOME)/Applications

.PHONY: all build app run install uninstall test icon clean release package cask

all: app

build:
	swift build -c release

test:
	swift test

# Assemble a proper .app bundle around the SwiftPM binary and ad-hoc sign it.
app: build
	rm -rf "$(APP_DIR)"
	mkdir -p "$(APP_DIR)/Contents/MacOS" "$(APP_DIR)/Contents/Resources" "$(APP_DIR)/Contents/Helpers"
	cp "$(BIN)" "$(APP_DIR)/Contents/MacOS/$(APP_NAME)"
	cp "$(HOOK_BIN)" "$(APP_DIR)/Contents/Helpers/ration-hook"
	sed -e 's/__BUNDLE_ID__/$(BUNDLE_ID)/' -e 's/__VERSION__/$(VERSION)/' -e 's/__BUILD__/$(BUILD_NUM)/' -e 's/__RELEASE__/$(RELEASE)/' \
		Resources/Info.plist > "$(APP_DIR)/Contents/Info.plist"
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$(APP_DIR)/Contents/Resources/"; fi
	printf 'APPL????' > "$(APP_DIR)/Contents/PkgInfo"
	codesign --force --sign - --timestamp=none "$(APP_DIR)/Contents/Helpers/ration-hook"
	codesign --force --sign - --timestamp=none "$(APP_DIR)"
	@echo "Built $(APP_DIR)"

run: app
	-pkill -x $(APP_NAME); sleep 0.5
	open "$(APP_DIR)"

install: app
	-pkill -x $(APP_NAME); sleep 0.5
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	cp -R "$(APP_DIR)" "$(INSTALL_DIR)/"
	open "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Installed to $(INSTALL_DIR)/$(APP_NAME).app"

uninstall:
	-pkill -x $(APP_NAME)
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"

# Regenerate Resources/AppIcon.icns from scripts/make-icon.swift.
icon:
	rm -rf $(BUILD_DIR)/AppIcon.iconset
	mkdir -p $(BUILD_DIR)/AppIcon.iconset
	swift scripts/make-icon.swift $(BUILD_DIR)/AppIcon.iconset
	iconutil -c icns $(BUILD_DIR)/AppIcon.iconset -o Resources/AppIcon.icns

# Build, zip and sign a release: build/Ration-<version>.zip and .zip.sig.
# CI runs this on every merge to main (see .github/workflows/ci.yml); locally it
# needs the update signing key (see CONTRIBUTING.md).
release: test package

package:
	@test -f "$(SIGNING_KEY)" || { echo "No signing key at $(SIGNING_KEY)"; exit 1; }
	$(MAKE) app RELEASE=true VERSION=$(VERSION)
	rm -f "$(ZIP)" "$(ZIP).sig"
	ditto -c -k --keepParent "$(APP_DIR)" "$(ZIP)"
	swift scripts/update-signing.swift sign "$(SIGNING_KEY)" "$(ZIP)"
	@shasum -a 256 "$(ZIP)"

# Write the Homebrew cask for the current release (copy it into the tap repo).
cask:
	@test -f "$(ZIP)" || { echo "Run make release first"; exit 1; }
	sed -e 's/__VERSION__/$(VERSION)/' -e "s/__SHA256__/$$(shasum -a 256 "$(ZIP)" | cut -d' ' -f1)/" \
		packaging/homebrew/ration.rb.in > $(BUILD_DIR)/ration.rb
	@echo "Wrote $(BUILD_DIR)/ration.rb"

clean:
	rm -rf .build $(BUILD_DIR)
