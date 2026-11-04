.PHONY: all bootstrap project open build test run clean models models-coreml-tiny help dmg release-build e2e package-test bundle-diarization verify-ane app app-debug sign-app

XCODEPROJ := Mila.xcodeproj
SCHEME := Mila

# ─────────────────────────────────────────────────────────────────────────────
# Local-only layout (personal fork): everything this build compiles, downloads
# or caches stays inside this folder. Nothing is written to ~/Library.
#
#   build/                Debug derived data — products, intermediate objects,
#                         module cache, index store, build/test logs, .xcresults
#   build-release/        Release derived data (what `make dmg` packages)
#   .local/SourcePackages/  Remote SPM packages (Sparkle, MCP) — cloned once and
#                         shared by Debug and Release. Without
#                         -clonedSourcePackagesDirPath these land in
#                         ~/Library/Developer/Xcode/DerivedData/SourcePackages.
#   .local/swiftpm-*/     SwiftPM's shared cache / config / security data for
#                         `swift test` + `swift run` in Packages/. Default is
#                         ~/Library/Caches/org.swift.swiftpm + ~/Library/org.swift.swiftpm.
#   .local/python-*/      pip wheel cache + temp tree for `make bundle-diarization`
#                         (its own tarball cache already lives in
#                         build/python-bundle-cache/).
#
# NOT relocated on purpose (runtime data the app itself reads, not build output):
#   ~/Library/Application Support/Mila/Models   (whisper weights; `make models`)
#   ~/.cache/whisper-{models,coreml-test}/      (test fixtures; `make models-coreml-tiny`)
# The SwiftPM *repository* cache (git clones) still lives in
# ~/Library/Caches/org.swift.swiftpm and stays small; pass
# -disablePackageRepositoryCache to XC_PACKAGE_CACHE below for a zero footprint
# at the cost of re-fetching Sparkle + MCP on every build.
#
# Optional, deliberately OFF: uncomment to also pull swiftc/xcodebuild's
# short-lived temp files out of /var/folders (they are deleted on exit).
#   export TMPDIR := $(CURDIR)/$(LOCAL)/tmp
#   # plus: @mkdir -p "$(TMPDIR)" in the recipes that need it
# ─────────────────────────────────────────────────────────────────────────────
DERIVED := build
RELEASE_DERIVED := build-release
LOCAL := .local
SOURCE_PACKAGES := $(LOCAL)/SourcePackages

# Appended to every xcodebuild invocation (alongside -derivedDataPath).
XC_PACKAGE_CACHE := -clonedSourcePackagesDirPath $(SOURCE_PACKAGES)

# Appended to every `swift test` / `swift run` in Packages/* (scratch dirs stay
# at each package's own Packages/*/.build, which is already inside the repo).
SWIFTPM_LOCAL := --cache-path $(LOCAL)/swiftpm-cache \
                --config-path $(LOCAL)/swiftpm-config \
                --security-path $(LOCAL)/swiftpm-security

APP := $(DERIVED)/Build/Products/Debug/Mila.app
RELEASE_APP := $(RELEASE_DERIVED)/Build/Products/Release/Mila.app

# Code-signing identity for `make app` / `make app-debug`. A self-signed cert
# never shows up as a "trusted identity", so sign-app resolves it to its SHA-1
# by name — the same trick scripts/make-dmg.sh uses. TCC keys mic / screen-
# recording grants on the signing identity, so keeping one stable cert means you
# approve those permissions once instead of after every rebuild.
# Override per run: make app CODESIGN_IDENTITY="Some Other Cert"
CODESIGN_IDENTITY ?= edrta913-local-dev
ENTITLEMENTS := Mila/Resources/Mila.entitlements
VERSION ?= $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Mila/Resources/Info.plist 2>/dev/null || echo "0.0.0")
DMG := Mila-$(VERSION).dmg
XCODE_DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
DEVELOPER_DIR ?= $(shell if [ -d "$(XCODE_DEVELOPER_DIR)" ]; then echo "$(XCODE_DEVELOPER_DIR)"; else xcode-select -p 2>/dev/null; fi)
export DEVELOPER_DIR

all: project

help:
	@echo "Targets:"
	@echo "  bootstrap     - Install xcodegen if missing"
	@echo "  project       - Generate the Xcode project from project.yml"
	@echo "  open          - Open the Xcode project"
	@echo "  build         - Debug build via xcodebuild"
	@echo "  app           - Release build, signed with $(CODESIGN_IDENTITY), NO dmg (the everyday target)"
	@echo "  app-debug     - Same but the Debug configuration (faster incremental builds)"
	@echo "  sign-app      - Re-sign an already-built .app in place (APP_PATH=<path/Mila.app>)"
	@echo "  release-build - Release build into $(RELEASE_DERIVED)"
	@echo "  test          - Run the MilaTests XCTest target"
	@echo "  run           - Build and launch the app"
	@echo "  models        - Pre-download both ggml models into ~/Library/Application Support/Mila/Models"
	@echo "  models-coreml-tiny - Download ggml-tiny + sibling -encoder.mlmodelc into ~/.cache/whisper-coreml-test/ (for CI ANE verification test)"
	@echo "  dmg           - Build a release DMG (VERSION=<x.y.z>) suitable for upload"
	@echo "  e2e           - Run E2E transcription tests (requires ggml-tiny.bin)"
	@echo "  package-test  - Run TranscriptionCore + MilaKit package unit tests"
	@echo "  bundle-diarization - Produce the bundled Python + pyannote.audio runtime under Mila/Resources/PythonRuntime/"
	@echo "  clean         - Remove generated project, build artifacts and .local caches"
	@echo ""
	@echo "Local layout (nothing outside this folder):"
	@echo "  build/, build-release/       xcodebuild derived data + logs + .xcresults"
	@echo "  .local/SourcePackages/       Sparkle + MCP package checkouts (Debug and Release share one)"
	@echo "  .local/swiftpm-*/            SwiftPM cache/config/security for Packages/* tests"
	@echo "  .local/python-*/             pip cache + temp tree for make bundle-diarization"

bootstrap:
	@command -v xcodegen >/dev/null 2>&1 || { \
		echo "Installing xcodegen via Homebrew..."; \
		brew install xcodegen; \
	}

check-xcode:
	@if [ "$(DEVELOPER_DIR)" = "/Library/Developer/CommandLineTools" ] || [ -z "$(DEVELOPER_DIR)" ] || [ ! -d "$(DEVELOPER_DIR)" ]; then \
		echo "Full Xcode is required. Install Xcode, then run sudo xcode-select -s $(XCODE_DEVELOPER_DIR)" >&2; \
		exit 1; \
	fi

project: bootstrap
	@# PythonRuntime is a .gitignored folder reference (see project.yml). It is
	@# only populated by `make bundle-diarization`. XcodeGen's `optional: true`
	@# suppresses generation errors but still emits the copy-resources phase, so
	@# xcodebuild fails on the missing path. Ensure an (empty) dir exists; the app
	@# detects no bundled python and falls back to system python automatically.
	@mkdir -p Mila/Resources/PythonRuntime
	xcodegen generate

open: project
	open $(XCODEPROJ)

build: project check-xcode
	mkdir -p $(SOURCE_PACKAGES)
	xcodebuild -project $(XCODEPROJ) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) $(XC_PACKAGE_CACHE) -destination 'platform=macOS' build

release-build: project check-xcode
	mkdir -p $(SOURCE_PACKAGES)
	xcodebuild -project $(XCODEPROJ) -scheme $(SCHEME) -configuration Release -derivedDataPath $(RELEASE_DERIVED) $(XC_PACKAGE_CACHE) -destination 'platform=macOS' build

test: project check-xcode
	mkdir -p $(SOURCE_PACKAGES)
	xcodebuild -project $(XCODEPROJ) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) $(XC_PACKAGE_CACHE) -destination 'platform=macOS' test

run: build
	open $(APP)

# ── Signed .app, no disk image ───────────────────────────────────────────────
# `dmg` is the only target that produces a DMG and nothing runs it automatically.
app: release-build
	@$(MAKE) --no-print-directory sign-app APP_PATH="$(RELEASE_APP)"

app-debug: build
	@$(MAKE) --no-print-directory sign-app APP_PATH="$(APP)"

# Two passes, copied from scripts/make-dmg.sh on purpose: --deep first so the
# nested code (mila-mcp, Sparkle.framework) gets its own signature, then the
# OUTER bundle re-signed with the entitlements — one --deep sign with
# --entitlements would stamp the app's entitlements onto every nested
# framework. Falls back to ad-hoc if the named cert isn't in any keychain, so a
# missing cert warns instead of failing the build.
APP_PATH ?= $(RELEASE_APP)
sign-app:
	@if [ ! -d "$(APP_PATH)" ]; then \
		echo "no app at $(APP_PATH) — build it first" >&2; exit 1; \
	fi
	@IDENTITY="$(CODESIGN_IDENTITY)"; \
	if [ "$$IDENTITY" != "-" ]; then \
		SHA=$$(security find-certificate -c "$$IDENTITY" -a -Z 2>/dev/null \
			| awk '/SHA-1 hash/ {print $$NF; exit}'); \
		if [ -n "$$SHA" ]; then \
			IDENTITY="$$SHA"; \
		else \
			echo "warning: no '$$IDENTITY' cert found in the keychain search list;" >&2; \
			echo "         ad-hoc signing — TCC will re-prompt for mic/recording." >&2; \
			IDENTITY="-"; \
		fi; \
	fi; \
	echo "==> signing $(APP_PATH) with $$IDENTITY"; \
	codesign --force --deep --sign "$$IDENTITY" "$(APP_PATH)"; \
	codesign --force --sign "$$IDENTITY" --entitlements "$(ENTITLEMENTS)" "$(APP_PATH)"; \
	codesign --verify --verbose=1 "$(APP_PATH)"; \
	codesign -d --entitlements - "$(APP_PATH)" 2>/dev/null | grep -q audio-input \
		|| echo "warning: entitlements missing com.apple.security.device.audio-input — system-audio capture will not work" >&2; \
	echo "==> $(APP_PATH)"

# Local (self-hosted) check: verify an upgrade doesn't recompile the CoreML/ANE
# encoder. Needs a real Neural Engine + an installed model + a GUI session, so
# it is NOT runnable on GitHub-hosted CI. See scripts/verify-ane-cache.sh.
verify-ane:
	./scripts/verify-ane-cache.sh

models:
	@mkdir -p "$(HOME)/Library/Application Support/Mila/Models"
	@echo "Downloading ivrit-ai/whisper-large-v3-ggml (~3GB). Press Ctrl-C to abort."
	curl -L --fail --progress-bar \
		"https://huggingface.co/ivrit-ai/whisper-large-v3-ggml/resolve/main/ggml-model.bin" \
		-o "$(HOME)/Library/Application Support/Mila/Models/ivrit-ai-whisper-large-v3.bin"
	@echo "Downloading openai/whisper-large-v3-turbo (~1.6GB). Press Ctrl-C to abort."
	curl -L --fail --progress-bar \
		"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin" \
		-o "$(HOME)/Library/Application Support/Mila/Models/openai-whisper-large-v3-turbo.bin"
	@echo "Done. Models installed."

dmg: release-build
	@./scripts/make-dmg.sh "$(RELEASE_APP)" "$(DMG)" "$(VERSION)"

e2e:
	mkdir -p $(LOCAL)/swiftpm-cache $(LOCAL)/swiftpm-config $(LOCAL)/swiftpm-security
	cd Packages/TranscriptionCore && swift run whisper-e2e $(SWIFTPM_LOCAL) \
		--model $(HOME)/.cache/whisper-models/ggml-tiny.bin \
		--fixtures Fixtures \
		--max-wer 0.3

# Download `ggml-tiny.bin` + sibling `ggml-tiny-encoder.mlmodelc` for the
# CoreML/ANE verification test (`WhisperEngineCoreMLTests`). Both go to
# `~/.cache/whisper-coreml-test/` so a CI cache step can persist them
# across runs. The .bin is ~75 MB; the .mlmodelc.zip is ~40 MB.
COREML_TEST_DIR := $(HOME)/.cache/whisper-coreml-test
models-coreml-tiny:
	@mkdir -p "$(COREML_TEST_DIR)"
	@if [ ! -f "$(COREML_TEST_DIR)/ggml-tiny.bin" ]; then \
		echo "Downloading ggml-tiny.bin (~75MB)..."; \
		curl -L --fail --progress-bar \
			"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin" \
			-o "$(COREML_TEST_DIR)/ggml-tiny.bin"; \
	fi
	@if [ ! -d "$(COREML_TEST_DIR)/ggml-tiny-encoder.mlmodelc" ]; then \
		echo "Downloading ggml-tiny-encoder.mlmodelc.zip (~40MB)..."; \
		curl -L --fail --progress-bar \
			"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny-encoder.mlmodelc.zip" \
			-o "$(COREML_TEST_DIR)/ggml-tiny-encoder.mlmodelc.zip"; \
		cd "$(COREML_TEST_DIR)" && unzip -q ggml-tiny-encoder.mlmodelc.zip && rm -rf __MACOSX ggml-tiny-encoder.mlmodelc.zip; \
	fi
	@echo "Ready: $(COREML_TEST_DIR)/ggml-tiny.bin (+ sibling .mlmodelc)"

package-test:
	@mkdir -p $(LOCAL)/swiftpm-cache $(LOCAL)/swiftpm-config $(LOCAL)/swiftpm-security
	cd Packages/TranscriptionCore && swift test $(SWIFTPM_LOCAL)
	cd Packages/MilaKit && swift test $(SWIFTPM_LOCAL)

# Produces Mila/Resources/PythonRuntime/ — a relocatable Python
# 3.11 with pyannote.audio (and deps) pre-installed, minus torch which
# DiarizationBootstrap downloads at first launch. Cached: re-running is
# fast if `python-bundle-cache/` is populated. The output is ~150-200 MB
# uncompressed and is NOT checked into git (see .gitignore). CI fetches
# the produced bundle from an actions/cache entry keyed on the script
# hash; dev machines run this once.
bundle-diarization:
	@# PBS tarball cache is already in-project (build/python-bundle-cache/). Redirect
	@# pip's wheel/download cache and the script's mktemp() staging tree, both of
	@# which default to ~/Library/Caches/pip and /var/folders/... respectively.
	@mkdir -p "$(CURDIR)/$(LOCAL)/pip-cache" "$(CURDIR)/$(LOCAL)/python-tmp"
	@PIP_CACHE_DIR="$(CURDIR)/$(LOCAL)/pip-cache" TMPDIR="$(CURDIR)/$(LOCAL)/python-tmp" \
		bash scripts/build-diarization-bundle.sh

clean:
	rm -rf $(XCODEPROJ) $(DERIVED) $(RELEASE_DERIVED) $(LOCAL) Packages/*/.build Mila-*.dmg
