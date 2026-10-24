# ResonChat

[![CI](https://github.com/resonchat-org/resonchat/actions/workflows/ci.yml/badge.svg)](https://github.com/resonchat-org/resonchat/actions/workflows/ci.yml)

[English](README.md) | 中文

一个基于 Flutter 的 XMPP 客户端：在**不修改服务端、不引入新 XEP** 的前提下，实现与 OMEMO 同构的**后量子加密**（X25519 + ML-KEM-1024），同时**保持与标准 OMEMO 客户端互通**；UI 为自有设计，输入栏等局部组件移植自 Telegram Android。Android 优先。

> [!CAUTION]
> **请勿登录带有反 spam 功能的服务器（例如 conversations.im）。** 本应用仍处于开发阶段，目前会被部分此类服务器**误判为 spam**，原因**尚未解决**；登录可能导致账号被**封禁**。

## 开发者预览

ResonChat 处于早期阶段，正在快速迭代。**M0–M5 已完成，M6 进行中，M7 未开始。未来将出现破坏兼容性的变更。**

加密协议为自定义的 OMEMO 后量子扩展，**尚未经过第三方安全审计**。在完成独立审计之前，请勿用于高敏感场景，也不应对外宣称其安全性。

## 安装

Android 构建产物挂在 [GitHub Releases](https://github.com/resonchat-org/resonchat/releases) 页面。[Obtainium](https://github.com/ImranR98/Obtainium) 可以直接从那里安装，并自动跟进更新：

[![Get it on Obtainium](https://img.shields.io/badge/Get_it_on-Obtainium-3DDC84?logo=android&logoColor=white)](https://apps.obtainium.imranr.dev/redirect?r=obtainium://app/%7B%22id%22%3A%22org.resonchat.resonchat%22%2C%22url%22%3A%22https%3A%2F%2Fgithub.com%2Fresonchat-org%2Fresonchat%22%2C%22author%22%3A%22resonchat-org%22%2C%22name%22%3A%22ResonChat%22%2C%22additionalSettings%22%3A%22%7B%5C%22includePrereleases%5C%22%3Atrue%2C%5C%22fallbackToOlderReleases%5C%22%3Atrue%2C%5C%22autoApkFilterByArch%5C%22%3Atrue%7D%22%7D)

该链接自带完整配置，不涉及任何应用市场收录：添加后跟随**最新发布（含预发布）**，即下方的开发者预览版，并由 Obtainium 自动挑选适配设备的 `arm64` / `x86_64` APK。

<details>
<summary>链接内置的配置，以及手动添加方式</summary>

```json
{"id":"org.resonchat.resonchat","url":"https://github.com/resonchat-org/resonchat","author":"resonchat-org","name":"ResonChat","additionalSettings":"{\"includePrereleases\":true,\"fallbackToOlderReleases\":true,\"autoApkFilterByArch\":true}"}
```

在 Obtainium 中手动添加源 `https://github.com/resonchat-org/resonchat`，并打开 **含预发布（Include pre-releases）** 与 **按架构自动选择（Auto-select by architecture）**，效果相同。

</details>

目前所有发布均为**开发者预览版**，且使用 debug 密钥签名。若本机已安装自行构建的 APK，请先卸载 —— 两者包名相同（`org.resonchat.resonchat`）但签名密钥不同，Android 会拒绝覆盖安装。

## 特性

| 特性 | 状态 | 说明 |
|---|---|---|
| 双轨端到端加密（A 轨） | 已完成 | 标准 OMEMO（XEP-0384），与 Conversations / Moxxy / Dino 等互通。已与真实 Conversations 2.20.4 完成互通验收 |
| 双轨端到端加密（B 轨） | 已完成 | PQ-OMEMO（X25519 + ML-KEM-1024 混合，PQXDH + SPQR）；用户选定 O2 且对端设备可达时发送。已双账号跨服务器互测通过 |
| 三轨选择（O2 / OM / NO） | 已完成 | 用户选定 + `TrackResolver` 判定可行性（见 [docs/10](docs/10-track-selection.md)） |
| 零服务端改动 / 零新 XEP | 已完成 | 复用 PEP、EME 等既有标准 |
| 数据库落盘加密 | 已完成 | SQLCipher，口令由 Android Keystore 保护 |
| 标准协议扩展 | 已完成 | MAM（XEP-0313）历史同步、回执（XEP-0184）、输入状态（XEP-0085）、Carbons（XEP-0280） |
| 平台支持 | 部分完成 | Android（arm64-v8a / x86_64，`pqcrypto` + native `libsignal`）；Web（Dart→Wasm + Drift WASM + WebSocket）；Linux AppImage / deb / rpm；Windows 安装包；iOS 未做 |
| UI | 进行中 | 自有气泡、色板与列表布局；输入栏移植自 Telegram Android。动画、平板适配未做 |

## 状态

**M0–M5 已完成，M6 进行中，M7 未开始。**

| 里程碑 | 状态 | 要点 |
|---|---|---|
| M0 工程骨架 | 已完成 | mono-repo 骨架、上游 fork 接线、CI、drift 存储、PQXDH 与双轨编解码、Android debug APK 可构建 |
| M1 通信基线 | 已完成 | SASL SCRAM-SHA-256、资源绑定、roster（RFC 6121 版本控制）、明文收发、MAM 历史同步、Carbons、消息存储 |
| M2 标准 OMEMO | 已完成 | **与真实 Conversations 2.20.4 互通验收通过**（我们加密的消息被第三方客户端解密并显示） |
| M3 PQ 内核 | 已完成 | ML-KEM / PQXDH / SPQR 走 native `libsignal`；纯 Dart `pqcrypto` 用于 ML-DSA-87 与 SHA3-512；**双账号跨服务器互测通过**（conversations.im 与 jabber.fr）；PQ bundle 已真实发布到服务器 |
| M4 协商与发送策略 | 已完成 | 能力服务 + 用户 Track / `TrackResolver`（docs/10）；PEP 变更失效缓存 |
| M5 存储与保护 | 已完成 | OMEMO 设备密钥经 Keystore 封存落库；数据库 SQLCipher 加密；聊天历史备份格式已有。**密钥备份/恢复与「不保存明文」选项未做** |
| M6 UI | 进行中 | 按 [docs/05](docs/05-ui.md) |
| M7 发布 | 未开始 | — |

每次 push 都会跑 CI：`dart analyze` 与完整的 `flutter test`，并在同一次任务里编译 Linux 和 Web，只确认能编过。

**已知限制与未完成项**（完整清单见 [`README.dev.md`](README.dev.md)）：

- 反向互通（Conversations 到本客户端）尚未验证 —— 验收环境对非双向订阅拒绝投递，需两台真实设备补齐
- 设备密钥仅存本机 Keystore，**换机即全部会话失效**（无备份与恢复）
- iOS 未做；Android 仅打 arm64-v8a / x86_64
- 消息一律落库（虽已加密），无「不保存明文」选项
- 加密协议**未经第三方安全审计**

## 构建指南

本仓库通过 **Git 子模块** 引入 `vendor/omemo_dart`、`vendor/moxxmpp`、`vendor/libsignal_dart`、`vendor/moxlib`（见 [`.gitmodules`](.gitmodules)）。子模块里有一部分**生成代码不在 Git 中**（例如 `moxxmpp` 的 build_runner 产物），必须先在各子模块里生成，再进入 `app` 构建；否则 `flutter pub get` / 编译会报缺少文件。

### 环境要求

- [Flutter](https://docs.flutter.dev/get-started/install) stable（与 [`README.dev.md`](README.dev.md) 一致：Dart 3.13+）
- Android 开发：JDK 21、Android SDK（运行/打包 APK 时需要）

### 1. 克隆仓库与子模块

```bash
git clone --recurse-submodules https://github.com/resonchat-org/resonchat
cd resonchat
```

### 2. 在子模块中生成代码

```bash
./scripts/generate_submodule_code.sh
```

该脚本按依赖顺序解析各 path 包，并在需要时执行 `build_runner`。（旧的 `omemo_dart` protoc 步骤已随纯 Dart OMEMO 栈一并移除 —— 不要对 `vendor/omemo_dart` 跑 `protoc`。）

### 3. 构建并运行应用

```bash
cd app
flutter pub get
dart run build_runner build   # 生成 drift：database.g.dart 等
flutter run                   # 连接设备或模拟器
```

调试 APK（仓库根目录）：

```bash
./scripts/build_android.sh
```

Linux AppImage（x86_64 / aarch64，需本机已装 Flutter Linux 桌面依赖：clang、cmake、ninja、GTK 3、libsecret 等）：

```bash
./scripts/build_appimage.sh
# → app/build/resonchat-<version>-x86_64.AppImage
chmod +x app/build/resonchat-*-x86_64.AppImage
./app/build/resonchat-*-x86_64.AppImage
```

Debian / RPM（同一 release bundle；链接库依赖由打包工具自动推断，CLI 依赖见 `scripts/linux_pkg_deps.sh`）：

```bash
./scripts/build_deb_rpm.sh          # 或 --skip-build 复用已有 bundle
# → app/build/resonchat_<version>_x86_64.deb
#   app/build/resonchat-<version>-1.x86_64.rpm
```

Windows 安装包（在 PowerShell 中执行，`scripts/build_windows.ps1`）：

```powershell
./scripts/build_windows.ps1
# → app/build/windows/installer/resonchat-<version>-x86_64-setup.exe
```

Web（Drift `sqlite3.wasm` + Dart→Wasm；产物在 `app/build/web/`）：

```bash
./scripts/build_web.sh
# Release 包：resonchat-<tag>-wasm.tar.gz（CD 从 app/build/web 打 tar.gz）
```

`vendor/libsignal_dart` 提供 native libsignal：它的构建 hook 会下载对应平台的预编译 `libsignal_frb` release，因此首次构建需要联网。

更完整的工具链版本、分析与测试命令见 [`README.dev.md`](README.dev.md)。

## 开发

构建、测试与本地环境见 [`README.dev.md`](README.dev.md)。

## 文档

完整设计文档见 [`docs/`](docs/README.md)：

| 文档 | 内容 |
|---|---|
| [总览与关键决策](docs/01-overview.md) | 目标、约束、ADR、架构 |
| [协议规范](docs/02-protocol-pqomemo.md) | 双轨 OMEMO、PQXDH、消息格式 |
| [XMPP 集成](docs/03-xmpp-integration.md) | PEP 节点、收发流程 |
| [密码学实现](docs/04-crypto-android.md) | pqcrypto / libsignal、密钥存储 |
| [UI 规范](docs/05-ui.md) | 布局、组件、输入栏移植 |
| [里程碑](docs/06-android-milestones.md) | M0–M7 |
| [合规](docs/07-licensing-compliance.md) | 许可证与商标 |
| [风险](docs/08-risks-open-questions.md) | 风险与待决问题 |
| [Briar 借鉴](docs/09-briar-lessons.md) | 信任 UX、省电设计 |
| [三轨选择](docs/10-track-selection.md) | 用户选定、可行性判定、标签一致性 |

## 许可证

[GNU GPL-3.0-or-later](LICENSE)。

## 第三方代码声明

本项目以 GPL-3.0-or-later 发布，并包含以下第三方代码。完整矩阵见 [`docs/07-licensing-compliance.md`](docs/07-licensing-compliance.md)。

### 仓库内上游 fork（`vendor/`，git 子模块）

以下四个库为上游 fork，**原 license 头与版权声明均予保留**：

| 路径 | 上游 | 许可证 | 本地改动 |
|---|---|---|---|
| `vendor/moxxmpp` | [codeberg.org/moxxy/moxxmpp](https://codeberg.org/moxxy/moxxmpp) | MIT | 移除私有 registry；Dart 3；MAM；RFC 7395 / XEP-0156 |
| `vendor/omemo_dart` | [github.com/PapaTutuWawa/omemo_dart](https://github.com/PapaTutuWawa/omemo_dart) | MIT | 移除私有 registry；axolotl 路径 |
| `vendor/libsignal_dart` | [github.com/djx-y-z/libsignal_dart](https://github.com/djx-y-z/libsignal_dart) | **AGPL-3.0** | ML-KEM-1024（`0x0A`）补丁；发布并下载预编译 native `libsignal_frb` release |
| `vendor/moxlib` | [codeberg.org/moxxy/moxlib](https://codeberg.org/moxxy/moxlib) | **GPL-3.0** | SDK 约束提升到 Dart 3 |

### UI 设计参考

`app/lib/ui/` 下的界面以本项目自有设计为主。局部组件（主要是输入栏）参考/移植自 Telegram for Android（GPL-2.0-or-later）。移植自 Telegram 的文件保留原始版权声明与 NOTICE，并显著标注修改来源与日期。**本项目不是 Telegram 官方客户端，与 Telegram 无关**；Telegram 名称与 Logo 均为其各自所有者的商标。

### 运行时依赖（经包管理器获取，不在本仓库内）

| 依赖 | 许可证 |
|---|---|
| `cryptography`（Dart） | Apache-2.0 |
| `pqcrypto`（Dart） | MIT |
| `libsignal`（path → `vendor/libsignal_dart`） | AGPL-3.0 |
| drift | MIT |
| SQLCipher / sqlcipher_flutter_libs | BSD-style（含 OpenSSL） |
| flutter_secure_storage | BSD-3-Clause |
| riverpod / flutter_riverpod | MIT |

> 自有源文件均带 `SPDX-License-Identifier: GPL-3.0-or-later` 文件头。

## 免责声明

加密协议为自定义的 OMEMO 后量子扩展，**尚未经过第三方安全审计**。在完成独立审计之前，请勿用于高敏感场景，也不应对外宣称其安全性。
