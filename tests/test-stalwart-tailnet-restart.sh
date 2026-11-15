#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 McFuzzySquirrel
# SPDX-License-Identifier: MIT
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
MOCK_BIN="$TMP_DIR/bin"
TEST_STATE="$TMP_DIR/state"
cleanup() {
    rm -f "$MOCK_BIN/tailscale" "$MOCK_BIN/ss" "$MOCK_BIN/systemctl" \
        "$MOCK_BIN/sleep" "$TEST_STATE/restarted"
    rmdir "$MOCK_BIN" "$TEST_STATE" "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$MOCK_BIN"

cat > "$MOCK_BIN/tailscale" <<'EOF'
#!/usr/bin/env bash
printf '100.64.10.20\n'
EOF

cat > "$MOCK_BIN/ss" <<'EOF'
#!/usr/bin/env bash
ports=(25 465 587 993 443)
if [[ ${TEST_MODE:-} == ready || -f "$TEST_STATE/restarted" ]]; then
    for port in "${ports[@]}"; do
        printf 'LISTEN 0 1024 100.64.10.20:%s 0.0.0.0:*\n' "$port"
    done
else
    printf 'LISTEN 0 1024 127.0.0.1:443 0.0.0.0:*\n'
fi
EOF

cat > "$MOCK_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
[[ $1 == restart && $2 == stalwart.service ]] || exit 2
touch "$TEST_STATE/restarted"
EOF

cat > "$MOCK_BIN/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$MOCK_BIN"/*
export PATH="$MOCK_BIN:$PATH"
export TEST_STATE
mkdir -p "$TEST_STATE"

TEST_MODE=ready "$ROOT_DIR/scripts/stalwart-tailnet-restart.sh"
[[ ! -e "$TEST_STATE/restarted" ]] || {
    echo "Expected no restart when all tailnet listeners are already present." >&2
    exit 1
}

TEST_MODE=missing "$ROOT_DIR/scripts/stalwart-tailnet-restart.sh"
[[ -e "$TEST_STATE/restarted" ]] || {
    echo "Expected Stalwart to restart when a tailnet listener is missing." >&2
    exit 1
}
