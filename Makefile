APP      = NotesApp
SCHEME   = NotesApp
NAME     = Off the Record
DERIVED  = build
APP_PATH = $(DERIVED)/Build/Products/Debug/$(NAME).app
RELEASE_APP = $(DERIVED)/Build/Products/Release/$(NAME).app
VERSION  = $(shell awk -F'"' '/CFBundleShortVersionString/ {print $$2}' project.yml)

# Best signing identity on this Mac (see scripts/sign-identity.sh); override with SIGN_ID=...
SIGN_ID  ?= $(shell scripts/sign-identity.sh)
# Hardened runtime only with a Developer ID: its library validation rejects the app's own
# frameworks when the certificate has no Team ID (self-signed).
HARDENED = $(if $(findstring Developer ID,$(SIGN_ID)),YES,NO)
# Passed as project variables so only the app target uses them (package bundles stay unsigned).
SIGNING  = OTR_SIGN_ID="$(SIGN_ID)" OTR_HARDENED=$(HARDENED)

.PHONY: gen build run clean setup deps hinglish-models release dmg notarize

FLUIDAUDIO_TAG = v0.18.2

# Xcode 26 ignores SwiftPM package traits, so FluidAudio is vendored and its
# traits manifest removed; plain Package.swift then enables the Diarizer.
deps:           ## Vendor FluidAudio at $(FLUIDAUDIO_TAG)
	@if [ ! -d Vendor/FluidAudio ]; then \
	  git clone -q --depth 1 --branch $(FLUIDAUDIO_TAG) https://github.com/FluidInference/FluidAudio Vendor/FluidAudio; \
	  rm -f Vendor/FluidAudio/Package@swift-6.2.swift Vendor/FluidAudio/Package@swift-6.1.swift; \
	fi

gen: deps       ## Generate NotesApp.xcodeproj from project.yml
	xcodegen generate

build: gen      ## Debug build (ad-hoc signed, personal use)
	xcodebuild -project $(APP).xcodeproj -scheme $(SCHEME) -configuration Debug \
	  -derivedDataPath $(DERIVED) -destination 'platform=macOS,arch=arm64' $(SIGNING) build | tail -40

run: build      ## Build and launch
	open "$(APP_PATH)"

release: gen    ## Optimized build for distribution, signed with $(SIGN_ID)
	@echo "Signing with: $(SIGN_ID)"
	xcodebuild -project $(APP).xcodeproj -scheme $(SCHEME) -configuration Release \
	  -derivedDataPath $(DERIVED) -destination 'platform=macOS,arch=arm64' $(SIGNING) build | tail -5
	codesign --verify --deep --strict "$(RELEASE_APP)" && codesign -dv "$(RELEASE_APP)" 2>&1 | grep -E "Authority|Identifier=" | head -3

dmg: release    ## dist/Off the Record <version>.dmg
	scripts/make-dmg.sh "$(RELEASE_APP)" "$(VERSION)" "$(SIGN_ID)"

notarize:       ## Developer ID only: NOTARY_PROFILE=<notarytool keychain profile> make notarize
	xcrun notarytool submit "dist/$(NAME) $(VERSION).dmg" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "dist/$(NAME) $(VERSION).dmg"

clean:
	rm -rf $(DERIVED) $(APP).xcodeproj

distclean: clean
	rm -rf Vendor

setup:          ## One-time: Ollama + Gemma 4 e4b (about 6.6 GB)
	brew list ollama >/dev/null 2>&1 || brew install ollama
	ollama serve >/dev/null 2>&1 & sleep 2; ollama pull gemma4:e4b

hinglish-models: ## Convert Tara and Apex (Hinglish Whisper) for the app; ~4.7 GB download, ~30 min
	scripts/convert-hinglish.sh all
