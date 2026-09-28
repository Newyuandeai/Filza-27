/** Small DOM/format/path helpers. No dependencies, no build step. */

export const $ = (selector, root = document) => root.querySelector(selector);
export const $$ = (selector, root = document) => Array.from(root.querySelectorAll(selector));

export function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs)) {
    if (value === null || value === undefined || value === false) continue;
    if (key === 'class') node.className = value;
    else if (key === 'dataset') Object.assign(node.dataset, value);
    else if (key === 'html') node.innerHTML = value;
    else if (key.startsWith('on') && typeof value === 'function') node.addEventListener(key.slice(2), value);
    else if (value === true) node.setAttribute(key, '');
    else node.setAttribute(key, String(value));
  }
  for (const child of children.flat()) {
    if (child === null || child === undefined || child === false) continue;
    node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return node;
}

/** Escapes text for safe interpolation into HTML strings. */
export function esc(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

/* ── formatting ─────────────────────────────────────────────────────────── */

export function fmtBytes(bytes) {
  const n = Number(bytes) || 0;
  if (n < 1024) return `${n} B`;
  const units = ['KB', 'MB', 'GB', 'TB', 'PB'];
  let value = n / 1024;
  let index = 0;
  while (value >= 1024 && index < units.length - 1) { value /= 1024; index += 1; }
  return `${value < 10 ? value.toFixed(1) : Math.round(value)} ${units[index]}`;
}

export function fmtDate(ms) {
  if (!ms) return '—';
  const date = new Date(ms);
  const pad = (n) => String(n).padStart(2, '0');
  const now = new Date();
  const sameYear = date.getFullYear() === now.getFullYear();
  const datePart = sameYear
    ? `${pad(date.getMonth() + 1)}-${pad(date.getDate())}`
    : `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
  return `${datePart} ${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

export function fmtRel(ms) {
  if (!ms) return '—';
  const delta = Date.now() - ms;
  const minute = 60000, hour = 3600000, day = 86400000;
  if (delta < minute) return '刚刚';
  if (delta < hour) return `${Math.floor(delta / minute)} 分钟前`;
  if (delta < day) return `${Math.floor(delta / hour)} 小时前`;
  if (delta < day * 30) return `${Math.floor(delta / day)} 天前`;
  return fmtDate(ms);
}

export function fmtDuration(ms) {
  const total = Math.max(0, Math.round((Number(ms) || 0) / 1000));
  const seconds = total % 60;
  const minutes = Math.floor(total / 60) % 60;
  const hours = Math.floor(total / 3600);
  if (hours) return `${hours}h ${minutes}m`;
  if (minutes) return `${minutes}m ${seconds}s`;
  return `${seconds}s`;
}

export function fmtSpeed(bytesPerSecond) {
  if (!Number.isFinite(bytesPerSecond) || bytesPerSecond <= 0) return '—';
  return `${fmtBytes(bytesPerSecond)}/s`;
}

/* ── paths ──────────────────────────────────────────────────────────────── */

export function joinPath(dir, name) {
  const base = String(dir || '').replace(/\/+$/, '');
  return `${base}/${String(name || '').replace(/^\/+/, '')}`;
}

export function parentPath(path) {
  const parts = String(path || '').split('/').filter(Boolean);
  if (parts.length <= 1) return null;
  return '/' + parts.slice(0, -1).join('/');
}

export function baseName(path) {
  const parts = String(path || '').split('/').filter(Boolean);
  return parts.length ? parts[parts.length - 1] : '';
}

export function pathSegments(path) {
  return String(path || '').split('/').filter(Boolean);
}

export function extOf(name) {
  const index = String(name || '').lastIndexOf('.');
  return index > 0 ? String(name).slice(index + 1).toLowerCase() : '';
}

/* ── misc ───────────────────────────────────────────────────────────────── */

export const KIND_ICON = {
  folder: 'folder',
  image: 'image',
  video: 'video',
  audio: 'audio',
  archive: 'archive',
  document: 'document',
  code: 'code',
  text: 'text',
  apk: 'apk',
  disk: 'disk',
  other: 'file',
};

export function kindIcon(entry) {
  return KIND_ICON[entry?.kind] || 'file';
}

export function iconNameForKind(kind) {
  return KIND_ICON[kind] || 'file';
}

export function debounce(fn, wait = 220) {
  let timer = null;
  return (...args) => {
    clearTimeout(timer);
    timer = setTimeout(() => fn(...args), wait);
  };
}

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max);
}

export function uid() {
  return Math.random().toString(36).slice(2, 10);
}

export function plural(count, one, many = `${one}`) {
  return `${count} ${count === 1 ? one : many}`;
}
