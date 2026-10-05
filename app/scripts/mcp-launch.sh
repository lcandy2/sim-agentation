# The plugins' MCP server: sim-agentation's own `mcp`, from wherever it is.
# Not run from this file: app/scripts/plugins.py writes it inline into each
# plugin's MCP config (none of the agents give a plugin a path to itself),
# with VERSION replaced by Config.version. It must stay quiet on stdout,
# which carries the MCP protocol.
#
# A build of your own (SIM_AGENTATION_BIN) wins. Then this version: already
# downloaded, or installed (Homebrew, PATH). Then it's downloaded from the
# GitHub release, checked against the release's .sha256, and unpacked into
# ~/Library/Caches/sim-agentation. Offline, any installed version will do.
v=VERSION
[ -n "$SIM_AGENTATION_BIN" ] && exec "$SIM_AGENTATION_BIN" mcp
cache="$HOME/Library/Caches/sim-agentation/release/$v"
own="$cache/sim-agentation-$v/bin/sim-agentation"
[ -x "$own" ] && exec "$own" mcp
found=
for b in "$(command -v sim-agentation 2>/dev/null)" /opt/homebrew/bin/sim-agentation /usr/local/bin/sim-agentation; do
  [ -n "$b" ] && [ -x "$b" ] || continue
  [ "$("$b" version 2>/dev/null)" = "$v" ] && exec "$b" mcp
  [ -n "$found" ] || found=$b
done
base=$SIM_AGENTATION_RELEASES
[ -n "$base" ] || base=https://github.com/lcandy2/sim-agentation/releases/download
tarball="sim-agentation-$v-macos-arm64.tar.gz"
part=$(mktemp -d)
if mkdir -p "$cache" &&
  curl -fsSL "$base/$v/$tarball" -o "$part/$tarball" &&
  curl -fsSL "$base/$v/$tarball.sha256" -o "$part/$tarball.sha256" &&
  (cd "$part" && shasum -a 256 -c "$tarball.sha256" >/dev/null) &&
  tar -xzf "$part/$tarball" -C "$part" &&
  mv "$part/sim-agentation-$v" "$cache/" 2>/dev/null; [ -x "$own" ]; then
  exec "$own" mcp
fi
[ -n "$found" ] && exec "$found" mcp
echo "sim-agentation $v couldn't be downloaded, and none is installed: brew install lcandy2/tap/sim-agentation" >&2
exit 1
