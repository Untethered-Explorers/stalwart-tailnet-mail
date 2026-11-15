#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 McFuzzySquirrel
# SPDX-License-Identifier: MIT
set -Eeuo pipefail

ports=(25 465 587 993 443)
tailnet_ip=""

command -v tailscale >/dev/null 2>&1 || {
    echo "Tailscale is not installed." >&2
    exit 1
}

for _ in {1..180}; do
    tailnet_ip="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
    if [[ $tailnet_ip =~ ^100\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        break
    fi
    sleep 1
done

if [[ ! $tailnet_ip =~ ^100\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Tailscale did not provide an IPv4 address within 180 seconds." >&2
    exit 1
fi

listeners_ready() {
    local sockets port
    sockets="$(ss -ltnH | awk '{print $4}')"
    for port in "${ports[@]}"; do
        grep -qxF "$tailnet_ip:$port" <<<"$sockets" || return 1
    done
}

if listeners_ready; then
    echo "Stalwart is already listening on $tailnet_ip."
    exit 0
fi

echo "Restarting Stalwart after Tailscale became available at $tailnet_ip."
systemctl restart stalwart.service || {
    echo "Could not restart stalwart.service." >&2
    exit 1
}

for _ in {1..30}; do
    if listeners_ready; then
        echo "Stalwart is listening on $tailnet_ip."
        exit 0
    fi
    sleep 1
done

echo "Stalwart is not listening on all expected ports at $tailnet_ip." >&2
exit 1
