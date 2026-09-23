  // dsh-bridge-en: verify bridge admin access before the host's directory picker opens remotely.
  // Uses the same admin session as the bridge panel (sessionStorage token; "Lock the admin panel again" revokes it).
  const ensureAdminForPicker = async (btn) => {
    const proceed = () => { btn.dataset.dshAdminOk = '1'; btn.click(); };
    let msg = '';
    try {
      const token = getAdminToken();
      const res = await rpcCall(BRIDGE_ENDPOINTS.listRemoteDirectories, { path: '', ...(token ? { adminToken: token } : {}) });
      if (res?.ok !== false) { proceed(); return; }
      msg = res?.error?.message || '';
    } catch (err) { msg = String(err?.message || err || ''); }
    const needsUnlock = msg.includes('admin privileges required') || msg.includes('password to unlock');
    const localOnly = msg.includes('local-machine admin only');
    if (!needsUnlock && !localOnly) { proceed(); return; } // not an admin gate (e.g. protection off) — do not block
    clearAdminToken();
    let ov = document.getElementById('dsh-picker-admin-gate');
    if (ov) ov.remove();
    ov = document.createElement('div');
    ov.id = 'dsh-picker-admin-gate';
    ov.style.cssText = 'position:fixed;inset:0;z-index:100000;background:rgba(0,0,0,0.45);display:flex;align-items:center;justify-content:center;padding:20px;';
    const inputHtml = localOnly ? '' : '<input name="pwd" type="password" autocomplete="current-password" placeholder="Enter the admin password" style="width:100%;box-sizing:border-box;font-size:14px;padding:10px 12px;border-radius:8px;border:1px solid var(--dsw-alias-border-l2,#d1d5db);background:var(--dsw-alias-bg-layer-2,#f9fafb);color:inherit;outline:none;" />';
    const submitHtml = localOnly ? '' : '<button type="submit" style="border:none;background:#2563eb;color:#fff;padding:8px 16px;border-radius:8px;font-size:13px;font-weight:600;cursor:pointer;">Unlock</button>';
    const title = localOnly ? 'Admin console locked' : 'Admin password required';
    const text = localOnly
      ? 'The "Local machine admin only" policy is active: browsing folders and adding workspaces is only allowed on the computer itself (127.0.0.1).'
      : 'Browsing folders and adding workspaces from a remote device requires the admin password (different from the access password).';
    ov.innerHTML = '<form style="width:100%;max-width:360px;background:var(--dsw-alias-bg-layer-1,#fff);color:var(--dsw-alias-label-primary,#111827);border-radius:14px;padding:18px 16px;box-shadow:0 12px 32px rgba(0,0,0,0.25);display:flex;flex-direction:column;gap:10px;">'
      + '<div style="font-size:15px;font-weight:600;">🔒 ' + title + '</div>'
      + '<div style="font-size:12px;color:var(--dsw-alias-label-secondary,#6b7280);line-height:1.5;">' + text + '</div>'
      + inputHtml
      + '<div data-err style="display:none;font-size:12px;color:#dc2626;"></div>'
      + '<div style="display:flex;gap:8px;justify-content:flex-end;">'
      + '<button type="button" data-cancel style="border:1px solid var(--dsw-alias-border-l2,#d1d5db);background:transparent;color:inherit;padding:8px 14px;border-radius:8px;font-size:13px;cursor:pointer;">Cancel</button>'
      + submitHtml
      + '</div></form>';
    document.body.appendChild(ov);
    const form = ov.querySelector('form'); const input = ov.querySelector('input[name=pwd]'); const errEl = ov.querySelector('[data-err]');
    const close = () => ov.remove();
    ov.querySelector('[data-cancel]').onclick = close;
    ov.addEventListener('click', (ev) => { if (ev.target === ov) close(); });
    if (input) setTimeout(() => input.focus(), 50);
    form.onsubmit = async (ev) => {
      ev.preventDefault();
      if (!input) return;
      const pwd = input.value; if (!pwd) return;
      const sb = form.querySelector('button[type=submit]'); sb.disabled = true; sb.textContent = 'Verifying…';
      const r = await unlockAdmin(rpcCall, pwd);
      if (r.ok) { close(); proceed(); return; }
      sb.disabled = false; sb.textContent = 'Unlock';
      errEl.textContent = r.error || 'Wrong admin password'; errEl.style.display = 'block';
      input.select();
    };
  };

