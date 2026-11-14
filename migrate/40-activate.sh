#!/usr/bin/env bash
#
# 40-activate.sh — cut over from OpenSMTPD + Dovecot to Stalwart.
# Run as root:  sudo bash migrate/40-activate.sh
#
# Order matters:
#   1. leave recovery mode (restores the configured listeners)
#   2. stop and disable Dovecot + OpenSMTPD so the mail ports are free
#   3. start Stalwart, which binds only loopback and the tailnet address
#
# If anything fails, run 50-rollback.sh. The old packages stay installed but
# disabled for exactly that reason.

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/bin/stalwart-cli"
ENV_FILE=/etc/stalwart/stalwart.env
PW_FILE=/root/stalwart-recovery-password

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "run with sudo: sudo bash $0"
[[ -s /etc/stalwart/config.json ]] || die "Stalwart is not configured yet"
[[ -s $PW_FILE ]] || die "recovery password missing — run 20-recovery-on.sh first"

if [[ -r /etc/default/mail-setup ]]; then
    # shellcheck disable=SC1091
    . /etc/default/mail-setup
fi
DOMAIN="${MAIL_DOMAIN:-}"
BIND_IP="${MAIL_BIND_IP:-$(tailscale ip -4 2>/dev/null | head -n1 || true)}"
[[ -n $DOMAIN && -n $BIND_IP ]] || die "cannot determine domain or tailnet address"

log "Leaving recovery mode"
python3 - "$ENV_FILE" <<'PY'
import re, sys
path = sys.argv[1]
out = []
for line in open(path).read().splitlines():
    if re.match(r"^\s*(STALWART_RECOVERY_MODE|STALWART_RECOVERY_ADMIN)=", line):
        out.append("# " + line + "   # disabled by migrate/40-activate.sh")
    else:
        out.append(line)
open(path, "w").write("\n".join(out) + "\n")
PY
info "recovery variables commented out"

log "Stopping the old stack"
systemctl disable --now dovecot.service opensmtpd.service >/dev/null 2>&1 || true
info "dovecot and opensmtpd are disabled"

log "Restarting Stalwart with the configured listeners"
systemctl restart stalwart.service
for _ in $(seq 1 40); do
    systemctl is-active --quiet stalwart.service && break
    sleep 1
done
systemctl is-active --quiet stalwart.service \
    || { journalctl -u stalwart -n 60 --no-pager; die "stalwart failed to start"; }

# A failed bind is logged, not fatal, so verify the sockets explicitly.
ok=1
for _ in $(seq 1 20); do
    socks="$(ss -ltnH 2>/dev/null | awk '{print $4}')"
    ok=1
    for port in 25 465 587 993 443; do
        if ! grep -qxF "${BIND_IP}:${port}" <<<"$socks"; then ok=0; fi
    done
    (( ok )) && break
    sleep 1
done
printf '%s\n' "$socks" | sort -u | sed 's/^/    /'

if (( ! ok )); then
    warn "expected listeners not all present on $BIND_IP (25, 465, 587, 993, 443)"
    journalctl -u stalwart -n 40 --no-pager | grep -i 'bind\|listener' || true
    die "listeners did not come up; run 50-rollback.sh"
fi
info "all five mail/web listeners are bound to $BIND_IP"

if grep -qE ':(8080)$' <<<"$socks"; then
    warn "something still listens on 8080 — recovery mode may not have been disabled"
fi

log "Checking HTTPS and the webmail bundle"
webmail_code=""
for _ in $(seq 1 30); do
    webmail_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "https://$DOMAIN/webmail/" || true)"
    [[ $webmail_code == 200 ]] && break
    sleep 2
done
info "GET /webmail/ → ${webmail_code:-no response}"

admin_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "https://$DOMAIN/admin" || true)"
info "GET /admin    → ${admin_code:-no response}"

if [[ $webmail_code != 200 ]]; then
    warn "the webmail bundle may still be downloading; check:"
    warn "  journalctl -u stalwart -n 50 --no-pager | grep -i application"
    warn "  stalwart-cli --url https://$DOMAIN --user admin --password '<admin>' create Action/UpdateApps"
fi

cat <<EOF

$(printf '\033[1;32mStalwart is live\033[0m')

  IMAP      : $DOMAIN:993
  SMTP      : $DOMAIN:465
  Webmail   : https://$DOMAIN/webmail/
  Admin     : https://$DOMAIN/admin
  Bind      : 127.0.0.1 and $BIND_IP only

  Accounts use the full address as the username, for example
  ${LOCAL_USER:-mcsquirrel}@$DOMAIN.

$(printf 'Next:' )
  1. Test webmail and a mail client with the credentials from /root/mail-credentials.txt
  2. Import the old mailboxes from ~/Maildir (see migrate/README.md, Vandelay)
  3. Update tailmail.py, the agent configs and the renewal timer
  4. If anything is wrong: sudo bash $HERE/50-rollback.sh

EOF
