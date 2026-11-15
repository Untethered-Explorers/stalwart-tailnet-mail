# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). This repository has no
tagged release yet, so `[Unreleased]` describes the current tree.

## [Unreleased]

### Added

- One-command installer for a private Stalwart mail server on a Tailscale
  tailnet, with preflight, bootstrap, recovery, certificate, listener, account,
  app-password, webmail, activation, firewall, renewal, and verification phases.
- Tailscale-issued TLS certificate for the node's MagicDNS name, with a weekly
  `mail-cert-renew.timer` that updates the Stalwart `Certificate` object over
  JMAP.
- Bulwark Lite webmail mounted as a Stalwart `Application` at `/webmail/`.
- Internal Stalwart accounts for humans, agents, and the administrator, using
  the full email address as the username.
- Per-agent app passwords and a generated `~/.config/tailmail/config` for the
  first agent.
- `scripts/tailmail.py`, a standard-library SMTP/IMAP client with `send`,
  `inbox`, and `read` commands.
- Harness-facing JSON output, IMAP wait, attachment transfer, and reply
  threading in `tailmail.py`, plus a per-user installer/configurator and an
  email-to-agent integration guide.
- Optional `tailmail_agent.py` watcher with interactive setup, sender
  allowlisting, per-project profiles, and per-user services for coding-agent
  hosts.
- Focused standard-library tests for the harness-facing mail client behavior.
- Installer modes for preflight, verification, diagnosis, resume, and
  reconfiguration after a tailnet IP change.
- A boot-time systemd helper that waits for Tailscale and restarts Stalwart only
  when its tailnet listeners are missing.
- Redacted support bundle generation for troubleshooting.
- Topic documentation, a user guide, an administrator guide, architecture
  decision records, and release notes.
- MIT license for the project's original code and Markdown documentation, plus
  `THIRD-PARTY-NOTICES.md` recording the upstream licenses and the distribution
  boundary.
- The hand-off tarball now includes the README, changelog, user and admin
  guides, ADRs, release notes, license, third-party notices, and `make-dist.sh`.
- The hand-off tarball includes the Tailscale boot helper and its systemd unit.

### Changed

- Configuration is applied through Stalwart's Bootstrap API and recovery-mode
  JMAP calls instead of the web wizard.
- Account management is documented through `/admin` and `/account` rather than
  installer re-runs.

### Fixed

- Corrected the installer log path in the documentation to
  `/var/lib/mail-setup/setup.log`.
- Expanded the uninstall steps to remove setup state, credentials, recovery
  password, and the mail certificate.

### Security

- All mail and web listeners bind to `127.0.0.1` and the node's `100.x`
  address; the recovery API on `:8080` is closed before activation.
- Secrets are written with mode 0600, and the diagnostic bundle redacts
  `"secret"` fields from the Stalwart configuration.
- The documentation states the private-tailnet boundary and the lack of spam
  filtering, malware filtering, and DKIM for public receivers.
- Replaced a real-looking MagicDNS hostname in the `tailmail.py` example with
  placeholders and corrected the example username to the full address.

[Unreleased]: https://github.com/Untethered-Explorers/stalwart-tailnet-mail/commits/main
