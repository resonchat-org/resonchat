# resonchat

一个基于 Flutter 的 XMPP 客户端：在**不修改服务端、不引入新 XEP** 的前提下，实现与 OMEMO 同构的**后量子加密**（X25519 + ML-KEM-768），同时**保持与标准 OMEMO 客户端互通**；UI 采用 Telegram Android 观感。Android 优先。

## 特性

| 特性 | 状态 | 说明 |
|---|---|---|
| 双轨端到端加密（A 轨） | 已完成 | 标准 OMEMO（XEP-0384），与 Conversations / Moxxy / Dino 等互通。已与真实 Conversations 2.20.4 完成互通验收 |
| 双轨端到端加密（B 轨） | 已完成 | PQ-OMEMO（X25519 + ML-KEM-768 混合，PQXDH），对端全部设备支持时自动升级。已双账号跨服务器互测通过 |
| 零服务端改动 / 零新 XEP | 已完成 | 复用 PEP、EME 等既有标准 |
| 数据库落盘加密 | 已完成 | SQLCipher，口令由 Android Keystore 保护 |
| 标准协议扩展 | 已完成 | MAM（XEP-0313）历史同步、回执（XEP-0184）、输入状态（XEP-0085）、Carbons（XEP-0280） |
| Android 平台支持 | 部分完成 | 仅 Android（arm64-v8a / x86_64）；iOS 与其他平台未做 |
| Telegram Android 观感 UI | 进行中 | 气泡、色板、列表布局已实现；动画、平板适配、资料页未做 |

## 状态

**M0–M5 已完成，M6 进行中，M7 未开始。**

| 里程碑 | 状态 | 要点 |
|---|---|---|
| M0 工程骨架 | 已完成 | mono-repo 骨架、三个上游 fork 接线、CI、drift 存储、PQXDH 与双轨编解码、Android debug APK 可构建 |
| M1 通信基线 | 已完成 | SASL SCRAM-SHA-256、资源绑定、roster（RFC 6121 版本控制）、明文收发、MAM 历史同步、Carbons、消息存储 |
| M2 标准 OMEMO | 已完成 | **与真实 Conversations 2.20.4 互通验收通过**（我们加密的消息被第三方客户端解密并显示） |
| M3 PQ 内核 | 已完成 | liboqs FFI 设备实测，与纯 Dart 实现逐字节等价；**双账号跨服务器互测通过**（conversations.im 与 jabber.fr）；PQ bundle 已真实发布到服务器 |
| M4 协商与回退 | 已完成 | `decideEncMode` 状态机、能力解析服务接发送路径；A 轨自动加密，B 轨优先、失败回落 |
| M5 存储与保护 | 已完成 | OMEMO 设备密钥经 Keystore 封存落库；数据库 SQLCipher 加密。**密钥备份/恢复与「不保存明文」选项未做** |
| M6 UI | 进行中 | 按 [docs/05](docs/05-ui-telegram.md) 重做中 |
| M7 发布 | 未开始 | — |

当前验证结果：`dart analyze lib test tool integration_test` 无告警；`flutter test` 123 项通过；`flutter build apk --debug` 成功。

**已知限制与未完成项**（完整清单见 [`README.dev.md`](README.dev.md)）：

- 反向互通（Conversations 到本客户端）尚未验证 —— 验收环境对非双向订阅拒绝投递，需两台真实设备补齐
- 设备密钥仅存本机 Keystore，**换机即全部会话失效**（无备份与恢复）
- 仅编译 Android 两个 ABI，liboqs 未支持 iOS
- 消息一律落库（虽已加密），无「不保存明文」选项
- 加密协议**未经第三方安全审计**

## 构建指南

本仓库通过 **Git 子模块** 引入 `packages/moxlib`、`packages/omemo_dart`、`packages/moxxmpp`（见 [`.gitmodules`](.gitmodules)）。子模块里有一部分**生成代码不在 Git 中**（例如 `omemo_dart` 的 `schema.pb.dart`），必须先在各子模块里生成，再进入 `app` 构建；否则 `flutter pub get` / 编译会报缺少文件。

### 环境要求

- [Flutter](https://docs.flutter.dev/get-started/install) stable（与 [`README.dev.md`](README.dev.md) 一致：Dart 3.13+）
- Android 开发：JDK 21、Android SDK（运行/打包 APK 时需要）
- **`protoc`**：`omemo_dart` 从 `protobuf/schema.proto` 生成 Dart 代码时需要（例如 Debian/Ubuntu：`protobuf-compiler`）

### 1. 克隆仓库与子模块

```bash
git clone --recurse-submodules https://github.com/resonchat-org/resonchat
cd resonchat
```

### 2. 在子模块中生成代码

按依赖顺序执行（路径均相对于仓库根目录）：

**`moxlib`（无代码生成，只需解析依赖）**

```bash
cd packages/moxlib && dart pub get && cd ../..
```

**`omemo_dart`（Protobuf → `lib/src/protobuf/schema.pb.dart`）**

```bash
cd packages/omemo_dart
dart pub get
dart pub global activate protoc_plugin
export PATH="$PATH:$HOME/.pub-cache/bin"
protoc --dart_out=lib/src/protobuf -Iprotobuf protobuf/schema.proto
cd ../..
```

**`moxxmpp`（拉取依赖并跑 `build_runner`；与上游 monorepo 习惯一致）**

```bash
cd packages/moxxmpp/packages/moxxmpp
dart pub get
dart run build_runner build
cd ../moxxmpp_socket_tcp
dart pub get
cd ../../..
```

也可在 `packages/moxxmpp` 使用 [melos](https://melos.invertase.dev/)：`melos bootstrap`（需本机已安装 `melos`），再于 `packages/moxxmpp/packages/moxxmpp` 执行上面的 `build_runner` 命令。

### 3. 构建并运行应用

```bash
cd app
flutter pub get
dart run build_runner build   # 生成 drift：database.g.dart 等
flutter run                   # 连接设备或模拟器
```

调试 APK：

```bash
cd app
flutter build apk --debug
```

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
| [密码学实现](docs/04-crypto-android.md) | liboqs/NDK、密钥存储 |
| [UI 规范](docs/05-ui-telegram.md) | Telegram 观感与移植 |
| [里程碑](docs/06-android-milestones.md) | M0–M7 |
| [合规](docs/07-licensing-compliance.md) | 许可证与商标 |
| [风险](docs/08-risks-open-questions.md) | 风险与待决问题 |
| [Briar 借鉴](docs/09-briar-lessons.md) | 信任 UX、省电设计，以及不该抄的部分 |

## 许可证

[GNU GPL-3.0-or-later](LICENSE)。

## 第三方代码声明

本项目以 GPL-3.0-or-later 发布，并包含以下第三方代码。完整矩阵见 [`docs/07-licensing-compliance.md`](docs/07-licensing-compliance.md)。

### 仓库内 vendored 的上游库（`packages/`）

以下三个库为上游 fork，仅移除 `publish_to` 与私有 registry 依赖、改用 path 依赖等少量改动，**原 license 头与版权声明均予保留**：

| 路径 | 上游 | 许可证 | 本地改动 |
|---|---|---|---|
| `packages/moxxmpp` | [codeberg.org/moxxy/moxxmpp](https://codeberg.org/moxxy/moxxmpp) | MIT（Copyright 2022 Alexander "PapaTutuWawa"） | 移除 `publish_to` 与私有 registry；`moxxmpp_socket_tcp` 的 SDK 约束提升到 Dart 3 |
| `packages/omemo_dart` | [github.com/PapaTutuWawa/omemo_dart](https://github.com/PapaTutuWawa/omemo_dart) | MIT | 仅移除 `publish_to` 与私有 registry |
| `packages/moxlib` | [codeberg.org/moxxy/moxlib](https://codeberg.org/moxxy/moxlib) | **GPL-3.0**（见 `packages/moxlib/LICENSE`） | SDK 约束提升到 Dart 3 |

> **关于 moxlib**：早期文档（`docs/07`）将 moxlib 记为 MIT，实测其仓库内的 `LICENSE` 为 GPL-3.0 全文。与本项目的 GPL-3.0-or-later 一致，不构成冲突。

### UI 设计参考

`app/lib/ui/` 下的界面设计参照 Telegram for Android 的布局与交互范式（GPL-2.0-or-later）。移植自 Telegram 的文件保留原始版权声明与 NOTICE，并显著标注修改来源与日期。**本项目不是 Telegram 官方客户端，与 Telegram 无关**；Telegram 名称与 Logo 均为其各自所有者的商标。

### 运行时依赖（经包管理器获取，不在本仓库内）

| 依赖 | 许可证 |
|---|---|
| liboqs | MIT |
| `cryptography`（Dart） | Apache-2.0 |
| `pqcrypto`（Dart） | MIT |
| drift | MIT |
| SQLCipher / sqlcipher_flutter_libs | BSD-style（含 OpenSSL） |
| flutter_secure_storage | BSD-3-Clause |
| riverpod / flutter_riverpod | MIT |

> 自有源文件均带 `SPDX-License-Identifier: GPL-3.0-or-later` 文件头。

## 免责声明

加密协议为自定义的 OMEMO 后量子扩展，**尚未经过第三方安全审计**。在完成独立审计之前，请勿用于高敏感场景，也不应对外宣称其安全性。

本项目**不是** Telegram 官方客户端，与 Telegram 无关；Telegram 名称与 Logo 为其各自所有者的商标。