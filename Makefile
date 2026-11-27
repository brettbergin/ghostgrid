TESTING_PLUGINS := /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
# Command Line Tools ship Swift Testing's macro plugin outside the default
# search path; full Xcode does not need this.
TEST_FLAGS := $(if $(wildcard $(TESTING_PLUGINS)),-Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS))

.PHONY: build test app debug run check clean libghostty install uninstall release release-check cask

build:
	swift build

test:
	swift test $(TEST_FLAGS)

app:
	Scripts/bundle.sh release

debug:
	Scripts/bundle.sh debug

run: debug
	open build/ghostgrid.app

check: test app
	shellcheck Scripts/*.sh Scripts/gg

# Installs the release app into /Applications and gg into ~/.local/bin.
PREFIX_APP ?= /Applications
PREFIX_BIN ?= $(HOME)/.local/bin

install: app
	@if pgrep -xq GhostGrid; then echo "ghostgrid is running: quit it (Cmd+Q) and run make install again" >&2; exit 1; fi
	rm -rf "$(PREFIX_APP)/ghostgrid.app"
	cp -R build/ghostgrid.app "$(PREFIX_APP)/ghostgrid.app"
	mkdir -p "$(PREFIX_BIN)"
	install -m 0755 Scripts/gg "$(PREFIX_BIN)/gg"
	@echo "Installed $(PREFIX_APP)/ghostgrid.app and $(PREFIX_BIN)/gg"

uninstall:
	rm -rf "$(PREFIX_APP)/ghostgrid.app" "$(PREFIX_BIN)/gg"

# A signed, notarized build/release/ghostgrid-<version>.dmg for other Macs
# (Developer ID; one-time setup in README, "Releases").
release:
	Scripts/release.sh

# The same packaging signed ad hoc and not notarized: checks the release
# signing (hardened runtime, entitlements, DMG) without certificates.
release-check:
	GHOSTGRID_SIGN_IDENTITY=- Scripts/release.sh

# Points the Homebrew cask (../homebrew-tap) at the published release and
# commits it there.
cask:
	Scripts/update-cask.sh

# Local libghostty with custom shaders (needs Xcode + Zig); see README.
libghostty:
	Scripts/build-libghostty.sh

clean:
	rm -rf .build build
