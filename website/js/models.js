// State that the Command Hub and Settings share: cleaner scans, processes, ports, memory and disk.
import { bus, confirmDestructive, ask, notify, formatBytes, playSound, sleep, settings, setSetting, store } from './core.js';
import { CLEANER, PROCESSES, PORTS, APPS } from './data.js';

export const system = {
  diskTotal: 494e9,
  diskFree: 212e9,
  memTotal: 16e9,
  memUsed: 10.4e9,
  cpu: 31,
};

// ---------------------------------------------------------------- cleaner

const clone = (o) => JSON.parse(JSON.stringify(o));
export const cleaner = {
  tabs: Object.fromEntries(Object.keys(CLEANER).map((k) => [k, { state: 'idle', categories: [] }])),
  info: (tab) => CLEANER[tab],

  async scan(tab) {
    const t = this.tabs[tab];
    t.state = 'scanning';
    bus.emit('cleaner', tab);
    await sleep(1400 + Math.random() * 600);
    t.categories = clone(CLEANER[tab].categories);
    t.state = 'done';
    bus.emit('cleaner', tab);
    return t;
  },

  selected(tab) {
    return this.tabs[tab].categories.filter((c) => c.selected).flatMap((c) => c.items.map(([name, size]) => ({ name, size, category: c.name })));
  },

  selectedSize(tab) { return this.selected(tab).reduce((a, i) => a + i.size, 0); },
  totalSize(tab) { return this.tabs[tab].categories.flatMap((c) => c.items).reduce((a, [, s]) => a + s, 0); },

  toggle(tab, index) {
    const c = this.tabs[tab].categories[index];
    c.selected = !c.selected;
    bus.emit('cleaner', tab);
  },

  /** Asks first, as the app does; removes nothing when declined. */
  async clean(tab) {
    const items = this.selected(tab);
    if (!items.length) return false;
    const size = this.selectedSize(tab);
    const deletes = CLEANER[tab].verb === 'Delete';
    const largest = [...items].sort((a, b) => b.size - a.size).slice(0, 4).map((i) => `${i.name} — ${formatBytes(i.size)}`);
    if (items.length > 4) largest.push(`and ${items.length - 4} more`);
    const ok = await confirmDestructive({
      title: deletes ? `Delete ${items.length === 1 ? '1 item' : `${items.length} items`} (${formatBytes(size)})?` : `Move ${items.length === 1 ? '1 item' : `${items.length} items`} (${formatBytes(size)}) to the Trash?`,
      message: deletes ? 'These will be permanently deleted and cannot be restored.' : 'Largest first:',
      details: largest,
      confirm: deletes ? 'Delete' : `Clean ${formatBytes(size)}`,
      iconName: 'sparkles',
    });
    if (!ok) return false;
    const t = this.tabs[tab];
    t.categories = t.categories.filter((c) => !c.selected);
    t.state = t.categories.length ? 'done' : 'clean';
    system.diskFree += size;
    if (!deletes) bus.emit('trash:add', items.map((i) => ({ name: i.name, size: i.size })));
    bus.emit('cleaner', tab);
    bus.emit('system');
    bus.emit('tour', 'cleaner');
    playSound('delete');
    notify({ icon: 'sparkles', title: `Cleaned ${formatBytes(size)}`, subtitle: deletes ? `${items.length} items deleted` : `${items.length} items moved to the Trash`, tint: 'green' });
    return true;
  },
};

// ---------------------------------------------------------------- processes

export const processes = {
  list: PROCESSES.map((p) => ({ ...p })),
  jitter() {
    for (const p of this.list) p.cpu = Math.max(0.3, Math.min(95, p.cpu * (0.8 + Math.random() * 0.4)));
    system.cpu = Math.round(Math.min(96, this.list.reduce((a, p) => a + p.cpu, 0) / 3 + 6));
    system.memUsed = Math.max(4e9, Math.min(15.2e9, system.memUsed + (Math.random() - 0.5) * 1.2e8));
  },
  async quit(name) {
    const p = this.list.find((x) => x.name === name);
    if (!p) return;
    const ok = await confirmDestructive({ title: `Quit ${name}?`, message: 'Zenith asks it to quit, then forces it if it does not. Unsaved changes in it may be lost.', confirm: 'Quit', iconName: p.icon });
    if (!ok) return;
    this.list = this.list.filter((x) => x !== p);
    system.memUsed = Math.max(3e9, system.memUsed - p.mem);
    bus.emit('processes');
    bus.emit('system');
    notify({ icon: 'check', title: `${name} quit`, subtitle: `${formatBytes(p.mem)} of memory freed`, tint: 'green' });
  },
};

// ---------------------------------------------------------------- ports

export const ports = {
  list: PORTS.map((p) => ({ ...p })),
  async stop(port) {
    const p = this.list.find((x) => x.port === port);
    if (!p) return;
    const ok = await confirmDestructive({ title: `Stop ${p.process} on port ${String(p.port)}?`, message: `It is process ${String(p.pid)}. Zenith sends it SIGTERM, then SIGKILL if it does not stop.`, confirm: 'Stop', iconName: 'port' });
    if (!ok) return;
    this.list = this.list.filter((x) => x !== p);
    bus.emit('ports');
    notify({ icon: 'port', title: `Port ${String(p.port)} is free`, subtitle: `${p.process} stopped`, tint: 'green' });
    bus.emit('tour', 'ports');
  },
};

// ---------------------------------------------------------------- boost

export async function boost() {
  await sleep(700);
  const freed = Math.min(system.memUsed - 4e9, 1.1e9 + Math.random() * 6e8);
  system.memUsed -= freed;
  bus.emit('system');
  notify({ icon: 'boost', title: 'Boost done', subtitle: `Freed ${formatBytes(freed)} of inactive memory and flushed the DNS cache`, tint: 'green', duration: 3600 });
}

// ---------------------------------------------------------------- Keep Awake

const clockText = (ms) => new Date(ms).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });

export const keepAwake = {
  until: null,
  timer: 0,
  /** minutes, Infinity for "until turned off", null to turn it off. `quiet` skips the notice (the island is open). */
  set(minutes, { quiet = false } = {}) {
    clearTimeout(this.timer);
    if (minutes == null) {
      const was = this.until != null;
      this.until = null;
      if (!quiet && was) notify({ icon: 'cup', title: 'Keep Awake is off', subtitle: 'The Mac sleeps as set in System Settings.' });
    } else {
      this.until = minutes === Infinity ? Infinity : Date.now() + minutes * 60000;
      if (minutes !== Infinity) this.timer = setTimeout(() => this.set(null), minutes * 60000);
      const label = minutes === Infinity ? 'until you turn it off' : minutes >= 60 ? `for ${minutes / 60} h` : `for ${minutes} min`;
      if (!quiet) notify({ icon: 'cup', title: 'Keeping your Mac awake', subtitle: `${label}${settings.keepAwakeDisplay ? ', display on' : ''}` });
      bus.emit('tour', 'awake');
    }
    bus.emit('keep-awake', this.until);
  },
  get on() { return this.until != null; },
  /** "58 min left", "1 h 5 min left" or "until turned off". */
  leftText() {
    if (this.until == null) return 'Off';
    if (this.until === Infinity) return 'On until turned off';
    const m = Math.max(1, Math.ceil((this.until - Date.now()) / 60000));
    return m >= 60 ? `${Math.floor(m / 60)} h${m % 60 ? ` ${m % 60} min` : ''} left` : `${m} min left`;
  },
  /** For the closed island's wing: "58m", "1h 5m" or "∞". */
  shortText() {
    if (this.until === Infinity) return '∞';
    const m = Math.max(1, Math.ceil((this.until - Date.now()) / 60000));
    return m >= 60 ? `${Math.floor(m / 60)}h${m % 60 ? ` ${m % 60}m` : ''}` : `${m}m`;
  },
};

export const AWAKE_CHOICES = [['15 min', 15], ['1 h', 60], ['2 h', 120], ['5 h', 300], ['Until Turned Off', Infinity]];

export function keepAwakeMenuItems() {
  const on = keepAwake.on;
  return [
    { header: on ? (keepAwake.until === Infinity ? 'Awake until turned off' : `Awake until ${clockText(keepAwake.until)}`) : 'Keep Awake is off' },
    { label: '15 Minutes', action: () => keepAwake.set(15) },
    { label: '1 Hour', action: () => keepAwake.set(60) },
    { label: '2 Hours', action: () => keepAwake.set(120) },
    { label: '5 Hours', action: () => keepAwake.set(300) },
    { label: 'Until Turned Off', action: () => keepAwake.set(Infinity) },
    { separator: true },
    { label: 'Keep the Display On', checked: settings.keepAwakeDisplay, action: () => setSetting('keepAwakeDisplay', !settings.keepAwakeDisplay) },
    { label: 'Turn Off', disabled: !on, action: () => keepAwake.set(null) },
  ];
}

// ---------------------------------------------------------------- app uninstaller (Settings → Cleaner → Uninstall)

export const uninstaller = {
  /** Installed apps that are still on this pretend Mac. */
  apps() {
    const gone = store.get('removedApps', []);
    return APPS.filter((a) => !gone.includes(a.file));
  },
  find: (file) => APPS.find((a) => a.file === file),
  /** What goes with the app, each with its size; a file matched only by the app's name is not ticked. */
  items(app) {
    return [
      { path: app.path, size: app.size, app: true, selected: true },
      ...app.files.map((f) => ({ path: f.path, size: f.size, nameOnly: !!f.nameOnly, selected: !f.nameOnly })),
    ];
  },

  /** Asks first; an open app is asked to quit before anything moves. Returns whether the app went to the Trash. */
  async run(app, items, { title } = {}) {
    const chosen = items.filter((i) => i.selected);
    if (!chosen.length) return false;
    const size = chosen.reduce((a, i) => a + i.size, 0);
    const leftovers = chosen.filter((i) => !i.app).length;
    const list = [...chosen].sort((a, b) => b.size - a.size).slice(0, 5).map((i) => `${i.path.replace(/^.*\//, '') || i.path} — ${formatBytes(i.size)}`);
    if (chosen.length > 5) list.push(`and ${chosen.length - 5} more`);
    const ok = await confirmDestructive({
      title: title ?? `Move ${app.name} and ${leftovers === 1 ? '1 file' : `${leftovers} files`} (${formatBytes(size)}) to the Trash?`,
      message: 'Everything goes to the Trash; nothing is deleted for good. Apple-owned entries are never touched.',
      details: list,
      confirm: 'Move to Trash',
      iconName: 'trash',
    });
    if (!ok) return false;
    if (app.running) {
      const i = await ask({ title: `${app.name} is open`, message: `Zenith asks it to quit first. If it stays open, nothing is removed.`, buttons: ['Leave It Open', `Quit ${app.name}`], iconName: app.icon });
      if (i !== 1) { notify({ icon: 'xcircle', title: `${app.name} is still open`, subtitle: 'Nothing was moved to the Trash.', tint: 'plain' }); return false; }
      app.running = false;
      const p = processes.list.find((x) => x.name === app.name);
      if (p) { processes.list = processes.list.filter((x) => x !== p); system.memUsed = Math.max(3e9, system.memUsed - p.mem); bus.emit('processes'); bus.emit('system'); }
    }
    bus.emit('trash:add', chosen.map((i) => ({ name: i.app ? app.file : i.path.replace(/^.*\//, ''), size: i.size })));
    bus.emit('app-removed', app.file);
    bus.emit('uninstalled', app.file);
    bus.emit('tour', 'uninstall');
    playSound('delete');
    notify({ icon: 'trash', title: `${app.name} moved to the Trash`, subtitle: `${chosen.length === 1 ? '1 item' : `${chosen.length} items`}, ${formatBytes(size)}`, tint: 'green' });
    return true;
  },
};
