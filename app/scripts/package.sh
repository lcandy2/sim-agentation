#!/bin/sh
# Builds a release of the Mac side as one tarball: the host binary, the
# built UI, and the iPhone Duo helper's sources, laid out the way the
# binary looks for them (web/ found by walking up from bin/, and
# host/Guest beside web/).
#
#   app/scripts/package.sh   →   dist/sim-agentation-<version>-macos-arm64.tar.gz
set -eu
cd "$(dirname "$0")/../.."

version=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' app/host/Sources/sim-agentation/Config.swift)
name="sim-agentation-$version"
stage=$(mktemp -d)/$name

pnpm exec vite build
swift build -c release --package-path app/host --arch arm64

mkdir -p "$stage/bin" "$stage/web" "$stage/host/Guest" "$stage/licenses" dist
cp app/host/.build/release/sim-agentation "$stage/bin/"
cp -R app/web/dist "$stage/web/dist"
cp app/web/index.html "$stage/web/"          # what the binary looks for to find web/
cp -R app/host/Guest/HingeControl "$stage/host/Guest/"
cp LICENSE NOTICE "$stage/"
cp app/host/Sources/SimBridge/LICENSE-* "$stage/licenses/"

tarball="dist/$name-macos-arm64.tar.gz"
tar -C "$(dirname "$stage")" -czf "$tarball" "$name"
shasum -a 256 "$tarball"
