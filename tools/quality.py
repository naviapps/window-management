"""Run the pinned shared first-party lint and formatting policy."""

from pathlib import Path

from _tooling import load

if __name__ == "__main__":
    raise SystemExit(load("quality").main(root=Path(__file__).resolve().parents[1]))
