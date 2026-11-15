# Email as a coding-agent harness channel

This optional companion setup lets an existing harness use a tailnet mailbox
for agent-to-user messages, replies, and email-triggered jobs. It is separate
from the Stalwart server install: it does not change the server, create
accounts, install an agent runtime, or run a background service.

The companion CLI is a transport adapter, not an orchestrator. Your harness
owns authorization, durable job tracking, workspace isolation, agent startup
and session resumption.

## What the companion CLI provides

`scripts/tailmail.py` uses only Python's standard library and provides:

- `send` over authenticated SMTP, including attachments and reply-thread
  headers;
- `inbox --json`, `read --json`, and `wait --json` over authenticated IMAP;
- optional attachment saving with generated safe filenames and a 10 MiB
  per-attachment limit by default;
- JSON output so a harness can consume mail without parsing human-readable
  output.

The CLI never launches an agent or executes an attachment. `wait` returns one
message after a caller-supplied IMAP UID; the harness must persist the cursor
and decide what to do with that message.

## 1. Create a mailbox for the harness

Create a dedicated user account in Stalwart for this harness or agent persona.
Use one account per independent agent when attribution and revocation matter.
Create an app password for this client and store it in a password manager
temporarily; the setup command will prompt for it. Do not use the admin
account. See [Accounts and agents](03-accounts-and-agents.md).

For different personas, create separate accounts or aliases and configure a
separate local client config for each. Each config should use that mailbox's
own app password.

## 2. Install and configure the companion CLI

Run this from the extracted project directory on the machine that runs the
harness. It installs the CLI to `~/.local/bin/tailmail` and prompts for the
server hostname, full mailbox address, optional sender alias, and app
password:

```bash
./scripts/install-tailmail-harness.sh
```

This does not use `sudo` or rerun `setup-mail.sh`. If `~/.local/bin` is not on
`PATH`, either add it or invoke `~/.local/bin/tailmail` directly. To configure
another mailbox later, run:

```bash
tailmail configure
```

The config is written to `~/.config/tailmail/config` with mode `0600`. Set
`TAILMAIL_CONFIG` to use a different file, for example when running different
personas under separate OS users or service environments. Protect that config
like a credential.

## 3. Check sending and receiving

Send a test message to a mailbox you control:

```bash
tailmail send --to alice@<mail-domain> \
  --subject "Harness mail test" \
  --body "The harness mailbox can send."
```

List recent mail as JSON, or read a message by its UID:

```bash
tailmail inbox --limit 5 --json
tailmail read 42 --json
```

To check the wait behavior, first note the latest UID from
`tailmail inbox --limit 1 --json`, then wait for a later message:

```bash
tailmail wait --after 42 --timeout 120 --json
```

It exits with status `3` when the timeout expires without a new message. A
successful JSON result includes the message `uid`, `message_id`, sender,
recipient, subject, body, and attachment metadata.

## 4. Connect it to an existing harness

Run a small bridge process alongside your existing agent runner. A typical
loop is:

1. Load a durable per-mailbox UID cursor from the harness database.
2. Call `tailmail wait --after <cursor> --timeout 60 --json`.
3. On exit `3`, poll again. On success, parse the JSON; validate the recipient,
   sender, subject convention, and any required job identifier.
4. Persist the message as a queued job and advance the UID cursor in one
   transaction. Deduplicate by mailbox plus UID (and retain `Message-ID` for
   threading).
5. Only after authorization, fetch attachments into a new, job-specific
   staging directory:

   ```bash
   tailmail read <uid> --json \
     --attachments-dir /path/to/jobs/<job-id>/incoming
   ```

6. Pass the validated body and staged files to the harness through its normal
   job API. Store the agent session ID and job state so a reply can resume the
   same session after a process restart.

On first startup, choose how to handle messages already in the mailbox: start
at UID `0` to process the backlog, or seed the cursor from the latest UID to
ignore older mail. Do not silently skip old mail if it may contain a request.

Do not use the email body as a shell command or interpolate it into a command
string. Invoke the agent through its normal API or a subprocess argument array,
with a fixed executable and explicit workspace. On completion, or when the
agent needs input, send a message through the CLI:

```bash
tailmail send --to alice@<mail-domain> \
  --subject "[job:<job-id>] Agent needs your input" \
  --body "Which implementation option should I use?" --json
```

The JSON response includes the sent message's `message_id`. Save it and use it
to thread a later message:

```bash
tailmail send --to alice@<mail-domain> \
  --subject "[job:<job-id>] Work complete" \
  --body "The requested change is ready." \
  --in-reply-to '<message-id-from-earlier-message>' \
  --json
```

Keep the job ID in the subject and in the harness's durable state. On a reply,
match the job ID and/or `In-Reply-To`/`References` headers, authorize the
sender again, append the response to that job, then resume its saved agent
session. `read --json` and `wait --json` include those threading headers.
Never treat a subject alone as proof that a message belongs to a job.

## 5. Allow email to start jobs

To let a user start work by emailing the harness, keep the bridge running on a
machine that can reach the mail server over the tailnet. Configure it to watch
a dedicated trigger mailbox or persona address. The bridge should accept only
the intended recipient and authorized senders, deduplicate by mailbox UID,
create a fresh isolated workspace, and record the request before starting the
agent. Attachments are available through the `read` command above.

The configured sender address is ordinary email metadata, not cryptographic
proof of identity. The private tailnet and mailbox app password protect the
bridge's connection to Stalwart; they do not prove who authored a delivered
message. Restrict which tailnet devices can access the mail ports, use a
dedicated trigger mailbox, and require an additional approval or stronger
sender verification before allowing consequential actions.

## Security and operations

- Treat email text and attachments as untrusted input, including messages from
  an otherwise authorized sender. Prompt injection can arrive in either.
- Apply your own allowed-sender and recipient checks before queuing jobs. Do
  not run every message in a mailbox as an agent request.
- The CLI does not extract archives, scan for malware, or sanitize document
  contents. Do not execute attachments; enforce your own total message/job
  size limits and scan files if appropriate.
- Use a separate, least-privilege agent mailbox and app password. Keep the
  config at mode `0600`; revoke the app password if the runner is retired.
- Run the agent in a per-job workspace with only the permissions it needs.
  Keep human approval in front of deployment, external publication, and other
  consequential actions.
- Store the UID cursor, job ID, message IDs, and agent session ID durably.
  IMAP UIDs are scoped to a mailbox folder; do not share one cursor across
  mailboxes or folders.
- Mail server and harness logs can contain message content or attachment
  names. Set retention and access accordingly.

This server accepts mail only within its tailnet-only exposure model; this
guide does not enable public internet email or provide a hosted webhook.
