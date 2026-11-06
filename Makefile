APP      = NotesApp
SCHEME   = NotesApp
NAME     = Off the Record
DERIVED  = build
APP_PATH = $(DERIVED)/Build/Products/Debug/$(NAME).app
RELEASE_APP = $(DERIVED)/Build/Products/Release/$(NAME).app
VERSION  = $(shell awk -F'"' '/CFBundleShortVersionString/ {print $$2}' project.yml)

# Best signing identity on this Mac (see scripts/sign-identity.sh); override with SIGN_ID=...
SIGN_ID  ?= $(shell scripts/sign-identity.sh)
# Passed as a project variable so only the app target uses it (package bundles stay unsigned).
SIGNING  = OTR_SIGN_ID="$(SIGN_ID)"

.PHONY: gen build run test clean setup deps hinglish-models release dmg notarize update-packages

FLUIDAUDIO_TAG = v0.18.2
# The commit that tag pointed to when it was vendored: a moved tag stops the build.
FLUIDAUDIO_COMMIT = e396cf780c4abf8e395087467c0585d3b0d17f68

# Exact package versions (GRDB, WhisperKit and theirs), copied into the generated project;
# xcodebuild uses only these. Update with `make update-packages`.
RESOLVED = $(APP).xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
PINNED   = -onlyUsePackageVersionsFromResolvedFile

# Xcode 26 ignores SwiftPM package traits, so FluidAudio is vendored and its
# traits manifest removed; plain Package.swift then enables the Diarizer.
deps:           ## Vendor FluidAudio at $(FLUIDAUDIO_TAG)
	@if [ ! -d Vendor/FluidAudio ]; then \
	  git clone -q --depth 1 --branch $(FLUIDAUDIO_TAG) https://github.com/FluidInference/FluidAudio Vendor/FluidAudio; \
	  if [ "$$(git -C Vendor/FluidAudio rev-parse HEAD)" != "$(FLUIDAUDIO_COMMIT)" ]; then \
	    echo "FluidAudio $(FLUIDAUDIO_TAG) is no longer commit $(FLUIDAUDIO_COMMIT); not building with it."; \
	    mv Vendor/FluidAudio Vendor/FluidAudio.unexpected; exit 1; \
	  fi; \
	  rm -f Vendor/FluidAudio/Package@swift-6.2.swift Vendor/FluidAudio/Package@swift-6.1.swift; \
	fi

gen: deps       ## Generate NotesApp.xcodeproj from project.yml
	xcodegen generate
	mkdir -p "$(dir $(RESOLVED))" && cp Package.resolved "$(RESOLVED)"

update-packages: gen  ## Resolve packages to the newest versions project.yml allows and keep them
	xcodebuild -project $(APP).xcodeproj -scheme $(SCHEME) -derivedDataPath $(DERIVED) -resolvePackageDependencies | tail -5
	cp "$(RESOLVED)" Package.resolved

build: gen      ## Debug build (ad-hoc signed, personal use)
	xcodebuild -project $(APP).xcodeproj -scheme $(SCHEME) -configuration Debug $(PINNED) \
	  -derivedDataPath $(DERIVED) -destination 'platform=macOS,arch=arm64' $(SIGNING) build | tail -40

run: build      ## Build and launch
	open "$(APP_PATH)"

test: gen       ## Unit tests (the app starts as a bare process: no windows, data or settings touched)
	set -o pipefail; xcodebuild -project $(APP).xcodeproj -scheme $(SCHEME) -configuration Debug $(PINNED) \
	  -derivedDataPath $(DERIVED) -destination 'platform=macOS,arch=arm64' $(SIGNING) test 2>&1 \
	  | grep -E "Test Case .*(passed|failed)|error:|Executed|\*\* TEST" | grep -v "\[Connection\]" | tail -60

release: gen    ## Optimized build for distribution, signed with $(SIGN_ID)
	@echo "Signing with: $(SIGN_ID)"
	xcodebuild -project $(APP).xcodeproj -scheme $(SCHEME) -configuration Release $(PINNED) \
	  -derivedDataPath $(DERIVED) -destination 'platform=macOS,arch=arm64' $(SIGNING) build | tail -5
	codesign --verify --deep --strict "$(RELEASE_APP)" && codesign -dv "$(RELEASE_APP)" 2>&1 | grep -E "Authority|Identifier=" | head -3
	@codesign -dv "$(RELEASE_APP)" 2>&1 | grep -q "flags=.*runtime" || { echo "The hardened runtime is off in $(RELEASE_APP)"; exit 1; }
	@! codesign -d --entitlements - "$(RELEASE_APP)" 2>/dev/null | grep -q get-task-allow || { echo "$(RELEASE_APP) allows debuggers (get-task-allow)"; exit 1; }

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
