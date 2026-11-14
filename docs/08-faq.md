# FAQ

**Why not Roundcube?**

Roundcube is fine software, but it is PHP plus a web server plus a database.
Bulwark Lite is the same client as full Bulwark, served as static files by
Stalwart, with no extra process and no CORS. If you specifically want Roundcube,
nothing in the mail server prevents it — it speaks IMAP/SMTP like any client.

**Why Bulwark Lite and not full Bulwark?**

Lite covers mail, calendars, contacts and files. Full Bulwark adds a Node
process, an admin console, plugins, settings sync and web push. For a small
tailnet the extra process is not worth it. Switching later is a deployment
swap, not a data migration: the mail already lives in Stalwart.

**Why no Let's Encrypt / ACME?**

ACME needs a public name and inbound port 443 (or DNS API access). A tailnet
name is not publicly resolvable. Tailscale issues a trusted certificate for the
MagicDNS name instead, and the weekly timer renews it.

**Can I use my own domain?**

Yes, with caveats. Run the installer with `--domain example.com`. The Tailscale
certificate will not cover `example.com`, so you need your own certificate
installed as a `Certificate` object, and clients must resolve the name. Internet
mail additionally needs MX, SPF, DKIM, DMARC and port 25 — a different project.

**Can I have more than one domain?**

Stalwart supports multiple domains and aliases. The installer creates one. Add
more in `/admin` → Domains, then attach addresses to accounts.

**Can agents use the webmail?**

They can, but should not. Agents use SMTP/IMAP with their own app password.
The webmail is for humans and is not an API.

**Can an agent send as another address?**

Only addresses attached to its account. Add an alias in `/admin` if a shared
sender is required.

**Where is the mail stored?**

`/var/lib/stalwart` (RocksDB and message files). There is no Maildir on disk;
back up the directory, not a folder tree.

**How do I move the server to another machine?**

Install on the new host, copy `/var/lib/stalwart` while the service is stopped,
and start it there with the same MagicDNS name (Tailscale identity moves with
the machine or the name). Then retire the old host.

**Why does `sendmail` not exist?**

Stalwart is an SMTP server, not a sendmail implementation. Use SMTP submission
with an app password, `msmtp-mta` for compatibility, or `tailmail.py`.

**Why did my script lock `agent-bot` out?**

Auto-ban after repeated failed logins. A stale app password in a retry loop
does it. Rotate the credential, then retry.

**Is this safe to expose to the internet?**

No. It is designed for a tailnet: no spam filtering, no DKIM for public
receivers, no abuse handling. Keep it private.

**How do I delete everything?**

See "Uninstall" in [04-operations.md](04-operations.md). Take a backup first.

**Where do I report a problem?**

Run `sudo ./setup-mail.sh --diagnose` and `--check`, review the bundle, and
share it with whoever is helping you.
