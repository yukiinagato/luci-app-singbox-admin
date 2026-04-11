#!/bin/sh
set -eu

VERSION="${1:-}"
ARCH="${2:-auto}"

if [ -z "$VERSION" ]; then
	echo "Usage: $0 <version> [arch|auto]" >&2
	exit 1
fi

normalize_arch() {
	case "$1" in
		x86_64|amd64) echo "amd64" ;;
		aarch64|arm64|armv8) echo "arm64" ;;
		armv7l|armv7) echo "armv7" ;;
		armv6l|armv6) echo "armv6" ;;
		i386|i686|386) echo "386" ;;
		mipsel_24kc|mipsel) echo "mipsle" ;;
		mips_24kc|mips) echo "mips" ;;
		mips64el) echo "mips64le" ;;
		mips64) echo "mips64" ;;
		riscv64) echo "riscv64" ;;
		*) echo "$1" ;;
	esac
}

if [ "$ARCH" = "auto" ]; then
	DETECTED_ARCH="$(uci -q get lucistat.system.arch 2>/dev/null || true)"
	[ -n "$DETECTED_ARCH" ] || DETECTED_ARCH="$(uname -m)"
	ARCH="$(normalize_arch "$DETECTED_ARCH")"
else
	ARCH="$(normalize_arch "$ARCH")"
fi

VER="${VERSION#v}"
TAG="v$VER"
ASSET="sing-box-${VER}-linux-${ARCH}.tar.gz"
URL="https://github.com/SagerNet/sing-box/releases/download/${TAG}/${ASSET}"

TMPDIR="$(mktemp -d /tmp/singbox-update.XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT INT TERM

echo "Version: $VER"
echo "Architecture: $ARCH"
echo "Download: $URL"

if ! wget -O "$TMPDIR/sing-box.tar.gz" "$URL"; then
	echo "Download failed." >&2
	exit 1
fi

if ! tar -xzf "$TMPDIR/sing-box.tar.gz" -C "$TMPDIR"; then
	echo "Extract failed." >&2
	exit 1
fi

BIN="$(find "$TMPDIR" -type f -name sing-box | head -n 1)"
if [ -z "$BIN" ] || [ ! -f "$BIN" ]; then
	echo "Cannot find sing-box binary in archive." >&2
	exit 1
fi

if [ -f /usr/bin/sing-box ]; then
	cp /usr/bin/sing-box "/usr/bin/sing-box.bak.$(date +%Y%m%d%H%M%S)"
fi

install -m 0755 "$BIN" /usr/bin/sing-box

echo "Installed /usr/bin/sing-box"
/usr/bin/sing-box version || true

/etc/init.d/sing-box restart || true
echo "Restart signal sent."
