#!/usr/bin/env bash
#
# 00-backup.sh — full pre-migration backup of the OpenSMTPD + Dovecot setup.
# Run as root:  sudo bash migrate/00-backup.sh
#
# Writes an archive set to /root/mail-migration-<timestamp>/ with:
#   maildirs.tar.gz   every /home/*/Maildir (cur, new, dovecot indexes)
#   etc.tar.gz        all mail config, PAM files, cert, renewal units
#   state.txt         listeners, services, packages, ufw, cert, tailscale
#   credentials.txt   copy of /root/mail-credentials.txt, if present
#   SHA256SUMS        checksums of the above
#
# The archive is mode 0700/0600 and includes the TLS key and passwords.

set -euo pipefail

[[ ${EUID} -eq 0 ]] || { echo "run with sudo: sudo bash $0" >&2; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="/root/mail-migration-$STAMP"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }

umask 077
mkdir -p "$DEST"

# --------------------------------------------------------------- maildirs ---

log "Maildirs"
mapfile -t MAILDIRS < <(find /home -maxdepth 3 -type d -name Maildir 2>/dev/null | sort)
if (( ${#MAILDIRS[@]} )); then
    tar -czf "$DEST/maildirs.tar.gz" -C / "${MAILDIRS[@]#/}"
    du -sh "$DEST/maildirs.tar.gz" | awk '{print "    archive: " $1}'
    printf '    %s\n' "${MAILDIRS[@]}"
else
    warn "no Maildir found under /home — nothing to archive here"
fi

# -------------------------------------------------------------------- etc ---

log "Configuration, certificates and PAM"
ETC_PATHS=()
for p in \
    /etc/dovecot \
    /etc/smtpd.conf \
    /etc/smtpd.conf.orig-mail-setup \
    /etc/pam.d/dovecot \
    /etc/pam.d/smtpd \
    /etc/aliases \
    /etc/aliases.db \
    /etc/mailname \
    /etc/default/mail-setup \
    /etc/ssl/tailscale \
    /etc/systemd/system/dovecot.service.d \
    /etc/systemd/system/opensmtpd.service.d \
    /etc/systemd/system/mail-cert-renew.service \
    /etc/systemd/system/mail-cert-renew.timer \
    /usr/local/sbin/mail-cert-renew ; do
    [[ -e $p ]] && ETC_PATHS+=("$p")
done

tar -czf "$DEST/etc.tar.gz" -C / "${ETC_PATHS[@]#/}"
du -sh "$DEST/etc.tar.gz" | awk '{print "    archive: " $1}'

# ------------------------------------------------------------------ state ---

log "Capturing state"
{
    echo "# captured $(date -Is) on $(hostname)"
    echo
    echo "## tailscale"
    tailscale status 2>&1 || true
    echo
    echo "## listening sockets"
    ss -ltnp 2>&1 || true
    echo
    echo "## services"
    systemctl status --no-pager dovecot opensmtpd 2>&1 | head -60 || true
    echo
    echo "## packages"
    dpkg -l 2>/dev/null | grep -E 'dovecot|opensmtpd|stalwart' || true
    echo
    echo "## firewall"
    ufw status verbose 2>&1 || true
    echo
    echo "## certificate"
    openssl x509 -in /etc/ssl/tailscale/mail.crt -noout -subject -issuer -enddate 2>&1 || true
    echo
    echo "## mail addresses"
    getent passwd | awk -F: '$3 >= 1000 && $3 < 65000 {print $1, $6}' || true
} > "$DEST/state.txt" 2>&1

# ------------------------------------------------------------ credentials ---

if [[ -s /root/mail-credentials.txt ]]; then
    cp -a /root/mail-credentials.txt "$DEST/credentials.txt"
    info "agent credentials copied"
else
    warn "/root/mail-credentials.txt not found"
fi

# --------------------------------------------------------------- integrity ---

log "Verifying archives"
tar -tzf "$DEST/maildirs.tar.gz" >/dev/null 2>&1 \
    && info "maildirs.tar.gz OK" \
    || warn "maildirs.tar.gz could not be listed"
tar -tzf "$DEST/etc.tar.gz" >/dev/null 2>&1 \
    && info "etc.tar.gz OK" \
    || { echo "etc archive is unreadable" >&2; exit 1; }

( cd "$DEST" && sha256sum -- * > SHA256SUMS 2>/dev/null || true )
chmod 600 "$DEST"/*
chmod 700 "$DEST"

printf '\n\033[1;32mBackup complete\033[0m\n'
printf '  %s\n' "$DEST"
du -sh "$DEST" | awk '{print "  total: " $1}'
printf '\nRestore/rollback is described in migrate/README.md.\n'
