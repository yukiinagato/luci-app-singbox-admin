local fs = require "nixio.fs"
local sys = require "luci.sys"
local util = require "luci.util"

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

local logs = m:field(TextValue, "logs", translate("Logs"), translate("Output from logread -e sing-box"))
logs.rows = 14
logs.readonly = true
function logs.cfgvalue()
	local out = sys.exec("logread -e sing-box 2>/dev/null | tail -n 200")
	return out ~= "" and out or "No sing-box logs found."
end

local clearlog = m:field(Button, "clear_logs", translate("Clear Logs"))
clearlog.inputstyle = "remove"
function clearlog.write()
	sys.call("logclear >/dev/null 2>&1 || true")
end

return m
