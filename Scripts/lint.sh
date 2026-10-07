#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"

if ! command -v swiftlint >/dev/null 2>&1; then
  echo "SwiftLint is required. Install it with: brew install swiftlint" >&2
  exit 127
fi

swiftlint lint --config .swiftlint.yml
