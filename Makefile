SDK_TOOLING ?= mise run sdk-tooling --
SWIFT_STRICT_FLAGS := -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors

.DEFAULT_GOAL := check

.PHONY: check check-source test-managed check-distribution build build-release clean format lint test test-consumer test-installed-consumers native native-verify test-rust test-dotnet test-c test-distribution-tools

check: check-source test test-consumer

check-source: lint test-rust test-managed

check-distribution: native-verify build-release test-distribution-tools test-installed-consumers test-c test-dotnet

build:
	swift build $(SWIFT_STRICT_FLAGS)

build-release:
	swift build -c release $(SWIFT_STRICT_FLAGS)

clean:
	$(SDK_TOOLING) clean .build target .native-build fixtures/consumers/swift/.build \
	  fixtures/acceptance/windows/host/bin fixtures/acceptance/windows/host/obj \
	  bindings/dotnet/src/NaviApps.WindowManagement/bin bindings/dotnet/src/NaviApps.WindowManagement/obj \
	  bindings/dotnet/tests/NaviApps.WindowManagement.Tests/bin bindings/dotnet/tests/NaviApps.WindowManagement.Tests/obj

format:
	mise run format

lint:
	mise run lint

test:
	swift test $(SWIFT_STRICT_FLAGS)

test-consumer:
	$(SDK_TOOLING) swift-consumer

test-installed-consumers:
	$(SDK_TOOLING) rust-c-consumers

native:
	$(SDK_TOOLING) xcframework

native-verify:
	$(SDK_TOOLING) xcframework --verify

test-rust:
	cargo clippy --workspace --all-targets --locked --offline -- -D warnings
	cargo test --workspace --locked --offline

test-dotnet:
	$(SDK_TOOLING) check-binding dotnet

test-c:
	$(SDK_TOOLING) check-binding c

test-distribution-tools:
	$(SDK_TOOLING) python -m unittest discover -s distribution/tests -v

test-managed:
	dotnet build --configuration Release bindings/dotnet/tests/NaviApps.WindowManagement.Tests/NaviApps.WindowManagement.Tests.csproj
