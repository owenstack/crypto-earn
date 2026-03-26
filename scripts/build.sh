#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"

echo "Building Zig engine..."
cd "$DIR/zig"
zig build -Doptimize=ReleaseFast

echo "Building TS control plane..."
cd "$DIR/ts"
bun install
bun run build

echo "Build complete."
