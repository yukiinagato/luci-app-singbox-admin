#!/bin/sh
#
# sing-box firewall executor.
#
# Historically the LuCI "Firewall Script" tab let users edit
# /etc/sing-box/nftables.sh but NOTHING ever executed it -- a silent footgun.
# This helper makes that file real: it is the single, validated, rollback-
# protected path through which the UI, boot, and reloads apply the firewall.
#
# The managed script is a plain /bin/sh script that builds the ruleset (it may
# use `nft -f -` heredocs, `nft add ...` commands, and `ip rule`/`ip route`
# for policy routing). It should make its own table deletes idempotent, e.g.
#     nft delete table inet singbox 2>/dev/null
#
# Subcommands:
#   validate  shell-syntax check only (no side effects)
#   apply     apply the script; on failure roll back to the last-known-good copy
#   flush     remove the plugin's nft tables and fwmark policy routes
#   status    print the live sing-box-related ruleset + policy routes
#
set -u

SCRIPT="/etc/sing-box/nftables.sh"
GOOD="/etc/sing-box/.nftables.good.sh"   # last-known-good copy
LOG="/tmp/sing-box-fw.log"
LOCK="/tmp/sing-box-fw.lock"

# Table names this plugin may create (used by flush). Space-separated
# "family name" pairs. Adjust if your script uses a different table name.
FW_TABLES="inet singbox"

now() { date "+%Y-%m-%d %H:%M:%S"; }

_syntax() {
	# Cheap shell-syntax check; does not execute any command.
	sh -n "$SCRIPT" 2>"$LOG"
}

_run() {
	# Run a firewall script and decide success. We do NOT use `set -e`
	# because well-formed scripts intentionally ignore `nft delete` failures.
	# Instead: run it, then treat a non-zero exit OR any nft "Error:" line in
	# the output as a failure.
	sh "$1" >"$LOG" 2>&1
	rc=$?
	if [ "$rc" -ne 0 ]; then
		return 1
	fi
	if grep -qiE "^error:|nft:|conflicting|no such file|not supported|could not process" "$LOG"; then
		return 1
	fi
	return 0
}

cmd_validate() {
	[ -f "$SCRIPT" ] || { echo "No firewall script at $SCRIPT" | tee "$LOG"; return 1; }
	if _syntax; then
		echo "Shell syntax OK. (nft rules are verified when applied.)" | tee "$LOG"
		return 0
	fi
	echo "Shell syntax error:" ; cat "$LOG"
	return 1
}

cmd_apply() {
	[ -f "$SCRIPT" ] || { echo "No firewall script at $SCRIPT" | tee "$LOG"; return 1; }

	# Serialize concurrent applies (UI + boot) when flock is available.
	if command -v flock >/dev/null 2>&1; then
		exec 9>"$LOCK"; flock 9 2>/dev/null || true
	fi

	if ! _syntax; then
		{ echo "[$(now)] Shell syntax error; not applying."; cat "$LOG"; } | tee "$LOG.msg" >&2
		cat "$LOG.msg"; rm -f "$LOG.msg"
		return 1
	fi

	if _run "$SCRIPT"; then
		cp "$SCRIPT" "$GOOD" 2>/dev/null
		echo "[$(now)] Firewall applied OK."
		return 0
	fi

	echo "[$(now)] Apply FAILED:"; cat "$LOG"
	if [ -f "$GOOD" ]; then
		echo "[$(now)] Rolling back to last-known-good..."
		if _run "$GOOD"; then
			echo "[$(now)] Rollback OK. The bad script is still saved at $SCRIPT; fix it and re-apply."
		else
			echo "[$(now)] Rollback ALSO failed:"; cat "$LOG"
		fi
	else
		echo "[$(now)] No known-good copy yet; nothing to roll back to."
	fi
	return 1
}

cmd_flush() {
	for pair in "$FW_TABLES"; do
		# shellcheck disable=SC2086
		nft delete table $pair 2>/dev/null
	done
	# Remove fwmark policy routes this kind of script commonly adds.
	for i in $(ip rule show 2>/dev/null | grep -i "fwmark 0x1" | awk -F: '{print $1}'); do
		ip rule del priority "$i" 2>/dev/null
	done
	for i in $(ip -6 rule show 2>/dev/null | grep -i "fwmark 0x1" | awk -F: '{print $1}'); do
		ip -6 rule del priority "$i" 2>/dev/null
	done
	return 0
}

cmd_status() {
	echo "=== nft: sing-box related tables ==="
	nft list ruleset 2>/dev/null | awk '
		/^table / { keep = ($0 ~ /sing/) }
		keep { print }
	'
	echo
	echo "=== ip rule (fwmark policy routing) ==="
	{ ip rule show 2>/dev/null | grep -i fwmark; ip -6 rule show 2>/dev/null | grep -i fwmark; } || true
	echo
	echo "=== sing-box listening sockets ==="
	{ ss -lntup 2>/dev/null | grep -i sing-box || netstat -lntup 2>/dev/null | grep -i sing-box; } || echo "(none)"
}

case "${1:-}" in
	validate) cmd_validate ;;
	apply)    cmd_apply ;;
	flush)    cmd_flush ;;
	status)   cmd_status ;;
	*) echo "Usage: $0 {validate|apply|flush|status}" >&2; exit 2 ;;
esac
