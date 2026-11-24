// The island's System page: what the machine is doing. Running apps, CPU, memory, storage and network speed, shared with the
// Command Hub (hub.js). It only samples while it is open.
import { $, bus, esc, icon } from './core.js';
import { processes } from './models.js';
import { island } from './island.js';
import { appsHTML, metersHTML, jitterSpeed, handleQuitClicks } from './hub.js';

function mountSystem(el) {
  el.innerHTML = `<div class="sys">
    <div class="hub-search">${icon('search')}<input type="text" placeholder="Search running apps" aria-label="Search running apps" autocomplete="off" spellcheck="false"></div>
    <div class="hub-meters hub-module"></div>
    <div class="sys-dyn"></div>
  </div>`;
  const input = $('input', el);
  let query = '';
  const render = () => {
    const q = query.trim().toLowerCase();
    const { apps, portRows, html } = appsHTML(q);
    $('.sys-dyn', el).innerHTML = html + (!apps.length && !portRows.length ? `<div class="hub-none">Nothing matches “${esc(query)}”.</div>` : '');
    $('.hub-meters', el).hidden = !!q;
    $('.hub-meters', el).innerHTML = q ? '' : metersHTML();
  };
  input.addEventListener('input', () => { query = input.value; render(); });
  el.addEventListener('click', handleQuitClicks);
  const off = ['processes', 'ports', 'system'].map((t) => bus.on(t, render));
  const ticker = setInterval(() => { processes.jitter(); jitterSpeed(); render(); }, 2500);
  render();
  return () => { clearInterval(ticker); off.forEach((f) => f()); el.removeEventListener('click', handleQuitClicks); };
}

function mountDisplays(el) {
  el.innerHTML = `<div class="displays-page" style="padding:14px;display:flex;flex-direction:column;gap:10px;">
    <div class="hub-module" style="padding:12px;border-radius:18px;display:flex;flex-direction:column;gap:8px;">
      <div style="display:flex;align-items:center;gap:8px;">
        <span style="font-size:13px;font-weight:600;color:var(--text-sec);">${icon('screen')}</span>
        <b style="font-size:13px;font-weight:600;color:var(--text-pri);flex:1;">Built-in Retina Display</b>
      </div>
      <div style="display:flex;align-items:center;gap:8px;">
        <span style="color:var(--text-sec);">${icon('sun')}</span>
        <input type="range" min="0" max="100" value="70" style="flex:1;accent-color:#64c4f8;" aria-label="Brightness of Built-in Retina Display">
        <span style="font-size:11.5px;font-variant-numeric:tabular-nums;color:var(--text-sec);width:34px;text-align:right;">70%</span>
      </div>
    </div>
    <div class="hub-module" style="padding:12px;border-radius:18px;display:flex;flex-direction:column;gap:8px;">
      <div style="display:flex;align-items:center;gap:8px;">
        <span style="font-size:13px;font-weight:600;color:var(--text-sec);">${icon('screen')}</span>
        <b style="font-size:13px;font-weight:600;color:var(--text-pri);flex:1;">Studio Monitor 27</b>
      </div>
      <div style="display:flex;align-items:center;gap:8px;">
        <span style="color:var(--text-sec);">${icon('sun')}</span>
        <input type="range" min="0" max="100" value="85" style="flex:1;accent-color:#64c4f8;" aria-label="Brightness of Studio Monitor 27">
        <span style="font-size:11.5px;font-variant-numeric:tabular-nums;color:var(--text-sec);width:34px;text-align:right;">85%</span>
      </div>
    </div>
  </div>`;
  el.querySelectorAll('input[type="range"]').forEach((slider) => {
    const val = slider.parentElement.querySelector('span:last-child');
    slider.addEventListener('input', () => { if (val) val.textContent = `${slider.value}%`; });
  });
  return () => {};
}

export function initPages() {
  island.registerPage('system', { mount: mountSystem });
  island.registerPage('displays', { mount: mountDisplays });
}
