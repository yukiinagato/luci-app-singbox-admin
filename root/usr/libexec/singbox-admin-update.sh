#!/bin/sh

set -eu

VERSION=""
ARCH=""
URL=""

while [ "$#" -gt 0 ]; do
	case "$1" in
		--version)
			VERSION="${2:-}"
			shift 2
			;;
		--arch)
			ARCH="${2:-}"
			shift 2
			;;
		--url)
			URL="${2:-}"
			shift 2
			;;
		*)
			echo "Unknown argument: $1" >&2
			exit 1
			;;
	esac
done

if [ -n "$URL" ]; then
	case "$URL" in
		http://*|https://*) ;;
		*)
			echo "Invalid URL" >&2
			exit 1
			;;
	esac
else
	case "$VERSION" in
		""|*[!0-9A-Za-z._-]*)
			echo "Invalid version" >&2
			exit 1
			;;
	esac

	case "$ARCH" in
		""|*[!a-z0-9_-]*)
			echo "Invalid architecture" >&2
			exit 1
			;;
	esac

	URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${ARCH}.tar.gz"
fi

TMPDIR="$(mktemp -d /tmp/singbox-update.XXXXXX)"
cleanup() {
	rm -rf "$TMPDIR"
}
trap cleanup EXIT INT TERM

TARBALL="$TMPDIR/sing-box.tar.gz"

if command -v uclient-fetch >/dev/null 2>&1; then
	uclient-fetch -T 20 -O "$TARBALL" "$URL"
else
	wget -T 20 -O "$TARBALL" "$URL"
fi

mkdir -p "$TMPDIR/extract"
tar -xzf "$TARBALL" -C "$TMPDIR/extract"
BIN="$(find "$TMPDIR/extract" -type f -name sing-box | head -n 1)"

if [ -z "$BIN" ] || [ ! -s "$BIN" ]; then
	echo "No sing-box binary found in package" >&2
	exit 1
fi

WAS_RUNNING=0
if /etc/init.d/sing-box status >/dev/null 2>&1; then
	WAS_RUNNING=1
	/etc/init.d/sing-box stop >/dev/null 2>&1 || true
fi

if [ -x /usr/bin/sing-box ]; then
	cp /usr/bin/sing-box "/usr/bin/sing-box.bak.$(date +%Y%m%d%H%M%S)"
fi

# Note: BusyBox/OpenWrt has no `install` applet by default.
# Stage into the target dir, set perms, then atomically rename into place.
NEWBIN="/usr/bin/.sing-box.new.$$"
cp "$BIN" "$NEWBIN"
chmod 0755 "$NEWBIN"
mv -f "$NEWBIN" /usr/bin/sing-box

if [ "$WAS_RUNNING" -eq 1 ]; then
	/etc/init.d/sing-box start >/dev/null 2>&1 || true
fi

echo "Updated from $URL"
