TESTING_PLUGINS := /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
# Command Line Tools ship Swift Testing's macro plugin outside the default
# search path; full Xcode does not need this.
TEST_FLAGS := $(if $(wildcard $(TESTING_PLUGINS)),-Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS))

.PHONY: build test app debug run check clean

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
	shellcheck Scripts/*.sh

clean:
	rm -rf .build build
