# packages/ — 上游 fork 目录（vendored）

本目录内的代码是上游库的**本地 fork**，以 vendored 形式直接纳入本仓库
（而非 git submodule），以保证 CI 与本地构建无需初始化子模块即可通过。

`app/pubspec.yaml` 通过 path 依赖 + `dependency_overrides` 引用它们，
并把上游自建 Gitea registry 的依赖全部改指到本目录。

| 目录 | 上游 | 版本 | 上游 commit | 许可证 |
|---|---|---|---|---|
| `moxxmpp/packages/moxxmpp` | https://codeberg.org/moxxy/moxxmpp | 0.4.0 | `c61ddeb338cd554e878eeb31911237f2809c9db7` (2024-11-17) | MIT |
| `moxxmpp/packages/moxxmpp_socket_tcp` | 同上（monorepo 内子包） | 0.4.0 | 同上 | MIT |
| `omemo_dart` | https://codeberg.org/PapaTutuWawa/omemo_dart | 0.6.0 | `124c997fa3f0792fa50ff66b80f43c3b71382f89` (2024-09-29) | MIT |
| `moxlib` | https://codeberg.org/moxxy/moxlib | 0.2.0 | `83be3c882631a6a432d64f3e5887f9304bfefe30` (2023-08-22) | MIT |

三个上游库均**不在 pub.dev**，其 `pubspec.yaml` 原本 `publish_to` 到
`https://git.polynom.me/api/packages/...`（作者自建 Gitea）。该服务可达性
无法保证，因此本地 fork 删除了 `publish_to` 与 `hosted:` 依赖声明。

## 本地改动清单

保持与上游最小差异，便于日后 rebase：

**moxxmpp / moxxmpp_socket_tcp**
- `pubspec.yaml`：删除 `publish_to`；`moxlib`、`omemo_dart` 依赖保留原样但由
  app 侧 `dependency_overrides` 覆盖为本地路径。
- `moxxmpp_socket_tcp/pubspec.yaml`：`environment.sdk` 由 `>=2.17.5 <3.0.0`
  提升为 `>=3.0.0 <4.0.0`，与主包及当前 Dart SDK（3.13）对齐。
- **并入 MAM（XEP-0313）**：上游 master 无该实现，从 `feat/mam` 分支
  （commit `67ce94d`，含 `09f331b` + `b67bd02`）取增量，涉及
  `lib/src/xeps/xep_0313.dart`（新文件）、`awaiter.dart`、`connection.dart`、
  `events.dart`、`managers/namespaces.dart`、`message.dart`、`namespaces.dart`、
  `stanza.dart`、`util/incoming_queue.dart`、`lib/moxxmpp.dart`。
  注意：该分支基于 FAST 迁移到 `xep_0484` 之前，因此 `lib/moxxmpp.dart` **不能**
  整文件照抄（会导出已不存在的 `staging/fast.dart` 并丢掉 `xep_0484` 导出），
  实际做法是保留 master 版并手工加一行 `xep_0313.dart` 导出。
- 同步新增 `examples_dart/bin/mam_example.dart`（上游示例）。

**omemo_dart**
- `pubspec.yaml`：删除 `publish_to`；`moxlib` 的 `hosted:` 声明保留，由 app 侧覆盖。

**moxlib**
- `pubspec.yaml`：`environment.sdk` 由 `>=2.17.0 <3.0.0` 提升为 `>=3.0.0 <4.0.0`。

## 未 vendored 的子包

`moxxmpp` 仓库还含 `moxxmpp_color`、examples、`integration_tests` 等，
本项目暂不使用，保留在目录内但不参与构建。

## 后续工作

- **MAM（XEP-0313）**：已并入（见上）。若上游日后合并 `feat/mam`，rebase 时
  需特别留意 `lib/moxxmpp.dart` 的导出顺序差异。
- **B 轨（PQ-OMEMO）**：按 ADR-006，PQ 代码放在 app 侧 `lib/omemo/` 与 `lib/pq/`，
  保持 omemo_dart 上游零侵入；A 轨继续完全委托 omemo_dart，以确保与
  Conversations 等客户端互通。