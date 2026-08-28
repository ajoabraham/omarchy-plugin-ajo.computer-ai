#!/usr/bin/env python3
"""Build an RFC 5322 message and print it to stdout, for himalaya to send or
save. Transport (SMTP/IMAP, multi-account, credentials) is himalaya's job;
this only constructs safe MIME — header-injection defence, attachments, and
the editable review file.

Modes:
  --emit         --from A --to B --subject S [--body T] [--attach F ...]
                 build a message from args and print it (body from stdin if
                 --body omitted)
  --make-editable FILE   --from A [--to ...] [--subject ...] [--body ...] [--attach F ...]
                 write a human-editable message file (headers + body)
  --emit-file FILE       parse an edited file and print the built message
  --summary-file FILE    print To/Cc/Subject/attachments for the review prompt
"""
import argparse
import mimetypes
import os
import re
import sys
from email.message import EmailMessage
from email.utils import formatdate, make_msgid, parseaddr

MAX_ATTACH = 20 * 1024 * 1024  # Gmail rejects over ~25MB; stay under.


def die(msg, code=2):
    print(f"mail-compose: {msg}", file=sys.stderr)
    sys.exit(code)


def clean_header(value, label):
    v = (value or "").strip()
    if any(ord(c) < 32 and c not in "\t" for c in v):
        die(f"{label} contains a control character (possible header injection) — refused.", 2)
    return v


def valid_email(addr):
    _, e = parseaddr(addr)
    return bool(e) and re.match(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", e)


def split_recipients(raw):
    if not raw:
        return []
    parts = [p.strip() for p in re.split(r"[,;]", raw) if p.strip()]
    for p in parts:
        if not valid_email(p):
            die(f"'{p}' does not look like an email address.", 2)
    return parts


def attach_files(msg, paths):
    for path in paths:
        path = os.path.expanduser(path.strip())
        if not path:
            continue
        if not os.path.isfile(path):
            die(f"attachment not found: {path}", 2)
        size = os.path.getsize(path)
        if size > MAX_ATTACH:
            die(f"attachment {os.path.basename(path)} is {size // (1024*1024)}MB — "
                f"over the {MAX_ATTACH // (1024*1024)}MB limit.", 2)
        ctype, _ = mimetypes.guess_type(path)
        maintype, _, subtype = (ctype or "application/octet-stream").partition("/")
        with open(path, "rb") as f:
            data = f.read()
        msg.add_attachment(data, maintype=maintype, subtype=subtype or "octet-stream",
                           filename=os.path.basename(path))


def compose(frm, to="", cc="", bcc="", subject="", body="", attach=None):
    msg = EmailMessage()
    frm = clean_header(frm, "from")
    if not frm:
        die("a From address is required.", 2)
    msg["From"] = frm
    msg["To"] = ", ".join(split_recipients(clean_header(to, "to")))
    if (cc or "").strip():
        msg["Cc"] = ", ".join(split_recipients(clean_header(cc, "cc")))
    if (bcc or "").strip():
        msg["Bcc"] = ", ".join(split_recipients(clean_header(bcc, "bcc")))
    msg["Subject"] = clean_header(subject, "subject")
    msg["Date"] = formatdate(localtime=True)
    msg["Message-ID"] = make_msgid(domain=frm.split("@")[-1].strip(">"))
    msg.set_content(body if body.endswith("\n") else body + "\n")
    if attach:
        attach_files(msg, attach)
    if not msg["To"]:
        die("a recipient (To) is required.", 2)
    return msg


# --- editable review file -------------------------------------------------

EDIT_HELP = (
    "# Edit freely. Lines up to the first blank line are headers (To, Cc, Bcc,\n"
    "# Subject, Attach); everything below the blank line is the message body.\n"
    "# Attach: one file path per line, or comma-separated. Save and close to\n"
    "# continue; you will be asked before anything is sent.\n")


def oneline(v):
    return " ".join((v or "").splitlines()).strip()


def write_editable(path, to="", cc="", subject="", body="", attach=None):
    with open(path, "w") as f:
        f.write(EDIT_HELP)
        f.write(f"To: {oneline(to)}\n")
        f.write(f"Cc: {oneline(cc)}\n")
        f.write(f"Subject: {oneline(subject)}\n")
        f.write(f"Attach: {', '.join(attach) if attach else ''}\n\n")
        f.write(body.rstrip("\n") + "\n")
    os.chmod(path, 0o600)


def read_editable(path):
    with open(path) as f:
        lines = f.read().splitlines()
    lines = [ln for ln in lines if not ln.startswith("#")]
    while lines and not lines[0].strip():
        lines.pop(0)
    headers, i = {}, 0
    while i < len(lines) and lines[i].strip():
        if ":" in lines[i]:
            k, v = lines[i].split(":", 1)
            headers[k.strip().lower()] = v.strip()
        i += 1
    body = "\n".join(lines[i + 1:]) if i < len(lines) else ""
    attach = [a.strip() for a in re.split(r"[,\n]", headers.get("attach", "")) if a.strip()]
    return {"to": headers.get("to", ""), "cc": headers.get("cc", ""),
            "bcc": headers.get("bcc", ""), "subject": headers.get("subject", ""),
            "attach": attach, "body": body}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--emit", action="store_true")
    ap.add_argument("--make-editable", metavar="FILE")
    ap.add_argument("--emit-file", metavar="FILE")
    ap.add_argument("--summary-file", metavar="FILE")
    ap.add_argument("--from", dest="frm", default="")
    ap.add_argument("--to", default="")
    ap.add_argument("--cc", default="")
    ap.add_argument("--bcc", default="")
    ap.add_argument("--subject", default="")
    ap.add_argument("--body", default=None)
    ap.add_argument("--attach", action="append", default=[])
    args = ap.parse_args()

    if args.make_editable:
        write_editable(args.make_editable, to=args.to, cc=args.cc,
                       subject=args.subject,
                       body=(args.body or ""), attach=args.attach)
        return

    if args.summary_file:
        fields = read_editable(args.summary_file)
        print(f"To: {fields['to']}")
        if fields["cc"]:
            print(f"Cc: {fields['cc']}")
        print(f"Subject: {fields['subject'] or '(no subject)'}")
        for a in fields["attach"]:
            p = os.path.expanduser(a)
            mark = "" if os.path.isfile(p) else "  [MISSING]"
            sz = f" ({os.path.getsize(p)//1024}KB)" if os.path.isfile(p) else ""
            print(f"Attach: {a}{sz}{mark}")
        # Validate so a bad recipient/attachment fails the review, not the send.
        compose(args.frm or "x@y.z", to=fields["to"], cc=fields["cc"],
                bcc=fields["bcc"], subject=fields["subject"],
                body=fields["body"], attach=fields["attach"])
        return

    if args.emit_file:
        f = read_editable(args.emit_file)
        msg = compose(args.frm, to=f["to"], cc=f["cc"], bcc=f["bcc"],
                      subject=f["subject"], body=f["body"], attach=f["attach"])
        sys.stdout.buffer.write(msg.as_bytes())
        return

    # default: --emit from args
    body = args.body
    if body is None:
        body = sys.stdin.read()
    msg = compose(args.frm, to=args.to, cc=args.cc, bcc=args.bcc,
                  subject=args.subject, body=body, attach=args.attach)
    sys.stdout.buffer.write(msg.as_bytes())


if __name__ == "__main__":
    main()
