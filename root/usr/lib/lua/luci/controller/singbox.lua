module("luci.controller.singbox", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/singbox") then
		return
	end

	local page = entry({"admin", "services", "sing-box"}, firstchild(), _("Sing-box设置"), 60)
	page.sysauth = "root" 
	page.dependent = true
	page.acl_depends = { "luci-app-singbox-admin" }

	entry({"admin", "services", "sing-box", "main"}, form("singbox/main"), _("Dashboard"), 10).leaf = true
	entry({"admin", "services", "sing-box", "config"}, form("singbox/config"), _("Config Editor"), 20).leaf = true
	entry({"admin", "services", "sing-box", "script"}, form("singbox/script"), _("Firewall Script"), 30).leaf = true
end
