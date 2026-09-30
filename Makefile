# QBO MCP Proxy — build and verification entry points.
#
# Like Tunnelbar: no .xcodeproj, everything builds headlessly with SwiftPM.

SWIFT ?= swift
NPM ?= npm

# Code signing identity: Developer ID, then Apple Development, then ad-hoc.
# A stable signature matters here for the same reasons as in Tunnelbar —
# Keychain ACLs (the Intuit keys and access keys) and SMAppService key on it,
# so an ad-hoc build re-prompts for the Keychain after every rebuild.
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null \
	| awk -F'"' '/Developer ID Application/ {print $$2; exit}'; \
	security find-identity -v -p codesigning 2>/dev/null \
	| awk -F'"' '/Apple Development/ {print $$2; exit}')
CODESIGN_ID := $(if $(SIGN_IDENTITY),$(SIGN_IDENTITY),-)
# The display name. Internals keep the QBOBar name on purpose: the bundle id
# (Keychain access), the executable, and the data folder are what settings
# are keyed on, so renaming them would strand every company and key.
APP := QBO MCP Proxy.app
EXE_NAME := QBOBar
# Notarization: a notarytool keychain profile, created once with
#   xcrun notarytool store-credentials qbo-mcp-proxy --apple-id <id> --team-id ZP8TR4ZYDR --password <app-specific>
# (an App Store Connect API key works too). No secret lives here.
NOTARY_PROFILE ?= qbo-mcp-proxy
# CI passes Apple ID credentials instead of a profile (see .github/workflows/release.yml).
NOTARY_AUTH ?= --keychain-profile "$(NOTARY_PROFILE)"
DIST_ZIP := dist/QBO-MCP-Proxy.zip
DMG := dist/QBO-MCP-Proxy.dmg
# Universal: Apple Silicon and Intel. The bundled server is plain JavaScript,
# so only the Swift binary needs both architectures.
ARCHS := --arch arm64 --arch x86_64
RELEASE_BIN := .build/apple/Products/Release/QBOBar
NODE ?= node
INSTALL_DIR ?= /Applications

# Intuit's server, pinned to the commit in UPSTREAM_REF. To move the pin,
# edit that file (or `make server SERVER_REF=…` for a one-off build).
SERVER_REPO ?= https://github.com/intuit/quickbooks-online-mcp-server.git
SERVER_REF ?= $(shell cat UPSTREAM_REF)
SERVER_SRC := .build/qbo-server/src
SERVER_STAGE := .build/qbo-server/stage

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk -F':.*?## ' '{printf "  \033[1m%-12s\033[0m %s\n", $$1, $$2}'

.PHONY: build
build: ## Build all targets
	$(SWIFT) build

.PHONY: test
test: ## Run the test suite (needs node for the fake upstream)
	$(SWIFT) test

.PHONY: test-upstream
test-upstream: server ## Also run the tests against Intuit's real server (no QBO credentials needed)
	QBOBAR_SERVER_DIR=$(abspath $(SERVER_STAGE)) $(SWIFT) test

.PHONY: node-check
node-check: ## Check that Node.js 18 or later is installed
	@v=$$($(NODE) --version 2>/dev/null) || { echo "Node.js 18 or later is needed: brew install node (or https://nodejs.org)"; exit 1; }; \
	major=$${v#v}; major=$${major%%.*}; \
	if [ "$$major" -lt 18 ]; then echo "Node.js 18 or later is needed; found $$v"; exit 1; fi; \
	echo "Node.js $$v"

.PHONY: server
server: $(SERVER_STAGE)/VERSION ## Fetch and build Intuit's QBO MCP server at SERVER_REF

$(SERVER_STAGE)/VERSION: UPSTREAM_REF Resources/upstream/qbobar-entry.mjs
	@test -n "$(SERVER_REF)" || { echo "SERVER_REF not found in UPSTREAM_REF"; exit 1; }
	@$(MAKE) --no-print-directory node-check
	@if [ ! -d $(SERVER_SRC)/.git ]; then git clone --quiet $(SERVER_REPO) $(SERVER_SRC); fi
	cd $(SERVER_SRC) && git fetch --quiet origin && git checkout --quiet $(SERVER_REF)
	cd $(SERVER_SRC) && $(NPM) ci --no-audit --no-fund && $(NPM) run build \
		&& $(NPM) prune --omit=dev --no-audit --no-fund
	rm -rf $(SERVER_STAGE)
	mkdir -p $(SERVER_STAGE)
	cp -R $(SERVER_SRC)/dist $(SERVER_SRC)/node_modules $(SERVER_STAGE)/
	cp $(SERVER_SRC)/LICENSE $(SERVER_STAGE)/LICENSE 2>/dev/null || true
	@# Our entry point: two internal read-only tools, then Intuit's index.js.
	cp Resources/upstream/qbobar-entry.mjs $(SERVER_STAGE)/dist/qbobar-entry.mjs
	@# The stamp covers the entry too, so companies re-seed dist when it changes.
	echo "$(SERVER_REF)+$$(shasum -a 256 Resources/upstream/qbobar-entry.mjs | cut -c1-12)" > $(SERVER_STAGE)/VERSION
	@# Native addons inside Resources would need their own signatures.
	@if find $(SERVER_STAGE)/node_modules -name '*.node' | grep -q .; then \
		echo "WARNING: native Node addons found; they need signing before notarisation"; fi
	@echo "Staged Intuit's server @ $(SERVER_REF)"

.PHONY: serve
serve: server ## Run the gateway headlessly from SwiftPM (uses the real Keychain and data folder)
	$(SWIFT) build
	QBOBAR_SERVER_DIR=$(abspath $(SERVER_STAGE)) .build/debug/QBOBar --serve

.PHONY: app
app: server ## Assemble and sign the app, with Intuit's server bundled
	$(SWIFT) build -c release $(ARCHS)
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp $(RELEASE_BIN) "$(APP)/Contents/MacOS/$(EXE_NAME)"
	@lipo -info "$(APP)/Contents/MacOS/$(EXE_NAME)"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	cp -R $(SERVER_STAGE) "$(APP)/Contents/Resources/server"
	@echo "Signing with: $(CODESIGN_ID)"
	codesign --force --options runtime --timestamp --sign "$(CODESIGN_ID)" \
		--identifier com.adolfsson.qbobar "$(APP)"
	@codesign --verify --strict --verbose=1 "$(APP)"
	@codesign -dv "$(APP)" 2>&1 | grep -E "Identifier|Authority|TeamIdentifier" | head -4
	@echo "Built $(APP)"

.PHONY: dmg
dmg: ## Package the built app as a drag-to-Applications disk image in dist/
	@test -d "$(APP)" || { echo "Build the app first (make app)"; exit 1; }
	rm -rf dist/dmg-root "$(DMG)"
	mkdir -p dist/dmg-root
	cp -R "$(APP)" dist/dmg-root/
	ln -s /Applications dist/dmg-root/Applications
	hdiutil create -volname "QBO MCP Proxy" -srcfolder dist/dmg-root -fs HFS+ -format UDZO -ov "$(DMG)"
	rm -rf dist/dmg-root
	codesign --force --timestamp --sign "$(CODESIGN_ID)" "$(DMG)"
	@echo "Built $(DMG)"

.PHONY: notarize
notarize: app ## Notarize and staple the app and a DMG of it (needs Developer ID + NOTARY_PROFILE)
	@case "$(CODESIGN_ID)" in "Developer ID Application"*) ;; \
		*) echo "Notarization needs a Developer ID Application certificate; signing identity is: $(CODESIGN_ID)"; exit 1;; esac
	@xcrun notarytool history $(NOTARY_AUTH) >/dev/null 2>&1 || { \
		echo "Notarization credentials not usable. Create the profile once with:"; \
		echo "  xcrun notarytool store-credentials $(NOTARY_PROFILE) --apple-id <APPLE_ID> --team-id ZP8TR4ZYDR --password <app-specific password>"; exit 1; }
	@# 1. The app itself, so its ticket can be stapled inside the DMG.
	mkdir -p dist
	rm -f "$(DIST_ZIP)"
	ditto -c -k --keepParent "$(APP)" "$(DIST_ZIP)"
	xcrun notarytool submit "$(DIST_ZIP)" $(NOTARY_AUTH) --wait
	xcrun stapler staple "$(APP)"
	rm -f "$(DIST_ZIP)"
	@# 2. The DMG around the stapled app: installs cleanly even offline.
	$(MAKE) --no-print-directory dmg
	xcrun notarytool submit "$(DMG)" $(NOTARY_AUTH) --wait
	xcrun stapler staple "$(DMG)"
	xcrun stapler validate "$(DMG)"
	spctl --assess --type open --context context:primary-signature --verbose=2 "$(DMG)"
	spctl --assess --type execute --verbose=2 "$(APP)"
	@echo "Notarized: $(DMG)"

.PHONY: install
install: app ## Build, sign, install into $(INSTALL_DIR), and relaunch
# Any running copy is stopped first, wherever it was launched from: two copies
# would each run every company on the same refresh-token chain. (The app also
# refuses to start a second gateway, but a clean handover is better.)
	@set -e; \
	WAS_RUNNING=0; \
	if pgrep -f "Contents/MacOS/$(EXE_NAME)" >/dev/null 2>&1; then \
		WAS_RUNNING=1; echo "Stopping the running copy."; \
		pkill -f "Contents/MacOS/$(EXE_NAME)" || true; \
		for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "Contents/MacOS/$(EXE_NAME)" >/dev/null || break; sleep 0.5; done; \
	fi; \
	rm -rf "$(INSTALL_DIR)/$(APP)"; \
	cp -R "$(APP)" "$(INSTALL_DIR)/"; \
	codesign --verify --strict --verbose=1 "$(INSTALL_DIR)/$(APP)"; \
	echo "Installed $(INSTALL_DIR)/$(APP)"; \
	open "$(INSTALL_DIR)/$(APP)"; echo "Launched."
# A login item records the exact path it was registered from.
	@if ! "$(INSTALL_DIR)/$(APP)/Contents/MacOS/$(EXE_NAME)" --login-item-status 2>/dev/null \
		| grep -q "$(INSTALL_DIR)/$(APP)"; then \
		echo "To open at login from here: \"$(INSTALL_DIR)/$(APP)/Contents/MacOS/$(EXE_NAME)\" --enable-login-item"; \
	fi

.PHONY: screenshots
screenshots: install ## Regenerate docs/screenshots from sample data (never real companies)
# Run from /Applications so paths in the pictures are the installed ones.
	"$(INSTALL_DIR)/$(APP)/Contents/MacOS/$(EXE_NAME)" --demo "$(abspath docs/screenshots)"

.PHONY: status
status: ## Print configuration (never secrets)
	@if [ -x "$(INSTALL_DIR)/$(APP)/Contents/MacOS/$(EXE_NAME)" ]; then \
		"$(INSTALL_DIR)/$(APP)/Contents/MacOS/$(EXE_NAME)" --status; \
	else $(SWIFT) build && .build/debug/QBOBar --status; fi

.PHONY: identities
identities: ## Show available code signing identities
	@security find-identity -v -p codesigning

.PHONY: clean
clean: ## Remove build products (keeps the Intuit server checkout)
	$(SWIFT) package clean
	rm -rf "$(APP)" QBOBar.app $(SERVER_STAGE)
