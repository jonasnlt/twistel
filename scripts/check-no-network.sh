#!/bin/bash
# Checks that a built app contains no networking code of its own. scripts/release.sh runs it on every release.
#
#   scripts/check-no-network.sh <App.app> [--sources <dir>]
#
# Exit status 0: nothing found. 1: something found (each finding is printed). 2: usage error.
#
# What it looks at, for every Mach-O file inside the bundle:
#   1. Linked libraries (otool -L): no networking frameworks (Network, CFNetwork, WebKit, CloudKit, ...).
#   2. Imported symbols (nm -u): no URLSession / NSURLConnection, no CFNetwork calls, no Network.framework (nw_*),
#      no BSD sockets or name lookups (socket, connect, getaddrinfo, ...), no Bonjour, no web views, and no dynamic
#      lookup (dlopen, NSClassFromString) that could pull any of these in by name at run time.
#   3. Objective-C selectors used by the app (__objc_methname): no request, task, or stream-to-host methods.
#   4. Web addresses compiled into the app: only hosts from the allow list below (XML namespaces and the project page).
# With --sources, it also scans the Swift sources for networking APIs that the binary check cannot tell apart
# (for example Data(contentsOf:) with a web address).
#
# This proves what the app itself links and calls. It does not cover what macOS does on the app's behalf when the
# user asks for it (Share, AirDrop, opening a web page in the browser): those are system services, listed as allowed.

set -uo pipefail

usage() { echo "usage: $0 <App.app> [--sources <dir>]" >&2; exit 2; }
[[ $# -ge 1 ]] || usage
APP="$1"; shift
SOURCES=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sources) [[ $# -ge 2 ]] || usage; SOURCES="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -d "$APP" || -f "$APP" ]] || { echo "not found: $APP" >&2; exit 2; }

# Frameworks and libraries that exist to talk to the network.
DENY_LIBRARIES='/(Network|CFNetwork|NetworkExtension|WebKit|CloudKit|MultipeerConnectivity|GameKit|SystemConfiguration|NetFS|Social|Accounts|AuthenticationServices|StoreKit|MapKit|WeatherKit|ExternalAccessory)\.framework/|/libcurl|/libresolv|/libnetwork'

# Imported symbols (nm -u). Swift names are matched as they appear in mangled form (plain text inside).
DENY_SYMBOLS='URLSession|NSURLConnection|NSURLDownload|URLRequest|NSURLRequest|NSHTTPURLResponse|HTTPURLResponse|NSURLProtocol|NSURLCache|NSURLCredential|^_CFHTTP|^_CFNetService|^_CFSocket|^_CFHost|^_CFStreamCreatePairWithSocket|^_CFReadStreamCreateForHTTPRequest|^_CFNetworkCopy|^_nw_|7Network|^_socket$|^_connect$|^_bind$|^_listen$|^_accept$|^_sendto$|^_recvfrom$|^_send$|^_recv$|^_sendmsg$|^_recvmsg$|^_getaddrinfo$|^_getnameinfo$|^_gethostbyname|^_gethostbyaddr|^_res_|^_inet_|^_DNSService|NSNetService|WKWebView|_WebView|MCSession|MCPeerID|^_dlopen$|^_NSClassFromString$|^_objc_getClass$|^_objc_lookUpClass$|^_SCNetwork'

# Objective-C selectors that send requests or open connections.
DENY_SELECTORS='getStreamsToHost|dataTaskWith|downloadTaskWith|uploadTaskWith|streamTaskWith|webSocketTask|sendSynchronousRequest|sendAsynchronousRequest|connectionWithRequest|initWithRequest:delegate|loadRequest:|loadHTMLString'

# Allowed, with a reason. One extended regex per line; matching symbols are reported as "allowed", not as findings.
#   _dlsym: emitted by the compiler for #available checks (__initializeAvailabilityCheck looks up a libSystem
#           function); the app itself never looks up code by name.
#   NSSharingService*: the Share menu and AirDrop are macOS services the user starts; the app hands over files only.
ALLOW_SYMBOLS='^_dlsym$|NSSharingService'

# Hosts that may appear in web addresses inside the app: XML namespaces of file formats (never fetched) and the
# project page (opened in the browser only).
ALLOW_HOSTS='^(schemas\.openxmlformats\.org|purl\.org|www\.w3\.org|www\.idpf\.org|www\.daisy\.org|openoffice\.org|ns\.apple\.com|ns\.adobe\.com|iptc\.org|cipa\.jp|github\.com/jonasnlt/twistel)'

FOUND=0
finding() { echo "FOUND: $*"; FOUND=1; }

MACHOS=()
if [[ -f "$APP" ]]; then
  MACHOS=("$APP")
else
  while IFS= read -r -d '' f; do
    file -b "$f" | grep -q 'Mach-O' && MACHOS+=("$f")
  done < <(find "$APP" -type f -print0)
fi
[[ ${#MACHOS[@]} -gt 0 ]] || { echo "no Mach-O files in $APP" >&2; exit 2; }

for bin in "${MACHOS[@]}"; do
  name="${bin#"$APP"/}"; [[ "$name" == "$bin" ]] && name="$(basename "$bin")"
  echo "== $name"

  # 1. Linked libraries (including weak links).
  while IFS= read -r lib; do
    finding "$name links $lib"
  done < <(otool -L "$bin" | tail -n +2 | awk '{print $1}' | grep -E "$DENY_LIBRARIES")

  # 2. Imported symbols.
  imports="$(nm -u "$bin" 2>/dev/null)"
  while IFS= read -r sym; do
    [[ -z "$sym" ]] && continue
    if grep -qE "$ALLOW_SYMBOLS" <<<"$sym"; then
      echo "   allowed: $sym"
    else
      finding "$name imports $(swift demangle --compact "$sym" 2>/dev/null || echo "$sym")"
    fi
  done < <(grep -iE "$DENY_SYMBOLS|$ALLOW_SYMBOLS" <<<"$imports" | sort -u)

  # 3. Objective-C selectors.
  while IFS= read -r sel; do
    finding "$name uses selector $sel"
  done < <(otool -v -s __TEXT __objc_methname "$bin" 2>/dev/null | awk 'NR>2 {print $2}' | grep -E "$DENY_SELECTORS" | sort -u)

  # 4. Web addresses.
  while IFS= read -r host; do
    finding "$name contains a web address for $host (add it to ALLOW_HOSTS only if it is never fetched)"
  done < <(strings -a "$bin" | grep -oE 'https?://[A-Za-z0-9._/-]+' | sed -E 's#^https?://##' | grep -vE "$ALLOW_HOSTS" | sort -u)
done

# 5. Sources (optional): APIs the binary check cannot tell apart from local use.
if [[ -n "$SOURCES" ]]; then
  echo "== sources: $SOURCES"
  while IFS= read -r line; do
    finding "source uses $line"
  done < <(grep -rnE --include='*.swift' '\b(URLSession|URLRequest|NSURLConnection|NWConnection|NWListener|NWBrowser|WKWebView|CFNetwork|getaddrinfo|import Network|import WebKit)\b' "$SOURCES")
  # A web address in code may only be the project page, which is opened in the browser.
  while IFS= read -r line; do
    finding "source builds a web URL: $line"
  done < <(grep -rnE --include='*.swift' 'URL\(string: *"https?://' "$SOURCES" | grep -v 'github.com/jonasnlt/twistel')
fi

if [[ $FOUND -eq 0 ]]; then
  echo "OK: no networking code found."
else
  echo "Networking code found (see FOUND lines above)." >&2
fi
exit $FOUND
