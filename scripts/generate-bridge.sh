#!/bin/sh
# Regenerates Sources/SwishCore/Bridge/StandardLibrary.swift from the
# standard library's symbol graph, for the toolchain in use. Run it after
# changing swish-bridge or the Swift toolchain.
set -e
cd "$(dirname "$0")/.."
graphs=$(mktemp -d)
trap 'rm -rf "$graphs"' EXIT
sdk=$(xcrun --show-sdk-path)
extract=$(xcrun --find swift-symbolgraph-extract)
"$extract" -module-name Swift -target arm64-apple-macosx14.0 -sdk "$sdk" -output-dir "$graphs"
swift run -c release swish-bridge "$graphs/Swift.symbols.json" Sources/SwishCore/Bridge/StandardLibrary.swift
