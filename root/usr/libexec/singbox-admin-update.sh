#!/bin/sh

# sing-box updater for OpenWrt.
#
# Supports both package managers found across OpenWrt releases:
#   - opkg (OpenWrt <= 24.10): installs the official
#         sing-box_<version>_openwrt_<arch>.ipk        (musl build)
#   - apk  (OpenWrt mainline >= 25.x / snapshots): installs the official
#         sing-box_<version>_openwrt_<arch>.apk        (same build, apk format)
# where <arch> is the OpenWrt package architecture, e.g. x86_64,
# aarch64_cortex-a53, mipsel_24kc. opkg/apk validate the architecture on
# install, so an incompatible download is refused before anything is touched.
#
# A custom --url may point to an .ipk, an .apk, or a .tar.gz (raw binary,
# swapped in with a pre-flight executability test and automatic rollback).
# The .tar.gz path is kept for advanced/manual use; note that upstream's
# plain linux-<arch> tarballs are glibc-linked and will NOT run on a musl
# OpenWrt -- prefer the .ipk/.apk or a *-musl tarball.

set -eu

TARGET="/usr/bin/sing-box"
INIT="/etc/init.d/sing-box"
KEEP_BACKUPS=2

VERSION=""
ARCH=""
URL=""

log() { echo "$@"; }
fail() { echo "$@" >&2; exit 1; }

# Serialize updaters. The caller (singbox-admin) also does a best-effort PID
# check, but that is check-then-act; this lock is the atomic guarantee that
# only one process ever installs over $TARGET at a time. A second concurrent
# invocation exits immediately instead of racing the package install.
LOCK="/tmp/sing-box-update.lock"
exec 9>"$LOCK" || fail "Cannot open update lock $LOCK."
if ! flock -n 9; then
	fail "Another sing-box update is already in progress."
fi

# ---------------------------------------------------------------------------
# Package manager detection: opkg wins when both exist (conservative -- a
# leftover apk on an opkg system may lack configured repositories).
# ---------------------------------------------------------------------------
PKG_MGR=""
if command -v opkg >/dev/null 2>&1; then
	PKG_MGR="opkg"
elif command -v apk >/dev/null 2>&1; then
	PKG_MGR="apk"
else
	fail "No package manager found (need opkg or apk) for .ipk/.apk installs."
fi

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
	# Official package for this arch (musl, installable by opkg AND apk).
	case "$PKG_MGR" in
		opkg) URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box_${VERSION}_openwrt_${ARCH}.ipk" ;;
		apk)  URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box_${VERSION}_openwrt_${ARCH}.apk" ;;
	esac

	# Pre-flight: older and alpha releases often publish no OpenWrt package in
	# the format this device needs (availability is format-specific -- e.g.
	# 1.13.0 ships an .ipk but no .apk), so a version picked from the tag list
	# can 404 mid-download. HEAD the exact asset and fail early with a clear
	# message. Uses the (unmetered) download host, NOT api.github.com, which is
	# rate-limited to 60 req/h and would fail open once exhausted. rc 8 = HTTP
	# error (404); a network failure (other rc) must NOT block -- the real
	# download below is the ultimate gate.
	case "$PKG_MGR" in opkg) EXT="ipk" ;; apk) EXT="apk" ;; *) EXT="" ;; esac
	if command -v uclient-fetch >/dev/null 2>&1; then SPIDER="uclient-fetch"; else SPIDER="wget"; fi
	SP_RC=0
	"$SPIDER" -T 15 --spider "$URL" >/dev/null 2>&1 || SP_RC="$?"
	if [ "$SP_RC" = "8" ]; then
		fail "sing-box ${VERSION} has no OpenWrt .${EXT} package for ${ARCH}. Pick a different version (older and alpha releases often ship no ${EXT} build for this arch)."
	fi
fi

TMPDIR="$(mktemp -d /tmp/singbox-update.XXXXXX)"
STAGED="${TARGET%/*}/.sing-box.new.$$"
cleanup() {
	rm -rf "$TMPDIR"
	[ -e "$STAGED" ] && rm -f "$STAGED"
	return 0
}
trap cleanup EXIT INT TERM

# --- download --------------------------------------------------------------
# Keep the original extension so we can dispatch on it (.ipk / .apk / other).
case "$URL" in
	*.ipk)  DLFILE="$TMPDIR/sing-box.ipk" ;;
	*.apk)  DLFILE="$TMPDIR/sing-box.apk" ;;
	*)      DLFILE="$TMPDIR/sing-box.tar.gz" ;;
esac

log "Downloading $URL"
if command -v uclient-fetch >/dev/null 2>&1; then
	uclient-fetch -T 30 -O "$DLFILE" "$URL" || fail "Download failed."
else
	wget -T 30 -O "$DLFILE" "$URL" || fail "Download failed."
fi
[ -s "$DLFILE" ] || fail "Downloaded file is empty."

# ===========================================================================
# Path 1b: apk package (OpenWrt mainline) -- apk validates arch on install.
# ===========================================================================
install_apk() {
	command -v apk >/dev/null 2>&1 || fail "apk not found; cannot install .apk."

	OLD_VER="$("$TARGET" version 2>/dev/null | head -n 1 || true)"

	WAS_RUNNING=0
	if "$INIT" status >/dev/null 2>&1; then
		WAS_RUNNING=1
		"$INIT" stop >/dev/null 2>&1 || true
	fi

	# apk refuses a package whose architecture does not match this device.
	# --allow-untrusted: upstream release apks are not signed with the
	# device's repo keys (same as manual upstream install instructions).
	if ! APK_OUT="$(apk add --allow-untrusted --force-overwrite "$DLFILE" 2>&1)"; then
		echo "$APK_OUT" >&2
		fail "apk add failed (architecture mismatch or missing deps?)."
	fi

	post_install_verify "$OLD_VER"
}

# Shared post-install verification for package installs (.ipk / .apk):
# binary runs, config still validates, service comes back if it was running.
post_install_verify() {
	OLD_VER="${1:-}"

	# Sanity-check the freshly installed binary.
	"$TARGET" version >/dev/null 2>&1 || fail "Installed binary does not run."

	# Validate existing config against the new version (warn, do not abort).
	CFG="/etc/sing-box/config.json"
	CFG_WARN=""
	if [ -f "$CFG" ] && ! "$TARGET" check -c "$CFG" >/dev/null 2>&1; then
		CFG_WARN="WARNING: current config.json failed validation against the new version; check the config before (re)starting."
	fi

	# Restart if it had been running, and confirm it came back.
	if [ "$WAS_RUNNING" -eq 1 ]; then
		"$INIT" restart >/dev/null 2>&1 || true
		sleep 1
		"$INIT" status >/dev/null 2>&1 || log "WARNING: service did not report running after restart."
	fi

	NEW_VER="$("$TARGET" version 2>/dev/null | head -n 1 || true)"
	log "Installed via ${PKG_MGR}: ${OLD_VER:-none} -> ${NEW_VER:-unknown}"
	[ -n "$CFG_WARN" ] && log "$CFG_WARN"
	log "Updated successfully from $URL"
}

# ===========================================================================
# Path 1: opkg package (.ipk) -- let opkg do arch validation + install.
# ===========================================================================
install_ipk() {
	command -v opkg >/dev/null 2>&1 || fail "opkg not found; cannot install .ipk."

	mkdir -p /var/lock

	OLD_VER="$("$TARGET" version 2>/dev/null | head -n 1 || true)"

	WAS_RUNNING=0
	if "$INIT" status >/dev/null 2>&1; then
		WAS_RUNNING=1
	fi

	# opkg refuses a package whose Architecture does not match this device,
	# so an incompatible download cannot brick the install here.
	if ! OPKG_OUT="$(opkg install --force-reinstall --force-downgrade "$DLFILE" 2>&1)"; then
		echo "$OPKG_OUT" >&2
		case "$OPKG_OUT" in
			*rch*) fail "opkg refused the package (architecture mismatch). Pick the arch that matches 'opkg print-architecture'." ;;
			*)     fail "opkg install failed." ;;
		esac
	fi

	post_install_verify "$OLD_VER"
}

# ===========================================================================
# Path 2: raw binary tarball -- pre-flight test, atomic swap, auto-rollback.
# ===========================================================================
install_tarball() {
	mkdir -p "$TMPDIR/extract"
	tar -xzf "$DLFILE" -C "$TMPDIR/extract" || fail "Failed to extract archive (not a valid .tar.gz?)."
	BIN="$(find "$TMPDIR/extract" -type f -name sing-box | head -n 1)"
	[ -n "$BIN" ] && [ -s "$BIN" ] || fail "No sing-box binary found in package."

	# Stage next to the target (real fs, avoids noexec /tmp) and prove it runs.
	cp "$BIN" "$STAGED" || fail "Could not stage new binary into ${TARGET%/*}."
	chmod 0755 "$STAGED"
	if ! NEW_VER_OUTPUT="$("$STAGED" version 2>&1)"; then
		echo "$NEW_VER_OUTPUT" >&2
		fail "Downloaded binary failed to execute (incompatible architecture/build, e.g. a glibc tarball on musl OpenWrt). Existing install left untouched."
	fi
	log "New binary OK: $(echo "$NEW_VER_OUTPUT" | head -n 1)"

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

	"$TARGET" version >/dev/null 2>&1 || rollback "Installed binary does not run."

	CFG="/etc/sing-box/config.json"
	if [ -f "$CFG" ]; then
		if ! CHECK_OUTPUT="$("$TARGET" check -c "$CFG" 2>&1)"; then
			echo "$CHECK_OUTPUT" >&2
			rollback "New version rejected the current config.json (likely a schema change)."
		fi
	fi

	if [ "$WAS_RUNNING" -eq 1 ]; then
		"$INIT" start >/dev/null 2>&1 || true
		sleep 1
		"$INIT" status >/dev/null 2>&1 || rollback "Service failed to start with the new version."
	fi

	# Keep only the most recent backups.
	ls -1t "${TARGET}".bak.* 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) | while IFS= read -r old; do
		rm -f "$old"
	done

	log "Updated successfully from $URL"
	log "$(echo "$NEW_VER_OUTPUT" | head -n 1)"
}

case "$DLFILE" in
	*.ipk)
		command -v opkg >/dev/null 2>&1 || fail "Downloaded .ipk but opkg is not available on this system; pick the .apk asset or a .tar.gz."
		install_ipk
		;;
	*.apk)
		command -v apk >/dev/null 2>&1 || fail "Downloaded .apk but apk is not available on this system."
		install_apk
		;;
	*)
		install_tarball
		;;
esac
