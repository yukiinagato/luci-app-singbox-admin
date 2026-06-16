local fs = require "nixio.fs"
local sys = require "luci.sys"
local util = require "luci.util"
local uci = require "luci.model.uci".cursor()

local config_path = "/etc/sing-box/config.json"
local check_path = "/tmp/sing-box-config.check.json"
local check_log = "/tmp/sing-box-check.log"

local m = SimpleForm("singbox_config", translate("Config Editor"), translate("Edit /etc/sing-box/config.json with validation before saving."))
m.reset = false

if not fs.access(config_path) then
	fs.mkdirr("/etc/sing-box/")
	fs.writefile(config_path, "{}\n")
end

local wrap = m:field(Flag, "config_wrap", translate("Auto Wrap"), translate("Enable line wrapping in editor."))
wrap.rmempty = false
function wrap.cfgvalue()
	return uci:get("singbox", "main", "config_wrap") or "0"
end
function wrap.write(self, section, value)
	uci:set("singbox", "main", "config_wrap", value)
	uci:commit("singbox")
end

local meta = m:field(DummyValue, "file_meta", translate("File Metadata"))
meta.rawhtml = true
function meta.cfgvalue()
	local st = fs.stat(config_path)
	local mtime = (st and st.mtime) and os.date("%Y-%m-%d %H:%M:%S", st.mtime) or "-"
	return "<div style='padding:8px 10px;background:#f8f8f8;border:1px solid #e5e5e5;'>"
		.. "<div><strong>Absolute Path:</strong> " .. util.pcdata(config_path) .. "</div>"
		.. "<div><strong>Last Modified:</strong> " .. util.pcdata(mtime) .. "</div>"
		.. "</div>"
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
cfg.rmempty = false

function cfg.cfgvalue()
	cfg.wrap = (uci:get("singbox", "main", "config_wrap") == "1") and "soft" or "off"
	return fs.readfile(config_path) or "{}\n"
end

function cfg.write(self, section, value)
	-- Normalize CRLF that browsers may submit; sing-box check tolerates it
	-- but keeping the saved file LF-only avoids spurious diffs.
	value = value:gsub("\r\n", "\n")

	fs.mkdirr("/etc/sing-box/")
	fs.writefile(check_path, value)

	local cmd = string.format("/usr/bin/sing-box check -c %q >%q 2>&1", check_path, check_log)
	local rc = sys.call(cmd)
	fs.remove(check_path)

	if rc ~= 0 then
		self.error = { [section] = translate("Configuration Check Failed!") }
		return false
	end

	fs.writefile(config_path, value)
	fs.writefile(check_log, "")
	m.message = translate("Configuration saved.")
end

local restart = m:field(Button, "restart", translate("Restart sing-box"))
restart.inputstyle = "apply"
restart.inputtitle = translate("Restart Now")
function restart.write()
	sys.call("/etc/init.d/sing-box restart >/dev/null 2>&1")
end

local editor_js = m:field(DummyValue, "editor_js", " ")
editor_js.rawhtml = true
function editor_js.cfgvalue()
	return [[
<script>
(function(){
	// Make Tab insert an indent instead of moving focus out of the editor.
	function enableTab(ta){
		if(!ta || ta._sbTab) return;
		ta._sbTab = true;
		ta.style.fontFamily = 'monospace';
		ta.addEventListener('keydown', function(e){
			if(e.key !== 'Tab' || e.ctrlKey || e.altKey || e.metaKey) return;
			e.preventDefault();
			var s = this.selectionStart, en = this.selectionEnd, v = this.value;
			this.value = v.slice(0, s) + '\t' + v.slice(en);
			this.selectionStart = this.selectionEnd = s + 1;
		});
	}
	document.querySelectorAll('textarea').forEach(enableTab);
})();
</script>]]
end

return m
