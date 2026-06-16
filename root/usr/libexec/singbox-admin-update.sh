#!/bin/sh

# sing-box binary updater.
#
# Safety model (this is the whole point of the script):
#   1. Download + extract into a temp dir.
#   2. Stage the new binary next to the target and TEST that it actually runs
#      (`sing-box version`) BEFORE the live binary is touched. An incompatible
#      download (wrong arch, dynamically-linked build, corruption) is rejected
#      here with zero impact on the running install.
#   3. Only after the test passes: stop service, back up current binary,
#      atomically swap in the new one.
#   4. Verify the installed binary runs and, if the service was running, that
#      it comes back up. If not, automatically roll back to the backup so the
#      router is never left without a working sing-box.
#   5. Keep only the most recent backups to avoid filling the device.

set -eu

TARGET="/usr/bin/sing-box"
INIT="/etc/init.d/sing-box"
KEEP_BACKUPS=2

VERSION=""
ARCH=""
URL=""

log() { echo "$@"; }
fail() { echo "$@" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
	case "$1" in
		--version) VERSION="${2:-}"; shift 2 ;;
		--arch)    ARCH="${2:-}";    shift 2 ;;
		--url)     URL="${2:-}";     shift 2 ;;
		*) fail "Unknown argument: $1" ;;
	esac
done

if [ -n "$URL" ]; then
	case "$URL" in
		http://*|https://*) ;;
		*) fail "Invalid URL" ;;
	esac
else
	case "$VERSION" in
		""|*[!0-9A-Za-z._-]*) fail "Invalid version" ;;
	esac
	case "$ARCH" in
		""|*[!a-z0-9_-]*) fail "Invalid architecture" ;;
	esac
	URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${ARCH}.tar.gz"
fi

TMPDIR="$(mktemp -d /tmp/singbox-update.XXXXXX)"
STAGED="${TARGET%/*}/.sing-box.new.$$"
cleanup() {
	rm -rf "$TMPDIR"
	[ -e "$STAGED" ] && rm -f "$STAGED"
	return 0
}
trap cleanup EXIT INT TERM

# --- 1. download -----------------------------------------------------------
TARBALL="$TMPDIR/sing-box.tar.gz"
log "Downloading $URL"
if command -v uclient-fetch >/dev/null 2>&1; then
	uclient-fetch -T 30 -O "$TARBALL" "$URL" || fail "Download failed."
else
	wget -T 30 -O "$TARBALL" "$URL" || fail "Download failed."
fi
[ -s "$TARBALL" ] || fail "Downloaded file is empty."

# --- 2. extract ------------------------------------------------------------
mkdir -p "$TMPDIR/extract"
tar -xzf "$TARBALL" -C "$TMPDIR/extract" || fail "Failed to extract archive (not a valid .tar.gz?)."
BIN="$(find "$TMPDIR/extract" -type f -name sing-box | head -n 1)"
[ -n "$BIN" ] && [ -s "$BIN" ] || fail "No sing-box binary found in package."

# --- 3. PRE-FLIGHT: stage next to target and prove it runs -----------------
# Staging in the target directory (not /tmp) means the executability test runs
# on the real filesystem, avoiding false negatives from a noexec /tmp.
cp "$BIN" "$STAGED" || fail "Could not stage new binary into ${TARGET%/*}."
chmod 0755 "$STAGED"

if ! NEW_VER_OUTPUT="$("$STAGED" version 2>&1)"; then
	echo "$NEW_VER_OUTPUT" >&2
	fail "Downloaded binary failed to execute (incompatible architecture/build). Existing install left untouched."
fi
log "New binary OK: $(echo "$NEW_VER_OUTPUT" | head -n 1)"

# --- 4. swap (live binary touched only from here on) -----------------------
WAS_RUNNING=0
if "$INIT" status >/dev/null 2>&1; then
	WAS_RUNNING=1
	"$INIT" stop >/dev/null 2>&1 || true
fi

BACKUP=""
if [ -x "$TARGET" ]; then
	BACKUP="${TARGET}.bak.$(date +%Y%m%d%H%M%S)"
	cp "$TARGET" "$BACKUP"
fi

mv -f "$STAGED" "$TARGET"

# Roll back to the backup, restore service, and exit with an error message.
rollback() {
	reason="$1"
	if [ -n "$BACKUP" ] && [ -x "$BACKUP" ]; then
		cp -f "$BACKUP" "$TARGET"
		chmod 0755 "$TARGET"
		[ "$WAS_RUNNING" -eq 1 ] && "$INIT" start >/dev/null 2>&1 || true
		fail "$reason Rolled back to previous version."
	fi
	fail "$reason No backup available to roll back to."
}

# --- 5. post-install verification ------------------------------------------
"$TARGET" version >/dev/null 2>&1 || rollback "Installed binary does not run."

# Validate the existing config against the new binary.
CFG="/etc/sing-box/config.json"
if [ -f "$CFG" ]; then
	if ! CHECK_OUTPUT="$("$TARGET" check -c "$CFG" 2>&1)"; then
		echo "$CHECK_OUTPUT" >&2
		rollback "New version rejected the current config.json (likely a schema change)."
	fi
fi

# Restart if it was running, and make sure it actually came back up.
if [ "$WAS_RUNNING" -eq 1 ]; then
	"$INIT" start >/dev/null 2>&1 || true
	sleep 1
	"$INIT" status >/dev/null 2>&1 || rollback "Service failed to start with the new version."
fi

# --- 6. prune old backups --------------------------------------------------
# Keep only the most recent $KEEP_BACKUPS backups.
ls -1t "${TARGET}".bak.* 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) | while IFS= read -r old; do
	rm -f "$old"
done

log "Updated successfully from $URL"
log "$(echo "$NEW_VER_OUTPUT" | head -n 1)"
