#!/usr/bin/env bash
#
# 05-install-cli.sh — fetch the Stalwart CLI into migrate/bin (no root needed).
# The CLI talks to the management API over HTTP, so it needs no system install.
#
# Usage:  bash migrate/05-install-cli.sh

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HERE/bin"
CLI_VERSION="1.0.14"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

case "$(uname -m)" in
    aarch64|arm64) TARGET="aarch64-unknown-linux-gnu" ;;
    x86_64|amd64)  TARGET="x86_64-unknown-linux-gnu" ;;
    *) die "unsupported architecture: $(uname -m)" ;;
esac

ASSET="stalwart-cli-${TARGET}.tar.xz"
BASE="https://github.com/stalwartlabs/cli/releases/download/v${CLI_VERSION}"

mkdir -p "$BIN_DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log "Downloading stalwart-cli ${CLI_VERSION} (${TARGET})"
curl -fsSL "$BASE/$ASSET" -o "$TMP/$ASSET"
curl -fsSL "$BASE/$ASSET.sha256" -o "$TMP/$ASSET.sha256"

log "Verifying checksum"
( cd "$TMP" && sha256sum -c "$ASSET.sha256" )

log "Installing"
tar -xJf "$TMP/$ASSET" -C "$TMP"
BINARY="$(find "$TMP" -maxdepth 3 -type f -name stalwart-cli | head -n1)"
[[ -n $BINARY ]] || die "stalwart-cli binary not found in the archive"
install -m 0755 "$BINARY" "$BIN_DIR/stalwart-cli"

"$BIN_DIR/stalwart-cli" --version
info "$BIN_DIR/stalwart-cli"
