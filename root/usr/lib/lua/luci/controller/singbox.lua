module("luci.controller.singbox", package.seeall)

local sys = require "luci.sys"
local http = require "luci.http"
local jsonc = require "luci.jsonc"

local function trim(v)
	return (v or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function runtime_payload()
	local payload = {
		pid = trim(sys.exec("pidof sing-box 2>/dev/null | awk '{print $1}'")),
		listeners = {}
	}

	if payload.pid == "" then
		payload.pid = "N/A"
	end

	local out = sys.exec("ss -lntup 2>/dev/null | grep -F 'sing-box' || true")
	for line in (out or ""):gmatch("[^\r\n]+") do
		local proto = line:match("^(%S+)") or ""
		local local_addr = line:match("%s+([%*%[%]%.%x:]+:%d+)%s") or ""
		local typ = "UNKNOWN"
		if proto:find("tcp", 1, true) then
			typ = "STREAM"
		elseif proto:find("udp", 1, true) then
			typ = "DGRAM"
		end

		payload.listeners[#payload.listeners + 1] = {
			proto = proto,
			type = typ,
			local = local_addr
		}
	end

	return payload
end

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
	entry({"admin", "services", "sing-box", "runtime"}, call("action_runtime")).leaf = true
	entry({"admin", "services", "sing-box", "logs"}, call("action_logs")).leaf = true
end

function action_runtime()
	http.prepare_content("application/json")
	http.write_json(runtime_payload())
end

function action_logs()
	http.prepare_content("text/plain; charset=utf-8")
	local out = sys.exec("logread -e sing-box 2>/dev/null | tail -n 200")
	http.write(out ~= "" and out or "No sing-box logs found.\n")
end
