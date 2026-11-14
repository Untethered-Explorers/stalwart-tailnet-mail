# Administrator Guide

This guide is for the person who installs and operates the server. End-user
workflows are in the [User Guide](user-guide.md); the design rationale is in the
[ADR index](adr/README.md).

## Responsibilities and Architecture

You own the host, the Tailscale node, the Stalwart service, the certificate, the
accounts, and the backups. The installer handles the first install; it does not
monitor or upgrade the service for you.

Stalwart handles SMTP, IMAP4, JMAP, and HTTPS. Bulwark Lite is a Stalwart
`Application` at `/webmail/`. All listeners bind to loopback and the `100.x`
address. The certificate is a Tailscale-issued certificate for the MagicDNS
name, renewed by `mail-cert-renew.timer`. See [00-overview](00-overview.md) and
[ADR-0001](adr/0001-single-stalwart-process.md).

## Prerequisites

- Debian 12/13 or Ubuntu 24.04/26.04 on x86_64 or aarch64.
- Tailscale installed and logged in, with MagicDNS and HTTPS Certificates
  enabled in the Tailscale admin console.
- Ports 25, 465, 587, 993 and 443 free.
- Root access.
- 2 GB free on `/var`; about 1 GB RAM recommended.
- A tailnet device to test the webmail and a mail client from.

The installer checks the OS, architecture, Tailscale state, MagicDNS name,
tailnet IPv4 address, HTTPS capability, busy ports, and free space on `/var`. It
warns, but does not stop, when `/var` has less than 2 GB free.

## Installation

From a checkout:

```bash
git clone https://github.com/Untethered-Explorers/stalwart-tailnet-mail.git
cd stalwart-tailnet-mail
./make-dist.sh
tar xzf dist/stalwart-tailnet-mail-*.tar.gz
cd stalwart-tailnet-mail-*
sudo ./setup-mail.sh
```

The script prints the resolved host, domain, address, mailbox names, and webmail
choice, then asks for confirmation. It then runs these phases in order:

1. Preflight: OS, architecture, Tailscale, HTTPS, ports, disk.
2. Install: apt packages, Stalwart, `stalwart-cli` 1.0.14.
3. Bootstrap: writes `config.json` through the Bootstrap API.
4. Recovery: management API on `:8080`, no mail listeners.
5. Certificate: `tailscale cert` to a Stalwart `Certificate` object.
6. Listeners: 25/465/587/993/443 on loopback and the tailnet address.
7. Accounts: human, agents, administrator.
8. App passwords: one per agent.
9. API key: for certificate renewal.
10. Webmail: Bulwark Lite mounted at `/webmail/`.
11. Activate: recovery off, services on the real ports.
12. Firewall: ufw rules for `tailscale0` when ufw is active.
13. Renewal: weekly timer.
14. Agent configuration: `~/.config/tailmail/config` for the sudo user.
15. Verification: listeners, TLS, IMAP login, webmail and UI pages.

The order matches `main()` in `setup-mail.sh`.

Unattended install:

```bash
cp mail-setup.conf.example mail-setup.conf
# edit mail-setup.conf
sudo ./setup-mail.sh --config mail-setup.conf --yes
```

See [02-quickstart](02-quickstart.md) for the prompt table and the web-wizard
fallback if the Bootstrap API changes.

## Configuration

### Installer flags

| Flag | Effect |
|---|---|
| `--preflight` | Run the checks only; change nothing |
| `--check` | Verify an existing install |
| `--diagnose` | Write a redacted support bundle to `/root` |
| `--resume` | Continue from the last completed phase |
| `--reconfigure` | Re-render listeners after a tailnet IP change |
| `--no-webmail` | Skip Bulwark Lite |
| `--domain <name>` | Override the domain (certificate caveat) |
| `--config <file>` | Load values from a file |
| `--yes` | Do not prompt |

### Configuration file

| Variable | Default when blank |
|---|---|
| `MAIL_HOST` | This node's MagicDNS name from `tailscale status` |
| `MAIL_DOMAIN` | `MAIL_HOST` |
| `HUMAN_USER` | The user running `sudo` |
| `AGENT_USERS` | No agent accounts |
| `WEBMAIL` | `yes`; set `no` to skip Bulwark Lite |

`--domain` overrides `MAIL_DOMAIN`. `--no-webmail` overrides `WEBMAIL`. With
`--config` and `--yes`, the script does not prompt. Without `--yes`, it can
still prompt for values the file leaves blank.

A custom `--domain` is not covered by the Tailscale certificate. Install your
own certificate as a `Certificate` object and make clients resolve the name. The
generated renewal script targets `MAIL_DOMAIN`; with a custom domain, replace
`/usr/local/sbin/mail-cert-renew` or disable `mail-cert-renew.timer` and renew
the certificate yourself. See [01-prerequisites](01-prerequisites.md).

## Identity, Secrets, and TLS

| Role | Purpose | Credentials |
|---|---|---|
| human | person, webmail and mail clients | account password |
| agent | automation, SMTP/IMAP only | account password and app password |
| admin | `/admin` management | account password |

Accounts are internal to Stalwart; the username is the full email address. Mail
users do not need Linux accounts. Do not re-run the installer to add a user,
because it resets the existing human, agent, and administrator passwords and
issues new agent app passwords. Add and remove accounts in `/admin` under
**Management → Directory → Accounts**. See
[03-accounts-and-agents](03-accounts-and-agents.md#adding-accounts-after-install).

Secrets:

| Secret | Path | Mode |
|---|---|---|
| account and admin passwords | `/root/mail-credentials.txt` | 0600, delete after storing |
| certificate renewal API key | `/root/stalwart-api-key` | 0600 |
| recovery admin password | `/root/stalwart-recovery-password` | 0600 |
| agent config | `~/.config/tailmail/config` | 0600 |
| TLS private key | `/etc/ssl/tailscale/mail.key` | 0600 |
| Stalwart data, including mail and settings | `/var/lib/stalwart` | `stalwart` user |

TLS:

- `tailscale cert` obtains a certificate for the node's MagicDNS name.
- `/usr/local/sbin/mail-cert-renew` fetches a new certificate, updates the
  `Certificate` object over JMAP, and restarts Stalwart only if the certificate
  changed. It targets `MAIL_DOMAIN`; replace it for a custom domain.
- `mail-cert-renew.timer` runs weekly with a randomized delay.
- The renewal script authenticates with `/root/stalwart-api-key`.

Force a renewal check:

```bash
systemctl list-timers mail-cert-renew.timer
sudo systemctl start mail-cert-renew.service
sudo /usr/local/sbin/mail-cert-renew
```

If the API key is lost, create a new one in `/admin` under the account's API
keys, or in recovery mode, and write it to `/root/stalwart-api-key`.

## Storage and Backups

Mail and configuration live together in `/var/lib/stalwart` (RocksDB). Stop the
service for a consistent copy:

```bash
sudo systemctl stop stalwart
sudo tar -C /var/lib -czf /root/stalwart-$(date +%F).tar.gz stalwart
sudo systemctl start stalwart
```

Copy the archive off the machine. Also keep `/etc/ssl/tailscale` and
`/root/stalwart-api-key`.

Restore:

```bash
sudo systemctl stop stalwart
# replace /var/lib/stalwart from the archive
sudo chown -R stalwart:stalwart /var/lib/stalwart
sudo systemctl start stalwart
```

Backups contain the mail, account settings, and possibly secrets. Treat them as
sensitive.

## Health Checks and Monitoring

```bash
sudo ./setup-mail.sh --check
sudo systemctl status stalwart --no-pager
sudo journalctl -u stalwart -n 100 --no-pager
ss -ltn | grep -E ':(25|465|587|993|443|8080) '
openssl x509 -in /etc/ssl/tailscale/mail.crt -noout -enddate
```

`--check` verifies the Stalwart service, listeners on the tailnet address, TLS
chain and hostname on 993/465/443, IMAP login as the human account, and HTTP 200
from the webmail, `/admin`, and `/account` pages. It reports a failure if
`:8080` is still open. It does not independently reject a wildcard bind, so
review the `ss` output for `0.0.0.0` or `::`. The verification function reports
failures in its output but exits 0, so read the output rather than relying on
the exit status.

No metrics are wired up by default. Stalwart can expose Prometheus metrics and
tracing if you need them; see its telemetry documentation. The mail queue is
visible in `/admin` under Emails. Watch the growth of `/var/lib/stalwart`.

## Upgrades and Rollback

### Stalwart

Stalwart is not an apt package. Take a backup, then run the official installer
again:

```bash
sudo systemctl stop stalwart
sudo tar -C /var/lib -czf /root/stalwart-$(date +%F).tar.gz stalwart
sudo systemctl start stalwart
curl --proto '=https' --tlsv1.2 -fsSL https://get.stalw.art/install.sh -o /tmp/install.sh
sudo sh /tmp/install.sh
sudo ./setup-mail.sh --check
```

Read the release notes for schema or configuration changes. Do not skip major
versions. The repository does not pin a Stalwart version and does not keep a
rollback binary. To roll back, restore the data backup and reinstall the
previous Stalwart version; there is no automated rollback.

### Bulwark Lite

The webmail is an `Application` object. Point it at a newer release and trigger
the download:

```bash
sudo stalwart-cli --url https://<host> --user admin@<domain> --password '<admin>' \
  update Application <id> \
  --field resourceUrl=https://github.com/bulwarkmail/webmail/releases/download/<version>/bulwark-lite-stalwart.zip
sudo stalwart-cli --url https://<host> --user admin@<domain> --password '<admin>' \
  create Action/UpdateApps
```

Find the Application id in `/admin` under Settings → Web Applications. Open tabs
pick up the new build on their next navigation.

## Troubleshooting

Run `sudo ./setup-mail.sh --diagnose` first. It writes
`/root/mail-setup-diagnose-<timestamp>.tar.gz` with versions, listeners, the
journal, and the sanitized configuration. Review it before sharing; it contains
logs and listener information with `"secret"` fields redacted.

The symptom, cause, and fix tables are in
[05-troubleshooting](05-troubleshooting.md). Common failures:

- `HTTPS certificates are disabled`: enable HTTPS Certificates in the Tailscale
  admin console under DNS.
- A port is busy: stop the old MTA and re-run.
- `tailscale cert failed`: HTTPS is disabled, or the hostname is not this node's
  MagicDNS name.
- Webmail 404: the bundle has not downloaded; check the Stalwart log for
  `resource.` events and run `Action/UpdateApps`.
- Mail stops after about 90 days: the renewal timer is failing; check
  `systemctl status mail-cert-renew` and the journal.

## Security and Privacy Checklist

- [ ] All listeners are on `127.0.0.1` and the `100.x` address; `ss -ltn` shows
      no `0.0.0.0` or `::` binds for 25/465/587/993/443.
- [ ] `:8080` is closed after activation.
- [ ] ufw, nftables, or the cloud firewall allows the mail ports only on
      `tailscale0`.
- [ ] Tailnet ACLs limit which devices can reach the mail ports.
- [ ] `/root/mail-credentials.txt` has been moved to a password manager and
      deleted.
- [ ] Secrets remain mode 0600; backups are protected as sensitive data.
- [ ] Recovery mode is reached only through loopback or an SSH tunnel, for as
      short a time as possible, and the recovery variables are disabled
      afterwards.
- [ ] Stalwart, Bulwark Lite, Tailscale, and OS packages are current.
- [ ] There is no public MX record, port forwarding, or public DNS entry for the
      mail service.

Upstream licenses are part of your responsibility. Stalwart and
`stalwart-cli` are AGPL-3.0-only OR SELv2; Bulwark Lite is AGPL-3.0-only with an
additional app-store permission. Review those terms for your use and see
[THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md).

The threat model and non-goals are in [06-security](06-security.md).

## Recovery and Support

Recovery mode stops the mail services and serves the management API on plain
HTTP `:8080` with brute-force protection disabled. Treat it as reachable on
every interface: use an SSH tunnel and keep the window short.

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

For a support request, collect:

```bash
sudo ./setup-mail.sh --diagnose
sudo ./setup-mail.sh --check
```

The bundle plus the output of `--check` answer most questions without exposing
secrets. Do not include passwords or app passwords in a report.
