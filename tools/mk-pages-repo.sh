#!/usr/bin/env bash
# Generate the static index that GitHub Pages serves to devices.
#
#   tools/mk-debs.sh
#   tools/mk-pages-repo.sh
#   gh release create v1.0 dist/debs/*.deb     # the packages live here
#   git add docs && git commit && git push     # only the index lives in git
#
# The packages are NOT committed. Pages serves a small index; the .deb files
# come from a GitHub release. Committing 12 MB of binaries per version would
# sit in git history forever, and history is the one thing you cannot prune
# later without rewriting everyone's clone.
#
# The index is deliberately plain text, not JSON: it is parsed on the device by
# a `while read` loop in /bin/sh, with no jq and no python. Each row carries an
# absolute URL, so the index and the packages can live on different hosts.
#
# Authenticity comes from TLS. n810-modern-update fetches over HTTPS with
# certificate verification against a current CA store, so the connection is
# what proves where these came from. The checksums catch truncation and
# corruption, not a hostile server.
set -euo pipefail

DIST="${DIST:-$PWD/dist}"
DEBS="${DEBS:-$DIST/debs}"
DOCS="${DOCS:-$PWD/docs}"
REPO="${GITHUB_REPO:-mitoyarzun/n810-modern}"
TAG="${TAG:-v1.0}"
PAGES="${PAGES_URL:-https://mitoyarzun.github.io/n810-modern}"
RELEASE="https://github.com/$REPO/releases/download/$TAG"

ls "$DEBS"/*.deb >/dev/null 2>&1 || { echo "no packages in $DEBS -- run tools/mk-debs.sh"; exit 1; }
command -v dpkg-deb >/dev/null || { echo "dpkg-deb not found"; exit 1; }

mkdir -p "$DOCS"
# Any .deb here is a leftover from when they were committed. They do not belong.
rm -f "$DOCS"/*.deb
rm -f "$DOCS/index.txt"

echo "==> Building the index (packages served from $TAG)"
{
  echo "# n810-modern package index"
  echo "# name version size sha256 url"
  for f in "$DEBS"/*.deb; do
    name=$(dpkg-deb -f "$f" Package)
    version=$(dpkg-deb -f "$f" Version)
    size=$(wc -c < "$f" | tr -d ' ')
    sha=$(sha256sum "$f" | cut -d' ' -f1)
    base=$(basename "$f")
    printf '%s %s %s %s %s/%s\n' "$name" "$version" "$size" "$sha" "$RELEASE" "$base"
  done
} > "$DOCS/index.txt"

sed -n '3,$p' "$DOCS/index.txt" | awk '{printf "    %-24s %-6s %s\n", $1, $2, $3}'

cat > "$DOCS/index.html" <<HTML
<!doctype html>
<meta charset="utf-8">
<title>n810-modern packages</title>
<style>
 body{font:16px/1.6 system-ui,sans-serif;max-width:42rem;margin:3rem auto;padding:0 1rem}
 code,pre{font-family:ui-monospace,Menlo,monospace;font-size:.9em}
 pre{background:#f5f5f5;padding:1rem;overflow-x:auto}
 table{border-collapse:collapse;width:100%}
 td,th{text-align:left;padding:.3rem .6rem .3rem 0;border-bottom:1px solid #eee}
 .note{color:#555;font-size:.95em}
</style>
<h1>n810-modern packages</h1>
<p>Modern software for the Nokia N800 and N810 running Maemo 4.1.2 (Diablo).
   Source and issues:
   <a href="https://github.com/$REPO">github.com/$REPO</a></p>

<h2>One package, by hand</h2>
<p>A stock device cannot complete a modern TLS handshake, so it cannot download
   anything. Get this one on a PC and copy it across by SD card or USB mass
   storage, then as root on the tablet:</p>
<pre>dpkg -i n810-modern-tls_${TAG#v}_armel.deb</pre>
<p class="note">It installs OpenSSL 3.5, zlib, curl and stunnel under
   <code>/opt/n810-modern</code>, alongside the stock libraries rather than over
   them. Nothing already on the device changes.</p>

<h2>Everything else, over the network</h2>
<p>That package ships <code>n810-modern-update</code>, which uses the curl it
   just installed:</p>
<pre>n810-modern-update
n810-modern-update install n810-modern-ssh
n810-modern-update upgrade</pre>

<h2>Packages</h2>
<table><tr><th>Package<th>Version<th>Download</tr>
$(sed -n '3,$p' "$DOCS/index.txt" | awk '{n=split($5,p,"/"); printf "<tr><td>%s<td>%s<td><a href=\"%s\">%s</a></tr>\n", $1, $2, $5, p[n]}')
</table>
<p class="note"><a href="index.txt">index.txt</a> is the machine-readable form.
   None of this has been tested on physical hardware yet -- it is verified
   under emulation.</p>
HTML

echo "==> $DOCS"
du -sh "$DOCS" | sed 's/^/    /'
echo
echo "Publish the packages, which are NOT in git:"
echo "  gh release create $TAG $DEBS/*.deb --title '$TAG' --notes '...'"
echo
echo "Then commit the index only:"
echo "  git add docs && git commit && git push"
echo
echo "Devices read: $PAGES/index.txt"
