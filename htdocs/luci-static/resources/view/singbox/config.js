'use strict';
'require view';
'require fs';
'require ui';
'require uci';

/*
 * Config Editor — edits /etc/sing-box/config.json through the privileged
 * helper. Every save runs `sing-box check` first and keeps a timestamped
 * backup (restorable below).
 */

const HELPER = '/usr/libexec/singbox-admin';

function call() {
	const args = Array.prototype.slice.call(arguments);

	return fs.exec(HELPER, args).then(function(res) {
		let data = null;
		try { data = JSON.parse(res.stdout || '{}'); }
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

function fmtTime(t) {
	if (!t) return '-';
	return new Date(t * 1000).toLocaleString();
}

function fmtBytes(n) {
	n = Number(n) || 0;
	const u = ['B', 'KB', 'MB', 'GB'];
	let i = 0;
	while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
	return n.toFixed(i ? 1 : 0) + ' ' + u[i];
}

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	/* ==== SECTION: load ==== */

	load: function() {
		return Promise.all([call('config', 'read'), uci.load('singbox')]);
	},

	render: function(data) {
		const cfgData = data[0] || {};
		const content = cfgData.content || '{}\n';
		const wrapOn = uci.get('singbox', 'main', 'config_wrap') == '1';

		const container = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Config Editor')),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('File Metadata')),
				E('div', { 'style': 'padding:8px 10px;background:#f8f8f8;border:1px solid #e5e5e5' }, [
					E('div', {}, [ E('strong', {}, _('Path: ')), '/etc/sing-box/config.json' ]),
					E('div', {}, [ E('strong', {}, _('Last modified: ')),
						E('span', { 'id': 'sb-cfg-mtime' }, fmtTime(cfgData.mtime)) ])
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Editor')),
				E('label', { 'style': 'display:block;margin-bottom:4px' }, [
					E('input', { 'type': 'checkbox', 'id': 'sb-cfg-wrap', 'checked': wrapOn }),
					' ' + _('Auto wrap')
				]),
				E('textarea', {
					'id': 'sb-cfg-text',
					'rows': 30,
					'wrap': wrapOn ? 'soft' : 'off',
					'class': 'cbi-input-textarea',
					'style': 'width:100%;font-family:monospace;box-sizing:border-box'
				}, content),
				E('div', { 'style': 'margin-top:8px;display:flex;gap:8px' }, [
					E('button', { 'class': 'btn cbi-button cbi-button-apply', 'id': 'sb-cfg-save' }, _('Save & Validate')),
					E('button', { 'class': 'btn cbi-button cbi-button-reload', 'id': 'sb-cfg-restart' }, _('Restart sing-box'))
				]),
				E('div', { 'id': 'sb-cfg-msg', 'style': 'margin-top:8px;color:#666' })
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Backups')),
				E('div', { 'style': 'display:flex;gap:8px;flex-wrap:wrap;align-items:center' }, [
					E('select', { 'id': 'sb-cfg-backups', 'style': 'min-width:280px' }, E('option', { 'value': '' }, _('Loading…'))),
					E('button', { 'class': 'btn cbi-button cbi-button-reload', 'id': 'sb-cfg-restore' }, _('Restore selected'))
				]),
				E('div', { 'id': 'sb-cfg-bkmsg', 'style': 'margin-top:6px;color:#666' })
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Validation Output')),
				E('pre', { 'id': 'sb-cfg-err', 'style': 'color:red;background:#fff1f0;padding:10px;border:1px solid #ffa39e;min-height:20px' })
			])
		]);

		const text = container.querySelector('#sb-cfg-text');
		const msg = container.querySelector('#sb-cfg-msg');
		const errPre = container.querySelector('#sb-cfg-err');

		return this.bindEvents(container, text, msg, errPre);
	},

	/* ==== SECTION: events ==== */

	bindEvents: function(container, text, msg, errPre) {
		const bkSelect = container.querySelector('#sb-cfg-backups');
		const bkMsg = container.querySelector('#sb-cfg-bkmsg');

		const loadBackups = function() {
			return call('config', 'backups').then(function(res) {
				const items = res.backups || [];

				bkSelect.innerHTML = '';
				if (!items.length) {
					bkSelect.appendChild(E('option', { 'value': '' }, _('(no backups)')));
					return;
				}
				items.forEach(function(b) {
					bkSelect.appendChild(E('option', { 'value': b.name },
						'%s  (%s, %s)'.format(b.name, fmtTime(b.mtime), fmtBytes(b.size || 0))));
				});
			});
		};

		const save = function() {
			msg.style.color = '#666';
			msg.textContent = _('Validating…');

			fs.write('/tmp/sing-box-cfg.upload.json', text.value).then(function() {
				return call('config', 'save', '--from', '/tmp/sing-box-cfg.upload.json');
			}).then(function(res) {
				if (res.ok) {
					msg.style.color = 'green';
					msg.textContent = res.message;
					errPre.textContent = '';
					return loadBackups();
				}
				msg.style.color = 'red';
				msg.textContent = _('Configuration Check Failed!');
				errPre.textContent = (res.message || '').replace(/^Configuration Check Failed!/, '').trim();
			}).catch(function(e) {
				msg.style.color = 'red';
				msg.textContent = e.message;
			});
		};

		container.querySelector('#sb-cfg-save').addEventListener('click', save);

		container.querySelector('#sb-cfg-restart').addEventListener('click', function() {
			return call('service', 'restart').then(function(res) {
				msg.style.color = res.ok ? 'green' : 'red';
				msg.textContent = res.message;
			});
		});

		container.querySelector('#sb-cfg-restore').addEventListener('click', function() {
			const name = bkSelect.value;

			if (!name || !confirm(_('Restore %s? Your current config is snapshotted first, and the backup is validated before it replaces config.json.').format(name)))
				return;

			bkMsg.style.color = '#666';
			bkMsg.textContent = _('Restoring…');

			return call('config', 'restore', '--name', name).then(function(res) {
				bkMsg.style.color = res.ok ? 'green' : 'red';
				bkMsg.textContent = res.message;

				if (res.ok)
					return call('config', 'read').then(function(cd) {
						text.value = cd.content || '{}\n';
					});
			});
		});

		/* Tab inserts an indent instead of moving focus out of the editor. */
		text.addEventListener('keydown', function(ev) {
			if (ev.key !== 'Tab' || ev.ctrlKey || ev.altKey || ev.metaKey)
				return;
			ev.preventDefault();
			const pos = this.selectionStart;
			this.value = this.value.slice(0, pos) + '\t' + this.value.slice(this.selectionEnd);
			this.selectionStart = this.selectionEnd = pos + 1;
		});

		container.querySelector('#sb-cfg-wrap').addEventListener('change', function(ev) {
			text.wrap = ev.target.checked ? 'soft' : 'off';
			uci.set('singbox', 'main', 'config_wrap', ev.target.checked ? '1' : '0');
			return uci.save('singbox').then(function() { return uci.apply('singbox'); });
		});

		loadBackups();

		return container;
	}
});