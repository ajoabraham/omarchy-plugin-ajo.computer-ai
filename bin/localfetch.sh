#!/usr/bin/env bash
# Fetch a URL from THIS machine, instead of through the agent harness's own
# web tool (which runs on the harness vendor's infrastructure, not here).
#
# Two reasons to want that. The request goes out over this household's
# connection rather than a datacentre's, so pages that geo-vary or block
# cloud ranges behave normally. And it can reach what only this machine can
# see: the LAN, the router, a service on localhost.
#
# That second reason is exactly why this is NOT pre-approved. It is a
# strictly wider reach than the built-in fetch, so it gets its own one-time
# grant through the panel like any other privilege here. The resolved
# address is printed in the header so a fetch of something on the local
# network is visible in the activity log rather than silent.
#
# Usage: localfetch.sh <http-or-https-url> [max-chars]
set -u
url="${1:-}"
max="${2:-20000}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "$url" ]; then
  echo "usage: localfetch.sh <http(s)://url> [max-chars]" >&2
  exit 2
fi
case "$url" in
  http://*|https://*) ;;
  *) echo "localfetch: only http:// and https:// URLs are supported" >&2; exit 2 ;;
esac
command -v curl >/dev/null 2>&1 || { echo "localfetch: curl is not installed" >&2; exit 2; }

tmpd=$(mktemp -d) || exit 2
trap 'rm -rf "$tmpd"' EXIT

# --proto and --proto-redir pin the scheme across redirects too, so a
# redirect cannot walk this into file:// or scp://. Size and time caps keep
# a hostile or broken page from hanging the turn.
meta=$(curl -sS --compressed \
  --proto '=http,https' --proto-redir '=http,https' \
  --location --max-redirs 5 \
  --connect-timeout 10 --max-time 25 \
  --max-filesize 8000000 \
  -A 'Mozilla/5.0 (X11; Linux x86_64) computer-ai/1.0' \
  -o "$tmpd/body" \
  -w '%{http_code}\t%{content_type}\t%{size_download}\t%{remote_ip}\t%{url_effective}' \
  "$url" 2>"$tmpd/err")
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "localfetch: request failed ($(head -c 200 "$tmpd/err" | tr '\n' ' '))" >&2
  exit 1
fi

IFS=$'\t' read -r code ctype size ip final <<<"$meta"
mime="${ctype%%;*}"
printf 'URL: %s\nHTTP %s   type: %s   bytes: %s   served by: %s\n\n' \
  "$final" "$code" "${mime:-unknown}" "$size" "$ip"

case "$mime" in
  text/html|application/xhtml+xml)
    python3 "$script_dir/html-to-text.py" < "$tmpd/body" > "$tmpd/text" 2>/dev/null \
      || cp "$tmpd/body" "$tmpd/text"
    ;;
  application/json|application/*+json|text/*|application/xml)
    cp "$tmpd/body" "$tmpd/text"
    ;;
  *)
    printf '(%s is not text — %s bytes not shown)\n' "${mime:-unknown}" "$size" > "$tmpd/text"
    ;;
esac

bytes=$(wc -c < "$tmpd/text")
head -c "$max" "$tmpd/text"
if [ "$bytes" -gt "$max" ]; then
  printf '\n\n[truncated at %s of %s characters]\n' "$max" "$bytes"
fi
