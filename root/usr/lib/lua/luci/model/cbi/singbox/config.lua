local fs = require "nixio.fs"
local sys = require "luci.sys"
local util = require "luci.util"
local dsp = require "luci.dispatcher"
local uci = require "luci.model.uci".cursor()

local config_path = "/etc/sing-box/config.json"
local check_path = "/tmp/sing-box-config.check.json"
local check_log = "/tmp/sing-box-check.log"
local backup_dir = "/etc/sing-box/backups"

local function app_url(path)
	return dsp.build_url("admin", "services", "sing-box", path)
end

local m = SimpleForm("singbox_config", translate("Config Editor"), translate("Edit /etc/sing-box/config.json with validation before saving. Every save keeps a timestamped backup you can restore."))
m.reset = false

if not fs.access(config_path) then
	fs.mkdirr("/etc/sing-box/")
	fs.writefile(config_path, "{}\n")
end

-- Prune backups to the newest `keep` copies.
local function prune_backups(keep)
	keep = tonumber(keep) or 10
	local items = {}
	if fs.access(backup_dir) then
		for name in fs.dir(backup_dir) do
			if name:match("^config%..*%.json$") then
				local st = fs.stat(backup_dir .. "/" .. name)
				items[#items + 1] = { name = name, mtime = st and st.mtime or 0 }
			end
		end
	end
	table.sort(items, function(a, b) return a.mtime > b.mtime end)
	for i = keep + 1, #items do
		fs.remove(backup_dir .. "/" .. items[i].name)
	end
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
	local html = "<div style='padding:8px 10px;background:#f8f8f8;border:1px solid #e5e5e5;'>"
		.. "<div><strong>Absolute Path:</strong> " .. util.pcdata(config_path) .. "</div>"
		.. "<div><strong>Last Modified:</strong> " .. util.pcdata(mtime) .. "</div>"
	-- Warn about stray editor swap files (a common source of confusion).
	for name in fs.dir("/etc/sing-box") do
		if name:match("%.swp$") or name:match("%.swo$") then
			html = html .. "<div style='color:#a8071a'><strong>Warning:</strong> stray editor swap file /etc/sing-box/" .. util.pcdata(name) .. " -- an external editor may be open or crashed; remove it to avoid confusion.</div>"
		end
	end
	return html .. "</div>"
end

-- Restore-from-backup control.
local restore = m:field(DummyValue, "restore_box", translate("Backups"))
restore.rawhtml = true
function restore.cfgvalue()
	local list_url = util.pcdata(app_url("config_backups"))
	local restore_url = util.pcdata(app_url("config_restore"))
	return string.format([[
<div style="display:flex; gap:8px; flex-wrap:wrap; align-items:center;">
	<select id="sb-bk-select" style="min-width:280px"><option value="">Loading backups...</option></select>
	<button class="btn cbi-button cbi-button-reload" type="button" id="sb-bk-restore">%s</button>
	<span id="sb-bk-msg" style="color:#666"></span>
</div>
<script>
(function(){
	var listUrl='%s', restoreUrl='%s';
	var sel=document.getElementById('sb-bk-select');
	var msg=document.getElementById('sb-bk-msg');
	function load(){
		XHR.get(listUrl,null,function(x,d){
			if(x.status!==200||!d||!d.backups){ sel.innerHTML='<option value="">(none)</option>'; return; }
			if(!d.backups.length){ sel.innerHTML='<option value="">(no backups yet)</option>'; return; }
			sel.innerHTML=d.backups.map(function(b){
				var t=b.mtime?new Date(b.mtime*1000).toLocaleString():'';
				return '<option value="'+b.name+'">'+b.name+'  ('+t+')</option>';
			}).join('');
		});
	}
	document.getElementById('sb-bk-restore').addEventListener('click',function(){
		var name=sel.value; if(!name){ return; }
		if(!confirm('Restore '+name+'? Your current config is snapshotted first, and the backup is validated before it replaces config.json.')) return;
		msg.style.color='#666'; msg.textContent='Restoring...';
		XHR.post(restoreUrl,{name:name},function(x,d){
			if(d){ msg.style.color=(x.status===200&&d.ok)?'green':'red'; msg.textContent=d.message||''; }
			else { msg.style.color='red'; msg.textContent='Restore failed'; }
		});
	});
	load();
})();
</script>]],
	translate("Restore selected"),
	list_url, restore_url)
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

	-- Snapshot the CURRENT config before overwriting, so a valid-but-wrong
	-- edit can still be undone.
	local cur = fs.readfile(config_path)
	if cur and cur ~= value then
		fs.mkdirr(backup_dir)
		fs.writefile(string.format("%s/config.%s.json", backup_dir, os.date("%Y%m%d%H%M%S")), cur)
		prune_backups(uci:get("singbox", "main", "backup_keep") or 10)
	end

	fs.writefile(config_path, value)
	fs.writefile(check_log, "")
	m.message = translate("Configuration saved (previous version backed up).")
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
