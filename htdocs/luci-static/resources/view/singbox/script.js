'use strict';
'require view';
'require fs';
'require ui';
'require poll';
'require uci';
'require singbox.common as sb';

/*
 * Firewall Script — edits /etc/sing-box/nftables.sh and applies it through
 * the validated, rollback-protected executor. Shared helpers live in
 * singbox/common.js.
 */

const call = L.bind(sb.call, sb);
const esc = sb.esc;

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	/* ==== SECTION: load ==== */

	load: function() {
		return Promise.all([call('fw', 'state'), uci.load('singbox')]);
	},

	render: function(data) {
		const state = data[0] || {};
		const wrapOn = uci.get('singbox', 'main', 'script_wrap') == '1';

		const container = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Firewall Script')),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Boot & Editor')),
				E('label', { 'style': 'display:block;margin-bottom:4px' }, [
					E('input', { 'type': 'checkbox', 'id': 'sb-fw-boot', 'checked': state.boot_enabled ? '' : null }),
					' ' + _('Apply firewall on boot (enables the singbox-firewall init service)')
				]),
				E('label', { 'style': 'display:block;margin-bottom:4px' }, [
					E('input', { 'type': 'checkbox', 'id': 'sb-fw-wrap', 'checked': wrapOn ? '' : null }),
					' ' + _('Auto wrap')
				]),
				E('textarea', {
					'id': 'sb-fw-text',
					'rows': 25,
					'wrap': wrapOn ? 'soft' : 'off',
					'class': 'cbi-input-textarea',
					'style': 'width:100%;font-family:monospace;box-sizing:border-box'
				}, _('Loading…')),
				E('div', { 'style': 'margin-top:8px;display:flex;gap:8px' }, [
					E('button', { 'class': 'btn cbi-button', 'id': 'sb-fw-validate' }, _('Validate')),
					E('button', { 'class': 'btn cbi-button cbi-button-apply', 'id': 'sb-fw-apply' }, _('Apply now')),
					E('button', { 'class': 'btn cbi-button cbi-button-reload', 'id': 'sb-fw-save' }, _('Save'))
				]),
				E('div', { 'id': 'sb-fw-msg', 'style': 'margin-top:8px;color:#666' })
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Live firewall state (what is actually loaded)')),
				E('pre', { 'id': 'sb-fw-state', 'style': 'max-height:340px;overflow:auto;margin:6px 0;background:#0b0b0b;color:#d0d0d0;padding:10px' },
					esc(state.output || '(empty)'))
			])
		]);

		return this.bindEvents(container);
	},

	/* ==== SECTION: events ==== */

	bindEvents: function(container) {
		const text = container.querySelector('#sb-fw-text');
		const msg = container.querySelector('#sb-fw-msg');
		const statePre = container.querySelector('#sb-fw-state');

		const setMsg = function(t, c) {
			msg.textContent = t;
			msg.style.color = c || '#666';
		};

		const refreshState = function() {
			return call('fw', 'state').then(function(res) {
				statePre.textContent = res.output || '(empty)';
			});
		};

		/* Stream editor content via cgi-io (sb.upload), avoiding the ubus
		 * message-size limit a plain fs.write would hit on large scripts. */
		const saveEditor = function() {
			return sb.upload('/tmp/sing-box-fw.upload.sh', text.value).catch(function(e) {
				return Promise.reject(new Error(
					_('Could not upload the script: ') + (e.message || e)));
			}).then(function() {
				return call('fw', 'save', '--from', '/tmp/sing-box-fw.upload.sh');
			});
		};

		const saveThen = function(next) {
			setMsg(_('Saving…'));
			return saveEditor().then(function(res) {
				if (res.ok) {
					setMsg(_('Saved.'));
					return next();
				}
				setMsg(res.message || _('Save failed'), 'red');
			}).catch(function(e) {
				setMsg(e.message, 'red');
			});
		};

		container.querySelector('#sb-fw-validate').addEventListener('click', function() {
			return saveThen(function() {
				setMsg(_('Validating…'));
				return call('fw', 'validate').then(function(res) {
					setMsg(res.message || '', res.ok ? 'green' : 'red');
				});
			});
		});

		container.querySelector('#sb-fw-apply').addEventListener('click', function() {
			if (!confirm(_('Save the editor and apply the firewall script now? On failure it auto-rolls back to the last good version.')))
				return;
			return saveThen(function() {
				setMsg(_('Applying…'));
				return call('fw', 'apply').then(function(res) {
					setMsg(res.message || '', res.ok ? 'green' : 'red');
					return refreshState();
				});
			});
		});

		container.querySelector('#sb-fw-save').addEventListener('click', function() {
			return saveThen(function() {
				setMsg(_('Saved. Use Validate / Apply to check and load it.'), 'green');
			});
		});

		container.querySelector('#sb-fw-boot').addEventListener('change', function(ev) {
			const on = ev.target.checked;

			return call('fw', on ? 'boot-on' : 'boot-off').then(function(res) {
				setMsg(res.message || '', res.ok ? 'green' : 'red');
			});
		});

		container.querySelector('#sb-fw-wrap').addEventListener('change', function(ev) {
			text.wrap = ev.target.checked ? 'soft' : 'off';
			uci.set('singbox', 'main', 'script_wrap', ev.target.checked ? '1' : '0');
			return uci.save('singbox').then(function() { return uci.apply('singbox'); });
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

		/* Load the script content (after fw ensure has seeded the template). */
		call('fw', 'ensure').then(function() {
			return fs.read('/etc/sing-box/nftables.sh');
		}).then(function(content) {
			text.value = content || '';
		}).catch(function(e) {
			setMsg(e.message, 'red');
		});

		refreshState();
		poll.add(L.bind(refreshState, this), 10);

		return container;
	}
});