APP_NAME := NoPeek
INSTALL_DIR := $(HOME)/Applications

.PHONY: build test install run clean icon dmg

build:
	@scripts/build-app.sh

test:
	swift test

install: build
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@# NoPeek takes a moment to exit cleanly (it unhides locked apps first); wait for it.
	@for i in $$(seq 1 30); do pgrep -x $(APP_NAME) >/dev/null || break; sleep 0.1; done
	@mkdir -p "$(INSTALL_DIR)"
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@cp -R build/$(APP_NAME).app "$(INSTALL_DIR)/"
	@echo "✓ Installed to $(INSTALL_DIR)/$(APP_NAME).app"

run: install
	@open "$(INSTALL_DIR)/$(APP_NAME).app"

dmg: build
	@scripts/make-dmg.sh

icon:
	@rm -rf build/AppIcon.iconset build/AppIcon.icns

clean:
	rm -rf build .build
