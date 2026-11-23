// The Command Hub, Control Center style: the popover under Zenith's menu bar icon. The icon is there only when Settings → Dynamic
// Island → Behavior → Menu Bar Icon is on, or the tool dock is off. A search capsule, two toggle tiles (Privacy Shield, Keep
// Awake: filled with the feature's colour while on), ring gauges, the running apps and a footer (Listening Ports, Settings, Quit).
// While the island has its dock, the hub leaves out Scan and Boost (typing in its search still finds and runs them). The gauges
// and the running apps are shared with the island's System page, which leaves out everything the island has itself.
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

/** A running app's CPU: from 100 % up the decimal goes ("156%"), below it keeps one ("9.5%"). */
const cpuText = (p) => `${p.cpu >= 100 ? Math.round(p.cpu) : (Math.round(p.cpu * 10) / 10).toFixed(1)}%`;
/** Orange above 20 %, red above 50 % (HubGaugeLevel.process). */
const cpuLevel = (cpu) => (cpu > 50 ? 'crit' : cpu > 20 ? 'warn' : '');

/** A size short enough for a 60 pt ring: one decimal below 10 GB, whole numbers above (HubStatus.compactSize). */
function compactSize(bytes) {
  const gb = Math.max(bytes, 0) / 1e9;
  if (gb >= 1000) return `${(gb / 1000) >= 10 ? Math.round(gb / 1000) : (gb / 1000).toFixed(1)} TB`;
  if (gb >= 10) return `${Math.round(gb)} GB`;
  if (gb >= 0.1) return `${gb.toFixed(1)} GB`;
  return `${Math.round(bytes / 1e6)} MB`;
}

/** The running-apps module (and, for a number typed in the search, the ports), as the hub and the System page draw them. */
export function appsHTML(q) {
  const apps = processes.list.filter((p) => !q || p.name.toLowerCase().includes(q)).slice(0, 5);
  const portQuery = q.replace(/^:/, '');
  const portRows = /^\d{1,5}$/.test(portQuery) ? ports.list.filter((p) => String(p.port).startsWith(portQuery)) : [];
  return {
    apps,
    portRows,
    html: `${portRows.length ? `<div class="hub-module hub-apps"><div class="hub-head"><span>Ports</span></div>${portRows.map((p) => `<div class="hub-app"><span class="app-ic">${icon('port')}</span><span class="grow"><b>${String(p.port)} · ${esc(p.process)}</b><span>${p.proto} · ${esc(p.address)} · PID ${String(p.pid)}</span></span><button type="button" class="x-btn" data-stop-port="${p.port}" aria-label="Stop ${esc(p.process)} on port ${p.port}" title="Stop">${icon('xcircle')}</button></div>`).join('')}</div>` : ''}
    ${apps.length ? `<div class="hub-module hub-apps"><div class="hub-head"><span>Running Apps</span><span>8 cores</span></div>
      ${apps.map((p, i) => `<div class="hub-app"><span class="app-ic">${icon(p.icon)}</span><span class="grow"><b>${esc(p.name)}</b><span>${formatBytes(p.mem)}</span></span><span class="cpu-bar"><span class="${cpuLevel(p.cpu)}" style="width:${Math.min(100, Math.max(0, p.cpu / 2))}%"></span></span><span class="cpu ${cpuLevel(p.cpu)}">${cpuText(p)}</span><button type="button" class="x-btn" data-quit="${esc(p.name)}" aria-label="Quit ${esc(p.name)}${i < 4 ? ` (⌘${i + 1})` : ''}" title="Quit${i < 4 ? ` (⌘${i + 1})` : ''}">${icon('xcircle')}</button></div>`).join('')}
    </div>` : ''}`,
  };
}

/** One 60 pt ring gauge: a 5 pt round-capped arc on a faint track, the value in the middle and the name under it. */
function gauge(title, value, fraction, color) {
  const r = 27.5;
  const c = 2 * Math.PI * r;
  const f = Math.min(1, Math.max(0.001, fraction));
  return `<div class="gauge" role="img" aria-label="${esc(title)}: ${esc(value)}"><span class="gauge-ring"><svg width="60" height="60" viewBox="0 0 60 60" aria-hidden="true"><circle class="g-track" cx="30" cy="30" r="${r}"/><circle class="g-arc" cx="30" cy="30" r="${r}" style="stroke:${color}" stroke-dasharray="${c.toFixed(2)}" stroke-dashoffset="${(c * (1 - f)).toFixed(2)}" transform="rotate(-90 30 30)"/></svg><b class="${value.length > 5 ? 'is-long' : ''}">${esc(value)}</b></span><span class="gauge-name">${esc(title)}</span></div>`;
}

/** The inside of the gauges module: CPU, memory and free space as rings, and the network line. */
export function metersHTML() {
  const memPct = Math.round((system.memUsed / system.memTotal) * 100);
  const cpuColor = system.cpu > 75 ? 'var(--red)' : system.cpu > 40 ? 'var(--orange)' : 'var(--accent)';
  return `${gauge('CPU', `${system.cpu}%`, system.cpu / 100, cpuColor)}
    ${gauge('Memory', `${memPct}%`, memPct / 100, memPct > 85 ? 'var(--red)' : 'var(--orange)')}
    ${gauge('Free Space', compactSize(system.diskFree), system.diskFree / system.diskTotal, '#5ac8d8')}
    <div class="hub-speed"><span>${icon('download')}${formatBytes(speed.down)}/s</span><span>${icon('download', 'ic flip')}${formatBytes(speed.up)}/s</span></div>`;
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
  // Searching: the matching actions come first (with the dock they are the island's, and only a search finds them here).
  const actions = q ? [...TILES, ...EXTRA].filter((t) => t.title.toLowerCase().includes(q)) : [];
  const { apps, portRows, html: appsPart } = appsHTML(q);
  const scanLabel = scanState === 'scanning' ? 'Scanning…' : scanState === 'found' ? `Clean ${formatBytes(cleaner.selectedSize('system'))}` : 'Scan';

  $('.hub-dyn', pop).innerHTML = `
    ${actions.length ? `<div class="hub-module hub-list">${actions.map((t) => `<button type="button" class="hub-row" data-run="${t.id}">${icon(t.icon)}<span class="grow">${t.title}</span>${shortcutText(t.id) ? `<kbd>${esc(shortcutText(t.id))}</kbd>` : ''}</button>`).join('')}</div>` : ''}
    ${appsPart}
    ${!actions.length && !apps.length && !portRows.length ? `<div class="hub-none">Nothing matches “${esc(query)}”.</div>` : ''}`;

  const shield = $('[data-hub="shield"]', pop);
  shield.classList.toggle('is-on', !!settings.shieldOn);
  shield.setAttribute('aria-pressed', String(!!settings.shieldOn));
  $('.ht-status', shield).textContent = settings.shieldOn ? 'On' : 'Off';
  const awake = $('[data-hub="awake-toggle"]', pop);
  awake.classList.toggle('is-on', keepAwake.on);
  awake.setAttribute('aria-pressed', String(keepAwake.on));
  $('.ht-status', awake).textContent = keepAwake.on ? keepAwake.leftText().replace(/^On until/, 'Until') : 'Off';
  $('.hub-tiles', pop).hidden = !!q;
  $('.hub-meters', pop).hidden = !!q;
  $('.hub-meters', pop).innerHTML = q ? '' : metersHTML();
  $('.hub-controls', pop).hidden = dockOn || !!q;
  $('.hub-ports-count', pop).textContent = String(ports.list.filter((p) => p.proto === 'TCP').length);
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
    <div class="hub-tiles">
      <div class="hub-tilewrap"><button type="button" class="hub-tile" data-hub="shield" aria-pressed="false" style="--on:#238a3d" title="Look sites up over encrypted DNS through a local proxy"><span class="ht-ic">${icon('lockshield')}</span><span class="ht-t"><b>Privacy Shield</b><span class="ht-status">Off</span></span></button></div>
      <div class="hub-tilewrap"><button type="button" class="hub-tile" data-hub="awake-toggle" aria-pressed="false" style="--on:#b35000" title="Keep the Mac from going to sleep until you turn it off"><span class="ht-ic">${icon('mug')}</span><span class="ht-t"><b>Keep Awake</b><span class="ht-status">Off</span></span></button><button type="button" class="ht-clock" data-hub="awake" aria-label="Keep Awake options" title="Keep the Mac awake for a while">${icon('timer')}</button></div>
    </div>
    <div class="hub-controls">
      <button type="button" class="hub-capsule" data-hub="scan">${icon('sparkles')}Scan</button>
      <button type="button" class="hub-capsule" data-hub="boost">${icon('boost')}Boost</button>
    </div>
    <div class="hub-meters hub-module"></div>
    <div class="hub-dyn"></div>
    <div class="hub-foot">
      <button type="button" class="hub-capsule" data-hub="ports">${icon('globe')}<span class="grow">Listening Ports</span><span class="dim hub-ports-count"></span>${icon('chevron')}</button>
      <button type="button" class="hub-circle" data-hub="settings" aria-label="Settings" title="Settings (⌘,)">${icon('gear')}</button>
      <button type="button" class="hub-circle" data-hub="quit" aria-label="Quit Zenith" title="Quit Zenith (⌘Q)">${icon('power')}</button>
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
    if (act === 'shield') setSetting('shieldOn', !settings.shieldOn);
    if (act === 'awake-toggle') keepAwake.set(keepAwake.on ? null : Infinity);
    if (act === 'ports') { closeHub(); runAction('settings', 'ports'); }
    if (act === 'awake') showMenu(e.target.closest?.('[data-hub]'), keepAwakeMenuItems(), { align: 'right', className: 'menu-over' });
  });
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
