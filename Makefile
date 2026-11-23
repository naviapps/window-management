SWIFT_STRICT_FLAGS := -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors

.DEFAULT_GOAL := check

.PHONY: check build build-release format lint test test-consumer test-installed-consumers native native-verify test-rust test-docs test-dotnet test-c test-windows-tool

check: lint native-verify build-release test test-consumer test-rust test-docs test-windows-tool

build:
	swift build $(SWIFT_STRICT_FLAGS)

build-release:
	swift build -c release $(SWIFT_STRICT_FLAGS)

format:
	mise exec -- python3 -B tools/quality.py format --dotnet

lint:
	mise exec -- python3 -B tools/quality.py check --dotnet

test:
	swift test $(SWIFT_STRICT_FLAGS)

test-consumer:
	python3 -B tools/consumer.py

test-installed-consumers:
	python3 -B tools/install-consumers.py

native:
	python3 tools/native.py

native-verify:
	python3 tools/native.py --verify

test-rust:
	cargo clippy --workspace --all-targets --locked --offline -- -D warnings
	cargo test --workspace --locked --offline

test-dotnet:
	python3 tools/test-dotnet.py

test-c:
	python3 tools/test-c.py

test-docs:
	python3 tools/test-docs.py

test-windows-tool:
	python3 -B -m unittest discover -s tools/tests -v
