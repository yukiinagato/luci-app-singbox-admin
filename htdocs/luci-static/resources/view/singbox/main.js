'use strict';
'require view';
'require fs';
'require ui';
'require poll';
'require uci';

/*
 * sing-box Dashboard — modern LuCI JS view.
 *
 * All privileged operations go through the ACL-guarded helper
 * /usr/libexec/singbox-admin (rpcd file.exec); see
 * root/usr/libexec/singbox-admin for the JSON contract.
 */

const HELPER = '/usr/libexec/singbox-admin';

function call() {
	const args = Array.prototype.slice.call(arguments);

	return fs.exec(HELPER, args).then(function(res) {
		let data = null;

		try {
			data = JSON.parse(res.stdout || '{}');
		}
		catch (e) {}

		if (data == null)
			return Promise.reject(new Error(_('Helper returned invalid data')));

		return data;
	});
}

function esc(s) {
	return String(s == null ? '' : s)
		.replace(/&/g, '&amp;')
		.replace(/</g, '&lt;')
		.replace(/>/g, '&gt;')
		.replace(/"/g, '&quot;')
		.replace(/'/g, '&#39;');
}

function fmtBytes(n) {
	n = Number(n) || 0;
	const u = ['B', 'KB', 'MB', 'GB', 'TB'];
	let i = 0;
	while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
	return n.toFixed(i ? 1 : 0) + ' ' + u[i];
}

function buildPanelHref(d) {
	if (!d.panel_port)
		return '';

	let host = d.panel_host || '';
	const wildcard = { '': 1, '0.0.0.0': 1, '127.0.0.1': 1, 'localhost': 1, '::': 1, '[::]': 1 };

	if (wildcard[host])
		host = window.location.hostname;

	if (host.indexOf(':') !== -1 && host.charAt(0) !== '[')
		host = '[' + host + ']';

	return '%s://%s:%s%s'.format(d.panel_scheme || 'http', host, d.panel_port, d.panel_ui || '');
}

const prevJiffies = {};

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	handleServiceAction: function(action, ev) {
		return call('service', action).then(function(data) {
			ui.addNotification(null, E('p', data.message || _('Done.')), data.ok ? 'info' : 'error');
			return this.refreshStatus();
		}.bind(this)).catch(function(e) {
			ui.addNotification(null, E('p', e.message), 'error');
		});
	},

	refreshStatus: function() {
		return call('status').then(function(data) {
			const el = document.getElementById('sb-service-status');

			if (el) {
				const run = data.running ?
					'<span style="color:green;font-weight:bold">Running</span>' :
					'<span style="color:red;font-weight:bold">Stopped</span>';
				const en = data.enabled ?
					'<span style="color:green">Enabled</span>' :
					'<span style="color:#999">Disabled</span>';
				el.innerHTML = run + '<br />Boot: ' + en;
			}

			const ver = document.getElementById('sb-version');

			if (ver && data.version_output && data.version_output != 'unknown')
				ver.textContent = data.version_output;

			const pid = document.getElementById('sb-pid');

			if (pid)
				pid.textContent = data.pid || '-';

			const tbody = document.getElementById('sb-listeners');

			if (tbody) {
				const rows = data.listeners || [];

				tbody.innerHTML = rows.length ?
					rows.map(function(r) {
						return '<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>'.format(
							esc(r.proto), esc(r.address), esc(r.port), esc(r.proc));
					}).join('') :
					'<tr><td colspan="4">No listening sockets</td></tr>';
			}

			const logEl = document.getElementById('sb-logs');

			if (logEl) {
				logEl.textContent = data.logs || _('No logs.');
				logEl.scrollTop = logEl.scrollHeight;
			}

			const link = document.getElementById('sb-panel-link');
			const wrap = document.getElementById('sb-panel-wrap');
			const href = buildPanelHref(data);

			if (link && wrap) {
				link.href = href;
				wrap.style.display = href ? '' : 'none';
			}
		});
	},
	/* ==== SECTION: procs ==== */

	renderProcs: function(data) {
		const tbody = document.getElementById('sb-procs');

		if (!tbody)
			return;

		const hz = data.hz || 100;
		const now = data.now || (Date.now() / 1000);
		const rows = data.procs || [];
		const seen = {};

		tbody.innerHTML = rows.length ?
			rows.map(function(p) {
				seen[p.pid] = 1;
				let cpu = '…';
				const pr = prevJiffies[p.pid];

				if (pr && now > pr.now) {
					const pct = ((p.jiffies - pr.jiffies) / hz) / (now - pr.now) * 100;
					cpu = (pct < 0 ? 0 : pct).toFixed(1) + '%';
				}

				prevJiffies[p.pid] = { jiffies: p.jiffies, now: now };
				const color = p.role === 'managed' ? 'green' : '#999';

				return '<tr><td>%s</td><td style="color:%s">%s</td><td>%s</td><td>%s</td><td>%s</td><td style="font-family:monospace;font-size:88%%;word-break:break-all">%s</td></tr>'.format(
					esc(p.pid), color, esc(p.role), esc(p.uid), cpu,
					fmtBytes((p.rss_kb || 0) * 1024), esc(p.cmd));
			}).join('') :
			'<tr><td colspan="6">No sing-box process found</td></tr>';

		Object.keys(prevJiffies).forEach(function(k) {
			if (!seen[k]) delete prevJiffies[k];
		});

		const ct = document.getElementById('sb-conntrack');

		if (ct)
			ct.textContent = (data.conntrack != null) ? data.conntrack : '-';

		const cc = document.getElementById('sb-clash-conn');
		const tr = document.getElementById('sb-clash-traffic');

		if (data.clash) {
			if (cc) cc.textContent = data.clash.connections;
			if (tr) tr.textContent = fmtBytes(data.clash.download_total) + ' / ' + fmtBytes(data.clash.upload_total);
		}
		else {
			if (cc) cc.textContent = 'n/a';
			if (tr) tr.textContent = 'n/a';
		}
	},

	refreshHealth: function() {
		return call('health').then(this.renderProcs);
	},

	handleUpdate: function(ev) {
		const version = document.getElementById('sb-version-input').value.trim();
		const archSel = document.getElementById('sb-arch-select').value;
		const customArch = document.getElementById('sb-custom-arch').value.trim();
		const url = document.getElementById('sb-url-input').value.trim();
		const msg = document.getElementById('sb-update-msg');
		const arch = (archSel === 'custom') ? customArch : archSel;

		if (!url && (!version || !arch)) {
			msg.style.color = 'red';
			msg.textContent = _('Provide a version and architecture, or a URL.');
			return;
		}

		if (!confirm(_('Download and install the selected sing-box build? The service will be restarted if running.')))
			return;

		msg.style.color = '#666';
		msg.textContent = _('Starting update…');

		const args = url ? ['--url', url] : ['--version', version, '--arch', arch];

		call.apply(null, ['update-start'].concat(args)).then(function(data) {
			if (!data.ok) {
				msg.style.color = 'red';
				msg.textContent = data.message;
				return null;
			}

			msg.textContent = _('Downloading… this may take a while.');

			const pollOnce = function() {
				return call('update-status').then(function(st) {
					if (st.log)
						msg.textContent = st.log;

					if (st.running)
						return new Promise(function(resolve) { setTimeout(resolve, 2000); }).then(pollOnce);

					msg.style.color = /success/i.test(st.log || '') ? 'green' : 'red';
					msg.textContent = st.log || _('Update finished.');

					return this.refreshStatus();
				}.bind(this));
			}.bind(this);

			return pollOnce();
		}.bind(this)).catch(function(e) {
			msg.style.color = 'red';
			msg.textContent = e.message;
		});
	},
	/* ==== SECTION: render ==== */

	load: function() {
		return call('update-info');
	},

	render: function(updateInfo) {
		updateInfo = updateInfo || {};
		const autoArch = updateInfo.auto_arch || '';
		const onlineVer = updateInfo.latest || _('(unavailable)');
		const curFirst = (updateInfo.version_output || 'unknown').split('\n')[0];

		const container = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Sing-box Dashboard')),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Service')),
				E('div', { 'id': 'sb-service-status' }, _('Loading…')),
				E('div', { 'style': 'margin-top:8px;display:flex;gap:8px' }, [
					E('button', { 'class': 'btn cbi-button cbi-button-apply',
						'click': ui.createHandlerFn(this, 'handleServiceAction', 'start') }, _('Start')),
					E('button', { 'class': 'btn cbi-button cbi-button-remove',
						'click': ui.createHandlerFn(this, 'handleServiceAction', 'stop') }, _('Stop')),
					E('button', { 'class': 'btn cbi-button cbi-button-reload',
						'click': ui.createHandlerFn(this, 'handleServiceAction', 'restart') }, _('Restart'))
				]),
				E('div', { 'style': 'margin-top:6px' }, [
					E('strong', {}, 'PID: '),
					E('span', { 'id': 'sb-pid' }, '-')
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Version')),
				E('pre', { 'id': 'sb-version', 'style': 'max-height:180px;overflow:auto;margin:0' }, curFirst + '\n' + (updateInfo.version_output || ''))
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Resources & Instances')),
				E('div', { 'style': 'margin-bottom:6px;color:#666' }, [
					E('span', {}, 'conntrack: '), E('span', { 'id': 'sb-conntrack' }, '-'),
					E('span', {}, ' | clash connections: '), E('span', { 'id': 'sb-clash-conn' }, '-'),
					E('span', {}, ' | ↓/↑ total: '), E('span', { 'id': 'sb-clash-traffic' }, '-')
				]),
				E('div', { 'style': 'max-height:280px;overflow-y:auto' },
					E('table', { 'class': 'table cbi-section-table', 'style': 'width:100%' }, [
						E('thead', {}, E('tr', {}, [
							E('th', {}, 'PID'), E('th', {}, _('Role')), E('th', {}, 'UID'),
							E('th', {}, 'CPU%'), E('th', {}, 'RSS'), E('th', {}, _('Command'))
						])),
						E('tbody', { 'id': 'sb-procs' },
							E('tr', {}, E('td', { 'colspan': 6 }, _('Loading…'))))
					])),
				E('div', { 'style': 'color:#999;font-size:90%;margin-top:4px' },
					_('managed = the procd-launched instance this dashboard controls. Other rows are separate sing-box processes (e.g. inside LXC/VMs sharing the host PID namespace). CPU% is derived between refreshes.'))
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Binary & Platform Management')),
				E('div', {}, [ _('Latest release: '), E('span', { 'id': 'sb-online-version' }, onlineVer) ]),
				E('div', {}, [ _('Detected architecture: '),
					E('span', { 'id': 'sb-arch-tip' }, autoArch || _('unknown')) ]),
				E('div', { 'style': 'margin:8px 0;display:flex;gap:8px;flex-wrap:wrap;align-items:center' }, [
					E('label', { 'for': 'sb-version-input' }, _('Version')),
					E('input', { 'id': 'sb-version-input', 'type': 'text', 'placeholder': '1.13.19', 'style': 'min-width:120px' }),
					E('label', { 'for': 'sb-arch-select' }, _('Architecture')),
					E('select', { 'id': 'sb-arch-select', 'style': 'min-width:170px' }, [
						autoArch ? E('option', { 'value': autoArch }, '%s (%s)'.format(autoArch, _('auto-detected'))) : E('option', { 'value': '' }, _('Auto Detect')),
						E('option', { 'value': 'custom' }, _('Custom/Manual'))
					]),
					E('input', { 'id': 'sb-custom-arch', 'type': 'text', 'placeholder': 'e.g. aarch64_cortex-a53', 'style': 'display:none;min-width:200px' })
				]),
				E('div', { 'style': 'margin:8px 0' }, [
					E('label', { 'for': 'sb-url-input' }, _('URL')),
					E('br'),
					E('input', { 'id': 'sb-url-input', 'type': 'text', 'placeholder': _('optional: direct .ipk/.apk/.tar.gz URL'), 'style': 'width:100%;max-width:740px' })
				]),
				E('div', { 'style': 'margin:8px 0' },
					E('button', { 'class': 'btn cbi-button cbi-button-apply', 'id': 'sb-update-btn',
						'click': ui.createHandlerFn(this, 'handleUpdate') }, _('Update now'))),
				E('div', { 'id': 'sb-update-msg', 'style': 'color:#666' })
			]),

			E('div', { 'class': 'cbi-section', 'id': 'sb-panel-wrap', 'style': 'display:none' }, [
				E('h3', {}, _('External Panel')),
				E('a', { 'id': 'sb-panel-link', 'target': '_blank', 'rel': 'noopener' }, _('Open External Panel'))
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('details', {}, [
					E('summary', {}, E('strong', {}, _('Active Ports'))),
					E('table', { 'class': 'table cbi-section-table', 'style': 'width:100%;margin-top:6px' }, [
						E('thead', {}, E('tr', {}, [
							E('th', {}, _('Proto')), E('th', {}, _('Address')),
							E('th', {}, _('Port')), E('th', {}, _('Process'))
						])),
						E('tbody', { 'id': 'sb-listeners' },
							E('tr', {}, E('td', { 'colspan': 4 }, _('Loading…'))))
					])
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Logs')),
				E('pre', { 'id': 'sb-logs', 'style': 'max-height:320px;overflow:auto;margin:0' }, _('Loading…'))
			])
		]);

		const archSel = container.querySelector('#sb-arch-select');
		const customIn = container.querySelector('#sb-custom-arch');

		archSel.addEventListener('change', function() {
			customIn.style.display = (archSel.value === 'custom') ? '' : 'none';
		});

		poll.add(L.bind(this.refreshStatus, this), 5);
		poll.add(L.bind(this.refreshHealth, this), 5);

		return container;
	}
});
