const call = (c, a) => window.__TAURI__.core.invoke(c, a);
const $ = (id) => document.getElementById(id);
const fmt = (b) => b >= 1e9 ? (b / 1e9).toFixed(2) + ' GB' : b >= 1e6 ? (b / 1e6).toFixed(1) + ' MB' : Math.round(b / 1e3) + ' KB';
let catalogue = [];
let editing = null;
const show = (e) => { $('err').textContent = e ? String(e) : ''; };
const el = (tag, text, cls) => { const n = document.createElement(tag); if (text !== undefined) n.textContent = text; if (cls) n.className = cls; return n; };
const act = (fn) => async () => { try { show(''); await fn(); } catch (e) { show(e); } await render(); };

async function render() {
  let views = [];
  try { views = await call('list_spaces'); } catch (e) { show(e); }
  const root = $('spaces'); root.replaceChildren();
  if (!views.length) root.append(el('p', 'No storage yet. Add R2, B2, e2, S3, GCS, Azure or any S3-compatible bucket.', 'muted'));
  for (const v of views) {
    const s = v.space, card = el('div', undefined, 'card'), row = el('div', undefined, 'row');
    row.append(el('h3', s.title), el('span', v.provider ? v.provider.title : s.provider, 'badge'));
    if (s.archive) row.append(el('span', 'Archive', 'badge'));
    const btn = (label, fn, sec) => { const b = el('button', label, sec ? 'sec' : ''); b.onclick = act(fn); return b; };
    row.append(v.running ? btn('Open', () => call('open_folder', { id: s.id }), true) : el('span'),
      v.running ? btn('Disconnect', () => call('stop_space', { id: s.id })) : btn('Connect', () => call('start_space', { id: s.id })),
      btn('Refresh usage', async () => { await call('refresh_usage', { id: s.id, force: true }); }, true));
    if (!v.running) row.append(btn('Edit', () => openEdit(v), true));
    if (!v.running) row.append(btn('Clean junk files', () => call('clean_junk', { id: s.id }), true));
    if (!v.running) row.append(btn('Remove', () => call('remove_space', { id: s.id }), true));
    card.append(row);
    if (v.quota) {
      const q = v.quota, bar = el('div', undefined, 'bar ' + q.level), fill = el('i');
      fill.style.width = Math.round((q.fraction ?? 0) * 100) + '%'; bar.append(fill);
      const text = q.limit ? `${fmt(q.used)} of ${fmt(q.limit)} free tier` + (q.level === 'exceeded' ? ` — over by ${fmt(q.overage)}, pay-as-you-go applies` : ` — ${fmt(q.remaining)} left`) : `${fmt(q.used)} used`;
      card.append(bar, el('div', text, 'muted'));
    } else card.append(el('div', 'Usage not measured yet.', 'muted'));
    if (v.provider && v.provider.price_per_gb && v.usage) {
      const cost = Math.max(v.usage.used - (v.provider.free_tier || 0), 0) / 1e9 * v.provider.price_per_gb;
      card.append(el('div', `Estimated storage cost: ${cost < 0.01 && cost > 0 ? '<$0.01' : '$' + cost.toFixed(2)} / month (list price, excludes requests and egress)`, 'muted'));
    }
    if (v.provider) card.append(el('div', v.provider.egress_note, 'muted'));
    root.append(card);
    call('refresh_usage', { id: s.id, force: false }).catch(() => {});
  }
}

function fillProvider() {
  const p = catalogue.find((x) => x.id === $('prov').value);
  $('steps').replaceChildren(...p.steps.map((t) => el('li', t)));
  $('note').textContent = p.egress_note; $('console').hidden = !p.console_url;
  $('fields').replaceChildren(...p.fields.map((f) => {
    const l = el('label', f.label), i = el('input'); i.dataset.key = f.key; i.type = f.secret ? 'password' : 'text';
    i.placeholder = f.placeholder; i.autocomplete = 'off'; i.required = true; l.append(i); return l;
  }));
  $('archive').checked = true;
}

function openEdit(v) {
  editing = v.space; $('form').reset(); $('prov').value = editing.provider; fillProvider();
  $('dtitle').textContent = 'Edit ' + editing.title; $('prov').disabled = true;
  $('title').value = editing.title; $('root').value = editing.root; $('ro').checked = editing.read_only; $('archive').checked = editing.archive;
  document.querySelectorAll('#fields input').forEach((i) => { i.required = false; i.placeholder = 'Leave blank to keep saved credentials'; });
  $('dlg').showModal();
}
$('add').onclick = () => { editing = null; $('prov').disabled = false; $('dtitle').textContent = 'Add storage'; $('form').reset(); fillProvider(); $('dlg').showModal(); };
$('prov').onchange = fillProvider;
$('console').onclick = () => call('open_url', { url: catalogue.find((x) => x.id === $('prov').value).console_url }).catch(show);
$('form').addEventListener('submit', async (ev) => {
  if (ev.submitter.value !== 'ok') return;
  const fields = {}; document.querySelectorAll('#fields input').forEach((i) => { fields[i.dataset.key] = i.value; });
  try {
    const args = { title: $('title').value, root: $('root').value, readOnly: $('ro').checked, archive: $('archive').checked, fields };
    if (editing) await call('update_space', { id: editing.id, ...args }); else await call('add_space', { provider: $('prov').value, ...args });
    show('');
  } catch (e) { show(e); }
  await render();
});

(async () => {
  catalogue = await call('catalogue');
  $('prov').replaceChildren(...catalogue.map((p) => { const o = el('option', p.title); o.value = p.id; return o; }));
  await render(); setInterval(render, 15000);
})();
