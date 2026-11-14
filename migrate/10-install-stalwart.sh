#!/usr/bin/env bash
#
# 10-install-stalwart.sh — install Stalwart in bootstrap mode.
# Run as root:  sudo bash migrate/10-install-stalwart.sh
#
# Uses the official install script, which:
#   - downloads the latest release for this architecture (aarch64)
#   - creates the `stalwart` service account
#   - installs /usr/local/bin/stalwart and /etc/systemd/system/stalwart.service
#   - starts it in bootstrap mode, serving only the setup wizard on :8080
#
# It does not touch Dovecot or OpenSMTPD, and binds no mail ports until the
# wizard is submitted and the server is restarted (which we do in recovery
# mode instead, so the old stack keeps running).

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "run with sudo: sudo bash $0"

[[ -f /etc/systemd/system/stalwart.service ]] \
    && die "Stalwart is already installed. Use 'systemctl status stalwart' or the upgrade docs."

if ! dpkg -s opensmtpd dovecot-core >/dev/null 2>&1; then
    warn "the OpenSMTPD/Dovecot packages were not found in dpkg state"
fi

TS_IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
[[ -n $TS_IP ]] || warn "no Tailscale IPv4 address found"

TMP_SCRIPT="$(mktemp)"
trap 'rm -f "$TMP_SCRIPT"' EXIT

log "Downloading the official installer"
curl --proto '=https' --tlsv1.2 -fsSL https://get.stalw.art/install.sh -o "$TMP_SCRIPT"
info "sha256: $(sha256sum "$TMP_SCRIPT" | cut -d' ' -f1)"
info "installer: $TMP_SCRIPT (reviewable before it runs)"

log "Running the installer"
sh "$TMP_SCRIPT"

log "Waiting for the service"
for _ in $(seq 1 30); do
    systemctl is-active --quiet stalwart.service && break
    sleep 1
done
systemctl is-active --quiet stalwart.service \
    || { journalctl -u stalwart -n 40 --no-pager; die "stalwart failed to start"; }

info "version: $(/usr/local/bin/stalwart --version 2>/dev/null || echo unknown)"

log "Bootstrap credentials"
journalctl -u stalwart -n 500 --no-pager 2>/dev/null \
    | grep -B6 -A6 -i 'temporary administrator' | tail -n 20 || true

log "Setup listener"
ss -ltnH | grep ':8080' || warn "nothing is listening on 8080 yet; check journalctl -u stalwart"

cat <<EOF

$(printf '\033[1;32mNext: complete the setup wizard\033[0m')

  1. From your laptop, tunnel the loopback port over SSH:
       ssh -L 8080:127.0.0.1:8080 mcsquirrel@${TS_IP:-<tailnet-ip>}

  2. Open http://localhost:8080/admin and sign in as
       admin / <the password printed above>

  3. Wizard answers:
       Server hostname          : mcsquirrel.tailc7d454.ts.net
       Default email domain     : mcsquirrel.tailc7d454.ts.net
       Automatically obtain TLS : OFF  (we install the Tailscale cert next)
       Generate signing keys    : leave at its default
       Storage                  : RocksDB, /var/lib/stalwart/
       Directory                : Use the internal directory
       Logging                  : Log file, ANSI colours off
       DNS management           : Manual

  4. Save the administrator account the wizard shows, then return here and run
       sudo bash ${HERE}/20-recovery-on.sh

EOF
