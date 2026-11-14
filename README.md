# Private mail on this machine

**Stalwart 1.1** (Rust) serves SMTP, IMAP and HTTPS; **Bulwark Lite** is the
webmail, hosted by Stalwart at `/webmail/`. Everything binds to loopback and the
Tailscale address only.

To run the same setup on another tailnet, use the generic installer and guide:
[`setup-mail.sh`](setup-mail.sh) and [`docs/00-overview.md`](docs/00-overview.md).
This page documents the instance already running here.

| | |
|---|---|
| Mail domain | `mcsquirrel.tailc7d454.ts.net` |
| Tailnet address | `100.112.57.64` |
| Accounts | `mcsquirrel@…`, `agent-bot@…` — full address is the username |
| IMAP | 993, implicit TLS |
| SMTP | 465 implicit TLS, 587 STARTTLS, 25 server-to-server |
| Webmail | `https://mcsquirrel.tailc7d454.ts.net/webmail/` |
| Admin | `https://mcsquirrel.tailc7d454.ts.net/admin` |
| Credentials | `/root/mail-credentials.txt` (0600) |

The OpenSMTPD + Dovecot stack is still installed but **disabled** for rollback.

## Daily checks

```bash
sudo bash migrate/60-verify.sh          # services, listeners, TLS, login, delivery, HTTP
journalctl -u stalwart -n 50 --no-pager
ls -l /var/log/stalwart/
```

`verify-mail.sh` at the repository root documents the old stack; use
`migrate/60-verify.sh` for the current one.

## Accounts and credentials

- Account passwords and the agent app password are in
  `/root/mail-credentials.txt`. Move them to a password manager and delete it.
- The `admin@…` account (wizard password) is for `/admin` only.
- Regular accounts can change passwords and create app passwords at
  `https://…/account`.

## For agents

`scripts/tailmail.py` uses `~/.config/tailmail/config`, written by
`migrate/80-agent-config.sh`:

```
[default]
host     = mcsquirrel.tailc7d454.ts.net
username = agent-bot@mcsquirrel.tailc7d454.ts.net
password = <app password>
from     = agent-bot@mcsquirrel.tailc7d454.ts.net
```

```bash
python3 scripts/tailmail.py send --to mcsquirrel@mcsquirrel.tailc7d454.ts.net \
    --subject "Build finished" --body "All tests passed."
python3 scripts/tailmail.py inbox --limit 10
python3 scripts/tailmail.py read 42
```

Per-agent isolation: one Stalwart account per agent, one app password per place
the credential lives. Revoke a single app password without touching the mailbox
password. Stalwart rejects a sender that is not one of the account's addresses.

## Mail data

- Stalwart stores mail in `/var/lib/stalwart/`; back it up with
  `systemctl stop stalwart && cp -a /var/lib/stalwart /backup/…` or the
  Stalwart backup tooling.
- The pre-migration Dovecot Maildirs are still in `/home/*/Maildir`; they were
  imported with Vandelay and are untouched.

## Certificate renewal

Tailscale certificates last ~90 days. Stalwart stores its certificate as a
`Certificate` object, so renewal updates it through the admin API:

- `/usr/local/sbin/mail-cert-renew` fetches a new cert, updates the object, and
  restarts Stalwart only when the certificate changed.
- `mail-cert-renew.timer` runs it weekly.
- The API key is `/root/stalwart-api-key` (0600), created by
  `migrate/85-cert-renewal.sh`.

## Updates

Stalwart is a binary product, not an apt package:

```bash
sudo cp -a /var/lib/stalwart /root/stalwart-backup-$(date +%F)
sudo sh install.sh            # official installer, upgrades in place
```

Bulwark updates through Stalwart: point the Application's `resourceUrl` at a new
release and run `stalwart-cli create Action/UpdateApps`.

## Security notes

- No public exposure: listeners are bound to `127.0.0.1` and `100.112.57.64`.
- No internet mail: only addresses at the tailnet domain are accepted, and
  outbound to external domains is not configured.
- `ufw` is active; tailnet access is governed by Tailscale ACLs.
- Recovery mode (`migrate/20-recovery-on.sh`) is for repairs only: it disables
  brute-force protection and serves plain HTTP on 8080.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Webmail sign-in fails | full address required | use `user@mcsquirrel.tailc7d454.ts.net` |
| `Authentication failed` after a password change | old app password still in client | create a new app password |
| Delivery stuck | sender not owned by the account | send from the account's address or add an alias |
| Cert warning | renewal did not update the object | run `sudo /usr/local/sbin/mail-cert-renew`, check `/root/stalwart-api-key` |
| Need the old stack | Stalwart misbehaving | `sudo bash migrate/50-rollback.sh` |

Full migration notes, phase by phase: [migrate/README.md](migrate/README.md).
