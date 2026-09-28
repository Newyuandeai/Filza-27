/**
 * FilzaRemote console bootstrap: pairing, connection, shell wiring, live events.
 * Loaded as an ES module; served either by the device's embedded server or from
 * any static host (then it simply points at another FilzaRemote host).
 */
import { FilzaClient, saveUrl } from './api.js';
import { $, $$, el, esc, fmtBytes, fmtDuration, fmtRel, baseName, debounce, plural } from './util.js';
import { loadSprite, icon, toast, modal, pickDirectory, setBanner, hideContextMenu } from './ui.js';
import { Browser } from './browser.js';
import { Transfers } from './transfers.js';
import { Preview } from './preview.js';

const KEY = {
  conn: 'filzaremote.conn.v1',
  settings: 'filzaremote.settings.v1',
  favorites: 'filzaremote.favorites.v1',
  recents: 'filzaremote.recents.v1',
};

function readJSON(key, fallback) {
  try { return JSON.parse(localStorage.getItem(key)) ?? fallback; } catch { return fallback; }
}
function writeJSON(key, value) {
  try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* private mode */ }
}

/** Accepts "192.168.1.20:8787", "host#pair=…", full URLs — returns a clean origin. */
function normalizeBase(raw) {
  let text = String(raw || '').trim();
  if (!text) return window.location.origin;
  text = text.split('#')[0].split('?')[0];
  if (!/^https?:\/\//i.test(text)) text = `http://${text}`;
  try {
    const url = new URL(text);
    return `${url.protocol}//${url.host}`;
  } catch {
    return window.location.origin;
  }
}

class App {
  constructor() {
    this.client = null;
    this.info = null;
    this.latency = null;
    this.favorites = readJSON(KEY.favorites, []);
    this.recents = readJSON(KEY.recents, []);
    this.settings = readJSON(KEY.settings, { theme: 'dark', showHidden: false, path: null });
    this.events = null;
    this.browser = new Browser(this);
    this.transfers = new Transfers(this);
    this.preview = new Preview(this);
    this.reloadSoon = debounce(() => {
      if (this.browser.path) this.browser.reload({ silent: true });
    }, 400);
  }

  /* ── boot ─────────────────────────────────────────────────────────────── */

  async boot() {
    await loadSprite();
    this.applyTheme(this.settings.theme);
    this.browser.view = this.settings.view || 'list';
    this.browser.showHidden = !!this.settings.showHidden;
    this.#bindChrome();

    const params = new URLSearchParams(window.location.hash.replace(/^#/, ''));
    const pairToken = params.get('pair') || params.get('token');
    const saved = readJSON(KEY.conn, null);
    $('#connect-host').value = saved?.baseUrl || window.location.origin;
    if (pairToken) {
      $('#connect-host').value = window.location.origin;
      $('#connect-token').value = pairToken;
    } else if (saved?.token) {
      $('#connect-token').value = saved.token;
    }

    if (pairToken) {
      await this.connect(window.location.origin, pairToken);
    } else if (saved?.token) {
      await this.connect(saved.baseUrl, saved.token, { silent: true });
    }
  }

  applyTheme(theme) {
    const next = theme === 'light' ? 'light' : 'dark';
    document.documentElement.dataset.theme = next;
    this.settings.theme = next;
    const button = $('#btn-theme');
    if (button) button.innerHTML = icon(next === 'dark' ? 'sun' : 'moon');
    writeJSON(KEY.settings, this.settings);
  }

  persistSettings() {
    this.settings.showHidden = this.browser.showHidden;
    this.settings.view = this.browser.view;
    this.settings.path = this.browser.path;
    writeJSON(KEY.settings, this.settings);
  }

  persistRecents() { writeJSON(KEY.recents, this.recents); }

  /* ── connection ───────────────────────────────────────────────────────── */

  async connect(baseUrlRaw, tokenRaw, { silent = false } = {}) {
    const baseUrl = normalizeBase(baseUrlRaw);
    const token = String(tokenRaw || '').trim();
    const errorBox = $('#connect-error');
    errorBox.hidden = true;
    const submit = $('#connect-submit');
    submit.disabled = true;
    submit.textContent = '连接中…';
    const client = new FilzaClient({ baseUrl, token });
    try {
      const info = await client.info();
      this.client = client;
      this.info = info;
      writeJSON(KEY.conn, { baseUrl, token });
      $('#connect-screen').hidden = true;
      $('#app-shell').hidden = false;
      document.title = `FilzaRemote · ${info.device?.model || baseUrl}`;
      this.renderSidebar();
      this.renderConnPill();
      this.#startPolling();
      const roots = info.roots || [];
      const preferred = this.settings.path && roots.some((root) => this.settings.path.startsWith(root.path))
        ? this.settings.path
        : (roots[0]?.path || '/');
      await this.browser.navigate(preferred, { push: true });
      this.#restartEvents();
      toast('已连接', `${info.device?.model || baseUrl} · ${plural(roots.length, '个位置')}`, 'ok', 3000);
      return true;
    } catch (error) {
      const message = this.describeConnectError(error);
      if (!silent) {
        errorBox.hidden = false;
        errorBox.textContent = message;
      } else {
        toast('自动连接失败', message, 'warn', 5000);
      }
      return false;
    } finally {
      submit.disabled = false;
      submit.textContent = '连接';
    }
  }

  describeConnectError(error) {
    if (error?.status === 401) return '配对令牌不正确或已轮换。请在设备端 App 仪表盘复制最新令牌。';
    if (error?.status === 429) return '请求过于频繁，稍后再试（服务端限速）。';
    if (error?.status === 0 || error?.code === 'network_error') {
      return '连不上设备：确认手机与这台电脑在同一局域网、App 里服务器已开启，并检查 IP 与端口。';
    }
    return error?.message || '未知错误';
  }

  async handleAuthFailure() {
    this.events?.close();
    this.events = null;
    this.client = null;
    writeJSON(KEY.conn, null);
    $('#app-shell').hidden = true;
    $('#connect-screen').hidden = false;
    const box = $('#connect-error');
    box.hidden = false;
    box.textContent = '登录状态已失效（令牌被轮换或服务器重启）。请重新配对。';
    toast('连接已失效', '请重新输入配对令牌', 'warn', 6000);
  }

  disconnect() {
    this.events?.close();
    this.events = null;
    this.client = null;
    this.info = null;
    $('#app-shell').hidden = true;
    $('#connect-screen').hidden = false;
    $('#connect-error').hidden = true;
    setBanner(null);
  }

  /* ── live events + polling ────────────────────────────────────────────── */

  #restartEvents() {
    this.events?.close();
    this.events = null;
    if (!this.client || !this.browser.path) return;
    this.events = this.client.events(this.browser.path, {
      onEvent: () => this.reloadSoon(),
      onError: () => this.#setConnState('down'),
      onOpen: () => this.#setConnState('live'),
    });
  }

  onPathChanged(path) {
    this.settings.path = path;
    writeJSON(KEY.settings, this.settings);
    this.#restartEvents();
    this.renderSidebar();
    this.renderStatusPath(path);
  }

  renderStatusPath(path) {
    $('#status-path').textContent = path || '';
  }

  #startPolling() {
    clearInterval(this.pollTimer);
    const tick = async () => {
      if (!this.client) return;
      try {
        const started = performance.now();
        await this.client.ping();
        this.latency = Math.round(performance.now() - started);
        const info = await this.client.info();
        this.info = info;
        this.renderSidebar();
        this.renderConnPill();
        this.#setConnState('live');
      } catch {
        this.#setConnState('down');
      }
    };
    tick();
    this.pollTimer = setInterval(tick, 20000);
  }

  #setConnState(state) {
    const pill = $('#conn-pill');
    pill.classList.toggle('is-live', state === 'live');
    pill.classList.toggle('is-down', state === 'down');
  }

  renderConnPill() {
    const info = this.info;
    if (!info) return;
    $('#conn-host').textContent = `${info.host || 'localhost'}:${info.port ?? ''}`;
    const bits = [];
    if (this.latency !== null) bits.push(`${this.latency} ms`);
    if (info.hostKind) bits.push(info.hostKind);
    $('#conn-meta').textContent = bits.join(' · ');
  }

  /* ── sidebar ──────────────────────────────────────────────────────────── */

  renderSidebar() {
    const info = this.info;
    if (!info) return;
    const roots = info.roots || [];
    const list = $('#root-list');
    list.innerHTML = '';
    for (const root of roots) {
      const item = el('li');
      const button = el('button', { class: `root-link${this.browser.path?.startsWith(root.path) ? ' is-active' : ''}`, title: `${root.label || root.name} — ${root.path}` });
      button.innerHTML = `${icon('storage', 'i--sm')}<span class="root-link__label">${esc(root.label || root.name)}</span><span class="root-link__tag">${root.writable ? '可写' : '只读'}</span>`;
      button.addEventListener('click', () => this.browser.navigate(root.path));
      button.addEventListener('contextmenu', (event) => {
        event.preventDefault();
        this.browser.path = root.path;
        this.browser.pathMenu(event);
      });
      item.append(button);
      list.append(item);
    }

    const favList = $('#favorite-list');
    favList.innerHTML = '';
    const groups = [
      { label: '最近', items: this.recents, kind: 'clock' },
      { label: '收藏', items: this.favorites, kind: 'star-filled' },
    ];
    let rendered = 0;
    for (const group of groups) {
      if (!group.items.length) continue;
      favList.insertAdjacentHTML('beforeend', `<li class="ctx__label" style="padding-left:2px">${group.label}</li>`);
      for (const path of group.items.slice(0, 6)) {
        const item = el('li');
        const button = el('button', { class: 'root-link', title: path });
        button.innerHTML = `${icon(group.kind, 'i--sm')}<span class="root-link__label">${esc(baseName(path) || path)}</span>`;
        button.addEventListener('click', () => this.browser.navigate(path));
        button.addEventListener('contextmenu', (event) => {
          event.preventDefault();
          const target = event.currentTarget;
          const menu = [
            { label: '打开', icon: 'folder', action: () => this.browser.navigate(path) },
            { label: '复制路径', icon: 'link', action: () => navigator.clipboard?.writeText(path) },
          ];
          if (group.kind === 'star-filled') menu.push({ label: '移除收藏', icon: 'trash', danger: true, action: () => this.removeFavorite(path) });
          void target;
          import('./ui.js').then((ui) => ui.contextMenu(menu, { x: event.clientX, y: event.clientY }));
        });
        item.append(button);
        favList.append(item);
        rendered += 1;
      }
    }
    if (!rendered) favList.innerHTML = `<li class="empty-hint">右键目录即可收藏，或用侧栏“最近”快速回到上次位置。</li>`;

    const storage = info.storage || {};
    const total = storage.totalBytes || 0;
    const free = storage.freeBytes || 0;
    const used = storage.usedBytes || Math.max(0, total - free);
    $('#storage-fill').style.width = total ? `${Math.min(100, Math.round((used / total) * 100))}%` : '0%';
    $('#storage-used').textContent = total ? `已用 ${fmtBytes(used)}` : '容量未知';
    $('#storage-free').textContent = total ? `可用 ${fmtBytes(free)}` : '';

    $('#dev-model').textContent = info.device?.model || '—';
    $('#dev-os').textContent = info.device?.android || '—';
    $('#dev-port').textContent = String(info.port ?? '—');
    $('#dev-uptime').textContent = fmtDuration(info.uptimeMs || 0);
    $('#sidebar-foot').innerHTML = `FilzaRemote v${esc(info.version || '?')} · ${info.features?.length || 0} 项能力 · 令牌保护中`;
  }

  /* ── favorites ────────────────────────────────────────────────────────── */

  isFavorite(path) { return this.favorites.includes(path); }
  addFavorite(path) { if (path && !this.favorites.includes(path)) { this.favorites.unshift(path); this.favorites = this.favorites.slice(0, 20); writeJSON(KEY.favorites, this.favorites); this.renderSidebar(); } }
  removeFavorite(path) { this.favorites = this.favorites.filter((item) => item !== path); writeJSON(KEY.favorites, this.favorites); this.renderSidebar(); }
  toggleFavorite(path) {
    if (this.isFavorite(path)) { this.removeFavorite(path); toast('已取消收藏', path, 'info', 2400); }
    else { this.addFavorite(path); toast('已收藏', path, 'ok', 2400); }
  }
  recordRecent(path) {
    if (!path) return;
    this.recents = [path, ...this.recents.filter((item) => item !== path)].slice(0, 12);
    this.persistRecents();
  }

  /* ── helpers used by the views ────────────────────────────────────────── */

  async pickFolder(start, title) {
    return pickDirectory(this.client, start || this.browser.path, { title });
  }

  openFilePicker(dir) {
    if (!dir) return;
    const input = el('input', { type: 'file', multiple: true, style: 'display:none' });
    input.addEventListener('change', async () => {
      const files = Array.from(input.files || []).map((file) => ({ file, relativePath: '' }));
      input.remove();
      if (files.length) await this.transfers.uploadFiles(files, dir);
    });
    document.body.append(input);
    input.click();
  }

  /* ── chrome wiring ────────────────────────────────────────────────────── */

  #bindChrome() {
    $('#connect-form').addEventListener('submit', async (event) => {
      event.preventDefault();
      const pair = $('#connect-pair').value.trim();
      const token = pair
        ? new URLSearchParams(String(pair).split('#')[1] || '').get('pair') || $('#connect-token').value.trim()
        : $('#connect-token').value.trim();
      const host = pair ? normalizeBase(pair) : $('#connect-host').value;
      await this.connect(host, token);
    });

    $('#connect-demo').addEventListener('click', () => {
      $('#connect-host').value = window.location.origin;
      toast('已填入当前站点', '把宿主控制台打印的 Token 粘贴进来即可（本机演示宿主默认端口 8787）', 'info', 7000);
      $('#connect-token').focus();
    });

    $('#btn-disconnect').addEventListener('click', () => this.disconnect());
    $('#btn-theme').addEventListener('click', () => this.applyTheme(this.settings.theme === 'dark' ? 'light' : 'dark'));
    $('#btn-sidebar').addEventListener('click', () => $('.shell').classList.toggle('sidebar-open'));
    $('#conn-pill').addEventListener('click', () => this.openDeviceModal());

    $('#search-form').addEventListener('submit', (event) => {
      event.preventDefault();
      this.browser.runSearch($('#search-input').value);
    });
    $('#search-input').addEventListener('input', debounce((event) => {
      const value = event.target.value.trim();
      if (value.length >= 2) this.browser.runSearch(value, { silent: true });
      else if (!value) this.browser.clearSearch();
    }, 420));
    $('#search-clear').addEventListener('click', () => this.browser.clearSearch());

    document.addEventListener('keydown', (event) => {
      const tag = document.activeElement?.tagName;
      const typing = tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT';
      if (event.key === '/' && !typing) {
        event.preventDefault();
        $('#search-input')?.focus();
      }
      if (event.key === 'Escape') hideContextMenu();
    });

    window.addEventListener('beforeunload', () => this.persistSettings());
    window.addEventListener('resize', () => {
      if (window.innerWidth > 900) $('.shell').classList.remove('sidebar-open');
    });
  }

  /* ── device / clients / settings modal ───────────────────────────────── */

  async openDeviceModal() {
    if (!this.client) return;
    const body = el('div');
    body.innerHTML = '<p class="muted">载入中…</p>';
    const dialog = modal({ title: '设备与设置', subtitle: this.client.baseUrl, body, footer: true });
    dialog.foot.append(el('span', { class: 'form-hint' }, '设置会保存在设备端'), el('div', { class: 'spacer' }));
    const close = el('button', { class: 'btn btn--ghost' }, '关闭');
    close.addEventListener('click', () => dialog.close());
    dialog.foot.append(close);

    try {
      const [clients, info] = await Promise.all([this.client.clients(), this.client.info()]);
      const roots = (info.roots || []).map((root) => `<li>${esc(root.label || root.name)} · <span class="mono">${esc(root.path)}</span> ${root.writable ? '（可写）' : '（只读）'}</li>`).join('');
      const clientRows = (clients.clients || []).map((item) => `<tr><td class="mono">${esc(item.remote)}</td><td>${item.requests}</td><td>${esc(fmtRel(item.lastSeen))}</td><td class="mono" style="max-width:220px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${esc(item.userAgent || '')}</td></tr>`).join('');
      const logRows = (clients.log || []).slice(0, 25).map((item) => `<tr><td class="mono">${esc(item.method)}</td><td class="mono" style="max-width:340px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${esc(item.path)}</td><td>${item.status}</td><td>${item.ms} ms</td></tr>`).join('');
      body.innerHTML = `
        <div class="form-row">
          <label>设备</label>
          <div class="form-hint">${esc(info.device?.model || '')} · ${esc(info.device?.android || '')} · 宿主类型 ${esc(info.hostKind || '')} · 运行 ${esc(fmtDuration(info.uptimeMs || 0))}</div>
        </div>
        <div class="form-row"><label>当前位置</label>
          <ul class="form-hint" style="margin:0;padding-left:18px">${roots || '<li>无</li>'}</ul>
        </div>
        <div class="form-row"><label>内置开关（写入设备）</label>
          <label class="form-hint"><input type="checkbox" id="set-writes" ${info.writesEnabled ? 'checked' : ''}> 允许写入（上传/新建/重命名/移动）</label>
          <label class="form-hint"><input type="checkbox" id="set-deletes" ${info.deletesEnabled ? 'checked' : ''}> 允许删除</label>
          <label class="form-hint"><input type="checkbox" id="set-hidden" ${this.browser.showHidden ? 'checked' : ''}> 显示隐藏文件（本浏览器）</label>
        </div>
        <div class="form-row"><label>已连接客户端（${(clients.clients || []).length}）· 当前连接 ${clients.connections ?? 0}</label>
          <table class="form-hint" style="width:100%;border-collapse:collapse"><thead><tr><th align="left">来源</th><th align="left">请求</th><th align="left">最近</th><th align="left">UA</th></tr></thead><tbody>${clientRows || '<tr><td colspan="4">暂无</td></tr>'}</tbody></table>
        </div>
        <div class="form-row"><label>最近请求日志</label>
          <table class="form-hint" style="width:100%;border-collapse:collapse"><tbody>${logRows || '<tr><td>暂无</td></tr>'}</tbody></table>
        </div>`;

      const apply = async () => {
        try {
          await this.client.settings({
            writesEnabled: $('#set-writes').checked,
            deletesEnabled: $('#set-deletes').checked,
          });
          this.browser.showHidden = $('#set-hidden').checked;
          this.settings.showHidden = this.browser.showHidden;
          this.persistSettings();
          this.info = await this.client.info();
          this.renderSidebar();
          this.browser.reload({ silent: true });
          toast('设置已应用', '设备端已更新', 'ok', 2600);
        } catch (error) {
          toast('设置失败', error.message, 'err');
        }
      };
      const save = el('button', { class: 'btn btn--primary' }, '应用开关');
      save.addEventListener('click', apply);
      dialog.foot.insertBefore(save, close);
    } catch (error) {
      body.innerHTML = `<p class="muted">读取设备信息失败：${esc(error.message)}</p>`;
    }
  }
}

const app = new App();
window.filzaremote = app;   // handy for debugging in the browser console
app.boot();
