include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-singbox-admin
# PKG_VERSION 必須存在，CI 會自動將其替換為 GitHub Tag 的版本
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_MAINTAINER:=Yukiinagato
PKG_LICENSE:=MIT

# LuCI 專用定義
LUCI_TITLE:=Sing-box Admin Web Interface
LUCI_DEPENDS:=+sing-box +luci-base
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/description
  LuCI support for Sing-box, providing a dashboard, configuration editor, and firewall script management.
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
