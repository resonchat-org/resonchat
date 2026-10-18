# ResonChat — 构建、测试与本地开发

## 工具链

| 组件 | 版本 | 说明 |
|---|---|---|
| Flutter | 3.47.5（stable） | `~/development/flutter` |
| Dart | 3.13.4 | 随 Flutter |
| JDK | 21 | `JAVA_HOME` 指向 system jdk 即可 |
| Android SDK | platform 35 + build-tools 35.0.0 | `~/Android/Sdk` |
| Android NDK | 随 Flutter | `libsignal` 插件构建需要 |

环境变量：

```bash
export PATH="$HOME/development/flutter/bin:$HOME/Android/Sdk/cmdline-tools/latest/bin:$HOME/Android/Sdk/platform-tools:$PATH"
export ANDROID_HOME="$HOME/Android/Sdk"
```

## 仓库结构

```
resonchat/
├─ docs/                     设计文档集
├─ scripts/                  CI/打包包装层
├─ app/                      Flutter 应用
│  ├─ lib/
│  │  ├─ account/            多账号枢纽
│  │  ├─ crypto/             加密：PQXDH / 指纹；omemo/ 双轨；pq/ ML-KEM
│  │  ├─ store/              drift + 备份格式 + 平台 DB 连接
│  │  ├─ state/              跨 feature Riverpod 读模型
│  │  ├─ ui/                 feature 页面 + 主题/壳层小组件
│  │  ├─ utils/              外观编解码、emoji 目录等非 UI 数据
│  │  └─ xmpp/               连接生命周期与事件分发
│  ├─ test/                  按关注点：crypto / rooms / store / messages / session / ui
│  └─ tool/                  Flutter 构建前置（web assets 等）+ Dart 探针
└─ vendor/                 上游 fork（git 子模块，path 依赖）
   ├─ moxxmpp/packages/moxxmpp
   ├─ moxxmpp/packages/moxxmpp_socket_tcp
   ├─ omemo_dart
   └─ moxlib
```

去掉 `scripts/` 后在 `app/` 内仍可：

```bash
flutter build apk
./tool/prepare_web_assets.sh && flutter build web --wasm
```

### fork 说明

三个上游库均为 fork 并保留原 license（子模块远程见 `.gitmodules`）：

| 包 | 上游 | 许可证 | 本地改动 |
|---|---|---|---|
| `moxxmpp` | codeberg.org/moxxy/moxxmpp | MIT | 移除私有 registry；Dart 3；并入 MAM；RFC 7395 / XEP-0156 |
| `omemo_dart` | github.com/PapaTutuWawa/omemo_dart | MIT | 移除私有 registry；axolotl 路径 |
| `moxlib` | codeberg.org/moxxy/moxlib | **GPL-3.0** | SDK 约束提升到 Dart 3 |

## Architecture: MVVM + Riverpod

贴近 Flutter 官方 MVVM（View + ViewModel），目录按 feature 组织：

| 层 | 本仓库落点 | 职责 |
|---|---|---|
| **View** | `ui/<feature>/*_page.dart` 等 | 渲染、滚动、对话框；不写协议/DB |
| **ViewModel** | 同目录 `*_viewmodel.dart`（Riverpod `Notifier`，按需） | UI 状态与命令 |
| **读模型** | `state/providers.dart` | 跨页面 Stream/Future providers |
| **Data** | `account/`、`store/`、`xmpp/`、`crypto/` | 经 `AccountHub` / `resolveChatKey` / providers 访问 |

```
ui/
  theme.dart, design_tokens.dart   主题 / tokens
  contact_avatar.dart              跨 feature 小组件
  column_mode*.dart, …             宽屏双栏壳层
  chat/  chats/  login/  settings/  room/  …
utils/
  appearance.dart                  会话外观编解码与壁纸绘制
  emoji_data.dart                  emoji 目录（纯数据）
```

类名：`ChatViewModel` + `ChatPage`。有状态/命令的 feature 才加 ViewModel；View 只绑回调与导航。非 UI 的数据/设置类放 `utils/`。

## 常用命令

```bash
# 应用侧（在 app/ 下）
cd app
flutter pub get
dart run build_runner build          # 生成 drift 代码（database.g.dart）
dart analyze lib test                # flutter analyze 在本机会崩，改用 dart analyze
flutter test                         # test/{crypto,rooms,store,messages,session,ui}/

# Flutter 构建前置（在 app/ 下，不依赖 scripts/）
./tool/prepare_web_assets.sh            # → web/sqlite3.wasm + drift_worker.js（仅 web）

# CI / 打包包装（在仓库根目录）
./scripts/build_android.sh           # mipmap + flutter build apk
./scripts/build_web.sh               # tool/prepare_web_assets + flutter build web --wasm
./scripts/build_appimage.sh          # Linux AppImage（需 GTK 3 等桌面依赖）
.\scripts\build_windows.ps1          # Windows Inno Setup（需 VS C++ + Inno Setup 6）
```

### 发布（CD）

GitHub 上 **Publish a release**（或 `gh release create vX.Y.Z`）会触发
`.github/workflows/cd.yml`：打两份 release APK（arm64 / x86_64）+ x86_64
AppImage / .deb / .rpm + Windows setup + Web（`--wasm`）tar.gz，并挂到该
Release 的 Assets。产物名形如
`resonchat-<tag>-arm64.apk` /
`resonchat-<tag>-x86_64.apk` /
`resonchat-<tag>-x86_64.AppImage` /
`resonchat-<tag>-x86_64.deb` /
`resonchat-<tag>-x86_64.rpm` /
`resonchat-<tag>-x86_64-setup.exe` /
`resonchat-<tag>-wasm.tar.gz`。

本地单 ABI：`./scripts/build_android.sh --release --abi arm` 或 `--abi x86`。

> 当前 release APK 仍用 debug 签名（`android/app/build.gradle.kts`）；上架
> 商店前需换成正式 keystore。

### opencode 自动化

仓库接了三个 opencode 工作流（认证走 OpenCode GitHub App + OIDC，模型由
runner 内本地 `commandcode-proxy` 经 `opencode.json` 的 `ccproxy` provider 提供；
均要求触发者是组织成员）：

| 工作流 | 触发 | 作用 |
|---|---|---|
| `.github/workflows/opencode.yml` | issue / PR 评论里包含 `/oc` 或 `/opencode` | 在该评论下按指令执行任务（回复、建分支、提 PR） |
| `.github/workflows/opencode-triage.yml` | 新 issue（`opened`） | 自动分类、补充文档链接与处理建议 |
| `.github/workflows/opencode-solve.yml` | issue 带上 `opencode` 标签 | 自动实现修复，跑 `dart analyze` / `flutter test` 后提 PR 并引用该 issue |

### 应用图标

单一源：`assets/icons/`。web / Linux 窗口直接读该目录；AppImage 打包时生成
hicolor；Windows 用 `app_icon.ico`（`Runner.rc` / Inno Setup）。Android mipmap 在
`./scripts/build_android.sh` 里从 `app_icon.png` 生成。

### Web 存储

同一套 Drift `AppDatabase`（表结构与查询）在两端复用：

| 平台 | 连接 | 物理存储 |
|---|---|---|
| 原生 | `database_connection_io.dart` → SQLCipher / SQLite 文件 | 本地文件 |
| Web | `database_connection_web.dart` → `WasmDatabase.open` | OPFS，否则 IndexedDB |

条件导入入口：`lib/store/database_connection.dart`（与 matrix-dart-sdk 的 box 切换同思路）。

`sqlite3.wasm` / `drift_worker.js` **不进仓库**，由 `./scripts/build_web.sh` 按
`pubspec.lock` 拉取。本地 `flutter run -d chrome` 前可先
`./scripts/build_web.sh --prepare-only`。

XMPP 传输同样条件导入（`lib/xmpp/xmpp_socket.dart`）：

| 平台 | 实现 |
|---|---|
| 原生 | TCP + SOCKS5（`moxxmpp_socket_tcp`） |
| Web | `moxxmpp` RFC 7395 WebSocket + XEP-0156 host-meta |

RFC 7395 framing / `WebSocketXmppSocket` 与 XEP-0156 在 `vendor/moxxmpp`（`rfcs/rfc_7395`、`xeps/xep_0156`），主库只做平台工厂。
登录页「主机」可填 `wss://…` 覆盖自动发现；SOCKS5 UI 在 web 上隐藏。

## 当前实现状态

验证：`dart analyze lib test tool integration_test` 无告警 · `flutter test` 通过 ·
`./scripts/build_android.sh` 成功 · 设备端 `native_pq_test`（pqcrypto）通过 ·
与真实 Conversations 的互通验收通过（两次运行，见 `app/tool/m2_verify_conversations.sh`）。

### 已踩过的坑（避免重蹈）

| 坑 | 现象 | 正确做法 |
|---|---|---|
| `cryptography` 的 `SecretBox.concatenation()` | 返回「密文 **+ 零填充**」，不是线格式 | 用 `cipherText` 再显式拼 tag；解密用 `SecretBox.fromConcatenation` |
| moxxmpp `OmemoManager.publishBundle` | 返回的 bool 是 `isType<PubSubError>()`，**true 表示失败** | 与 `PubSubManager.publish` 语义相反，别混用 |
| SASL 机制 | 只注册 SCRAM-SHA-256 时，对端只提供 PLAIN/SHA-1 就完全登不上 | 按强度降级注册：sha256→sha512→sha1→PLAIN |
| `OMEMOAuthenticatedMessage` | 不能手工拼 `message`+`mac` | 必须用 `writeToBuffer()` / `fromBuffer()` |
| Double Ratchet 关联数据 | `IK_发起方 ‖ IK_接收方` 顺序反了不会报错，只是每条消息都解密失败 | 两侧顺序必须一致 |
| ratchet 存储 key | 同一 ratchet 挂两个 key 会状态污染 | 每个远端设备只存一份，以 (对端jid, 对端id) 为 key |
| `calloc.asTypedList()` | 返回的视图在 `free` 后仍被使用（use-after-free，不崩只静默出错） | 先 `Uint8List.fromList` 复制再释放 |
| C 符号导出 | `-fvisibility=hidden` 下 `.so` 能加载但符号全找不到 | 导出函数加 `__attribute__((visibility("default")))` |
| adb 输入法 | 中文 TTS IME 会吞掉 `@` 和 `.`，把 `xmpprev@jabber.fr` 变成「下面品牌Rev@就ABB而.」 | `adb shell ime disable` 禁用全部输入法后 `input text` 原样注入 |
| XEP-0384 线格式 | 规范节点名 `urn:xmpp:omemo:2:*` 没有任何客户端实现；真实世界是 `eu.siacs.conversations.axolotl.*` | 出入站都同时支持两种方言（`lib/crypto/omemo/defacto.dart`） |
| Signal 公钥序列化 | 公钥是「1 字节类型前缀 0x05 + 32 字节密钥」= 33 字节；omemo_dart 用裸 32 字节 | 读时剥前缀、写时加前缀（`stripKeyTypeByte`/`addKeyTypeByte`） |
| PubSub item id | 真实客户端把 bundle 挂在 `current` 上，moxxmpp 用设备号 | 取整节点，谁的 item 能解析就用谁 |
| `ShouldEncrypt` 回调 | moxxmpp 对**每个**出站 stanza 都问一次「要不要加密」 | 只对 `message` 回答；否则能力解析会为每个 PubSub IQ 再发 IQ，形成无界级联把登录饿死 |
| RFC 6121 版本控制 | 服务器无变更时回不含 `<query/>` 的 `<iq/>`，moxxmpp 转成**空**增量 | 联系人列表必须从本地缓存读，不能直接用 IQ 返回值 |

| 里程碑 | 状态 | 要点 |
|---|---|---|
| M0 工程骨架 | 已完成 | 应用/包结构、fork 接线、CI、分析与测试全绿、Android debug APK 可构建 |
| M1 通信基线 | 已完成 | 连接/SASL SCRAM-SHA-256、资源绑定、roster（drift 持久化 + RFC 6121 版本）、明文收发、XEP-0184 回执、XEP-0085 输入状态、XEP-0280 Carbons、**XEP-0313 MAM**（已从上游 `feat/mam` 并入）、drift 消息存储、最小 UI。剩余验证项：与真实服务端/客户端的双账号互发 |
| M2 标准 OMEMO | 已完成 | **与真实 Conversations 2.20.4 互通验收通过**：我们加密的消息被第三方客户端解密并显示（唯一标记 + 抓第三方 view hierarchy 自动判定，见 `app/tool/m2_verify_conversations.sh`）。为此修掉 3 处「按规范实现但真实世界不认」的互不兼容：PEP 节点名、bundle 元素名、Signal 公钥类型字节 |
| M3 PQ 内核 | 已完成 | PQXDH 到 Double Ratchet 接线完成；ML-KEM 走纯 Dart `pqcrypto`；**双账号跨服务器真实互测通过**（conversations.im 与 jabber.fr，10/10 检查）；PQ bundle 已真实发布到服务器 |
| M4 协商与发送策略 | 已完成 | `decideEncMode` / `CapabilityService` 给出最高可达轨道；发送由用户 Track + `TrackResolver` 判定（见 docs/10）。PEP 变更订阅：四个节点（两种方言 × 两轨）任一变化即失效缓存 |
| M5 存储与保护 | 已完成 | OMEMO 设备密钥经 Keystore 封存落库；数据库用 SQLCipher 加密（口令在 Keystore，验收测试直接搜原始文件证明明文不外泄）。**密钥备份/恢复、「不保存明文」选项仍未做** |
| M6 UI | 进行中 | 已按 docs/05 重做：TG 色板（真实采样自 ThemeColors.java）、CustomPainter 气泡带尾角、日期分隔、未读线、会话列表两行布局、滚动到底 FAB、输入栏（空输入变麦克风）。动画、平板适配、资料页未做 |
| M7 发布 | 未开始 | — |

## 关键待办（下一步优先级）

1. **反向互通（Conversations 到本客户端）**：A 轨已改为完整 OMEMO 0.3.0/axolotl
   （`omemo_dart_axolotl` + `eu.siacs.conversations.axolotl` 消息路径）。出站曾通过
   M2 验收；入站需两台真实设备补齐（conversations.im 非双向订阅会拒投递）。
2. **密钥备份与恢复**：设备密钥目前只在本机 Keystore，换机即全部会话失效。
3. **「不保存明文」选项**与消息删除：目前消息一律落库（虽已加密）。
4. **UI 打磨**：见 docs/05，动画、平板适配、资料页未做。
5. **iOS**：尚未做。

## 已完成的验证工具

| 工具 | 用途 |
|---|---|
| `scripts/smoke_test.sh <jid> <pass>` | 无人值守登录冒烟（`--dart-define` 注入凭据，仅 debug 生效） |
| `app/tool/m2_verify_conversations.sh <jid> <pass> <peer>` | **M2 验收**：发一条带唯一标记的加密消息，再抓第三方客户端的界面确认它解出来了 |
| `app/tool/send_text.dart <jid> <pass> <peer> <text>` | 绕开本客户端的明文发送工具，用来判定「服务器不路由」还是「客户端处理错」 |
| `app/tool/peek_pep.dart <jid> <pass> <peer>` | 直读对端 PEP 节点与自身 roster，并打印服务器原始 IQ 回复 |
| `integration_test/a_track_interop_test.dart` | 两个独立客户端实例跨服务器交换真实 OMEMO 消息（可复现回归） |
| `integration_test/m2_interop_test.dart` | 与真实客户端的能力协商全流程：读它的 bundle、判定轨道、发消息、等入站 |
| `app/tool/interop_probe.dart <jid> <pass> [peer]` | A 轨 bundle 线格式与 PEP 发布校验 |
| `app/tool/pq_interop.dart <jidA> <passA> <jidB> <passB>` | **B 轨双账号真实互测**：PQ 加解密 + PEP 能力发现 |
| `app/tool/prepare_web_assets.sh` | 拉取 Drift `sqlite3.wasm` / `drift_worker.js`（web 构建前置） |
| `app/tool/previews/` | 把 UI 渲染成 PNG 供设计评审 |
| `integration_test/native_pq_test.dart` | 设备上确认纯 Dart `pqcrypto` ML-KEM 可用 |
<!-- ci doc-only skip test -->
