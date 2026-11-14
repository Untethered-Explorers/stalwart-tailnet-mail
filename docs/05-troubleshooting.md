# Troubleshooting

Run `sudo ./setup-mail.sh --diagnose` first when something fails. It writes a
redacted bundle to `/root` with versions, listeners, the journal and the
sanitized config.

## During the install

| Symptom | Cause | Fix |
|---|---|---|
| `HTTPS certificates are disabled` | Tailscale admin setting | Tailscale admin → DNS → enable HTTPS Certificates |
| `port(s) already in use: 25 465 993` | Postfix/Exim/Dovecot/OpenSMTPD running | stop and disable the old MTA, then re-run |
| `tailscale cert failed` | HTTPS disabled, or the name is not this node's | check the wizard's hostname equals `tailscale status` DNSName |
| `Bootstrap did not write config.json` | Bootstrap API rejected a field | check the log; fall back to the web wizard (see quick start) |
| `the Bootstrap step did not create domain <name>` | domain mismatch | the domain is what the script printed; re-run with `--domain` |
| Listener creation fails with a schema error | Stalwart changed a field | check the log line; the call is printed before it runs |
| `could not create an app password` | account id lookup failed | the script prints the JMAP response; check the account exists |

## After the install

| Symptom | Cause | Fix |
|---|---|---|
| Webmail login fails | username is not the full address | use `user@<host>.<tailnet>.ts.net` |
| Webmail returns 404 on `/webmail/` | bundle still downloading or download failed | wait, then `journalctl -u stalwart \| grep -i resource`; trigger `Action/UpdateApps` |
| `/admin` returns 302 | normal: redirect to login | open it in a browser |
| `501 You are not allowed to send from this address` | From is not an account address | send as the account, or add an alias |
| `535 ... credentials invalid` | wrong password, or account password changed | verify in `/account`; use the app password in configs |
| Client cannot connect from another node | ufw/ACL blocks the port | check `ufw status verbose` and tailnet grants |
| `Connection refused` on 993/465 | Stalwart not listening on the tailnet IP | `ss -ltn`, check binds; re-run `--reconfigure` |
| Certificate warning | certificate object not updated | run `/usr/local/sbin/mail-cert-renew`; check `/root/stalwart-api-key` |
| Mail stops after ~90 days | renewal timer failing | `systemctl status mail-cert-renew`, journal |
| Cron `sendmail: not found` | Stalwart has no sendmail binary | install `msmtp-mta` or call `tailmail.py` |
| Agent locked out | auto-ban after repeated bad logins | wait, or clear the ban in `/admin`; rotate the credential |

## API quirks worth knowing

These cost time during the original build. They are not bugs in your setup.

- **Listeners are created at the first normal start**, not by the Bootstrap
  step. That is why a browser-free install creates them explicitly.
- **`update` takes the object id, not the display name.** `query` may return a
  bare id list; `x:NetworkListener/get` returns objects with `id` and `name`.
- **`delete` uses `--ids`**, not a positional argument.
- **Certificate fields are tagged unions**: `certificate` is
  `{"@type":"Text","value":"<PEM>"}` and `privateKey` is
  `{"@type":"Text","secret":"<PEM>"}`. A raw PEM string is rejected.
- **Recovery mode only authenticates the recovery admin.** A regular account
  cannot create its own app password there; create app passwords for others
  through the admin JMAP call (`x:AppPassword/set` with `accountId`).
- **`query Domain --json` returns bare ids**, while `x:Domain/get` returns
  objects. Prefer JMAP for reads.
- **The wizard's domain field is easy to typo.** Always compare the account
  addresses after setup: `x:Account/get` and check the domain part.

## Reading Stalwart logs

```bash
journalctl -u stalwart -n 100 --no-pager
journalctl -u stalwart -f | grep -iE 'error|warn|listener|resource'
```

Common event names: `network.listen-start`, `network.build-error`,
`resource.application-updated`, `resource.error`, `authentication.failed`,
`smtp.connection`, `smtp.message`.

## Getting help

Collect:

```bash
sudo ./setup-mail.sh --diagnose
sudo ./setup-mail.sh --check
```

The bundle plus the output of `--check` answers most questions without exposing
secrets. Review the bundle before sharing it: it contains logs and listener
information, with secret fields redacted.
