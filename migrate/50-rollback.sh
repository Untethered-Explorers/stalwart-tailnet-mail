#!/usr/bin/env bash
#
# 50-rollback.sh — go back to OpenSMTPD + Dovecot.
# Run as root:  sudo bash migrate/50-rollback.sh
#
# This restores mail service immediately. It cannot restore mail that was
# already delivered into Stalwart after activation; those messages are still
# in Stalwart's data store, and the pre-migration mail is in the backup and in
# ~/Maildir either way.

set -euo pipefail

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "run with sudo: sudo bash $0"

log "Stopping and disabling Stalwart"
systemctl disable --now stalwart.service >/dev/null 2>&1 || true
info "stalwart is stopped (its data and configuration are untouched)"

log "Restoring the old stack"
systemctl enable --now dovecot.service opensmtpd.service
info "dovecot and opensmtpd are enabled and started"

sleep 1
ss -ltnH | awk '{print $4}' | grep -E ':(25|465|587|993)$' | sort -u | sed 's/^/    /' || true

cat <<EOF

$(printf '\033[1;32mRolled back to OpenSMTPD + Dovecot\033[0m')

  Backups: /root/mail-migration-*   (see state.txt and SHA256SUMS)
  Stalwart data: /var/lib/stalwart (kept)

  Mail that arrived while Stalwart was live is only in Stalwart's store.
  Re-run 40-activate.sh when the problem is fixed, or leave the old stack
  running and remove Stalwart later.

EOF
