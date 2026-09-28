/**
 * FilzaRemote API v1 client — mirrors docs/API.md exactly.
 * No framework, no build step: the same bundle is served by the iOS app's
 * embedded server and can be hosted anywhere to drive another host.
 */

export class ApiError extends Error {
  constructor(status, code, message, payload) {
    super(message || code || `HTTP ${status}`);
    this.name = 'ApiError';
    this.status = status;
    this.code = code || 'http_error';
    this.payload = payload || null;
  }
  get isAuth() { return this.status === 401; }
  get isMissing() { return this.status === 404; }
}

const DEFAULT_CHUNK = 4 * 1024 * 1024;
const UPLOAD_RETRIES = 3;

export class FilzaClient {
  constructor({ baseUrl, token }) {
    this.baseUrl = String(baseUrl || '').replace(/\/+$/, '');
    this.token = token || '';
  }

  static fromLocation(hash = window.location.hash) {
    const base = window.location.origin;
    const params = new URLSearchParams(String(hash).replace(/^#/, ''));
    return { baseUrl: base, token: params.get('pair') || params.get('token') || '' };
  }

  /** Builds an absolute URL, appending the token unless `auth: false`. */
  url(path, params = {}, { auth = true, token = true } = {}) {
    const target = new URL(this.baseUrl + path);
    const supplied = new Set();
    for (const [key, value] of Object.entries(params)) {
      if (value === undefined || value === null || value === '') continue;
      if (Array.isArray(value)) {
        for (const item of value) target.searchParams.append(key, item);
        supplied.add(key);
      } else {
        target.searchParams.set(key, String(value));
        supplied.add(key);
      }
    }
    if (auth && token && this.token && !target.searchParams.has('token') && !supplied.has('token')) {
      target.searchParams.set('token', this.token);
    }
    return target.toString();
  }

  async request(path, { method = 'GET', params, body, json, headers = {}, raw = false, signal, auth = true } = {}) {
    const init = { method, headers: { ...headers }, signal };
    if (auth && this.token) init.headers['X-Filza-Token'] = this.token;
    if (json !== undefined) {
      init.headers['Content-Type'] = 'application/json; charset=utf-8';
      init.body = JSON.stringify(json);
    } else if (body !== undefined) {
      init.body = body;
    }
    let response;
    try {
      response = await fetch(this.url(path, params, { auth }), init);
    } catch (error) {
      if (error.name === 'AbortError') throw error;
      throw new ApiError(0, 'network_error', '无法连接到设备：' + (error.message || '网络错误'));
    }
    if (raw) {
      if (!response.ok) throw await this.#toError(response);
      return response;
    }
    const text = await response.text();
    let payload = null;
    if (text) { try { payload = JSON.parse(text); } catch { payload = null; } }
    if (!response.ok || (payload && payload.ok === false)) throw await this.#toError(response, payload);
    return payload ?? {};
  }

  async #toError(response, payload) {
    let data = payload;
    if (!data) {
      try { data = JSON.parse(await response.clone().text()); } catch { data = null; }
    }
    return new ApiError(response.status, data?.error, data?.message, data);
  }

  // ── read endpoints ────────────────────────────────────────────────────
  ping() { return this.request('/api/v1/ping', { auth: false }); }
  info() { return this.request('/api/v1/info'); }
  list(path, { showHidden = null } = {}) {
    const params = { path };
    if (showHidden !== null) params.showHidden = showHidden ? 1 : 0;
    return this.request('/api/v1/list', { params });
  }
  stat(path) { return this.request('/api/v1/stat', { params: { path } }); }
  search(path, term, { limit = 500, caseSensitive = false } = {}) {
    return this.request('/api/v1/search', { params: { path, q: term, limit, caseSensitive: caseSensitive ? 1 : 0 } });
  }
  text(path, { max = 262144, offset = 0 } = {}) {
    return this.request('/api/v1/text', { params: { path, max, offset } });
  }
  hexdump(path, { offset = 0, length = 8192 } = {}) {
    return this.request('/api/v1/hex', { params: { path, offset, length } });
  }
  clients() { return this.request('/api/v1/clients'); }
  settings(patch) { return this.request('/api/v1/settings', { method: 'POST', json: patch }); }
  rotateToken() { return this.request('/api/v1/token/rotate', { method: 'POST' }); }

  // ── mutations ─────────────────────────────────────────────────────────
  mkdir(path) { return this.request('/api/v1/mkdir', { method: 'POST', json: { path } }); }
  rename(from, to) { return this.request('/api/v1/rename', { method: 'POST', json: { from, to } }); }
  remove(paths) { return this.request('/api/v1/delete', { method: 'POST', json: { paths, recursive: true } }); }
  move(paths, dest, overwrite = false) {
    return this.request('/api/v1/move', { method: 'POST', json: { paths, dest, overwrite } });
  }
  copy(paths, dest, overwrite = false) {
    return this.request('/api/v1/copy', { method: 'POST', json: { paths, dest, overwrite } });
  }

  // ── binary URLs (token in query so <img>/<video> work) ────────────────
  downloadUrl(path, { inline = false } = {}) {
    return this.url('/api/v1/download', { path, inline: inline ? 1 : undefined });
  }
  thumbUrl(path, width = 256) {
    return this.url('/api/v1/thumb', { path, w: width });
  }
  zipUrl(paths) {
    return this.url('/api/v1/zip', { paths: Array.isArray(paths) ? paths : [paths] });
  }

  // ── live events (SSE) ─────────────────────────────────────────────────
  events(path, { onEvent, onOpen, onError } = {}) {
    let closed = false;
    let source = null;
    const open = () => {
      if (closed) return;
      source = new EventSource(this.url('/api/v1/events', { path }));
      source.onopen = () => onOpen?.();
      source.onmessage = (event) => {
        try { onEvent?.(JSON.parse(event.data)); } catch { /* ignore malformed frame */ }
      };
      source.onerror = () => {
        onError?.();
        if (closed) return;
        source.close();
        setTimeout(open, 3000); // the server watches one directory per stream
      };
    };
    open();
    return { close() { closed = true; try { source?.close(); } catch { /* ignore */ } } };
  }

  // ── resumable chunked upload ──────────────────────────────────────────
  /**
   * Streams a File to `dir` in chunks. Progress is reported per chunk; a
   * `409 offset_mismatch` resyncs from the server's authoritative offset, which
   * is what makes an interrupted upload recoverable (see docs/API.md §4.9).
   */
  upload(file, dir, { onProgress, signal, chunkSize = DEFAULT_CHUNK, overwrite = false, onResume } = {}) {
    let offset = 0;
    let attempt = 0;

    const sendTrack = (relative) => new Promise((resolve, reject) => {
      const end = Math.min(offset + chunkSize, file.size);
      const complete = end >= file.size;
      const xhr = new XMLHttpRequest();
      const target = this.url('/api/v1/upload', {
        path: dir,
        name: file.name,
        offset,
        complete: complete ? 1 : 0,
        overwrite: overwrite ? 1 : 0,
      });
      xhr.open('PUT', target, true);
      xhr.responseType = 'text';
      if (this.token) xhr.setRequestHeader('X-Filza-Token', this.token);
      xhr.setRequestHeader('X-Filza-Size', String(file.size));
      xhr.upload.onprogress = (event) => {
        if (event.lengthComputable) onProgress?.(offset + event.loaded, file.size);
      };
      xhr.onload = () => {
        let payload = null;
        try { payload = JSON.parse(xhr.responseText || '{}'); } catch { /* keep null */ }
        if (xhr.status === 200 && payload) {
          offset = Number.isFinite(payload.offset) ? payload.offset : end;
          relative.sent = offset;
          onProgress?.(offset, file.size);
          resolve({ complete: !!payload.complete, payload });
          return;
        }
        if (xhr.status === 409 && payload?.expectedOffset !== undefined) {
          offset = payload.expectedOffset; // authoritative resume point
          onResume?.(offset);
          resolve({ complete: false, payload, resync: true });
          return;
        }
        reject(new ApiError(xhr.status, payload?.error, payload?.message || `上传失败（HTTP ${xhr.status}）`, payload));
      };
      xhr.onerror = () => reject(new ApiError(0, 'network_error', '上传连接中断'));
      xhr.onabort = () => reject(new DOMException('aborted', 'AbortError'));
      signal?.addEventListener('abort', () => xhr.abort(), { once: true });
      xhr.send(file.slice(offset, end));
    });

    const track = { sent: 0, name: file.name, size: file.size, kind: 'upload' };

    const run = async () => {
      while (offset < file.size) {
        try {
          const result = await sendTrack(track);
          attempt = 0;
          if (result.complete) return { ...track, sent: file.size };
          if (result.resync) continue;
        } catch (error) {
          if (error.name === 'AbortError') throw error;
          attempt += 1;
          if (attempt > UPLOAD_RETRIES) throw error;
          await new Promise((resolve) => setTimeout(resolve, 400 * attempt));
        }
      }
      // zero-byte file: send an empty final chunk so the server commits it
      if (file.size === 0) {
        const result = await sendTrack(track);
        return { ...track, sent: 0, payload: result.payload };
      }
      return { ...track, sent: file.size };
    };

    return run();
  }

  /** Downloads with progress for reasonably sized files; returns a Blob. */
  async download(path, { onProgress, signal, maxBytes = 96 * 1024 * 1024 } = {}) {
    const response = await fetch(this.downloadUrl(path), { signal });
    if (!response.ok) throw await this.#toError(response);
    const total = Number(response.headers.get('content-length') || 0);
    if (!total || total <= maxBytes) {
      const blob = await response.blob();
      onProgress?.(blob.size, blob.size);
      return blob;
    }
    const reader = response.body.getReader();
    const chunks = [];
    let received = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(value);
      received += value.length;
      onProgress?.(received, total);
    }
    return new Blob(chunks);
  }
}

/** Triggers a browser download for a URL without buffering it in memory. */
export function saveUrl(url, filename) {
  const anchor = document.createElement('a');
  anchor.href = url;
  if (filename) anchor.download = filename;
  anchor.rel = 'noopener';
  document.body.appendChild(anchor);
  anchor.click();
  anchor.remove();
}

export function saveBlob(blob, filename) {
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement('a');
  anchor.href = url;
  anchor.download = filename;
  document.body.appendChild(anchor);
  anchor.click();
  anchor.remove();
  setTimeout(() => URL.revokeObjectURL(url), 20000);
}
