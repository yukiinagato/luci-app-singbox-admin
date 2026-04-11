local fs = require "nixio.fs"
local sys = require "luci.sys"
local uci = require "luci.model.uci".cursor()
local util = require "luci.util"

local script_path = "/etc/sing-box/nftables.sh"

local m = SimpleForm("singbox_script", translate("Firewall Script"), translate("Edit /etc/sing-box/nftables.sh"))
m.reset = false

local wrap = m:field(Flag, "script_wrap", translate("Auto Wrap"), translate("Enable line wrapping in editor."))
wrap.rmempty = false
function wrap.cfgvalue()
	return uci:get("singbox", "main", "script_wrap") or "0"
end
function wrap.write(self, section, value)
	uci:set("singbox", "main", "script_wrap", value)
	uci:commit("singbox")
end

local meta = m:field(DummyValue, "file_meta", translate("File Metadata"))
meta.rawhtml = true
function meta.cfgvalue()
	if not fs.access(script_path) then
		fs.mkdirr("/etc/sing-box/")
		fs.writefile(script_path, "#!/bin/sh\n\n")
		sys.call(string.format("chmod +x %q", script_path))
	end

	local st = fs.stat(script_path)
	local mtime = (st and st.mtime) and os.date("%Y-%m-%d %H:%M:%S", st.mtime) or "-"
	return "<div style='padding:8px 10px;background:#f8f8f8;border:1px solid #e5e5e5;'>"
		.. "<div><strong>Absolute Path:</strong> " .. util.pcdata(script_path) .. "</div>"
		.. "<div><strong>Last Modified:</strong> " .. util.pcdata(mtime) .. "</div>"
		.. "</div>"
end

local script = m:field(TextValue, "nftables", translate("nftables.sh"))
script.rows = 25
script.rmempty = false

function script.cfgvalue()
	if not fs.access(script_path) then
		fs.mkdirr("/etc/sing-box/")
		fs.writefile(script_path, "#!/bin/sh\n\n")
		sys.call(string.format("chmod +x %q", script_path))
	end
	script.wrap = (uci:get("singbox", "main", "script_wrap") == "1") and "soft" or "off"
	return fs.readfile(script_path) or "#!/bin/sh\n\n"
end

function script.write(self, section, value)
	fs.writefile(script_path, value)
	sys.call(string.format("chmod +x %q", script_path))
end

return m
