[![Build luci-app-singbox-admin](https://github.com/yukiinagato/luci-app-singbox-admin/actions/workflows/build.yml/badge.svg)](https://github.com/yukiinagato/luci-app-singbox-admin/actions/workflows/build.yml)

# luci-app-singbox-admin

A LuCI web interface for [sing-box](https://github.com/SagerNet/sing-box) on
OpenWrt / ImmortalWrt: dashboard, config editor, firewall-script management, and
one-click binary updates.

## Features

**Dashboard** (`admin/services/sing-box/main`)
- Service status / start / stop / restart, boot-enable state.
- **Resources & Instances** panel: lists *every* sing-box process on the host
  (including ones running inside LXC/VM containers, which share the host PID
  namespace) with live per-process **CPU%** and **RSS**, and flags which one is
  the procd-managed instance. Also shows conntrack count and clash-API
  connection/traffic totals. This makes "is sing-box actually the CPU hog, and
  which sing-box?" answerable at a glance — VSZ is not CPU, and container
  instances are not your managed one.
- Binary & platform management: detects the OpenWrt package arch and installs
  the matching `sing-box_<ver>_openwrt_<arch>.ipk`, or a custom URL.
- External clash panel link, active-port list, logs.

**Config Editor** (`admin/services/sing-box/config`)
- Edits `/etc/sing-box/config.json` and runs `sing-box check` before saving.
- **Every save keeps a timestamped backup** under `/etc/sing-box/backups/`
  (keep count via `backup_keep`), with a **restore** dropdown — a
  valid-but-wrong edit can be undone. Restores are validated before they
  replace the live config, and snapshot the current config first.
- Warns about stray editor swap files (`*.swp`) left in `/etc/sing-box`.

**Firewall Script** (`admin/services/sing-box/script`)
- Edits `/etc/sing-box/nftables.sh` and — unlike before — **actually applies
  it**, through a validated, rollback-protected executor
  (`/usr/libexec/singbox-fw.sh`):
  - **Validate**: shell-syntax check.
  - **Apply now**: runs the script; on any `nft` error it **auto-rolls back**
    to the last-known-good copy (`/etc/sing-box/.nftables.good.sh`).
  - **Apply firewall on boot** toggle: enables the `singbox-firewall` init
    service so the script is (re)applied at boot.
  - **Live firewall state** panel: shows the sing-box-related `nft` ruleset,
    fwmark policy routes, and listening sockets that are *actually loaded* —
    so "what I wrote" vs "what is running" is never ambiguous again.

## Runtime requirements

- `sing-box`, `luci-base`, `nftables` (pulled as dependencies).
- For transparent proxy (tproxy): `kmod-nft-tproxy` (and `ip-full` if your
  script uses `ip rule`/`ip route` policy routing). These are usually already
  present on setups that use tproxy; install them if the firewall Apply reports
  `not supported`.

## Important: the firewall script now takes effect

Previously `/etc/sing-box/nftables.sh` was editable in the UI but **nothing ran
it** — a common source of "my rules aren't working" confusion. It is now the
single, validated file the plugin applies.

If your sing-box init script already loads its **own** nft ruleset (e.g.
`nft -f /etc/singbox-tproxy.nft`), you now have two potential owners of the same
nft table. Pick one:

- **Recommended:** move that ruleset's logic into `/etc/sing-box/nftables.sh`,
  remove the `nft -f ...` line from your sing-box init, and turn on
  *Apply firewall on boot*. The plugin then owns the firewall end-to-end.
- Or leave your init as-is and keep *Apply firewall on boot* **off** (default),
  using the Firewall tab only to inspect live state.

## Build

CI builds an `.ipk` on every push/tag (see `.github/workflows/build.yml`).
Install with `opkg install luci-app-singbox-admin_*.ipk`.
