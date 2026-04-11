include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-singbox-admin
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

LUCI_TITLE:=LuCI support for sing-box administration
LUCI_DEPENDS:=+sing-box +luci-base
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
