/** Preview modal: images, video/audio, PDF, text/code, hex for binaries. */
import { $, el, esc, fmtBytes, fmtDate, baseName, parentPath, extOf } from './util.js';
import { icon, modal, toast } from './ui.js';

export class Preview {
  constructor(app) {
    this.app = app;
    this.list = [];
    this.index = -1;
    this.dialog = null;
  }

  get client() { return this.app.client; }
  get current() { return this.list[this.index] || null; }

  open(entry, siblings = []) {
    const candidates = (siblings || []).filter((item) => item && !item.dir);
    this.list = candidates.length ? candidates : [entry];
    const found = this.list.findIndex((item) => item.path === entry.path);
    if (found === -1) this.list = [entry];
    this.index = Math.max(0, this.list.findIndex((item) => item.path === entry.path));
    this.render();
  }

  close() {
    this.dialog?.close();
    this.dialog = null;
  }

  navigate(delta) {
    if (this.list.length < 2) return;
    this.index = (this.index + delta + this.list.length) % this.list.length;
    this.render();
  }

  render() {
    const entry = this.current;
    if (!entry) return;
    this.close();

    const body = el('div', { class: 'stage' });
    body.innerHTML = '<span class="muted">载入预览…</span>';
    const actions = el('div', { class: 'modal__head-actions' });

    const dialog = modal({
      title: entry.name,
      subtitle: `${entry.path} · ${entry.dir ? '文件夹' : fmtBytes(entry.size)} · ${fmtDate(entry.mtime)} · ${entry.mime}`,
      body,
      size: 'modal--wide',
      footer: true,
    });
    this.dialog = dialog;
    dialog.headActions.prepend(actions);

    const download = el('button', { class: 'btn btn--ghost btn--sm' });
    download.innerHTML = `${icon('download', 'i--sm')}下载`;
    download.addEventListener('click', () => this.app.transfers.download(entry));
    actions.append(download);

    const openRaw = el('button', { class: 'btn btn--ghost btn--sm' });
    openRaw.innerHTML = `${icon('external', 'i--sm')}新窗口`;
    openRaw.addEventListener('click', () => window.open(this.client.downloadUrl(entry.path, { inline: true }), '_blank', 'noopener'));
    actions.append(openRaw);

    const copyPath = el('button', { class: 'btn btn--ghost btn--sm' });
    copyPath.innerHTML = `${icon('link', 'i--sm')}路径`;
    copyPath.addEventListener('click', async () => {
      try { await navigator.clipboard.writeText(entry.path); toast('已复制路径', entry.path, 'ok', 2400); }
      catch { toast('复制失败', '浏览器拒绝了剪贴板访问', 'warn'); }
    });
    actions.append(copyPath);

    const prev = el('button', { class: 'btn btn--ghost' });
    prev.innerHTML = `${icon('arrow-left', 'i--sm')}上一个`;
    prev.disabled = this.list.length < 2;
    prev.addEventListener('click', () => this.navigate(-1));
    const next = el('button', { class: 'btn btn--ghost' });
    next.innerHTML = `下一个${icon('arrow-right', 'i--sm')}`;
    next.disabled = this.list.length < 2;
    next.addEventListener('click', () => this.navigate(1));
    const counter = el('span', { class: 'form-hint' }, this.list.length > 1 ? `${this.index + 1} / ${this.list.length}` : '');
    dialog.foot.append(prev, next, counter, el('div', { class: 'spacer' }));

    const keyHandler = (event) => {
      if (event.key === 'ArrowLeft') { event.preventDefault(); this.navigate(-1); }
      if (event.key === 'ArrowRight') { event.preventDefault(); this.navigate(1); }
    };
    document.addEventListener('keydown', keyHandler);
    const originalClose = dialog.close.bind(dialog);
    dialog.close = (result) => { document.removeEventListener('keydown', keyHandler); originalClose(result); };

    this.#renderBody(entry, body);
  }

  #renderBody(entry, stage) {
    const url = this.client.downloadUrl(entry.path, { inline: true });
    switch (entry.kind) {
      case 'image': {
        const img = el('img', { src: url, alt: entry.name, loading: 'eager' });
        img.addEventListener('load', () => stage.replaceChildren(img));
        img.addEventListener('error', () => { stage.innerHTML = `<span class="muted">无法在浏览器中显示该图像（格式可能不受支持）。</span>`; });
        img.addEventListener('click', () => img.classList.toggle('is-zoomed'));
        setTimeout(() => { if (stage.contains(img) === false && stage.querySelector('img') === null) stage.replaceChildren(img); }, 50);
        break;
      }
      case 'video':
        stage.replaceChildren(el('video', { src: url, controls: true, playsinline: true, preload: 'metadata' }));
        break;
      case 'audio':
        stage.replaceChildren(el('audio', { src: url, controls: true, preload: 'metadata' }));
        break;
      case 'document':
        if (extOf(entry.name) === 'pdf') stage.replaceChildren(el('iframe', { src: url, title: entry.name }));
        else stage.innerHTML = this.#unsupported(entry, '文档预览需要设备端转码，直接下载即可查看。');
        break;
      case 'code':
      case 'text':
        this.#renderText(entry, stage);
        break;
      default:
        this.#renderHex(entry, stage);
        break;
    }
  }

  async #renderText(entry, stage) {
    try {
      const data = await this.client.text(entry.path, { max: 262144 });
      if (data.binary) return void this.#renderHex(entry, stage, data.size);
      const pre = el('pre', { class: 'viewer-text' });
      pre.textContent = data.content || '';
      stage.replaceChildren(pre);
      if (data.truncated) stage.insertAdjacentHTML('beforeend', `<p class="form-hint" style="margin:10px 0 0">仅显示前 256 KB（文件 ${fmtBytes(data.size)}）。下载可看全文。</p>`);
    } catch (error) {
      if (error.isAuth) return this.app.handleAuthFailure();
      stage.innerHTML = `<span class="muted">读取失败：${esc(error.message)}</span>`;
    }
  }

  async #renderHex(entry, stage, knownSize = null) {
    try {
      const data = await this.client.hexdump(entry.path, { offset: 0, length: 8192 });
      const rows = (data.rows || []).map((row) => `<div><span class="off">${row.offset.toString(16).padStart(8, '0')}</span>  <span class="hex">${esc(row.hex.padEnd(47, ' '))}</span>  <span class="ascii">${esc(row.ascii)}</span></div>`).join('');
      stage.innerHTML = `<div style="width:100%">
        <p class="form-hint" style="margin:0 0 10px">二进制文件 · 共 ${esc(fmtBytes(knownSize ?? data.total))}，下面显示前 8 KB（十六进制）。</p>
        <div class="viewer-hex">${rows}</div>
        <p style="margin:12px 0 0"><button class="btn btn--ghost btn--sm" data-download>${icon('download', 'i--sm')}下载完整文件</button></p>
      </div>`;
      stage.querySelector('[data-download]')?.addEventListener('click', () => this.app.transfers.download(entry));
    } catch (error) {
      stage.innerHTML = this.#unsupported(entry, error.message);
    }
  }

  #unsupported(entry, note) {
    return `<div style="text-align:center">
      <p class="muted" style="margin:0 0 6px">${esc(note || '该类型无法内联预览。')}</p>
      <p class="form-hint">${esc(entry.mime)} · ${esc(parentPath(entry.path) || '')}</p>
    </div>`;
  }
}
