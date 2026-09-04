#!/usr/bin/env bash
# Fetch a URL from THIS machine, instead of through the agent harness's own
# web tool (which runs on the harness vendor's infrastructure, not here).
#
# Two reasons to want that. The request goes out over this household's
# connection rather than a datacentre's, so pages that geo-vary or block
# cloud ranges behave normally. And it can reach what only this machine can
# see: the LAN, the router, a service on localhost.
#
# That second reason is also what makes it dangerous. Once the grant is
# approved it never expires, and the agent's context is full of text it did
# not write — pages, mail, browser content — any of which can ask for a URL.
# So reach is gated per destination rather than once, at install:
#
#   public address        fetch it
#   loopback/LAN/router/  a confirmation card in the panel, per destination,
#   link-local/metadata   every time (bin/confirm.sh)
#
# Each hop is resolved and classified before the request (bin/url-guard.py),
# then pinned with --resolve so the name cannot resolve to something else
# between the check and the connection. Redirects are followed by hand, one
# at a time, so a public URL cannot bounce into the private ranges — which is
# exactly what --location used to allow.
#
# Usage: localfetch.sh <http-or-https-url> [max-chars]
set -u
umask 077

url="${1:-}"
max="${2:-20000}"
case "$max" in ''|*[!0-9]*) max=20000 ;; esac
[ "$max" -le 200000 ] || max=200000

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "$url" ]; then
  echo "usage: localfetch.sh <http(s)://url> [max-chars]" >&2
  exit 2
fi
[ "${#url}" -le 2048 ] || { echo "localfetch: URL too long" >&2; exit 2; }
case "$url" in
  http://*|https://*) ;;
  *) echo "localfetch: only http:// and https:// URLs are supported" >&2; exit 2 ;;
esac
command -v curl >/dev/null 2>&1 || { echo "localfetch: curl is not installed" >&2; exit 2; }

tmpd=$(mktemp -d) || exit 2
trap 'rm -rf "$tmpd"' EXIT

max_hops=5
hop=0
final=""
code=""
ctype=""
size=""
ip=""

while :; do
  hop=$((hop + 1))
  if [ "$hop" -gt "$max_hops" ]; then
    echo "localfetch: too many redirects" >&2
    exit 1
  fi

  # Resolve and classify BEFORE connecting. Worst case is the first line, so
  # a name answering with both a public and a loopback address is treated as
  # loopback.
  if ! "$script_dir/url-guard.py" check "$url" > "$tmpd/guard" 2>"$tmpd/err"; then
    echo "localfetch: $(head -c 200 "$tmpd/err" | tr '\n' ' ')" >&2
    exit 1
  fi
  IFS=$'\t' read -r host port ip class < "$tmpd/guard"

  if [ "$class" != "public" ]; then
    # Not a standing power: this destination, this time.
    if ! "$script_dir/confirm.sh" "fetch $host" \
         "The assistant wants to fetch $url — that is a $class address ($ip) on this machine or network."; then
      echo "localfetch: the user declined the request to $host ($class)." >&2
      exit 3
    fi
  fi

  # -q ignores ~/.curlrc, --noproxy '*' ignores http_proxy/ALL_PROXY: the
  # request must be exactly what was just validated, not what ambient
  # configuration turns it into. --max-redirs 0 keeps redirect handling here.
  meta=$(curl -q -sS --compressed \
    --proto '=http,https' \
    --noproxy '*' \
    --resolve "$host:$port:$ip" \
    --max-redirs 0 \
    --connect-timeout 10 --max-time 25 \
    --max-filesize 8000000 \
    -A 'Mozilla/5.0 (X11; Linux x86_64) computer-ai/1.0' \
    -D "$tmpd/headers" \
    -o "$tmpd/body" \
    -w '%{http_code}\t%{content_type}\t%{size_download}\t%{url_effective}' \
    "$url" 2>"$tmpd/err")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "localfetch: request failed ($(head -c 200 "$tmpd/err" | tr '\n' ' '))" >&2
    exit 1
  fi

  IFS=$'\t' read -r code ctype size final <<<"$meta"

  case "$code" in
    301|302|303|307|308)
      loc=$(awk 'BEGIN{IGNORECASE=1} /^location:/ {sub(/^[^:]*:[ \t]*/, ""); gsub(/\r/, ""); print; exit}' "$tmpd/headers")
      if [ -z "$loc" ]; then
        echo "localfetch: redirect with no destination" >&2
        exit 1
      fi
      if ! url=$("$script_dir/url-guard.py" join "$final" "$loc" 2>"$tmpd/err"); then
        echo "localfetch: $(head -c 200 "$tmpd/err" | tr '\n' ' ')" >&2
        exit 1
      fi
      # Loop: the new hop is resolved, classified and confirmed on its own.
      continue
      ;;
  esac
  break
done

mime="${ctype%%;*}"
printf 'URL: %s\nHTTP %s   type: %s   bytes: %s   served by: %s (%s)\n\n' \
  "$final" "$code" "${mime:-unknown}" "$size" "$ip" "$class"

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
