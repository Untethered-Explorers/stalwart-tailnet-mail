#!/usr/bin/env bash
#
# 33-fix-domain.sh — correct a mistyped domain / hostname from the wizard.
# Run as root, in recovery mode.
#
# Expected values come from /etc/default/mail-setup (written by install-mail.sh):
#   MAIL_DOMAIN=mcsquirrel.tailc7d454.ts.net
#
# It renames the existing Domain object and, if needed, corrects
# SystemSettings.defaultHostname. Account addresses are derived from the
# domain, so they follow the rename; the script re-reads them to confirm.

set -euo pipefail

trap 'rc=$?; printf "\n\033[1;31m[error]\033[0m failed at %s line %s (exit %s)\n" "${BASH_SOURCE[0]}" "$LINENO" "$rc" >&2' ERR

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/bin/stalwart-cli"
URL="http://127.0.0.1:8080"
PW_FILE=/root/stalwart-recovery-password

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "run with sudo: sudo bash $0"
[[ -s $PW_FILE ]] || die "$PW_FILE is missing"
RECOVERY_PW="$(cat "$PW_FILE")"

if [[ -r /etc/default/mail-setup ]]; then
    # shellcheck disable=SC1091
    . /etc/default/mail-setup
fi
EXPECTED="${MAIL_DOMAIN:-}"
[[ -n $EXPECTED ]] || die "MAIL_DOMAIN is not set in /etc/default/mail-setup"

cli() { "$CLI" --url "$URL" --user admin --password "$RECOVERY_PW" "$@"; }

log "Domains"
DOMAINS="$(curl -fsS -u "admin:$RECOVERY_PW" \
    -H 'Content-Type: application/json' \
    -d '{"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],"methodCalls":[["x:Domain/get",{"ids":null},"0"]]}' \
    "$URL/jmap/")" || die "x:Domain/get failed"

DOMAIN_LIST="$(printf '%s' "$DOMAINS" | jq -c '.methodResponses[0][1].list // []')"
printf '%s\n' "$DOMAIN_LIST" | jq -r '.[] | "    \(.id)  \(.name)"'

DOMAIN_ID="$(printf '%s' "$DOMAIN_LIST" | jq -r --arg d "$EXPECTED" 'map(select(.name==$d))[0].id // empty')"
CURRENT_NAME="$(printf '%s' "$DOMAIN_LIST" | jq -r '.[0].name // empty')"

if [[ -n $DOMAIN_ID ]]; then
    info "domain already correct: $EXPECTED ($DOMAIN_ID)"
else
    COUNT="$(printf '%s' "$DOMAIN_LIST" | jq 'length')"
    (( COUNT == 1 )) || die "expected exactly one domain to rename, found $COUNT"
    DOMAIN_ID="$(printf '%s' "$DOMAIN_LIST" | jq -r '.[0].id')"
    info "renaming '$CURRENT_NAME' → '$EXPECTED'"
    if ! cli update Domain "$DOMAIN_ID" --field "name=$EXPECTED" >/dev/null; then
        die "the rename was rejected. Options: create a new domain and update each account's domainId."
    fi
    info "renamed"
fi

log "System hostname setting"
HOSTNAME_SETTING="$(cli get SystemSettings --json 2>/dev/null \
    | jq -r '.defaultHostname // empty' 2>/dev/null || true)"
if [[ -z $HOSTNAME_SETTING ]]; then
    warn "could not read SystemSettings.defaultHostname"
elif [[ $HOSTNAME_SETTING == "$EXPECTED" ]]; then
    info "defaultHostname already $EXPECTED"
else
    info "defaultHostname '$HOSTNAME_SETTING' → '$EXPECTED'"
    cli update SystemSettings --field "defaultHostname=$EXPECTED" >/dev/null
    info "updated"
fi

log "Account addresses"
ACCOUNTS="$(curl -fsS -u "admin:$RECOVERY_PW" \
    -H 'Content-Type: application/json' \
    -d '{"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],"methodCalls":[["x:Account/get",{"ids":null},"0"]]}' \
    "$URL/jmap/")"
printf '%s\n' "$ACCOUNTS" | jq -r '.methodResponses[0][1].list[] | "    \(.name)  \(.emailAddress // "")"'

BAD="$(printf '%s' "$ACCOUNTS" | jq -r --arg d "@$EXPECTED" \
    '[.methodResponses[0][1].list[] | select((.emailAddress // "") | endswith($d) | not)] | length')"
if [[ $BAD == "0" ]]; then
    info "every account address is now @$EXPECTED"
else
    warn "$BAD account(s) still use another domain. If the rename does not cascade,"
    warn "restart Stalwart and re-run this script:  systemctl restart stalwart"
fi

cat <<EOF

$(printf '\033[1;32mDomain check complete\033[0m')

  expected : $EXPECTED
  domain id: $DOMAIN_ID

EOF
