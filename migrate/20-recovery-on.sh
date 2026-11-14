#!/usr/bin/env bash
#
# 20-recovery-on.sh — switch Stalwart from bootstrap to recovery mode.
# Run as root:  sudo bash migrate/20-recovery-on.sh
#
# Run this only after the setup wizard has written /etc/stalwart/config.json.
#
# Recovery mode starts the management API and WebUI on plain HTTP :8080 with
# all mail listeners stopped. That lets us install the Tailscale certificate,
# rewrite listener binds, create accounts and mount Bulwark without binding a
# single mail port — and without competing with Dovecot/OpenSMTPD.
#
# The recovery administrator password is generated once and stored in
# /root/stalwart-recovery-password (mode 0600). Recovery mode has no brute-force
# protection, so keep :8080 off untrusted networks and remove it in
# 40-activate.sh.

set -euo pipefail

[[ ${EUID} -eq 0 ]] || { echo "run with sudo: sudo bash $0" >&2; exit 1; }

ENV_FILE=/etc/stalwart/stalwart.env
PW_FILE=/root/stalwart-recovery-password

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

[[ -s /etc/stalwart/config.json ]] \
    || die "/etc/stalwart/config.json is missing — finish the setup wizard first"
[[ -f $ENV_FILE ]] || die "$ENV_FILE is missing"

if [[ -s $PW_FILE ]]; then
    PW="$(cat "$PW_FILE")"
    info "reusing the recovery password in $PW_FILE"
else
    PW="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-24)"
    ( umask 077; printf '%s\n' "$PW" > "$PW_FILE" )
    chmod 0600 "$PW_FILE"
    info "generated a recovery password in $PW_FILE"
fi

log "Enabling recovery mode"
python3 - "$ENV_FILE" "$PW" <<'PY'
import re, sys
path, pw = sys.argv[1], sys.argv[2]
text = open(path).read().splitlines()
wanted = {
    "STALWART_RECOVERY_MODE": "1",
    "STALWART_RECOVERY_ADMIN": f"admin:{pw}",
}
out, seen = [], set()
for line in text:
    m = re.match(r"^#?\s*(STALWART_[A-Z_]+)=(.*)$", line)
    if m and m.group(1) in wanted:
        out.append(f"{m.group(1)}={wanted[m.group(1)]}")
        seen.add(m.group(1))
    else:
        out.append(line)
for key, value in wanted.items():
    if key not in seen:
        out.append(f"{key}={value}")
open(path, "w").write("\n".join(out) + "\n")
PY
chown root:stalwart "$ENV_FILE"
chmod 0640 "$ENV_FILE"

log "Restarting Stalwart"
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

log "Recovery API"
if curl -fsS -o /dev/null http://127.0.0.1:8080/ 2>/dev/null; then
    info "http://127.0.0.1:8080 is up"
else
    die "the management listener did not come up; journalctl -u stalwart -n 50"
fi
ss -ltnH | grep ':8080' || true

cat <<EOF

$(printf '\033[1;32mRecovery mode is active\033[0m')

  The management API is on :8080, with no mail listeners running.
  Credentials: admin / (in ${PW_FILE})

  Recovery mode disables auto-ban and serves plain HTTP on all interfaces.
  Use an SSH tunnel and do not leave it running longer than needed:
    ssh -L 8080:127.0.0.1:8080 mcsquirrel@$(tailscale ip -4 2>/dev/null | head -n1 || echo '<tailnet-ip>')

  Next: review the configuration plan, then apply it.
    sudo bash ${BASH_SOURCE[0]%/*}/30-configure.sh            # dry run
    sudo APPLY=1 bash ${BASH_SOURCE[0]%/*}/30-configure.sh    # apply

EOF
