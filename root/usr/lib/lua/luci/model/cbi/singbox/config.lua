local fs = require "nixio.fs"
local sys = require "luci.sys"
local util = require "luci.util"

local config_path = "/etc/sing-box/config.json"
local check_path = "/tmp/sing-box-config.check.json"
local check_log = "/tmp/sing-box-check.log"

local m = SimpleForm("singbox_config", translate("Config Editor"), translate("Edit /etc/sing-box/config.json with validation before saving."))
m.reset = false

if not fs.access(config_path) then
	fs.mkdirr("/etc/sing-box/")
	fs.writefile(config_path, "{}\n")
end

local error_box = m:field(DummyValue, "check_error", translate("Validation Output"))
error_box.rawhtml = true
function error_box.cfgvalue()
	local msg = fs.readfile(check_log)
	if not msg or msg == "" then
		return ""
	end
	return "<pre style=\"color:red; background:#fff1f0; padding:10px; border:1px solid #ffa39e;\">"
		.. util.pcdata(msg)
		.. "</pre>"
end

local cfg = m:field(TextValue, "config_json", translate("config.json"))
cfg.rows = 30
cfg.wrap = "off"
cfg.rmempty = false

function cfg.cfgvalue()
	return fs.readfile(config_path) or "{}\n"
end

function cfg.write(self, section, value)
	fs.mkdirr("/etc/sing-box/")
	fs.writefile(check_path, value)

	local cmd = string.format("/usr/bin/sing-box check -c %q >%q 2>&1", check_path, check_log)
	if sys.call(cmd) ~= 0 then
		return
	end

	fs.writefile(config_path, value)
	fs.writefile(check_log, "")
	m.message = translate("Configuration saved. You may restart sing-box now.")
end

local restart = m:field(Button, "restart", translate("Restart sing-box"))
restart.inputstyle = "apply"
restart.inputtitle = translate("Restart Now")
function restart.write()
	sys.call("/etc/init.d/sing-box restart >/dev/null 2>&1")
end

return m
