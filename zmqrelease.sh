#!/bin/bash

set -u
PATH=$PATH:/opt/zimbra/bin:/usr/bin:/bin:/usr/sbin:/sbin
LOG="${ZMQ_LOG:-$HOME/zmqrelease.log}"

die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(whoami)" = "zimbra" ] || die "run as the zimbra user (su - zimbra)"
command -v zmprov >/dev/null 2>&1 || die "zmprov not found; is this a Zimbra mailbox server?"

QACCT=$(zmprov gcf zimbraAmavisQuarantineAccount 2>/dev/null | awk '{print $2}')
[ -n "$QACCT" ] || die "could not read zimbraAmavisQuarantineAccount"
MBOXID=$(zmprov gmi "$QACCT" 2>/dev/null | awk '/mailboxId/{print $2}')
[ -n "$MBOXID" ] || die "could not get mailbox ID for $QACCT"
QDIR="/opt/zimbra/store/0/$MBOXID/msg/0"
[ -d "$QDIR" ] || die "quarantine store not found: $QDIR"

# hdr <file> <Header-Name>  -> first matching header value (reads first 150 lines only)
hdr() {
  head -n 150 "$1" | grep -m1 -i "^$2:" | sed 's/^[^:]*:[[:space:]]*//; s/[<>"]//g; s/\r//g'
}

# resolve <file-or-name> -> full path
resolve() {
  local f="$1"
  [ -f "$f" ] || f="$QDIR/$1"
  [ -f "$f" ] || die "file not found: $1"
  echo "$f"
}

show_file() {
  local f="$1"
  echo "File:      $f"
  echo "Subject:   $(hdr "$f" Subject)"
  echo "Date:      $(hdr "$f" Date)"
  echo "Msg-ID:    $(hdr "$f" Message-ID)"
  echo "From:      $(hdr "$f" X-Envelope-From)"
  echo "To(block): $(hdr "$f" X-Envelope-To-Blocked)"
  echo "Size:      $(stat -c %s "$f") bytes"
  echo
}

cmd="${1:-}"
case "$cmd" in
  info)
    echo "Quarantine account: $QACCT"
    echo "Mailbox ID:         $MBOXID"
    echo "Store path:         $QDIR"
    echo "Files:              $(ls -1 "$QDIR" | wc -l)"
    ;;

  find)
    [ $# -eq 2 ] || die "usage: $0 find <Message-ID>"
    id="${2//[<>]/}"
    found=0
    for f in "$QDIR"/*; do
      [ -f "$f" ] || continue
      if head -n 150 "$f" | grep -qiF -- "$id"; then
        found=1
        show_file "$f"
      fi
    done
    [ $found -eq 1 ] || { echo "No quarantined file matches Message-ID: $id"; exit 2; }
    echo "Next: $0 inspect <file> <your-mailbox>   then   $0 release <file>"
    ;;

  search)
    [ $# -eq 2 ] || die "usage: $0 search <text>"
    matches=$(grep -lai -F -- "$2" "$QDIR"/* 2>/dev/null)
    [ -n "$matches" ] || { echo "No file contains: $2"; exit 2; }
    while IFS= read -r f; do show_file "$f"; done <<< "$matches"
    ;;

  show)
    [ $# -eq 2 ] || die "usage: $0 show <file>"
    show_file "$(resolve "$2")"
    ;;

  inspect)
    [ $# -eq 3 ] || die "usage: $0 inspect <file> <your-mailbox>"
    f=$(resolve "$2"); me="$3"
    sender=$(hdr "$f" X-Envelope-From)
    [ -n "$sender" ] || die "no X-Envelope-From in file"
    show_file "$f"
    zmprov ga "$me" zimbraId >/dev/null 2>&1 || die "mailbox does not exist: $me"
    zmlmtpinject -r "$me" -s "$sender" "$f" || die "zmlmtpinject failed"
    echo "$(date '+%F %T') INSPECT $(basename "$f") -> $me" >> "$LOG"
    cat <<EOF
Copy injected to $me.
Now: download the ZIP, run sha256sum, check VirusTotal, and confirm with the
sender over another channel. 'Not found' on VirusTotal does NOT mean clean.
Then: $0 release $(basename "$f")
EOF
    ;;

  release)
    [ $# -ge 2 ] && [ $# -le 4 ] || die "usage: $0 release <file> [rcpt] [sender]"
    f=$(resolve "$2")
    rcpt="${3:-$(hdr "$f" X-Envelope-To-Blocked | awk '{print $1}')}"
    sender="${4:-$(hdr "$f" X-Envelope-From | awk '{print $1}')}"
    [ -n "$rcpt" ]   || die "no recipient found; pass it as the 3rd argument"
    [ -n "$sender" ] || die "no sender found; pass it as the 4th argument"
    zmprov ga "$rcpt" zimbraId >/dev/null 2>&1 || die "recipient mailbox does not exist: $rcpt"
    show_file "$f"
    echo "About to RELEASE (bypasses antivirus):"
    echo "  to:   $rcpt"
    echo "  from: $sender"
    read -r -p "Have you verified this file and the sender? Type 'yes' to continue: " ans
    [ "$ans" = "yes" ] || die "aborted"
    zmlmtpinject -r "$rcpt" -s "$sender" "$f" || die "zmlmtpinject failed"
    echo "$(date '+%F %T') RELEASE $(basename "$f") -> $rcpt (from $sender)" >> "$LOG"
    echo "Released. Verify: grep \"$rcpt\" /var/log/zimbra.log | grep -i lmtp | tail -5"
    echo "Ask the user to check Inbox and Junk."
    ;;

  *)
    sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'
    [ -z "$cmd" ] || exit 1
    ;;
esac
