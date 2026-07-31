include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-singbox-admin
# PKG_VERSION 必須存在，CI 會自動將其替換為 GitHub Tag 的版本
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_MAINTAINER:=Yukiinagato
PKG_LICENSE:=MIT

# LuCI 專用定義
LUCI_TITLE:=Sing-box Admin Web Interface
# nftables is required by the firewall executor. tproxy transparent proxying
# additionally needs kmod-nft-tproxy at runtime (not forced here to keep the
# manual .ipk install flexible -- see README).
LUCI_DEPENDS:=+sing-box +luci-base +nftables
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/description
  LuCI web admin for sing-box on OpenWrt: a live dashboard (service state,
  per-process CPU/RAM, clash-api connections, listening sockets and logs),
  a config.json editor with validation and timestamped backups/restore, a
  rollback-protected nftables/tproxy firewall-script manager (validate,
  apply now, apply on boot), and one-click sing-box binary updates from
  GitHub releases with architecture auto-detection.
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
