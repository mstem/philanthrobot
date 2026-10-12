// Served by Caddy at /static/loader.js in place of Open WebUI's empty stock
// file, so Open WebUI updates cannot overwrite it. Shows the planned-update
// notice from /update-notice.json in a light gray bar, including in tabs that
// were already open when the notice was switched on.
(() => {
	const NOTICE_URL = '/update-notice.json';
	const DISMISSED_KEY = 'philanthrobot-update-notice-dismissed';
	const CHECK_EVERY_MS = 5 * 60 * 1000;
	const BAR_ID = 'philanthrobot-update-notice';

	const dismissedId = () => {
		try {
			return localStorage.getItem(DISMISSED_KEY);
		} catch {
			return null;
		}
	};

	const remove = () => {
		document.getElementById(BAR_ID)?.remove();
		document.documentElement.style.removeProperty('--philanthrobot-notice-h');
		document.documentElement.classList.remove('philanthrobot-notice-on');
	};

	const style = () => {
		if (document.getElementById(BAR_ID + '-style')) return;
		const s = document.createElement('style');
		s.id = BAR_ID + '-style';
		s.textContent = `
			#${BAR_ID} {
				position: fixed; top: 0; left: 0; right: 0; z-index: 9999;
				display: flex; align-items: center; justify-content: center; gap: 12px;
				padding: 8px 44px 8px 16px;
				background: #f3f4f6; color: #374151;
				border-bottom: 1px solid #e5e7eb;
				font: 400 13px/1.4 system-ui, -apple-system, sans-serif;
				text-align: center;
			}
			#${BAR_ID} button {
				position: absolute; right: 10px; top: 50%; transform: translateY(-50%);
				width: 26px; height: 26px; padding: 0;
				border: 0; border-radius: 6px; background: transparent;
				color: #6b7280; font: 400 18px/1 system-ui, sans-serif; cursor: pointer;
			}
			#${BAR_ID} button:hover { background: #e5e7eb; color: #111827; }
			html.dark #${BAR_ID} { background: #262626; color: #d4d4d4; border-bottom-color: #333; }
			html.dark #${BAR_ID} button { color: #a3a3a3; }
			html.dark #${BAR_ID} button:hover { background: #333; color: #fafafa; }
			html.philanthrobot-notice-on body { padding-top: var(--philanthrobot-notice-h); }
			html.philanthrobot-notice-on .h-screen { height: calc(100vh - var(--philanthrobot-notice-h)) !important; }
			html.philanthrobot-notice-on .max-h-\\[100dvh\\] { max-height: calc(100dvh - var(--philanthrobot-notice-h)) !important; }
		`;
		document.head.appendChild(s);
	};

	const show = (notice) => {
		let bar = document.getElementById(BAR_ID);
		if (bar && bar.dataset.noticeId === notice.id) return;
		bar?.remove();
		style();
		bar = document.createElement('div');
		bar.id = BAR_ID;
		bar.dataset.noticeId = notice.id;
		bar.setAttribute('role', 'status');
		const text = document.createElement('span');
		text.textContent = notice.text;
		const close = document.createElement('button');
		close.type = 'button';
		close.setAttribute('aria-label', 'Close');
		close.textContent = '×';
		close.addEventListener('click', () => {
			try {
				localStorage.setItem(DISMISSED_KEY, notice.id);
			} catch {}
			remove();
		});
		bar.append(text, close);
		document.body.appendChild(bar);
		const fit = () =>
			document.documentElement.style.setProperty('--philanthrobot-notice-h', bar.offsetHeight + 'px');
		fit();
		new ResizeObserver(fit).observe(bar);
		document.documentElement.classList.add('philanthrobot-notice-on');
	};

	const check = async () => {
		try {
			const res = await fetch(NOTICE_URL, { cache: 'no-store', credentials: 'omit' });
			if (!res.ok) return remove();
			const notice = await res.json();
			if (notice.active && notice.id && notice.text && dismissedId() !== notice.id) show(notice);
			else remove();
		} catch {}
	};

	const start = () => {
		check();
		setInterval(check, CHECK_EVERY_MS);
		document.addEventListener('visibilitychange', () => {
			if (document.visibilityState === 'visible') check();
		});
	};

	if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
	else start();
})();
