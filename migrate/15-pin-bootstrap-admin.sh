#!/usr/bin/env bash
#
# 15-pin-bootstrap-admin.sh — replace the one-time bootstrap password with a
# known credential, before the setup wizard.
# Run as root:  sudo bash migrate/15-pin-bootstrap-admin.sh
#
# Stalwart generates a random administrator password at every start while no
# configuration exists, and prints it only once. Setting
# STALWART_RECOVERY_ADMIN in the environment file pins a credential instead,
# which is also reused later for recovery mode.
#
# The password is written to /root/stalwart-recovery-password (0600), the same
# file 20-recovery-on.sh reuses.

set -euo pipefail

ENV_FILE=/etc/stalwart/stalwart.env
PW_FILE=/root/stalwart-recovery-password

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "run with sudo: sudo bash $0"
[[ -f $ENV_FILE ]] || die "$ENV_FILE is missing — run 10-install-stalwart.sh first"

if [[ -s $PW_FILE ]]; then
    PW="$(cat "$PW_FILE")"
    info "reusing $PW_FILE"
else
    PW="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-24)"
    ( umask 077; printf '%s\n' "$PW" > "$PW_FILE" )
    chmod 0600 "$PW_FILE"
    info "generated a pinned bootstrap password"
fi

log "Pinning the bootstrap administrator"
python3 - "$ENV_FILE" "$PW" <<'PY'
import re, sys
path, pw = sys.argv[1], sys.argv[2]
out, seen = [], False
for line in open(path).read().splitlines():
    if re.match(r"^#?\s*STALWART_RECOVERY_ADMIN=", line):
        out.append(f"STALWART_RECOVERY_ADMIN=admin:{pw}")
        seen = True
    elif re.match(r"^#?\s*STALWART_RECOVERY_MODE=", line):
        out.append("# STALWART_RECOVERY_MODE=1")   # stay in bootstrap mode
    else:
        out.append(line)
if not seen:
    out.append(f"STALWART_RECOVERY_ADMIN=admin:{pw}")
open(path, "w").write("\n".join(out) + "\n")
PY
chown root:stalwart "$ENV_FILE"
chmod 0640 "$ENV_FILE"

log "Restarting Stalwart in bootstrap mode"
systemctl restart stalwart.service
for _ in $(seq 1 30); do
    systemctl is-active --quiet stalwart.service && break
    sleep 1
done
systemctl is-active --quiet stalwart.service \
    || { journalctl -u stalwart -n 40 --no-pager; die "stalwart failed to start"; }

for _ in $(seq 1 20); do
    curl -fsS -o /dev/null http://127.0.0.1:8080/ 2>/dev/null && break
    sleep 0.5
done

TS_IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"

cat <<EOF

$(printf '\033[1;32mBootstrap administrator pinned\033[0m')

  username : admin
  password : $PW
  file     : $PW_FILE

  Open the wizard:
    ssh -L 8080:127.0.0.1:8080 mcsquirrel@${TS_IP:-<tailnet-ip>}
    http://localhost:8080/admin

  Wizard answers:
    Server hostname          : mcsquirrel.tailc7d454.ts.net
    Default email domain     : mcsquirrel.tailc7d454.ts.net
    Automatically obtain TLS : OFF
    Storage                  : RocksDB, /var/lib/stalwart/
    Directory                : Use the internal directory
    Logging                  : Log file, ANSI colours off
    DNS management           : Manual

  Then:
    sudo bash ${BASH_SOURCE[0]%/*}/20-recovery-on.sh

EOF
