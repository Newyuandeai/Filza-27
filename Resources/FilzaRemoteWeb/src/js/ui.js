/** Icons (SVG sprite), toasts, modal framework, dialogs, context menu, picker. */
import { $, el, esc } from './util.js';

const SPRITE_URL = './assets/images/filetype-icon-sprite.svg';
let spritePromise = null;

/** Injects assets/images/filetype-icon-sprite.svg so <use href="#i-*"> resolves. */
export function loadSprite() {
  if (!spritePromise) {
    spritePromise = fetch(SPRITE_URL, { cache: 'force-cache' })
      .then((response) => (response.ok ? response.text() : Promise.reject(new Error(String(response.status)))))
      .then((text) => { $('#sprite-mount').innerHTML = text; })
      .catch(() => { /* icons degrade to empty glyphs; the console still works */ });
  }
  return spritePromise;
}

export function icon(name, cls = '') {
  return `<svg class="i${cls ? ' ' + cls : ''}" aria-hidden="true"><use href="#i-${esc(name)}"></use></svg>`;
}

export function iconEl(name, cls = '') {
  const holder = document.createElement('span');
  holder.innerHTML = icon(name, cls);
  return holder.firstElementChild;
}

/* ── toasts ─────────────────────────────────────────────────────────────── */

const TOAST_ICON = { ok: 'check', err: 'warn', warn: 'warn', info: 'info' };

export function toast(title, message = '', kind = 'info', timeout = 4200) {
  const root = $('#toast-root');
  const node = el('div', { class: `toast toast--${kind}` });
  node.innerHTML = `${icon(TOAST_ICON[kind] || 'info')}<div class="toast__body"><div class="toast__title">${esc(title)}</div>${message ? `<div class="toast__msg">${esc(message)}</div>` : ''}</div>`;
  root.append(node);
  let removed = false;
  const close = () => {
    if (removed) return;
    removed = true;
    node.style.transition = 'opacity .15s, transform .15s';
    node.style.opacity = '0';
    node.style.transform = 'translateY(6px)';
    setTimeout(() => node.remove(), 170);
  };
  node.addEventListener('click', close);
  if (timeout) setTimeout(close, timeout);
  return close;
}

/* ── modal framework ────────────────────────────────────────────────────── */

export function modal({ title, subtitle = '', body = null, actions = [], size = '', iconName = null, footer = false, onClose = null }) {
  const backdrop = el('div', { class: 'modal-backdrop' });
  const box = el('div', { class: `modal glass${size ? ' ' + size : ''}` });
  const head = el('header', { class: 'modal__head' });
  const titleWrap = el('div', { class: 'modal__title' });
  titleWrap.innerHTML = `<h2>${esc(title)}</h2>${subtitle ? `<p>${esc(subtitle)}</p>` : ''}`;
  if (iconName) head.insertAdjacentHTML('beforeend', icon(iconName, 'i--lg'));
  head.append(titleWrap);
  const headActions = el('div', { class: 'modal__head-actions' });
  head.append(headActions);

  const bodyWrap = el('div', { class: 'modal__body' });
  if (body) bodyWrap.append(body);
  const foot = el('footer', { class: 'modal__foot' });

  box.append(head, bodyWrap);
  const showFooter = footer || actions.length > 0;
  if (showFooter) box.append(foot);
  backdrop.append(box);
  document.body.append(backdrop);

  const api = {
    box,
    body: bodyWrap,
    foot,
    headActions,
    close(result) {
      document.removeEventListener('keydown', onKey, true);
      backdrop.remove();
      onClose?.(result);
    },
  };

  const closeButton = el('button', { class: 'icon-btn', title: '关闭', html: icon('close') });
  closeButton.addEventListener('click', () => api.close(null));
  headActions.append(closeButton);

  for (const action of actions) {
    const button = el('button', { class: `btn ${action.class || 'btn--ghost'}` }, action.label);
    button.addEventListener('click', () => { action.action?.(api); if (action.close !== false) api.close(action.value ?? null); });
    foot.append(button);
  }

  function onKey(event) {
    if (event.key === 'Escape') { event.stopPropagation(); api.close(null); }
  }
  document.addEventListener('keydown', onKey, true);
  backdrop.addEventListener('mousedown', (event) => { if (event.target === backdrop) api.close(null); });

  return api;
}

export function confirmDialog({ title, message, confirmText = '确定', cancelText = '取消', danger = true }) {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (value) => { if (!settled) { settled = true; resolve(value); } };
    const body = el('div', {}, el('p', { style: 'margin:0;color:var(--text-dim);line-height:1.65' }, message));
    const dialog = modal({
      title, body, size: 'modal--sm', footer: true,
      iconName: danger ? 'warn' : 'info',
      onClose: () => finish(false),
    });
    const cancel = el('button', { class: 'btn btn--ghost' }, cancelText);
    cancel.addEventListener('click', () => dialog.close());
    const ok = el('button', { class: `btn ${danger ? 'btn--danger' : 'btn--primary'}` }, confirmText);
    ok.addEventListener('click', () => { dialog.close(); finish(true); });
    dialog.foot.append(el('div', { class: 'spacer' }), cancel, ok);
    setTimeout(() => ok.focus(), 40);
  });
}

export function promptDialog({ title, label, value = '', hint = '', confirmText = '确定', cancelText = '取消', mono = false, placeholder = '', selectBasename = false }) {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (result) => { if (!settled) { settled = true; resolve(result); } };
    const input = el('input', { value, placeholder, class: mono ? 'mono' : '' });
    const wrap = el('div', {}, el('div', { class: 'form-row' },
      el('label', {}, label),
      input,
      hint ? el('div', { class: 'form-hint' }, hint) : null,
    ));
    const dialog = modal({ title, body: wrap, size: 'modal--sm', footer: true, onClose: () => finish(null) });
    const cancel = el('button', { class: 'btn btn--ghost' }, cancelText);
    cancel.addEventListener('click', () => dialog.close());
    const ok = el('button', { class: 'btn btn--primary' }, confirmText);
    const submit = () => {
      const text = input.value.trim();
      dialog.close();
      finish(text || null);
    };
    ok.addEventListener('click', submit);
    input.addEventListener('keydown', (event) => {
      if (event.key === 'Enter') { event.preventDefault(); submit(); }
    });
    dialog.foot.append(el('div', { class: 'spacer' }), cancel, ok);
    setTimeout(() => {
      input.focus();
      if (selectBasename) {
        const dot = input.value.lastIndexOf('.');
        input.setSelectionRange(0, dot > 0 ? dot : input.value.length);
      } else {
        input.select();
      }
    }, 40);
  });
}

/** Mini directory browser used by move/copy. Resolves to a path or null. */
export function pickDirectory(client, startPath, { title = '选择目标文件夹' } = {}) {
  return new Promise((resolve) => {
    let current = startPath;
    let settled = false;
    const finish = (value) => { if (!settled) { settled = true; resolve(value); } };

    const pathLine = el('div', { class: 'picker__head' });
    const list = el('div', { class: 'picker__list' });
    const body = el('div', {}, el('div', { class: 'picker' }, pathLine, list));
    const dialog = modal({ title, body, footer: true, onClose: () => finish(null) });

    const cancel = el('button', { class: 'btn btn--ghost' }, '取消');
    cancel.addEventListener('click', () => dialog.close());
    const ok = el('button', { class: 'btn btn--primary' }, '使用此文件夹');
    ok.addEventListener('click', () => { dialog.close(); finish(current); });
    dialog.foot.append(el('span', { class: 'form-hint' }, '只能选择服务器已暴露的根目录内部'), el('div', { class: 'spacer' }), cancel, ok);

    async function load(target) {
      current = target;
      pathLine.innerHTML = `${icon('folder', 'i--sm kind-folder')}<span class="mono">${esc(target)}</span>`;
      list.innerHTML = `<div class="picker__empty">载入中…</div>`;
      try {
        const data = await client.list(target);
        const dirs = (data.entries || []).filter((entry) => entry.dir);
        list.innerHTML = '';
        const up = target.split('/').filter(Boolean).length > 1
          ? '/' + target.split('/').filter(Boolean).slice(0, -1).join('/')
          : null;
        if (up) {
          const button = el('button', { class: 'picker__item' });
          button.innerHTML = `${icon('arrow-up', 'i--sm')}<span>上一层</span>`;
          button.addEventListener('click', () => load(up));
          list.append(button);
        }
        if (!dirs.length) list.append(el('div', { class: 'picker__empty' }, '这里没有子文件夹'));
        for (const dir of dirs) {
          const button = el('button', { class: 'picker__item' });
          button.innerHTML = `${icon('folder', 'i--sm kind-folder')}<span>${esc(dir.name)}</span>`;
          button.addEventListener('click', () => load(dir.path));
          list.append(button);
        }
      } catch (error) {
        list.innerHTML = `<div class="picker__empty">无法读取：${esc(error.message)}</div>`;
      }
    }
    load(startPath);
  });
}

/* ── context menu ───────────────────────────────────────────────────────── */

let contextOpen = false;

export function hideContextMenu() {
  const root = $('#context-menu');
  root.hidden = true;
  root.innerHTML = '';
  if (contextOpen) {
    document.removeEventListener('mousedown', onDocumentMouseDown, true);
    document.removeEventListener('scroll', hideContextMenu, true);
    window.removeEventListener('resize', hideContextMenu);
    contextOpen = false;
  }
}

function onDocumentMouseDown(event) {
  const root = $('#context-menu');
  if (!root.contains(event.target)) hideContextMenu();
}

export function contextMenu(items, { x, y }) {
  const root = $('#context-menu');
  root.innerHTML = '';
  for (const item of items) {
    if (!item) continue;
    if (item === 'sep') { root.append(el('hr')); continue; }
    if (item.header) { root.append(el('div', { class: 'ctx__label' }, item.header)); continue; }
    const button = el('button', { class: item.danger ? 'is-danger' : '' });
    button.innerHTML = `${icon(item.icon || 'chevron-right', 'i--sm')}<span>${esc(item.label)}</span>`;
    button.addEventListener('click', () => { hideContextMenu(); item.action?.(); });
    root.append(button);
  }
  root.hidden = false;
  root.style.left = '0px';
  root.style.top = '0px';
  const rect = root.getBoundingClientRect();
  root.style.left = `${Math.max(8, Math.min(x, window.innerWidth - rect.width - 8))}px`;
  root.style.top = `${Math.max(8, Math.min(y, window.innerHeight - rect.height - 8))}px`;
  if (!contextOpen) {
    contextOpen = true;
    setTimeout(() => {
      document.addEventListener('mousedown', onDocumentMouseDown, true);
      document.addEventListener('scroll', hideContextMenu, true);
      window.addEventListener('resize', hideContextMenu);
    }, 0);
  }
}

/* ── inline banner (e.g. read-only host) ───────────────────────────────── */

export function setBanner(content, kind = 'warn') {
  const existing = $('#app-banner');
  if (!content) { existing?.remove(); return null; }
  const node = existing || el('div', { class: 'banner', id: 'app-banner' });
  node.className = `banner banner--${kind}`;
  node.innerHTML = `${icon(kind === 'warn' ? 'warn' : 'info', 'i--sm')}<span>${esc(content)}</span>`;
  if (!existing) $('#listing').before(node);
  return node;
}
