// The Command Hub: the popover under Zenith's menu bar icon. The icon is there only when Settings → Dynamic Island → Behavior →
// Menu Bar Icon is on, or the tool dock is off. While the island has its dock, the hub leaves out its quick-action grid and its
// Clean and Boost buttons (typing in its search still finds and runs them). Its running-apps and meters are shared with the
// island's System page.
import {
  $, bus, esc, icon, html, settings, setSetting, registerAction, runAction, shortcutText, formatBytes, closeMenus,
  showMenu, app, codeOf,
} from './core.js';
import { cleaner, processes, ports, system, boost, keepAwake, keepAwakeMenuItems } from './models.js';
import { island } from './island.js';

let pop = null;
let ticker = 0;
let query = '';
let scanState = 'idle';
export const speed = { down: 2.4e6, up: 1.8e5 };

const TILES = [
  { id: 'captureArea', title: 'Capture Area', icon: 'crop', tint: 'blue' },
  { id: 'captureScreen', title: 'Capture Screen', icon: 'screen', tint: 'indigo' },
  { id: 'ocr', title: 'Copy Text', icon: 'textscan', tint: 'teal' },
  { id: 'clipboard', title: 'Clipboard', icon: 'clipboard', tint: 'orange' },
];

const EXTRA = [
  { id: 'cleaningMode', title: 'Cleaning Mode', icon: 'sparkles' },
  { id: 'snippets', title: 'Snippets', icon: 'snippet' },
  { id: 'island', title: 'Open the Island', icon: 'island', run: () => island.open() },
  { id: 'boost', title: 'Boost', icon: 'boost', run: () => doBoost() },
  { id: 'settings', title: 'Settings…', icon: 'gear' },
];

const cpuText = (p) => `${p.cpu.toFixed(1)}%`;

/** The running-apps list (and, for a number, the ports), as the hub and the System page draw it. */
export function appsHTML(q) {
  const apps = processes.list.filter((p) => !q || p.name.toLowerCase().includes(q)).slice(0, 5);
  const portQuery = q.replace(/^:/, '');
  const portRows = /^\d{1,5}$/.test(portQuery) ? ports.list.filter((p) => String(p.port).startsWith(portQuery)) : [];
  return {
    apps,
    portRows,
    html: `${portRows.length ? `<div class="hub-sec"><div class="hub-head"><span>Ports</span></div>${portRows.map((p) => `<div class="hub-app"><span class="app-ic">${icon('port')}</span><span class="grow"><b>${String(p.port)} · ${esc(p.process)}</b><span>${p.proto} · ${esc(p.address)} · PID ${String(p.pid)}</span></span><button type="button" class="x-btn" data-stop-port="${p.port}" aria-label="Stop ${esc(p.process)} on port ${p.port}">${icon('xcircle')}</button></div>`).join('')}</div>` : ''}
    ${apps.length ? `<div class="hub-sec"><div class="hub-head"><span>Running Apps</span><span>${system.cpu}% CPU · 8 cores</span></div>
      ${apps.map((p, i) => `<div class="hub-app"><span class="app-ic">${icon(p.icon)}</span><span class="grow"><b>${esc(p.name)}</b><span>${formatBytes(p.mem)}</span></span><span class="cpu ${p.cpu > 15 ? 'hot' : ''}">${cpuText(p)}</span><button type="button" class="x-btn" data-quit="${esc(p.name)}" aria-label="Quit ${esc(p.name)} (⌘${i + 1})" title="Quit (⌘${i + 1})">${icon('xcircle')}</button></div>`).join('')}
    </div>` : ''}`,
  };
}

export function metersHTML() {
  const usedPct = Math.round((system.memUsed / system.memTotal) * 100);
  const diskPct = Math.round(((system.diskTotal - system.diskFree) / system.diskTotal) * 100);
  return `
    <div class="meter-box"><span>CPU</span><b>${system.cpu}%</b><span class="meter"><span style="width:${system.cpu}%"></span></span></div>
    <div class="meter-box"><span>Memory</span><b>${usedPct}%</b><span class="meter"><span style="width:${usedPct}%"></span></span></div>
    <div class="meter-box"><span>Free Space</span><b>${formatBytes(system.diskFree)}</b><span class="meter"><span style="width:${diskPct}%"></span></span></div>
    <div class="hub-speed">${icon('download')}${formatBytes(speed.down)}/s <span>${icon('download', 'ic flip')}${formatBytes(speed.up)}/s</span></div>`;
}

export function jitterSpeed() {
  speed.down = Math.max(1e5, speed.down * (0.7 + Math.random() * 0.6));
  speed.up = Math.max(1e4, speed.up * (0.7 + Math.random() * 0.6));
}

/** Clicks on a running app's ✕ or a port's ✕, shared by the hub and the System page. */
export function handleQuitClicks(e) {
  const quit = e.target.closest?.('[data-quit]')?.dataset.quit;
  if (quit) { processes.quit(quit); return true; }
  const port = e.target.closest?.('[data-stop-port]')?.dataset.stopPort;
  if (port) { ports.stop(Number(port)); return true; }
  return false;
}

const iconVisible = () => !$('#mb-zenith').hidden;

function render() {
  if (!pop) return;
  const q = query.trim().toLowerCase();
  const dockOn = settings.toolDock;
  // With the dock the quick actions are the island's; a search still finds them.
  const tiles = dockOn && !q ? [] : TILES.filter((t) => !q || t.title.toLowerCase().includes(q));
  const extras = q ? EXTRA.filter((t) => t.title.toLowerCase().includes(q)) : [];
  const { apps, portRows, html: appsPart } = appsHTML(q);
  const scanLabel = scanState === 'scanning' ? 'Scanning…' : scanState === 'found' ? `Clean ${formatBytes(cleaner.selectedSize('system'))}` : 'Scan';

  $('.hub-dyn', pop).innerHTML = `
    ${tiles.length ? `<div class="hub-tiles">${tiles.map((t) => `<button type="button" class="hub-tile" data-run="${t.id}"><span class="tile-ic tint-${t.tint}">${icon(t.icon)}</span><span><b>${t.title}</b><kbd>${esc(shortcutText(t.id) || '—')}</kbd></span></button>`).join('')}</div>` : ''}
    ${extras.length ? `<div class="hub-list">${extras.map((t) => `<button type="button" class="hub-row" data-run="${t.id}">${icon(t.icon)}<span class="grow">${t.title}</span>${shortcutText(t.id) ? `<kbd>${esc(shortcutText(t.id))}</kbd>` : ''}</button>`).join('')}</div>` : ''}
    ${appsPart}
    ${!q ? `<button type="button" class="hub-awake hub-ports" data-hub="ports"><span class="tile-ic small tint-cyan">${icon('globe')}</span><span class="grow">Listening Ports</span><span class="dim">${ports.list.filter((p) => p.proto === 'TCP').length}</span>${icon('chevron')}</button>` : ''}
    ${!tiles.length && !extras.length && !apps.length && !portRows.length ? `<div class="hub-none">Nothing matches “${esc(query)}”.</div>` : ''}`;

  $('.hub-meters', pop).innerHTML = metersHTML();
  $('.hub-shield input', pop).checked = settings.shieldOn;
  $('.hub-awake-switch', pop).checked = keepAwake.on;
  $('.hub-controls', pop).hidden = dockOn;
  const scan = $('[data-hub="scan"]', pop);
  scan.innerHTML = `${icon('sparkles')}${scanLabel}`;
  scan.disabled = scanState === 'scanning';
}

async function doBoost() {
  const b = $('[data-hub="boost"]', pop);
  if (b) { b.disabled = true; b.innerHTML = `${icon('boost')}Boosting…`; }
  await boost();
  if (b) { b.disabled = false; b.innerHTML = `${icon('boost')}Boost`; }
  render();
}

async function doScan() {
  if (scanState === 'found') {
    await cleaner.clean('system');
    scanState = cleaner.selectedSize('system') ? 'found' : 'idle';
    render();
    return;
  }
  scanState = 'scanning';
  render();
  await cleaner.scan('system');
  scanState = cleaner.selectedSize('system') ? 'found' : 'idle';
  render();
}

function openHub() {
  if (!app.running || !iconVisible()) return;
  if (pop) { closeHub(); return; }
  closeMenus();
  const anchor = $('#mb-zenith');
  pop = html`<div class="hub" role="dialog" aria-label="Zenith Command Hub">
    <div class="hub-search">${icon('search')}<input type="text" placeholder="Search actions and apps" aria-label="Search actions and apps" autocomplete="off" spellcheck="false"></div>
    <div class="hub-dyn"></div>
    <div class="hub-meters"></div>
    <div class="hub-controls">
      <span class="grow"></span>
      <button type="button" class="chip" data-hub="scan">${icon('sparkles')}Scan</button>
      <button type="button" class="chip" data-hub="boost">${icon('boost')}Boost</button>
    </div>
    <div class="hub-switches">
      <label class="hub-shield"><span class="tile-ic tint-green small">${icon('lockshield')}</span><span class="grow">Privacy Shield</span><input type="checkbox" class="switch" role="switch"></label>
      <div class="hub-shield hub-awake-row"><span class="tile-ic tint-amber small">${icon('mug')}</span><span class="grow">Keep Awake</span><button type="button" class="x-btn" data-hub="awake" aria-label="Keep Awake for how long" title="For how long">${icon('timer')}</button><input type="checkbox" class="switch hub-awake-switch" role="switch" aria-label="Keep Awake"></div>
    </div>
    <div class="hub-foot">
      <button type="button" data-hub="settings">Settings… <kbd>⌘,</kbd></button>
      <button type="button" data-hub="quit">Quit Zenith <kbd>⌘Q</kbd></button>
    </div>
  </div>`;
  document.body.append(pop);
  const r = anchor.getBoundingClientRect();
  pop.style.top = `${r.bottom + 6}px`;
  pop.style.right = `${Math.max(8, window.innerWidth - r.right - 60)}px`;
  anchor.classList.add('open');
  anchor.setAttribute('aria-expanded', 'true');
  const input = $('input[type="text"]', pop);
  input.addEventListener('input', () => { query = input.value; render(); });
  input.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') { e.preventDefault(); closeHub(); anchor.focus(); }
    if (e.key === 'Enter') {
      e.preventDefault();
      if (query.trim().toLowerCase() === 'boost') { doBoost(); return; }
      $('.hub-dyn [data-run]', pop)?.click();
    }
    const meta = e.metaKey || e.ctrlKey;
    if (meta && /^Digit[1-4]$/.test(codeOf(e))) {
      e.preventDefault();
      const p = processes.list[Number(codeOf(e).slice(5)) - 1];
      if (p) processes.quit(p.name);
    }
  });
  pop.addEventListener('click', (e) => {
    const run = e.target.closest?.('[data-run]')?.dataset.run;
    if (run) {
      const extra = EXTRA.find((x) => x.id === run);
      closeHub();
      if (extra?.run) extra.run(); else runAction(run);
      return;
    }
    if (handleQuitClicks(e)) return;
    const act = e.target.closest?.('[data-hub]')?.dataset.hub;
    if (act === 'scan') doScan();
    if (act === 'boost') doBoost();
    if (act === 'settings') { closeHub(); runAction('settings'); }
    if (act === 'quit') { closeHub(); runAction('quit'); }
    if (act === 'ports') { closeHub(); if (!island.openPage('ports')) runAction('settings', 'ports'); }
    if (act === 'awake') showMenu(e.target.closest?.('[data-hub]'), keepAwakeMenuItems(), { align: 'right', className: 'menu-over' });
  });
  $('.hub-shield input', pop).addEventListener('change', (e) => setSetting('shieldOn', e.target.checked));
  $('.hub-awake-switch', pop).addEventListener('change', (e) => keepAwake.set(e.target.checked ? Infinity : null));
  query = '';
  render();
  input.focus();
  bus.emit('tour', 'hub');
  // Like the app, the hub only samples while it is open.
  ticker = setInterval(() => {
    processes.jitter();
    jitterSpeed();
    render();
  }, 2500);
}

function closeHub() {
  if (!pop) return;
  clearInterval(ticker);
  pop.remove();
  pop = null;
  $('#mb-zenith').classList.remove('open');
  $('#mb-zenith').setAttribute('aria-expanded', 'false');
}

export function initHub() {
  registerAction('hub', openHub);
  document.addEventListener('pointerdown', (e) => {
    if (!pop || pop.contains(e.target) || e.target.closest?.('#mb-zenith, .scrim, .menu')) return;
    closeHub();
  }, true);
  ['processes', 'ports', 'system', 'keep-awake', 'setting:shieldOn', 'setting:toolDock', 'cleaner'].forEach((t) => bus.on(t, render));
  ['setting:menuBarIcon', 'setting:toolDock'].forEach((t) => bus.on(t, () => queueMicrotask(() => { if (!iconVisible()) closeHub(); })));
  bus.on('zenith-running', (r) => { if (!r) closeHub(); });
  window.addEventListener('blur', closeHub);
}
