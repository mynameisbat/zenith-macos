// The notch island: closed wings, hover-then-open, click, swipes, what is going on (Now Playing, widgets, AI agents, the drop
// shelf), the dock of tools under it, the pages it grows into, and notices.
import {
  $, $$, bus, esc, icon, html, settings, setSetting, notify, setNoticeHandler, formatClock, formatBytes, reduceMotion,
  anyFullScreen, app, playSound, confirmDestructive, clamp, runAction, shortcutText, showContextMenu, menuIsOpen, isNarrow,
} from './core.js';
import { TRACKS, artwork } from './data.js';
import { cleaner, boost, keepAwake, keepAwakeMenuItems, uninstaller, AWAKE_CHOICES } from './models.js';
import { TOOLS, TOOL_GROUPS, PAGES, DOCK_MAX, dockPinned, dockIsFull, dockIsDefault, dockLayout } from './tools.js';

const NOTCH_H = 32;
const SLOT = 40; // an icon on the Tools page's dock strip: the icon and the gap to the next
// A phone has room for a smaller notch only, or the menu bar items disappear under it.
const notchWidth = () => (window.innerWidth <= 720 ? 110 : 186);
const headerH = () => (settings.notch ? NOTCH_H + 4 : 34);

const S = {
  open: false,
  hover: false,
  hoverTimer: 0,
  closeTimer: 0,
  suppressHover: false,
  tab: 'music',
  track: 0,
  playing: true,
  position: 84,
  timer: { mode: null, remaining: 0, total: 0, paused: false },
  sessions: 0,
  shelf: [],
  alert: null,
  alertTimer: 0,
  mute: 0,
  dropping: false,
  eventAt: Date.now() + 15 * 60000 + 20000,
  speed: { down: 2.4e6, up: 1.8e5 },
  page: null,
  pageArg: null,
  backPage: null,
  editing: false,
  awakePrompt: false,
  hintTool: null,
  drag: null,
};

const arts = TRACKS.map((t) => artwork(t.art));
const pageSpecs = {};
let pageDispose = null;
let root;
let shape;

export const island = {
  open, close, openPage, closePage, registerPage, nextTrack, previousTrack, togglePlay, startTimer, stopTimer,
  get state() { return S; },
  addShelfItems,
  available: () => visible(),
  /** The Tools page, ready for editing (the dock's "Edit Dock…"). */
  editDock() { S.editing = true; bus.emit('tour', 'dock-edit'); return openPage('tools'); },
  /** Swallows the notices of the next `ms`: a switch flipped on the dock speaks for itself. */
  mute(ms = 500) { S.mute = Date.now() + ms; },
};

// ---------------------------------------------------------------- geometry

function visible() {
  return app.running && settings.islandEnabled && !(settings.hideInFullScreen && anyFullScreen());
}

const aiWorking = () => settings.aiAgents;
const hasActivity = () => S.playing || S.timer.mode || aiWorking() || keepAwake.on;

function pageSize(id) {
  let [w, h] = PAGES[id].size;
  if (id === 'tools' && isNarrow()) h = 440; // the groups stack on a phone
  const vw = window.innerWidth;
  const vh = window.innerHeight;
  // A small display gets less, and a phone gets the full width.
  return { w: isNarrow() ? vw : Math.min(w, Math.max(380, vw - 40)), h: Math.min(h, Math.max(160, vh - headerH() - 90)) };
}

function geometry() {
  const vw = window.innerWidth;
  const notch = settings.notch;
  const nw = notch ? notchWidth() : 0;
  const narrow = vw <= 720;
  if (S.alert) return { w: Math.min(Math.max(nw + 220, 400), vw - 16), h: NOTCH_H + 42 };
  if (S.open) {
    if (S.page) { const p = pageSize(S.page); return { w: p.w, h: headerH() + p.h }; }
    return { w: Math.min(380, vw - 12), h: 96 + (settings.toolDock ? 66 : 0) };
  }
  const wing = S.timer.mode ? (narrow ? 58 : 76) : keepAwake.on && !S.playing && !aiWorking() ? (narrow ? 50 : 62) : (narrow ? 36 : 42);
  let w = hasActivity() ? nw + 2 * wing : nw;
  let h = NOTCH_H;
  if (!notch) w = hasActivity() ? 2 * wing + 40 : 140;
  if (S.hover && notch && !reduceMotion()) { w += 16; h += 5; }
  return { w, h };
}

function layout() {
  if (!root) return;
  const g = geometry();
  root.style.setProperty('--iw', `${g.w}px`);
  root.style.setProperty('--ih', `${g.h}px`);
  root.style.setProperty('--hh', `${headerH()}px`);
  root.style.setProperty('--nw', `${notchWidth()}px`);
  // Notices go under the island, whatever it shows, and under a page.
  document.documentElement.style.setProperty('--toast-top', S.open && !S.alert ? `${Math.round(g.h + (settings.notch ? 12 : 18))}px` : '');
  root.classList.toggle('no-notch', !settings.notch);
  root.classList.toggle('is-open', S.open && !S.alert);
  root.classList.toggle('has-page', !!S.page && S.open);
  root.classList.toggle('has-dock', !!settings.toolDock);
  root.classList.toggle('has-alert', !!S.alert);
  root.classList.toggle('is-hover', S.hover);
  root.classList.toggle('is-hidden', !visible());
  root.classList.toggle('is-dropping', S.dropping);
  root.classList.toggle('playing', S.playing);
  root.classList.toggle('timer-on', !!S.timer.mode);
  root.classList.toggle('idle', !hasActivity());
  shape.setAttribute('aria-expanded', String(S.open));
}

// ---------------------------------------------------------------- open / close / hover

function open(tab) {
  clearTimeout(S.hoverTimer);
  clearTimeout(S.closeTimer);
  if (tab) S.tab = tab;
  const was = S.open;
  if (!S.open) {
    S.open = true;
    bus.emit('tour', 'island-open');
  } else if (S.page) {
    // Asking for what is going on (a dropped file) leaves the page.
    leavePage();
  }
  renderOpen();
  layout();
  return !was;
}

function leavePage() {
  disposePage();
  S.page = null;
  S.backPage = null;
  S.editing = false;
  S.awakePrompt = false;
}

function close({ suppress = false } = {}) {
  clearTimeout(S.hoverTimer);
  clearTimeout(S.closeTimer);
  if (!S.open && !S.dropping) return;
  S.open = false;
  S.dropping = false;
  S.drag = null;
  leavePage();
  if (suppress) S.suppressHover = true;
  layout();
}

/** Grows the island into a page and keeps it open: a page does not close when the pointer leaves it. */
function openPage(id, arg) {
  if (!PAGES[id] || !visible()) return false;
  clearTimeout(S.hoverTimer);
  clearTimeout(S.closeTimer);
  clearTimeout(S.alertTimer);
  S.alert = null;
  S.hover = false;
  S.suppressHover = false;
  S.awakePrompt = false;
  S.dropping = false;
  // One step of history: a page opened from another page goes back to it.
  const previous = S.page === id ? S.backPage : S.page;
  if (S.page !== id) S.editing = false;
  S.backPage = previous;
  S.page = id;
  S.pageArg = arg;
  S.open = true;
  renderOpen();
  layout();
  bus.emit('tour', 'island-open');
  if (id === 'tools') bus.emit('tour', 'tools');
  return true;
}

/** Back one step: to the page this one was opened from, else to the island as it opens. */
function closePage() {
  if (!S.page) return;
  if (S.backPage) {
    const back = S.backPage;
    S.backPage = null;
    S.editing = false;
    S.page = back;
    S.pageArg = undefined;
    renderOpen();
    layout();
    return;
  }
  leavePage();
  renderOpen();
  layout();
  if (!shape.matches(':hover')) scheduleClose();
}

function registerPage(id, spec) { pageSpecs[id] = spec; }

function disposePage() {
  try { pageDispose?.(); } catch { /* a page that fails to clean up must not keep the island open */ }
  pageDispose = null;
}

function scheduleClose() {
  clearTimeout(S.closeTimer);
  S.closeTimer = setTimeout(() => {
    if (!S.open || S.page || S.dropping) return;
    // A menu or a dialog over the island is not the pointer leaving it.
    if (menuIsOpen() || $('.scrim') || shape.matches(':hover')) { if (S.open && !S.page) scheduleClose(); return; }
    close();
  }, 380);
}

function pointerEntered() {
  clearTimeout(S.closeTimer);
  if (S.suppressHover || S.open) return;
  S.hover = true;
  layout();
  clearTimeout(S.hoverTimer);
  S.hoverTimer = setTimeout(() => {
    if (S.hover) { open(); bus.emit('tour', 'island-hover'); }
  }, settings.hoverDelay * 1000);
}

function pointerLeft() {
  S.suppressHover = false;
  S.hover = false;
  clearTimeout(S.hoverTimer);
  if (S.open && !S.page && !S.dropping) scheduleClose();
  layout();
}

// ---------------------------------------------------------------- swipes (one action per swipe, distances in finger direction)

let swipe = null;
function onWheel(e) {
  if (!settings.swipes || !visible()) return;
  // A page scrolls its own lists.
  if (S.page && e.target.closest?.('.isl-page-body')) return;
  e.preventDefault();
  if (!swipe) swipe = { down: 0, right: 0, done: false, axis: null };
  clearTimeout(swipe.timer);
  swipe.timer = setTimeout(() => { swipe = null; }, 220);
  if (swipe.done) return;
  // With natural scrolling the content follows the finger, so the finger travels opposite to the delta.
  swipe.down += -e.deltaY;
  swipe.right += -e.deltaX;
  swipe.axis ??= Math.abs(swipe.down) + Math.abs(swipe.right) > 6 ? (Math.abs(swipe.right) > Math.abs(swipe.down) ? 'h' : 'v') : null;
  let action = null;
  if (swipe.axis === 'v' && swipe.down >= 40 && !S.open) action = 'open';
  else if (swipe.axis === 'v' && swipe.down <= -40 && S.open) action = 'close';
  else if (swipe.axis === 'h' && TRACKS[S.track].canSkip && swipe.right <= -60) action = 'next';
  else if (swipe.axis === 'h' && TRACKS[S.track].canSkip && swipe.right >= 60) action = 'previous';
  if (!action) return;
  swipe.done = true;
  bus.emit('tour', 'island-swipe');
  if (action === 'open') open();
  if (action === 'close') close({ suppress: true });
  if (action === 'next') nextTrack(true);
  if (action === 'previous') previousTrack(true);
}

// ---------------------------------------------------------------- Now Playing

function track() { return TRACKS[S.track]; }

function nextTrack(fromSwipe = false) {
  if (!track().canSkip) return;
  S.track = (S.track + 1) % TRACKS.length;
  S.position = 0;
  S.playing = true;
  bus.emit('tour', 'island-track');
  if (fromSwipe && !S.open) notify({ icon: 'music', title: track().title, subtitle: track().artist, tint: 'music' });
  render();
}

function previousTrack(fromSwipe = false) {
  if (!track().canSkip) return;
  if (S.position > 3) S.position = 0;
  else S.track = (S.track - 1 + TRACKS.length) % TRACKS.length;
  S.position = 0;
  S.playing = true;
  bus.emit('tour', 'island-track');
  if (fromSwipe && !S.open) notify({ icon: 'music', title: track().title, subtitle: track().artist, tint: 'music' });
  render();
}

function togglePlay() {
  S.playing = !S.playing;
  render();
}

function seek(fraction) {
  if (!track().canSeek) return;
  S.position = Math.round(clamp(fraction, 0, 1) * track().duration);
  bus.emit('tour', 'island-seek');
  updateProgress();
}

// ---------------------------------------------------------------- focus timer

function startTimer(mode) {
  const minutes = mode === 'break' ? settings.breakMinutes : settings.focusMinutes;
  S.timer = { mode, remaining: minutes * 60, total: minutes * 60, paused: false };
  bus.emit('tour', 'timer');
  bus.emit('timer');
  render();
}

function stopTimer() {
  S.timer = { mode: null, remaining: 0, total: 0, paused: false };
  bus.emit('timer');
  render();
}

function toggleTimerPause() {
  if (!S.timer.mode) return;
  S.timer.paused = !S.timer.paused;
  bus.emit('timer');
  render();
}

export function timerSnapshot() { return { ...S.timer, sessions: S.sessions }; }

// ---------------------------------------------------------------- notices

function showAlert(alert) {
  if (!visible()) return false;
  // Muted: a switch on the dock speaks for itself. A page is being worked in: its notices use the floating toast.
  if (Date.now() < S.mute) return true;
  if (S.page && S.open) return false;
  clearTimeout(S.alertTimer);
  S.alert = alert;
  renderAlert();
  layout();
  S.alertTimer = setTimeout(() => { S.alert = null; layout(); }, alert.duration ?? 2600);
  return true;
}

// ---------------------------------------------------------------- shelf

let shelfId = 0;
function addShelfItems(items) {
  for (const it of items) S.shelf.push({ id: ++shelfId, ...it });
  bus.emit('tour', 'shelf');
  open('shelf');
}

function removeShelfItem(id) {
  const it = S.shelf.find((x) => x.id === id);
  if (it?.url) URL.revokeObjectURL(it.url);
  S.shelf = S.shelf.filter((x) => x.id !== id);
  render();
}

function fileKind(name, type) {
  if (/\.app$/i.test(name)) return 'app';
  if (type?.startsWith('image/')) return 'photo';
  if (type?.startsWith('text/') || /\.(txt|md|json|csv|swift|js|css|html|log)$/i.test(name)) return 'doc';
  if (type?.startsWith('video/')) return 'film';
  if (type?.startsWith('audio/')) return 'music';
  if (/\.(dmg|iso|zip|pkg)$/i.test(name)) return 'disk';
  return 'doc';
}

async function itemsFromDrop(dt) {
  const out = [];
  const appName = dt.getData('application/x-zenith-app');
  if (appName) {
    out.push({ name: appName, size: uninstaller.find(appName)?.size ?? 4.12e8, kind: 'app', isApp: true });
    return out;
  }
  for (const f of Array.from(dt.files ?? [])) {
    const kind = fileKind(f.name, f.type);
    const item = { name: f.name, size: f.size, kind, type: f.type };
    if (kind === 'photo') item.url = URL.createObjectURL(f);
    if (kind === 'doc' && f.size < 5e6) item.preview = (await f.slice(0, 4000).text()).slice(0, 4000);
    out.push(item);
  }
  if (!out.length) {
    const text = dt.getData('text/plain');
    if (text) out.push({ name: text.length > 28 ? `${text.slice(0, 28)}…` : text, size: new Blob([text]).size, kind: 'doc', preview: text, isText: true });
  }
  return out;
}

function quickLook(item) {
  const body = item.kind === 'photo' && item.url
    ? `<img src="${item.url}" alt="${esc(item.name)}">`
    : item.preview != null
      ? `<pre>${esc(item.preview)}</pre>`
      : `<div class="ql-icon">${icon(item.kind)}</div>`;
  const scrim = html`<div class="scrim ql-scrim"><div class="ql" role="dialog" aria-modal="true" aria-label="Preview of ${esc(item.name)}">
    <div class="ql-body">${body}</div>
    <div class="ql-foot"><b>${esc(item.name)}</b><span>${formatBytes(item.size)}${item.isApp ? '' : ' · stays in your browser'}</span><button type="button" class="btn btn-small">Close</button></div>
  </div></div>`;
  const done = () => { scrim.remove(); document.removeEventListener('keydown', onKey, true); };
  const onKey = (e) => { if (e.key === 'Escape' || e.key === ' ') { e.preventDefault(); e.stopPropagation(); done(); } };
  scrim.addEventListener('click', (e) => { if (e.target === scrim || e.target.closest?.('button')) done(); });
  document.addEventListener('keydown', onKey, true);
  document.body.append(scrim);
  scrim.querySelector('button').focus();
}

async function uninstallApp(item) {
  const a = uninstaller.find(item.name);
  if (!a) return;
  const items = uninstaller.items(a);
  const n = items.filter((i) => i.selected && !i.app).length;
  const ok = await uninstaller.run(a, items, { title: `Move ${a.name} and ${n === 1 ? '1 file' : `${n} files`} to the Trash?` });
  if (ok) removeShelfItem(item.id);
}

async function slimApp(item) {
  const ok = await confirmDestructive({
    title: 'Slim Sketchbook?',
    message: 'Removes the Intel part of the app. Zenith thins a copy, re-signs it, checks the signature, swaps it in and moves the original to the Trash.',
    details: ['Sketchbook.app: 412 MB → 226 MB'],
    confirm: 'Slim',
    iconName: 'brush',
  });
  if (!ok) return;
  item.size = 2.26e8;
  item.slimmed = true;
  bus.emit('trash:add', [{ name: 'Sketchbook.app (original)', size: 4.12e8 }]);
  bus.emit('tour', 'uninstall');
  notify({ icon: 'check', title: 'Sketchbook slimmed', subtitle: 'Saved 186 MB · the original is in the Trash', tint: 'green' });
  render();
}

// ---------------------------------------------------------------- tools (the dock and the Tools page)

const toolOn = (id) => (id === 'privacyShield' ? !!settings.shieldOn : id === 'keepAwake' ? keepAwake.on : null);

function toolButtonHTML(id, extra = '') {
  const t = TOOLS[id];
  const on = toolOn(id);
  const sc = t.shortcut ? shortcutText(t.shortcut) : '';
  return `<button type="button" class="tool ${on === false ? 'is-off' : ''}" data-act="tool" data-tool="${id}" style="--tint:${t.tint}" aria-label="${esc(t.title)}"${on != null ? ` aria-pressed="${on}"` : ''} title="${esc(sc ? `${t.detail} (${sc})` : t.detail)}">${icon(t.icon)}${extra}</button>`;
}

function hintText() {
  if (S.awakePrompt) return 'Keep the Mac awake for';
  const id = S.hintTool;
  if (!id) return '';
  const t = TOOLS[id];
  const on = toolOn(id);
  if (on == null) { const sc = t.shortcut ? shortcutText(t.shortcut) : ''; return sc ? `${t.title}  ${sc}` : t.title; }
  if (id === 'keepAwake' && on) return `${t.title}: ${keepAwake.leftText()}`;
  return `${t.title}: ${on ? 'On' : 'Off'}`;
}

function awakeChoicesHTML() {
  return `<div class="awake-choices">${AWAKE_CHOICES.map(([label, m]) => `<button type="button" class="awake-chip" data-act="awake" data-min="${m === Infinity ? 'inf' : m}">${label}</button>`).join('')}<span class="grow"></span><button type="button" class="awake-x" data-act="awake-cancel" aria-label="Cancel">${icon('x')}</button></div>`;
}

function dockHTML() {
  const strip = S.awakePrompt
    ? awakeChoicesHTML()
    : `<div class="dk-icons">${[...dockPinned(), 'allTools'].map((id) => toolButtonHTML(id)).join('')}</div>`;
  return `<div class="dk-hint" aria-hidden="${S.awakePrompt ? 'false' : 'true'}">${esc(hintText())}</div><div class="dk-strip">${strip}</div>`;
}

function renderDock() {
  const dk = $('.isl-dock', root);
  if (!dk) return;
  dk.hidden = !settings.toolDock;
  if (settings.toolDock) dk.innerHTML = dockHTML();
}

function setHint() {
  const text = hintText();
  for (const el of $$('.dk-hint', root)) el.textContent = text;
}

function activateTool(id) {
  const t = TOOLS[id];
  if (id === 'keepAwake') {
    // On: turn it off. Off: ask for how long, right there, instead of silently meaning "until turned off".
    if (keepAwake.on) keepAwake.set(null, { quiet: true });
    else S.awakePrompt = true;
    refreshTools();
    return;
  }
  if (id === 'privacyShield') {
    island.mute();
    setSetting('shieldOn', !settings.shieldOn);
    refreshTools();
    return;
  }
  if (t.page) {
    openPage(t.page, id === 'uninstall' ? { tab: 'uninstall' } : id === 'cleaner' ? { tab: 'system' } : undefined);
    return;
  }
  // Anything else closes the island first: a capture must not start with the open island in the picture.
  close({ suppress: true });
  setTimeout(() => runTool(id), 140);
}

async function quickClean() {
  notify({ icon: 'sparkles', title: 'Scanning for junk…', tint: 'purple', duration: 1800 });
  await cleaner.scan('system');
  if (!cleaner.selectedSize('system')) { notify({ icon: 'check', title: 'Nothing to clean', subtitle: 'Your Mac is clean.', tint: 'green' }); return; }
  await cleaner.clean('system');
}

function runTool(id) {
  const t = TOOLS[id];
  if (t.action) runAction(t.action);
  else if (t.run === 'quickClean') quickClean();
  else if (t.run === 'boost') boost();
  else if (t.run === 'quit') runAction('quit');
}

/** The tools that are switches changed (or the dock layout did): redraw what shows them. */
function refreshTools() {
  if (!S.open) return;
  renderDock();
  if (S.page === 'tools') renderToolsPage();
  setHint();
}

function toolMenuItems(id) {
  const items = [];
  if (id === 'keepAwake') items.push(...keepAwakeMenuItems(), { separator: true });
  if (id === 'privacyShield') items.push({ label: 'Privacy Shield Settings…', action: () => runAction('settings', 'privacy') }, { separator: true });
  return items;
}

function onContextMenu(e) {
  const b = e.target.closest?.('[data-tool]');
  if (!b || !S.open) return;
  e.preventDefault();
  const id = b.dataset.tool;
  const onDock = b.closest('.dk-icons, .tp-icons');
  const items = toolMenuItems(id);
  if (onDock && dockLayout.contains(id)) {
    items.push(
      { label: 'Move Left', disabled: !dockLayout.canMove(id, -1), action: () => { dockLayout.moveBy(id, -1); refreshTools(); } },
      { label: 'Move Right', disabled: !dockLayout.canMove(id, 1), action: () => { dockLayout.moveBy(id, 1); refreshTools(); } },
      { label: 'Remove from Dock', action: () => { dockLayout.unpin(id); refreshTools(); } },
      { separator: true },
    );
  }
  if (onDock) items.push({ label: 'Edit Dock…', action: () => { S.editing = true; bus.emit('tour', 'dock-edit'); openPage('tools'); } });
  while (items.at(-1)?.separator) items.pop();
  if (items.length) showContextMenu(e.clientX, e.clientY, items);
}

// ---------------------------------------------------------------- the Tools page

function toolsPageHTML() {
  const col = (groups) => `<div class="tp-col">${groups.map((g) => `<div class="tp-group"><h4>${g.title}</h4><div class="tp-tiles">${g.tools.map(tileHTML).join('')}</div></div>`).join('')}</div>`;
  return `<div class="tp-grid">${col([TOOL_GROUPS[0], TOOL_GROUPS[2]])}${col([TOOL_GROUPS[1], TOOL_GROUPS[3]])}</div><div class="tp-strip"></div>`;
}

function tileHTML(id) {
  const t = TOOLS[id];
  const pinned = dockLayout.contains(id);
  const unavailable = S.editing && !pinned && dockIsFull();
  const on = toolOn(id);
  const sc = t.shortcut ? shortcutText(t.shortcut) : '';
  const badge = S.editing && !unavailable ? `<i class="tp-badge ${pinned ? 'is-on' : ''}">${icon(pinned ? 'check' : 'plus')}</i>` : '';
  return `<button type="button" class="tp-tile ${unavailable ? 'is-unavailable' : ''}" data-act="tool" data-tool="${id}" aria-label="${esc(t.title)}"${S.editing ? ` aria-pressed="${pinned}"` : on != null ? ` aria-pressed="${on}"` : ''} title="${esc(sc ? `${t.detail} (${sc})` : t.detail)}">
    <span class="tool ${on === false ? 'is-off' : ''}" style="--tint:${t.tint}">${icon(t.icon)}${badge}</span><span class="tp-name">${esc(t.title)}</span></button>`;
}

function stripHTML() {
  if (S.awakePrompt) return `<div class="tp-ask"><div class="tp-cap">Keep the Mac awake for</div>${awakeChoicesHTML()}</div>`;
  const pinned = dockPinned();
  const dragged = S.drag?.id;
  const icons = pinned.map((id) => {
    const t = TOOLS[id];
    const on = toolOn(id);
    const minus = S.editing && id !== dragged ? `<i class="tp-badge minus">${icon('minus')}</i>` : '';
    return `<span class="tool tp-pin ${on === false ? 'is-off' : ''} ${dragged === id ? 'is-gap' : ''}" data-tool="${id}" data-pin="${id}" style="--tint:${t.tint}" role="img" aria-label="${esc(t.title)}" title="${esc(t.title)}">${icon(t.icon)}${minus}</span>`;
  }).join('');
  const ghost = S.drag ? `<span class="tool tp-pin tp-ghost" style="--tint:${TOOLS[S.drag.id].tint};transform:translateX(${S.drag.x}px)" aria-hidden="true">${icon(TOOLS[S.drag.id].icon)}</span>` : '';
  const caption = !S.editing ? 'Dock' : dockIsFull() ? 'The dock is full. Click a tool on it to take it off, or drag to reorder.' : 'Click a tool to put it on the dock or take it off. Drag the icons here to reorder.';
  const buttons = S.editing
    ? `<button type="button" class="strip-btn" data-act="dock-reset" ${dockIsDefault() ? 'disabled' : ''}>Reset</button><button type="button" class="strip-btn is-prominent" data-act="dock-done">Done</button>`
    : `<button type="button" class="strip-btn" data-act="dock-edit">Edit</button>`;
  return `<div class="tp-cap ${S.editing ? 'is-edit' : ''} tp-hint-line">${esc(caption)}</div>
    <div class="tp-row"><div class="tp-icons" style="--slot:${SLOT}px">${icons}<span class="tool tp-pin is-all" title="All Tools is always the last icon on the dock" role="img" aria-label="All Tools" style="--tint:${TOOLS.allTools.tint}">${icon('grid')}</span>${ghost}</div><span class="grow"></span>${buttons}</div>`;
}

function renderToolsPage() {
  const body = $('.isl-page-body', root);
  const grid = $('.tp-grid', body);
  if (!grid) return;
  const scroll = grid.scrollTop;
  const tmp = document.createElement('div');
  tmp.innerHTML = toolsPageHTML();
  grid.replaceWith(tmp.firstElementChild);
  renderToolsStrip();
  $('.tp-grid', body).scrollTop = scroll;
}

function renderToolsStrip() {
  const strip = $('.tp-strip', root);
  if (!strip) return;
  strip.classList.toggle('is-edit', S.editing);
  strip.innerHTML = stripHTML();
}

function mountTools(body) {
  body.innerHTML = `<div class="tp">${toolsPageHTML()}</div>`;
  renderToolsStrip();
  let drag = null;
  const down = (e) => {
    const pin = e.target.closest?.('.tp-pin[data-pin]');
    if (!pin || !S.editing || e.button !== 0) return;
    const list = dockPinned();
    drag = { id: pin.dataset.pin, start: list.indexOf(pin.dataset.pin), x0: e.clientX, moved: false, pointerId: e.pointerId };
    body.setPointerCapture(e.pointerId);
  };
  const move = (e) => {
    if (!drag || e.pointerId !== drag.pointerId) return;
    const dx = e.clientX - drag.x0;
    if (!drag.moved && Math.abs(dx) < 3) return;
    drag.moved = true;
    const n = dockPinned().length;
    const target = clamp(drag.start + Math.round(dx / SLOT), 0, n - 1);
    if (target !== dockPinned().indexOf(drag.id)) dockLayout.moveTo(drag.id, target);
    S.drag = { id: drag.id, x: clamp(drag.start * SLOT + dx, -8, (n - 1) * SLOT + 8) };
    renderToolsStrip();
  };
  const up = (e) => {
    if (!drag || e.pointerId !== drag.pointerId) return;
    const d = drag;
    drag = null;
    try { body.releasePointerCapture(e.pointerId); } catch { /* already released */ }
    S.drag = null;
    if (!d.moved) { dockLayout.unpin(d.id); renderToolsPage(); setHint(); renderDock(); return; }
    renderToolsStrip();
  };
  body.addEventListener('pointerdown', down);
  body.addEventListener('pointermove', move);
  body.addEventListener('pointerup', up);
  body.addEventListener('pointercancel', up);
  return () => { S.editing = false; S.awakePrompt = false; S.drag = null; };
}

registerPage('tools', { mount: mountTools });

// ---------------------------------------------------------------- rendering

function timerRing(size, stroke) {
  const r = (size - stroke) / 2;
  const c = 2 * Math.PI * r;
  const frac = S.timer.total ? 1 - S.timer.remaining / S.timer.total : 0;
  return `<svg class="ring" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}" aria-hidden="true">
    <circle cx="${size / 2}" cy="${size / 2}" r="${r}" stroke-width="${stroke}" class="ring-bg"/>
    <circle cx="${size / 2}" cy="${size / 2}" r="${r}" stroke-width="${stroke}" class="ring-fg ${S.timer.mode === 'break' ? 'is-break' : ''}"
      stroke-dasharray="${c}" stroke-dashoffset="${c * (1 - frac)}" transform="rotate(-90 ${size / 2} ${size / 2})"/>
  </svg>`;
}

function renderClosed() {
  const t = track();
  const left = $('.isl-wing-left', root);
  const right = $('.isl-wing-right', root);
  if (S.timer.mode) {
    left.innerHTML = S.playing ? `<img class="disc" src="${arts[S.track]}" alt="">` : `<span class="wing-ring">${timerRing(20, 3)}</span>`;
    right.innerHTML = `<span class="wing-timer ${S.timer.mode === 'break' ? 'is-break' : ''}">${S.playing ? timerRing(16, 2.5) : ''}<b>${formatClock(S.timer.remaining)}</b></span>`;
  } else if (S.playing) {
    left.innerHTML = `<img class="disc" src="${arts[S.track]}" alt="">`;
    right.innerHTML = `<span class="eq" style="--eq:${t.tint}"><i></i><i></i><i></i><i></i></span>`;
  } else if (aiWorking()) {
    left.innerHTML = `<span class="wing-ai">${icon('sparkles')}</span>`;
    right.innerHTML = '<span class="ai-dot"></span>';
  } else if (keepAwake.on) {
    left.innerHTML = `<span class="wing-awake">${icon('mug')}</span>`;
    right.innerHTML = `<span class="wing-awake-time">${keepAwake.shortText()}</span>`;
  } else {
    left.innerHTML = `<img class="disc" src="${arts[S.track]}" alt="">`;
    right.innerHTML = `<span class="eq" style="--eq:${t.tint}"><i></i><i></i><i></i><i></i></span>`;
  }
}

function renderAlert() {
  const a = S.alert;
  const box = $('.isl-alert', root);
  if (!a) return;
  box.className = `isl-alert tint-${a.tint ?? 'accent'}`;
  box.innerHTML = `<span class="al-left">${icon(a.icon)}</span>
    <span class="al-right">${a.accessory ? `<b>${esc(a.accessory)}</b>` : ''}</span>
    <span class="al-text"><b>${esc(a.title)}</b>${a.subtitle ? `<span>${esc(a.subtitle)}</span>` : ''}</span>`;
}

function tabsAvailable() {
  const tabs = [['music', 'music', 'Now Playing']];
  if (settings.timerWidget || settings.calendarWidget || settings.speedWidget) tabs.push(['widgets', 'grid', 'Widgets']);
  if (settings.aiAgents) tabs.push(['ai', 'sparkles', 'AI']);
  tabs.push(['shelf', 'tray', 'Shelf', S.shelf.length]);
  return tabs;
}

function tabsHTML() {
  const tabs = tabsAvailable();
  if (!tabs.some(([id]) => id === S.tab)) S.tab = 'music';
  const compact = tabs.length > 2;
  // Beside a notch the tabs sit either side of it; without one they share the row.
  const leftCount = settings.notch ? Math.ceil(tabs.length / 2) : tabs.length;
  const btn = ([id, ic, label, count]) => `<button type="button" role="tab" class="isl-tab ${id === S.tab ? 'on' : ''}" data-act="tab" data-tab="${id}" aria-selected="${id === S.tab}" aria-label="${esc(label)}" title="${esc(label)}">${icon(ic)}${count ? `<b>${count}</b>` : ''}${compact ? '' : `<span>${esc(label)}</span>`}</button>`;
  return `<div class="isl-tabs" role="tablist">${tabs.slice(0, leftCount).map(btn).join('')}</div><span class="isl-gap"></span><div class="isl-tabs" role="tablist">${tabs.slice(leftCount).map(btn).join('')}</div>`;
}

function renderHome() {
  $('.isl-head', root).innerHTML = tabsHTML();
  const body = $('.isl-body', root);
  if (S.tab === 'music') body.innerHTML = musicPanel();
  else if (S.tab === 'widgets') body.innerHTML = widgetsPanel();
  else if (S.tab === 'ai') body.innerHTML = aiPanel();
  else body.innerHTML = shelfPanel();
  renderDock();
  updateProgress();
}

function renderOpen() {
  const home = $('.isl-home', root);
  const page = $('.isl-page', root);
  home.hidden = !!S.page;
  page.hidden = !S.page;
  if (S.page) renderPageView(); else renderHome();
}

function renderPageView() {
  disposePage();
  const spec = PAGES[S.page];
  const head = $('.isl-page-head', root);
  const body = $('.isl-page-body', root);
  const back = S.backPage ? PAGES[S.backPage].title : '';
  const tools = S.page === 'tools'
    ? `<button type="button" class="isl-round" data-act="page-settings" aria-label="Settings" title="Settings">${icon('gear')}</button><button type="button" class="isl-round" data-act="page-quit" aria-label="Quit Zenith" title="Quit Zenith">${icon('power')}</button>`
    : '';
  head.innerHTML = `<button type="button" class="isl-back" data-act="page-back" aria-label="${back ? `Back to ${esc(back)}` : 'Back'}">${icon('back')}${back ? `<span>${esc(back)}</span>` : ''}</button>
    <span class="grow"></span><span class="isl-page-title">${icon(spec.icon)}${esc(spec.title)}</span>${tools}<button type="button" class="isl-round" data-act="page-close" aria-label="Close" title="Close">${icon('x')}</button>`;
  body.className = `isl-page-body page-${S.page}`;
  body.scrollTop = 0;
  body.innerHTML = '';
  pageDispose = pageSpecs[S.page]?.mount(body, S.pageArg) ?? null;
}

function musicPanel() {
  const t = track();
  return `<div class="np">
    <img class="np-art" src="${arts[S.track]}" alt="">
    <div class="np-main">
      <div class="np-top">
        <div class="np-meta"><b>${esc(t.title)}</b><span>${esc([t.artist, t.album].filter(Boolean).join(' · '))}</span></div>
        <span class="np-app" style="--tint:${t.tint}">${icon('music')}${esc(t.app === 'Music' ? 'Apple Music' : t.app)}</span>
      </div>
      <div class="np-bar ${t.canSeek ? '' : 'no-seek'}" data-act="seek" role="slider" tabindex="0" aria-label="Position" aria-valuemin="0" aria-valuemax="${t.duration}">
        <span class="np-fill" style="--tint:${t.tint}"></span>
      </div>
      <div class="np-controls">
        <span class="np-time np-pos">0:00</span>
        <span class="np-buttons">
          <button type="button" class="np-btn" data-act="prev" ${t.canSkip ? '' : 'disabled'} aria-label="Previous">${icon('prev')}</button>
          <button type="button" class="np-btn np-play" data-act="play" aria-label="${S.playing ? 'Pause' : 'Play'}">${icon(S.playing ? 'pause' : 'play')}</button>
          <button type="button" class="np-btn" data-act="next" ${t.canSkip ? '' : 'disabled'} aria-label="Next">${icon('next')}</button>
        </span>
        <span class="np-time np-dur">${formatClock(t.duration)}</span>
      </div>
    </div>
  </div>`;
}

function widgetsPanel() {
  const cards = [];
  if (settings.timerWidget) {
    if (S.timer.mode) {
      cards.push(`<div class="wcard wcard-timer">
        <span class="wt-ring">${timerRing(40, 4)}${icon('timer')}</span>
        <span class="wt-text"><b class="wt-time">${formatClock(S.timer.remaining)}</b><span>${S.timer.mode === 'break' ? 'Break' : 'Focus'}${S.timer.paused ? ' · paused' : ''}</span></span>
        <button type="button" class="wbtn wbtn-orange" data-act="timer-pause" aria-label="${S.timer.paused ? 'Resume' : 'Pause'}">${icon(S.timer.paused ? 'play' : 'pause')}</button>
        <button type="button" class="wbtn" data-act="timer-stop" aria-label="Stop">${icon('stop')}</button>
      </div>`);
    } else {
      cards.push(`<div class="wcard wcard-timer">
        <span class="wt-ring">${timerRing(40, 4)}${icon('timer')}</span>
        <span class="wt-text"><b>Focus</b><span>${settings.focusMinutes} min · break ${settings.breakMinutes} min</span></span>
        <button type="button" class="wbtn wbtn-orange" data-act="timer-focus" aria-label="Start focus">${icon('play')}</button>
        <button type="button" class="wbtn wbtn-text" data-act="timer-break">Break</button>
      </div>`);
    }
  }
  if (settings.calendarWidget) {
    if (settings.calendarAccess === 'granted') {
      const mins = Math.max(0, Math.round((S.eventAt - Date.now()) / 60000));
      cards.push(`<div class="wcard wcard-event"><span class="ev-bar"></span><span class="wt-text"><b>Design review</b><span class="ev-when">${mins > 0 ? `In ${mins} min` : 'Now'}</span></span></div>`);
    } else {
      cards.push(`<div class="wcard wcard-event"><span class="ev-bar off"></span><span class="wt-text"><b>No access</b><span>Allow Calendars in Settings</span></span></div>`);
    }
  }
  if (settings.speedWidget) {
    cards.push(`<div class="wcard wcard-speed"><span>${icon('download')}<b class="sp-down">${formatBytes(S.speed.down)}/s</b></span><span>${icon('download', 'ic flip')}<b class="sp-up">${formatBytes(S.speed.up)}/s</b></span></div>`);
  }
  return `<div class="widgets">${cards.join('')}</div>`;
}

function aiPanel() {
  return `<div class="ai-cards">
    <div class="aicard"><b>${icon('sparkles')}Claude Code<i class="ai-dot"></i></b><span class="is-working">Working · example-app</span><span>Today 10M · Session 3.2M</span></div>
    <div class="aicard"><b>${icon('code')}Codex</b><span>Idle · website</span><span>Today 2.3M · Session 778K</span></div>
  </div>`;
}

function shelfPanel() {
  if (!S.shelf.length) {
    return `<div class="shelf-empty">${icon('tray')}<b>Drop files here to stage</b></div>`;
  }
  return `<div class="shelf">${S.shelf.map((it) => `
    <div class="shelf-item" data-id="${it.id}">
      <button type="button" class="shelf-tile" data-act="ql" data-id="${it.id}" aria-label="Preview ${esc(it.name)}">
        ${it.kind === 'photo' && it.url ? `<img src="${it.url}" alt="">` : `<span class="shelf-ic k-${it.kind}">${icon(it.kind === 'app' ? 'brush' : it.kind)}</span>`}
        <span class="shelf-name">${esc(it.name)}</span>
        <span class="shelf-size">${formatBytes(it.size)}</span>
      </button>
      <button type="button" class="shelf-x" data-act="remove" data-id="${it.id}" aria-label="Remove ${esc(it.name)} from the shelf">${icon('x')}</button>
      ${it.isApp ? `<span class="shelf-actions">
        <button type="button" class="wbtn wbtn-text danger" data-act="uninstall" data-id="${it.id}">Deep Uninstall</button>
        <button type="button" class="wbtn wbtn-text" data-act="slim" data-id="${it.id}" ${it.slimmed ? 'disabled' : ''}>${it.slimmed ? 'Slimmed' : 'Slim'}</button>
      </span>` : ''}
    </div>`).join('')}</div>`;
}

function updateProgress() {
  if (!S.open || S.page || S.tab !== 'music') return;
  const t = track();
  const fill = $('.np-fill', root);
  if (!fill) return;
  fill.style.width = `${(S.position / t.duration) * 100}%`;
  $('.np-pos', root).textContent = formatClock(S.position);
  $('.np-bar', root).setAttribute('aria-valuenow', String(S.position));
}

function render() {
  renderClosed();
  // A page keeps what it shows (scroll, a field being typed in) while settings change under it.
  if (S.open && !S.page) renderHome();
  layout();
}

// ---------------------------------------------------------------- ticking

function tick() {
  if (S.playing) {
    S.position += 1;
    if (S.position >= track().duration) {
      if (track().canSkip) nextTrack(); else { S.position = 0; S.playing = false; render(); }
    }
  }
  if (S.timer.mode && !S.timer.paused) {
    S.timer.remaining -= 1;
    if (S.timer.remaining <= 0) {
      const was = S.timer.mode;
      if (was === 'focus') S.sessions += 1;
      stopTimer();
      notify({ icon: 'timer', title: was === 'focus' ? 'Focus session done' : 'Break is over', subtitle: was === 'focus' ? 'Time for a break.' : 'Ready when you are.', tint: 'orange', duration: 4000 });
      playSound('Hero', { force: settings.soundsOn });
    }
    bus.emit('timer');
  }
  if (S.open && !S.page && S.tab === 'widgets' && settings.speedWidget) {
    S.speed.down = clamp(S.speed.down * (0.75 + Math.random() * 0.5), 2e5, 9e6);
    S.speed.up = clamp(S.speed.up * (0.7 + Math.random() * 0.6), 2e4, 9e5);
  }
  // Only the parts that change, so the open page does not flicker.
  if (S.timer.mode || S.playing || keepAwake.on) renderClosed();
  if (S.open && !S.page && S.tab === 'music') updateProgress();
  if (S.open && !S.page && S.tab === 'widgets') {
    const time = $('.wt-time', root);
    if (time) time.textContent = formatClock(S.timer.remaining);
    const ring = $('.wcard-timer .wt-ring', root);
    if (ring && S.timer.mode) ring.innerHTML = `${timerRing(40, 4)}${icon('timer')}`;
    const down = $('.sp-down', root);
    if (down) { down.textContent = `${formatBytes(S.speed.down)}/s`; $('.sp-up', root).textContent = `${formatBytes(S.speed.up)}/s`; }
    const when = $('.ev-when', root);
    if (when) { const m = Math.max(0, Math.round((S.eventAt - Date.now()) / 60000)); when.textContent = m > 0 ? `In ${m} min` : 'Now'; }
  }
  if (S.hintTool === 'keepAwake' && keepAwake.on) setHint();
}

// ---------------------------------------------------------------- setup

export function initIsland() {
  root = $('#island');
  root.innerHTML = `
    <div class="isl-shape" tabindex="0" role="button" aria-label="Zenith island" aria-expanded="false">
      <div class="isl-closed"><span class="isl-wing-left"></span><span class="isl-wing-right"></span></div>
      <div class="isl-alert"></div>
      <div class="isl-open">
        <div class="isl-home"><div class="isl-head"></div><div class="isl-body"></div><div class="isl-dock"></div></div>
        <div class="isl-page" hidden><div class="isl-page-head"></div><div class="isl-page-body"></div></div>
      </div>
      <div class="isl-drop">${icon('tray')}<span>Drop to keep it on the shelf</span></div>
    </div>`;
  shape = $('.isl-shape', root);

  shape.addEventListener('pointerenter', (e) => { if (e.pointerType === 'mouse') pointerEntered(); });
  shape.addEventListener('pointerleave', (e) => { if (e.pointerType === 'mouse') pointerLeft(); });
  shape.addEventListener('wheel', onWheel, { passive: false });
  shape.addEventListener('click', (e) => {
    if (e.target.closest?.('[data-act]')) return;
    if (!S.open) { open(); bus.emit('tour', 'island-hover'); }
  });
  shape.addEventListener('keydown', (e) => {
    if (e.target !== shape) return;
    if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); S.open ? close() : open(); }
  });
  // Escape closes the island; a dialog or a menu over it takes the key first.
  document.addEventListener('keydown', (e) => {
    if (e.key !== 'Escape' || e.defaultPrevented || !S.open || $('.scrim') || menuIsOpen()) return;
    if (e.target.closest?.('.recorder, .hub')) return;
    close({ suppress: true });
  });
  // A click anywhere else closes it. Dialogs, menus and the hub are not "elsewhere".
  document.addEventListener('pointerdown', (e) => {
    if (S.open && !shape.contains(e.target) && !e.target.closest?.('.scrim, .menu, .hub, .toast') && (e.pointerType !== 'mouse' || !S.hover || S.page)) close();
  });

  root.addEventListener('contextmenu', onContextMenu);
  root.addEventListener('pointerover', (e) => {
    const b = e.target.closest?.('[data-tool], .tp-pin');
    if (!b) return;
    S.hintTool = b.dataset.tool ?? (b.classList.contains('is-all') ? 'allTools' : null);
    setHint();
  });
  root.addEventListener('pointerout', (e) => {
    const b = e.target.closest?.('[data-tool], .tp-pin');
    if (!b || b.contains(e.relatedTarget)) return;
    S.hintTool = null;
    setHint();
  });
  root.addEventListener('focusin', (e) => {
    const b = e.target.closest?.('.dk-icons [data-tool]');
    if (b) { S.hintTool = b.dataset.tool; setHint(); }
  });

  root.addEventListener('click', (e) => {
    const b = e.target.closest?.('[data-act]');
    if (!b) return;
    const act = b.dataset.act;
    const id = Number(b.dataset.id);
    const item = S.shelf.find((x) => x.id === id);
    if (act === 'tab') { S.tab = b.dataset.tab; renderHome(); }
    if (act === 'play') togglePlay();
    if (act === 'next') nextTrack();
    if (act === 'prev') previousTrack();
    if (act === 'timer-focus') startTimer('focus');
    if (act === 'timer-break') startTimer('break');
    if (act === 'timer-pause') toggleTimerPause();
    if (act === 'timer-stop') stopTimer();
    if (act === 'ql' && item) quickLook(item);
    if (act === 'remove') removeShelfItem(id);
    if (act === 'uninstall' && item) uninstallApp(item);
    if (act === 'slim' && item) slimApp(item);
    if (act === 'tool') {
      // On the Tools page a click in edit mode puts the tool on the dock or takes it off.
      if (S.editing && b.classList.contains('tp-tile')) { dockLayout.toggle(b.dataset.tool); renderToolsPage(); renderDock(); return; }
      activateTool(b.dataset.tool);
    }
    if (act === 'awake') {
      keepAwake.set(b.dataset.min === 'inf' ? Infinity : Number(b.dataset.min), { quiet: true });
      S.awakePrompt = false;
      refreshTools();
    }
    if (act === 'awake-cancel') { S.awakePrompt = false; refreshTools(); }
    if (act === 'page-back') closePage();
    if (act === 'page-close') close({ suppress: true });
    if (act === 'page-settings') openPage('settings');
    if (act === 'page-quit') { close({ suppress: true }); runAction('quit'); }
    if (act === 'dock-edit') { S.editing = true; bus.emit('tour', 'dock-edit'); renderToolsPage(); }
    if (act === 'dock-done') { S.editing = false; renderToolsPage(); }
    if (act === 'dock-reset') { dockLayout.reset(); renderToolsPage(); renderDock(); }
  });

  // Seeking: drag along the progress bar.
  root.addEventListener('pointerdown', (e) => {
    const bar = e.target.closest?.('.np-bar');
    if (!bar || !track().canSeek) return;
    bar.setPointerCapture(e.pointerId);
    const at = (ev) => { const r = bar.getBoundingClientRect(); seek((ev.clientX - r.left) / r.width); };
    at(e);
    const up = () => { bar.removeEventListener('pointermove', at); bar.removeEventListener('pointerup', up); };
    bar.addEventListener('pointermove', at);
    bar.addEventListener('pointerup', up);
  });
  root.addEventListener('keydown', (e) => {
    if (!e.target.closest?.('.np-bar')) return;
    if (e.key === 'ArrowRight') { seek((S.position + 10) / track().duration); e.preventDefault(); }
    if (e.key === 'ArrowLeft') { seek((S.position - 10) / track().duration); e.preventDefault(); }
  });

  // Drop shelf: anything dragged to the top of the screen.
  const isShelfDrag = (dt) => dt && Array.from(dt.types).some((t) => t === 'Files' || t === 'application/x-zenith-app' || t === 'text/plain');
  document.addEventListener('dragover', (e) => {
    if (!isShelfDrag(e.dataTransfer)) return;
    e.preventDefault();
    const near = e.clientY < 150 && Math.abs(e.clientX - window.innerWidth / 2) < 320;
    if (near && visible() && !S.dropping) { S.dropping = true; open('shelf'); }
    if (!near && S.dropping && !shape.contains(e.target)) { S.dropping = false; close(); }
  });
  document.addEventListener('dragleave', (e) => {
    if (e.relatedTarget == null && S.dropping) { S.dropping = false; close(); }
  });
  document.addEventListener('drop', async (e) => {
    if (!isShelfDrag(e.dataTransfer)) return;
    e.preventDefault();
    const wasDropping = S.dropping;
    S.dropping = false;
    if (!wasDropping && !shape.contains(e.target)) { layout(); return; }
    const items = await itemsFromDrop(e.dataTransfer);
    if (items.length) addShelfItems(items); else layout();
  });

  setNoticeHandler((n) => showAlert(n));
  ['islandEnabled', 'notch', 'hideInFullScreen', 'timerWidget', 'calendarWidget', 'calendarAccess', 'speedWidget', 'focusMinutes', 'breakMinutes', 'aiAgents', 'toolDock', 'dockLayout'].forEach((k) => bus.on(`setting:${k}`, render));
  bus.on('setting:shieldOn', () => refreshTools());
  bus.on('keep-awake', () => { renderClosed(); layout(); refreshTools(); });
  bus.on('fullscreen', () => { if (anyFullScreen() && settings.hideInFullScreen) close(); layout(); });
  bus.on('windows', layout);
  bus.on('zenith-running', () => { if (!app.running) close(); layout(); });
  window.addEventListener('resize', layout);

  render();
  setInterval(tick, 1000);
}
