local fs = require "nixio.fs"
local sys = require "luci.sys"
local util = require "luci.util"
local dsp = require "luci.dispatcher"
local jsonc = require "luci.jsonc"
local uci = require "luci.model.uci".cursor()

-- Read clash_api panel info straight from the config so the "Open External
-- Panel" button can be rendered on page load, instead of waiting for the 5s
-- runtime-status poll. Returns scheme/host/port and the /ui/ path (the API
-- root requires auth; the dashboard lives under /ui/).
local function read_clash_panel()
	local raw = fs.readfile("/etc/sing-box/config.json")
	if not raw then return nil end
	local data = jsonc.parse(raw)
	if type(data) ~= "table" then return nil end
	local ca = (data.experimental or {}).clash_api or {}
	local ec = ca.external_controller
	if type(ec) ~= "string" then return nil end
	ec = ec:gsub("^%s+", ""):gsub("%s+$", "")
	if ec == "" then return nil end
	local scheme = "http"
	if ec:match("^https?://") then
		scheme = ec:match("^(https?)://")
		ec = ec:gsub("^https?://", "")
	end
	local host, port
	if ec:match("^%[") then
		host, port = ec:match("^(%[.-%]):?(%d*)$")
	else
		host, port = ec:match("^(.-):(%d+)$")
		if not host then host, port = ec, "" end
	end
	if not port or port == "" then return nil end
	-- UCI override wins; else default to sing-box's fixed /ui/ when external_ui
	-- is configured. (external_ui is the local directory, not the URL path.)
	local ui_path = ""
	local override = uci:get("singbox", "main", "panel_path")
	if type(override) == "string" and override:gsub("%s", "") ~= "" then
		ui_path = override:gsub("^%s+", ""):gsub("%s+$", "")
		if ui_path:sub(1, 1) ~= "/" then ui_path = "/" .. ui_path end
		if ui_path:sub(-1) ~= "/" then ui_path = ui_path .. "/" end
	elseif type(ca.external_ui) == "string" and ca.external_ui:gsub("%s", "") ~= "" then
		ui_path = "/ui/"
	end
	return { scheme = scheme, host = host or "", port = port, ui_path = ui_path }
end

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
	return "<pre id='sb-full-version' style='max-height:260px;overflow:auto;margin:0;'>" .. util.pcdata(out) .. "</pre>"
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

-- Resource + multi-instance health. Answers "is sing-box actually the CPU hog,
-- and which of several sing-box processes is it?" -- the exact question that
-- is otherwise easy to get wrong (VSZ != CPU; container instances share the
-- host PID namespace).
local health = m:field(DummyValue, "health", translate("Resources & Instances"))
health.rawhtml = true
function health.cfgvalue()
	return [[
<div style="margin-bottom:6px;color:#666">
	<span><strong>conntrack:</strong> <span id="sb-conntrack">-</span></span>
	&nbsp;|&nbsp;
	<span><strong>clash connections:</strong> <span id="sb-clash-conn">-</span></span>
	&nbsp;|&nbsp;
	<span><strong>↓/↑ total:</strong> <span id="sb-clash-traffic">-</span></span>
</div>
<div style="max-height:280px;overflow-y:auto;">
	<table class="table cbi-section-table" style="width:100%;">
		<thead><tr>
			<th>PID</th><th>Role</th><th>UID</th><th>CPU%</th><th>RSS</th><th>Command</th>
		</tr></thead>
		<tbody id="sb-procs"><tr><td colspan="6">Loading...</td></tr></tbody>
	</table>
</div>
<div style="color:#999;font-size:90%;margin-top:4px;">
	"managed" = the procd-launched instance this dashboard controls. "container/other" rows are separate sing-box processes (e.g. inside LXC/VMs) that share the host PID list -- don't confuse their CPU with the managed one. CPU% is derived live between refreshes.
</div>]]
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
			<option value="custom">Custom/Manual</option>
		</select>
		<input id="sb-custom-arch" type="text" placeholder="e.g. x86_64, aarch64_cortex-a53" style="display:none;min-width:200px" />
	</div>
	<div style="margin:8px 0; display:flex; gap:8px; flex-wrap:wrap; align-items:center;">
		<label>%s</label>
		<input id="sb-url-input" type="text" placeholder="optional: direct .ipk or .tar.gz URL (leave blank to use version + arch)" style="min-width:420px;width:100%%;max-width:740px" />
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
	var archAuto = '';

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
			msg.textContent = (!arch && archSelect.value === 'auto')
				? 'Architecture not detected -- pick Custom/Manual and enter it (e.g. x86_64), or use a direct URL.'
				: 'Please provide URL or version + architecture.';
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
		archAuto = data.auto_arch || '';
		var online = document.getElementById('sb-online-version');
		online.textContent = data.latest ? data.latest : 'Unavailable';
		var archTip = document.getElementById('sb-arch-tip');
		archTip.textContent = (data.raw_arch || 'unknown') + ' -> ' + (archAuto || '(undetected)') + ' (' + (data.arch_source || 'auto') + ')';
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
	local p = read_clash_panel()
	if not p then
		-- No clash_api configured; nothing to link to.
		return [[<div id="sb-panel-wrap" style="display:none;"></div>]]
	end
	-- Render the button immediately and set its href on load (substituting the
	-- browser's hostname for wildcard bind addresses). No wait for the poll.
	return string.format([[
<div id="sb-panel-wrap" style="margin-bottom:8px;">
	<a id="sb-panel-link" class="btn cbi-button cbi-button-action" target="_blank" rel="noopener">%s</a>
</div>
<script>
(function(){
	var scheme=%q, host=%q, port=%q, uipath=%q;
	var wildcard={ '':1,'0.0.0.0':1,'127.0.0.1':1,'localhost':1,'::':1,'[::]':1,'::1':1,'[::1]':1 };
	if(wildcard[host]) host=window.location.hostname;
	if(host.indexOf(':')!==-1 && host.charAt(0)!=='[') host='['+host+']';
	var a=document.getElementById('sb-panel-link');
	if(a) a.href = scheme+'://'+host+':'+port+uipath;
})();
</script>]],
	translate("Open External Panel"),
	p.scheme, p.host, p.port, p.ui_path)
end

local runtime = m:field(DummyValue, "runtime_info", translate("Runtime Details"))
runtime.rawhtml = true
function runtime.cfgvalue()
	return [[
<div><strong>PID:</strong> <span id="sb-pid">-</span> <span style="color:#999">(see Resources &amp; Instances for all sing-box processes)</span></div>
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

local logs = m:field(DummyValue, "logs", translate("Logs"), translate("Output from logread -e sing-box (falls back to log.output file)"))
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
	local health_url = util.pcdata(app_url("health"))
	return [[
<script>
(function(){
	var statusUrl = ']] .. status_url .. [[';
	var healthUrl = ']] .. health_url .. [[';

	function esc(s) {
		return String(s == null ? '' : s)
			.replace(/&/g, '&amp;')
			.replace(/</g, '&lt;')
			.replace(/>/g, '&gt;')
			.replace(/"/g, '&quot;')
			.replace(/'/g, '&#39;');
	}

	function fmtBytes(n){
		n = Number(n)||0;
		var u=['B','KB','MB','GB','TB']; var i=0;
		while(n>=1024 && i<u.length-1){ n/=1024; i++; }
		return n.toFixed(i?1:0)+' '+u[i];
	}

	function buildPanelHref(data){
		if(!data || !data.panel_port) return '';
		var host = data.panel_host || '';
		var wildcard = { '': 1, '0.0.0.0': 1, '127.0.0.1': 1, 'localhost': 1, '::': 1, '[::]': 1, '::1': 1, '[::1]': 1 };
		if(wildcard[host]){
			host = window.location.hostname;
		}
		if(host.indexOf(':') !== -1 && host.charAt(0) !== '['){
			host = '[' + host + ']';
		}
		var scheme = data.panel_scheme || 'http';
		return scheme + '://' + host + ':' + data.panel_port + (data.panel_ui || '');
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
			var href = buildPanelHref(data);
			if(href){
				panelLink.href = href;
				panelWrap.style.display = '';
			} else {
				panelWrap.style.display = 'none';
			}
		}
	}

	// --- health: compute per-process CPU% from cumulative jiffies deltas ---
	var prev = {};   // pid -> { jiffies, now }
	function renderHealth(data){
		if(!data) return;
		var hz = data.hz || 100;
		var now = data.now || (Date.now()/1000);

		var ct = document.getElementById('sb-conntrack');
		if(ct) ct.textContent = (data.conntrack != null ? data.conntrack : '-');

		var cc = document.getElementById('sb-clash-conn');
		var ctr = document.getElementById('sb-clash-traffic');
		if(data.clash){
			if(cc) cc.textContent = data.clash.connections;
			if(ctr) ctr.textContent = fmtBytes(data.clash.download_total) + ' / ' + fmtBytes(data.clash.upload_total);
		} else {
			if(cc) cc.textContent = 'n/a';
			if(ctr) ctr.textContent = 'n/a';
		}

		var tb = document.getElementById('sb-procs');
		if(!tb) return;
		var rows = data.procs || [];
		if(!rows.length){ tb.innerHTML = '<tr><td colspan="6">No sing-box process found</td></tr>'; prev={}; return; }
		var seen = {};
		tb.innerHTML = rows.map(function(p){
			seen[p.pid] = 1;
			var cpu = '…';
			var pr = prev[p.pid];
			if(pr && now > pr.now){
				var pct = ((p.jiffies - pr.jiffies) / hz) / (now - pr.now) * 100;
				if(pct < 0) pct = 0;
				cpu = pct.toFixed(1) + '%';
			}
			prev[p.pid] = { jiffies: p.jiffies, now: now };
			var roleColor = p.role === 'managed' ? 'green' : '#999';
			return '<tr>'
				+ '<td>' + esc(p.pid) + '</td>'
				+ "<td style='color:" + roleColor + "'>" + esc(p.role) + '</td>'
				+ '<td>' + esc(p.uid) + '</td>'
				+ '<td>' + cpu + '</td>'
				+ '<td>' + Math.round((p.rss_kb||0)/1024) + ' MB</td>'
				+ "<td style='font-family:monospace;font-size:88%;word-break:break-all;'>" + esc(p.cmd) + '</td>'
				+ '</tr>';
		}).join('');
		Object.keys(prev).forEach(function(k){ if(!seen[k]) delete prev[k]; });
	}

	XHR.poll(5, statusUrl, null, function(x, data){
		if (x.status === 200) render(data);
	});
	XHR.poll(5, healthUrl, null, function(x, data){
		if (x.status === 200) renderHealth(data);
	});
})();
</script>]]
end

return m
