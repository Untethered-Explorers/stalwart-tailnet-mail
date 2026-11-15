#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 McFuzzySquirrel
# SPDX-License-Identifier: MIT
set -Eeuo pipefail

if (( EUID != 0 )); then
    echo "Run this installer with sudo." >&2
    exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

[[ -f /etc/systemd/system/stalwart.service ]] \
    || { echo "Stalwart's systemd service is not installed." >&2; exit 1; }
command -v tailscale >/dev/null 2>&1 \
    || { echo "Tailscale is not installed." >&2; exit 1; }

install -m 0755 "$SCRIPT_DIR/stalwart-tailnet-restart.sh" \
    /usr/local/sbin/stalwart-tailnet-restart
install -m 0644 "$PROJECT_DIR/systemd/stalwart-tailnet-restart.service" \
    /etc/systemd/system/stalwart-tailnet-restart.service

systemctl daemon-reload
systemctl enable --now stalwart-tailnet-restart.service
