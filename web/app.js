const $ = (s, root = document) => root.querySelector(s);
const state = { user: null, repos: [], groups: [], namespaces: [], implementation: '', page: 0, navOpen: false };
const paths = {
  repo: 'M4 3h12a2 2 0 0 1 2 2v16H5a3 3 0 0 1-3-3V5a2 2 0 0 1 2-2Zm-2 15a3 3 0 0 1 3-3h13M7 7h6M7 10h4',
  search: 'm21 21-5-5M18 10a8 8 0 1 1-16 0 8 8 0 0 1 16 0',
  grid: 'M3 3h7v7H3zM14 3h7v7h-7zM3 14h7v7H3zM14 14h7v7h-7z',
  group: 'M3 7h7l2 2h9v11H3zM3 7V4h7l2 2h7',
  pin: 'm9 3 6 0-1 6 4 4v2H6v-2l4-4-1-6ZM12 15v6',
  branch: 'M6 6v12M6 12c8 0 12-1 12-6M8 4a2 2 0 1 1-4 0 2 2 0 0 1 4 0ZM8 20a2 2 0 1 1-4 0 2 2 0 0 1 4 0ZM20 4a2 2 0 1 1-4 0 2 2 0 0 1 4 0Z',
  plus: 'M12 5v14M5 12h14',
  clock: 'M12 7v5l3 2M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0',
  lock: 'M5 10h14v11H5zM8 10V6a4 4 0 0 1 8 0v4',
  globe: 'M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0M2 12h20M12 2c5 5 5 15 0 20-5-5-5-15 0-20',
  code: 'm8 5-7 7 7 7M16 5l7 7-7 7',
  external: 'M14 3h7v7M21 3 10 14M10 3H3v18h18v-7',
  pull: 'M6 6v12M8 4a2 2 0 1 1-4 0 2 2 0 0 1 4 0M8 20a2 2 0 1 1-4 0 2 2 0 0 1 4 0M20 20a2 2 0 1 1-4 0 2 2 0 0 1 4 0M18 18V8a4 4 0 0 0-4-4h-2m3-3-3 3 3 3',
  settings: 'M12 8a4 4 0 1 1 0 8 4 4 0 0 1 0-8M4 4l4-2 2 3h4l2-3 4 2-1 4 3 2v4l-3 2 1 4-4 2-2-3h-4l-2 3-4-2 1-4-3-2v-4l3-2-1-4Z',
  people: 'M17 21v-2a5 5 0 0 0-5-5H7a5 5 0 0 0-5 5v2M14 6a4 4 0 1 1-8 0 4 4 0 0 1 8 0M17 3a4 4 0 0 1 0 8M22 21v-2a5 5 0 0 0-4-5',
  terminal: 'm4 6 6 6-6 6M13 18h7',
  key: 'M15 3a6 6 0 1 1-3 11L5 21H2v-3l3-3h3l2-2a6 6 0 0 1 5-10ZM17 7h.01',
  logout: 'M9 3H3v18h6M9 12h12m-5-5 5 5-5 5',
  menu: 'M4 6h16M4 12h16M4 18h16',
  close: 'm6 6 12 12M18 6 6 18',
  file: 'M14 2H4v20h16V8l-6-6ZM14 2v6h6',
  chevron: 'm9 5 7 7-7 7',
  copy: 'M9 8h12v13H9zM5 16H2V2h13v3',
  check: 'm4 12 5 5L20 6',
  refresh: 'M21 4v6h-6M3 20v-6h6M4 9a8 8 0 0 1 13-5l4 6M3 14l4 6a8 8 0 0 0 13-5',
  sun: 'M16 12a4 4 0 1 1-8 0 4 4 0 0 1 8 0M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1.5 1.5M17.5 17.5 19 19M5 19l1.5-1.5M17.5 6.5 19 5',
  moon: 'M21 13a9 9 0 0 1-10-10 9 9 0 1 0 10 10Z',
};
function icon(name, extra = '') {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  for (const [k, v] of Object.entries({ viewBox: '0 0 24 24', fill: 'none', stroke: 'currentColor', 'stroke-width': '1.6', 'stroke-linecap': 'round', 'stroke-linejoin': 'round', 'aria-hidden': 'true', class: `icon ${extra}` })) svg.setAttribute(k, v);
  const path = document.createElementNS(svg.namespaceURI, 'path');
  path.setAttribute('d', paths[name] || paths.repo); svg.append(path); return svg;
}
function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs)) {
    if (value === null || value === undefined || value === false) continue;
    if (key.startsWith('on')) node.addEventListener(key.slice(2).toLowerCase(), value);
    else if (key === 'class') node.className = value;
    else if (key === 'text') node.textContent = value;
    else if (key === 'checked' || key === 'disabled' || key === 'hidden' || key === 'selected') node[key] = value;
    else if (key === 'value') node.value = value;
    else node.setAttribute(key, value === true ? '' : String(value));
  }
  for (const child of children.flat(Infinity)) if (child !== null && child !== undefined && child !== false) node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  return node;
}
function link(text, href, cls = '') { return el('a', { href, class: cls }, text); }
function button(text, action, cls = '', glyph = '') { return el('button', { type: 'button', class: `button ${cls}`, onClick: action }, glyph ? icon(glyph) : null, text); }
function actionLink(text, href, cls = '', glyph = '') { return el('a', { href, class: `button ${cls}` }, glyph ? icon(glyph) : null, text); }
function badge(text) { return el('span', { class: `badge ${['open', 'closed', 'merged', 'approve', 'request_changes'].includes(text) ? text : ''}` }, text.replaceAll('_', ' ')); }
function time(value) {
  const d = new Date(typeof value === 'string' && /^\d+$/.test(value) ? Number(value) : value);
  if (!Number.isFinite(d.getTime())) return el('span', {}, 'Unknown time');
  const seconds = Math.max(0, (Date.now() - d.getTime()) / 1000);
  const text = seconds < 60 ? 'just now' : seconds < 3600 ? `${Math.floor(seconds / 60)}m ago` : seconds < 86400 ? `${Math.floor(seconds / 3600)}h ago` : seconds < 604800 ? `${Math.floor(seconds / 86400)}d ago` : d.toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: d.getFullYear() === new Date().getFullYear() ? undefined : 'numeric' });
  return el('time', { datetime: d.toISOString(), title: d.toLocaleString() }, text);
}
function bytes(n) { return n < 1024 ? `${n || 0} B` : n < 1048576 ? `${(n / 1024).toFixed(1)} KiB` : `${(n / 1048576).toFixed(1)} MiB`; }
function query(values) { const p = new URLSearchParams(); for (const [k, v] of Object.entries(values)) if (v !== null && v !== undefined && v !== '') p.set(k, v); return p.size ? `?${p}` : ''; }
function repoPath(repo, section = 'code', params = {}) { return `/repos/${repo.id}/${section}${query(params)}`; }
function announce(message) { $('#announcer').textContent = message; }
async function api(path, method = 'GET', body) {
  const headers = { 'X-GitClub-Request': '1' };
  if (method !== 'GET') headers['Content-Type'] = 'application/json';
  const response = await fetch(path, { method, credentials: 'same-origin', headers, body: method === 'GET' ? undefined : JSON.stringify(body ?? {}) });
  let data; try { data = await response.json(); } catch { throw new Error(response.ok ? 'The server returned an unreadable response. Retry this action.' : `The server could not complete this request (${response.status}). Retry this action.`); }
  if (!response.ok) throw new Error(data.error || `Request failed (${response.status}).`);
  return data;
}
function errorBox(error) { return el('div', { class: 'error', role: 'alert' }, error.message || String(error)); }
function report(error) { const main = $('#main'); if (main) main.prepend(errorBox(error)); }
async function mutation(action, target) {
  if (target) target.disabled = true;
  try { await action(); } catch (error) { report(error); } finally { if (target?.isConnected) target.disabled = false; }
}
function heading(title, description = '', actions = []) { return el('div', { class: 'page-heading' }, el('div', {}, el('h1', {}, title), description ? el('p', {}, description) : null), actions.length ? el('div', { class: 'actions' }, actions) : null); }
function empty(title, description, actions = [], compact = false, glyph = 'repo') { return el('div', { class: `empty ${compact ? 'compact' : ''}` }, icon(glyph), el('h2', {}, title), el('p', {}, description), actions.length ? el('div', { class: 'actions' }, actions) : null); }
function section(title, description = '', ...children) { return el('section', { class: 'section' }, el('h2', {}, title), description ? el('p', { class: 'section-description' }, description) : null, children); }
let fieldSequence = 0;
function field(label, name, value = '', options = {}) {
  const id = `field-${++fieldSequence}`;
  const { type = 'text', help = '', choices, required = false, ...rest } = options;
  let control;
  if (choices) control = el('select', { id, name, required, ...rest }, choices.map(choice => { const item = typeof choice === 'string' ? { value: choice, label: choice } : choice; return el('option', { value: item.value, selected: String(item.value) === String(value) }, item.label); }));
  else control = el(type === 'textarea' ? 'textarea' : 'input', { id, name, ...(type === 'textarea' ? {} : { type }), required, ...rest });
  if (!choices) control.value = value ?? '';
  if (help) control.setAttribute('aria-describedby', `${id}-help`);
  return el('div', { class: 'field' }, el('label', { for: id }, label), control, help ? el('small', { id: `${id}-help` }, help) : null);
}
function checkbox(label, name, checked = false, value = 'on') { return el('label', { class: 'checkbox-label' }, el('input', { type: 'checkbox', name, checked, value }), label); }
function draftKey(scope, name) { return `gitclub:draft:${state.user?.id || 'anonymous'}:${scope}:${name}`; }
function withDraft(node, scope) {
  for (const area of node.querySelectorAll('textarea')) {
    const key = draftKey(scope, area.name);
    try { const draft = localStorage.getItem(key); if (draft !== null) area.value = draft; } catch { /* Browser may disable local storage. */ }
    area.addEventListener('input', () => { try { localStorage.setItem(key, area.value); } catch { /* Draft storage is optional. */ } });
  }
  node.clearDraft = () => { for (const area of node.querySelectorAll('textarea')) try { localStorage.removeItem(draftKey(scope, area.name)); } catch { /* Draft storage is optional. */ } };
  return node;
}
function form(fields, submitLabel, submit, options = {}) {
  const status = el('div', { class: 'form-status', role: 'status' });
  const errors = el('div', {});
  const submitButton = el('button', { type: 'submit', class: `button ${options.danger ? 'danger' : 'primary'}` }, submitLabel);
  const node = el('form', { class: `form ${options.class || ''}` }, errors, fields, el('div', { class: 'form-footer' }, submitButton, options.cancel ? actionLink('Cancel', options.cancel) : null, status));
  node.addEventListener('submit', async event => {
    event.preventDefault(); errors.replaceChildren(); status.textContent = ''; submitButton.disabled = true; submitButton.textContent = 'Saving…';
    try {
      const values = Object.fromEntries(new FormData(node));
      for (const input of node.querySelectorAll('input[type=checkbox]')) if (!input.name.endsWith('[]')) values[input.name] = input.checked;
      await submit(values, node, status);
    } catch (error) { errors.replaceChildren(errorBox(error)); errors.scrollIntoView({ block: 'nearest' }); }
    finally { submitButton.disabled = false; submitButton.textContent = submitLabel; }
  });
  if (options.draft) withDraft(node, options.draft);
  return node;
}
function codeBlock(text) {
  const copy = button('Copy', async () => {
    try { await navigator.clipboard.writeText(text); copy.replaceChildren(icon('check'), 'Copied'); announce('Copied to clipboard'); setTimeout(() => { if (copy.isConnected) copy.replaceChildren(icon('copy'), 'Copy'); }, 1800); }
    catch { const range = document.createRange(); range.selectNodeContents(pre); const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range); copy.textContent = 'Selected. Press Ctrl/Cmd+C'; }
  }, 'small', 'copy');
  const pre = el('pre', {}, text);
  return el('div', { class: 'code-block' }, pre, el('div', { class: 'code-block-footer' }, copy));
}
function setNav(open) { state.navOpen = open; $('.shell')?.classList.toggle('nav-open', open); $('.mobile-menu')?.setAttribute('aria-expanded', String(open)); const workspace = $('.workspace'); if (workspace) workspace.inert = open; if (open) $('.nav-close')?.focus(); }
function navLink(label, href, glyph, selected = false) { return el('a', { href, class: `nav-link ${selected ? 'active' : ''}`, ...(selected ? { 'aria-current': 'page' } : {}) }, icon(glyph), el('span', {}, label)); }
function smallRepo(repo) { return el('a', { href: repoPath(repo), class: `nav-link repo-nav ${location.pathname.startsWith(`/repos/${repo.id}/`) ? 'active' : ''}`, title: repo.full_name }, icon('repo'), el('span', { class: 'name' }, repo.full_name)); }
function renderSidebar() {
  const sidebar = $('.sidebar'); if (!sidebar) return;
  const signed = !!state.user;
  const pins = state.repos.filter(repo => repo.pinned);
  const others = state.repos.filter(repo => !repo.pinned);
  const current = location.pathname;
  const brand = el('a', { href: '/repos', class: 'brand', 'aria-label': 'GitClub repositories' }, el('img', { src: '/favicon.svg', alt: '', class: 'brand-mark', width: 28, height: 28 }), 'GitClub');
  const close = el('button', { type: 'button', class: 'subtle-button nav-close', 'aria-label': 'Close navigation', onClick: () => { setNav(false); $('.mobile-menu')?.focus(); } }, icon('close'));
  const switcher = el('button', { type: 'button', class: 'switcher-trigger', onClick: openSwitcher, 'aria-label': 'Find a repository. Control or Command K' }, icon('search'), 'Find a repository', el('kbd', {}, '⌘ K'));
  const primary = el('nav', { 'aria-label': 'Workspace' }, navLink('Repositories', '/repos', 'repo', current === '/repos'), signed ? navLink('Groups', '/groups', 'group', current.startsWith('/groups')) : null, signed ? navLink('Namespaces', '/namespaces', 'people', current.startsWith('/namespaces')) : null);
  const scroll = el('div', { class: 'sidebar-scroll' },
    el('div', { class: 'nav-section' }, el('div', { class: 'nav-caption' }, 'Pinned'), pins.length ? pins.map(smallRepo) : el('p', { class: 'nav-empty' }, signed ? 'Pin a repository to keep it here.' : 'Sign in to pin repositories.')),
    state.groups.length ? el('div', { class: 'nav-section' }, el('div', { class: 'nav-caption' }, 'Groups', el('a', { href: '/groups/new', 'aria-label': 'Create a group', title: 'Create a group' }, '+')), state.groups.map(group => el('details', { class: 'group-nav' }, el('summary', {}, group.name), state.repos.filter(repo => group.repo_ids.includes(repo.id)).map(smallRepo), el('a', { href: `/repos?group=${group.id}`, class: 'nav-link repo-nav' }, 'View group')))) : null,
    el('div', { class: 'nav-section' }, el('div', { class: 'nav-caption' }, 'Default branch activity'), others.length ? others.map(smallRepo) : el('p', { class: 'nav-empty' }, pins.length ? 'All repositories are pinned.' : 'Your repositories appear here.')));
  const footer = el('div', { class: 'sidebar-footer' }, signed ? navLink('Agent access', '/agents', 'terminal', current === '/agents') : null, signed ? navLink('SSH keys', '/settings/ssh', 'key', current === '/settings/ssh') : null,
    signed ? el('div', { class: 'account' }, el('span', { class: 'avatar', 'aria-hidden': 'true' }, state.user.username.slice(0, 2)), el('span', { class: 'account-name' }, state.user.username), el('button', { class: 'subtle-button', type: 'button', title: 'Sign out', 'aria-label': 'Sign out', onClick: e => mutation(async () => { await api('/api/auth/logout', 'POST'); state.user = null; state.groups = []; state.namespaces = []; await refreshWorkspace(); go('/login'); }, e.currentTarget) }, icon('logout'))) : actionLink('Sign in', '/login', 'primary'),
    el('div', { class: 'implementation' }, el('span', {}, 'SELF-HOSTED'), el('span', {}, state.implementation ? `${({ go: 'Go' })[state.implementation] || state.implementation} server` : 'GitClub')));
  sidebar.replaceChildren(brand, close, switcher, primary, scroll, footer);
}
function shell() {
  const root = $('#app');
  root.replaceChildren(el('div', { class: 'shell' }, el('aside', { id: 'sidebar', class: 'sidebar', 'aria-label': 'Repository navigation' }), el('button', { type: 'button', class: 'backdrop', 'aria-label': 'Close navigation', tabindex: '-1', onClick: () => setNav(false) }), el('div', { class: 'workspace' }, el('header', { class: 'topbar' }, el('button', { class: 'subtle-button mobile-menu', type: 'button', 'aria-label': 'Open navigation', 'aria-controls': 'sidebar', 'aria-expanded': 'false', onClick: () => setNav(!state.navOpen) }, icon('menu')), el('span', { class: 'context' }, 'Your workspace'), el('div', { class: 'right' }, el('span', { class: 'context-help' }, 'Code, together.'), button('Find repository', openSwitcher, 'small', 'search'), themeToggle())), el('main', { id: 'main', class: 'main', tabindex: '-1' }))));
  renderSidebar();
}
function themeToggle() {
  const control = el('button', { type: 'button', class: 'subtle-button theme-toggle', onClick: () => {
    const next = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
    window.setGitClubTheme(next, true);
    update();
    announce(`${next === 'dark' ? 'Dark' : 'Light'} mode enabled`);
  } });
  const update = () => {
    const dark = document.documentElement.dataset.theme === 'dark';
    control.title = `Switch to ${dark ? 'light' : 'dark'} mode`;
    control.setAttribute('aria-label', control.title);
    control.replaceChildren(icon(dark ? 'sun' : 'moon'));
  };
  update();
  return control;
}
async function refreshWorkspace() {
  const results = await Promise.all([api('/api/repos'), state.user ? api('/api/groups') : Promise.resolve({ groups: [] }), state.user ? api('/api/namespaces') : Promise.resolve({ namespaces: [] })]);
  state.repos = results[0].repositories; state.groups = results[1].groups; state.namespaces = results[2].namespaces; renderSidebar();
}
function go(url, replace = false) { if (replace) history.replaceState(null, '', url); else history.pushState(null, '', url); renderRoute(); }
function openSwitcher() {
  if ($('.dialog')) return;
  const results = el('div', { class: 'dialog-results', role: 'listbox', id: 'switcher-results', 'aria-label': 'Repositories' });
  const input = el('input', { type: 'search', placeholder: 'Search every owner and repository…', 'aria-label': 'Find a repository', autocomplete: 'off', role: 'combobox', 'aria-controls': 'switcher-results', 'aria-expanded': 'true', 'aria-autocomplete': 'list' });
  const dialog = el('dialog', { class: 'dialog', 'aria-label': 'Find a repository' }, el('div', { class: 'dialog-header' }, icon('search'), input, el('button', { class: 'subtle-button', type: 'button', 'aria-label': 'Close repository switcher', onClick: () => dialog.close() }, icon('close'))), results, el('div', { class: 'dialog-footer' }, el('span', {}, el('kbd', {}, '↑ ↓'), ' Navigate'), el('span', {}, el('kbd', {}, 'Enter'), ' Open'), el('span', {}, el('kbd', {}, 'Esc'), ' Close')));
  let selection = 0;
  let filtered = [];
  const select = index => { selection = Math.max(0, Math.min(filtered.length - 1, index)); [...results.children].forEach((node, i) => node.setAttribute('aria-selected', String(i === selection))); if (filtered.length) { input.setAttribute('aria-activedescendant', `switcher-${selection}`); results.children[selection]?.scrollIntoView({ block: 'nearest' }); } else input.removeAttribute('aria-activedescendant'); };
  const filter = () => { const q = input.value.trim().toLowerCase(); filtered = state.repos.filter(repo => `${repo.full_name} ${repo.description}`.toLowerCase().includes(q)).slice(0, 50); results.replaceChildren(...filtered.map((repo, i) => el('a', { href: repoPath(repo), id: `switcher-${i}`, role: 'option', class: 'switcher-result', tabindex: '-1', onClick: () => dialog.close() }, icon(repo.pinned ? 'pin' : 'repo'), repo.full_name))); if (!filtered.length) results.append(el('p', { class: 'nav-empty' }, q ? 'No accessible repositories match this search.' : 'Create or import a repository to get started.')); select(0); };
  input.addEventListener('input', filter);
  input.addEventListener('keydown', event => { if (event.key === 'ArrowDown' || event.key === 'ArrowUp') { event.preventDefault(); select(selection + (event.key === 'ArrowDown' ? 1 : -1)); } if (event.key === 'Enter' && filtered[selection]) { event.preventDefault(); const url = repoPath(filtered[selection]); dialog.close(); go(url); } });
  dialog.addEventListener('close', () => dialog.remove());
  dialog.addEventListener('click', event => { if (event.target === dialog) { const box = dialog.getBoundingClientRect(); if (event.clientX < box.left || event.clientX > box.right || event.clientY < box.top || event.clientY > box.bottom) dialog.close(); } });
  document.body.append(dialog); filter(); dialog.showModal(); input.focus();
}
function pinButton(repo) { const btn = el('button', { class: `pin-button ${repo.pinned ? 'pinned' : ''}`, type: 'button', title: `${repo.pinned ? 'Unpin' : 'Pin'} ${repo.full_name}`, 'aria-label': `${repo.pinned ? 'Unpin' : 'Pin'} ${repo.full_name}`, 'aria-pressed': String(repo.pinned), onClick: () => mutation(async () => { await api(`/api/repos/${repo.id}/pin`, 'POST', { pinned: !repo.pinned }); await refreshWorkspace(); await renderRoute(false); announce(`${repo.full_name} ${repo.pinned ? 'unpinned' : 'pinned'}`); }, btn) }, icon('pin')); return btn; }
function repoRow(repo) { return el('article', { class: 'repo-row' }, el('span', { class: 'repo-symbol' }, icon('repo')), el('div', { class: 'repo-summary' }, el('a', { class: 'repo-name', href: repoPath(repo) }, el('span', { class: 'owner-name' }, `${repo.owner} / `), repo.name), repo.description ? el('p', { class: 'repo-description' }, repo.description) : null, el('div', { class: 'repo-meta' }, el('span', {}, icon('branch'), repo.default_branch), el('span', {}, icon(repo.visibility === 'private' ? 'lock' : 'globe'), repo.visibility), el('span', {}, icon('clock'), 'Updated ', time(repo.updated_at)))), el('div', { class: 'repo-freshness' }, time(repo.updated_at), el('span', {}, 'Default branch update')), state.user ? pinButton(repo) : null); }
async function repositoriesPage(params) {
  const groupId = params.get('group') || '';
  const group = state.groups.find(item => String(item.id) === groupId);
  let owner = params.get('owner') || ''; let search = params.get('q') || '';
  const headingNode = heading(group ? group.name : 'Repositories', group ? 'A collection across owners. Repository permissions still apply.' : 'All your repositories. Every owner. One place.', [button('Refresh', () => renderRoute(false), '', 'refresh'), state.user ? actionLink('New repository', '/repos/new', 'primary', 'plus') : actionLink('Create an account', '/register', 'primary')]);
  const searchInput = el('input', { type: 'search', placeholder: 'Find a repository…', value: search, 'aria-label': 'Search repositories', autocomplete: 'off' });
  const owners = [...new Set(state.repos.map(repo => repo.owner))].sort();
  const ownerSelect = el('select', { 'aria-label': 'Filter by owner' }, el('option', { value: '' }, 'All owners'), owners.map(name => el('option', { value: name, selected: name === owner }, name)));
  const groupSelect = el('select', { 'aria-label': 'Filter by group', onChange: event => go(`/repos${query({ q: search, owner, group: event.target.value })}`) }, el('option', { value: '' }, 'All groups'), state.groups.map(item => el('option', { value: item.id, selected: String(item.id) === groupId }, item.name)));
  const result = el('div', { 'aria-live': 'polite' });
  const update = () => {
    const q = search.trim().toLowerCase();
    const filtered = state.repos.filter(repo => (!owner || repo.owner === owner) && (!groupId || group?.repo_ids.includes(repo.id)) && `${repo.full_name} ${repo.description}`.toLowerCase().includes(q));
    history.replaceState(null, '', `/repos${query({ q: search, owner, group: groupId })}`);
    if (!filtered.length) result.replaceChildren(empty(state.repos.length ? 'No repositories match' : 'Your next project starts here', state.repos.length ? 'Try another name, owner, or group.' : 'Create a repository here, then push your existing Git history. Personal and organization repositories will live in this same view.', state.repos.length ? [button('Clear filters', () => go('/repos'))] : state.user ? [actionLink('Create a repository', '/repos/new', 'primary', 'plus'), actionLink('Create an organization', '/namespaces')] : [actionLink('Sign in', '/login', 'primary')]));
    else result.replaceChildren(el('div', { class: 'list-head' }, el('span', {}, `${filtered.length} ${filtered.length === 1 ? 'repository' : 'repositories'}${filtered.some(repo => repo.pinned) ? ' · Pins first' : ''}`), el('span', {}, 'Newest default-branch update first')), el('div', { class: 'repo-list' }, filtered.map(repoRow)));
  };
  searchInput.addEventListener('input', () => { search = searchInput.value; update(); });
  ownerSelect.addEventListener('change', () => { owner = ownerSelect.value; update(); });
  update();
  return [headingNode, el('div', { class: 'toolbar' }, el('div', { class: 'search-field' }, icon('search'), searchInput), ownerSelect, state.user ? groupSelect : null, el('span', { class: 'sorting-note', title: 'Only changes accepted on the configured default branch affect ordering. Feature branches and page visits do not.' }, icon('clock'), 'Default-branch freshness')), result];
}
function authPage(register) {
  if (state.user) return [heading('You are signed in', `Continue as ${state.user.username}.`), actionLink('Open repositories', '/repos', 'primary')];
  return [el('div', { class: 'auth-layout' }, heading(register ? 'Join your GitClub' : 'Welcome back', register ? 'Create an account on this self-hosted server.' : 'Sign in to find your repositories and continue your work.'), form([
    field('Username', 'username', '', { required: true, autocomplete: 'username', pattern: '[a-z0-9][a-z0-9._-]{0,62}', help: register ? 'Lowercase letters, numbers, dots, underscores, and hyphens.' : '' }),
    field('Password', 'password', '', { type: 'password', required: true, autocomplete: register ? 'new-password' : 'current-password', minlength: register ? 12 : undefined, maxlength: 256, help: register ? 'At least 12 characters. Use a unique password.' : '' }),
  ], register ? 'Create account' : 'Sign in', async values => { const data = await api(`/api/auth/${register ? 'register' : 'login'}`, 'POST', values); state.user = data.user; await refreshWorkspace(); go('/repos'); }), el('p', { class: 'auth-note' }, register ? 'Already have an account? ' : 'New to this server? ', link(register ? 'Sign in' : 'Create an account', register ? '/login' : '/register')))];
}
function createRepoPage() {
  return [heading('New repository', 'Start a project or bring an existing repository with its Git history.'), form([
    el('div', { class: 'form-row' }, field('Owner', 'owner', state.user.username, { choices: state.namespaces.filter(n => n.role === 'admin' || n.role === 'write').map(n => n.name), required: true }), field('Repository name', 'name', '', { required: true, pattern: '[a-z0-9][a-z0-9._-]{0,62}', maxlength: 63, placeholder: 'project-name' })),
    field('Description', 'description', '', { maxlength: 500, placeholder: 'What does this repository do?' }),
    el('div', { class: 'form-row' }, field('Visibility', 'visibility', 'private', { choices: [{ value: 'private', label: 'Private · invited members' }, { value: 'public', label: 'Public · anyone can read' }] }), field('Default branch', 'default_branch', 'main', { required: true, help: 'This branch determines repository freshness.' })),
    el('div', { class: 'notice' }, 'GitClub creates an empty repository. The next screen gives you commands to push your existing Git history.'),
  ], 'Create repository', async values => { const data = await api('/api/repos', 'POST', values); await refreshWorkspace(); go(repoPath(data.repository)); }, { cancel: '/repos' })];
}
async function groupsPage(id) {
  const groups = state.groups;
  const own = group => group.creator_id === state.user.id;
  if (id === 'new' || id) {
    const group = id === 'new' ? null : groups.find(item => String(item.id) === id);
    if (id !== 'new' && !group) throw new Error('This group is unavailable or is not shared with you.');
    if (group && !own(group)) return [heading(group.name, 'This shared collection is managed by its creator.'), actionLink('View repositories', `/repos?group=${group.id}`, 'primary')];
    const fields = [field('Group name', 'name', group?.name || '', { required: true, maxlength: 80, placeholder: 'Libraries, client work, weekend projects…' }), checkbox('Share this group with other signed-in users', 'shared', group?.shared || false), el('p', { class: 'content-note' }, 'Sharing grants no repository access. Each person only sees repositories they already have permission to read.'), section('Repositories', 'Mix personal and organization repositories in this collection.', state.repos.length ? el('div', { class: 'repo-checklist' }, state.repos.map(repo => checkbox(repo.full_name, 'repo_ids[]', group?.repo_ids.includes(repo.id), repo.id))) : el('p', { class: 'content-note' }, 'Create a repository first, or save an empty group.'))];
    return [heading(group ? `Edit ${group.name}` : 'New group', 'Organize repositories without changing their ownership.'), form(fields, group ? 'Save group' : 'Create group', async (values, node) => { const ids = new FormData(node).getAll('repo_ids[]').map(Number); let result; if (group) result = await api(`/api/groups/${group.id}`, 'PATCH', { name: values.name, shared: values.shared, repo_ids: ids }); else { result = await api('/api/groups', 'POST', { name: values.name, shared: values.shared }); if (ids.length) await api(`/api/groups/${result.group.id}`, 'PATCH', { repo_ids: ids }); } await refreshWorkspace(); go(`/repos?group=${result.group.id}`); }, { cancel: '/groups' }), group ? section('Delete group', 'Repositories, permissions, and Git history remain intact.', button('Delete group', async event => { if (!confirm(`Delete the group “${group.name}”? Its repositories will remain intact.`)) return; await mutation(async () => { await api(`/api/groups/${group.id}`, 'DELETE'); await refreshWorkspace(); go('/groups'); }, event.currentTarget); }, 'danger')) : null];
  }
  return [heading('Groups', 'Collections that work across repository owners.', [actionLink('New group', '/groups/new', 'primary', 'plus')]), groups.length ? el('div', {}, groups.map(group => el('div', { class: 'group-row' }, el('div', {}, el('h2', {}, link(group.name, `/repos?group=${group.id}`)), el('p', {}, `${group.repo_ids.length} accessible ${group.repo_ids.length === 1 ? 'repository' : 'repositories'} · ${group.shared ? 'Shared' : 'Only you'}`)), el('div', { class: 'actions' }, own(group) ? actionLink('Edit group', `/groups/${group.id}`, 'small') : badge('shared'))))) : empty('Make room for your own organization', 'Group repositories by project, team, or purpose. A group can include repositories from any owner you can access.', [actionLink('Create a group', '/groups/new', 'primary', 'plus')], false, 'group')];
}
function memberForm(path) {
  return form([el('div', { class: 'form-row' }, field('Username', 'username', '', { required: true, placeholder: 'An existing GitClub username' }), field('Role', 'role', 'read', { choices: [{ value: 'read', label: 'Read · code and discussions' }, { value: 'write', label: 'Write · push and collaborate' }, { value: 'admin', label: 'Admin · manage access and settings' }] }))], 'Save membership', async (values, node, status) => { await api(path, 'POST', values); status.textContent = `Saved ${values.role} access for ${values.username}.`; await refreshWorkspace(); });
}
function namespacesPage() {
  return [heading('Namespaces', 'Ownership and access, without splitting your repository navigation.'), el('div', {}, state.namespaces.map(namespace => el('div', { class: 'section' }, el('div', { class: 'group-row' }, el('div', {}, el('h2', {}, namespace.name), el('p', {}, `${namespace.kind === 'personal' ? 'Personal namespace' : 'Organization'} · ${namespace.role}`)), actionLink('View repositories', `/repos?owner=${encodeURIComponent(namespace.name)}`, 'small')), namespace.kind !== 'personal' && namespace.role === 'admin' ? el('details', { class: 'details' }, el('summary', {}, 'Add or update a member'), memberForm(`/api/namespaces/${encodeURIComponent(namespace.name)}/members`)) : null))), section('Create an organization', 'An organization owns repositories and shares access through member roles.', form([field('Organization name', 'name', '', { required: true, pattern: '[a-z0-9][a-z0-9._-]{0,62}', maxlength: 63, placeholder: 'your-team' })], 'Create organization', async values => { await api('/api/namespaces', 'POST', values); await refreshWorkspace(); await renderRoute(false); }))];
}
function repoHeader(repo, active) {
  const tabs = [['code', 'Code', 'code'], ['pulls', 'Pull requests', 'pull']];
  if (repo.role === 'admin') tabs.push(['settings', 'Settings', 'settings']);
  return [el('div', { class: 'repo-heading' }, heading(el('span', {}, el('span', { class: 'owner-name' }, `${repo.owner} / `), repo.name), repo.description || '', [badge(repo.visibility), state.user ? pinButton(repo) : null])), el('nav', { class: 'tabs', 'aria-label': 'Repository' }, tabs.map(([key, label, glyph]) => el('a', { href: repoPath(repo, key), class: `tab ${active === key ? 'active' : ''}`, ...(active === key ? { 'aria-current': 'page' } : {}) }, icon(glyph), label)), repo.kaneo_project_url ? el('a', { href: repo.kaneo_project_url, class: 'tab', target: '_blank', rel: 'noopener noreferrer', title: 'Open Kaneo project in a new tab' }, icon('external'), 'Kaneo') : null)];
}
function importInstructions(repo) {
  const remote = `${location.origin}/${repo.full_name}.git`;
  return section('Bring your Git history', 'Push from your computer. Your Git client connects directly to this server.',
    el('p', { class: 'content-note' }, 'For an existing local repository:'), codeBlock(`git remote add gitclub ${remote}\ngit push gitclub --all\ngit push gitclub --tags`),
    el('details', { class: 'details' }, el('summary', {}, 'Import every branch and tag from another server'), el('p', { class: 'content-note' }, 'Use this only with a new, empty GitClub repository. A mirror push makes its refs match the source.'), codeBlock(`git clone --mirror <source-repository-url>\ncd <repository>.git\ngit push --mirror ${remote}`)),
    el('p', { class: 'content-note' }, 'For HTTPS authentication, enter your GitClub username and use an agent access token as the password. ', link('Create a token', '/agents'), '. Select the matching default branch in repository settings after importing. SSH access is available when your server operator enables OpenSSH. ', link('Add an SSH key', '/settings/ssh'), '.'));
}
function branchToolbar(repo, branches, ref, sectionName, params = {}) {
  const branchSelect = el('select', { class: 'branch-select', 'aria-label': 'Branch', onChange: event => go(repoPath(repo, sectionName, { ...params, ref: event.target.value })) }, (branches.length ? branches : [{ name: repo.default_branch }]).map(branch => el('option', { value: branch.name, selected: branch.name === ref }, branch.name)));
  if (!branches.some(branch => branch.name === ref) && ref !== repo.default_branch) branchSelect.append(el('option', { value: ref, selected: true }, ref));
  return el('div', { class: 'toolbar' }, icon('branch'), branchSelect, el('span', { class: 'version-copy' }, `${branches.length} ${branches.length === 1 ? 'branch' : 'branches'}`), el('div', { class: 'toolbar-links' }, link('Files', repoPath(repo, 'code', { ref })), link('History', repoPath(repo, 'history', { ref })), link('Compare branches', repoPath(repo, 'compare', { base: repo.default_branch, head: ref }))));
}
function pathBreadcrumbs(repo, ref, path, file = false) {
  const pieces = path.split('/').filter(Boolean);
  return el('nav', { class: 'breadcrumbs', 'aria-label': 'File path' }, link(repo.name, repoPath(repo, 'code', { ref })), pieces.flatMap((piece, i) => [el('span', { class: 'separator', 'aria-hidden': 'true' }, '/'), file && i === pieces.length - 1 ? el('span', {}, piece) : link(piece, repoPath(repo, 'code', { ref, path: pieces.slice(0, i + 1).join('/') }))]));
}
function diffPanel(diff, truncated, onLine) {
  const pre = el('pre', { class: 'diff', tabindex: '0', 'aria-label': 'Unified diff' });
  let filePath = ''; let lineNo = 0;
  for (const line of (diff || '').split('\n')) {
    let cls = ''; let number = '';
    if (line.startsWith('diff --git ') || line.startsWith('index ') || line.startsWith('--- ') || line.startsWith('+++ ')) cls = 'file';
    else if (line.startsWith('@@')) { cls = 'hunk'; const match = line.match(/\+(\d+)/); if (match) lineNo = Number(match[1]) - 1; }
    else if (line.startsWith('+')) { cls = 'add'; number = String(++lineNo); }
    else if (line.startsWith('-')) cls = 'remove';
    else if (line.startsWith(' ')) number = String(++lineNo);
    if (line.startsWith('+++ b/')) filePath = line.slice(6);
    const row = el('span', { class: `diff-line ${cls}` }, number ? el('span', { class: 'line-number', 'aria-hidden': 'true' }, number) : null, line || ' ');
    if (onLine && filePath && number) {
      const anchor = { path: filePath, line: Number(number) };
      row.setAttribute('role', 'button'); row.tabIndex = 0; row.setAttribute('aria-label', `Comment on ${filePath}, line ${number}: ${line}`);
      row.addEventListener('click', () => onLine(anchor));
      row.addEventListener('keydown', event => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); onLine(anchor); } });
    }
    pre.append(row);
  }
  return el('div', { class: 'code-panel' }, el('div', { class: 'code-header' }, 'Changes', onLine ? el('span', {}, 'Select a line to leave a comment') : null), diff ? pre : el('p', { class: 'content-note' }, 'No changes between these revisions.'), truncated ? el('div', { class: 'notice' }, 'This diff is truncated. Fetch both branches locally to review the complete change before merging.') : null);
}
async function codePage(repo, type, params) {
  const { branches } = await api(`/api/repos/${repo.id}/branches`);
  const ref = params.get('ref') || repo.default_branch;
  const path = params.get('path') || '';
  const base = params.get('base') || repo.default_branch;
  const head = params.get('head') || branches.find(branch => branch.name !== base)?.name || base;
  const toolbar = branchToolbar(repo, branches, ref, type, type === 'file' || type === 'code' ? { path } : {});
  if (type === 'history') {
    const { commits } = await api(`/api/repos/${repo.id}/commits${query({ ref })}`);
    return [toolbar, commits.length ? el('div', { class: 'thread-list' }, commits.map(commit => el('div', { class: 'thread-row' }, icon('clock'), el('div', { class: 'thread-summary' }, el('div', { class: 'thread-title' }, commit.subject), el('div', { class: 'thread-meta' }, el('span', {}, commit.author), time(commit.date))), link(commit.short_oid, repoPath(repo, 'code', { ref: commit.oid }), 'monospace')))) : empty('No commits yet', 'Push the first commit to this branch to see its history.', [], true)];
  }
  if (type === 'compare') {
    const options = branches.map(branch => branch.name);
    const compareForm = form([el('div', { class: 'form-row' }, field('Base branch', 'base', base, { choices: options, required: true }), field('Head branch', 'head', head, { choices: options, required: true }))], 'Compare branches', async values => go(repoPath(repo, 'compare', values)));
    if (!branches.length) return [empty('Push a branch to compare changes', 'Branch comparisons are available after your first push.', [], true), importInstructions(repo)];
    const data = await api(`/api/repos/${repo.id}/diff${query({ base, head })}`);
    return [compareForm, section('Branch comparison', `${base} ← ${head}`, diffPanel(data.diff, data.truncated)), state.user && repo.role !== 'read' && base !== head && data.diff ? el('div', { class: 'form-footer' }, actionLink('Open a pull request', repoPath(repo, 'pulls/new', { base, head }), 'primary', 'pull')) : null];
  }
  if (type === 'file') {
    const data = await api(`/api/repos/${repo.id}/blob${query({ ref, path })}`);
    return [toolbar, pathBreadcrumbs(repo, ref, path, true), el('div', { class: 'code-panel' }, el('div', { class: 'code-header' }, data.path, el('span', {}, `${bytes(data.size)}${data.truncated ? ' · Truncated' : ''}`)), data.binary ? el('div', { class: 'empty compact' }, el('p', {}, 'This binary file cannot be displayed as text. Clone the repository to open it locally.')) : el('pre', { class: 'code', tabindex: '0', 'aria-label': data.path }, data.content)), data.truncated ? el('p', { class: 'content-note' }, 'Only the first 512 KiB are displayed. Clone the repository to read the complete file.') : null];
  }
  const data = await api(`/api/repos/${repo.id}/tree${query({ ref, path })}`);
  const entries = [...data.entries].sort((a, b) => a.type === b.type ? a.name.localeCompare(b.name) : a.type === 'directory' ? -1 : 1);
  return [toolbar, path ? pathBreadcrumbs(repo, ref, path) : null, entries.length ? el('div', { class: 'file-list' }, path ? el('div', { class: 'file-row' }, icon('group'), link('..', repoPath(repo, 'code', { ref, path: path.split('/').slice(0, -1).join('/') }))) : null, entries.map(entry => el('div', { class: 'file-row' }, icon(entry.type === 'directory' ? 'group' : 'file'), link(entry.name, repoPath(repo, entry.type === 'directory' ? 'code' : 'file', { ref, path: entry.path })), el('span', { class: 'file-size' }, entry.type === 'directory' ? '' : bytes(entry.size))))) : empty(branches.length ? 'This directory is empty' : 'Ready for your first push', branches.length ? 'Choose another branch or directory to continue browsing.' : `Your repository is ready. Push code to ${repo.default_branch} to start collaborating.`, [], true), !branches.length ? importInstructions(repo) : section('Clone this repository', '', codeBlock(`git clone ${location.origin}/${repo.full_name}.git`))];
}
function repoSettings(repo) {
  if (repo.role !== 'admin') throw new Error('Only repository administrators can change these settings.');
  return [heading('Repository settings', 'Manage the default branch, review requirements, and access.'), form([
    field('Description', 'description', repo.description, { maxlength: 500 }),
    field('Kaneo project URL', 'kaneo_project_url', repo.kaneo_project_url || '', { type: 'url', maxlength: 2048, placeholder: 'https://kaneo.example.com/dashboard/workspace/WORKSPACE/project/PROJECT/board', help: 'Link this repository to its Kaneo project. Leave empty to disconnect. Task completion on merge requires the operator to enable sync for this repository.' }),
    el('div', { class: 'form-row' }, field('Visibility', 'visibility', repo.visibility, { choices: ['private', 'public'] }), field('Default branch', 'default_branch', repo.default_branch, { required: true, help: 'Changing this branch refreshes the repository’s activity time.' })),
    checkbox('Require an approval before merging into the default branch', 'require_review', repo.require_review),
    el('p', { class: 'content-note' }, 'Approval must come from another writer and apply to the current head commit. When enabled, direct pushes to an initialized default branch are blocked. Default-branch deletion and non-fast-forward pushes are always blocked.'),
  ], 'Save settings', async values => { await api(`/api/repos/${repo.id}`, 'PATCH', values); await refreshWorkspace(); await renderRoute(false); const status = $('#main .form-status'); if (status) status.textContent = 'Repository settings saved.'; }), section('Repository membership', 'Add a user or change their repository role. Namespace access is inherited; the highest granted role applies.', memberForm(`/api/repos/${repo.id}/members`))];
}
function pullRow(repo, item) {
  return el('article', { class: 'thread-row' }, icon('pull'), el('div', { class: 'thread-summary' }, link(item.title, repoPath(repo, `pulls/${item.id}`), 'thread-title'), el('div', { class: 'thread-meta' }, el('span', {}, `#${item.id}`), badge(item.state), el('span', {}, `${item.author} opened `, time(item.created_at)), el('span', { class: 'monospace' }, `${item.base_branch} ← ${item.head_branch}`), item.kaneo_task_url ? link('Kaneo task', item.kaneo_task_url) : null)), el('span', { class: 'thread-date version-copy' }, time(item.updated_at)));
}
async function pullsPage(repo) {
  const { pulls: items } = await api(`/api/repos/${repo.id}/pulls`);
  const output = el('div', {});
  const filter = el('select', { 'aria-label': 'Filter pull requests by state' }, el('option', { value: 'open' }, `Open (${items.filter(item => item.state === 'open').length})`), el('option', { value: 'all' }, `All (${items.length})`), el('option', { value: 'closed' }, `Closed (${items.filter(item => item.state === 'closed').length})`), el('option', { value: 'merged' }, `Merged (${items.filter(item => item.state === 'merged').length})`));
  const search = el('input', { type: 'search', placeholder: 'Search pull requests…', 'aria-label': 'Search pull requests' });
  const update = () => { const q = search.value.toLowerCase(); const matching = items.filter(item => (filter.value === 'all' || item.state === filter.value) && `${item.title} ${item.body}`.toLowerCase().includes(q)); output.replaceChildren(matching.length ? el('div', { class: 'thread-list' }, matching.map(item => pullRow(repo, item))) : empty('No pull requests here yet', search.value || filter.value !== 'open' ? 'Try another search or state filter.' : 'Push a feature branch, then open a pull request to review its changes.', state.user && repo.role !== 'read' ? [actionLink('Open a pull request', repoPath(repo, 'pulls/new'), 'primary', 'plus')] : [], true, 'pull')); };
  filter.addEventListener('change', update); search.addEventListener('input', update); update();
  return [heading('Pull requests', 'Review changes and merge with confidence.', state.user && repo.role !== 'read' ? [actionLink('New pull request', repoPath(repo, 'pulls/new'), 'primary', 'plus')] : []), el('div', { class: 'toolbar' }, el('div', { class: 'search-field' }, icon('search'), search), filter), output];
}
function kaneoTaskField(repo, value = '') {
  return repo.kaneo_project_url || value ? field('Kaneo task URL', 'kaneo_task_url', value, { type: 'url', maxlength: 2048, help: 'Optional. Paste a task link from this repository’s Kaneo project.' }) : null;
}
async function newPull(repo, params) {
  if (repo.role === 'read') throw new Error('Write access is required to create a pull request.');
  const { branches } = await api(`/api/repos/${repo.id}/branches`);
  if (branches.length < 2) return [heading('Open a pull request', 'A pull request compares two branches in this repository.'), empty('Push a feature branch first', 'Create a branch locally, commit your changes, and push it to GitClub. You can then review it against the default branch.', [actionLink('Back to code', repoPath(repo), 'primary')], true, 'branch')];
  const base = params.get('base') || repo.default_branch;
  const branchFields = [el('div', { class: 'form-row' }, field('Base branch', 'base_branch', base, { choices: branches.map(branch => branch.name), required: true }), field('Head branch', 'head_branch', params.get('head') || branches.find(branch => branch.name !== base)?.name, { choices: branches.map(branch => branch.name), required: true }))];
  return [heading('Open a pull request', 'Describe what changed and what the reviewer should check.'), form([...branchFields, field('Title', 'title', '', { required: true, maxlength: 240, placeholder: 'What does this change accomplish?' }), field('Description', 'body', '', { type: 'textarea', rows: 9, maxlength: 100000, help: 'Plain text. Drafts are saved locally in this browser.' }), kaneoTaskField(repo)], 'Open pull request', async (values, node) => { const data = await api(`/api/repos/${repo.id}/pulls`, 'POST', values); node.clearDraft?.(); go(repoPath(repo, `pulls/${data.pull.id}`)); }, { cancel: repoPath(repo, 'pulls'), draft: `${repo.id}:pulls:new` })];
}
function editPull(repo, item) {
  if (!state.user || !(state.user.id === item.author_id || repo.role === 'admin') || item.state === 'merged') return null;
  return el('details', { class: 'details' }, el('summary', {}, 'Edit pull request'), form([field('Title', 'title', item.title, { required: true, maxlength: 240 }), field('Description', 'body', item.body, { type: 'textarea', rows: 6, maxlength: 100000 }), kaneoTaskField(repo, item.kaneo_task_url || '')], 'Save changes', async values => { await api(`/api/repos/${repo.id}/pulls/${item.id}`, 'PATCH', values); await renderRoute(false); }));
}
function pullStateButton(repo, item) {
  if (!state.user || !(state.user.id === item.author_id || repo.role === 'admin') || item.state === 'merged') return null;
  const next = item.state === 'open' ? 'closed' : 'open';
  return button(next === 'closed' ? 'Close pull request' : 'Reopen', event => mutation(async () => { await api(`/api/repos/${repo.id}/pulls/${item.id}`, 'PATCH', { state: next }); await renderRoute(false); }, event.currentTarget), next === 'closed' ? '' : 'primary');
}
function commentItem(comment) {
  return el('article', { class: 'comment' }, el('div', { class: 'comment-header' }, el('span', { class: 'avatar', 'aria-hidden': 'true' }, comment.author.slice(0, 2)), el('strong', {}, comment.author), time(comment.created_at)), comment.path ? el('p', { class: 'comment-location' }, `${comment.path}:${comment.line} · ${(comment.commit_oid || '').slice(0, 8)}`) : null, el('p', { class: 'prose' }, comment.body));
}
function threadHeading(item) { return heading(el('span', {}, item.title, el('span', { class: 'owner-name' }, ` #${item.id}`)), '', [badge(item.state)]); }
function discussionBody(item) { return el('div', { class: 'discussion-body' }, el('div', { class: 'thread-meta' }, el('strong', {}, item.author), 'opened ', time(item.created_at)), el('p', { class: 'prose' }, item.body || 'No description provided.')); }
async function pullDetail(repo, id) {
  const data = await api(`/api/repos/${repo.id}/pulls/${id}`); const item = data.pull;
  const canWrite = !!state.user && repo.role !== 'read';
  let inline = null;
  const anchorBox = el('div', { hidden: true, class: 'inline-anchor' });
  const commentForm = canWrite ? form([anchorBox, field('Comment', 'body', '', { type: 'textarea', required: true, maxlength: 100000, help: 'Your draft is saved locally until you post it.' })], 'Post comment', async (values, node) => { await api(`/api/repos/${repo.id}/pulls/${id}/comments`, 'POST', { body: values.body, ...(inline ? { ...inline, commit_oid: data.head_oid } : {}) }); node.clearDraft?.(); await renderRoute(false); }, { draft: `${repo.id}:pulls:${id}:comment` }) : null;
  const anchorLine = anchor => { inline = anchor; anchorBox.hidden = false; anchorBox.replaceChildren(el('span', {}, `${anchor.path}:${anchor.line} · ${data.head_oid.slice(0, 8)}`), button('Clear location', () => { inline = null; anchorBox.hidden = true; }, 'small')); commentForm.scrollIntoView({ block: 'center', behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'instant' : 'smooth' }); $('textarea', commentForm).focus({ preventScroll: true }); };
  const diffArea = el('div', {}, diffPanel(data.diff, data.truncated, canWrite ? anchorLine : null));
  const reviewKey = `gitclub:review:${state.user?.id || 'anonymous'}:${repo.id}:${id}:${data.head_oid}`;
  let savedScroll = 0;
  try { savedScroll = Number(sessionStorage.getItem(reviewKey) || 0); } catch { /* Review position storage is optional. */ }
  const attachDiffScroll = () => { const pre = $('.diff', diffArea); if (!pre) return; pre.scrollTop = savedScroll; pre.addEventListener('scroll', () => { try { sessionStorage.setItem(reviewKey, String(pre.scrollTop)); } catch { /* Review position storage is optional. */ } }, { passive: true }); };
  requestAnimationFrame(attachDiffScroll);
  const latestReview = state.user ? [...data.reviews].filter(review => review.author_id === state.user.id).sort((a, b) => b.created_at - a.created_at)[0] : null;
  const diffToolbar = el('div', { class: 'toolbar' }, el('span', { class: 'version-copy monospace' }, `${item.base_branch} ← ${item.head_branch}`), data.head_oid ? el('span', { class: 'version-copy monospace', title: data.head_oid }, data.head_oid.slice(0, 8)) : null, button('Refresh pull request', () => renderRoute(false), 'small', 'refresh'));
  if (latestReview && latestReview.commit_oid !== data.head_oid) {
    let sinceReview = false;
    const toggle = button('Changes since your review', async event => mutation(async () => { if (!sinceReview) { const comparison = await api(`/api/repos/${repo.id}/diff${query({ base: latestReview.commit_oid, head: data.head_oid })}`); diffArea.replaceChildren(diffPanel(comparison.diff, comparison.truncated, canWrite ? anchorLine : null)); } else diffArea.replaceChildren(diffPanel(data.diff, data.truncated, canWrite ? anchorLine : null)); sinceReview = !sinceReview; toggle.textContent = sinceReview ? 'Show complete diff' : 'Changes since your review'; }, event.currentTarget), 'small');
    diffToolbar.append(toggle);
  }
  if (savedScroll) diffToolbar.append(el('span', { class: 'review-position' }, 'Review position restored'));
  const reviews = data.reviews.map(review => el('article', { class: 'comment' }, el('div', { class: 'comment-header' }, el('strong', {}, review.author), badge(review.decision), time(review.created_at), el('span', { class: 'monospace' }, (review.commit_oid || '').slice(0, 8)), review.commit_oid !== data.head_oid ? badge('earlier revision') : badge('current revision')), review.body ? el('p', { class: 'prose' }, review.body) : null));
  const reviewForm = canWrite && item.state === 'open' ? section('Submit a review', 'Your decision applies to the displayed head commit. Refresh and review again if the branch changes.', form([field('Decision', 'decision', 'comment', { choices: [{ value: 'comment', label: 'Comment · no merge decision' }, ...(state.user.id !== item.author_id ? [{ value: 'approve', label: 'Approve · ready to merge' }] : []), { value: 'request_changes', label: 'Request changes · block merging' }] }), field('Review notes', 'body', '', { type: 'textarea', maxlength: 100000 })], 'Submit review', async (values, node) => { await api(`/api/repos/${repo.id}/pulls/${id}/reviews`, 'POST', { ...values, expected_head_oid: data.head_oid }); node.clearDraft?.(); await renderRoute(false); }, { draft: `${repo.id}:pulls:${id}:review`, class: 'review-form' })) : null;
  const blockers = data.merge_blockers || [];
  const merge = el('section', { class: 'merge-panel' }, el('h2', {}, item.state === 'merged' ? 'Changes merged' : item.state === 'closed' ? 'Pull request closed' : data.mergeable ? 'Ready to merge' : 'Merge blocked'), item.state === 'merged' ? el('p', {}, 'Merged commit ', el('code', {}, item.merged_oid)) : item.state === 'open' ? [blockers.length ? el('ul', {}, blockers.map(blocker => el('li', {}, blocker))) : el('p', {}, 'The branches can be merged and the review requirements are satisfied.'), canWrite ? button('Merge pull request', event => mutation(async () => { await api(`/api/repos/${repo.id}/pulls/${id}/merge`, 'POST', { expected_head_oid: data.head_oid }); await refreshWorkspace(); await renderRoute(false); announce('Pull request merged'); }, event.currentTarget), 'primary', 'pull') : el('p', {}, 'Write access is required to merge.')] : el('p', {}, 'Reopen this pull request to continue reviewing and merging.'));
  const mergeButton = $('button', merge); if (mergeButton) mergeButton.disabled = !data.mergeable;
  return [threadHeading(item), discussionBody(item), item.kaneo_task_url ? el('p', { class: 'content-note' }, el('a', { href: item.kaneo_task_url, target: '_blank', rel: 'noopener noreferrer' }, 'Open linked Kaneo task ', icon('external'))) : null, editPull(repo, item), el('div', { class: 'actions' }, pullStateButton(repo, item)), section('Changes', '', diffToolbar, diffArea), section(`Reviews (${data.reviews.length})`, '', reviews.length ? reviews : el('p', { class: 'content-note' }, 'No reviews yet.')), reviewForm, merge, section(`Discussion (${data.comments.length})`, '', data.comments.length ? data.comments.map(commentItem) : el('p', { class: 'content-note' }, 'No comments yet.')), commentForm ? section('Add a comment', '', commentForm) : el('p', { class: 'content-note' }, state.user ? 'Write access is required to comment.' : link('Sign in to participate', '/login'))];
}
async function sshPage() {
  const { ssh_keys } = await api('/api/ssh-keys');
  return [heading('SSH keys', 'Use your existing Git client with a key attached to your account.'), ssh_keys.length ? el('div', {}, ssh_keys.map(key => el('div', { class: 'key-row' }, el('div', {}, el('h3', {}, key.title), el('p', {}, 'Added ', time(key.created_at)), el('div', { class: 'key-preview', title: key.public_key }, key.public_key)), button('Remove', event => { if (!confirm(`Remove the SSH key “${key.title}”? This key will no longer authenticate to GitClub.`)) return; mutation(async () => { await api(`/api/ssh-keys/${key.id}`, 'DELETE'); await renderRoute(false); }, event.currentTarget); }, 'small danger')))) : empty('No SSH keys added', 'Add a public key below. Your private key stays on your computer.', [], true, 'key'), section('Add a public key', 'Paste a single OpenSSH public key. Never paste your private key.', form([field('Title', 'title', '', { required: true, maxlength: 100, placeholder: 'Work laptop' }), field('Public key', 'public_key', '', { type: 'textarea', required: true, rows: 4, placeholder: 'ssh-ed25519 AAAA…', spellcheck: 'false', autocomplete: 'off' })], 'Add SSH key', async values => { await api('/api/ssh-keys', 'POST', values); await renderRoute(false); })), section('Create a key on your computer', '', codeBlock('ssh-keygen -t ed25519\ncat ~/.ssh/id_ed25519.pub'), el('p', { class: 'content-note' }, 'Your server operator must configure GitClub’s OpenSSH integration before SSH clone and push are available. Use the SSH host, port, and service username provided by your operator.'))];
}
function agentsPage() {
  const credentials = el('div', { hidden: true });
  const endpoint = `${location.origin}/mcp`;
  const tokenForm = form([field('Your password', 'password', '', { type: 'password', required: true, autocomplete: 'current-password', help: 'Reauthenticate to create a token. The token is shown only in this page session.' })], 'Create access token', async (values, node, status) => {
    const data = await api('/api/auth/login', 'POST', { username: state.user.username, password: values.password });
    $('input[type=password]', node).value = '';
    credentials.hidden = false;
    credentials.replaceChildren(el('div', { class: 'notice' }, 'Treat this token like your password. It has your account’s permissions. Store it in your local secret manager. Signing out from this session revokes it.'), section('Access token', '', codeBlock(data.token)), section('Codex', 'Store the token in your shell environment, then add the MCP server.', codeBlock(`export GITCLUB_TOKEN='${data.token}'\ncodex mcp add gitclub --url '${endpoint}' --bearer-token-env-var GITCLUB_TOKEN`)), section('Claude Code', 'Add GitClub using its HTTP MCP endpoint.', codeBlock(`claude mcp add --transport http gitclub '${endpoint}' --header 'Authorization: Bearer ${data.token}'`)), section('Generic MCP configuration', 'Use this with a client that supports HTTP transport and authorization headers.', codeBlock(JSON.stringify({ mcpServers: { gitclub: { type: 'http', url: endpoint, headers: { Authorization: `Bearer ${data.token}` } } } }, null, 2))), button('Hide token and configuration', () => { credentials.replaceChildren(); credentials.hidden = true; status.textContent = 'Token hidden. It remains valid until this session signs out.'; }));
    status.textContent = 'Token created. Copy it before leaving this page.';
    credentials.scrollIntoView({ block: 'start' });
  });
  return [heading('Agent access', 'Connect the Codex and Claude tools you already use.'), el('div', { class: 'notice' }, 'Agents work through your account’s repository permissions and branch protections. GitClub provides the collaboration surface; your agent runs in your own tools.'), section('MCP endpoint', '', codeBlock(endpoint)), section('Available operations', '', el('ul', { class: 'api-list' }, ['Find repositories across owners and read repository code.', 'Read, create, and update pull requests linked to Kaneo tasks.', 'Inspect diffs, leave comments, and submit reviews.', 'Merge pull requests when repository protections allow it.'].map(text => el('li', {}, text)))), section('Create a credential', 'Credentials stay out of browser storage. Use a dedicated account if you want to limit an agent’s access.', tokenForm), credentials, section('Git authentication', 'For HTTPS clone and push, use your GitClub username and an access token as the password. Let your Git credential helper store it; avoid putting tokens into remote URLs.', codeBlock(`git clone ${location.origin}/OWNER/REPOSITORY.git`))];
}
async function renderRoute(focus = true) {
  const generation = ++state.page;
  setNav(false); renderSidebar();
  const main = $('#main');
  const path = location.pathname.replace(/\/+$/, '') || '/repos';
  const params = new URLSearchParams(location.search);
  const parts = path.split('/').filter(Boolean);
  main.replaceChildren(el('p', { class: 'loading-text', role: 'status' }, 'Loading workspace…'), el('div', { class: 'skeleton', 'aria-hidden': 'true' }), el('div', { class: 'skeleton', 'aria-hidden': 'true' }));
  let contents;
  let title = 'Repositories';
  try {
    if (path === '/login' || path === '/register') { contents = authPage(path === '/register'); title = path === '/register' ? 'Create account' : 'Sign in'; }
    else if (path === '/repos' || path === '/') { await refreshWorkspace(); if (generation !== state.page) return; contents = await repositoriesPage(params); }
    else if (path === '/repos/new') { requireUser(); contents = createRepoPage(); title = 'New repository'; }
    else if (parts[0] === 'groups') { requireUser(); contents = await groupsPage(parts[1]); title = 'Groups'; }
    else if (path === '/namespaces') { requireUser(); contents = namespacesPage(); title = 'Namespaces'; }
    else if (path === '/settings/ssh') { requireUser(); contents = await sshPage(); title = 'SSH keys'; }
    else if (path === '/agents') { requireUser(); contents = agentsPage(); title = 'Agent access'; }
    else if (parts[0] === 'repos' && /^\d+$/.test(parts[1])) {
      const { repository: repo } = await api(`/api/repos/${parts[1]}`);
      const type = parts[2] || 'code'; const itemId = parts[3]; title = repo.full_name;
      let body;
      if (['code', 'file', 'history', 'compare'].includes(type)) body = await codePage(repo, type, params);
      else if (type === 'settings') { requireUser(); body = repoSettings(repo); }
      else if (type === 'issues') {
        body = [heading('Issue tracking moved to Kaneo', repo.kaneo_project_url ? 'Open the connected project to manage tasks.' : 'A repository administrator can connect a Kaneo project in Settings.'), repo.kaneo_project_url ? actionLink('Open Kaneo project', repo.kaneo_project_url, 'primary', 'external') : repo.role === 'admin' ? actionLink('Connect Kaneo', repoPath(repo, 'settings'), 'primary') : null];
      } else if (type === 'pulls') {
        if (!itemId) body = await pullsPage(repo);
        else if (itemId === 'new') { requireUser(); body = await newPull(repo, params); }
        else if (/^\d+$/.test(itemId)) body = await pullDetail(repo, itemId);
        else throw new Error('This page does not exist. Return to the repository to continue.');
      } else throw new Error('This page does not exist. Return to the repository to continue.');
      contents = [...repoHeader(repo, ['pulls', 'settings'].includes(type) ? type : 'code'), ...body];
    } else contents = [heading('Page not found', 'This address does not match a GitClub page.'), actionLink('Open repositories', '/repos', 'primary')];
    if (generation !== state.page) return;
    main.replaceChildren(...contents.flat(Infinity).filter(Boolean));
    document.title = `${title} · GitClub`; $('.topbar .context').textContent = title;
    if (focus) { window.scrollTo(0, 0); main.focus({ preventScroll: true }); }
  } catch (error) {
    if (generation !== state.page) return;
    main.replaceChildren(heading(error.message === 'Sign in to continue.' ? 'Sign in to continue' : 'Could not open this page'), errorBox(error), el('div', { class: 'actions' }, error.message === 'Sign in to continue.' ? actionLink('Sign in', '/login', 'primary') : button('Try again', () => renderRoute()), actionLink('Back to repositories', '/repos')));
  }
}
function requireUser() { if (!state.user) throw new Error('Sign in to continue.'); }
document.addEventListener('click', event => {
  const anchor = event.target.closest('a[href]'); if (!anchor || event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || anchor.target || anchor.hasAttribute('download')) return;
  const url = new URL(anchor.href, location.origin); if (url.origin !== location.origin || url.hash || !/^\/(repos|groups|namespaces|settings|agents|login|register)(\/|$)/.test(url.pathname)) return;
  event.preventDefault(); go(url.pathname + url.search);
});
document.addEventListener('keydown', event => {
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') { event.preventDefault(); setNav(false); openSwitcher(); }
  if (event.key === 'Escape' && state.navOpen) { setNav(false); $('.mobile-menu')?.focus(); }
  if (event.key === 'Tab' && state.navOpen) {
    const controls = [...$('.sidebar').querySelectorAll('a[href],button:not(:disabled),summary')].filter(node => node.getClientRects().length);
    const first = controls[0]; const last = controls[controls.length - 1];
    if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
    else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
  }
});
matchMedia('(min-width: 801px)').addEventListener('change', event => { if (event.matches) setNav(false); });
window.addEventListener('popstate', () => renderRoute());
async function boot() {
  shell();
  try {
    const [session, health] = await Promise.all([api('/api/session'), api('/health')]); state.user = session.user; state.implementation = health.implementation;
    await refreshWorkspace(); await renderRoute();
  } catch (error) { $('#main').replaceChildren(heading('GitClub is unavailable', 'Check the server connection and retry.'), errorBox(error), button('Retry connection', boot, 'primary', 'refresh')); }
}
boot();
