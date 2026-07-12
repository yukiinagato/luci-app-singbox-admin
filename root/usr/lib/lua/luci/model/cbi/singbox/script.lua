local fs = require "nixio.fs"
local sys = require "luci.sys"
local uci = require "luci.model.uci".cursor()
local util = require "luci.util"
local dsp = require "luci.dispatcher"

local script_path = "/etc/sing-box/nftables.sh"
local template_path = "/usr/share/singbox-admin/nftables.sh.example"

local function app_url(path)
	return dsp.build_url("admin", "services", "sing-box", path)
end

local m = SimpleForm("singbox_script", translate("Firewall Script"),
	translate("Edit /etc/sing-box/nftables.sh. This script is applied through a validated, rollback-protected executor -- what you save here can actually take effect (via the Apply button below, or on boot if enabled)."))
m.reset = false

local function ensure_script()
	-- Seed the live script from the shipped template on first use only; never
	-- overwrite an existing (possibly customized) file. Runtime-created files
	-- are also safe from opkg overwrites on upgrade.
	if not fs.access(script_path) then
		fs.mkdirr("/etc/sing-box/")
		local seed = fs.access(template_path) and fs.readfile(template_path) or nil
		if not seed or seed == "" then
			seed = "#!/bin/sh\n\n# Build your nft ruleset / policy routes here.\n# Make deletes idempotent, e.g.: nft delete table inet singbox 2>/dev/null\n"
		end
		fs.writefile(script_path, seed)
		sys.call(string.format("chmod +x %q", script_path))
	end
end
ensure_script()

-- Apply-on-boot toggle: enables/disables the plugin's firewall init service.
local boot = m:field(Flag, "fw_boot", translate("Apply firewall on boot"),
	translate("Enable the singbox-firewall service so this script is (re)applied at boot. Leave off if your sing-box init already loads its own nft ruleset."))
boot.rmempty = false
function boot.cfgvalue()
	return (sys.call("/etc/init.d/singbox-firewall enabled >/dev/null 2>&1") == 0) and "1" or "0"
end
function boot.write(self, section, value)
	if value == "1" then
		sys.call("/etc/init.d/singbox-firewall enable >/dev/null 2>&1")
	else
		sys.call("/etc/init.d/singbox-firewall disable >/dev/null 2>&1")
	end
	uci:set("singbox", "main", "fw_boot", value)
	uci:commit("singbox")
end

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
	local st = fs.stat(script_path)
	local mtime = (st and st.mtime) and os.date("%Y-%m-%d %H:%M:%S", st.mtime) or "-"
	local good = fs.access("/etc/sing-box/.nftables.good.sh")
	return "<div style='padding:8px 10px;background:#f8f8f8;border:1px solid #e5e5e5;'>"
		.. "<div><strong>Absolute Path:</strong> " .. util.pcdata(script_path) .. "</div>"
		.. "<div><strong>Last Modified:</strong> " .. util.pcdata(mtime) .. "</div>"
		.. "<div><strong>Rollback copy:</strong> " .. (good and "present (.nftables.good.sh)" or "none yet") .. "</div>"
		.. "</div>"
end

local script = m:field(TextValue, "nftables", translate("nftables.sh"))
script.rows = 25
script.rmempty = false

function script.cfgvalue()
	ensure_script()
	script.wrap = (uci:get("singbox", "main", "script_wrap") == "1") and "soft" or "off"
	return fs.readfile(script_path) or "#!/bin/sh\n\n"
end

function script.write(self, section, value)
	value = value:gsub("\r\n", "\n")
	fs.writefile(script_path, value)
	sys.call(string.format("chmod +x %q", script_path))
	m.message = translate("Saved. Use Validate / Apply below to check and load it.")
end

-- Buttons + live-state panel + JS glue.
local tools = m:field(DummyValue, "fw_tools", " ")
tools.rawhtml = true
function tools.cfgvalue()
	local state_url = util.pcdata(app_url("fw_state"))
	local validate_url = util.pcdata(app_url("fw_validate"))
	local apply_url = util.pcdata(app_url("fw_apply"))
	local save_url = util.pcdata(app_url("fw_save"))
	return string.format([[
<div style="margin:8px 0; display:flex; gap:8px; flex-wrap:wrap; align-items:center;">
	<button class="btn cbi-button" type="button" id="sb-fw-validate">%s</button>
	<button class="btn cbi-button cbi-button-apply" type="button" id="sb-fw-apply">%s</button>
	<span id="sb-fw-msg" style="color:#666">%s</span>
</div>
<details style="margin-top:6px;" open>
	<summary><strong>%s</strong></summary>
	<pre id="sb-fw-state" style="max-height:340px;overflow:auto;margin:6px 0;background:#0b0b0b;color:#d0d0d0;padding:10px;">Loading...</pre>
</details>
<script>
(function(){
	var stateUrl='%s', validateUrl='%s', applyUrl='%s', saveUrl='%s';
	var msg=document.getElementById('sb-fw-msg');
	function setMsg(t,c){ msg.textContent=t; msg.style.color=c||'#666'; }

	// The editor textarea (the only nftables TextValue on this page). Validate
	// and Apply act on the on-disk file, so we flush the editor to disk first --
	// otherwise unsaved edits are silently ignored and lost on the next refresh.
	function editor(){
		return document.querySelector('textarea[id*="nftables"]')
			|| document.querySelector('textarea');
	}

	function refreshState(){
		XHR.get(stateUrl,null,function(x,d){
			if(x.status===200&&d){
				var el=document.getElementById('sb-fw-state');
				if(el) el.textContent=d.output||'(empty)';
			}
		});
	}

	// Persist the editor content, then run next() on success.
	function saveThen(next){
		var ta=editor();
		if(!ta){ setMsg('Editor textarea not found; use the Save button below.','red'); return; }
		setMsg('Saving...','#666');
		XHR.post(saveUrl,{script:ta.value},function(x,d){
			if(x.status===200&&d&&d.ok){ next(); }
			else setMsg((d&&d.message)||'Save failed','red');
		});
	}

	document.getElementById('sb-fw-validate').addEventListener('click',function(){
		saveThen(function(){
			setMsg('Validating...','#666');
			XHR.get(validateUrl,null,function(x,d){
				if(x.status===200&&d){ setMsg(d.message||'', d.ok?'green':'red'); }
				else setMsg('Validation request failed','red');
			});
		});
	});

	document.getElementById('sb-fw-apply').addEventListener('click',function(){
		if(!confirm('Save the editor and apply the firewall script now? On failure it auto-rolls back to the last good version.')) return;
		saveThen(function(){
			setMsg('Applying...','#666');
			XHR.post(applyUrl,{},function(x,d){
				if(d){ setMsg(d.message||'', (x.status===200&&d.ok)?'green':'red'); }
				else setMsg('Apply request failed','red');
				refreshState();
			});
		});
	});

	refreshState();
	XHR.poll(10, stateUrl, null, function(x,d){
		if(x.status===200&&d){ var el=document.getElementById('sb-fw-state'); if(el) el.textContent=d.output||'(empty)'; }
	});
})();
</script>]],
	translate("Validate"),
	translate("Apply now"),
	translate("Validate / Apply now auto-save the editor first — the Save button is optional."),
	translate("Live firewall state (what is actually loaded)"),
	state_url, validate_url, apply_url, save_url)
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
