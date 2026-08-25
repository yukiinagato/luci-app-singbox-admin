[![Build luci-app-singbox-admin](https://github.com/yukiinagato/luci-app-singbox-admin/actions/workflows/build.yml/badge.svg)](https://github.com/yukiinagato/luci-app-singbox-admin/actions/workflows/build.yml)

# luci-app-singbox-admin

A LuCI web interface for [sing-box](https://github.com/SagerNet/sing-box) on
OpenWrt / ImmortalWrt: dashboard, config editor, firewall-script management, and
one-click binary updates.

## Supported OpenWrt versions

| OpenWrt | Package manager | Package format | Status |
|---|---|---|---|
| 23.05 / 24.10 (and ImmortalWrt equivalents) | opkg | `.ipk` | supported |
| 25.12 / master snapshot | apk | `.apk` | supported |
| ≤ 21.02 | opkg | — | **not supported** (no client-side LuCI views) |

The app is a **modern JS LuCI app**: client-side views
(`/www/luci-static/resources/view/singbox/*.js`), menu registration via
`/usr/share/luci/menu.d/`, and a single privileged backend helper
`/usr/libexec/singbox-admin` written in [ucode](https://ucode.mein.io/)
(already shipped with `luci-base`). There is **no Lua controller and no
`luci-compat` dependency**, and all backend access is gated by the rpcd ACL in
`/usr/share/rpcd/acl.d/luci-app-singbox-admin.json`.

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
- Binary & platform management: detects the package manager (opkg or apk) and
  the OpenWrt package arch, then installs the matching upstream
  `sing-box_<ver>_openwrt_<arch>.ipk` / `.apk` — or a custom URL (`.ipk`,
  `.apk`, or a plain tarball with try-run + rollback). Downloads run
  asynchronously with live log polling, so long downloads no longer hit the
  ubus 30 s timeout.
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
  - On first use the live script is **seeded from a template**
    (`/usr/share/singbox-admin/nftables.sh.example`): a full-tproxy setup that
    proxies all LAN devices by default and excludes infrastructure (containers/
    VMs, VoIP, a `bypass_mac` set) — new devices are proxied automatically. An
    existing `/etc/sing-box/nftables.sh` is never overwritten.

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

## Install

Grab the artifact matching your system from the
[Releases](../../releases) page:

```sh
# OpenWrt 23.05 / 24.10 (opkg)
opkg install luci-app-singbox-admin_*_all.ipk

# OpenWrt 25.12 / master snapshot (apk)
apk add --allow-untrusted luci-app-singbox-admin_*_all.apk
```

`--allow-untrusted` is needed because the CI-built `.apk` is unsigned (the same
applies to sing-box's own upstream `.apk` releases). After install the LuCI
pages appear under **Services → Sing-box设置** — no cache clearing needed
(handled by the post-install script).

## Build

CI builds both formats on every push/tag (see `.github/workflows/build.yml`):

- `.ipk` via OpenWrt's `ipkg-build` script;
- `.apk` via `apk mkpkg` from a host build of
  [apk-tools](https://gitlab.alpinelinux.org/alpine/apk-tools) v3, using the
  same metadata layout as OpenWrt mainline's `package-pack.mk`
  (`arch:noarch`, opkg `postinst` mapped to the `post-install` script slot).

The `Makefile` also builds in the normal OpenWrt buildroot/SDK feed flow
(`luci.mk` installs `htdocs/` to `/www` and `root/` to `/`).
