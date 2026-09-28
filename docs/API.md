# FilzaRemote — HTTP API v1（冻结契约）

> 本文件是三份实现共同遵守的**唯一契约**：
> 1. `ios/Sources/FilzaCore` — Swift 跨平台服务器内核（iOS App 内嵌，**同一份代码在 Windows 上真编译真运行**）
> 2. `host/server.mjs` — 桌面参考宿主（Node，可独立当远程文件服务器用）
> 3. `web/` — Web 远程文件查看控制台（浏览器端，既由 App 自己托管，也可指向任意宿主）
>
> 任何一端改动都必须同步本文件；`docs/API.md` 是 review 的基准。

---

## 1. 基础

| 项 | 值 |
|---|---|
| 协议 | HTTP/1.1（明文，仅限局域网；App 侧可开「仅 Wi-Fi」） |
| 前缀 | `/api/v1` |
| 默认端口 | `8787` |
| 编码 | JSON 一律 `application/json; charset=utf-8`；文件名走 RFC 5987 `filename*=UTF-8''…` |
| CORS | 所有 `/api/v1` 响应带 `Access-Control-Allow-Origin: *`，允许头 `X-Filza-Token, Content-Type, X-Filza-Size, X-Filza-Complete`，方法 `GET,POST,PUT,DELETE,OPTIONS`，暴露 `Content-Range, Content-Length, Content-Disposition` |
| 静态资源 | `/`、`/index.html`、`/css/*`、`/js/*`、`/assets/*` **不需要 token**（只是 UI 文件）；`/api/v1/*` 一律需要 |

## 2. 认证

配对 token：≥128 bit 随机（App 用 `SecRandomCopyBytes`，宿主用 `crypto.randomBytes`），
展示形态 `XXXX-XXXX-XXXX-XXXX-XXXX`，App 仪表盘明文展示 + 二维码。

接受三种携带方式（任一）：
```
X-Filza-Token: <token>
Authorization: Bearer <token>
?token=<token>          # 供 <img>/<video>/下载链接使用
```
比对必须**常量时间**（长度不等直接 false）。失败：
```http
HTTP/1.1 401 Unauthorized
{"ok":false,"error":"unauthorized","message":"missing or invalid pairing token"}
```
`GET /api/v1/ping` 与所有静态资源**不需要**认证，且不得泄露 token 或文件内容。

## 3. 虚拟路径（关键设计）

物理路径永不出现在协议里。每个服务器声明若干 **root**，虚拟路径形如
`/<RootName>/相对/路径`（正斜杠，`..` 与 `.` 段一律拒绝）。

* iOS：`/App`（App 容器 `Documents/`）、`/OnMyiPhone-<名>`（用户通过 `UIDocumentPicker` 授权的文件夹，安全书签持久化）、`/Photos`（照片图库虚拟根）
* 宿主：`/Demo`、`/Workspace`、`/Home`

**安全不变量（每个实现都必须满足）**
1. 解析后 `canonicalPath` 必须等于 root 的 canonical 路径或以 `root + "/"` 开头，否则 `403 outside_root`。
2. `list/download/stat/...` 均先做第 1 步校验，再做任何 I/O。
3. `.filzapart` 分片临时文件**不可**通过 `download` 下载、`list` 可隐藏、`delete` 可清理。
4. 删除/移动/重命名拒绝作用于 root 自身。
5. 每 IP 限速（默认 600 req / 10 s → `429 rate_limited`），最大并发连接 24～64。

## 4. 端点

### 4.1 `GET /api/v1/ping`
```json
{"ok":true,"serverTime":1712345678000}
```
无认证，用于可达性探测与延迟显示。

### 4.2 `GET /api/v1/info`
```json
{
  "ok": true, "app": "FilzaRemote", "version": "1.0.0",
  "serverTime": 1712345678000, "uptimeMs": 84213,
  "device": {"model":"iPhone 15 Pro","manufacturer":"Apple","android":"iOS 17.5 (21F79)","sdkInt":0},
  "host": "192.168.1.20", "port": 8787, "tokenRequired": true,
  "roots": [{"name":"App","path":"/App","label":"FilzaRemote 容器","readable":true,"writable":true}],
  "storage": {"totalBytes": 255000000000, "freeBytes": 41000000000, "usedBytes": 214000000000},
  "features": ["list","stat","mkdir","rename","delete","move","copy","search","download","zip","upload","upload-chunked","thumb","text","hex","events","clients","settings","token-rotate"],
  "writesEnabled": true, "deletesEnabled": true,
  "hostKind": "ios-app"
}
```
`hostKind` ∈ `ios-app | android-app | desktop-reference`（前端据此提示能力差异）。

### 4.3 `GET /api/v1/list?path=/App/Documents&showHidden=0`
```json
{
  "ok": true, "path": "/App/Documents", "parent": "/App", "root": "App",
  "entries": [{
    "name": "IMG_0001.HEIC", "path": "/App/Documents/IMG_0001.HEIC",
    "dir": false, "size": 2841993, "mtime": 1712345678000,
    "ext": "heic", "kind": "image", "mime": "image/heic",
    "hidden": false, "readable": true, "writable": true, "symlink": false
  }],
  "count": 1, "truncated": false
}
```
* 排序：目录优先，其后按名称不区分大小写升序。
* `kind` ∈ `folder|image|video|audio|archive|document|code|text|apk|disk|other`。
* 上限 5000 条，超出 `truncated: true`。
* `parent` 在 root 层为 `null`（禁止越权 `..`）。

### 4.4 `GET /api/v1/stat?path=…`
返回单个 entry 对象 + `"ok":true`；不存在 → `404 not_found`。

### 4.5 变更类（全部 `POST`，均需 `writesEnabled`）
| 端点 | 请求体 | 成功响应 |
|---|---|---|
| `/mkdir` | `{"path":"/App/New"}` | `{"ok":true,"path":"/App/New"}`（已存在 → 409 `conflict`） |
| `/rename` | `{"from":"…","to":"…"}` | `{"ok":true,"path":"<新路径>"}` |
| `/delete` | `{"paths":["…"],"recursive":true}` | `{"ok":true,"deleted":["…"],"failed":[{"path":"…","error":"…"}]}` |
| `/move` | `{"paths":["…"],"dest":"/App/Target","overwrite":false}` | `{"ok":true,"moved":["…"],"failed":[…]}` |
| `/copy` | 同 move | `{"ok":true,"copied":["…"],"failed":[…]}` |

`deletesEnabled=false` → `403 {"ok":false,"error":"forbidden","message":"deletes_disabled"}`。
部分失败仍返回 `200`，逐项写在 `failed[]`（前端据此逐个报错）。

### 4.6 搜索 `GET /api/v1/search?path=/App&q=term&limit=500&caseSensitive=0`
```json
{"ok":true,"results":[<entry>…],"scanned":1234,"limitReached":false,"tookMs":42}
```
BFS，最大深度 24，跳过不可读目录与点文件，命中 `limit` 即停。**服务端**搜索（不是前端过滤），因为手机目录可能很大。

### 4.7 下载与打包
* `GET /api/v1/download?path=<file>`
  正确 `Content-Type`（未知 → `application/octet-stream`）、`Content-Disposition: attachment; filename*=UTF-8''…`、`Accept-Ranges: bytes`、**完整 Range 支持**（206 + `Content-Range`，非法区间 416）。`text/*`、`image/*` 允许 inline 以便预览。
* `GET /api/v1/zip?path=/App/Dir` 或 `?paths=a&paths=b`（重复参数）
  流式 `application/zip`，边生成边写 socket，**不得全量缓存**；上限 20000 条；长文件名 ≥ 4 GB 需 ZIP64 或截断（当前实现上限 4 GB/条）。

### 4.8 预览辅助
| 端点 | 说明 |
|---|---|
| `GET /thumb?path=<image>&w=256` | 图像缩略图（iOS: `CGImageSourceCreateThumbnailAtIndex` 并按 EXIF 转正；宿主/Windows: 原图透传，浏览器缩放）。非图像 → `415 unsupported_media`；`w` 上限 1024 |
| `GET /text?path=&max=262144&offset=0` | `{"ok":true,"path":…,"size":n,"offset":n,"truncated":bool,"encoding":"utf-8","binary":false,"content":"…"}`；含 NUL 判定二进制则 `binary:true,"content":null` |
| `GET /hex?path=&offset=0&length=4096` | `{"ok":true,"path":…,"offset":n,"length":n,"total":n,"rows":[{"offset":n,"hex":"4d 5a …","ascii":"MZ……"}]}`，单次上限 1 MiB |

### 4.9 上传
两种形态，**同一路径**：

**A. 原始可续传（Web 控制台使用）**
```http
PUT /api/v1/upload?path=/App/Downloads&name=big.mov&offset=0&complete=0
X-Filza-Size: 1073741824
X-Filza-Complete: 0            # 与 ?complete=1 等价

<二进制分片>
```
* 写入 `<目标>.filzapart`；`offset` 必须等于 `.part` 当前大小，否则
  `409 {"ok":false,"error":"conflict","message":"offset_mismatch","expectedOffset":N}`（客户端据此续传）。
* 分片大小建议 4 MiB；最后一片带 `complete=1`（或 `.part` 大小达到 `X-Filza-Size`）→ 原子 `rename` 到最终名。
* 已存在且 `?overwrite` 非 `1` → `409 exists`。
* 响应：`{"ok":true,"path":…,"size":n,"offset":n,"complete":true|false}`

**B. `multipart/form-data`（`curl -F` 等通用客户端）**
`POST /api/v1/upload?path=/App/Downloads`，字段名任意、读 `filename`（含 `filename*`），流式解析。响应同 A。

### 4.10 实时事件（SSE）
`GET /api/v1/events?path=/App/Documents`
```
Content-Type: text/event-stream; Cache-Control: no-cache; Connection: keep-alive

: connected

data: {"type":"fs","op":"create","path":"/App/Documents/new.txt","name":"new.txt"}

: hb
```
* **一个 SSE 流只监听一个目录**（iOS 用 `DispatchSource` 监听目录，宿主用 `fs.watch`）；客户端切换目录时重连（Client 端统一处理）。
* 心跳 `: hb` 每 15 s。
* 客户端断开必须释放监听资源（`finally`）。
* 事件类型 `type:"fs"`，`op` ∈ `create|delete|move|modify|attrib`。

### 4.11 管理
* `GET /api/v1/clients` → `{"ok":true,"clients":[{"remote":"192.168.1.5","userAgent":"…","firstSeen":n,"lastSeen":n,"requests":n}],"log":[{"id":"ab12cd34","time":n,"method":"GET","path":"/api/v1/list?…","status":200,"ms":3,"remote":"…","userAgent":"…"}],"connections":1}`（日志环形缓冲 ≤ 500 条）
* `POST /api/v1/settings` → `{"writesEnabled":bool?,"deletesEnabled":bool?,"showHidden":bool?,"port":int?}` → `{"ok":true,"settings":{…}}`；改端口需重启监听
* `POST /api/v1/token/rotate` → `{"ok":true,"token":"<新 token>"}`

## 5. 错误码表

| HTTP | `error` | 触发 |
|---|---|---|
| 400 | `bad_request` | 参数缺失/非法、`invalid JSON body` |
| 401 | `unauthorized` | token 缺失或错误 |
| 403 | `forbidden` | `outside_root`、`writes_disabled`、`deletes_disabled`、拒绝删除 root |
| 404 | `not_found` | 路径/端点不存在、`unknown_root` |
| 405 | `method_not_allowed` | 方法不匹配 |
| 409 | `conflict` | `exists`、`offset_mismatch` |
| 413 | `too_large` | 请求体超限 |
| 415 | `unsupported_media` | `/thumb` 拿到非图像 |
| 429 | `rate_limited` | 触发限速 |
| 500 | `internal` | 未预期异常（绝不崩线程，仅记日志） |
| 503 | `unavailable` | 并发连接超限 |

统一错误体：`{"ok":false,"error":"<code>","message":"<人话>"}`（`offset_mismatch` 额外带 `expectedOffset`）。

## 6. 平台差异（前端应按 `hostKind` / `features` 降级）

| 能力 | iOS App | Android App（附赠） | 桌面宿主 |
|---|---|---|---|
| 根目录 | `/App`、授权文件夹、`/Photos` | `/Internal`、`/SDCard`、`/App` | `/Demo`、`/Workspace`、`/Home` |
| 缩略图 | ImageIO 真实缩略 + EXIF 转正 | `BitmapFactory` + ExifInterface | 原图透传 |
| 后台存活 | 前台有效；可选「静音音频保活」开关（侧载场景），App Store 审核不允许 | 前台服务常驻 | 常驻 |
| 删除语义 | 进废纸篓（可选）或直接删 | 直接删 | 直接删 |
| 视频转码 | 无（原样流式播放） | 同 | 同 |

## 7. 前端必须处理的边界

1. `truncated:true` → 提示「仅显示前 5000 项」。
2. `429/503` → 指数退避重试 + 明确提示。
3. token 失效（401）→ 回到配对页，清除本地 token，不静默失败。
4. SSE 断线 → 3 s 退避重连，同时保留 20 s 兜底轮询。
5. 上传：`path` 中文件名由 `name` 参数单独给出，**不得**把用户文件名拼进 URL 路径段（避免编码/穿越歧义）。
6. 大目录渲染必须分批（每批 200 行），避免手机端浏览器卡死。
