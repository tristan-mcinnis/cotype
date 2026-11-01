# One entry point for agents and humans. Warnings are errors in build and test.
# Targets wrap scripts/; the scripts stay the source of truth.

SWIFT_FLAGS := -Xswiftc -warnings-as-errors

.PHONY: build test check app install

build:
	swift build $(SWIFT_FLAGS)

test:
	swift test $(SWIFT_FLAGS)

# Strict build and test, then the deterministic gate (debug + release builds, tests, bundle check).
check: build test
	./scripts/verify.sh

# Build, sign and version-stamp dist/Cotype.app. Does not install or launch.
app:
	./scripts/build-app.sh

# Install to ~/Applications and relaunch. Pass flags with ARGS, e.g. ARGS=--no-relaunch.
install:
	./scripts/install.sh $(ARGS)
