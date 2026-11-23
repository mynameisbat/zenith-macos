// Clipboard history (a docked strip of preview cards, filters, keyboard), copies made on this page, the ignored-app and concealed rules,
// auto-clear, clean links, and text snippets.
import {
  $, $$, bus, esc, icon, html, settings, notify, registerAction, runAction, frontWindow, windowSpec, store,
  showContextMenu, playSound, formatBytes, isMac, shortcutText, closeMenus, isNarrow, codeOf,
} from './core.js';
import { seedClipboard, sampleCardImage, cleanLink, webHost, SNIPPETS } from './data.js';
import { scratchpad } from './desktop.js';

// ---------------------------------------------------------------- the history

let nextId = 1;
const withIds = (list) => list.map((it) => ({ id: nextId++, pinned: false, ...it }));
let items = [];

function loadItems() {
  const saved = store.get('clipboard', null);
  if (saved) {
    items = withIds(saved.map(({ id, ...rest }) => rest));
  } else {
    const c = sampleCardImage(640, 360);
    items = withIds(seedClipboard(c.toDataURL('image/jpeg', 0.85)).map((i) => (i.kind === 'image' ? { ...i, seed: true } : i)));
  }
}

function save() {
  // Images from captures are large; keep the seed picture and text only.
  store.set('clipboard', items.filter((i) => i.kind !== 'image' || i.seed).map(({ id, ...rest }) => rest));
}

function kindOf(text) {
  if (webHost(text)) return 'link';
  if (/^#(?:[0-9a-f]{3}|[0-9a-f]{6})$/i.test(text.trim())) return 'color';
  return 'text';
}

export const clipboardStore = {
  get items() { return items; },
  clearUnpinned() { items = items.filter((i) => i.pinned); save(); render(); },
  add,
};

function add(item) {
  const existing = item.kind !== 'image' ? items.find((i) => i.kind === item.kind && i.text === item.text) : null;
  if (existing) {
    existing.at = Date.now();
    items = [existing, ...items.filter((i) => i !== existing)];
  } else {
    items.unshift({ id: nextId++, pinned: false, at: Date.now(), ...item });
  }
  // Bounded like the app: unpinned items beyond the limit go first.
  while (items.length > settings.historyLimit) {
    const victim = [...items].reverse().find((i) => !i.pinned);
    if (!victim) break;
    items = items.filter((i) => i !== victim);
  }
  save();
  if (panel) render();
}

// ---------------------------------------------------------------- the system clipboard of the pretend Mac, and auto-clear

let pasteboard = null;
let clearTimer = 0;

function setPasteboard(text, label = text) {
  pasteboard = { text, label, at: Date.now() };
  scheduleClear();
  updateFoot();
}

function scheduleClear() {
  clearTimeout(clearTimer);
  if (!pasteboard || !settings.clearAfter) return;
  const mine = pasteboard;
  clearTimer = setTimeout(() => {
    if (pasteboard !== mine) return;
    pasteboard = null;
    updateFoot();
    notify({ icon: 'clipboard', title: 'Clipboard emptied', subtitle: 'The history still has the item.' });
  }, settings.clearAfter * 1000);
}

bus.on('setting:clearAfter', scheduleClear);
bus.on('lock', () => {
  if (!settings.clearOnLock || !pasteboard) return;
  pasteboard = null;
  updateFoot();
  const off = bus.on('unlock', () => {
    off();
    notify({ icon: 'lock', title: 'Clipboard emptied when the Mac locked', subtitle: 'The history still has the item.' });
  });
});

export function currentPasteboardText() { return pasteboard?.text ?? ''; }

// ---------------------------------------------------------------- copies

function appForNode(node) {
  const el = node?.nodeType === 1 ? node : node?.parentElement;
  const win = el?.closest?.('.win');
  return win?.dataset.app ?? 'Finder';
}

function selectedText() {
  const a = document.activeElement;
  if (a && (a.tagName === 'TEXTAREA' || (a.tagName === 'INPUT' && /text|search|url/.test(a.type)))) {
    return a.value.slice(a.selectionStart, a.selectionEnd);
  }
  return String(window.getSelection() ?? '');
}

function onDocumentCopy(e) {
  let text = selectedText();
  if (!text.trim()) return;
  const sel = window.getSelection();
  const app = appForNode(document.activeElement?.closest('.win') ? document.activeElement : sel?.anchorNode);
  if (settings.cleanLinksOnCopy && !settings.ignoredApps.includes(app)) {
    const c = cleanLink(text);
    if (c.removed && webHost(text)) {
      e.clipboardData.setData('text/plain', c.url);
      e.preventDefault();
      text = c.url;
      notify({ icon: 'link', title: 'Link cleaned as you copied it', subtitle: c.removed === 1 ? 'Removed 1 tracking parameter' : `Removed ${c.removed} tracking parameters`, tint: 'green' });
      bus.emit('tour', 'clean-link');
    }
  }
  bus.emit('copy', { text, app, fromPage: true });
}

bus.on('copy', ({ text, app, concealed }) => {
  setPasteboard(text, concealed ? '••••••••' : text);
  if (concealed) {
    notify({ icon: 'lock', title: 'Not kept in the history', subtitle: `${app} marked the copy as concealed.`, tint: 'plain' });
    bus.emit('tour', 'privacy-copy');
    return;
  }
  if (settings.ignoredApps.includes(app)) {
    notify({ icon: 'lock', title: 'Not kept in the history', subtitle: `Copied in ${app}, which is on your ignored list.`, tint: 'plain' });
    bus.emit('tour', 'privacy-copy');
    return;
  }
  add({ kind: kindOf(text), text, source: app });
  playSound('copy');
});

bus.on('copy-image', ({ img, w, h, size, label }) => {
  setPasteboard(label, label);
  add({ kind: 'image', text: label, img, w, h, size, source: 'Zenith' });
});

// ---------------------------------------------------------------- the panel
// A strip docked to the bottom of the screen: a search field and the filters on top, preview cards in a row, the keys and the
// Paste button under them. Left and right browse the cards (so they no longer move the caret in the search field).

let panel = null;
let filter = 'all';
let query = '';
let selectedId = null;
let pasteTarget = null;

const FILTERS = [['all', 'All'], ['text', 'Text'], ['link', 'Links'], ['image', 'Images'], ['pinned', 'Pinned']];

function matches(item) {
  if (filter === 'pinned' && !item.pinned) return false;
  if (filter === 'text' && !(item.kind === 'text' || item.kind === 'color')) return false;
  if (filter === 'link' && item.kind !== 'link') return false;
  if (filter === 'image' && item.kind !== 'image') return false;
  if (!query) return true;
  const hay = item.text.toLowerCase();
  const q = query.toLowerCase();
  if (hay.includes(q)) return true;
  let i = 0;
  for (const ch of hay) if (ch === q[i]) i++;
  return i === q.length && q.length > 2;
}

function visibleItems() { return items.filter(matches); }

/** A guess on top of the kind, like ClipboardItem.looksLikeCode: it never changes what the Text filter shows. */
function looksLikeCode(item) {
  if (item.kind !== 'text') return false;
  const t = item.text.trim();
  return /^(\$ |brew |swift |npm |pnpm |yarn |git |cd |ls |sudo |curl |python3? |node |\.\/)/.test(t) || /[{};]\s*$|=>|\(\)|<\/?[a-z]+>/.test(t);
}

const KIND_LABEL = { text: 'Text', link: 'Link', image: 'Image', color: 'Color', code: 'Code' };
const cardKind = (it) => (looksLikeCode(it) ? 'code' : it.kind);

/** Where a copy came from: an app icon in a small tile (a system app's, or the kind's symbol when the app is unknown). */
const SOURCE_APPS = {
  Notes: ['notes', '#f5c93a'], Terminal: ['code', '#1c1c1e'], Mail: ['doc', '#2f8cf5'], Safari: ['globe', '#2f8cf5'], Zenith: ['zenith', '#5856d6'],
  Scratchpad: ['notes', '#f5c93a'], 'Read Me': ['doc', '#8e8e93'], Finder: ['folder', '#2f8cf5'], 'Design Tool': ['brush', '#af52de'], 'Chat App': ['chat', '#34c759'], 'Code Editor': ['code', '#0a84ff'],
};
function sourceTile(it) {
  const [ic, color] = SOURCE_APPS[it.source] ?? [it.kind === 'link' ? 'link' : it.kind === 'image' ? 'photo' : it.kind === 'color' ? 'swatch' : 'lines', '#8e8e93'];
  return `<span class="cb-src" style="--c:${color}" title="${esc(it.source ?? '')}">${icon(ic)}</span>`;
}

/** "6 min ago", "3 h ago", "yesterday", "3 days ago" (ClipboardCardContent.relativeTime). */
function relativeTime(at) {
  const m = Math.floor((Date.now() - at) / 60000);
  if (m < 1) return 'just now';
  if (m < 60) return `${m} min ago`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h} h ago`;
  const d = Math.floor(h / 24);
  return d === 1 ? 'yesterday' : `${d} days ago`;
}

function linkParts(text) {
  try {
    const u = new URL(text.trim());
    return { host: u.hostname.replace(/^www\./, ''), path: `${u.pathname === '/' ? '' : u.pathname}${u.search}` };
  } catch { return { host: text.trim().slice(0, 40), path: '' }; }
}

function hexRGB(hex) {
  let h = hex.replace('#', '');
  if (h.length === 3) h = [...h].map((c) => c + c).join('');
  const n = parseInt(h, 16);
  return `${(n >> 16) & 255} ${(n >> 8) & 255} ${n & 255}`;
}

function cardBody(it) {
  if (it.kind === 'image') return `<div class="cb-pv cb-photo"><img src="${it.img}" alt="${esc(it.text)}"></div>`;
  if (it.kind === 'color') return `<div class="cb-pv cb-swatch-big" style="background:${esc(it.text)}"><b>${esc(it.text.toUpperCase())}</b></div>`;
  if (it.kind === 'link') {
    const { host, path } = linkParts(it.text);
    return `<div class="cb-pv cb-link"><span class="cb-link-ic">${icon('link')}</span><b>${esc(host)}</b><span>${esc(path)}</span></div>`;
  }
  return `<div class="cb-pv cb-text ${looksLikeCode(it) ? 'is-code' : ''}">${esc(it.text.slice(0, 600))}</div>`;
}

function cardMeta(it) {
  if (it.kind === 'image') return `${it.w} × ${it.h} · ${formatBytes(it.size ?? 0)}`;
  if (it.kind === 'color') return `RGB ${hexRGB(it.text)}`;
  if (it.kind === 'link') return linkParts(it.text).host;
  if (looksLikeCode(it)) { const n = it.text.split('\n').length; return n === 1 ? '1 line' : `${n} lines`; }
  const n = it.text.length;
  return n === 1 ? '1 character' : `${n.toLocaleString('en-GB')} characters`;
}

function pasteLabel(it) {
  if (it.kind === 'image') return it.text;
  const t = it.text.replace(/\s+/g, ' ').trim();
  return t.length > 16 ? `${t.slice(0, 14)}…` : t;
}

function render() {
  if (!panel) return;
  const list = visibleItems();
  if (!list.some((i) => i.id === selectedId)) selectedId = list[0]?.id ?? null;
  const strip = $('.cb-strip', panel);
  const scroll = strip.scrollLeft;
  strip.innerHTML = list.length
    ? list.map((it, i) => `<div class="cb-card ${it.id === selectedId ? 'sel' : ''}" role="option" id="cb-${it.id}" data-id="${it.id}" aria-selected="${it.id === selectedId}">
        <div class="cb-card-head">${sourceTile(it)}<span class="cb-ct"><b>${KIND_LABEL[cardKind(it)]}</b><span>${relativeTime(it.at)}</span></span>${it.pinned ? `<span class="cb-pin" aria-label="Pinned">${icon('pin')}</span>` : ''}</div>
        ${cardBody(it)}
        <div class="cb-card-foot"><span>${esc(cardMeta(it))}</span>${i < 9 ? `<span class="cb-key">⌘${i + 1}</span>` : ''}</div>
      </div>`).join('')
    : `<div class="cb-empty">${query ? `Nothing matches “${esc(query)}”.` : 'Nothing here yet.'}</div>`;
  strip.scrollLeft = scroll;
  $$('.cb-filter', panel).forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.filter === filter)));
  $('.cb-input', panel).setAttribute('aria-activedescendant', selectedId ? `cb-${selectedId}` : '');
  const it = items.find((i) => i.id === selectedId);
  const btn = $('[data-cb="paste"]', panel);
  btn.textContent = it ? `Paste “${pasteLabel(it)}”` : 'Paste';
  btn.disabled = !it;
  updateFoot();
  $(`#cb-${selectedId}`, panel)?.scrollIntoView({ block: 'nearest', inline: 'nearest' });
}

function updateFoot() {
  if (!panel) return;
  const list = visibleItems();
  $('.cb-count', panel).textContent = list.length === 1 ? '1 item' : `${list.length} items`;
  let pb = 'The clipboard is empty';
  if (pasteboard) {
    const label = pasteboard.label.replace(/\s+/g, ' ');
    pb = `On the clipboard: “${label.length > 26 ? `${label.slice(0, 26)}…` : label}”`;
    if (settings.clearAfter) {
      const left = Math.max(0, Math.round((pasteboard.at + settings.clearAfter * 1000 - Date.now()) / 1000));
      pb += ` · empties in ${left} s`;
    }
  }
  $('.cb-pb', panel).textContent = pb;
}

function select(delta) {
  const list = visibleItems();
  if (!list.length) return;
  const i = list.findIndex((x) => x.id === selectedId);
  selectedId = list[Math.max(0, Math.min(list.length - 1, (i < 0 ? 0 : i) + delta))].id;
  render();
}

function paste(item, variant = 'normal') {
  if (!item) return;
  let text = item.text;
  let note = '';
  if (variant === 'clean' || (variant === 'plain' && item.kind === 'link')) {
    const c = cleanLink(item.text);
    text = c.url;
    if (c.removed) { note = c.removed === 1 ? 'Without 1 tracking parameter' : `Without ${c.removed} tracking parameters`; bus.emit('tour', 'clean-link'); }
  } else if (variant === 'plain') {
    note = 'As plain text';
  }
  setPasteboard(text, item.kind === 'image' ? item.text : text);
  const target = pasteTarget;
  closePanel();
  playSound('paste');
  bus.emit('tour', 'clipboard');
  if (target === 'scratchpad') {
    if (item.kind === 'image') scratchpad.insertImage(item.img, item.text);
    else scratchpad.insert(text);
    notify({ icon: 'clipboard', title: 'Pasted into Scratchpad', subtitle: note || undefined });
    return;
  }
  if (item.kind !== 'image') navigator.clipboard?.writeText(text).catch(() => {});
  notify({ icon: 'clipboard', title: 'Copied', subtitle: `${note ? `${note}. ` : ''}Nothing to paste into here: click Scratchpad first, or press ⌘V where you like.` });
}

function togglePin(item) {
  item.pinned = !item.pinned;
  playSound('pin');
  save();
  render();
}

function remove(item) {
  items = items.filter((i) => i !== item);
  playSound('delete');
  save();
  render();
}

function onPanelKey(e) {
  const meta = isMac ? e.metaKey : (e.metaKey || e.ctrlKey);
  const item = items.find((i) => i.id === selectedId);
  if (e.key === 'Escape') { e.preventDefault(); closePanel(); return; }
  if (e.key === 'ArrowDown' || (e.ctrlKey && codeOf(e) === 'KeyN')) { e.preventDefault(); select(1); return; }
  if (e.key === 'ArrowUp' || (e.ctrlKey && codeOf(e) === 'KeyP')) { e.preventDefault(); select(-1); return; }
  // Left and right browse the cards; with ⌥, ⌘ or ⇧ they still move the caret in the search field.
  if ((e.key === 'ArrowRight' || e.key === 'ArrowLeft') && !e.altKey && !e.metaKey && !e.shiftKey) { e.preventDefault(); select(e.key === 'ArrowRight' ? 1 : -1); return; }
  if (e.key === 'Enter') { e.preventDefault(); paste(item, e.shiftKey ? 'plain' : 'normal'); return; }
  if (meta && /^Digit[1-9]$/.test(codeOf(e))) { e.preventDefault(); paste(visibleItems()[Number(codeOf(e).slice(5)) - 1]); return; }
  if (meta && codeOf(e) === 'KeyP' && item) { e.preventDefault(); togglePin(item); return; }
  if (meta && e.key === 'Backspace' && item) { e.preventDefault(); remove(item); }
}

function openPanel() {
  if (panel) { closePanel(); return; }
  const front = frontWindow();
  pasteTarget = front === 'scratchpad' ? 'scratchpad' : null;
  closeMenus();
  query = '';
  filter = 'all';
  selectedId = null;
  panel = html`<div class="scrim cb-scrim"><div class="cb-panel" role="dialog" aria-modal="true" aria-label="Clipboard history">
    <div class="cb-top">
      <div class="cb-search">${icon('search')}<input class="cb-input" type="text" placeholder="Search clipboard history" aria-label="Search clipboard history" role="combobox" aria-controls="cb-list" aria-expanded="true" autocomplete="off" spellcheck="false"></div>
      <div class="cb-filters" role="toolbar" aria-label="Filters">${FILTERS.map(([id, label]) => `<button type="button" class="cb-filter" data-filter="${id}" aria-pressed="false">${label}</button>`).join('')}</div>
      <span class="grow"></span><span class="cb-pb"></span><span class="cb-count"></span>
    </div>
    <div class="cb-strip" id="cb-list" role="listbox" aria-orientation="horizontal" aria-label="History"></div>
    <div class="cb-foot">
      <span class="cb-keys"><span><kbd>↵</kbd>Paste</span><span><kbd>⇧↵</kbd>Plain Text</span><span><kbd>⌘1–9</kbd>Quick Paste</span><span><kbd>←→</kbd>Browse</span><span><kbd>⌘P</kbd>Pin</span><span><kbd>⌘⌫</kbd>Delete</span><span><kbd>esc</kbd>Close</span></span>
      <button type="button" class="cb-paste" data-cb="paste">Paste</button>
    </div>
  </div></div>`;
  document.body.append(panel);
  const input = $('.cb-input', panel);
  input.addEventListener('input', () => { query = input.value; selectedId = null; render(); });
  input.addEventListener('keydown', onPanelKey);
  panel.addEventListener('click', (e) => {
    if (e.target === panel) { closePanel(); return; }
    const f = e.target.closest?.('[data-filter]');
    if (f) { filter = f.dataset.filter; selectedId = null; render(); input.focus(); return; }
    // A click selects a card, a double-click pastes it.
    const card = e.target.closest?.('.cb-card');
    if (card) { selectedId = Number(card.dataset.id); render(); input.focus(); return; }
    const act = e.target.closest?.('[data-cb]')?.dataset.cb;
    const item = items.find((i) => i.id === selectedId);
    if (act === 'paste') paste(item);
  });
  panel.addEventListener('dblclick', (e) => {
    const card = e.target.closest?.('.cb-card');
    if (card) paste(items.find((i) => i.id === Number(card.dataset.id)));
  });
  panel.addEventListener('contextmenu', (e) => {
    const card = e.target.closest?.('.cb-card');
    if (!card) return;
    e.preventDefault();
    const item = items.find((i) => i.id === Number(card.dataset.id));
    selectedId = item.id;
    render();
    showContextMenu(e.clientX, e.clientY, [
      { label: 'Paste', shortcut: '↵', action: () => paste(item) },
      { label: 'Paste as Plain Text', shortcut: '⇧↵', disabled: item.kind === 'image', action: () => paste(item, 'plain') },
      ...(item.kind === 'link' ? [
        { label: 'Paste Clean Link', disabled: !cleanLink(item.text).removed, action: () => paste(item, 'clean') },
        { label: 'Open Link', action: () => notify({ icon: 'link', title: 'Opens in your browser', subtitle: `${linkParts(item.text).host} (not on this page)`, tint: 'plain' }) },
      ] : []),
      { separator: true },
      { label: item.pinned ? 'Unpin' : 'Pin', shortcut: '⌘P', action: () => togglePin(item) },
      { label: 'Delete', shortcut: '⌘⌫', action: () => remove(item) },
    ]);
  });
  render();
  input.focus();
  footTimer = setInterval(updateFoot, 1000);
  if (isNarrow()) panel.classList.add('narrow');
}

let footTimer = 0;
function closePanel() {
  if (!panel) return;
  clearInterval(footTimer);
  panel.remove();
  panel = null;
  if (pasteTarget === 'scratchpad') windowSpec('scratchpad')?.el?.querySelector('textarea')?.focus();
}

// ---------------------------------------------------------------- snippets

export const snippetStore = {
  list: store.get('snippets', SNIPPETS),
  save() { store.set('snippets', this.list); bus.emit('snippets'); },
};

function pad2(n) { return String(n).padStart(2, '0'); }
function formatDate(d, fmt) {
  return fmt.replace(/yyyy|MM|dd|HH|mm/g, (t) => ({ yyyy: d.getFullYear(), MM: pad2(d.getMonth() + 1), dd: pad2(d.getDate()), HH: pad2(d.getHours()), mm: pad2(d.getMinutes()) })[t]);
}

/** Expands {clipboard}, {date}, {date:fmt}, {time}, {datetime}; returns the text and where {cursor} was. */
export function expandSnippet(template) {
  const d = new Date();
  let text = template
    .replace(/\{clipboard\}/g, currentPasteboardText())
    .replace(/\{date:([^}]+)\}/g, (_, f) => formatDate(d, f))
    .replace(/\{date\}/g, d.toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric' }))
    .replace(/\{time\}/g, d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' }))
    .replace(/\{datetime\}/g, `${d.toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric' })} ${d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })}`);
  const cursor = text.indexOf('{cursor}');
  text = text.replace(/\{cursor\}/g, '');
  return { text, cursor: cursor < 0 ? text.length : cursor };
}

function onScratchpadInput(e) {
  if (!settings.snippetsOn || e.inputType === 'insertFromPaste') return;
  const ta = e.target;
  const caret = ta.selectionStart;
  const before = ta.value.slice(0, caret);
  for (const s of snippetStore.list) {
    if (!s.trigger || !before.endsWith(s.trigger)) continue;
    const start = caret - s.trigger.length;
    if (start > 0 && !/[\s([{"'“]/.test(before[start - 1])) continue;
    const { text, cursor } = expandSnippet(s.text);
    ta.setRangeText(text, start, caret, 'end');
    ta.selectionStart = ta.selectionEnd = start + cursor;
    bus.emit('tour', 'snippet');
    return;
  }
}

function snippetPicker() {
  const target = frontWindow() === 'scratchpad' ? 'scratchpad' : null;
  let q = '';
  let sel = 0;
  const scrim = html`<div class="scrim sp-scrim"><div class="sp-panel" role="dialog" aria-modal="true" aria-label="Snippets">
    <div class="cb-search">${icon('search')}<input type="text" placeholder="Search Snippets" aria-label="Search snippets" autocomplete="off"></div>
    <div class="sp-list" role="listbox"></div>
    <div class="sp-foot"><span class="cb-keys"><span><kbd>↵</kbd>Insert</span><span><kbd>↑↓</kbd>Choose</span><span><kbd>esc</kbd>Close</span></span><span class="sp-where">${target ? 'Types it into Scratchpad' : 'Puts it in Scratchpad'}</span></div>
  </div></div>`;
  const list = () => snippetStore.list.filter((s) => `${s.name} ${s.trigger} ${s.text}`.toLowerCase().includes(q.toLowerCase()));
  const draw = () => {
    const l = list();
    sel = Math.min(sel, Math.max(0, l.length - 1));
    $('.sp-list', scrim).innerHTML = l.length ? l.map((s, i) => `<div class="sp-row ${i === sel ? 'sel' : ''}" role="option" data-i="${i}" aria-selected="${i === sel}"><b>${esc(s.name)}</b><code>${esc(s.trigger)}</code><span>${esc(s.text.replace(/\s+/g, ' '))}</span></div>`).join('') : '<div class="cb-empty">No snippet matches.</div>';
  };
  const choose = (s) => {
    if (!s) return;
    scrim.remove();
    const { text, cursor } = expandSnippet(s.text);
    scratchpad.insert(text);
    const ta = scratchpad.el;
    ta.selectionStart = ta.selectionEnd = ta.selectionStart - (text.length - cursor);
    bus.emit('tour', 'snippet');
  };
  const input = $('input', scrim);
  input.addEventListener('input', () => { q = input.value; sel = 0; draw(); });
  input.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowDown') { e.preventDefault(); sel++; draw(); }
    if (e.key === 'ArrowUp') { e.preventDefault(); sel = Math.max(0, sel - 1); draw(); }
    if (e.key === 'Enter') { e.preventDefault(); choose(list()[sel]); }
    if (e.key === 'Escape') { e.preventDefault(); scrim.remove(); }
  });
  scrim.addEventListener('click', (e) => {
    if (e.target === scrim) { scrim.remove(); return; }
    const row = e.target.closest?.('.sp-row');
    if (row) choose(list()[Number(row.dataset.i)]);
  });
  document.body.append(scrim);
  draw();
  input.focus();
}

// ---------------------------------------------------------------- setup

export function initClipboard() {
  loadItems();
  document.addEventListener('copy', onDocumentCopy);
  document.addEventListener('cut', onDocumentCopy);
  registerAction('clipboard', openPanel);
  registerAction('snippets', snippetPicker);
  document.addEventListener('input', (e) => { if (e.target === scratchpad.el) onScratchpadInput(e); });
  bus.on('setting:historyLimit', () => {
    let unpinnedSeen = 0;
    const keepUnpinned = Math.max(0, settings.historyLimit - items.filter((i) => i.pinned).length);
    items = items.filter((i) => i.pinned || ++unpinnedSeen <= keepUnpinned);
    save();
  });
}

export { openPanel as openClipboard };
