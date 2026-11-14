#!/usr/bin/env bash
#
# 85-cert-renewal.sh — create an admin API key and install the Stalwart-aware
# certificate renewal script.
# Run as root:  sudo bash migrate/85-cert-renewal.sh
#
# Stalwart stores certificates as objects in its data store, so renewing the
# file alone is not enough. This installs a renewal script that updates the
# Certificate object over the admin JMAP API and restarts Stalwart only when the
# certificate changed.
#
# Creating the API key needs admin credentials:
#   - in recovery mode (http://127.0.0.1:8080) it uses the pinned recovery admin;
#   - otherwise it prompts once for the admin@<domain> password.

set -euo pipefail

trap 'rc=$?; printf "\n\033[1;31m[error]\033[0m failed at %s line %s (exit %s)\n" "${BASH_SOURCE[0]}" "$LINENO" "$rc" >&2' ERR

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/bin/stalwart-cli"
TOKEN_FILE=/root/stalwart-api-key

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "run with sudo: sudo bash $0"
[[ -x $CLI ]] || die "$CLI is missing — run: bash migrate/05-install-cli.sh"

if [[ -r /etc/default/mail-setup ]]; then
    # shellcheck disable=SC1091
    . /etc/default/mail-setup
fi
DOMAIN="${MAIL_DOMAIN:-}"
[[ -n $DOMAIN ]] || die "cannot determine the mail domain"

# ------------------------------------------------------------- api key ---

if [[ -s $TOKEN_FILE ]]; then
    info "API key already present in $TOKEN_FILE"
else
    if curl -fsS -o /dev/null http://127.0.0.1:8080/ 2>/dev/null; then
        info "recovery mode detected — using the recovery admin"
        RECOVERY_PW="$(cat /root/stalwart-recovery-password)"
        CLI_ARGS=(--url http://127.0.0.1:8080 --user admin --password "$RECOVERY_PW")
    else
        read -rsp "admin@$DOMAIN password (the one the wizard showed): " ADMIN_PW
        echo
        [[ -n $ADMIN_PW ]] || die "no password entered"
        CLI_ARGS=(--url "https://$DOMAIN" --user "admin@$DOMAIN" --password "$ADMIN_PW")
    fi

    log "Creating the cert-renewal API key"
    out="$( "$CLI" "${CLI_ARGS[@]}" create ApiKey \
        --field "description=cert-renewal" \
        --field 'permissions={"@type":"Inherit"}' 2>&1 )" || {
            printf '%s\n' "$out" >&2
            die "ApiKey creation failed. If the admin password is lost, run 20-recovery-on.sh first."
        }
    token="$(printf '%s' "$out" | grep -oE 'API_[A-Za-z0-9]+' | head -n1 || true)"
    if [[ -z $token ]]; then
        printf '%s\n' "$out" >&2
        die "could not find the API key in the output"
    fi
    ( umask 077; printf '%s\n' "$token" > "$TOKEN_FILE" )
    chmod 0600 "$TOKEN_FILE"
    info "API key saved to $TOKEN_FILE"
fi

# ------------------------------------------------------------- script ---

log "Installing /usr/local/sbin/mail-cert-renew"
sed "s|__DOMAIN__|$DOMAIN|g" "$HERE/../config/mail-cert-renew.sh.in" \
    > /usr/local/sbin/mail-cert-renew
chmod 0755 /usr/local/sbin/mail-cert-renew
chown root:root /usr/local/sbin/mail-cert-renew
info "installed"

log "Testing renewal (no change expected)"
if /usr/local/sbin/mail-cert-renew; then
    info "renewal script ran cleanly"
else
    die "renewal script failed — see the error above"
fi

systemctl is-enabled --quiet mail-cert-renew.timer \
    && info "weekly timer is enabled" \
    || info "timer not enabled: systemctl enable --now mail-cert-renew.timer"
