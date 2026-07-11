module("luci.controller.singbox", package.seeall)

local fs = require "nixio.fs"
local http = require "luci.http"
local sys = require "luci.sys"
local jsonc = require "luci.jsonc"
local uci = require "luci.model.uci".cursor()

local CONFIG_PATH = "/etc/sing-box/config.json"
local UPDATE_SCRIPT = "/usr/libexec/singbox-admin-update.sh"
local FW_SCRIPT = "/etc/sing-box/nftables.sh"
local FW_EXEC = "/usr/libexec/singbox-fw.sh"
local BACKUP_DIR = "/etc/sing-box/backups"

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
	entry({"admin", "services", "sing-box", "health"}, call("action_health")).leaf = true
	entry({"admin", "services", "sing-box", "update_info"}, call("action_update_info")).leaf = true
	entry({"admin", "services", "sing-box", "update_download"}, call("action_update_download")).leaf = true
	entry({"admin", "services", "sing-box", "fw_state"}, call("action_fw_state")).leaf = true
	entry({"admin", "services", "sing-box", "fw_apply"}, call("action_fw_apply")).leaf = true
	entry({"admin", "services", "sing-box", "fw_validate"}, call("action_fw_validate")).leaf = true
	entry({"admin", "services", "sing-box", "config_backups"}, call("action_config_backups")).leaf = true
	entry({"admin", "services", "sing-box", "config_restore"}, call("action_config_restore")).leaf = true
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

-- The sing-box release assets named sing-box_<ver>_openwrt_<arch>.ipk use the
-- OpenWrt package architecture (e.g. "x86_64", "aarch64_cortex-a53",
-- "mipsel_24kc"). That string is exactly what `opkg print-architecture`
-- reports, so we can feed it straight into the asset name -- no mapping table.
local function detect_openwrt_arch()
	local out = sys.exec("opkg print-architecture 2>/dev/null") or ""
	local best, best_prio = nil, -1
	-- lines look like: "arch x86_64 10"
	for name, prio in out:gmatch("arch%s+(%S+)%s+(%d+)") do
		if name ~= "all" and name ~= "noarch" then
			local p = tonumber(prio) or 0
			if p >= best_prio then
				best, best_prio = name, p
			end
		end
	end
	return best
end

local function detect_platform_arch()
	local raw = detect_raw_arch()
	local openwrt = detect_openwrt_arch()
	if openwrt then
		return raw, openwrt, "opkg print-architecture"
	end
	-- Fallback: derive a plausible opkg arch from the CPU when opkg is
	-- unavailable. Covers only the common generic targets. NOTE: this must be
	-- an OpenWrt package arch (e.g. x86_64), never "amd64" -- there is no
	-- sing-box openwrt_amd64 asset.
	local a = (raw or ""):lower()
	if a:find("x86_64", 1, true) or a == "amd64" then
		return raw, "x86_64", "uname (fallback)"
	elseif a:find("aarch64", 1, true) or a == "arm64" then
		return raw, "aarch64_generic", "uname (fallback)"
	elseif a:find("riscv64", 1, true) then
		return raw, "riscv64_generic", "uname (fallback)"
	end
	return raw, "", "unknown"
end

-- Returns scheme, host, port, secret parsed from experimental.clash_api.
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

	-- Resolve the dashboard URL path. The clash API root requires auth (returns
	-- {"message":"Unauthorized"}), so the button must point at the UI path.
	-- Precedence: an explicit UCI override (singbox.main.panel_path) wins;
	-- otherwise, if clash_api.external_ui is configured, sing-box serves it at
	-- its fixed /ui/ path. external_ui is only the local directory, not the URL.
	local ui_path = ""
	local override = uci:get("singbox", "main", "panel_path")
	if type(override) == "string" and trim(override) ~= "" then
		ui_path = trim(override)
		if ui_path:sub(1, 1) ~= "/" then ui_path = "/" .. ui_path end
		if ui_path:sub(-1) ~= "/" then ui_path = ui_path .. "/" end
	elseif type(clash_api.external_ui) == "string" and trim(clash_api.external_ui) ~= "" then
		ui_path = "/ui/"
	end

	return {
		scheme = scheme,
		host = host or "",
		port = port,
		secret = type(clash_api.secret) == "string" and clash_api.secret or "",
		ui_path = ui_path
	}
end

-- Query the clash_api (used by sing-box for stats). Returns a parsed table or
-- nil. Reachable on loopback regardless of the configured bind address.
local function clash_get(path)
	local panel = read_panel_info()
	if not panel then
		return nil
	end
	local host = panel.host
	local wildcard = { [""] = true, ["0.0.0.0"] = true, ["127.0.0.1"] = true,
		["localhost"] = true, ["::"] = true, ["[::]"] = true }
	if wildcard[host] then
		host = "127.0.0.1"
	end
	local hdr = ""
	if panel.secret ~= "" then
		hdr = string.format("--header %q", "Authorization: Bearer " .. panel.secret)
	end
	local url = string.format("%s://%s:%s%s", panel.scheme, host, panel.port, path)
	local body = sys.exec(string.format(
		"uclient-fetch -T 3 -qO- %s %q 2>/dev/null", hdr, url))
	if not body or trim(body) == "" then
		body = sys.exec(string.format("wget -T 3 -qO- %q 2>/dev/null", url))
	end
	if not body or trim(body) == "" then
		return nil
	end
	return jsonc.parse(body)
end

-- Enumerate every sing-box process on the host (including ones inside
-- containers, which share the host PID namespace). Returns raw cumulative CPU
-- jiffies so the browser can compute a rate between polls -- no server sleep.
local function collect_processes()
	local procs = {}

	-- Authoritative PID of the procd-managed instance, if we can get it.
	local managed_pid = nil
	local svc = jsonc.parse(sys.exec("ubus call service list '{\"name\":\"sing-box\"}' 2>/dev/null")) or {}
	local sb = svc["sing-box"]
	if type(sb) == "table" and type(sb.instances) == "table" then
		for _, inst in pairs(sb.instances) do
			if type(inst) == "table" and inst.pid then
				managed_pid = tostring(inst.pid)
			end
		end
	end

	for pid in fs.dir("/proc") do
		if pid:match("^%d+$") then
			local cmdline = fs.readfile("/proc/" .. pid .. "/cmdline")
			if cmdline and cmdline:find("sing-box", 1, true)
				and not cmdline:find("singbox%-fw")
				and not cmdline:find("singbox%-admin") then
				local cmd = trim((cmdline:gsub("%z", " ")))
				local stat = fs.readfile("/proc/" .. pid .. "/stat") or ""
				-- fields after the "(comm)" token: state ppid ... utime stime ...
				local after = stat:match("%)%s+(.*)$") or ""
				local f = {}
				for tok in after:gmatch("%S+") do f[#f + 1] = tok end
				local utime = tonumber(f[12]) or 0   -- field 14
				local stime = tonumber(f[13]) or 0   -- field 15
				local status = fs.readfile("/proc/" .. pid .. "/status") or ""
				local rss_kb = tonumber(status:match("VmRSS:%s*(%d+)")) or 0
				local uid = status:match("Uid:%s*(%d+)") or "?"

				local role = "other"
				if pid == managed_pid then
					role = "managed"
				elseif cmd:find(CONFIG_PATH, 1, true) then
					role = "managed"
				elseif cmd:find("/var/lib/sing-box", 1, true) then
					role = "container/other"
				end

				procs[#procs + 1] = {
					pid = pid,
					uid = uid,
					role = role,
					cmd = cmd,
					rss_kb = rss_kb,
					jiffies = utime + stime,
				}
			end
		end
	end

	table.sort(procs, function(a, b)
		if a.role ~= b.role then return a.role == "managed" end
		return tonumber(a.pid) < tonumber(b.pid)
	end)
	return procs
end

local function read_log(lines)
	lines = lines or 200
	local logs = sys.exec("logread -e sing-box 2>/dev/null | tail -n " .. lines)
	if trim(logs) ~= "" then
		return logs
	end
	-- Fallback: many setups log to stderr/procd or to a file (log.output),
	-- so `logread -e sing-box` returns nothing. Try the configured log file.
	local data = jsonc.parse(fs.readfile(CONFIG_PATH) or "") or {}
	local out = type(data.log) == "table" and data.log.output or nil
	if type(out) == "string" and out ~= "" and out ~= "stderr" and out ~= "stdout" and fs.access(out) then
		logs = sys.exec(string.format("tail -n %d %q 2>/dev/null", lines, out))
		if trim(logs) ~= "" then
			return logs
		end
	end
	logs = sys.exec("logread 2>/dev/null | grep -i sing-box | tail -n " .. lines)
	if trim(logs) ~= "" then
		return logs
	end
	return "No sing-box logs found (service may log to stderr/procd; check 'logread' or set log.output in config.json)."
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
	local panel = read_panel_info()
	json_response(200, {
		running = running,
		enabled = enabled,
		pid = pid ~= "" and pid or "-",
		listeners = collect_listeners(),
		logs = read_log(200),
		panel_scheme = panel and panel.scheme or "",
		panel_host = panel and panel.host or "",
		panel_port = panel and panel.port or "",
		panel_ui = panel and panel.ui_path or ""
	})
end

-- Resource + multi-instance health. CPU is reported as cumulative jiffies so
-- the client can derive a rate; this avoids a blocking sleep on the server.
function action_health()
	local conntrack = trim(fs.readfile("/proc/sys/net/netfilter/nf_conntrack_count") or "")
	local clash_conn = clash_get("/connections")
	local clash = nil
	if type(clash_conn) == "table" then
		clash = {
			connections = type(clash_conn.connections) == "table" and #clash_conn.connections or 0,
			download_total = clash_conn.downloadTotal or 0,
			upload_total = clash_conn.uploadTotal or 0,
			memory = clash_conn.memory or 0,
		}
	end
	json_response(200, {
		hz = 100,               -- OpenWrt kernels are built with CONFIG_HZ=100
		now = os.time(),
		procs = collect_processes(),
		conntrack = tonumber(conntrack) or nil,
		clash = clash,
	})
end

function action_fw_state()
	if not fs.access(FW_EXEC) then
		json_response(200, { output = "Firewall executor not installed: " .. FW_EXEC })
		return
	end
	local out = sys.exec(string.format("%q status 2>&1", FW_EXEC))
	local boot_enabled = (sys.call("/etc/init.d/singbox-firewall enabled >/dev/null 2>&1") == 0)
	json_response(200, {
		output = out ~= "" and out or "(empty)",
		boot_enabled = boot_enabled,
	})
end

function action_fw_validate()
	if not fs.access(FW_EXEC) then
		json_response(500, { ok = false, message = "Executor not installed." })
		return
	end
	local log = "/tmp/sing-box-fw.validate.log"
	local rc = sys.call(string.format("%q validate >%q 2>&1", FW_EXEC, log))
	json_response(200, { ok = (rc == 0), message = trim(fs.readfile(log) or "") })
end

function action_fw_apply()
	if not fs.access(FW_EXEC) then
		json_response(500, { ok = false, message = "Executor not installed." })
		return
	end
	local log = "/tmp/sing-box-fw.apply.log"
	local rc = sys.call(string.format("%q apply >%q 2>&1", FW_EXEC, log))
	local out = trim(fs.readfile(log) or "")
	json_response(rc == 0 and 200 or 500, {
		ok = (rc == 0),
		message = out ~= "" and out or (rc == 0 and "Applied." or "Apply failed.")
	})
end

local function list_backups()
	local items = {}
	if fs.access(BACKUP_DIR) then
		for name in fs.dir(BACKUP_DIR) do
			if name:match("^config%..*%.json$") then
				local st = fs.stat(BACKUP_DIR .. "/" .. name)
				items[#items + 1] = {
					name = name,
					mtime = st and st.mtime or 0,
					size = st and st.size or 0,
				}
			end
		end
	end
	table.sort(items, function(a, b) return a.mtime > b.mtime end)
	return items
end

function action_config_backups()
	json_response(200, { backups = list_backups() })
end

function action_config_restore()
	local name = trim(http.formvalue("name") or "")
	-- Strict allow-list: basename only, must match our backup pattern.
	if not name:match("^config%.[0-9A-Za-z_%.%-]+%.json$") then
		json_response(400, { ok = false, message = "Invalid backup name." })
		return
	end
	local src = BACKUP_DIR .. "/" .. name
	if not fs.access(src) then
		json_response(404, { ok = false, message = "Backup not found." })
		return
	end
	local value = fs.readfile(src)
	if not value then
		json_response(500, { ok = false, message = "Cannot read backup." })
		return
	end
	-- Validate against the current binary before touching the live config.
	local check_path = "/tmp/sing-box-config.check.json"
	local check_log = "/tmp/sing-box-check.log"
	fs.writefile(check_path, value)
	local rc = sys.call(string.format("/usr/bin/sing-box check -c %q >%q 2>&1", check_path, check_log))
	fs.remove(check_path)
	if rc ~= 0 then
		json_response(400, { ok = false, message = "Backup failed validation:\n" .. trim(fs.readfile(check_log) or "") })
		return
	end
	-- Snapshot the current config first, then restore.
	local cur = fs.readfile(CONFIG_PATH)
	if cur then
		fs.mkdirr(BACKUP_DIR)
		fs.writefile(string.format("%s/config.%s.pre-restore.json", BACKUP_DIR, os.date("%Y%m%d%H%M%S")), cur)
	end
	fs.writefile(CONFIG_PATH, value)
	json_response(200, { ok = true, message = "Restored " .. name .. ". Restart sing-box to apply." })
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
