# vendor/ — 上游 fork（git 子模块）

本目录内的代码是上游库的**本地 fork**，以 **git 子模块** 纳入本仓库（见根目录 `.gitmodules`）。克隆时使用 `git clone --recurse-submodules`，或之后 `git submodule update --init --recursive`。

`app/pubspec.yaml` 通过 path 依赖 + `dependency_overrides` 引用它们，并把上游自建 Gitea registry 的依赖全部改指到本目录。

| 目录 | 上游 | 许可证 |
|---|---|---|
| `moxxmpp` | https://codeberg.org/moxxy/moxxmpp | MIT |
| `omemo_dart` | https://github.com/PapaTutuWawa/omemo_dart | MIT |
| `moxlib` | https://codeberg.org/moxxy/moxlib | **GPL-3.0** |

三个上游库均**不在 pub.dev**，其 `pubspec.yaml` 原本 `publish_to` 到作者自建 Gitea。本地 fork 删除了 `publish_to` 与 `hosted:` 依赖声明。

本仓库的子模块远程指向 `github.com/resonchat-org/{moxxmpp,omemo_dart,moxlib}`（维护用 fork）。

## 本地改动清单

保持与上游最小差异，便于日后 rebase：

**moxxmpp**
- `pubspec.yaml`：删除 `publish_to`；依赖由 app 侧 path 引用。
- 库根就是仓库根（原先在 `packages/moxxmpp`）。分析规则收成根目录一份 `analysis_options.yaml`。
- TCP 传输（原 `moxxmpp_socket_tcp`）在 `package:moxxmpp/socket_tcp.dart`。
- **并入 MAM（XEP-0313）**：从上游 `feat/mam` 取增量（`xep_0313.dart` 等）。
- **RFC 7395 WebSocket + XEP-0156**：Web 传输与 host-meta 发现在 moxxmpp 内实现；应用侧只做平台 socket 工厂。

**omemo_dart**
- `pubspec.yaml`：删除 `publish_to`。
- A 轨完整 Conversations/axolotl 路径（`omemo_dart_axolotl`）；Protobuf 生成物由子模块内 `protoc` 产出。

**moxlib**
- `pubspec.yaml`：`environment.sdk` 提升为 Dart 3。

## 未参与构建的子包

`moxxmpp` 仓库还含 examples、`integration_tests` 等，本项目保留在目录内但不参与应用构建。XEP-0392 的 `moxxmpp_color` 未使用，已删除。

## B 轨与 A 轨分工

按 ADR-006，B 轨 PQ/OMEMO2 在 app 侧 `lib/crypto/omemo2/`，双轨编排在 `lib/crypto/dual/`，A 轨方言在 `lib/crypto/axolotl/`；保持 omemo_dart 上游零侵入，A 轨继续完全委托 omemo_dart / axolotl，以确保与 Conversations 等客户端互通。
