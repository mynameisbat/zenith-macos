// The island's System page: what the machine is doing. Running apps, CPU, memory, storage and network speed, shared with the
// Command Hub (hub.js). It only samples while it is open.
import { $, bus, esc, icon } from './core.js';
import { processes } from './models.js';
import { island } from './island.js';
import { appsHTML, metersHTML, jitterSpeed, handleQuitClicks } from './hub.js';

function mountSystem(el) {
  el.innerHTML = `<div class="sys">
    <div class="hub-search">${icon('search')}<input type="text" placeholder="Search running apps" aria-label="Search running apps" autocomplete="off" spellcheck="false"></div>
    <div class="sys-dyn"></div>
    <div class="hub-meters"></div>
  </div>`;
  const input = $('input', el);
  let query = '';
  const render = () => {
    const q = query.trim().toLowerCase();
    const { apps, portRows, html } = appsHTML(q);
    $('.sys-dyn', el).innerHTML = html + (!apps.length && !portRows.length ? `<div class="hub-none">Nothing matches “${esc(query)}”.</div>` : '');
    $('.hub-meters', el).innerHTML = metersHTML();
  };
  input.addEventListener('input', () => { query = input.value; render(); });
  el.addEventListener('click', handleQuitClicks);
  const off = ['processes', 'ports', 'system'].map((t) => bus.on(t, render));
  const ticker = setInterval(() => { processes.jitter(); jitterSpeed(); render(); }, 2500);
  render();
  return () => { clearInterval(ticker); off.forEach((f) => f()); el.removeEventListener('click', handleQuitClicks); };
}

export function initPages() {
  island.registerPage('system', { mount: mountSystem });
}
