SDK_TOOLING ?= mise run sdk-tooling --
SWIFT_STRICT_FLAGS := -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors

.DEFAULT_GOAL := check

.PHONY: check check-source test-managed check-distribution build build-release format lint test test-consumer test-installed-consumers native native-verify test-rust test-docs test-dotnet test-c test-distribution-tools

check: check-source test test-consumer

check-source: lint test-rust test-managed

check-distribution: native-verify build-release test-docs test-distribution-tools test-installed-consumers test-c test-dotnet

build:
	swift build $(SWIFT_STRICT_FLAGS)

build-release:
	swift build -c release $(SWIFT_STRICT_FLAGS)

format:
	mise run format

lint:
	mise run lint

test:
	swift test $(SWIFT_STRICT_FLAGS)

test-consumer:
	$(SDK_TOOLING) swift-consumer

test-installed-consumers:
	$(SDK_TOOLING) installed-consumers

native:
	$(SDK_TOOLING) native

native-verify:
	$(SDK_TOOLING) native --verify

test-rust:
	cargo clippy --workspace --all-targets --locked --offline -- -D warnings
	cargo test --workspace --locked --offline

test-dotnet:
	$(SDK_TOOLING) binding-consumer dotnet

test-c:
	$(SDK_TOOLING) binding-consumer c

test-docs:
	$(SDK_TOOLING) docs

test-distribution-tools:
	$(SDK_TOOLING) python -m unittest discover -s distribution/tests -v

test-managed:
	dotnet build --configuration Release bindings/dotnet/tests/NaviApps.WindowManagement.Tests/NaviApps.WindowManagement.Tests.csproj
