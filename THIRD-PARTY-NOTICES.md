# Third-Party Notices

This repository contains the installer, the agent client, and documentation. It
does not bundle the mail server, webmail, CLI, or operating-system packages.
`setup-mail.sh` downloads or installs them at runtime. Each component remains
under its own license. This file summarizes those licenses and points to the
authoritative texts.

This is a compliance summary, not legal advice.

## Runtime components

| Component | How it enters the system | License | Authoritative source |
|---|---|---|---|
| Stalwart Mail Server | `setup-mail.sh` runs the official installer from `get.stalw.art` | AGPL-3.0-only OR LicenseRef-SEL (dual; the Community edition is AGPL-3.0-only) | [stalwartlabs/stalwart](https://github.com/stalwartlabs/stalwart), [AGPL text](https://github.com/stalwartlabs/stalwart/blob/main/LICENSES/AGPL-3.0-only.txt), [SEL text](https://github.com/stalwartlabs/stalwart/blob/main/LICENSES/LicenseRef-SEL.txt) |
| Stalwart CLI 1.0.14 | Downloaded from GitHub releases and installed as `/usr/local/bin/stalwart-cli` | AGPL-3.0-only OR LicenseRef-SEL | [stalwartlabs/cli](https://github.com/stalwartlabs/cli), [AGPL text](https://github.com/stalwartlabs/cli/blob/main/LICENSES/AGPL-3.0-only.txt), [SEL text](https://github.com/stalwartlabs/cli/blob/main/LICENSES/LicenseRef-SEL.txt) |
| Bulwark Lite | Downloaded as a Stalwart `Application` bundle from GitHub releases | AGPL-3.0-only, with an additional app-store distribution permission | [bulwarkmail/webmail](https://github.com/bulwarkmail/webmail), [LICENSE](https://github.com/bulwarkmail/webmail/blob/main/LICENSE) |
| Tailscale | Installed and logged in by the operator; used for MagicDNS and certificate issuance | BSD-3-Clause for the client; the certificate service is governed by Tailscale's terms | [tailscale/tailscale](https://github.com/tailscale/tailscale), [LICENSE](https://github.com/tailscale/tailscale/blob/main/LICENSE), [legal terms](https://tailscale.com/legal/) |
| Python 3 | Runtime for installer helper code and `scripts/tailmail.py` | PSF-2.0 | [Python license](https://docs.python.org/3/license.html) |

## System packages

These are installed with `apt-get` from the host distribution. They are not
bundled in this repository or the tarball.

| Package | Used for | License | Source |
|---|---|---|---|
| curl | Downloads the Stalwart installer and CLI; calls the renewal API | curl license | [curl copyright](https://curl.se/docs/copyright.html) |
| jq | Parses JMAP and certificate responses | MIT, with bundled third-party notices; documentation under CC BY 3.0 | [jq COPYING](https://github.com/jqlang/jq/blob/master/COPYING) |
| openssl | Generates passwords and checks certificate expiry | Apache-2.0 | [OpenSSL LICENSE](https://github.com/openssl/openssl/blob/master/LICENSE.txt) |
| python3 | Runs installer helpers and `tailmail.py` | PSF-2.0 | [Python license](https://docs.python.org/3/license.html) |
| ca-certificates | System CA trust store | GPL-2+ for the Debian packaging; certificates under the Mozilla CA Certificate Policy | [Debian copyright](https://sources.debian.org/src/ca-certificates/) |

## Host components

| Component | Used for | License | Source |
|---|---|---|---|
| systemd | Service and timer management | LGPL-2.1-or-later, with some parts under GPL-2.0-or-later | [systemd LICENSE](https://github.com/systemd/systemd/blob/main/LICENSE) |
| ufw | Optional firewall rules on `tailscale0` | GPL-3.0 | [ufw COPYING](https://git.launchpad.net/ufw/tree/COPYING) |
| Debian or Ubuntu base | Supported host distribution | Various free software licenses | [Debian licenses](https://www.debian.org/legal/licenses/), [Ubuntu legal](https://ubuntu.com/legal) |

## Distribution boundary

- The repository and the hand-off tarball contain the MIT-licensed project code
  and Markdown documentation, and no Stalwart, `stalwart-cli`, Bulwark Lite,
  Tailscale, or distro binaries.
- `setup-mail.sh` fetches the Stalwart installer from `get.stalw.art`, the
  `stalwart-cli` release from GitHub, and the Bulwark Lite bundle from GitHub.
  The operator accepts the upstream licenses when installing them.
- If you modify and redistribute Stalwart or Bulwark Lite, or offer a modified
  version as a network service, review the AGPL-3.0 obligations in the upstream
  license.
