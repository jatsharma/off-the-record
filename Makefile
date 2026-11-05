APP      = NotesApp
SCHEME   = NotesApp
DERIVED  = build
APP_PATH = $(DERIVED)/Build/Products/Debug/NotesApp.app

.PHONY: gen build run clean setup deps hinglish-models

FLUIDAUDIO_TAG = v0.18.2

# Xcode 26 ignores SwiftPM package traits, so FluidAudio is vendored and its
# traits manifest removed; plain Package.swift then enables the Diarizer.
# scripts/fluidaudio-qwen3.patch restores the Qwen3-ASR backend upstream removed
# in June 2026 (#676) and ports its downloader to the current ModelHub API.
deps:           ## Vendor FluidAudio at $(FLUIDAUDIO_TAG)
	@if [ ! -d Vendor/FluidAudio ]; then \
	  git clone -q --depth 1 --branch $(FLUIDAUDIO_TAG) https://github.com/FluidInference/FluidAudio Vendor/FluidAudio; \
	  rm -f Vendor/FluidAudio/Package@swift-6.2.swift Vendor/FluidAudio/Package@swift-6.1.swift; \
	  git -C Vendor/FluidAudio apply ../../scripts/fluidaudio-qwen3.patch; \
	fi

gen: deps       ## Generate NotesApp.xcodeproj from project.yml
	xcodegen generate

build: gen      ## Debug build (ad-hoc signed, personal use)
	xcodebuild -project $(APP).xcodeproj -scheme $(SCHEME) -configuration Debug \
	  -derivedDataPath $(DERIVED) -destination 'platform=macOS,arch=arm64' build | tail -40

run: build      ## Build and launch
	open $(APP_PATH)

clean:
	rm -rf $(DERIVED) $(APP).xcodeproj

distclean: clean
	rm -rf Vendor

setup:          ## One-time: Ollama + Qwen 3.5 4B (about 3.3 GB)
	brew list ollama >/dev/null 2>&1 || brew install ollama
	ollama serve >/dev/null 2>&1 & sleep 2; ollama pull qwen3.5:4b

hinglish-models: ## Convert Tara and Apex (Hinglish Whisper) for the app; ~4.7 GB download, ~30 min
	scripts/convert-hinglish.sh all
