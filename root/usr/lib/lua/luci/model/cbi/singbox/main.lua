local fs = require "nixio.fs"
local sys = require "luci.sys"
local util = require "luci.util"
local http = require "luci.http"
local jsonc = require "luci.jsonc"

local function shell_quote(v)
	return string.format("%q", v or "")
end

local function trim(v)
	return (v or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function detect_arch()
	local arch = trim(sys.exec("uci -q get lucistat.system.arch 2>/dev/null"))
	if arch == "" then
		arch = trim(sys.exec("uname -m 2>/dev/null"))
	end

	local map = {
		["x86_64"] = "amd64",
		["amd64"] = "amd64",
		["aarch64"] = "arm64",
		["arm64"] = "arm64",
		["armv8"] = "arm64",
		["armv7l"] = "armv7",
		["armv7"] = "armv7",
		["armv6l"] = "armv6",
		["armv6"] = "armv6",
		["mipsel_24kc"] = "mipsle",
		["mipsel"] = "mipsle",
		["mips_24kc"] = "mips",
		["mips"] = "mips",
		["mips64el"] = "mips64le",
		["mips64"] = "mips64",
		["riscv64"] = "riscv64",
	}

	return map[arch] or arch
end

local function parse_external_panel()
	local raw = fs.readfile("/etc/sing-box/config.json")
	if not raw or raw == "" then
		return nil
	end

	local cfg = jsonc.parse(raw)
	if type(cfg) ~= "table" then
		return nil
	end

	local exp = cfg.experimental or {}
	local clash = exp.clash_api or {}
	local addr = clash.external_controller
	if type(addr) ~= "string" or addr == "" then
		return nil
	end

	addr = trim(addr)
	if addr:match("^https?://") then
		return addr
	end

	local host, port = addr:match("^([^:]+):(%d+)$")
	if not host or not port then
		return nil
	end

	if host == "0.0.0.0" or host == "::" or host == "[::]" then
		local req_host = http.getenv("HTTP_HOST") or ""
		req_host = req_host:match("^([^:]+)") or req_host
		if req_host and req_host ~= "" then
			host = req_host
		end
	end

	return "http://" .. host .. ":" .. port
end

local function fetch_latest_and_versions()
	local cmd = [[wget -qO- https://api.github.com/repos/SagerNet/sing-box/releases 2>/dev/null | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^" ]*\)".*/\1/p' | head -n 15]]
	local out = sys.exec(cmd)
	local versions, seen = {}, {}

	for line in (out or ""):gmatch("[^\r\n]+") do
		line = trim(line)
		if line ~= "" and not seen[line] then
			versions[#versions + 1] = line
			seen[line] = true
		end
	end

	local current = trim(sys.exec("/usr/bin/sing-box version 2>/dev/null | sed -n '1s/.*version \([^ ]*\).*/\1/p'"))
	if current ~= "" and not seen[current] then
		table.insert(versions, 1, current)
	end

	return versions[1] or "", versions
end

local m = SimpleForm("singbox", translate("sing-box Dashboard"), translate("Manage sing-box runtime status and resources."))
m.reset = false
m.submit = false

local status_text = m:field(DummyValue, "service_state", translate("Service Status"))
status_text.rawhtml = true
function status_text.cfgvalue()
	local running = (sys.call("/etc/init.d/sing-box status >/dev/null 2>&1") == 0)
	local enabled = (sys.call("/etc/init.d/sing-box enabled >/dev/null 2>&1") == 0)
	local s1 = running and "<span style='color:green;font-weight:bold'>Running</span>" or "<span style='color:red;font-weight:bold'>Stopped</span>"
	local s2 = enabled and "<span style='color:green'>Enabled</span>" or "<span style='color:#999'>Disabled</span>"
	return string.format("%s<br />Boot: %s", s1, s2)
end

local current_version = m:field(DummyValue, "current_version", translate("Current Version"))
function current_version.cfgvalue()
	local ver = trim(sys.exec("/usr/bin/sing-box version 2>/dev/null | sed -n '1s/.*version \([^ ]*\).*/\1/p'"))
	return (ver ~= "" and ver) or "Unknown"
end

local latest_ver, version_list = fetch_latest_and_versions()
local latest_version = m:field(DummyValue, "latest_version", translate("Latest Version (GitHub)"))
function latest_version.cfgvalue()
	return latest_ver ~= "" and latest_ver or "Unavailable"
end

local arch_info = m:field(DummyValue, "arch_info", translate("Detected Architecture"))
function arch_info.cfgvalue()
	return detect_arch()
end

local version_select = m:field(ListValue, "target_version", translate("Target Version"))
for _, v in ipairs(version_list) do
	version_select:value(v, v)
end
if #version_list == 0 then
	version_select:value("", "Unavailable (check network)")
end
version_select.default = version_list[1]

local arch_select = m:field(ListValue, "target_arch", translate("Target Architecture"))
arch_select:value("auto", "auto (detected)")
arch_select:value("amd64", "amd64")
arch_select:value("arm64", "arm64")
arch_select:value("armv7", "armv7")
arch_select:value("armv6", "armv6")
arch_select:value("386", "386")
arch_select:value("mips", "mips")
arch_select:value("mipsle", "mipsle")
arch_select:value("mips64", "mips64")
arch_select:value("mips64le", "mips64le")
arch_select:value("riscv64", "riscv64")
arch_select.default = "auto"

local update_btn = m:field(Button, "download_replace", translate("Download & Replace"))
update_btn.inputstyle = "apply"
function update_btn.write()
	local version = trim(http.formvalue("cbid.singbox.target_version") or "")
	local arch = trim(http.formvalue("cbid.singbox.target_arch") or "auto")
	if version == "" then
		return
	end

	sys.call("/usr/libexec/singbox-admin/update-singbox.sh " .. shell_quote(version) .. " " .. shell_quote(arch) .. " >/tmp/singbox-update.log 2>&1")
end

local update_log = m:field(DummyValue, "update_log", translate("Update Log"))
update_log.rawhtml = true
function update_log.cfgvalue()
	local out = fs.readfile("/tmp/singbox-update.log") or "No update operation yet."
	return "<pre style='max-height:180px;overflow:auto'>" .. util.pcdata(out) .. "</pre>"
end

local start = m:field(Button, "start", translate("Start"))
start.inputstyle = "apply"
function start.write()
	sys.call("/etc/init.d/sing-box start >/dev/null 2>&1")
end

local stop = m:field(Button, "stop", translate("Stop"))
stop.inputstyle = "remove"
function stop.write()
	sys.call("/etc/init.d/sing-box stop >/dev/null 2>&1")
end

local restart = m:field(Button, "restart", translate("Restart"))
restart.inputstyle = "reload"
function restart.write()
	sys.call("/etc/init.d/sing-box restart >/dev/null 2>&1")
end

local external_panel = m:field(DummyValue, "external_panel", translate("External Panel"))
external_panel.rawhtml = true
function external_panel.cfgvalue()
	local panel = parse_external_panel()
	if not panel then
		return "<span style='color:#999'>Not configured in config.json</span>"
	end
	return string.format("<a class='btn cbi-button cbi-button-apply' href='%s' target='_blank' rel='noopener noreferrer'>%s</a>", util.pcdata(panel), translate("Open External Panel"))
end

local runtime_info = m:field(DummyValue, "runtime_info", translate("Runtime Details"))
runtime_info.rawhtml = true
function runtime_info.cfgvalue()
	local pid = trim(sys.exec("pidof sing-box 2>/dev/null | awk '{print $1}'"))
	pid = (pid ~= "" and pid) or "N/A"

	local lines = {}
	lines[#lines + 1] = "<div><strong>PID:</strong> <span id='singbox-pid'>" .. util.pcdata(pid) .. "</span></div>"
	lines[#lines + 1] = "<table class='table cbi-section-table' id='singbox-listeners' style='margin-top:8px'>"
	lines[#lines + 1] = "<tr class='tr table-titles'><th class='th'>Proto</th><th class='th'>Type</th><th class='th'>Local Address</th></tr>"
	lines[#lines + 1] = "</table>"
	lines[#lines + 1] = [[<script type="text/javascript">
		(function() {
			function esc(v) { return String(v || '').replace(/[&<>"']/g, function(c){ return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]; }); }
			function render(data) {
				var pidNode = document.getElementById('singbox-pid');
				if (pidNode) pidNode.textContent = data.pid || 'N/A';
				var tb = document.getElementById('singbox-listeners');
				if (!tb) return;
				var html = "<tr class='tr table-titles'><th class='th'>Proto</th><th class='th'>Type</th><th class='th'>Local Address</th></tr>";
				if (data.listeners && data.listeners.length) {
					for (var i = 0; i < data.listeners.length; i++) {
						var it = data.listeners[i];
						html += "<tr class='tr'><td class='td'>" + esc(it.proto) + "</td><td class='td'>" + esc(it.type) + "</td><td class='td'>" + esc(it.local) + "</td></tr>";
					}
				} else {
					html += "<tr class='tr'><td class='td' colspan='3'>No listening sockets detected.</td></tr>";
				}
				tb.innerHTML = html;
			}
			XHR.poll(5, '" .. luci.dispatcher.build_url("admin", "services", "sing-box", "runtime") .. [[', null, function(x, data) {
				if (data) render(data);
			});
		})();
	</script>]]
	return table.concat(lines, "\n")
end

local ui_files = m:field(DummyValue, "ui_files", translate("UI Directory Listing"))
ui_files.rawhtml = true
function ui_files.cfgvalue()
	local dir = "/etc/sing-box/ui"
	if not fs.access(dir) then
		return "<pre>Directory not found: " .. dir .. "</pre>"
	end

	local names = {}
	for name in fs.dir(dir) do
		names[#names + 1] = name
	end
	table.sort(names)

	if #names == 0 then
		return "<pre>(empty)</pre>"
	end

	return "<pre>" .. util.pcdata(table.concat(names, "\n")) .. "</pre>"
end

local logs = m:field(DummyValue, "logs", translate("Logs"), translate("Auto-refreshing output from logread -e sing-box"))
logs.rawhtml = true
function logs.cfgvalue()
	local out = sys.exec("logread -e sing-box 2>/dev/null | tail -n 200")
	if out == "" then
		out = "No sing-box logs found."
	end
	return [[<textarea id="singbox-logbox" class="cbi-input-textarea" style="width:100%;min-height:280px" readonly="readonly">]]
		.. util.pcdata(out)
		.. [[</textarea>
		<script type="text/javascript">
			(function() {
				var box = document.getElementById('singbox-logbox');
				if (!box) return;
				function scrollBottom() { box.scrollTop = box.scrollHeight; }
				scrollBottom();
				XHR.poll(3, ']] .. luci.dispatcher.build_url("admin", "services", "sing-box", "logs") .. [[', null, function(x, data) {
					if (typeof data === 'string') {
						box.value = data;
						scrollBottom();
					}
				});
			})();
		</script>]]
end

local clearlog = m:field(Button, "clear_logs", translate("Clear Logs"))
clearlog.inputstyle = "remove"
function clearlog.write()
	sys.call("logclear >/dev/null 2>&1 || true")
end

return m
