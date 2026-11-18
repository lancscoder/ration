APP_NAME   := ClaudeBar
BUNDLE_ID  := local.claudebar.ClaudeBar
VERSION    := 1.0.0
BUILD_NUM  := $(shell git rev-list --count HEAD 2>/dev/null || echo 1)

BUILD_DIR  := build
APP_DIR    := $(BUILD_DIR)/$(APP_NAME).app
BIN        := .build/release/$(APP_NAME)
HOOK_BIN   := .build/release/claudebar-hook
INSTALL_DIR := $(HOME)/Applications

.PHONY: all build app run install uninstall test icon clean

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
	cp "$(HOOK_BIN)" "$(APP_DIR)/Contents/Helpers/claudebar-hook"
	sed -e 's/__BUNDLE_ID__/$(BUNDLE_ID)/' -e 's/__VERSION__/$(VERSION)/' -e 's/__BUILD__/$(BUILD_NUM)/' \
		Resources/Info.plist > "$(APP_DIR)/Contents/Info.plist"
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$(APP_DIR)/Contents/Resources/"; fi
	printf 'APPL????' > "$(APP_DIR)/Contents/PkgInfo"
	codesign --force --sign - --timestamp=none "$(APP_DIR)/Contents/Helpers/claudebar-hook"
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

clean:
	rm -rf .build $(BUILD_DIR)
