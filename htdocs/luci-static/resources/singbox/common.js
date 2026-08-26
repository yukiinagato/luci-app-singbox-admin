'use strict';
'require baseclass';
'require fs';
'require rpc';
'require request';
'require ui';

/*
 * Shared helpers for the sing-box admin views. Loaded via
 * 'require singbox.common as sb'. Keeping this in one place avoids the
 * call()/esc()/fmtBytes() copies drifting between main/config/script.
 */

const HELPER = '/usr/libexec/singbox-admin';

return baseclass.extend({
	HELPER: HELPER,

	/* Invoke the privileged helper (rpcd file.exec) and parse its JSON. */
	call: function() {
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
	},

	/* HTML-escape for the few places that build markup strings for innerHTML
	 * (E() table rows). Prefer textContent / E() children elsewhere. */
	esc: function(s) {
		return String(s == null ? '' : s)
			.replace(/&/g, '&amp;')
			.replace(/</g, '&lt;')
			.replace(/>/g, '&gt;')
			.replace(/"/g, '&quot;')
			.replace(/'/g, '&#39;');
	},

	/* In-page confirmation dialog. Returns a Promise resolving to true/false.
	 * Replaces window.confirm(), which some browsers/webviews suppress (a
	 * dialog dismissed with "prevent additional dialogs" makes every later
	 * confirm() silently return false -- the button then looks dead). */
	confirm: function(title, message, okLabel) {
		return new Promise(function(resolve) {
			const done = function(val) { ui.hideModal(); resolve(val); };

			ui.showModal(title, [
				E('p', {}, message),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', 'click': function() { done(false); } }, _('Cancel')),
					' ',
					E('button', {
						'class': 'btn cbi-button cbi-button-action important',
						'click': function() { done(true); }
					}, okLabel || _('OK'))
				])
			]);
		});
	},

	fmtBytes: function(n) {
		n = Number(n) || 0;
		const u = ['B', 'KB', 'MB', 'GB', 'TB'];
		let i = 0;
		while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
		return n.toFixed(i ? 1 : 0) + ' ' + u[i];
	},

	/* Stream editor text to an ACL-allowed /tmp path through cgi-io's
	 * multipart upload endpoint. Unlike fs.write (one ubus message, capped by
	 * the ubus transport size) this handles arbitrarily large configs/scripts.
	 * The caller then hands the same path to the helper via `--from`. */
	upload: function(path, content) {
		const data = new FormData();

		data.append('sessionid', rpc.getSessionID());
		data.append('filename', path);
		data.append('filedata',
			new Blob([content != null ? content : ''], { type: 'application/octet-stream' }),
			'upload');

		return request.post(L.env.cgi_base + '/cgi-upload', data).then(function(res) {
			const reply = res.json();

			if (!L.isObject(reply) || reply.failure)
				return Promise.reject(new Error((reply && reply.message) || _('Upload failed')));

			return reply;
		});
	}
});
