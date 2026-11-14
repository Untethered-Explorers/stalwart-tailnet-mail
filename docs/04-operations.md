# Operations

## Verify

```bash
sudo ./setup-mail.sh --check
```

Checks: Stalwart active, no leftover mail daemons, listeners on the tailnet
address, no wildcard binds, no 8080, TLS chain and hostname on 993/465/443,
IMAP login, and HTTP 200 from webmail, `/admin` and `/account`.

## Logs

| What | Where |
|---|---|
| Installer | `/var/log/mail-setup.log` |
| Stalwart | `journalctl -u stalwart`, `/var/log/stalwart/` |
| Webmail bundle downloads | Stalwart log, look for `resource.` events |

```bash
journalctl -u stalwart -n 100 --no-pager
```

## Backups

Mail and configuration live together in `/var/lib/stalwart` (RocksDB). Stop the
service for a consistent copy:

```bash
sudo systemctl stop stalwart
sudo tar -C /var/lib -czf /root/stalwart-$(date +%F).tar.gz stalwart
sudo systemctl start stalwart
```

Copy the archive off the machine. The certificate files in
`/etc/ssl/tailscale` and `/root/stalwart-api-key` are useful to keep too.

Restore: stop Stalwart, replace `/var/lib/stalwart` from the archive, keep the
ownership (`stalwart:stalwart`), start Stalwart.

## Upgrades

Stalwart is not an apt package. Take a backup, then run the official installer
again; it replaces the binary and restarts the service:

```bash
sudo tar -C /var/lib -czf /root/stalwart-$(date +%F).tar.gz stalwart
curl --proto '=https' --tlsv1.2 -fsSL https://get.stalw.art/install.sh -o /tmp/install.sh
sudo sh /tmp/install.sh
sudo ./setup-mail.sh --check
```

Read the release notes for schema or configuration changes. Do not skip major
versions.

### Bulwark Lite updates

The webmail is an `Application` object. Point it at a newer release and trigger
the download:

```bash
sudo stalwart-cli --url https://<host> --user admin@<domain> --password '<admin>' \
  update Application <id> \
  --field resourceUrl=https://github.com/bulwarkmail/webmail/releases/download/<version>/bulwark-lite-stalwart.zip
sudo stalwart-cli --url https://<host> --user admin@<domain> --password '<admin>' \
  create Action/UpdateApps
```

The Application id is visible in `/admin` under Settings → Web Applications.
Open tabs pick up the new build on their next navigation.

## Certificate renewal

- `/usr/local/sbin/mail-cert-renew` fetches a new certificate, updates the
  `Certificate` object over JMAP, and restarts Stalwart **only if the
  certificate changed**.
- `mail-cert-renew.timer` runs weekly.
- It authenticates with `/root/stalwart-api-key`.

```bash
systemctl list-timers mail-cert-renew.timer
sudo systemctl start mail-cert-renew.service      # force a check now
sudo /usr/local/sbin/mail-cert-renew              # same, in the foreground
```

If the API key is lost, create a new one (`/admin` → account → API keys, or
recovery mode) and write it to `/root/stalwart-api-key`.

## Adding and removing accounts

Accounts are managed in `/admin` under **Management → Directory → Accounts**.
Creating a user, setting an initial password, adding an alias and suspending an
account (by disabling `authenticate`) are all done there; see
[03-accounts-and-agents.md](03-accounts-and-agents.md#adding-accounts-after-install).

Do not re-run the installer to add a user: it rotates the passwords of the
existing accounts. Mail users do not need Linux accounts on the host.

## Password changes

| Account | How |
|---|---|
| your own | `https://<host>/account` → **Credentials → Password** |
| any account | `/admin` → **Management → Directory → Accounts** → **Credentials → Password** |
| locked out | an administrator resets it; if the administrator is locked out, recovery mode, see below |

There is no email-based "forgot password" flow: changing a password in the
Account Manager requires the current one. After changing a password, update
clients that use it. App passwords survive a password change; webmail sessions
do not.

## Recovering access

Recovery mode stops the mail services and serves the management API on plain
HTTP `:8080` with brute-force protection disabled.

```bash
# pin a recovery admin if you do not have one
sudo bash -c 'printf "STALWART_RECOVERY_MODE=1\nSTALWART_RECOVERY_ADMIN=admin:%s\n" "$(openssl rand -base64 24)" >> /etc/stalwart/stalwart.env'
sudo systemctl restart stalwart
# reset the admin password
sudo stalwart-cli --url http://127.0.0.1:8080 --user admin --password '<recovery>' \
  update Account <id> --field 'credentials/0/secret=<new>'
# leave recovery mode
sudo sed -i 's/^STALWART_RECOVERY_MODE=/# STALWART_RECOVERY_MODE=/' /etc/stalwart/stalwart.env
sudo systemctl restart stalwart
```

Keep `:8080` on loopback. If you need the WebUI there, use an SSH tunnel.

## Reconfigure after a tailnet IP change

Listeners pin `100.x.y.z`. If the address changes (re-auth, new node), update
the binds:

```bash
sudo ./setup-mail.sh --reconfigure
```

It enters the existing recovery data, updates every listener to the new
address, and restarts the service.

## Restart and status

```bash
sudo systemctl restart stalwart
sudo systemctl status stalwart --no-pager
```

## Uninstall

```bash
sudo systemctl disable --now stalwart mail-cert-renew.timer
sudo rm -f /etc/systemd/system/stalwart.service \
           /etc/systemd/system/mail-cert-renew.service \
           /etc/systemd/system/mail-cert-renew.timer \
           /usr/local/sbin/mail-cert-renew /usr/local/bin/stalwart-cli \
           /root/stalwart-api-key
sudo rm -rf /var/lib/stalwart /etc/stalwart /var/log/stalwart
sudo userdel stalwart 2>/dev/null || true
sudo systemctl daemon-reload
```

Remove the ufw rules if you added them, and delete any tailnet DNS entries you
created. The mail is in the backup; nothing else remains.

## Monitoring

- `systemctl is-active stalwart`
- certificate expiry: `openssl x509 -in /etc/ssl/tailscale/mail.crt -noout -enddate`
- queue and delivery: `/admin` → Emails
- disk: `/var/lib/stalwart` growth

There are no metrics wired up by default. Stalwart can expose Prometheus metrics
and tracing if you need them; see its telemetry docs.
