# HoTH iOS build helpers. Requires Xcode + XcodeGen.
PROJECT      := ios/HoTH.xcodeproj
SCHEME       := HoTH
DERIVED_DATA := build/DerivedData
# First available iPhone simulator (override: make test SIM_ID=<udid>)
SIM_ID ?= $(shell xcrun simctl list devices available | grep -E '^\s+iPhone' | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')

.PHONY: gen build test clean

gen:
	cd ios && xcodegen generate

build: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'generic/platform=iOS Simulator' \
		-derivedDataPath $(DERIVED_DATA) build

test: gen
	@if [ -z "$(SIM_ID)" ]; then echo "No available iPhone simulator found (install an iOS runtime)."; exit 1; fi
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'platform=iOS Simulator,id=$(SIM_ID)' \
		-derivedDataPath $(DERIVED_DATA) test

clean:
	rm -rf $(DERIVED_DATA)
	rm -rf $(PROJECT)
