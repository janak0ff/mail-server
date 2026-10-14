# zmqrelease.sh

Find and release emails that Zimbra has quarantined because the attachment could not be scanned, for example `Heuristics.Encrypted.Zip` (password-protected ZIP files).

Quarantined mails have subjects such as:

```
[WARNING: ATTACHMENT UNSCANNED][WARNING: MESSAGE ENCRYPTED]Re:
```

Forwarding or redirecting these from webmail fails because the copy is scanned and quarantined again. This script re-injects the raw message over LMTP with `zmlmtpinject`, which skips the antivirus scan.

> **Important:** "Encrypted ZIP" means ClamAV could not scan the file. It does not mean the file is clean. Always inspect and confirm with the sender before releasing.

## Features

- Detects the quarantine account, mailbox ID and store path automatically (nothing hardcoded)
- Finds the exact file by the Message-ID from the virus alert
- Searches by sender, subject or keyword
- Shows key headers without printing the message body
- Sends an inspection copy to your own mailbox first
- Releases to the real recipient and sender, read from the message headers
- Asks for typed confirmation before releasing
- Checks that the target mailbox exists before injecting
- Logs every inspect and release action

## Requirements

- Zimbra mailbox store server (the one holding `/opt/zimbra/store`)
- Run as the `zimbra` user (`su - zimbra`)
- `bash`, `awk`, `sed`, `grep`, `stat` (standard on Linux)
- For the one-line install: outbound HTTPS to `raw.githubusercontent.com`

## Installation

Download and review it first:

```bash
su - zimbra
curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/<commit-or-branch>/zimbra/zmqrelease.sh -o zmqrelease.sh
chmod +x zmqrelease.sh
```

Or run it without saving. Arguments go after a throwaway `$0` word (`zmq`):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/<commit-sha>/zimbra/zmqrelease.sh)" zmq info
```

Pin the URL to a **commit SHA** rather than a branch. The script runs as `zimbra` and can inject mail, so a branch that changes later would change what runs on your server.

## Usage

```
zmqrelease.sh <command> [args]

  info                              show quarantine account, mailbox ID, store path
  find <Message-ID>                 find file(s) by Message-ID from the virus alert
  search <text>                     find file(s) by sender / subject / keyword
  show <file>                       show key headers of one file
  inspect <file> <your-mailbox>     inject a copy to YOUR mailbox for checking
  release <file> [rcpt] [sender]    release to the real recipient (asks to confirm)
```

`<file>` can be a bare name (`306-3016.msg`) or a full path.

## Workflow

1. **Get the Message-ID** from the virus alert email the user received.
2. **Find the file:**
   ```bash
   ./zmqrelease.sh find "20260914101453.648958109C8C@proxy.example.org.np"
   ```
3. **Inspect a copy** in your own mailbox:
   ```bash
   ./zmqrelease.sh inspect 306-3016.msg your.admin@example.org.np
   ```
4. **Verify the attachment:**
   - Download the ZIP.
   - Hash it: `sha256sum file.zip` (Linux) or `Get-FileHash file.zip -Algorithm SHA256` (PowerShell).
   - Search the hash on VirusTotal. For encrypted ZIPs, "not found" is common and does not prove it is clean.
   - Confirm with the sender over a separate channel that they sent it and that a password-protected ZIP is expected.
5. **Release:**
   ```bash
   ./zmqrelease.sh release 306-3016.msg
   ```
   The script shows the recipient and sender, then asks you to type `yes`.
6. **Check delivery:**
   ```bash
   grep "recipient@example.org.np" /var/log/zimbra.log | grep -i lmtp | tail -5
   ```
   Ask the user to check **Inbox and Junk**.

## How it works

1. `zmprov gcf zimbraAmavisQuarantineAccount` returns the hidden quarantine account.
2. `zmprov gmi <account>` returns its mailbox ID.
3. Messages live in `/opt/zimbra/store/0/<mailboxId>/msg/0/`.
4. `find` and `show` read only the first 150 lines of each file to get headers.
5. `release` takes the recipient from `X-Envelope-To-Blocked` and the sender from `X-Envelope-From`, unless you pass them.
6. `zmlmtpinject -r <recipient> -s <sender> <file>` delivers the raw message.

## Release with explicit addresses

```bash
./zmqrelease.sh release 351-3218.msg dibya@example.org.np ajeet@sender.example
```

When a message was blocked for several recipients, `release` uses only the first address in the header. Run it again with an explicit recipient for each of the others.

## Logging

Every `inspect` and `release` is appended to `~/zmqrelease.log`:

```
2026-10-14 15:02:11 INSPECT 306-3016.msg -> your.admin@example.org.np
2026-10-14 15:20:45 RELEASE 306-3016.msg -> recipient@example.org.np (from sender@example.com)
```

Environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `ZMQ_LOG` | `~/zmqrelease.log` | Log file path |
| `ZMQ_PROG` | `zmqrelease.sh` | Name shown in usage and hint messages |

## Safety notes

- Never `cat` quarantined files. They can be large and may be malicious. The script only reads headers.
- A wrong recipient leaks the mail, which matters most for keys, credentials and reports. Check the recipient shown before typing `yes`.
- Release only the file that matches the alert. Several files can share a sender and subject, one per blocked recipient or per message in a thread.
- Do not release a mail you could not confirm with the sender.
- Releasing bypasses the antivirus scan on purpose. Treat each release as your decision.

## Troubleshooting

| Problem | Cause and fix |
|---|---|
| `run as the zimbra user` | Run `su - zimbra` first. |
| `could not read zimbraAmavisQuarantineAccount` | Not a mailbox store server, or Amavis quarantine is not configured. |
| `No quarantined file matches Message-ID` | Wrong server (multi-server setups have one store per mailbox server), or the message was purged. Try `search` with the sender. |
| Message-ID prints blank in `show` | The header is folded onto the next line. Use `find` with the ID, which matches on the first 150 lines. |
| `no recipient found` | Header missing. Pass the recipient as the 3rd argument. |
| `mailbox does not exist` | Typo in the address, or a placeholder was left in. |
| Released mail not arriving | Check `/var/log/zimbra.log` for the recipient, then ask them to check Junk. |
| Mailbox ID differs between servers | Expected. The script looks it up each run. |
