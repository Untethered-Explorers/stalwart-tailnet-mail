#!/usr/bin/env bash
#
# 30-configure.sh — configure Stalwart through the recovery management API.
# Run as root, while 20-recovery-on.sh is active.
#
#   sudo bash migrate/30-configure.sh             # dry run: print the plan
#   sudo APPLY=1 bash migrate/30-configure.sh     # apply the plan
#
# Optional:
#   RESET_PASSWORDS=1   regenerate the password of accounts that already exist
#
# What it does:
#   - finds the default domain created by the wizard
#   - installs the existing Tailscale certificate as a Certificate object
#   - creates/updates the five listeners, bound to loopback + tailnet only
#   - creates or resets the mcsquirrel and agent-bot accounts, saving passwords
#     to /root/mail-credentials.txt immediately
#   - creates an app password for agent-bot through the admin JMAP API
#     (regular accounts cannot sign in to the API in recovery mode)
#   - mounts Bulwark Lite at /webmail and triggers the bundle download
#
# It never touches mail data. Mail is imported after activation.

set -euo pipefail

# Make silent deaths impossible: report the failing line.
trap 'rc=$?; printf "\n\033[1;31m[error]\033[0m failed at %s line %s (exit %s)\n" "${BASH_SOURCE[0]}" "$LINENO" "$rc" >&2' ERR

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/bin/stalwart-cli"
URL="http://127.0.0.1:8080"
PW_FILE=/root/stalwart-recovery-password
CRED_FILE=/root/mail-credentials.txt
CERT_FILE=/etc/ssl/tailscale/mail.crt
KEY_FILE=/etc/ssl/tailscale/mail.key
BULWARK_VERSION="1.21.2"
BULWARK_URL="https://github.com/bulwarkmail/webmail/releases/download/${BULWARK_VERSION}/bulwark-lite-stalwart.zip"

APPLY="${APPLY:-0}"
RESET_PASSWORDS="${RESET_PASSWORDS:-0}"
LOCAL_USER="${LOCAL_USER:-mcsquirrel}"
AGENT_USER="${AGENT_USER:-agent-bot}"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "run with sudo: sudo bash $0"
[[ -x $CLI ]] || die "$CLI is missing — run: bash migrate/05-install-cli.sh"
[[ -s $PW_FILE ]] || die "$PW_FILE is missing — run: sudo bash migrate/20-recovery-on.sh"
[[ -s $CERT_FILE && -s $KEY_FILE ]] || die "Tailscale certificate/key not found under /etc/ssl/tailscale"

curl -fsS -o /dev/null "$URL/" 2>/dev/null \
    || die "recovery API is not reachable on $URL — run 20-recovery-on.sh first"

# ---------------------------------------------------------------- settings ---

if [[ -r /etc/default/mail-setup ]]; then
    # shellcheck disable=SC1091
    . /etc/default/mail-setup
fi
DOMAIN="${MAIL_DOMAIN:-}"
BIND_IP="${MAIL_BIND_IP:-$(tailscale ip -4 2>/dev/null | head -n1 || true)}"
[[ -n $DOMAIN ]] || die "cannot determine the mail domain"
[[ -n $BIND_IP ]] || die "cannot determine the tailnet address"

RECOVERY_PW="$(cat "$PW_FILE")"

cli() { "$CLI" --url "$URL" --user admin --password "$RECOVERY_PW" "$@"; }

act() {
    printf '    '
    if [[ $APPLY == 1 ]]; then
        printf '%s\n' "$*"
        "$@" >/dev/null
        printf '    \033[32mdone\033[0m\n'
    else
        printf '[dry-run] %s\n' "$*"
    fi
}

gen_password() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-24; }

printf '\n\033[1mStalwart configuration — %s (%s)\033[0m\n' "$DOMAIN" "$BIND_IP"
[[ $APPLY == 1 ]] && printf 'Mode: APPLY\n' || printf 'Mode: dry run (set APPLY=1 to execute)\n'

# ------------------------------------------------------------------ domain ---

log "Domain"
DOMAINS="$(cli query Domain --json --fields id,name,certificateManagement 2>/dev/null || true)"
[[ -n ${DOMAINS//[[:space:]]/} ]] || DOMAINS="$(cli query Domain --json 2>/dev/null || true)"
DOMAIN_ID="$(printf '%s\n' "$DOMAINS" | jq -rs --arg d "$DOMAIN" '(. // []) | map(select(.name==$d))[0].id // empty' 2>/dev/null || true)"
[[ -n $DOMAIN_ID ]] || die "no domain named '$DOMAIN' exists (found: $(printf '%s\n' "$DOMAINS" | jq -rs '(. // []) | map(.name) | join(", ")' 2>/dev/null)). Run: sudo bash $HERE/33-fix-domain.sh"
info "domain id: $DOMAIN_ID"
info "certificate management: $(printf '%s\n' "$DOMAINS" | jq -rs --arg i "$DOMAIN_ID" '(. // []) | map(select(.id==$i))[0].certificateManagement."@type" // "?"' 2>/dev/null || echo '?')"

# ------------------------------------------------------------- certificate ---

log "TLS certificate"
CERTS="$(cli query Certificate --json --fields id 2>/dev/null || true)"
[[ -n ${CERTS//[[:space:]]/} ]] || CERTS="$(cli query Certificate --json 2>/dev/null || true)"
mapfile -t CERT_IDS < <(printf '%s\n' "$CERTS" | jq -rs '(. // []) | map(.id) | .[]' 2>/dev/null || true)

if (( ${#CERT_IDS[@]} > 0 )); then
    info "certificate object present (${CERT_IDS[0]})"
    for extra in "${CERT_IDS[@]:1}"; do
        info "duplicate certificate $extra → delete"
        act cli delete Certificate --ids "$extra"
    done
else
    info "installing /etc/ssl/tailscale/mail.crt as a Certificate object"
    if [[ $APPLY == 1 ]]; then
        CERT_JSON="$(jq -Rs '{ "@type": "Text", value: . }' "$CERT_FILE")"
        KEY_JSON="$(jq -Rs '{ "@type": "Text", secret: . }' "$KEY_FILE")"
        cli create Certificate \
            --field "certificate=$CERT_JSON" \
            --field "privateKey=$KEY_JSON" >/dev/null
        info "certificate created"
    else
        printf '    [dry-run] stalwart-cli create Certificate --field certificate={"@type":"Text","value":<PEM>} --field privateKey={"@type":"Text","secret":<PEM>}\n'
    fi
fi

# --------------------------------------------------------------- listeners ---

log "Listeners"
KEEP="smtp submissions submission imaps https"
LISTENERS="$(cli query NetworkListener --json --fields id,name,protocol,bind 2>/dev/null || true)"
[[ -n ${LISTENERS//[[:space:]]/} ]] || LISTENERS="$(cli query NetworkListener --json 2>/dev/null || true)"

if [[ -z ${LISTENERS//[[:space:]]/} ]]; then
    info "no listener objects yet — creating them with tailnet-only binds"

    create_listener() { # name protocol port [implicit]
        local name=$1 protocol=$2 port=$3 implicit=${4:-}
        local bind="{\"127.0.0.1:$port\":true,\"$BIND_IP:$port\":true}"
        local args=(create NetworkListener --field "name=$name" --field "protocol=$protocol" --field "bind=$bind")
        [[ $implicit == implicit ]] && args+=(--field implicitTls=true)
        info "$name ($protocol/$port) → 127.0.0.1 and $BIND_IP${implicit:+, implicit TLS}"
        act cli "${args[@]}"
    }

    create_listener smtp        smtp 25
    create_listener submissions smtp 465 implicit
    create_listener submission  smtp 587
    create_listener imaps       imap 993 implicit
    create_listener https       http 443 implicit
else
    while IFS=$'\t' read -r id name protocol addr; do
        [[ -n $name ]] || continue
        target="${id:-$name}"
        port="${addr##*:}"
        [[ -n $port ]] || die "cannot determine the port of listener $name"
        if [[ " $KEEP " == *" $name "* ]]; then
            bind="{\"127.0.0.1:$port\":true,\"$BIND_IP:$port\":true}"
            info "$name ($protocol/$port) → 127.0.0.1 and $BIND_IP"
            act cli update NetworkListener "$target" --field "bind=$bind"
        else
            info "$name ($protocol/$port) → delete"
            act cli delete NetworkListener --ids "$target"
        fi
    done < <(printf '%s\n' "$LISTENERS" | jq -r '[.id // .name, .name, .protocol, ((.bind // {}) | keys[0] // "")] | @tsv')
fi

# ----------------------------------------------------------------- accounts ---

log "Accounts"
ACCOUNTS_JSON="$(cli query Account --json --fields id,name 2>/dev/null || true)"
[[ -n ${ACCOUNTS_JSON//[[:space:]]/} ]] || ACCOUNTS_JSON="$(cli query Account --json 2>/dev/null || true)"
EXISTING_ACCOUNTS="$(printf '%s\n' "$ACCOUNTS_JSON" | jq -r '.name' 2>/dev/null || true)"
account_id() { printf '%s\n' "$ACCOUNTS_JSON" | jq -rs --arg n "$1" '(. // []) | map(select(.name==$n))[0].id // empty' 2>/dev/null; }

declare -A PASSWORDS=()
for user in "$LOCAL_USER" "$AGENT_USER"; do
    exists=0
    grep -qx "$user" <<<"$EXISTING_ACCOUNTS" && exists=1

    if (( exists )) && [[ $RESET_PASSWORDS != 1 ]]; then
        info "$user already exists (password unchanged)"
        continue
    fi

    pw="$(gen_password)"
    PASSWORDS["$user"]="$pw"

    if (( exists )); then
        info "$user already exists → reset password"
        if [[ $APPLY == 1 ]]; then
            cli update Account "$(account_id "$user")" \
                --field "credentials/0/secret=$pw" >/dev/null
            printf '    \033[32mdone\033[0m\n'
        else
            printf '    [dry-run] stalwart-cli update Account %s --field credentials/0/secret=<generated>\n' "$user"
        fi
    else
        info "$user → create with a generated password"
        if [[ $APPLY == 1 ]]; then
            cli create Account/User \
                --field "name=$user" \
                --field "domainId=$DOMAIN_ID" \
                --field "credentials={\"0\":{\"@type\":\"Password\",\"secret\":\"$pw\"}}" >/dev/null
            printf '    \033[32mdone\033[0m\n'
        else
            printf '    [dry-run] stalwart-cli create Account/User --field name=%s --field domainId=%s --field credentials=<generated>\n' \
                "$user" "$DOMAIN_ID"
        fi
    fi
done

# Save account passwords immediately: a later failure must not lose them.
if [[ $APPLY == 1 ]] && (( ${#PASSWORDS[@]} > 0 )); then
    umask 077
    {
        printf '# Generated by migrate/30-configure.sh on %s\n' "$(date -Is)"
        printf '# Stalwart accounts. Move these into your password manager, then delete.\n'
        printf 'host            = %s\n' "$DOMAIN"
        printf 'imap            = imaps://%s:993\n' "$DOMAIN"
        printf 'smtp            = smtps://%s:465\n' "$DOMAIN"
        printf 'webmail         = https://%s/webmail/\n' "$DOMAIN"
        printf 'admin           = https://%s/admin\n' "$DOMAIN"
        for user in "$LOCAL_USER" "$AGENT_USER"; do
            [[ -n ${PASSWORDS[$user]:-} ]] && printf '%-15s = %s\n' "$user" "${PASSWORDS[$user]}"
        done
    } > "$CRED_FILE"
    chmod 0600 "$CRED_FILE"
    info "account passwords saved to $CRED_FILE"
fi

ACCOUNTS_JSON="$(cli query Account --json 2>/dev/null || true)"
# The agent's account id comes from the admin JMAP API: the CLI's account
# query proved unreliable here, and the app-password call uses JMAP anyway.
AGENT_ID="$(curl -fsS -u "admin:$RECOVERY_PW" \
    -H 'Content-Type: application/json' \
    -d '{"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],"methodCalls":[["x:Account/get",{"ids":null},"0"]]}' \
    "$URL/jmap/" 2>/dev/null \
    | jq -r --arg n "$AGENT_USER" '.methodResponses[0][1].list | map(select(.name==$n))[0].id // empty' 2>/dev/null || true)"

# ------------------------------------------------------------ app password ---

log "Agent app password"
if [[ -z $AGENT_ID ]]; then
    warn "$AGENT_USER has no account id; skipping the app password"
elif [[ $APPLY != 1 ]]; then
    printf '    [dry-run] x:AppPassword/set accountId=%s description=%s-opencode (admin JMAP call)\n' \
        "$AGENT_ID" "$AGENT_USER"
elif grep -q 'app-password' "$CRED_FILE" 2>/dev/null; then
    info "an app password is already recorded in $CRED_FILE"
else
    payload="$(jq -n --arg id "$AGENT_ID" --arg desc "$AGENT_USER-opencode" '{
        using: ["urn:ietf:params:jmap:core", "urn:stalwart:jmap"],
        methodCalls: [[ "x:AppPassword/set", {
            accountId: $id,
            create: { p1: {
                description: $desc,
                permissions: { "@type": "Inherit" },
                allowedIps: {}
            } }
        }, "0" ]]
    }')"

    if ! response="$(curl -fsS -u "admin:$RECOVERY_PW" \
            -H 'Content-Type: application/json' -d "$payload" "$URL/jmap/")"; then
        die "the app-password JMAP call failed (is /jmap/ available in recovery mode?)"
    fi

    APP_SECRET="$(printf '%s' "$response" | jq -r '.methodResponses[0][1].created.p1.secret // empty')"
    if [[ -z $APP_SECRET ]]; then
        printf '%s\n' "$response" >&2
        die "could not parse the app-password secret from the JMAP response"
    fi

    if [[ ! -s $CRED_FILE ]]; then
        ( umask 077
          printf '# Generated by migrate/30-configure.sh on %s\n' "$(date -Is)" > "$CRED_FILE"
          printf 'host            = %s\nimap            = imaps://%s:993\nsmtp            = smtps://%s:465\n' \
              "$DOMAIN" "$DOMAIN" "$DOMAIN"
        )
    fi
    ( umask 077
      printf '%-15s = %s   (use this in agent configs)\n' "app-password" "$APP_SECRET" >> "$CRED_FILE"
    )
    chmod 0600 "$CRED_FILE"
    info "app password created and appended to $CRED_FILE"
fi

# ------------------------------------------------------------------ webmail ---

log "Bulwark Lite application"
APPS="$(cli query Application --json 2>/dev/null | jq -r '.description // empty' 2>/dev/null || true)"
if grep -qx 'Bulwark Webmail' <<<"$APPS"; then
    info "application already exists"
else
    act cli create Application \
        --field "description=Bulwark Webmail" \
        --field "resourceUrl=$BULWARK_URL" \
        --field 'urlPrefix={"/webmail":true}'
    act cli create Action/UpdateApps
fi

# ----------------------------------------------------------------- summary ---

cat <<EOF

$(printf '\033[1;32mConfiguration plan complete\033[0m')

  domain        : $DOMAIN ($DOMAIN_ID)
  bind          : 127.0.0.1 and $BIND_IP
  webmail       : https://$DOMAIN/webmail/
  admin         : https://$DOMAIN/admin
  credentials   : $CRED_FILE

$( [[ $APPLY == 1 ]] && echo "Next: sudo bash $HERE/40-activate.sh" || echo "Review the dry run, then: sudo APPLY=1 bash $HERE/30-configure.sh" )

EOF
