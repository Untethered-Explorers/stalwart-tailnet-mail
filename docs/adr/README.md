# Architecture Decision Records

*The durable architectural decisions for this project, one decision per record.
Each record states the options considered, the choice, and the consequences
accepted. Link this index from the project README and keep it accurate as
records are added or superseded.*

| ADR | Title | Status | Date |
|---|---|---|---|
| [ADR-0001](0001-single-stalwart-process.md) | [Use Stalwart as the only mail and web process](0001-single-stalwart-process.md) | Accepted | 2026-11-14 |
| [ADR-0002](0002-tailnet-only-listeners.md) | [Bind all listeners to loopback and the tailnet address](0002-tailnet-only-listeners.md) | Accepted | 2026-11-14 |
| [ADR-0003](0003-tailscale-issued-certificates.md) | [Use Tailscale-issued certificates and renew them weekly](0003-tailscale-issued-certificates.md) | Accepted | 2026-11-14 |
| [ADR-0004](0004-bootstrap-api-in-recovery-mode.md) | [Configure Stalwart through the Bootstrap API in recovery mode](0004-bootstrap-api-in-recovery-mode.md) | Accepted | 2026-11-14 |
| [ADR-0005](0005-internal-accounts-and-app-passwords.md) | [Use internal accounts, full-address usernames, and per-agent app passwords](0005-internal-accounts-and-app-passwords.md) | Accepted | 2026-11-14 |
| [ADR-0006](0006-bulwark-lite-as-application.md) | [Serve Bulwark Lite as a Stalwart Application](0006-bulwark-lite-as-application.md) | Accepted | 2026-11-14 |
| [ADR-0007](0007-date-stamped-tarball.md) | [Distribute a date-stamped, self-contained tarball](0007-date-stamped-tarball.md) | Accepted | 2026-11-15 |

## Rules

- One row per record, in identifier order, with no gaps in numbering.
- Keep each row's status and date in step with the record they point at.
- When a record is superseded, update its row to `Superseded by ADR-NNNN` and
  link the replacement in the same row rather than deleting the entry.
- Fill a row from the record itself rather than from memory; the index is a
  directory, not a summary.
