// Notifications for editors on this device (both pages; build.py puts this file into each). The browser's
// push subscription is stored in Supabase (push_subscriptions); see functions/api/notify.js for the sending side.
const makePush = (sb, vapidKey) => {
  const ios = /iP(hone|ad|od)/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
  const installed = matchMedia('(display-mode: standalone)').matches || navigator.standalone === true;
  const can = !!vapidKey && 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window && window.isSecureContext;
  const keyBytes = () => Uint8Array.from(atob(vapidKey.replace(/-/g, '+').replace(/_/g, '/')), c => c.charCodeAt(0));
  const current = async () => {
    const r = await navigator.serviceWorker.getRegistration();
    return r ? r.pushManager.getSubscription() : null;
  };
  const save = async s => {
    const { data: { session } } = await sb.auth.getSession();
    const j = s.toJSON();
    const { error } = await sb.from('push_subscriptions').upsert({ endpoint: j.endpoint, p256dh: j.keys.p256dh, auth: j.keys.auth, email: session.user.email });
    if (error) throw error;
  };
  return {
    // 'on' | 'off' | 'denied' | 'ios' (iPhone: add the site to the Home Screen first) | 'none' (no support)
    async state() {
      if (!can) return ios && !installed ? 'ios' : 'none';
      if (Notification.permission === 'denied') return 'denied';
      const s = await current();
      if (s) save(s).catch(() => {});   // keep the stored device in step (it may have been removed)
      return s ? 'on' : 'off';
    },
    async enable() {
      if (await Notification.requestPermission() !== 'granted') return this.state();
      const r = await navigator.serviceWorker.register('sw.js');
      await navigator.serviceWorker.ready;
      const s = (await r.pushManager.getSubscription()) || await r.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: keyBytes() });
      await save(s);
      return 'on';
    },
    async disable() {
      const s = await current();
      if (s) {
        await sb.from('push_subscriptions').delete().eq('endpoint', s.endpoint);
        await s.unsubscribe();
      }
      return 'off';
    },
    // the switch in the editors' review panel (t and esc are the page's own)
    html(st) {
      const bell = '<svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 11.5V7.2a4 4 0 0 1 8 0v4.3l1.2 1.3H2.8z"/><path d="M6.6 14.2a1.5 1.5 0 0 0 2.8 0"/></svg>';
      return st === 'off' ? `<button type="button" class="btn" data-push="on">${bell}${esc(t('pushOn'))}</button>`
        : st === 'on' ? `<span class="pushnote">${bell}${esc(t('pushIsOn'))}</span><button type="button" class="btn" data-push="off">${esc(t('pushOff'))}</button>`
        : st === 'denied' || st === 'ios' ? `<span class="pushnote">${esc(t(st === 'ios' ? 'pushIos' : 'pushDenied'))}</span>` : '';
    },
    async fill(el) { if (el) el.innerHTML = this.html(await this.state().catch(() => 'none')); },
    async click(el, b) {
      b.disabled = true;
      try { el.innerHTML = this.html(b.dataset.push === 'on' ? await this.enable() : await this.disable()); }
      catch (e) {
        console.error(e);
        el.innerHTML = this.html(await this.state().catch(() => 'none')) + `<span class="pushnote err">${esc(t('failed') + (e.message || e))}</span>`;
      }
    }
  };
};
