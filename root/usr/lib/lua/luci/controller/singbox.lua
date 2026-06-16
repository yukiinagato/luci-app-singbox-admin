module("luci.controller.singbox", package.seeall)

local fs = require "nixio.fs"
local http = require "luci.http"
local sys = require "luci.sys"
local jsonc = require "luci.jsonc"

local CONFIG_PATH = "/etc/sing-box/config.json"
local UPDATE_SCRIPT = "/usr/libexec/singbox-admin-update.sh"

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

	entry({"admin", "services", "sing-box", "runtime_status"}, call("action_runtime_status")).leaf = true
	entry({"admin", "services", "sing-box", "update_info"}, call("action_update_info")).leaf = true
	entry({"admin", "services", "sing-box", "update_download"}, call("action_update_download")).leaf = true
end

local function json_response(code, payload)
	http.status(code, "OK")
	http.prepare_content("application/json")
	http.write_json(payload or {})
end

local function trim(s)
	return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function sanitize_version(v)
	v = trim(v):gsub("^v", "")
	if v:match("^[0-9][0-9A-Za-z%._%-]*$") then
		return v
	end
	return nil
end

local function sanitize_arch(a)
	a = trim(a):lower()
	if a:match("^[a-z0-9_%-]+$") then
		return a
	end
	return nil
end

local function sanitize_url(u)
	u = trim(u)
	if u == "" then
		return nil
	end
	if u:match("^https?://[%w%._%-%~:/%?#%[%]@!%$&'%(%)%*%+,;=]+$") then
		return u
	end
	return nil
end

local function get_version_output()
	local out = sys.exec("/usr/bin/sing-box version 2>&1")
	out = trim(out)
	return out ~= "" and out or "unknown"
end

local function detect_raw_arch()
	local arch = trim(sys.exec("uci -q get lucistat.system.arch 2>/dev/null"))
	if arch ~= "" then
		return arch, "uci:lucistat.system.arch"
	end

	local board = jsonc.parse(sys.exec("ubus call system board 2>/dev/null")) or {}
	arch = trim(board.architecture or board.cpu_arch or "")
	if arch ~= "" then
		return arch, "ubus:system.board"
	end

	arch = trim(sys.exec("uname -m 2>/dev/null"))
	if arch ~= "" then
		return arch, "uname -m"
	end

	return "unknown", "fallback"
end

local function map_singbox_arch(raw)
	local a = (raw or ""):lower()
	if a:find("x86_64", 1, true) or a == "amd64" then
		return "amd64"
	elseif a:find("aarch64", 1, true) or a == "arm64" then
		return "arm64"
	elseif a:find("armv7", 1, true) then
		return "armv7"
	elseif a:find("armv6", 1, true) then
		return "armv6"
	elseif a:find("armv5", 1, true) then
		return "armv5"
	elseif a:find("i386", 1, true) or a:find("i686", 1, true) then
		return "386"
	elseif a:find("mips64el", 1, true) then
		return "mips64le"
	elseif a:find("mipsel", 1, true) then
		return "mipsle"
	elseif a:find("mips64", 1, true) then
		return "mips64"
	elseif a:find("mips", 1, true) then
		return "mips"
	elseif a:find("riscv64", 1, true) then
		return "riscv64"
	elseif a:find("s390x", 1, true) then
		return "s390x"
	elseif a:find("loongarch64", 1, true) then
		return "loong64"
	end
	return "amd64"
end

local function detect_platform_arch()
	local raw, source = detect_raw_arch()
	local mapped = map_singbox_arch(raw)
	return raw, mapped, source
end

-- Returns scheme, host, port parsed from clash_api.external_controller.
-- The host is left as stored (may be a wildcard/loopback bind address);
-- the browser substitutes its own hostname when needed.
local function read_panel_info()
	if not fs.access(CONFIG_PATH) then
		return nil
	end

	local data = jsonc.parse(fs.readfile(CONFIG_PATH) or "")
	if type(data) ~= "table" then
		return nil
	end

	local experimental = data.experimental or {}
	local clash_api = experimental.clash_api or {}
	local ec = clash_api.external_controller
	if type(ec) ~= "string" or trim(ec) == "" then
		return nil
	end

	ec = trim(ec)
	local scheme = "http"
	local rest = ec:match("^(https?)://(.+)$")
	if rest then
		scheme, ec = ec:match("^(https?)://(.+)$")
	end

	-- Split host:port, accounting for bracketed IPv6 like [::]:9090
	local host, port
	if ec:match("^%[") then
		host, port = ec:match("^(%[.-%]):?(%d*)$")
	else
		host, port = ec:match("^(.-):(%d+)$")
		if not host then
			host, port = ec, ""
		end
	end

	if not port or port == "" then
		return nil
	end

	return { scheme = scheme, host = host or "", port = port }
end

local function collect_listeners()
	local out = sys.exec("ss -lntup 2>/dev/null | awk 'NR>1 && /sing-box/ {print $1\"\\t\"$5\"\\t\"$NF}'")
	if out == "" then
		out = sys.exec("netstat -lntup 2>/dev/null | awk 'NR>2 && /sing-box/ {print $1\"\\t\"$4\"\\t\"$7}'")
	end

	local listeners = {}
	for line in out:gmatch("[^\r\n]+") do
		local proto, local_addr, proc = line:match("^(%S+)%s+(%S+)%s+(.*)$")
		if proto and local_addr then
			local port = local_addr:match(".*:(%d+)$") or "-"
			listeners[#listeners + 1] = {
				proto = proto,
				address = local_addr,
				port = port,
				proc = proc or ""
			}
		end
	end

	return listeners
end

function action_runtime_status()
	local running = (sys.call("/etc/init.d/sing-box status >/dev/null 2>&1") == 0)
	local enabled = (sys.call("/etc/init.d/sing-box enabled >/dev/null 2>&1") == 0)
	local pid = trim(sys.exec("pidof sing-box 2>/dev/null | awk '{print $1}'"))
	local logs = sys.exec("logread -e sing-box 2>/dev/null | tail -n 200")
	local panel = read_panel_info()
	json_response(200, {
		running = running,
		enabled = enabled,
		pid = pid ~= "" and pid or "-",
		listeners = collect_listeners(),
		logs = logs ~= "" and logs or "No sing-box logs found.",
		panel_scheme = panel and panel.scheme or "",
		panel_host = panel and panel.host or "",
		panel_port = panel and panel.port or ""
	})
end

function action_update_info()
	local latest = ""
	local body = sys.exec("uclient-fetch -T 8 -qO- https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null")
	if body == "" then
		body = sys.exec("wget -T 8 -qO- https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null")
	end

	if body and body ~= "" then
		local data = jsonc.parse(body) or {}
		latest = trim((data.tag_name or ""):gsub("^v", ""))
	end

	local raw_arch, auto_arch, arch_source = detect_platform_arch()
	json_response(200, {
		version_output = get_version_output(),
		latest = latest,
		raw_arch = raw_arch,
		auto_arch = auto_arch,
		arch_source = arch_source
	})
end

function action_update_download()
	local version = sanitize_version(http.formvalue("version") or "")
	local arch = sanitize_arch(http.formvalue("arch") or "")
	local url = sanitize_url(http.formvalue("url") or "")

	if not url and (not version or not arch) then
		json_response(400, { ok = false, message = "Use URL or provide valid version + architecture." })
		return
	end

	if not fs.access(UPDATE_SCRIPT) then
		json_response(500, { ok = false, message = "Update script not found." })
		return
	end

	local cmd
	if url then
		cmd = string.format("%q --url %q >/tmp/sing-box-update.log 2>&1", UPDATE_SCRIPT, url)
	else
		cmd = string.format("%q --version %q --arch %q >/tmp/sing-box-update.log 2>&1", UPDATE_SCRIPT, version, arch)
	end

	local rc = sys.call(cmd)
	if rc == 0 then
		json_response(200, {
			ok = true,
			message = "sing-box updated successfully.",
			version_output = get_version_output()
		})
	else
		local msg = trim(fs.readfile("/tmp/sing-box-update.log") or "")
		if msg == "" then
			msg = "Update failed."
		end
		json_response(500, { ok = false, message = msg })
	end
end
