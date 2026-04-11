local fs = require "nixio.fs"
local sys = require "luci.sys"
local util = require "luci.util"
local dsp = require "luci.dispatcher"

local m = SimpleForm("singbox", translate("sing-box Dashboard"), translate("Manage sing-box runtime status and resources."))
m.reset = false
m.submit = false

local function app_url(path)
	return dsp.build_url("admin", "services", "sing-box", path)
end

local status_text = m:field(DummyValue, "service_state", translate("Service Status"))
status_text.rawhtml = true
function status_text.cfgvalue()
	local running = (sys.call("/etc/init.d/sing-box status >/dev/null 2>&1") == 0)
	local enabled = (sys.call("/etc/init.d/sing-box enabled >/dev/null 2>&1") == 0)
	local s1 = running and "<span style='color:green;font-weight:bold'>Running</span>" or "<span style='color:red;font-weight:bold'>Stopped</span>"
	local s2 = enabled and "<span style='color:green'>Enabled</span>" or "<span style='color:#999'>Disabled</span>"
	return string.format("<span id='sb-service-status'>%s<br />Boot: %s</span>", s1, s2)
end

local full_ver = m:field(DummyValue, "full_version", translate("sing-box Version Output"))
full_ver.rawhtml = true
function full_ver.cfgvalue()
	local out = sys.exec("/usr/bin/sing-box version 2>&1")
	if not out or out == "" then
		out = "unknown"
	end
	return "<pre style='max-height:260px;overflow:auto;margin:0;'>" .. util.pcdata(out) .. "</pre>"
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

local updater = m:field(DummyValue, "updater", translate("Binary & Platform Management"))
updater.rawhtml = true
function updater.cfgvalue()
	local info_url = util.pcdata(app_url("update_info"))
	local update_url = util.pcdata(app_url("update_download"))
	return string.format([[ 
<div>
	<div><strong>%s:</strong> <span id="sb-online-version">Loading...</span></div>
	<div><strong>%s:</strong> <span id="sb-arch-tip">Detecting...</span></div>
	<div style="margin:8px 0; display:flex; gap:8px; flex-wrap:wrap; align-items:center;">
		<label>%s</label>
		<input id="sb-version-input" type="text" placeholder="1.13.0" style="min-width:120px" />
		<label>%s</label>
		<select id="sb-arch-select">
			<option value="auto">Auto Detect (Recommended)</option>
			<option value="amd64">amd64</option>
			<option value="arm64">arm64</option>
			<option value="armv7">armv7</option>
			<option value="armv6">armv6</option>
			<option value="armv5">armv5</option>
			<option value="386">386</option>
			<option value="mips">mips</option>
			<option value="mips64">mips64</option>
			<option value="mipsle">mipsle</option>
			<option value="mips64le">mips64le</option>
			<option value="riscv64">riscv64</option>
			<option value="s390x">s390x</option>
			<option value="loong64">loong64</option>
			<option value="custom">Custom/Manual</option>
		</select>
		<input id="sb-custom-arch" type="text" placeholder="custom platform" style="display:none;min-width:150px" />
	</div>
	<div style="margin:8px 0; display:flex; gap:8px; flex-wrap:wrap; align-items:center;">
		<label>%s</label>
		<input id="sb-url-input" type="text" placeholder="https://.../sing-box-x.y.z-linux-amd64.tar.gz" style="min-width:420px;width:100%%;max-width:740px" />
	</div>
	<div style="margin:8px 0;">
		<button class="btn cbi-button cbi-button-apply" type="button" id="sb-update-btn">%s</button>
	</div>
	<div id="sb-update-msg" style="color:#666"></div>
</div>
<script>
(function(){
	var infoUrl = '%s';
	var updateUrl = '%s';
	var archAuto = 'amd64';

	var versionInput = document.getElementById('sb-version-input');
	var archSelect = document.getElementById('sb-arch-select');
	var customArch = document.getElementById('sb-custom-arch');
	var urlInput = document.getElementById('sb-url-input');
	var msg = document.getElementById('sb-update-msg');

	function syncCustomArch(){
		customArch.style.display = (archSelect.value === 'custom') ? '' : 'none';
	}

	function postUpdate(){
		var version = (versionInput.value || '').trim();
		var custom = (customArch.value || '').trim();
		var directUrl = (urlInput.value || '').trim();
		var arch = archSelect.value === 'auto' ? archAuto : archSelect.value;
		if (archSelect.value === 'custom') arch = custom;

		if (!directUrl && (!version || !arch)) {
			msg.style.color = 'red';
			msg.textContent = 'Please provide URL or version + architecture.';
			return;
		}

		msg.style.color = '#666';
		msg.textContent = 'Downloading...';
		XHR.post(updateUrl, { version: version, arch: arch, url: directUrl }, function(x, data){
			if (x.status === 200 && data && data.ok) {
				msg.style.color = 'green';
				msg.textContent = data.message;
				var verNode = document.getElementById('sb-full-version');
				if (verNode && data.version_output) verNode.textContent = data.version_output;
			} else {
				msg.style.color = 'red';
				msg.textContent = (data && data.message) ? data.message : 'Update failed';
			}
		});
	}

	XHR.get(infoUrl, null, function(x, data){
		if (x.status !== 200 || !data) return;
		archAuto = data.auto_arch || 'amd64';
		var online = document.getElementById('sb-online-version');
		online.textContent = data.latest ? data.latest : 'Unavailable';
		var archTip = document.getElementById('sb-arch-tip');
		archTip.textContent = (data.raw_arch || 'unknown') + ' -> ' + archAuto + ' (' + (data.arch_source || 'auto') + ')';
		if (data.latest) {
			versionInput.value = data.latest;
		}
		if (data.version_output) {
			var verNode = document.getElementById('sb-full-version');
			if (verNode) verNode.textContent = data.version_output;
		}
	});

	archSelect.addEventListener('change', syncCustomArch);
	document.getElementById('sb-update-btn').addEventListener('click', postUpdate);
	syncCustomArch();
})();
</script>]],
	translate("Latest Version"),
	translate("Detected Platform"),
	translate("Version"),
	translate("Platform/Architecture"),
	translate("Binary Download URL"),
	translate("Download & Replace"),
	info_url,
	update_url)
end

local panel = m:field(DummyValue, "external_panel", translate("External Panel"))
panel.rawhtml = true
function panel.cfgvalue()
	return [[<div id="sb-panel-wrap" style="display:none;margin-bottom:8px;">
		<a id="sb-panel-link" class="btn cbi-button cbi-button-action" target="_blank" rel="noopener">]] ..
		translate("Open External Panel") .. [[</a>
	</div>]]
end

local runtime = m:field(DummyValue, "runtime_info", translate("Runtime Details"))
runtime.rawhtml = true
function runtime.cfgvalue()
	return [[
<div><strong>PID:</strong> <span id="sb-pid">-</span></div>
<details id="sb-ports-box" style="margin-top:6px;">
	<summary><strong>sing-box Active Ports</strong></summary>
	<div style="max-height:260px;overflow-y:auto;margin-top:6px;">
		<table class="table cbi-section-table" style="width:100%;">
			<thead>
				<tr><th>Proto</th><th>Local Address</th><th>Port</th><th>Process</th></tr>
			</thead>
			<tbody id="sb-listeners"><tr><td colspan="4">Loading...</td></tr></tbody>
		</table>
	</div>
</details>]]
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

local logs = m:field(DummyValue, "logs", translate("Logs"), translate("Output from logread -e sing-box"))
logs.rawhtml = true
function logs.cfgvalue()
	return [[<pre id="sb-logs" style="max-height:320px;overflow:auto;margin:0;">Loading...</pre>]]
end

local clearlog = m:field(Button, "clear_logs", translate("Clear Logs"))
clearlog.inputstyle = "remove"
function clearlog.write()
	sys.call("logclear >/dev/null 2>&1 || true")
end

local js = m:field(DummyValue, "dashboard_js", " ")
js.rawhtml = true
function js.cfgvalue()
	local status_url = util.pcdata(app_url("runtime_status"))
	return [[
<script>
(function(){
	var statusUrl = ']] .. status_url .. [[';

	function esc(s) {
		return String(s == null ? '' : s)
			.replace(/&/g, '&amp;')
			.replace(/</g, '&lt;')
			.replace(/>/g, '&gt;')
			.replace(/"/g, '&quot;')
			.replace(/'/g, '&#39;');
	}

	function render(data){
		if(!data) return;
		var status = document.getElementById('sb-service-status');
		if(status){
			var run = data.running ? "<span style='color:green;font-weight:bold'>Running</span>" : "<span style='color:red;font-weight:bold'>Stopped</span>";
			var en = data.enabled ? "<span style='color:green'>Enabled</span>" : "<span style='color:#999'>Disabled</span>";
			status.innerHTML = run + "<br />Boot: " + en;
		}

		var pid = document.getElementById('sb-pid');
		if(pid) pid.textContent = data.pid || '-';

		var tbody = document.getElementById('sb-listeners');
		if(tbody){
			var rows = data.listeners || [];
			if(!rows.length){
				tbody.innerHTML = '<tr><td colspan="4">No listening sockets</td></tr>';
			} else {
				tbody.innerHTML = rows.map(function(r){
					return '<tr><td>' + esc(r.proto || '-') + '</td><td>' + esc(r.address || '-') + '</td><td>' + esc(r.port || '-') + '</td><td>' + esc(r.proc || '-') + '</td></tr>';
				}).join('');
			}
		}

		var logEl = document.getElementById('sb-logs');
		if(logEl){
			logEl.textContent = data.logs || 'No sing-box logs found.';
			logEl.scrollTop = logEl.scrollHeight;
		}

		var panelWrap = document.getElementById('sb-panel-wrap');
		var panelLink = document.getElementById('sb-panel-link');
		if(panelWrap && panelLink){
			if(data.panel_url){
				panelLink.href = data.panel_url;
				panelWrap.style.display = '';
			} else {
				panelWrap.style.display = 'none';
			}
		}
	}

	XHR.poll(5, statusUrl, null, function(x, data){
		if (x.status === 200) render(data);
	});
})();
</script>]]
end

return m
