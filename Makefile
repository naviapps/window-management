SDK_TOOLING ?= mise run sdk-tooling --
SWIFT_STRICT_FLAGS := -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors

.DEFAULT_GOAL := check

.PHONY: check check-source test-managed check-distribution build build-release format lint test test-consumer test-installed-consumers native native-verify test-rust test-docs test-dotnet test-c test-windows-tool

check: check-source test test-consumer

check-source: lint test-rust test-managed

check-distribution: native-verify build-release test-docs test-windows-tool

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
	mise run sdk-tooling -- swift-consumer

test-installed-consumers:
	mise run sdk-tooling -- installed-consumers

native:
	python3 tools/native.py

native-verify:
	python3 tools/native.py --verify

test-rust:
	cargo clippy --workspace --all-targets --locked --offline -- -D warnings
	cargo test --workspace --locked --offline

test-dotnet:
	$(SDK_TOOLING) binding-consumer dotnet

test-c:
	$(SDK_TOOLING) binding-consumer c

test-docs:
	mise run sdk-tooling -- docs

test-windows-tool:
	python3 -B -m unittest discover -s tools/tests -v

test-managed:
	dotnet build --configuration Release bindings/dotnet/tests/NaviApps.WindowManagement.Tests/NaviApps.WindowManagement.Tests.csproj
