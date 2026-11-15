# Tailnet mail (Unreleased)

**Release date:** Not released

## Summary

This is the first documented baseline of the private Tailscale mail server. The
repository has no tagged release, so these notes describe the current tree
rather than a published version.

The project installs Stalwart for SMTP, IMAP4, JMAP, and HTTPS, serves Bulwark
Lite at `/webmail/`, and uses a Tailscale-issued certificate for the node's
MagicDNS name. Every listener binds to loopback and the `100.x` address.

## Highlights

- One-command installer with preflight, bootstrap, recovery, certificate,
  listener, account, app-password, webmail, activation, firewall, renewal, and
  verification phases.
- Browser-free configuration through Stalwart's Bootstrap API and recovery-mode
  JMAP calls.
- Internal Stalwart accounts for humans, agents, and the administrator, with
  the full email address as the username.
- One account and one app password per agent, plus `scripts/tailmail.py` for
  sending, structured inbox reads, waiting for new messages, attachments, and
  reply threading. The optional `install-tailmail-harness.sh` configures this
  companion client without changing the server setup.
- Weekly certificate renewal through `mail-cert-renew.timer`.
- Installer modes for preflight, verification, diagnosis, resume, and
  reconfiguration after a tailnet IP change.

## Compatibility and Prerequisites

- Debian 12/13 or Ubuntu 24.04/26.04, x86_64 or aarch64.
- Tailscale installed and logged in, with MagicDNS and HTTPS certificates
  enabled for the tailnet.
- Ports 25, 465, 587, 993 and 443 free on the host.
- Root access.
- 2 GB free on `/var`; about 1 GB RAM recommended.
- Stalwart is installed from the official `get.stalw.art` installer and is not
  pinned by this repository. `stalwart-cli` is pinned to 1.0.14.

There is no upgrade path from a previous tagged release because no tagged
release exists.

## Installation or Upgrade

```bash
git clone https://github.com/Untethered-Explorers/stalwart-tailnet-mail.git
cd stalwart-tailnet-mail
./make-dist.sh
tar xzf dist/stalwart-tailnet-mail-*.tar.gz
cd stalwart-tailnet-mail-*
sudo ./setup-mail.sh
```

For unattended installs:

```bash
cp mail-setup.conf.example mail-setup.conf
# edit mail-setup.conf
sudo ./setup-mail.sh --config mail-setup.conf --yes
```

See the [Quick start](../02-quickstart.md) for the prompt table and the
web-wizard fallback, and the [Administrator guide](../admin-guide.md) for
upgrades and backups.

## Known Limitations

- Private tailnet only. No internet mail, no MX record, no port forwarding.
- No spam filtering, malware filtering, or DKIM for public receivers.
- Stalwart upgrades are manual, and the repository does not keep a rollback
  binary or pin a Stalwart version.
- No metrics are wired up by default.
- No tagged release or CI workflow; current automated coverage is limited.
- A custom `--domain` requires an externally supplied certificate, and the
  default Tailscale renewal timer does not cover it.
- The Dovecot migration path depends on the external Vandelay tool and has not
  been validated in this repository.

## Validation

Checked in the repository on 2026-11-15:

- `python3 -m unittest discover -s tests -p 'test_*.py'` passed.
- `python3 -m py_compile scripts/tailmail.py tests/test_tailmail.py` passed.
- `bash -n scripts/install-tailmail-harness.sh` passed.
- `bash tests/test-stalwart-tailnet-restart.sh` passed.
- `./make-dist.sh` built the tarball and printed its SHA-256; the archive
  contains the new harness guide, installer helper, and `tailmail.py`.
- `git diff --check` reported no whitespace errors.

Not run in this environment:

- `sudo ./setup-mail.sh --preflight`, `--check`, and a full install, because
  they need root and a live tailnet with HTTPS certificates enabled.
- Any SMTP/IMAP delivery test against a running Stalwart instance.
- The Dovecot migration commands.

There is a small standard-library test suite and a shell regression test, but
there is no CI workflow.

## Security and Privacy

- Mail and web listeners bind to `127.0.0.1` and the node's `100.x` address
  only.
- The recovery API on `:8080` is closed before activation.
- Secrets are written with mode 0600. The diagnostic bundle redacts `"secret"`
  fields from the Stalwart configuration but still contains logs and listener
  information.
- Backups contain the full mail store and must be protected as sensitive.
- Report vulnerabilities privately to the maintainer, not in a public issue.

## License

The project's original code and Markdown documentation are MIT-licensed; see
[LICENSE](../../LICENSE). Stalwart, `stalwart-cli`, Bulwark Lite, Tailscale, and
the distro packages retain their own licenses; see
[THIRD-PARTY-NOTICES.md](../../THIRD-PARTY-NOTICES.md).

## Documentation

- [README](../../README.md)
- [User guide](../user-guide.md)
- [Administrator guide](../admin-guide.md)
- [ADR index](../adr/README.md)
- [Changelog](../../CHANGELOG.md)
- [License](../../LICENSE)
- [Third-party notices](../../THIRD-PARTY-NOTICES.md)
- [Security](../06-security.md)
- [Troubleshooting](../05-troubleshooting.md)
