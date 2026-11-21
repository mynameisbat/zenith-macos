// Settings: the same panes as ZenithPreferencesView, working on the demo's made-up machine.
import {
  $, $$, bus, esc, icon, html, settings, setSetting, registerWindow, registerAction, openWindow, notify, ask,
  confirmDestructive, SHORTCUT_DEFS, shortcutFor, setShortcut, comboText, eventCombo, captureKeys, runAction,
  SOUND_NAMES, playSound, formatBytes, formatClock, sleep, VERSION, store, isWindowOpen,
} from './core.js';
import { cleaner, ports, system, boost, keepAwake, uninstaller } from './models.js';
import { island, timerSnapshot } from './island.js';
import { clipboardStore, snippetStore, expandSnippet } from './clipboard.js';
import { BREW_INSTALLED, BREW_SEARCH } from './data.js';

const TABS = [
  { id: 'general', title: 'General', icon: 'gear', tint: 'gray', keys: 'login updates clipboard history privacy ignored apps keep awake cleaning mode' },
  { id: 'shortcuts', title: 'Shortcuts', icon: 'cmd', tint: 'red', keys: 'hotkeys keyboard keys' },
  { id: 'audio', title: 'Audio', icon: 'speaker', tint: 'pink', keys: 'sound effects volume' },
  { id: 'island', title: 'Dynamic Island', icon: 'island', tint: 'black', keys: 'notch timer calendar network speed hover swipe full screen widgets dock tools menu bar icon ai agents' },
  { id: 'snippets', title: 'Snippets', icon: 'snippet', tint: 'yellow', keys: 'text expansion trigger' },
  { sep: true },
  { id: 'privacy', title: 'Privacy Shield', icon: 'shield', tint: 'green', keys: 'doh dns proxy trackers block ads' },
  { id: 'ports', title: 'Ports', icon: 'port', tint: 'blue', keys: 'listening tcp udp process' },
  { id: 'cleaner', title: 'Cleaner', icon: 'sparkles', tint: 'purple', keys: 'disk caches projects installers leftovers drives scan ram memory uninstall apps' },
  { id: 'homebrew', title: 'Homebrew', icon: 'mug', tint: 'amber', keys: 'brew formulae casks install upgrade' },
  { id: 'permissions', title: 'Permissions', icon: 'hand', tint: 'blue', keys: 'screen recording accessibility automation calendars' },
];

// Settings is drawn in two places: the island's Settings page (and its Cleaner, Ports and Homebrew pages) and, while a full-screen
// window hides the island, a window. Each place is a "mount"; one shared state, so what changes shows in all of them.
const mounts = new Set();
let current = 'general';
const live = () => [...mounts].filter((m) => m.el.isConnected && !m.el.closest('[hidden]'));

// ---------------------------------------------------------------- small building blocks (System Settings style)

const sw = (key, label) => `<input type="checkbox" class="switch" role="switch" data-setting="${key}" data-type="bool" aria-label="${esc(label)}" ${settings[key] ? 'checked' : ''}>`;

function row({ ic, tint, title, sub, control = '', cls = '' }) {
  return `<div class="srow ${cls}">
    ${ic ? `<span class="tile-ic small tint-${tint ?? 'gray'}">${icon(ic)}</span>` : ''}
    <span class="srow-text"><b>${title}</b>${sub ? `<span>${sub}</span>` : ''}</span>
    <span class="srow-ctl">${control}</span>
  </div>`;
}

function section(title, rows, footer = '') {
  return `<section class="ssec">${title ? `<h4>${esc(title)}</h4>` : ''}<div class="sgroup">${rows.join('')}</div>${footer ? `<p class="sfoot">${footer}</p>` : ''}</section>`;
}

function select(key, options, label, type = 'num') {
  return `<select class="pop-btn" data-setting="${key}" data-type="${type}" aria-label="${esc(label)}">${options.map(([v, t]) => `<option value="${esc(v)}" ${String(settings[key]) === String(v) ? 'selected' : ''}>${esc(t)}</option>`).join('')}</select>`;
}

function stepper(key, min, max, step, unit, label) {
  return `<span class="stepper"><span class="stepper-val">${settings[key]} ${unit}</span><span class="stepper-btns"><button type="button" data-step="${key}" data-delta="${step}" data-min="${min}" data-max="${max}" aria-label="Increase ${esc(label)}">▲</button><button type="button" data-step="${key}" data-delta="${-step}" data-min="${min}" data-max="${max}" aria-label="Decrease ${esc(label)}">▼</button></span></span>`;
}

// ---------------------------------------------------------------- panes

const panes = {
  general() {
    const ignored = settings.ignoredApps;
    return [
      section('Startup', [row({ ic: 'zenith', tint: 'indigo', title: 'Open at Login', sub: 'Start Zenith in the menu bar when you log in.', control: sw('openAtLogin', 'Open at Login') })]),
      section('Updates', [
        row({ ic: 'download', tint: 'blue', title: 'Check Automatically', sub: 'Once a day, from GitHub. Nothing is installed without your click.', control: sw('checkUpdates', 'Check for updates automatically') }),
        row({ title: `Zenith ${VERSION}`, sub: 'You have the version this page shows.', control: '<button type="button" class="btn" data-act="check-update">Check Now</button>' }),
      ]),
      section('Clipboard', [
        row({ ic: 'clipboard', tint: 'orange', title: 'History Size', sub: 'Pinned items are kept beyond it.', control: stepper('historyLimit', 50, 1000, 50, 'items', 'history size') }),
        row({ title: 'Clear History', sub: `${clipboardStore.items.length} items, ${clipboardStore.items.filter((i) => i.pinned).length} pinned`, control: '<button type="button" class="btn" data-act="clear-history">Clear History…</button>' }),
      ]),
      section('Clipboard Privacy', [
        row({ ic: 'lock', tint: 'gray', title: 'Clear Clipboard', sub: 'Empties the clipboard after a copy, if it still holds that copy. The history keeps it.', control: select('clearAfter', [[0, 'Never'], [30, 'After 30 Seconds'], [60, 'After 1 Minute'], [300, 'After 5 Minutes'], [600, 'After 10 Minutes']], 'Clear clipboard') }),
        row({ title: 'Clear When the Mac Locks', sub: 'Try it: Events → Lock Screen.', control: sw('clearOnLock', 'Clear when the Mac locks') }),
        row({ ic: 'link', tint: 'blue', title: 'Clean Links When I Copy Them', sub: 'Removes utm_*, fbclid, gclid and the like when you copy exactly one link.', control: sw('cleanLinksOnCopy', 'Clean links when copied') }),
        `<div class="srow col"><span class="srow-text"><b>Ignored Apps</b><span>Copies made while one of these is in front are not kept.</span></span>
          <div class="chips">${ignored.length ? ignored.map((a) => `<span class="tag">${esc(a)}<button type="button" data-remove-ignored="${esc(a)}" aria-label="Remove ${esc(a)}">${icon('x')}</button></span>`).join('') : '<span class="dim">No ignored apps.</span>'}
          <button type="button" class="btn btn-small" data-act="add-ignored">Choose App…</button></div></div>`,
      ]),
      section('Keep Awake', [
        row({ ic: 'cup', tint: 'brown', title: 'Keep Mac Awake', sub: keepAwake.until == null ? 'Off. The Mac sleeps as set in System Settings.' : keepAwake.until === Infinity ? 'On until you turn it off.' : `On until ${new Date(keepAwake.until).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })}.`, control: `<span class="btn-row"><button type="button" class="btn" data-awake="60">1 Hour</button><button type="button" class="btn" data-awake="inf">On</button><button type="button" class="btn" data-awake="off" ${keepAwake.until == null ? 'disabled' : ''}>Turn Off</button></span>` }),
        row({ title: 'Keep the Display On', control: sw('keepAwakeDisplay', 'Keep the display on') }),
      ]),
      section('Cleaning Mode', [
        row({ ic: 'sparkles', tint: 'teal', title: 'Time Limit', sub: 'It always ends by itself. Hold ⌃⌥⌘ for 2 seconds to stop early.', control: select('cleaningSeconds', [15, 30, 45, 60, 90, 120, 180, 300].map((s) => [s, s < 60 ? `${s} seconds` : s === 60 ? '1 minute' : `${s / 60} minutes`]), 'Time limit') }),
        row({ title: 'Screen', control: select('cleaningScreen', [['dim', 'Dimmed'], ['black', 'Black']], 'Screen', 'str') }),
        row({ title: 'Global Shortcut', control: `<kbd>${esc(comboText(shortcutFor('cleaningMode')) || 'None')}</kbd> <button type="button" class="btn" data-act="cleaning">Start</button>` }),
      ]),
    ].join('');
  },

  shortcuts() {
    return section('Global Shortcuts', SHORTCUT_DEFS.map((d) => {
      const c = shortcutFor(d.id);
      const isDefault = comboText(c) === comboText(d.def);
      return row({
        title: d.title,
        sub: `Default: ${comboText(d.def)}${d.alt ? ` · <button type="button" class="linkish" data-alt="${d.id}">Use ${comboText(d.alt)}</button>` : ''}`,
        control: `<button type="button" class="recorder" data-record="${d.id}" aria-label="Shortcut for ${esc(d.title)}: ${esc(comboText(c) || 'none')}. Click to change.">${esc(comboText(c) || 'Record Shortcut')}</button>${isDefault ? '' : `<button type="button" class="btn btn-icon" data-reset-key="${d.id}" aria-label="Back to the default">${icon('undo')}</button>`}`,
      });
    }), 'Click a shortcut, then press the new keys (with ⌘, ⌃ or ⌥). Esc cancels, Delete removes it. They work on this page at once; your browser keeps a few, such as ⌘W and ⌘T.')
      + '<div class="pane-actions"><button type="button" class="btn" data-act="reset-shortcuts">Restore All Defaults</button></div>';
  },

  audio() {
    const events = [['capture', 'Screen Capture', 'When a screenshot is taken.'], ['copy', 'Copy', 'When an item is copied.'], ['paste', 'Paste', 'When you paste an item from the history.'], ['pin', 'Pin', 'When an item is pinned or unpinned.'], ['delete', 'Delete', 'When an item is removed from the history.'], ['error', 'Error', 'When something cannot be done.'], ['color', 'Color Sample', 'When the loupe picks a color.']];
    return section('Sound Effects', [
      row({ ic: 'speaker', tint: 'pink', title: 'Play Sound Effects', sub: 'Off by default on this page, so it does not surprise you.', control: sw('soundsOn', 'Play sound effects') }),
      row({ title: 'Volume', control: `<input type="range" min="0" max="1" step="0.05" value="${settings.soundVolume}" data-setting="soundVolume" data-type="num" aria-label="Volume">` }),
    ]) + section('Sounds', events.map(([id, title, sub]) => row({
      title, sub,
      control: `<select class="pop-btn" data-sound="${id}" aria-label="${esc(title)} sound"><option value="">None</option>${SOUND_NAMES.map((n) => `<option ${settings.sounds[id] === n ? 'selected' : ''}>${n}</option>`).join('')}</select><button type="button" class="btn btn-icon" data-play="${id}" aria-label="Play ${esc(title)} sound">${icon('play')}</button>`,
    })), 'The sounds here are synthesised by your browser; the app plays the system sounds of the same names, or ones you import.');
  },

  island() {
    const t = timerSnapshot();
    const access = { granted: 'Allowed', denied: 'Not allowed', notDetermined: 'Not asked yet' }[settings.calendarAccess];
    return section('', [
      row({ ic: 'island', tint: 'black', title: 'Show the Island', sub: 'When off, notices use a floating panel instead.', control: sw('islandEnabled', 'Show the island') }),
      row({ title: 'Display Has a Notch', sub: 'This page only: the app sees whether your display has one.', control: sw('notch', 'Display has a notch') }),
    ]) + section('Widgets', [
      row({ ic: 'timer', tint: 'orange', title: 'Focus Timer', sub: 'A Pomodoro-style timer with breaks.', control: sw('timerWidget', 'Focus timer') }),
      row({ title: 'Focus Length', control: stepper('focusMinutes', 1, 120, 1, 'min', 'focus length'), cls: 'indent' }),
      row({ title: 'Break Length', control: stepper('breakMinutes', 1, 60, 1, 'min', 'break length'), cls: 'indent' }),
      row({ ic: 'calendar', tint: 'red', title: 'Next Calendar Event', sub: 'Your next meeting from the Calendar app, with how long until it starts.', control: sw('calendarWidget', 'Next calendar event') }),
      row({ title: 'Calendar Access', sub: access, control: settings.calendarAccess === 'notDetermined' ? '<button type="button" class="btn" data-act="cal-allow">Allow…</button>' : '<button type="button" class="btn" data-act="open-system">Open…</button>', cls: 'indent' }),
      row({ ic: 'network', tint: 'cyan', title: 'Network Speed', sub: 'Download and upload speed, measured only while the island is open on the Widgets tab.', control: sw('speedWidget', 'Network speed') }),
    ], 'Move the pointer to the notch to open the island, then pick the Widgets tab. A running timer stays next to the notch.')
    + section('AI Agents', [
      row({ ic: 'sparkles', tint: 'purple', title: 'Coding Agents', sub: 'Show Claude Code, Codex and Antigravity at work on the island, with today’s tokens and plan limits. (Made-up numbers here.)', control: sw('aiAgents', 'Coding agents') }),
    ], 'Off until you turn it on. In the app Zenith reads these tools’ local logs, read-only: only token counts, times, model names and folder names.')
    + section('Behavior', [
      row({ ic: 'island', tint: 'gray', title: 'Menu Bar Icon', sub: 'Also keep Zenith in the menu bar, with the Command Hub. It is always there while the tool dock is off.', control: sw('menuBarIcon', 'Menu bar icon') }),
      row({ ic: 'cmd', tint: 'indigo', title: 'Tool Dock', sub: 'A row of tools under the open island, and a page with all of them. The Command Hub then leaves its own buttons out; searching there still finds them.', control: sw('toolDock', 'Tool dock') }),
      row({ title: 'Hover Delay', sub: 'How long the pointer rests on the notch before the island opens. A click opens it at once.', control: `<input type="range" min="0.1" max="1" step="0.05" value="${settings.hoverDelay}" data-setting="hoverDelay" data-type="num" aria-label="Hover delay"> <span class="dim val">${settings.hoverDelay.toFixed(2)} s</span>` }),
      row({ title: 'Swipe Gestures', sub: 'Pull down to open, push up to close, sideways to change track.', control: sw('swipes', 'Swipe gestures') }),
      row({ title: 'Hide in Full-Screen Apps', sub: 'Notices then use a floating panel.', control: sw('hideInFullScreen', 'Hide in full-screen apps') }),
    ])
    + section('Timer', [row({
      ic: 'timer', tint: 'orange',
      title: t.mode ? 'Running' : 'Not Running',
      sub: t.mode ? `${t.mode === 'break' ? 'Break' : 'Focus'} · ${formatClock(t.remaining)} left${t.paused ? ' (paused)' : ''}` : t.sessions === 0 ? 'No focus sessions finished today.' : t.sessions === 1 ? '1 focus session finished today.' : `${t.sessions} focus sessions finished today.`,
      control: t.mode ? '<button type="button" class="btn" data-act="timer-stop">Stop</button>' : '<span class="btn-row"><button type="button" class="btn" data-act="timer-break">Start Break</button><button type="button" class="btn" data-act="timer-focus">Start Focus</button></span>',
    })]);
  },

  snippets() {
    const list = snippetStore.list;
    return section('', [row({ ic: 'snippet', tint: 'yellow', title: 'Expand Snippets as You Type', sub: 'Type a trigger in Scratchpad and the snippet takes its place. In the app this needs Accessibility.', control: sw('snippetsOn', 'Expand snippets as you type') })])
      + section('Snippets', list.length ? list.map((s, i) => row({
        title: `${esc(s.name)} <code>${esc(s.trigger || '—')}</code>`,
        sub: esc(expandSnippet(s.text).text.replace(/\s+/g, ' ').slice(0, 90)),
        control: `<button type="button" class="btn btn-small" data-edit-snippet="${i}">Edit</button><button type="button" class="btn btn-icon" data-del-snippet="${i}" aria-label="Delete ${esc(s.name)}">${icon('trash')}</button>`,
      })) : [row({ title: 'No snippets yet.' })], 'Placeholders: {clipboard}, {date}, {time}, {datetime}, {date:yyyy-MM-dd} and {cursor}, where the caret ends up.')
      + `<div class="pane-actions"><button type="button" class="btn" data-act="import-snippets">Import…</button><button type="button" class="btn" data-act="export-snippets">Export…</button><span class="grow"></span><button type="button" class="btn btn-primary" data-act="add-snippet">${icon('plus')}Add Snippet</button></div>`;
  },

  privacy() {
    const providers = [['cloudflare', 'Cloudflare'], ['google', 'Google'], ['quad9', 'Quad9'], ['adguard', 'AdGuard DNS (blocks ads)'], ['nextdns', 'NextDNS'], ['custom', 'Custom…']];
    const filtering = settings.shieldProvider === 'adguard' || settings.shieldProvider === 'nextdns';
    return section('', [
      row({ ic: 'shield', tint: 'green', title: 'Privacy Shield', sub: 'Looks up site names over encrypted DNS and splits the first TLS packet of each connection. It is not a VPN and does not hide your IP address.', control: sw('shieldOn', 'Privacy Shield') }),
      `<div class="srow col shield-status ${settings.shieldOn ? 'on' : ''}"><span class="srow-text"><b>${settings.shieldOn ? `Running on 127.0.0.1:${String(settings.shieldPort)}` : 'Off'}</b><span>${settings.shieldOn ? 'The system proxy points here; your previous settings are saved and come back when it stops.' : 'Your system proxy is as you set it.'}</span></span>
        <div class="feed" aria-live="off">${feed.length ? feed.map((f) => `<div class="${f.blocked ? 'blocked' : ''}"><span>${esc(f.host)}</span><span>${f.blocked ? `403 · ${esc(f.why)}` : `DoH → ${f.ip}`}</span></div>`).join('') : `<div class="dim">${settings.shieldOn ? 'Waiting for requests from the pretend apps…' : 'Requests appear here while it runs.'}</div>`}</div>
        <span class="dim">${stats.requests} requests · ${stats.blocked} refused</span></div>`,
    ]) + section('Resolver', [
      row({ title: 'Resolver Provider', control: select('shieldProvider', providers, 'Resolver provider', 'str') }),
      settings.shieldProvider === 'nextdns' ? row({ title: 'Profile ID:', control: '<input type="text" class="field" placeholder="abc123" aria-label="NextDNS profile ID">', cls: 'indent' }) : '',
      settings.shieldProvider === 'custom' ? row({ title: 'DoH URL:', control: '<input type="url" class="field" placeholder="https://dns.example/dns-query" aria-label="DoH URL">', cls: 'indent' }) + row({ title: 'Bootstrap IP (Optional):', control: '<input type="text" class="field" placeholder="192.0.2.1" aria-label="Bootstrap IP">', cls: 'indent' }) : '',
      row({ title: 'Local Proxy Endpoint:', sub: settings.shieldOn ? 'Stop Privacy Shield to reconfigure local proxy port.' : 'Common Ports: <button type="button" class="linkish" data-port="8080">8080</button> <button type="button" class="linkish" data-port="8085">8085</button> <button type="button" class="linkish" data-port="1080">1080</button>', control: `127.0.0.1 : <input type="text" inputmode="numeric" class="field port" value="${String(settings.shieldPort)}" data-port-field ${settings.shieldOn ? 'disabled' : ''} aria-label="Port">` }),
    ], filtering ? `${settings.shieldProvider === 'adguard' ? 'AdGuard DNS' : 'NextDNS'} also blocks ads and trackers, with a list it keeps up to date. Its blocks are counted here, and Never Block applies to it too.` : 'The resolver is reached by its IP address, so its own name is never looked up in plain DNS.')
    + section('Block Ads and Trackers', [
      row({ ic: 'xcircle', tint: 'red', title: 'Block Ads and Trackers', sub: 'Refuses connections to the domains on your lists before any lookup is made for them. Only while Privacy Shield is on.', control: sw('blockTrackers', 'Block ads and trackers') }),
      `<div class="srow col"><span class="srow-text"><b>Domain List</b></span><div class="chips">${settings.blocklist.map((d) => `<span class="tag">${esc(d)}<button type="button" data-unblock="${esc(d)}" aria-label="Remove ${esc(d)}">${icon('x')}</button></span>`).join('') || '<span class="dim">No list imported. Import a hosts file, or use a filtering resolver.</span>'}</div>
        <form class="inline-form" data-form="block"><input type="text" class="field" placeholder="ads.example.com" aria-label="Domain to block"><button type="submit" class="btn">Add</button><button type="button" class="btn" data-act="import-hosts">Import List…</button></form></div>`,
      `<div class="srow col"><span class="srow-text"><b>Never Block</b><span>Kept even while blocking is off; looked up with a resolver that does not filter.</span></span><div class="chips">${settings.neverBlock.map((d) => `<span class="tag">${esc(d)}<button type="button" data-unnever="${esc(d)}" aria-label="Remove ${esc(d)}">${icon('x')}</button></span>`).join('') || '<span class="dim">Nothing yet.</span>'}</div>
        <form class="inline-form" data-form="never"><input type="text" class="field" placeholder="login.example.com" aria-label="Domain never to block"><button type="submit" class="btn">Add</button></form></div>`,
    ])
    + section('Try a Name', [`<div class="srow col"><form class="inline-form" data-form="test"><input type="text" class="field wide" placeholder="pixel.example-metrics.com" aria-label="Site name to test"><button type="submit" class="btn">Test</button></form><div class="test-result" aria-live="polite"></div></div>`,
      row({ title: 'Automated Connectivity Probe', sub: 'Send sample requests through the local proxy to verify DoH resolution and TLS bypass. (Simulated on this page.)', control: '<button type="button" class="btn" data-act="probe">Run Test</button>' }),
      '<div class="probe" hidden></div>']);
  },

  ports() {
    const q = portQuery.trim();
    const own = settings.shieldOn ? [{ port: settings.shieldPort, proto: 'TCP', process: 'Zenith', pid: 4242, address: '127.0.0.1', app: 'Privacy Shield', own: true }] : [];
    const list = [...own, ...ports.list].filter((p) => (showUDP || p.proto === 'TCP') && (!q || String(p.port).includes(q.replace(':', '')) || p.process.toLowerCase().includes(q.toLowerCase())));
    return `<div class="pane-tools"><span class="search-field">${icon('search')}<input type="text" placeholder="Port or process" value="${esc(portQuery)}" data-port-search aria-label="Filter ports"></span><label class="check"><input type="checkbox" data-udp ${showUDP ? 'checked' : ''}> Include UDP</label></div>`
      + section('', list.length ? list.map((p) => row({
        ic: 'port', tint: p.own ? 'green' : 'blue',
        title: `${String(p.port)} <span class="dim">${p.proto}</span>`,
        sub: `${esc(p.process)} · PID ${String(p.pid)} · ${esc(p.address)}${p.own ? ' · Privacy Shield' : ''}`,
        control: p.own ? '<span class="dim">Zenith</span>' : `<button type="button" class="btn" data-stop-port="${p.port}">Stop…</button>`,
      })) : [row({ title: q ? `No port matches “${esc(q)}”` : 'None of your processes is listening on a port.' })], 'The ports your processes listen on. Stopping one sends SIGTERM, then SIGKILL if needed, after you confirm. Type a port number in the System page’s search to find it there too.');
  },

  cleaner() {
    const used = system.diskTotal - system.diskFree;
    const memPct = Math.round((system.memUsed / system.memTotal) * 100);
    const meters = section('', [
      `<div class="srow col"><span class="srow-text"><b>Macintosh HD Storage</b><span>${formatBytes(system.diskFree)} available of ${formatBytes(system.diskTotal)}</span></span><span class="meter big"><span style="width:${(used / system.diskTotal) * 100}%"></span></span></div>`,
      `<div class="srow col"><span class="srow-text"><b>Live System Memory (RAM)</b><span>${formatBytes(system.memUsed)} used (${memPct}%) of ${formatBytes(system.memTotal)}</span></span><span class="meter big"><span style="width:${memPct}%"></span></span><div class="pane-actions"><button type="button" class="btn" data-act="boost">Optimize RAM</button></div></div>`,
    ]);
    const seg = `<div class="seg" role="tablist" aria-label="Cleaner">${[...Object.keys(cleaner.tabs), 'uninstall'].map((k) => `<button type="button" role="tab" class="seg-btn" data-clean-tab="${k}" aria-selected="${k === cleanTab}">${k === 'uninstall' ? 'Uninstall' : esc(cleaner.info(k).title)}</button>`).join('')}</div>`;
    const top = meters + seg;
    if (cleanTab === 'uninstall') return seg + uninstallPane();
    const t = cleaner.tabs[cleanTab];
    const info = cleaner.info(cleanTab);
    let body = '';
    if (t.state === 'idle') body = `<div class="empty small">${icon('sparkles')}<span>Not scanned yet. Nothing is removed until you confirm.</span><button type="button" class="btn btn-primary" data-act="scan">Scan</button></div>`;
    else if (t.state === 'scanning') body = `<div class="empty small"><span class="spinner"></span><span>Scanning system caches and developer files...</span></div>`;
    else if (t.state === 'clean') body = `<div class="empty small">${icon('check')}<b>Your Mac is Clean</b><span>No significant junk or developer cache files were found.</span><button type="button" class="btn" data-act="scan">Scan Again</button></div>`;
    else {
      const sel = cleaner.selected(cleanTab);
      body = `<div class="sgroup">${t.categories.map((c, i) => `<details class="cat"><summary><input type="checkbox" data-cat="${i}" ${c.selected ? 'checked' : ''} aria-label="${esc(c.name)}"><span class="grow">${esc(c.name)} <span class="dim">(${c.items.length})</span></span><span class="dim">${formatBytes(c.items.reduce((a, [, s]) => a + s, 0))}</span></summary><ul>${c.items.map(([n, s]) => `<li><span>${esc(n)}</span><span class="dim">${formatBytes(s)}</span></li>`).join('')}</ul></details>`).join('')}</div>
        <div class="pane-actions"><span class="dim">${sel.length} of ${t.categories.flatMap((c) => c.items).length} items selected (${formatBytes(cleaner.selectedSize(cleanTab))} selected)</span><span class="grow"></span><button type="button" class="btn" data-act="scan">Scan</button><button type="button" class="btn ${info.verb === 'Delete' ? 'btn-danger' : 'btn-primary'}" data-act="clean" ${sel.length ? '' : 'disabled'}>${info.verb === 'Delete' ? 'Delete…' : 'Clean…'}</button></div>`;
    }
    return top
      + `<p class="dim pane-note">${esc(info.note)}</p>${body}`
      + section('Scheduled Scan', [
        row({ ic: 'timer', tint: 'purple', title: 'Scan Automatically', sub: 'Only scans, never deletes, and only while Zenith runs.', control: sw('scheduledScan', 'Scan automatically') }),
        row({ title: 'Frequency', control: select('scanFrequency', [['daily', 'Every Day'], ['weekly', 'Every Week'], ['monthly', 'Every 30 Days']], 'Frequency', 'str'), cls: 'indent' }),
        row({ title: 'Try it now', sub: 'Runs a scheduled scan on this page.', control: `<button type="button" class="btn" data-act="scheduled" ${settings.scheduledScan ? '' : 'disabled'}>Run</button>`, cls: 'indent' }),
      ], 'You are told once when at least 1 GB can be cleaned, and again only after it grows by another 1 GB.');
  },

  homebrew() {
    const outdated = brew.installed.filter((p) => p.version !== p.latest);
    const head = `<div class="seg" role="tablist" aria-label="Homebrew">${[['installed', `Installed (${brew.installed.length})`], ['search', 'Search']].map(([k, l]) => `<button type="button" role="tab" class="seg-btn" data-brew-tab="${k}" aria-selected="${k === brewTab}">${l}</button>`).join('')}</div>`;
    const log = brew.log.length ? `<pre class="brew-log" aria-live="polite">${esc(brew.log.join('\n'))}</pre>` : '';
    if (brewTab === 'search') {
      const q = brew.query.toLowerCase();
      const results = q ? BREW_SEARCH.filter((p) => p.name.includes(q) || p.desc.toLowerCase().includes(q)) : BREW_SEARCH;
      return head + `<div class="pane-tools"><span class="search-field">${icon('search')}<input type="text" placeholder="Search Homebrew" value="${esc(brew.query)}" data-brew-search aria-label="Search Homebrew"></span></div>`
        + section('', results.length ? results.map((p) => {
          const have = brew.installed.some((i) => i.name === p.name);
          return row({ ic: p.cask ? 'screen' : 'code', tint: 'amber', title: `${esc(p.name)} <span class="dim">${esc(p.latest)}${p.cask ? ' · app' : ''}</span>`, sub: esc(p.desc), control: have ? '<span class="dim">Installed</span>' : `<button type="button" class="btn" data-brew-install="${esc(p.name)}" ${brew.busy ? 'disabled' : ''}>Install</button>` });
        }) : [row({ title: 'Nothing found.' })]) + log;
    }
    return head + `<div class="pane-actions"><span class="dim">${outdated.length ? `${outdated.length} outdated` : 'Everything is up to date'}</span><span class="grow"></span><button type="button" class="btn" data-act="brew-update" ${brew.busy ? 'disabled' : ''}>Update Homebrew</button><button type="button" class="btn btn-primary" data-act="brew-upgrade-all" ${outdated.length && !brew.busy ? '' : 'disabled'}>Upgrade All…</button></div>`
      + section('', brew.installed.map((p) => row({
        ic: p.cask ? 'screen' : 'code', tint: 'amber',
        title: `${esc(p.name)} <span class="dim">${esc(p.version)}${p.version !== p.latest ? ` → ${esc(p.latest)}` : ''}${p.cask ? ' · app' : ''}</span>`,
        sub: `${esc(p.desc)} · ${formatBytes(p.size)}`,
        control: `${p.version !== p.latest ? `<button type="button" class="btn" data-brew-upgrade="${esc(p.name)}" ${brew.busy ? 'disabled' : ''}>Upgrade</button>` : ''}<button type="button" class="btn" data-brew-remove="${esc(p.name)}" ${brew.busy ? 'disabled' : ''}>Uninstall…</button>`,
      })), 'Simulated here: no brew command runs. In the app the same buttons run brew and show its output.') + log;
  },

  permissions() {
    const cal = settings.calendarAccess;
    const cards = [
      ['Screen Recording', 'screen', 'red', 'Allowed', 'ok', 'Capture, the loupe and Copy Text.', 'Without it: captures show only the wallpaper.'],
      ['Accessibility', 'hand', 'blue', 'Not allowed', 'off', 'Pasting for you with ⌘V, snippets as you type, and the media-key fallback.', 'Without it: items are only copied; you press ⌘V.'],
      ['Automation', 'cmd', 'gray', 'Asked per app', 'mixed', 'Controlling Music and Spotify, Music’s artwork, and asking Finder to trash protected leftovers.', 'Music: allowed · Spotify: not asked · Finder: allowed'],
      ['Calendars', 'calendar', 'red', { granted: 'Allowed', denied: 'Not allowed', notDetermined: 'Not asked' }[cal], cal === 'granted' ? 'ok' : 'off', `The island’s calendar widget${settings.calendarWidget ? '' : ' (turned off)'}.`, settings.calendarWidget ? '' : 'Nothing uses it while the widget is off.'],
    ];
    return `<p class="pane-note">Zenith never asks for a permission on this page. Allow or remove them in System Settings.</p>`
      + `<div class="perm-cards">${cards.map(([name, ic, tint, state, kind, use, without]) => `<div class="perm-card">
        <div class="perm-top"><span class="tile-ic small tint-${tint}">${icon(ic)}</span><b>${name}</b><span class="badge ${kind}">${esc(state)}</span></div>
        <p><span class="dim">Used by</span> ${esc(use)}</p>${without ? `<p class="dim">${esc(without)}</p>` : ''}
        <button type="button" class="btn btn-small" data-act="open-system">Open…</button></div>`).join('')}</div>`
      + '<div class="pane-actions"><button type="button" class="btn" data-act="perm-check">Check Again</button></div>';
  },
};

// ---------------------------------------------------------------- pane state

let portQuery = '';
let showUDP = false;
let cleanTab = 'system';
let brewTab = 'installed';
const brew = { installed: BREW_INSTALLED.map((p) => ({ ...p })), query: '', log: [], busy: false };
const feed = [];
const stats = { requests: 0, blocked: 0 };

// ---------------------------------------------------------------- Uninstall (Settings → Cleaner → Uninstall)

const un = { app: null, items: [], scanning: false, query: '', notice: '' };
const baseName = (p) => p.replace(/\/$/, '').replace(/^.*\//, '');
const dirName = (p) => p.replace(/[^/]*$/, '');

function uninstallPane() {
  const a = un.app;
  if (a) {
    const bar = `<div class="un-bar"><button type="button" class="btn btn-small" data-un-back>${icon('back')}All Apps</button><span class="grow"></span><span class="un-id"><b>${esc(a.name)} ${esc(a.version)}</b><code>${esc(a.bundle)}</code></span><span class="tile-ic small tint-pink">${icon(a.icon)}</span></div>`;
    if (un.scanning) return `${bar}<div class="empty small"><span class="spinner"></span><span>Looking for the files ${esc(a.name)} keeps…</span></div>`;
    const sel = un.items.filter((i) => i.selected);
    return `${bar}<div class="sgroup">${un.items.map((it, i) => `<label class="un-row"><input type="checkbox" data-un-item="${i}" ${it.selected ? 'checked' : ''} aria-label="${esc(baseName(it.path))}"><span class="grow"><b>${esc(it.app ? a.file : baseName(it.path))}</b><span class="dim">${esc(dirName(it.path))}${it.nameOnly ? ' · matched by the app’s name only, so not ticked' : ''}</span></span><span class="dim">${formatBytes(it.size)}</span></label>`).join('')}</div>
      <div class="pane-actions"><span class="dim">${sel.length} of ${un.items.length} items selected (${formatBytes(sel.reduce((x, i) => x + i.size, 0))})</span><span class="grow"></span><button type="button" class="btn btn-danger" data-un-run ${sel.length ? '' : 'disabled'}>Move to Trash…</button></div>
      <p class="sfoot">${a.running ? `${esc(a.name)} is open: Zenith asks it to quit first, and if it stays open nothing is removed. ` : ''}Everything goes to the Trash. Files that only carry the app’s name start unticked.</p>`;
  }
  const q = un.query.trim().toLowerCase();
  const apps = uninstaller.apps().filter((x) => !q || x.name.toLowerCase().includes(q) || x.bundle.includes(q));
  return `<div class="srow col un-head"><span class="srow-text"><b>Uninstall an app</b><span>Pick an app to see the files it keeps in your Library. Nothing is removed until you confirm, and everything goes to the Trash. Apps that are part of macOS are not listed.</span></span>
      <div class="pane-actions"><button type="button" class="btn btn-small" data-un-refresh>${icon('undo')}Refresh</button><button type="button" class="btn btn-small" data-un-choose>Choose App…</button></div>
      ${un.notice ? `<span class="dim un-notice">${esc(un.notice)}</span>` : ''}</div>`
    + `<div class="pane-tools"><span class="search-field">${icon('search')}<input type="text" placeholder="Search apps" value="${esc(un.query)}" data-un-search aria-label="Search apps"></span></div>`
    + `<div class="sgroup un-list">${apps.length ? apps.map((x) => `<button type="button" class="un-app" data-un-pick="${esc(x.file)}"><span class="tile-ic small tint-pink">${icon(x.icon)}</span><span class="grow"><b>${esc(x.name)}</b><span class="dim">${esc(x.version)} · ${esc(x.path)}</span></span>${icon('chevron')}</button>`).join('') : `<div class="un-none dim">${uninstaller.apps().length ? 'No app matches your search.' : 'No apps found in the Applications folders.'}</div>`}</div>`;
}

async function unPick(app) {
  un.app = app;
  un.items = [];
  un.scanning = true;
  un.notice = '';
  render();
  await sleep(650);
  if (un.app !== app) return;
  un.items = uninstaller.items(app);
  un.scanning = false;
  render();
}

async function unChoose() {
  const i = await ask({ title: 'Choose an app', message: 'In the app this opens a file dialog. Pick one of these to see what Zenith does with it.', buttons: ['Cancel', 'Safari.app', 'Zenith.app', 'Portable Tool.app'], iconName: 'folder' });
  if (i === 1) un.notice = 'Safari is part of macOS or made by Apple, so Zenith leaves it alone.';
  else if (i === 2) un.notice = 'Zenith can’t uninstall itself. Quit it and move it to the Trash in Finder.';
  else if (i === 3) { await unPick({ id: 'portable', name: 'Portable Tool', file: 'Portable Tool.app', version: '0.9', bundle: 'com.example.portable', path: '~/Downloads/Portable Tool.app', size: 3.1e7, icon: 'code', running: false, files: [{ path: '~/Library/Preferences/com.example.portable.plist', size: 4e3 }] }); return; }
  else return;
  render();
}

async function unRun() {
  const a = un.app;
  if (!await uninstaller.run(a, un.items)) { render(); return; }
  un.app = null;
  un.items = [];
  un.notice = `${a.name} and its files are in the Trash.`;
  render();
}

// ---------------------------------------------------------------- Privacy Shield behaviour

const PUBLIC_SUFFIXES = new Set(['com', 'net', 'org', 'io', 'co', 'uk', 'co.uk', 'de', 'fr', 'jp', 'vn', 'com.vn', 'app', 'dev']);

function normalizeDomain(input) {
  const d = String(input).trim().toLowerCase().replace(/^https?:\/\//, '').replace(/[/:].*$/, '').replace(/^\*\./, '').replace(/\.$/, '');
  if (!/^[a-z0-9.-]+$/.test(d) || !d.includes('.') || PUBLIC_SUFFIXES.has(d) || d.split('.').some((p) => !p)) return null;
  return d;
}

const onList = (host, list) => list.some((d) => host === d || host.endsWith(`.${d}`));
const providerName = () => ({ cloudflare: 'Cloudflare', google: 'Google', quad9: 'Quad9', adguard: 'AdGuard DNS', nextdns: 'NextDNS', custom: 'your resolver' })[settings.shieldProvider];
const looksLikeAds = (h) => /(^|\.)(ads?|adservice|tracker|pixel|metrics|analytics|telemetry)[.-]/.test(h) || /-ads\.|-metrics\./.test(h);

function verdict(host) {
  if (!settings.shieldOn) return { kind: 'off', text: `Privacy Shield is off: ${host} is looked up by the system as usual, in plain DNS.` };
  if (onList(host, settings.neverBlock)) return { kind: 'ok', text: `On Never Block: looked up over DoH with a resolver that does not filter, then connected.` };
  if (settings.blockTrackers && onList(host, settings.blocklist)) return { kind: 'blocked', why: 'your list', text: 'Refused with 403 before any lookup: it is on your Domain List.' };
  if ((settings.shieldProvider === 'adguard' || settings.shieldProvider === 'nextdns') && looksLikeAds(host)) return { kind: 'blocked', why: providerName(), text: `${providerName()} answered 0.0.0.0, so Zenith refused it with 403 and counted it as blocked.` };
  return { kind: 'ok', text: `Looked up over DNS-over-HTTPS at ${providerName()}, so the name is not sent in plain DNS. The first TLS packet is split in two.` };
}

const FEED_HOSTS = ['api.example.com', 'cdn.example.net', 'tracker.example-ads.net', 'fonts.example.org', 'pixel.example-metrics.com', 'updates.example-app.io', 'mail.example.com', 'ads.example-network.com'];
let feedTimer = 0;
function feedTick() {
  if (!settings.shieldOn) return;
  const host = FEED_HOSTS[Math.floor(Math.random() * FEED_HOSTS.length)];
  const v = verdict(host);
  stats.requests++;
  if (v.kind === 'blocked') stats.blocked++;
  feed.unshift({ host, blocked: v.kind === 'blocked', why: v.why, ip: `203.0.113.${(host.length * 7) % 250 + 2}` });
  feed.length = Math.min(feed.length, 6);
  if (current === 'privacy') {
    for (const m of live()) {
      const f = $('.feed', m.el);
      if (f) f.innerHTML = feed.map((x) => `<div class="${x.blocked ? 'blocked' : ''}"><span>${esc(x.host)}</span><span>${x.blocked ? `403 · ${esc(x.why)}` : `DoH → ${x.ip}`}</span></div>`).join('');
      const s = $('.shield-status > .dim', m.el);
      if (s) s.textContent = `${stats.requests} requests · ${stats.blocked} refused`;
    }
  }
}

async function shieldChanged(on) {
  clearInterval(feedTimer);
  if (on) {
    notify({ icon: 'shield', title: 'Privacy Shield is on', subtitle: `127.0.0.1:${String(settings.shieldPort)} · ${providerName()}`, tint: 'green' });
    feedTimer = setInterval(feedTick, 1600);
  } else {
    notify({ icon: 'shield', title: 'Privacy Shield is off', subtitle: 'Proxy settings restored. Open connections may finish for up to 30 s.', tint: 'plain' });
  }
}

// ---------------------------------------------------------------- Homebrew (simulated)

async function brewRun(lines, done) {
  brew.busy = true;
  brew.log = [];
  render();
  for (const l of lines) {
    brew.log.push(l);
    render();
    await sleep(320 + Math.random() * 300);
  }
  brew.busy = false;
  done?.();
  render();
}

// ---------------------------------------------------------------- rendering and events

function renderSidebar(m, filter = '') {
  const q = filter.trim().toLowerCase();
  $('.side-list', m.el).innerHTML = TABS.map((t) => {
    if (t.sep) return q ? '' : '<li class="side-sep" role="presentation"></li>';
    if (q && !`${t.title} ${t.keys}`.toLowerCase().includes(q)) return '';
    return `<li><button type="button" class="side-item ${t.id === current ? 'on' : ''}" data-tab="${t.id}" aria-current="${t.id === current ? 'page' : 'false'}"><span class="tile-ic small tint-${t.tint}">${icon(t.icon)}</span>${t.title}</button></li>`;
  }).join('') || '<li class="dim side-none">No results</li>';
}

const KEEP_FOCUS = '[data-port-search], [data-brew-search], [data-un-search]';

function renderMount(m) {
  const full = m.kind === 'full';
  const pane = full ? $('.pane-body', m.el) : m.el;
  if (full) $('.pane-title', m.el).textContent = TABS.find((t) => t.id === current).title;
  const scroll = pane.scrollTop;
  const active = document.activeElement;
  const keep = active && pane.contains(active) && active.matches(KEEP_FOCUS) ? { sel: KEEP_FOCUS.split(', ').find((q) => active.matches(q)), pos: active.selectionStart } : null;
  pane.innerHTML = panes[full ? current : m.pane]();
  pane.scrollTop = scroll;
  if (keep) { const el = $(keep.sel, pane); el.focus(); el.setSelectionRange(keep.pos, keep.pos); }
  if (full) renderSidebar(m, $('.side-search input', m.el).value);
}

function render() {
  for (const m of [...mounts]) {
    if (!m.el.isConnected) { mounts.delete(m); continue; }
    if (m.el.closest('[hidden]')) continue;
    renderMount(m);
  }
}

function selectTab(id, m) {
  current = id;
  if (m) $('.pane-body', m.el).scrollTop = 0;
  render();
  if (id === 'shortcuts') bus.emit('tour', 'settings');
}

/** Settings with its sidebar, in `el` (the island's Settings page, or the window). Returns what unmounts it. */
export function mountSettings(el, tab) {
  if (tab && panes[tab]) current = tab;
  el.innerHTML = `<div class="settings">
    <aside class="side">
      <div class="side-search">${icon('search')}<input type="search" placeholder="Search" aria-label="Search settings"></div>
      <div class="side-app"><img src="assets/app-icon.png" width="36" height="36" alt=""><span><b>Zenith</b><span>Version ${VERSION}</span></span></div>
      <ul class="side-list" role="list"></ul>
    </aside>
    <section class="pane"><h3 class="pane-title"></h3><div class="pane-body"></div></section>
  </div>`;
  return mount(el, 'full');
}

/** One pane without the sidebar: the island's Cleaner, Ports and Homebrew pages. */
export function mountPane(el, pane, arg) {
  if (pane === 'cleaner' && arg?.tab) cleanTab = arg.tab;
  return mount(el, 'pane', pane);
}

function mount(el, kind, pane) {
  const m = { el, kind, pane };
  mounts.add(m);
  el.dataset.mount = kind;
  el.addEventListener('click', onClick);
  el.addEventListener('change', onChange);
  el.addEventListener('input', onInput);
  el.addEventListener('submit', onSubmit);
  if (kind === 'full') {
    $('.side-search input', el).addEventListener('input', (e) => {
      renderSidebar(m, e.target.value);
      const first = $('.side-item', el);
      if (first && e.target.value) selectTab(first.dataset.tab, m);
    });
  }
  renderMount(m);
  return () => {
    mounts.delete(m);
    el.removeEventListener('click', onClick);
    el.removeEventListener('change', onChange);
    el.removeEventListener('input', onInput);
    el.removeEventListener('submit', onSubmit);
  };
}

const mountOf = (e) => [...mounts].find((m) => m.el.contains(e.target));

async function onClick(e) {
  const t = e.target;
  const tab = t.closest('[data-tab]');
  if (tab) { selectTab(tab.dataset.tab, mountOf(e)); return; }
  const step = t.closest('[data-step]');
  if (step) {
    const k = step.dataset.step;
    setSetting(k, Math.min(Number(step.dataset.max), Math.max(Number(step.dataset.min), settings[k] + Number(step.dataset.delta))));
    render();
    return;
  }
  const rec = t.closest('[data-record]');
  if (rec) { recordShortcut(rec); return; }
  if (t.closest('[data-reset-key]')) { const id = t.closest('[data-reset-key]').dataset.resetKey; const s = { ...(settings.shortcuts ?? {}) }; delete s[id]; setSetting('shortcuts', s); render(); return; }
  if (t.closest('[data-alt]')) { const d = SHORTCUT_DEFS.find((x) => x.id === t.closest('[data-alt]').dataset.alt); setShortcut(d.id, d.alt); bus.emit('tour', 'shortcut'); render(); return; }
  if (t.closest('[data-play]')) { playSound(t.closest('[data-play]').dataset.play, { force: true }); return; }
  if (t.closest('[data-remove-ignored]')) { setSetting('ignoredApps', settings.ignoredApps.filter((a) => a !== t.closest('[data-remove-ignored]').dataset.removeIgnored)); render(); return; }
  if (t.closest('[data-unblock]')) { setSetting('blocklist', settings.blocklist.filter((d) => d !== t.closest('[data-unblock]').dataset.unblock)); render(); return; }
  if (t.closest('[data-unnever]')) { setSetting('neverBlock', settings.neverBlock.filter((d) => d !== t.closest('[data-unnever]').dataset.unnever)); render(); return; }
  if (t.closest('[data-port]')) { setSetting('shieldPort', Number(t.closest('[data-port]').dataset.port)); render(); return; }
  if (t.closest('[data-stop-port]')) { await ports.stop(Number(t.closest('[data-stop-port]').dataset.stopPort)); render(); return; }
  if (t.closest('[data-clean-tab]')) { cleanTab = t.closest('[data-clean-tab]').dataset.cleanTab; render(); return; }
  if (t.closest('[data-un-pick]')) { const a = uninstaller.find(t.closest('[data-un-pick]').dataset.unPick); if (a) unPick(a); return; }
  if (t.closest('[data-un-back]')) { un.app = null; un.items = []; un.scanning = false; render(); return; }
  if (t.closest('[data-un-run]')) { await unRun(); return; }
  if (t.closest('[data-un-refresh]')) { un.notice = ''; render(); return; }
  if (t.closest('[data-un-choose]')) { await unChoose(); return; }
  if (t.closest('[data-cat]')) { e.stopPropagation(); cleaner.toggle(cleanTab, Number(t.closest('[data-cat]').dataset.cat)); render(); return; }
  if (t.closest('[data-brew-tab]')) { brewTab = t.closest('[data-brew-tab]').dataset.brewTab; render(); return; }
  if (t.closest('[data-awake]')) { const v = t.closest('[data-awake]').dataset.awake; keepAwake.set(v === 'off' ? null : v === 'inf' ? Infinity : Number(v)); render(); return; }
  if (t.closest('[data-edit-snippet]')) { editSnippet(Number(t.closest('[data-edit-snippet]').dataset.editSnippet)); return; }
  if (t.closest('[data-del-snippet]')) {
    const i = Number(t.closest('[data-del-snippet]').dataset.delSnippet);
    if (await confirmDestructive({ title: `Delete ${snippetStore.list[i].name}?`, confirm: 'Delete', iconName: 'snippet' })) { snippetStore.list.splice(i, 1); snippetStore.save(); render(); }
    return;
  }
  const bi = t.closest('[data-brew-install]')?.dataset.brewInstall;
  if (bi) {
    const p = BREW_SEARCH.find((x) => x.name === bi);
    brewRun([`$ brew install ${p.cask ? '--cask ' : ''}${bi}`, `==> Fetching ${bi}`, `==> Downloading https://ghcr.io/v2/homebrew/core/${bi}/blobs/sha256:…`, `==> Pouring ${bi}--${p.latest}.arm64_sequoia.bottle.tar.gz`, `🍺  ${bi} ${p.latest} is installed (simulated)`], () => {
      brew.installed.push({ name: bi, version: p.latest, latest: p.latest, desc: p.desc, size: 3e6 + Math.random() * 4e7, cask: p.cask });
      notify({ icon: 'mug', title: `${bi} installed`, subtitle: 'Simulated: nothing ran on your computer', tint: 'amber' });
    });
    return;
  }
  const bu = t.closest('[data-brew-upgrade]')?.dataset.brewUpgrade;
  if (bu) {
    const p = brew.installed.find((x) => x.name === bu);
    brewRun([`$ brew upgrade ${bu}`, `==> Upgrading ${bu} ${p.version} -> ${p.latest}`, '==> Pouring bottle', `🍺  ${bu} ${p.latest} (simulated)`], () => { p.version = p.latest; });
    return;
  }
  const br = t.closest('[data-brew-remove]')?.dataset.brewRemove;
  if (br) {
    if (!await confirmDestructive({ title: `Uninstall ${br}?`, message: 'Runs brew uninstall. (Simulated on this page.)', confirm: 'Uninstall', iconName: 'mug' })) return;
    brewRun([`$ brew uninstall ${br}`, `Uninstalling ${br}... (simulated)`], () => { brew.installed = brew.installed.filter((x) => x.name !== br); });
    return;
  }
  const act = t.closest('[data-act]')?.dataset.act;
  if (!act) return;
  switch (act) {
    case 'check-update': {
      const b = t.closest('button');
      b.disabled = true;
      b.textContent = 'Checking…';
      await sleep(900);
      notify({ icon: 'check', title: `Zenith ${VERSION} is the newest version`, subtitle: 'In the app this asks GitHub; this page does not.' });
      render();
      break;
    }
    case 'clear-history':
      if (await confirmDestructive({ title: 'Clear All Unpinned Items?', message: 'This cannot be undone. Pinned items are kept.', confirm: 'Clear', iconName: 'clipboard' })) { clipboardStore.clearUnpinned(); render(); }
      break;
    case 'add-ignored': {
      const apps = ['Scratchpad', 'Read Me', 'Preview', 'Sketchbook', 'Vault'].filter((a) => !settings.ignoredApps.includes(a));
      if (!apps.length) { notify({ title: 'No other apps are open' }); break; }
      const i = await ask({ title: 'Choose an app to ignore', message: 'Copies made while it is in front are not kept in the history.', buttons: ['Cancel', ...apps] });
      if (i > 0) { setSetting('ignoredApps', [...settings.ignoredApps, apps[i - 1]]); render(); }
      break;
    }
    case 'cleaning': runAction('cleaningMode'); break;
    case 'reset-shortcuts': setSetting('shortcuts', null); render(); break;
    case 'timer-focus': island.startTimer('focus'); render(); break;
    case 'timer-break': island.startTimer('break'); render(); break;
    case 'timer-stop': island.stopTimer(); render(); break;
    case 'cal-allow': await askCalendar(); render(); break;
    case 'open-system': notify({ icon: 'gear', title: 'System Settings', subtitle: 'In the app this opens Privacy & Security at the right page.' }); break;
    case 'perm-check': notify({ icon: 'hand', title: 'Checked again', subtitle: 'Nothing changed.' }); break;
    case 'scan': await cleaner.scan(cleanTab); render(); break;
    case 'clean': await cleaner.clean(cleanTab); render(); break;
    case 'boost': await boost(); render(); break;
    case 'scheduled': {
      t.closest('button').disabled = true;
      await cleaner.scan('system');
      notify({ icon: 'sparkles', title: `${formatBytes(cleaner.selectedSize('system'))} can be cleaned`, subtitle: 'Scheduled scan · open Cleaner to review it. Nothing was deleted.', tint: 'purple', duration: 4200 });
      cleanTab = 'system';
      render();
      break;
    }
    case 'probe': probe(t.closest('[data-mount]')); break;
    case 'import-hosts': importHosts(); break;
    case 'add-snippet': editSnippet(-1); break;
    case 'export-snippets': {
      const a = document.createElement('a');
      a.href = URL.createObjectURL(new Blob([JSON.stringify(snippetStore.list, null, 2)], { type: 'application/json' }));
      a.download = 'Zenith Snippets.json';
      a.click();
      break;
    }
    case 'import-snippets': importSnippets(); break;
    case 'brew-update': brewRun(['$ brew update', '==> Updating Homebrew...', 'Already up-to-date. (simulated)']); break;
    case 'brew-upgrade-all': {
      const out = brew.installed.filter((p) => p.version !== p.latest);
      if (!await confirmDestructive({ title: `Upgrade ${out.length} packages?`, details: out.map((p) => `${p.name} ${p.version} → ${p.latest}`), confirm: 'Upgrade All', iconName: 'mug' })) break;
      brewRun(['$ brew upgrade', ...out.map((p) => `==> Upgrading ${p.name} ${p.version} -> ${p.latest}`), '🍺  Done (simulated)'], () => out.forEach((p) => { p.version = p.latest; }));
      break;
    }
    default: break;
  }
}

function onChange(e) {
  const el = e.target;
  if (el.dataset.unItem != null) { un.items[Number(el.dataset.unItem)].selected = el.checked; render(); return; }
  if (el.dataset.setting) {
    const type = el.dataset.type;
    const v = type === 'bool' ? el.checked : type === 'num' ? Number(el.value) : el.value;
    if (el.dataset.setting === 'calendarWidget' && v && settings.calendarAccess === 'notDetermined') {
      setSetting('calendarWidget', true);
      askCalendar().then(render);
      return;
    }
    setSetting(el.dataset.setting, v);
    if (el.type !== 'range') render();
    return;
  }
  if (el.dataset.sound) { setSetting('sounds', { ...settings.sounds, [el.dataset.sound]: el.value }); playSound(el.dataset.sound, { force: true }); return; }
  if (el.matches('[data-udp]')) { showUDP = el.checked; render(); return; }
  if (el.matches('[data-port-field]')) {
    const n = Number(el.value);
    if (Number.isInteger(n) && n >= 1 && n <= 65535) setSetting('shieldPort', n);
    else notify({ icon: 'xcircle', title: 'Not a port', subtitle: 'Use a number from 1 to 65535.', tint: 'red' });
    render();
  }
}

function onInput(e) {
  const el = e.target;
  if (el.matches('input[type="range"][data-setting]')) {
    setSetting(el.dataset.setting, Number(el.value));
    const val = el.parentElement.querySelector('.val');
    if (val) val.textContent = `${Number(el.value).toFixed(2)} s`;
  }
  if (el.matches('[data-port-search]')) { portQuery = el.value; render(); }
  if (el.matches('[data-brew-search]')) { brew.query = el.value; render(); }
  if (el.matches('[data-un-search]')) { un.query = el.value; render(); }
}

function onSubmit(e) {
  const form = e.target.closest('[data-form]');
  if (!form) return;
  e.preventDefault();
  const input = form.querySelector('input');
  const kind = form.dataset.form;
  if (kind === 'test') {
    const host = normalizeDomain(input.value || input.placeholder);
    const out = $('.test-result', form.closest('[data-mount]'));
    if (!host) { out.className = 'test-result bad'; out.textContent = 'That is not a site name (one-word names and public suffixes such as “com” are refused).'; return; }
    const v = verdict(host);
    out.className = `test-result ${v.kind}`;
    out.innerHTML = `<b>${esc(host)}</b> ${esc(v.text)}`;
    if (settings.shieldOn) bus.emit('tour', 'shield');
    return;
  }
  const d = normalizeDomain(input.value);
  if (!d) { notify({ icon: 'xcircle', title: 'Not added', subtitle: 'Use a full name such as ads.example.com; one-word names and public suffixes are refused.', tint: 'red' }); return; }
  if (kind === 'block' && !settings.blocklist.includes(d)) setSetting('blocklist', [...settings.blocklist, d]);
  if (kind === 'never' && !settings.neverBlock.includes(d)) setSetting('neverBlock', [...settings.neverBlock, d]);
  render();
}

async function askCalendar() {
  const i = await ask({ title: '“Zenith” would like to access your calendars.', message: 'Zenith shows your next event on the island. (This prompt is the demo’s; nothing on your computer is asked.)', buttons: ['Don’t Allow', 'Allow'], iconName: 'calendar' });
  setSetting('calendarAccess', i === 1 ? 'granted' : 'denied');
}

function recordShortcut(btn) {
  const id = btn.dataset.record;
  btn.classList.add('recording');
  btn.textContent = 'Type shortcut…';
  const release = captureKeys((e) => {
    if (e.type !== 'keydown') return true;
    if (['Shift', 'Control', 'Alt', 'Meta', 'OS'].includes(e.key)) return true;
    if (e.key === 'Escape') { done(); return true; }
    if (e.key === 'Backspace' || e.key === 'Delete') { setShortcut(id, null); done(); return true; }
    const c = eventCombo(e);
    if (!c.meta && !c.ctrl && !c.alt && !/^F\d+$/.test(c.code)) { btn.textContent = 'Add ⌘, ⌃ or ⌥'; return true; }
    const clash = SHORTCUT_DEFS.find((d) => d.id !== id && comboText(shortcutFor(d.id)) === comboText(c));
    if (clash) { notify({ icon: 'cmd', title: `${comboText(c)} is taken`, subtitle: `${clash.title} uses it.`, tint: 'red' }); done(); return true; }
    setShortcut(id, c);
    bus.emit('tour', 'shortcut');
    notify({ icon: 'cmd', title: `${SHORTCUT_DEFS.find((d) => d.id === id).title}: ${comboText(c)}`, subtitle: 'Try it now.' });
    done();
    return true;
  });
  const done = () => { release(); render(); };
  const away = (ev) => { if (!btn.contains(ev.target)) { document.removeEventListener('pointerdown', away, true); if (btn.isConnected && btn.classList.contains('recording')) done(); } };
  document.addEventListener('pointerdown', away, true);
}

function editSnippet(index) {
  const s = index >= 0 ? snippetStore.list[index] : { name: '', trigger: '', text: '' };
  const scrim = html`<div class="scrim"><form class="alert sheet" role="dialog" aria-modal="true" aria-label="${index >= 0 ? 'Edit Snippet' : 'New Snippet'}">
    <h3>${index >= 0 ? 'Edit Snippet' : 'New Snippet'}</h3>
    <label class="field-row">Name<input type="text" class="field" name="name" value="${esc(s.name)}" required></label>
    <label class="field-row">Trigger<input type="text" class="field" name="trigger" value="${esc(s.trigger)}" placeholder=";sig"><span class="dim">Optional. A short word you would not type by accident, such as ;sig.</span></label>
    <label class="field-row">Text<textarea class="field" name="text" rows="4">${esc(s.text)}</textarea></label>
    <div class="field-row">Preview<pre class="snippet-preview"></pre><span class="dim">Shown with the clipboard and time right now; | marks where the caret ends up.</span></div>
    <div class="alert-buttons"><button type="button" class="btn" data-cancel>Cancel</button><button type="submit" class="btn btn-primary">Save</button></div>
  </form></div>`;
  const form = $('form', scrim);
  const preview = () => { const { text, cursor } = expandSnippet(form.text.value); $('.snippet-preview', scrim).textContent = `${text.slice(0, cursor)}|${text.slice(cursor)}`; };
  form.addEventListener('input', preview);
  form.addEventListener('submit', (e) => {
    e.preventDefault();
    const v = { name: form.name.value.trim() || 'Untitled', trigger: form.trigger.value.trim(), text: form.text.value };
    if (index >= 0) snippetStore.list[index] = v; else snippetStore.list.push(v);
    snippetStore.save();
    scrim.remove();
    render();
  });
  $('[data-cancel]', scrim).addEventListener('click', () => scrim.remove());
  scrim.addEventListener('keydown', (e) => { if (e.key === 'Escape') { e.stopPropagation(); scrim.remove(); } });
  document.body.append(scrim);
  preview();
  form.name.focus();
}

function pickFile(accept, fn) {
  const input = document.createElement('input');
  input.type = 'file';
  input.accept = accept;
  input.addEventListener('change', async () => { const f = input.files[0]; if (f) fn(await f.text()); });
  input.click();
}

function importHosts() {
  pickFile('.txt,.hosts,text/plain', (text) => {
    const found = new Set();
    for (const line of text.split('\n')) {
      const parts = line.replace(/#.*/, '').trim().split(/\s+/);
      const name = parts.length > 1 ? parts[1] : parts[0];
      const d = name && normalizeDomain(name);
      if (d && d !== 'localhost') found.add(d);
    }
    setSetting('blocklist', [...new Set([...settings.blocklist, ...found])]);
    notify({ icon: 'shield', title: `Imported ${found.size} domains`, subtitle: 'Read in your browser; the file was not uploaded.' });
    render();
  });
}

function importSnippets() {
  pickFile('.json,application/json', (text) => {
    try {
      const list = JSON.parse(text).filter((s) => s && typeof s.text === 'string').map((s) => ({ name: String(s.name ?? 'Untitled'), trigger: String(s.trigger ?? ''), text: s.text }));
      snippetStore.list.push(...list);
      snippetStore.save();
      notify({ icon: 'snippet', title: list.length === 1 ? 'Imported 1 snippet' : `Imported ${list.length} snippets` });
      render();
    } catch { notify({ icon: 'xcircle', title: 'Not a snippets file', tint: 'red' }); }
  });
}

async function probe(scope) {
  const box = $('.probe', scope);
  box.hidden = false;
  const steps = [
    settings.shieldOn ? `Local proxy answers on 127.0.0.1:${String(settings.shieldPort)}` : 'Local proxy is not running — turn Privacy Shield on first',
    `DoH lookup of example.com through ${providerName()}`,
    'CONNECT example.com:443 through the proxy',
    'TLS ClientHello split into 2 + rest, 5 ms apart',
    'HTTP/1.1 plain request relayed with Connection: close',
  ];
  box.innerHTML = '';
  for (const [i, s] of steps.entries()) {
    await sleep(500);
    const ok = settings.shieldOn || i > 0 ? settings.shieldOn : false;
    box.insertAdjacentHTML('beforeend', `<div class="${ok ? 'ok' : 'bad'}">${icon(ok ? 'check' : 'x')}${esc(s)}</div>`);
    if (!settings.shieldOn) break;
  }
}

export function initSettings() {
  registerWindow('settings', {
    app: 'Zenith', title: 'Zenith Settings', width: 820, height: 600,
    build(body, el) {
      el.classList.add('win-settings');
      el.querySelector('.win-title').textContent = '';
      mountSettings(body);
    },
    onOpen(tab) {
      if (tab && panes[tab]) current = tab;
      render();
    },
  });
  // Every way to Settings (⌘, menus, the Read Me) opens the island's Settings page; the window is only for while a
  // full-screen window hides the island.
  registerAction('settings', (tab) => {
    if (!island.openPage('settings', { tab })) openWindow('settings', tab);
  });
  island.registerPage('settings', { mount: (el, arg) => mountSettings(el, arg?.tab) });
  island.registerPage('cleaner', { mount: (el, arg) => mountPane(el, 'cleaner', arg) });
  island.registerPage('ports', { mount: (el) => mountPane(el, 'ports') });
  island.registerPage('homebrew', { mount: (el) => mountPane(el, 'homebrew') });
  bus.on('setting:shieldOn', shieldChanged);
  if (settings.shieldOn) feedTimer = setInterval(feedTick, 1600);
  // Turning the island off while its Settings page is open: the settings move to the window.
  bus.on('setting:islandEnabled', (on) => {
    if (on || island.state.page !== 'settings') return;
    island.close();
    openWindow('settings', current);
  });
  ['timer', 'cleaner', 'ports', 'system', 'keep-awake', 'snippets', 'uninstalled', 'setting:shieldOn', 'setting:calendarAccess', 'setting:ignoredApps', 'setting:islandEnabled', 'setting:notch'].forEach((t) => bus.on(t, () => {
    // Re-render quietly; the timer only matters on its own pane.
    if (t === 'timer' && current !== 'island') return;
    const active = document.activeElement;
    if (active && live().some((m) => m.el.contains(active)) && active.matches('input[type="text"], input[type="search"], textarea, select')) return;
    render();
  }));
}
