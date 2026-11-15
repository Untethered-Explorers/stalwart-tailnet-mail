#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 McFuzzySquirrel
# SPDX-License-Identifier: MIT
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${HOME}/.local/bin"
INSTALL_PATH="${INSTALL_DIR}/tailmail"

if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required." >&2
    exit 1
fi

mkdir -p "$INSTALL_DIR"
install -m 0755 "$SCRIPT_DIR/tailmail.py" "$INSTALL_PATH"
echo "Installed $INSTALL_PATH"

case ":$PATH:" in
    *":$INSTALL_DIR:"*) ;;
    *)
        echo "Add $INSTALL_DIR to PATH to run 'tailmail' directly."
        ;;
esac

exec "$INSTALL_PATH" configure
