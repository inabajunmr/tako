APP_NAME := TakoLauncher
BUILD_DIR := .build/release
APP_DIR := dist/$(APP_NAME).app
CONTENTS_DIR := $(APP_DIR)/Contents
MACOS_DIR := $(CONTENTS_DIR)/MacOS

.PHONY: build run package open

build:
	swift build -c release

run:
	swift run TakoLauncher

package: build
	mkdir -p "$(MACOS_DIR)"
	cp "$(BUILD_DIR)/$(APP_NAME)" "$(MACOS_DIR)/$(APP_NAME)"
	cp Resources/Info.plist "$(CONTENTS_DIR)/Info.plist"
	chmod +x "$(MACOS_DIR)/$(APP_NAME)"

open: package
	open "$(APP_DIR)"
