/** File listing: list/grid views, selection, sorting, crumbs, drag-drop, keyboard. */
import { $, el, esc, fmtBytes, fmtDate, kindIcon, joinPath, parentPath, plural } from './util.js';
import { icon, toast, contextMenu, setBanner, confirmDialog, promptDialog } from './ui.js';

const BATCH = 400; // render rows in batches so a 5000-entry directory stays responsive

export class Browser {
  constructor(app) {
    this.app = app;
    this.path = null;
    this.entries = [];
    this.truncated = false;
    this.searchState = null;      // { term, results, scanned, limitReached }
    this.sort = { key: 'name', dir: 1 };
    this.view = 'list';
    this.showHidden = false;
    this.selection = new Set();
    this.cursor = -1;
    this.loading = false;
    this.error = null;
    this.history = [];
    this.historyIndex = -1;
    this.rendered = 0;
    this.#bindOnce();
  }

  get client() { return this.app.client; }
  get items() { return this.searchState ? this.searchState.results : this.entries; }

  /* ── data ─────────────────────────────────────────────────────────────── */

  async navigate(path, { push = true, silent = false } = {}) {
    if (!path) return;
    this.loading = true;
    this.error = null;
    this.searchState = null;
    if (!silent) this.render();
    try {
      const data = await this.client.list(path, { showHidden: this.showHidden ? 1 : 0 });
      this.path = data.path;
      this.entries = data.entries || [];
      this.truncated = !!data.truncated;
      this.selection.clear();
      this.cursor = this.entries.length ? 0 : -1;
      if (push) this.#pushHistory(data.path);
      this.#remember(data.path);
      this.app.onPathChanged(data.path);
    } catch (error) {
      this.error = error;
      if (error.isAuth) return this.app.handleAuthFailure();
      if (!silent) toast('无法打开目录', error.message, 'err');
    } finally {
      this.loading = false;
      this.render();
    }
  }

  async reload({ silent = false } = {}) {
    if (this.searchState) return this.runSearch(this.searchState.term, { silent });
    if (this.path) return this.navigate(this.path, { push: false, silent });
    return undefined;
  }

  async runSearch(term, { silent = false } = {}) {
    const trimmed = String(term || '').trim();
    if (!trimmed) return this.clearSearch();
    this.loading = true;
    this.error = null;
    if (!silent) this.render();
    try {
      const data = await this.client.search(this.path, trimmed, { limit: 500 });
      this.searchState = {
        term: trimmed,
        results: data.results || [],
        scanned: data.scanned || 0,
        limitReached: !!data.limitReached,
        tookMs: data.tookMs || 0,
      };
      this.selection.clear();
      this.cursor = this.items.length ? 0 : -1;
    } catch (error) {
      this.error = error;
      if (error.isAuth) return this.app.handleAuthFailure();
      toast('搜索失败', error.message, 'err');
    } finally {
      this.loading = false;
      this.render();
    }
    return undefined;
  }

  clearSearch() {
    if (!this.searchState) return;
    this.searchState = null;
    $('#search-input').value = '';
    this.render();
  }

  applySort(entries) {
    const { key, dir } = this.sort;
    const factor = dir;
    const compare = (a, b) => {
      if (a.dir !== b.dir) return a.dir ? -1 : 1;   // folders always first
      switch (key) {
        case 'size': return (a.size - b.size) * factor;
        case 'mtime': return (a.mtime - b.mtime) * factor;
        case 'kind': return (a.kind.localeCompare(b.kind) || a.name.localeCompare(b.name)) * factor;
        default: return a.name.localeCompare(b.name, undefined, { sensitivity: 'base', numeric: true }) * factor;
      }
    };
    return [...entries].sort(compare);
  }

  /* ── selection ────────────────────────────────────────────────────────── */

  selectOnly(entry) {
    this.selection.clear();
    if (entry) this.selection.add(entry.path);
    this.#syncSelectionBar();
  }

  toggle(entry, extend = false) {
    if (extend && this.cursor >= 0) {
      const list = this.items;
      const target = list.findIndex((item) => item.path === entry.path);
      const [from, to] = [Math.min(this.cursor, target), Math.max(this.cursor, target)];
      for (let i = from; i <= to; i += 1) this.selection.add(list[i].path);
    } else if (this.selection.has(entry.path)) {
      this.selection.delete(entry.path);
    } else {
      this.selection.add(entry.path);
    }
    this.#syncSelectionBar();
  }

  selectAll() {
    this.selection = new Set(this.items.map((entry) => entry.path));
    this.#syncSelectionBar();
    this.render();
  }

  clearSelection() {
    this.selection.clear();
    this.#syncSelectionBar();
    this.render();
  }

  selectedEntries() {
    const wanted = this.selection;
    return this.items.filter((entry) => wanted.has(entry.path));
  }

  #syncSelectionBar() {
    const bar = $('#selbar');
    const count = this.selection.size;
    bar.hidden = count === 0;
    $('#sel-count').textContent = `已选 ${count} 项`;
    this.render();
  }

  /* ── actions ──────────────────────────────────────────────────────────── */

  open(entry) {
    if (!entry) return;
    if (entry.dir) { this.app.recordRecent(entry.path); return void this.navigate(entry.path); }
    return void this.app.preview.open(entry, this.items);
  }

  async newFolder() {
    const name = await promptDialog({
      title: '新建文件夹', label: '文件夹名称', value: '新建文件夹',
      hint: `将在 ${this.path} 下创建`, mono: true, selectBasename: true,
    });
    if (!name) return;
    try {
      await this.client.mkdir(joinPath(this.path, name));
      toast('已创建文件夹', name, 'ok');
      await this.reload();
    } catch (error) {
      toast('创建失败', error.message, 'err');
    }
  }

  async renameEntry(entry) {
    if (!entry) return;
    const name = await promptDialog({
      title: '重命名', label: '新名称', value: entry.name, mono: true, selectBasename: true,
      hint: '同一目录内的新名称',
    });
    if (!name || name === entry.name) return;
    try {
      await this.client.rename(entry.path, joinPath(this.path, name));
      toast('已重命名', `${entry.name} → ${name}`, 'ok');
      await this.reload();
    } catch (error) {
      toast('重命名失败', error.message, 'err');
    }
  }

  async deleteEntries(entries) {
    const list = entries.filter(Boolean);
    if (!list.length) return;
    const preview = list.slice(0, 6).map((entry) => `· ${entry.name}`).join('\n');
    const more = list.length > 6 ? `\n· …以及另外 ${list.length - 6} 项` : '';
    const ok = await confirmDialog({
      title: `删除 ${plural(list.length, '项')}？`,
      message: `${preview}${more}\n\n此操作在设备上不可撤销（部分宿主会移入废纸篓）。`,
      confirmText: '删除',
    });
    if (!ok) return;
    try {
      const result = await this.client.remove(list.map((entry) => entry.path));
      const failed = result.failed || [];
      if (failed.length) {
        toast('部分删除失败', failed.map((item) => `${item.path}: ${item.error}`).join('；'), 'warn', 7000);
      } else {
        toast('已删除', plural(result.deleted?.length || list.length, '项'), 'ok');
      }
      this.selection.clear();
      this.#syncSelectionBar();
      await this.reload();
    } catch (error) {
      toast('删除失败', error.message, 'err');
    }
  }

  async copyMove(entries, mode) {
    const list = entries.filter(Boolean);
    if (!list.length) return;
    const dest = await this.app.pickFolder(this.path, mode === 'move' ? '移动到…' : '复制到…');
    if (!dest) return;
    try {
      const result = mode === 'move'
        ? await this.client.move(list.map((entry) => entry.path), dest)
        : await this.client.copy(list.map((entry) => entry.path), dest);
      const done = (mode === 'move' ? result.moved : result.copied) || [];
      const failed = result.failed || [];
      toast(mode === 'move' ? '已移动' : '已复制', `${done.length} 项 → ${dest}`, failed.length ? 'warn' : 'ok');
      if (failed.length) toast('部分失败', failed.map((item) => item.error).join('；'), 'warn', 6000);
      this.selection.clear();
      this.#syncSelectionBar();
      await this.reload();
    } catch (error) {
      toast(mode === 'move' ? '移动失败' : '复制失败', error.message, 'err');
    }
  }

  downloadEntries(entries) {
    const list = entries.filter(Boolean);
    if (!list.length) return;
    if (list.length === 1 && !list[0].dir) return void this.app.transfers.download(list[0]);
    this.app.transfers.downloadZip(list);
  }

  rowMenu(entry, event) {
    const single = this.selection.size <= 1;
    const targets = this.selection.has(entry.path) ? this.selectedEntries() : [entry];
    contextMenu([
      { header: entry.name },
      { label: entry.dir ? '打开' : '预览', icon: entry.dir ? 'folder' : 'eye', action: () => this.open(entry) },
      entry.dir ? null : { label: '下载', icon: 'download', action: () => this.downloadEntries(targets) },
      entry.dir ? { label: '打包下载 (ZIP)', icon: 'download-zip', action: () => this.app.transfers.downloadZip([entry]) } : null,
      'sep',
      { label: '重命名', icon: 'edit', action: () => this.renameEntry(entry) },
      { label: '复制到…', icon: 'copy', action: () => this.copyMove(targets, 'copy') },
      { label: '移动到…', icon: 'move', action: () => this.copyMove(targets, 'move') },
      { label: this.app.isFavorite(this.path) ? '取消收藏当前目录' : '收藏当前目录', icon: 'star', action: () => this.app.toggleFavorite(this.path) },
      'sep',
      { label: '复制虚拟路径', icon: 'link', action: () => this.#copyPath(entry.path) },
      { label: '删除', icon: 'trash', danger: true, action: () => this.deleteEntries(targets) },
    ], { x: event.clientX, y: event.clientY });
    if (single && !this.selection.has(entry.path)) this.selectOnly(entry);
  }

  pathMenu(event) {
    contextMenu([
      { header: this.path },
      { label: '刷新', icon: 'refresh', action: () => this.reload() },
      { label: '新建文件夹', icon: 'folder-plus', action: () => this.newFolder() },
      { label: '上传到此处', icon: 'upload', action: () => this.app.openFilePicker(this.path) },
      'sep',
      { label: '复制虚拟路径', icon: 'link', action: () => this.#copyPath(this.path) },
      this.path && parentPath(this.path) ? { label: '打包当前目录 (ZIP)', icon: 'download-zip', action: () => this.app.transfers.downloadZip([{ path: this.path, name: this.path.split('/').pop(), dir: true }]) } : null,
    ], { x: event.clientX, y: event.clientY });
  }

  async #copyPath(path) {
    try {
      await navigator.clipboard.writeText(path);
      toast('已复制路径', path, 'ok', 2600);
    } catch {
      toast('复制失败', '浏览器拒绝了剪贴板访问', 'warn');
    }
  }

  /* ── rendering ────────────────────────────────────────────────────────── */

  render() {
    this.renderCrumbs();
    this.renderList();
    this.renderStatus();
  }

  renderCrumbs() {
    const crumbs = $('#crumbs');
    if (!this.path) { crumbs.innerHTML = ''; return; }
    const parts = this.path.split('/').filter(Boolean);
    crumbs.innerHTML = '';
    parts.forEach((part, index) => {
      const target = '/' + parts.slice(0, index + 1).join('/');
      const isLast = index === parts.length - 1;
      if (index > 0) crumbs.insertAdjacentHTML('beforeend', `<span class="crumb__sep">${icon('chevron-right', 'i--sm')}</span>`);
      const button = el('button', { class: `crumb${isLast ? ' is-last' : ''}`, title: target });
      button.innerHTML = `${index === 0 ? icon('storage', 'i--sm') : ''}<span>${esc(part)}</span>`;
      button.addEventListener('click', () => this.navigate(target));
      button.addEventListener('contextmenu', (event) => { event.preventDefault(); this.pathMenu(event); });
      crumbs.append(button);
    });
    // keep the last crumb visible on narrow screens
    crumbs.scrollLeft = crumbs.scrollWidth;
  }

  renderList() {
    const listing = $('#listing');
    listing.classList.toggle('is-grid', this.view === 'grid');
    $('#view-list').classList.toggle('is-active', this.view === 'list');
    $('#view-grid').classList.toggle('is-active', this.view === 'grid');
    $('#btn-hidden').classList.toggle('is-active', this.showHidden);

    if (this.loading && !this.items.length) {
      listing.innerHTML = Array.from({ length: 9 }, () => '<div class="skeleton"></div>').join('');
      return;
    }
    if (this.error) {
      listing.innerHTML = this.#stateBlock(
        'state-disconnected.svg',
        '打不开这个位置',
        `${this.error.message}${this.error.code ? ` · ${this.error.code}` : ''}`,
        'state--error',
      );
      listing.querySelector('[data-retry]')?.addEventListener('click', () => this.reload());
      return;
    }
    if (!this.items.length) {
      if (this.searchState) {
        listing.innerHTML = this.#stateBlock('state-no-results.svg', '没有匹配项', `在 ${this.path} 下扫描了 ${this.searchState.scanned} 个目录，用时 ${this.searchState.tookMs} ms`);
      } else {
        listing.innerHTML = this.#stateBlock('state-empty-folder.svg', '这个文件夹是空的', '把文件拖进窗口即可上传');
        listing.insertAdjacentHTML('beforeend', `<div class="state" style="padding-top:0"><button class="btn btn--ghost" data-upload>${icon('upload', 'i--sm')}上传文件</button></div>`);
        listing.querySelector('[data-upload]')?.addEventListener('click', () => this.app.openFilePicker(this.path));
      }
      return;
    }

    const sorted = this.applySort(this.items);
    this.rendered = Math.min(sorted.length, BATCH);
    const head = this.view === 'list' ? this.#listHead() : '';
    listing.innerHTML = head + this.#rows(sorted.slice(0, this.rendered));
    if (this.rendered < sorted.length) {
      listing.insertAdjacentHTML('beforeend', `<div class="state"><button class="btn btn--ghost" data-more>再显示 ${Math.min(BATCH, sorted.length - this.rendered)} 项（共 ${sorted.length} 项）</button></div>`);
      listing.querySelector('[data-more]')?.addEventListener('click', () => {
        const from = this.rendered;
        this.rendered = Math.min(sorted.length, this.rendered + BATCH);
        const holder = document.createElement('div');
        holder.innerHTML = this.#rows(sorted.slice(from, this.rendered));
        listing.querySelector('[data-more]')?.closest('.state').replaceWith(...holder.children);
        if (this.rendered < sorted.length) listing.insertAdjacentHTML('beforeend', `<div class="state"><button class="btn btn--ghost" data-more>再显示 ${Math.min(BATCH, sorted.length - this.rendered)} 项（共 ${sorted.length} 项）</button></div>`);
      });
    }
  }

  #listHead() {
    const sortMark = (key) => (this.sort.key === key ? `<span class="is-sorted">${this.sort.dir > 0 ? '↑' : '↓'}</span>` : '');
    return `<div class="list-head">
      <div class="row__check"></div>
      <button data-sort="name">名称 ${sortMark('name')}</button>
      <button data-sort="size" style="text-align:right">大小 ${sortMark('size')}</button>
      <button data-sort="mtime">修改时间 ${sortMark('mtime')}</button>
      <button data-sort="kind">类型 ${sortMark('kind')}</button>
      <div></div>
    </div>`;
  }

  #rows(entries) {
    return entries.map((entry) => {
      const selected = this.selection.has(entry.path);
      const showPath = this.searchState ? (parentPath(entry.path) || '') : '';
      if (this.view === 'grid') {
        const thumb = entry.kind === 'image'
          ? `<img loading="lazy" decoding="async" src="${esc(this.client.thumbUrl(entry.path, 240))}" alt="" onerror="this.replaceWith(document.createTextNode(''))">`
          : `<span class="kind-${entry.kind}">${icon(kindIcon(entry), 'i--xl')}</span>`;
        return `<div class="card${selected ? ' is-selected' : ''}" data-path="${esc(entry.path)}" title="${esc(entry.path)}">
          <label class="card__check"><input type="checkbox" ${selected ? 'checked' : ''}></label>
          <div class="card__thumb">${thumb}</div>
          <div class="card__name">${esc(entry.name)}</div>
          <div class="card__meta">${entry.dir ? '文件夹' : fmtBytes(entry.size)}</div>
        </div>`;
      }
      return `<div class="row${selected ? ' is-selected' : ''}" data-path="${esc(entry.path)}" title="${esc(entry.path)}">
        <div class="row__check"><input type="checkbox" ${selected ? 'checked' : ''}></div>
        <div class="row__name">
          <span class="row__icon kind-${entry.kind}">${icon(kindIcon(entry), entry.dir ? 'i--lg' : '')}</span>
          <span>${esc(entry.name)}</span>
          ${entry.symlink ? '<span class="form-hint">链接</span>' : ''}
        </div>
        <div class="row__size">${entry.dir ? '—' : fmtBytes(entry.size)}</div>
        <div class="row__time">${esc(showPath || fmtDate(entry.mtime))}</div>
        <div class="row__kind">${esc(entry.dir ? '文件夹' : entry.kind)}</div>
        <div class="row__act"><button class="icon-btn" data-menu title="更多操作">${icon('more', 'i--sm')}</button></div>
      </div>`;
    }).join('');
  }

  #stateBlock(image, title, message, extraClass = '') {
    return `<div class="state ${extraClass}">
      <img src="./assets/images/${esc(image)}" alt="" width="132" height="132">
      <h3>${esc(title)}</h3>
      <p>${esc(message)}</p>
      ${extraClass.includes('error') ? '<button class="btn btn--ghost" data-retry>重试</button>' : ''}
    </div>`;
  }

  renderStatus() {
    const items = this.items.length;
    $('#status-items').textContent = this.searchState
      ? `搜索结果 ${items} 项`
      : `${plural(items, '项')}${this.truncated ? '（仅显示前 5000 项）' : ''}`;
    $('#status-path').textContent = this.path || '';
    const notes = [];
    if (this.selection.size) notes.push(`已选 ${this.selection.size}`);
    if (this.searchState?.limitReached) notes.push('结果已截断到 500 条');
    if (!this.app.info?.writesEnabled) notes.push('宿主的写入已关闭');
    $('#status-note').textContent = notes.join(' · ');
    setBanner(!this.app.info?.writesEnabled ? '设备端已关闭写入与删除，控制台当前是只读模式。' : null);
  }

  /* ── events ───────────────────────────────────────────────────────────── */

  #bindOnce() {
    const listing = $('#listing');

    listing.addEventListener('click', (event) => {
      const more = event.target.closest('[data-more]');
      if (more) return;
      const sortButton = event.target.closest('[data-sort]');
      if (sortButton) {
        const key = sortButton.dataset.sort;
        this.sort = { key, dir: this.sort.key === key ? -this.sort.dir : 1 };
        this.renderList();
        return;
      }
      const node = event.target.closest('.row, .card');
      if (!node) return;
      const entry = this.items.find((item) => item.path === node.dataset.path);
      if (!entry) return;
      if (event.target.closest('input[type=checkbox]')) {
        event.stopPropagation();
        this.toggle(entry, event.shiftKey);
        return;
      }
      if (event.target.closest('[data-menu]')) {
        event.stopPropagation();
        this.rowMenu(entry, event);
        return;
      }
      if (event.metaKey || event.ctrlKey) this.toggle(entry);
      else this.selectOnly(entry);
      this.cursor = this.items.findIndex((item) => item.path === entry.path);
      listing.querySelectorAll('.row.is-cursor, .card.is-cursor').forEach((n) => n.classList.remove('is-cursor'));
      if (this.view === 'list') node.classList.add('is-cursor');
    });

    listing.addEventListener('dblclick', (event) => {
      const node = event.target.closest('.row, .card');
      if (!node) return;
      const entry = this.items.find((item) => item.path === node.dataset.path);
      if (entry) this.open(entry);
    });

    listing.addEventListener('contextmenu', (event) => {
      event.preventDefault();
      const node = event.target.closest('.row, .card');
      if (!node) return this.pathMenu(event);
      const entry = this.items.find((item) => item.path === node.dataset.path);
      if (entry) this.rowMenu(entry, event);
    });

    listing.addEventListener('keydown', (event) => this.onKeyDown(event));

    $('#btn-up').addEventListener('click', () => {
      const up = parentPath(this.path);
      if (up) this.navigate(up);
    });
    $('#btn-back').addEventListener('click', () => {
      if (this.historyIndex > 0) {
        this.historyIndex -= 1;
        this.navigate(this.history[this.historyIndex], { push: false });
      }
    });
    $('#btn-forward').addEventListener('click', () => {
      if (this.historyIndex < this.history.length - 1) {
        this.historyIndex += 1;
        this.navigate(this.history[this.historyIndex], { push: false });
      }
    });
    $('#btn-reload').addEventListener('click', () => this.reload());
    $('#btn-hidden').addEventListener('click', () => {
      this.showHidden = !this.showHidden;
      this.app.settings.showHidden = this.showHidden;
      this.app.persistSettings();
      this.reload();
    });
    $('#sort-select').addEventListener('change', (event) => {
      this.sort = { key: event.target.value, dir: 1 };
      this.renderList();
    });
    $('#view-list').addEventListener('click', () => { this.view = 'list'; this.renderList(); });
    $('#view-grid').addEventListener('click', () => { this.view = 'grid'; this.renderList(); });
    $('#btn-newfolder').addEventListener('click', () => this.newFolder());
    $('#btn-upload').addEventListener('click', () => this.app.openFilePicker(this.path));
    $('#sel-download').addEventListener('click', () => this.downloadEntries(this.selectedEntries()));
    $('#sel-copy').addEventListener('click', () => this.copyMove(this.selectedEntries(), 'copy'));
    $('#sel-move').addEventListener('click', () => this.copyMove(this.selectedEntries(), 'move'));
    $('#sel-delete').addEventListener('click', () => this.deleteEntries(this.selectedEntries()));
    $('#sel-clear').addEventListener('click', () => this.clearSelection());
    $('#sel-fav').addEventListener('click', () => {
      for (const entry of this.selectedEntries()) this.app.addFavorite(entry.path);
      toast('已加入收藏', plural(this.selection.size, '项'), 'ok', 2400);
    });

    // drag & drop upload onto the main area
    const main = $('#main');
    let dragDepth = 0;
    const overlay = $('#drop-overlay');
    window.addEventListener('dragenter', (event) => {
      if (!this.path) return;
      if (!event.dataTransfer?.types?.includes('Files')) return;
      dragDepth += 1;
      overlay.hidden = false;
      $('#drop-target').textContent = this.path;
    });
    window.addEventListener('dragleave', () => {
      dragDepth = Math.max(0, dragDepth - 1);
      if (!dragDepth) overlay.hidden = true;
    });
    window.addEventListener('dragover', (event) => {
      if (event.dataTransfer?.types?.includes('Files')) event.preventDefault();
    });
    window.addEventListener('drop', async (event) => {
      if (!event.dataTransfer?.files?.length) return;
      event.preventDefault();
      dragDepth = 0;
      overlay.hidden = true;
      const files = await collectDroppedFiles(event.dataTransfer);
      await this.app.transfers.uploadFiles(files, this.path);
    });
    main.addEventListener('contextmenu', (event) => {
      if (event.target.closest('.row, .card')) return;
      event.preventDefault();
      this.pathMenu(event);
    });
  }

  onKeyDown(event) {
    const tag = document.activeElement?.tagName;
    if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return;
    const list = this.items;
    if (!list.length) return;
    switch (event.key) {
      case 'ArrowDown':
        event.preventDefault();
        this.cursor = Math.min(list.length - 1, this.cursor + 1);
        this.#cursorChanged();
        break;
      case 'ArrowUp':
        event.preventDefault();
        this.cursor = Math.max(0, this.cursor <= 0 ? 0 : this.cursor - 1);
        this.#cursorChanged();
        break;
      case 'Home': this.cursor = 0; this.#cursorChanged(); break;
      case 'End': this.cursor = list.length - 1; this.#cursorChanged(); break;
      case 'Enter': {
        const entry = list[this.cursor];
        if (entry) { event.preventDefault(); this.open(entry); }
        break;
      }
      case ' ':
        if (list[this.cursor]) { event.preventDefault(); this.toggle(list[this.cursor], event.shiftKey); }
        break;
      case 'Backspace': {
        const up = parentPath(this.path);
        if (up) { event.preventDefault(); this.navigate(up); }
        break;
      }
      case 'Delete': {
        if (this.selection.size) { event.preventDefault(); this.deleteEntries(this.selectedEntries()); }
        break;
      }
      case 'F2': {
        const entry = list[this.cursor];
        if (entry) { event.preventDefault(); this.renameEntry(entry); }
        break;
      }
      case 'Escape':
        if (this.selection.size) this.clearSelection();
        else this.clearSearch();
        break;
      default:
        if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'a') {
          event.preventDefault();
          this.selectAll();
        }
        if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'r') {
          event.preventDefault();
          this.reload();
        }
        break;
    }
  }

  #cursorChanged() {
    const list = this.applySort(this.items);
    const entry = list[this.cursor];
    if (!entry) return;
    this.selectOnly(entry);
    if (this.cursor >= this.rendered) {
      this.rendered = Math.min(list.length, this.cursor + BATCH);
      this.renderList();
    }
    const node = $(`#listing .row[data-path="${CSS.escape(entry.path)}"], #listing .card[data-path="${CSS.escape(entry.path)}"]`);
    node?.scrollIntoView({ block: 'nearest' });
    $('#listing').querySelectorAll('.is-cursor').forEach((n) => n.classList.remove('is-cursor'));
    node?.classList.add('is-cursor');
  }

  #pushHistory(path) {
    if (this.history[this.historyIndex] === path) return;
    this.history = this.history.slice(0, this.historyIndex + 1);
    this.history.push(path);
    if (this.history.length > 60) this.history.shift();
    this.historyIndex = this.history.length - 1;
    this.#syncNavButtons();
  }

  #syncNavButtons() {
    $('#btn-back').disabled = this.historyIndex <= 0;
    $('#btn-forward').disabled = this.historyIndex >= this.history.length - 1;
    $('#btn-up').disabled = !parentPath(this.path);
  }

  #remember(path) {
    const recents = this.app.recents.filter((item) => item !== path);
    recents.unshift(path);
    this.app.recents = recents.slice(0, 12);
    this.app.persistRecents();
  }

  onPathChanged(path) {
    this.#syncNavButtons();
    this.app.onPathChanged(path);
  }
}

/** Expands a DataTransfer into { file, relativePath } entries, folders included. */
export async function collectDroppedFiles(dataTransfer) {
  const items = Array.from(dataTransfer.items || []);
  const entries = items.map((item) => (item.webkitGetAsEntry ? item.webkitGetAsEntry() : null)).filter(Boolean);
  if (!entries.length) {
    return Array.from(dataTransfer.files || []).map((file) => ({ file, relativePath: '' }));
  }
  const collected = [];
  await Promise.all(entries.map((entry) => walkEntry(entry, '', collected)));
  return collected;
}

function walkEntry(entry, prefix, out) {
  return new Promise((resolve) => {
    if (entry.isFile) {
      entry.file((file) => { out.push({ file, relativePath: prefix }); resolve(); }, () => resolve());
      return;
    }
    if (entry.isDirectory) {
      const reader = entry.createReader();
      const readBatch = () => {
        reader.readEntries(async (batch) => {
          if (!batch.length) { resolve(); return; }
          for (const child of batch) await walkEntry(child, `${prefix}${entry.name}/`, out);
          readBatch();
        }, () => resolve());
      };
      readBatch();
      return;
    }
    resolve();
  });
}
