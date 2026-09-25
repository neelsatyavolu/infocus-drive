#!/bin/sh
# Install the InFocus Drive CLI (`infocus`) for the current macOS user.
#   curl -fsSL <drive>/cli/install.sh | sh
# Optional: INFOCUS_VERSION=1.2.3 to pin a release, INFOCUS_BIN_DIR to choose the install folder.
set -eu

INFOCUS_SERVER='__INFOCUS_SERVER__'
REPO="neelsatyavolu/infocus-drive"
ASSET="infocus-darwin-universal.tar.gz"
BIN_DIR="${INFOCUS_BIN_DIR:-$HOME/.local/bin}"
CONFIG_DIR="$HOME/.config/infocus"

fail() { printf 'infocus install: %s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "only macOS is supported for now."
command -v curl >/dev/null 2>&1 || fail "curl is required."
command -v shasum >/dev/null 2>&1 || fail "shasum is required."

if [ -n "${INFOCUS_DOWNLOAD_BASE:-}" ]; then
  BASE="$INFOCUS_DOWNLOAD_BASE" # local testing only: checksums come from the same place
elif [ -n "${INFOCUS_VERSION:-}" ]; then
  BASE="https://github.com/$REPO/releases/download/cli-v$INFOCUS_VERSION"
else
  BASE="https://github.com/$REPO/releases/latest/download"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

printf 'Downloading infocus…\n'
curl -fsSL "$BASE/$ASSET" -o "$TMP/$ASSET" || fail "download failed ($BASE/$ASSET)."
curl -fsSL "$BASE/SHA256SUMS" -o "$TMP/SHA256SUMS" || fail "checksum download failed."
(cd "$TMP" && grep " $ASSET\$" SHA256SUMS | shasum -a 256 -c - >/dev/null) \
  || fail "checksum mismatch — refusing to install."

tar -xzf "$TMP/$ASSET" -C "$TMP" infocus || fail "archive is missing the infocus binary."
mkdir -p "$BIN_DIR" "$CONFIG_DIR"
install -m 0755 "$TMP/infocus" "$BIN_DIR/infocus"

if [ ! -f "$CONFIG_DIR/config.json" ]; then
  umask 077
  printf '{\n  "server": "%s"\n}\n' "$INFOCUS_SERVER" > "$CONFIG_DIR/config.json"
fi

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    PROFILE="$HOME/.zshrc"
    LINE="export PATH=\"$BIN_DIR:\$PATH\""
    if ! grep -qsF "$LINE" "$PROFILE"; then
      printf '\n# InFocus Drive CLI\n%s\n' "$LINE" >> "$PROFILE"
      printf 'Added %s to PATH in %s (open a new terminal to pick it up).\n' "$BIN_DIR" "$PROFILE"
    fi
    ;;
esac

"$BIN_DIR/infocus" version
printf '\nInstalled. Next: run  infocus login\n'
