/** Transfer queue: resumable uploads with progress + downloads/ZIP handoff. */
import { $, $$, el, esc, fmtBytes, fmtSpeed, uid, plural, baseName, joinPath } from './util.js';
import { icon, toast } from './ui.js';
import { saveBlob, saveUrl } from './api.js';

const CONCURRENCY = 2;
const LARGE_DOWNLOAD = 96 * 1024 * 1024;

export class Transfers {
  constructor(app) {
    this.app = app;
    this.items = [];
    this.filter = 'all';
    this.panelOpen = false;
    this.pending = [];
    this.active = 0;
    this.#bind();
  }

  get client() { return this.app.client; }

  /* ── queue bookkeeping ────────────────────────────────────────────────── */

  add(item) {
    const entry = {
      id: uid(),
      status: 'queued',
      sent: 0,
      speed: 0,
      error: null,
      startedAt: Date.now(),
      lastAt: Date.now(),
      lastSent: 0,
      ...item,
    };
    this.items.unshift(entry);
    if (this.items.length > 120) this.items.length = 120;
    this.render();
    return entry;
  }

  update(id, patch) {
    const item = this.items.find((candidate) => candidate.id === id);
    if (!item) return;
    Object.assign(item, patch);
    // rolling speed estimate
    const now = Date.now();
    const elapsed = (now - item.lastAt) / 1000;
    if (elapsed >= 0.4 && item.status === 'active') {
      const delta = (item.sent || 0) - (item.lastSent || 0);
      item.speed = delta > 0 ? delta / elapsed : 0;
      item.lastAt = now;
      item.lastSent = item.sent || 0;
    }
    this.render();
  }

  /* ── uploads ──────────────────────────────────────────────────────────── */

  async uploadFiles(files, dir) {
    const list = Array.isArray(files) ? files : Array.from(files || []).map((file) => ({ file, relativePath: '' }));
    if (!list.length || !dir) return;
    this.openPanel();
    let queued = 0;
    for (const { file, relativePath } of list) {
      const target = relativePath ? joinPath(dir, relativePath.replace(/\/$/, '')) : dir;
      const item = this.add({ kind: 'upload', name: file.name, size: file.size, dir: target, status: 'queued' });
      queued += 1;
      this.pending.push({ item, file, dir: target });
    }
    toast('已加入上传队列', `${plural(queued, '个文件')} → ${dir}`, 'info', 3000);
    this.#drain();
  }

  async #drain() {
    while (this.active < CONCURRENCY && this.pending.length) {
      const job = this.pending.shift();
      this.active += 1;
      this.#runUpload(job).finally(() => {
        this.active -= 1;
        this.#drain();
      });
    }
    if (!this.pending.length && !this.active) {
      const failed = this.items.filter((item) => item.kind === 'upload' && item.status === 'error').length;
      const done = this.items.filter((item) => item.kind === 'upload' && item.status === 'done').length;
      if (done && failed) toast('上传完成（有失败）', `${done} 成功 · ${failed} 失败`, 'warn', 5000);
      else if (done) {
        toast('上传完成', plural(done, '个文件'), 'ok', 3200);
        await this.app.browser.reload({ silent: true });
      }
    }
  }

  async #runUpload({ item, file, dir }) {
    this.update(item.id, { status: 'active' });
    try {
      // dropped folders arrive with a relative path: make sure it exists first
      const segments = (item.relativePathSegments = String(item.dir).split('/').filter(Boolean));
      const baseDir = this.app.browser.path;
      if (baseDir && !item.dir.startsWith(baseDir) === false) { /* noop, keeps intent explicit */ }
      const relative = item.dir.slice(this.app.browser.path.length).replace(/^\/+/, '');
      if (relative) {
        let walk = this.app.browser.path;
        for (const segment of relative.split('/')) {
          walk = joinPath(walk, segment);
          try { await this.client.mkdir(walk); } catch (error) { if (error.status !== 409) throw error; }
        }
      }
      await this.client.upload(file, dir === item.dir ? dir : dir, {
        overwrite: true,
        onProgress: (sent, total) => this.update(item.id, { sent, size: total }),
        onResume: () => { /* server told us the authoritative offset; the client already resynced */ },
      });
      this.update(item.id, { status: 'done', sent: file.size, speed: 0 });
    } catch (error) {
      if (error.isAuth) return this.app.handleAuthFailure();
      this.update(item.id, { status: 'error', error: error.message || String(error) });
    }
  }

  /* ── downloads ────────────────────────────────────────────────────────── */

  async download(entry) {
    this.openPanel();
    const item = this.add({ kind: 'download', name: entry.name, size: entry.size || 0, path: entry.path, status: 'active' });
    try {
      if ((entry.size || 0) > LARGE_DOWNLOAD) {
        saveUrl(this.client.downloadUrl(entry.path), entry.name);
        this.update(item.id, { status: 'done', sent: entry.size, note: '已交给浏览器下载' });
        return;
      }
      const blob = await this.client.download(entry.path, {
        onProgress: (received, total) => this.update(item.id, { sent: received, size: total || entry.size }),
      });
      saveBlob(blob, entry.name);
      this.update(item.id, { status: 'done', sent: blob.size, size: blob.size || entry.size });
      toast('已下载', entry.name, 'ok', 2600);
    } catch (error) {
      if (error.isAuth) return this.app.handleAuthFailure();
      this.update(item.id, { status: 'error', error: error.message || String(error) });
      toast('下载失败', error.message, 'err');
    }
  }

  downloadZip(entries) {
    const list = (entries || []).filter(Boolean);
    if (!list.length) return;
    this.openPanel();
    const name = list.length === 1 ? `${baseName(list[0].path) || 'root'}.zip` : `filzaremote-${list.length}-items.zip`;
    this.add({ kind: 'download', name, size: 0, status: 'done', sent: 0, note: 'ZIP 已交给浏览器下载' });
    saveUrl(this.client.zipUrl(list.map((entry) => entry.path)), name);
    toast('正在打包下载', list.length === 1 ? list[0].path : plural(list.length, '项'), 'info', 3200);
  }

  /* ── panel UI ─────────────────────────────────────────────────────────── */

  openPanel() {
    this.panelOpen = true;
    $('#transfers-panel').hidden = false;
    $('.body').classList.add('has-drawer');
    this.render();
  }

  closePanel() {
    this.panelOpen = false;
    $('#transfers-panel').hidden = true;
    $('.body').classList.remove('has-drawer');
  }

  togglePanel() {
    if (this.panelOpen) this.closePanel();
    else this.openPanel();
  }

  clearFinished() {
    this.items = this.items.filter((item) => item.status === 'active' || item.status === 'queued');
    this.render();
  }

  render() {
    const list = $('#transfer-list');
    const active = this.items.filter((item) => item.status === 'active' || item.status === 'queued').length;
    const badge = $('#transfers-badge');
    badge.hidden = active === 0;
    badge.textContent = String(active);

    const visible = this.items.filter((item) => this.filter === 'all' || item.kind === this.filter);
    if (!visible.length) {
      list.innerHTML = `<li class="empty-hint">还没有传输任务。拖拽文件到窗口，或点“上传”。</li>`;
      return;
    }
    list.innerHTML = visible.map((item) => {
      const percent = item.size ? Math.min(100, Math.round((item.sent / item.size) * 100)) : (item.status === 'done' ? 100 : 0);
      const statusText = {
        queued: '排队中',
        active: item.kind === 'upload' ? '上传中' : '下载中',
        done: item.note || '完成',
        error: item.error || '失败',
      }[item.status] || item.status;
      const eta = item.status === 'active' && item.speed > 0 && item.size
        ? `剩余 ${Math.max(1, Math.round((item.size - item.sent) / item.speed))}s`
        : '';
      return `<li class="transfer${item.status === 'error' ? ' is-error' : ''}${item.status === 'done' ? ' is-done' : ''}">
        <div class="transfer__top">
          <span class="${item.kind === 'upload' ? 'kind-document' : 'kind-code'}">${icon(item.kind === 'upload' ? 'upload' : 'download', 'i--sm')}</span>
          <span class="transfer__name" title="${esc(item.name)}">${esc(item.name)}</span>
          <span class="transfer__pct">${item.status === 'active' ? percent + '%' : ''}</span>
        </div>
        <div class="transfer__bar"><span class="transfer__fill" style="width:${item.status === 'error' ? 100 : percent}%"></span></div>
        <div class="transfer__meta">
          <span>${esc(statusText)}</span>
          ${item.size ? `<span>${fmtBytes(item.sent)} / ${fmtBytes(item.size)}</span>` : ''}
          ${item.speed ? `<span>${fmtSpeed(item.speed)}</span>` : ''}
          ${eta ? `<span>${esc(eta)}</span>` : ''}
        </div>
      </li>`;
    }).join('');
  }

  #bind() {
    $('#btn-transfers').addEventListener('click', () => this.togglePanel());
    $('#transfers-close').addEventListener('click', () => this.closePanel());
    $('#transfers-clear').addEventListener('click', () => this.clearFinished());
    $$('.drawer__tabs .tab').forEach((tab) => {
      tab.addEventListener('click', () => {
        this.filter = tab.dataset.tab;
        $$('.drawer__tabs .tab').forEach((other) => other.classList.toggle('is-active', other === tab));
        this.render();
      });
    });
  }
}
