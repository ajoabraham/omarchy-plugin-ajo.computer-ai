#!/usr/bin/env bash
# Email for the assistant, on top of the himalaya CLI. himalaya owns transport
# and multi-account config; this wraps it with safe MIME (mail-compose.py), a
# gnome-keyring credential (via secret-tool), and a human review-and-approve
# window for sending. One grantable rule: Bash(.../mail.sh:*).
#
#   mail.sh accounts                              list configured addresses
#   mail.sh setup                                 open a window to add an account
#   mail.sh configure                             interactive add-account (in the window)
#   mail.sh draft  [-a ACCT] --to A --subject S --body B [--attach F]
#   mail.sh send   [-a ACCT] --to A --subject S --body B [--attach F]
#
# 'draft' saves to Gmail Drafts. 'send' NEVER sends directly: it opens the
# message in an editor for the user to review, edit, and approve; only their
# keystroke there sends it. Secrets live in gnome-keyring, never on disk.
set -u
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hcfg="${HIMALAYA_CONFIG:-$HOME/.config/himalaya/config.toml}"
KR_SERVICE="computer-ai-mail"   # secret-tool attribute namespace

have() { command -v "$1" >/dev/null 2>&1; }
have himalaya || { echo "mail: himalaya is not installed (pacman -S himalaya)." >&2; exit 2; }

# --- account helpers -------------------------------------------------------
accounts_configured() { [ -f "$hcfg" ] && grep -qE '^\[accounts\.' "$hcfg"; }

# email address for an account name, read from the himalaya config.
account_email() {
  awk -v want="[accounts.$1]" '
    $0==want {inacct=1; next}
    /^\[accounts\./ {inacct=0}
    inacct && /^[[:space:]]*email[[:space:]]*=/ {
      gsub(/.*=[[:space:]]*"?|"[[:space:]]*$/,""); print; exit }' "$hcfg" 2>/dev/null
}

default_account() {
  # the account marked default=true, else the first one.
  awk '
    /^\[accounts\./ { name=$0; gsub(/^\[accounts\.|\][[:space:]]*$/,"",name); if(first=="")first=name }
    /^[[:space:]]*default[[:space:]]*=[[:space:]]*true/ { print name; found=1; exit }
    END { if(!found) print first }' "$hcfg" 2>/dev/null
}

list_accounts() { grep -oE '^\[accounts\.[^]]+\]' "$hcfg" 2>/dev/null | sed 's/^\[accounts\.//; s/\]$//'; }

# Resolve the -a flag (or default); print the account name, or fail with a
# message the assistant can relay.
resolve_account() {
  local want="$1"
  if ! accounts_configured; then
    echo "__NONE__"; return
  fi
  if [ -n "$want" ]; then
    if list_accounts | grep -qx "$want"; then echo "$want"; else echo "__MISSING__"; fi
    return
  fi
  local n; n=$(list_accounts | wc -l)
  if [ "$n" -gt 1 ]; then echo "__AMBIGUOUS__"; else default_account; fi
}

# --- setup / configure -----------------------------------------------------
if [ "${1:-}" = "setup" ]; then
  term=""; for t in ghostty alacritty foot kitty; do have "$t" && { term="$t"; break; }; done
  [ -n "$term" ] || { echo "mail: no terminal to open the setup window." >&2; exit 2; }
  title="Computer · email setup"
  inner="'$script_dir/mail.sh' configure; echo; read -n1 -r -p 'Press any key to close…'"
  case "$term" in
    ghostty)   launch=(ghostty --title="$title" -e bash -lc "$inner") ;;
    alacritty) launch=(alacritty --title "$title" -e bash -lc "$inner") ;;
    foot)      launch=(foot --title="$title" bash -lc "$inner") ;;
    kitty)     launch=(kitty --title "$title" bash -lc "$inner") ;;
  esac
  if have uwsm-app; then setsid uwsm-app -- "${launch[@]}" >/dev/null 2>&1 &
  else setsid "${launch[@]}" >/dev/null 2>&1 & fi
  echo "Opened an email setup window. Enter the account there; it applies as soon as you finish."
  exit 0
fi

if [ "${1:-}" = "configure" ]; then
  have secret-tool || { echo "mail: secret-tool (gnome-keyring) not found." >&2; exit 2; }
  gum=0; have gum && gum=1
  ask()  { if [ "$gum" = 1 ]; then gum input --prompt "$1 " --placeholder "$2"; else printf '%s ' "$1" >&2; IFS= read -r r; printf '%s' "$r"; fi; }
  askpw(){ if [ "$gum" = 1 ]; then gum input --password --prompt "$1 " --placeholder "$2"; else printf '%s ' "$1" >&2; stty -echo 2>/dev/null; IFS= read -r r; stty echo 2>/dev/null; printf '\n' >&2; printf '%s' "$r"; fi; }

  email=""; while :; do email=$(ask "Gmail address:" "you@gmail.com"); case "$email" in *@*.*) break;; *) echo "  not an email." >&2;; esac; done
  # A short label defaults to the local part; the user can override.
  suggest="${email%@*}"
  label=$(ask "Account label:" "$suggest"); label="${label:-$suggest}"
  label=$(printf '%s' "$label" | tr -cd 'a-zA-Z0-9_-')
  [ -n "$label" ] || label="$suggest"
  pw=$(askpw "App Password:" "16 chars from myaccount.google.com/apppasswords")
  pw=$(printf '%s' "$pw" | tr -d '[:space:]')
  [ -n "$pw" ] || { echo "mail: no password entered." >&2; exit 2; }

  # Store the secret in gnome-keyring; himalaya reads it via secret-tool.
  printf '%s' "$pw" | secret-tool store --label="Computer email: $email" service "$KR_SERVICE" account "$email"

  mkdir -p "$(dirname "$hcfg")"
  is_first=1; accounts_configured && is_first=0
  { [ -s "$hcfg" ] && echo;
    echo "[accounts.$label]"
    [ "$is_first" = 1 ] && echo "default = true"
    echo "email = \"$email\""
    echo "display-name = \"$label\""
    echo "mailbox.alias.inbox = \"INBOX\""
    echo "mailbox.alias.drafts = \"[Gmail]/Drafts\""
    echo "mailbox.alias.sent = \"[Gmail]/Sent Mail\""
    echo "mailbox.alias.trash = \"[Gmail]/Trash\""
    echo "imap.server = \"imaps://imap.gmail.com:993\""
    echo "imap.sasl.plain.username = \"$email\""
    echo "imap.sasl.plain.password.command = \"secret-tool lookup service $KR_SERVICE account $email\""
    echo "smtp.server = \"smtps://smtp.gmail.com:465\""
    echo "smtp.sasl.plain.username = \"$email\""
    echo "smtp.sasl.plain.password.command = \"secret-tool lookup service $KR_SERVICE account $email\""
  } >> "$hcfg"

  printf 'Checking… ' >&2
  if out=$(himalaya -a "$label" account check 2>&1 | sed 's/\x1b\[[0-9;]*m//g'); then
    echo "$out" | grep -qi fail && { echo "$out" >&2; echo "Saved, but sign-in failed — check the App Password and re-run setup." >&2; exit 4; }
    echo "Account '$label' ($email) is ready. Ask Computer to draft or send email."
  else
    echo "$out" >&2; exit 4
  fi
  exit 0
fi

# --- accounts list ---------------------------------------------------------
if [ "${1:-}" = "accounts" ]; then
  if ! accounts_configured; then echo "No email accounts configured yet. Run: mail.sh setup"; exit 0; fi
  for a in $(list_accounts); do printf '  %s\t%s%s\n' "$a" "$(account_email "$a")" \
      "$([ "$a" = "$(default_account)" ] && echo '  (default)')"; done
  exit 0
fi

# --- reading: inbox / read / search (all leave mail UNREAD) ----------------
# These need an account too; resolve -a the same way, then hand off to himalaya.
if [ "${1:-}" = "inbox" ] || [ "${1:-}" = "read" ] || [ "${1:-}" = "search" ]; then
  rmode="$1"; shift
  racct=""; rn=10; rargs=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -a|--account) racct="${2:-}"; shift 2 ;;
      -n|--number)  rn="${2:-10}"; shift 2 ;;
      *) rargs+=("$1"); shift ;;
    esac
  done
  acct=$(resolve_account "$racct")
  case "$acct" in
    __NONE__)      echo "No email account is set up yet. Open setup first: mail.sh setup" >&2; exit 5 ;;
    __MISSING__)   echo "No account named '$racct'. Configured: $(list_accounts | paste -sd, -)" >&2; exit 5 ;;
    __AMBIGUOUS__) echo "Which account? Configured: $(list_accounts | paste -sd, -). Pass -a <name>." >&2; exit 6 ;;
  esac

  fmt_envelopes() {  # JSON on stdin -> one clean line per message for the voice reply
    jq -r '(.envelopes // . // []) | (if type=="array" then . else [] end) | .[] |
      (((.flags // []) | map(tostring | ascii_downcase)) as $f
       | if ($f | index("seen")) then " " else "*" end) as $u |
      (.from[0] // {}) as $fr |
      "\($u) [\(.id // "?")] \($fr.name // $fr.email // "?") — \(.subject // "(no subject)") — \((.date // "")[0:16])"' 2>/dev/null
  }

  # himalaya --json prints errors as {"error":"..."} on stdout; get a clean line.
  hima_err() {  # $1=stdout-file $2=stderr-file
    local m
    m=$(jq -r 'try .error catch empty' "$1" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | head -1)
    [ -n "$m" ] || m=$(sed 's/\x1b\[[0-9;]*m//g' "$2" "$1" 2>/dev/null | grep -iE 'error|fail|invalid|reject|cannot' | head -1)
    echo "${m:-himalaya failed}"
  }

  if [ "$rmode" = "inbox" ]; then
    out=$(mktemp); err=$(mktemp)
    if himalaya -a "$acct" envelope list -m inbox -s "$rn" --json >"$out" 2>"$err"; then
      n=$(jq -r 'try ((.envelopes // . // []) | length) catch 0' "$out" 2>/dev/null)
      if [ -z "$n" ]; then
        echo "mail: unexpected inbox output — $(head -c 200 "$out" | tr '\n' ' ')" >&2
        rm -f "$out" "$err"; exit 1
      fi
      echo "Inbox — $acct ($n shown; * = unread):"
      [ "$n" -gt 0 ] 2>/dev/null && fmt_envelopes <"$out" || echo "  (no messages)"
    else
      echo "mail: could not list inbox — $(hima_err "$out" "$err")" >&2
      rm -f "$out" "$err"; exit 1
    fi
    rm -f "$out" "$err"; exit 0
  fi

  if [ "$rmode" = "search" ]; then
    [ ${#rargs[@]} -gt 0 ] || { echo "usage: mail.sh search [-a acct] <query>  (from alice, subject invoice, after 2026-08-01)" >&2; exit 2; }
    q="${rargs[*]}"
    # himalaya's grammar is strict (from/to/subject/body <val>, after/before
    # <date>, and/or/not). If the query doesn't start with a keyword, treat it
    # as free text and phrase-search subject+body, so a natural request works.
    first=$(printf '%s' "$q" | awk '{print tolower($1)}')
    case "$first" in
      from|to|subject|body|after|before|not|date|flag) query="$q" ;;
      *) esc=$(printf '%s' "$q" | sed 's/"/\\"/g'); query="subject \"$esc\" or body \"$esc\"" ;;
    esac
    out=$(mktemp); err=$(mktemp)
    if himalaya -a "$acct" envelope search -m inbox -s "$rn" --json -- "$query" >"$out" 2>"$err"; then
      n=$(jq -r 'try ((.envelopes // . // []) | length) catch 0' "$out" 2>/dev/null)
      echo "Search — $acct (${n:-0}):"
      [ "${n:-0}" -gt 0 ] 2>/dev/null && fmt_envelopes <"$out" || echo "  (no matches)"
    else
      m=$(hima_err "$out" "$err")
      case "$m" in
        *"cannot parse"*) echo "mail: search terms not understood — use himalaya syntax: from <x>, subject <x>, body <x>, after <YYYY-MM-DD>, before <YYYY-MM-DD>, joined with and/or/not." >&2 ;;
        *) echo "mail: search failed — $m" >&2 ;;
      esac
      rm -f "$out" "$err"; exit 1
    fi
    rm -f "$out" "$err"; exit 0
  fi

  # read <id> — prints headers + plain text; leaves the message unread.
  [ ${#rargs[@]} -gt 0 ] || { echo "usage: mail.sh read [-a acct] <message-id>" >&2; exit 2; }
  himalaya -a "$acct" message read -m inbox "${rargs[0]}" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
  exit ${PIPESTATUS[0]}
fi

# --- parse -a for draft/send ----------------------------------------------
mode="${1:-}"; shift || true
acct_flag=""
argv=()
while [ $# -gt 0 ]; do
  case "$1" in
    -a|--account) acct_flag="${2:-}"; shift 2 ;;
    *) argv+=("$1"); shift ;;
  esac
done
set -- "${argv[@]+"${argv[@]}"}"

acct=$(resolve_account "$acct_flag")
case "$acct" in
  __NONE__)      echo "No email account is set up yet. Open setup first: mail.sh setup" >&2; exit 5 ;;
  __MISSING__)   echo "No account named '$acct_flag'. Configured: $(list_accounts | paste -sd, -)" >&2; exit 5 ;;
  __AMBIGUOUS__) echo "Which account? Configured: $(list_accounts | paste -sd, -). Pass -a <name>." >&2; exit 6 ;;
esac
from=$(account_email "$acct")
[ -n "$from" ] || { echo "mail: could not resolve the address for account '$acct'." >&2; exit 2; }

# --- draft: build MIME, save to Gmail Drafts via himalaya ------------------
if [ "$mode" = "draft" ]; then
  mime=$("$script_dir/mail-compose.py" --emit --from "$from" "$@") || exit $?
  err=$(mktemp)   # NEVER write into $script_dir — the plugin dir reloads on change
  # himalaya prints errors to STDOUT, so capture combined output.
  if printf '%s' "$mime" | himalaya -a "$acct" message add -m drafts >"$err" 2>&1; then
    echo "Draft saved to $from's Gmail Drafts. Review and send it from Gmail; nothing was sent."
    rm -f "$err"
  else
    msg=$(sed 's/\x1b\[[0-9;]*m//g' "$err" | grep -iE 'error|fail|invalid|reject' | head -1)
    echo "mail: could not save the draft — ${msg:-himalaya failed}" >&2
    rm -f "$err"; exit 1
  fi
  exit 0
fi

# --- send: open the message for review + approval, then himalaya sends -----
if [ "$mode" = "send" ]; then
  f=$(mktemp --suffix=.eml) || exit 2; chmod 600 "$f"
  if ! "$script_dir/mail-compose.py" --make-editable "$f" "$@" 2>"$f.err"; then
    cat "$f.err" >&2; rm -f "$f" "$f.err"; exit 3
  fi
  rm -f "$f.err"
  term=""; for t in ghostty alacritty foot kitty; do have "$t" && { term="$t"; break; }; done
  [ -n "$term" ] || { echo "mail: no terminal for the review window." >&2; rm -f "$f"; exit 2; }
  title="Computer · review email ($from)"
  inner="'$script_dir/mail.sh' review '$f' '$acct' '$from'"
  case "$term" in
    ghostty)   launch=(ghostty --title="$title" -e bash -lc "$inner") ;;
    alacritty) launch=(alacritty --title "$title" -e bash -lc "$inner") ;;
    foot)      launch=(foot --title="$title" bash -lc "$inner") ;;
    kitty)     launch=(kitty --title "$title" bash -lc "$inner") ;;
  esac
  if have uwsm-app; then setsid uwsm-app -- "${launch[@]}" >/dev/null 2>&1 &
  else setsid "${launch[@]}" >/dev/null 2>&1 & fi
  echo "Opened the email from $from in the editor for review. It sends only after you edit, confirm, and approve there — nothing has been sent."
  exit 0
fi

# --- review: runs INSIDE the window — edit, confirm, then himalaya send ----
if [ "$mode" = "review" ]; then
  f="${1:-}"; acct="${2:-}"; from="${3:-}"
  [ -f "$f" ] || { echo "review: no message file." >&2; exit 2; }
  trap 'rm -f "$f"' EXIT
  editor="${EDITOR:-}"; [ -n "$editor" ] || for e in nvim vim nano vi; do have "$e" && { editor="$e"; break; }; done
  [ -n "$editor" ] || { echo "review: no editor (set \$EDITOR)." >&2; exit 2; }
  "$editor" "$f"
  echo; echo "----- from $from · this will be sent -----"
  "$script_dir/mail-compose.py" --summary-file "$f" --from "$from" || { echo "(problem above — not sending)"; exit 1; }
  echo "------------------------------------------"; echo
  if have gum; then gum confirm "Send this email now?" && c=y || c=n
  else printf 'Send this email now? [y/N] '; IFS= read -r c; fi
  case "$c" in
    y|Y|yes|YES)
      if "$script_dir/mail-compose.py" --emit-file "$f" --from "$from" | himalaya -a "$acct" message send --save sent; then
        echo "Sent from $from."
      else echo "Send failed."; fi ;;
    *)
      echo "Not sent."
      if have gum; then gum confirm "Save to Drafts instead?" && s=y || s=n
      else printf 'Save to Drafts instead? [y/N] '; IFS= read -r s; fi
      case "$s" in y|Y|yes|YES) "$script_dir/mail-compose.py" --emit-file "$f" --from "$from" | himalaya -a "$acct" message add -m drafts && echo "Saved to Drafts." ;; *) echo "Discarded." ;; esac ;;
  esac
  echo; read -n1 -r -p "Press any key to close…"
  exit 0
fi

echo "mail: unknown command '$mode' (accounts|setup|draft|send)." >&2
exit 2
