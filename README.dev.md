# resonchat — 构建、测试与本地开发

## 工具链

| 组件 | 版本 | 说明 |
|---|---|---|
| Flutter | 3.47.5（stable） | `~/development/flutter` |
| Dart | 3.13.4 | 随 Flutter |
| JDK | 21 | `JAVA_HOME` 指向 system jdk 即可 |
| Android SDK | platform 35 + build-tools 35.0.0 | `~/Android/Sdk` |
| Android NDK | 27.0.12077973 | M3 起编译 liboqs 时需要 |
| CMake (SDK) | 3.22.1 | M3 起使用 |

环境变量：

```bash
export PATH="$HOME/development/flutter/bin:$HOME/Android/Sdk/cmdline-tools/latest/bin:$HOME/Android/Sdk/platform-tools:$PATH"
export ANDROID_HOME="$HOME/Android/Sdk"
```

## 仓库结构

```
xmppflutter/
├─ docs/                     设计文档集（docs/）
├─ app/                      Flutter 应用
│  ├─ lib/
│  │  ├─ crypto/             PQXDH / KDF / 指纹
│  │  ├─ omemo/              双轨协议：常量、编解码、协商状态机、轨道管理器
│  │  ├─ pq/                 ML-KEM-768 抽象与纯 Dart 实现
│  │  ├─ store/              drift 数据库 + roster 状态桥
│  │  ├─ state/              Riverpod providers
│  │  ├─ ui/                 登录 / 会话列表 / 聊天 / 加密信息 / 设置
│  │  └─ xmpp/               连接生命周期与事件分发
│  └─ test/                  单元测试
└─ packages/                 上游 fork（mono-repo 内 path 依赖）
   ├─ moxxmpp/packages/moxxmpp
   ├─ moxxmpp/packages/moxxmpp_socket_tcp
   ├─ omemo_dart
   └─ moxlib
```

### fork 说明

三个上游库都从 Codeberg fork 并保留原 license：

| 包 | 上游 | 许可证 | 本地改动 |
|---|---|---|---|
| `moxxmpp` | codeberg.org/moxxy/moxxmpp | MIT（文档写作 MPL-2.0，实为 MIT，以仓库为准） | 移除私有 registry（`publish_to`），改用 path 依赖；`moxxmpp_socket_tcp` SDK 约束提升到 Dart 3 |
| `omemo_dart` | codeberg.org/PapaTutuWawa/omemo_dart | MIT | 仅移除 `publish_to` / 私有 registry |
| `moxlib` | codeberg.org/moxxy/moxlib | MIT | SDK 约束提升到 Dart 3 |

> 注意：docs/07 记录的 moxxmpp 许可证为 MPL-2.0，实际仓库 LICENSE 为 MIT，已按 MIT 处理（MIT 与 GPLv3 兼容）。

`app/pubspec.yaml` 用 `dependency_overrides` 把私有 registry 依赖全部指向 `packages/`，因此 `flutter pub get` 不需要访问上游自建 Gitea。

## 常用命令

```bash
cd app
flutter pub get
dart run build_runner build          # 生成 drift 代码（database.g.dart）
dart analyze lib test                # flutter analyze 在本机会崩，改用 dart analyze
flutter test
flutter build apk --debug
```

## 当前实现状态

验证：`dart analyze lib test` 无告警 · `flutter test` 35 项通过 · `flutter build apk --debug` 成功。

存储层注意：drift 的 DateTime 默认按**秒**存储，故消息排序以 `timestamp` + 自增 `id` 兜底，
会话活跃时间仅在变新时更新（导入旧历史不会让列表回退）。

| 里程碑 | 状态 |
|---|---|
| M0 工程骨架 | ✅ 应用/包结构、fork 接线、CI、分析与测试全绿、Android debug APK 可构建 |
| M1 通信基线 | 🟡 连接/SASL SCRAM-SHA-256、资源绑定、roster（drift 持久化 + RFC 6121 版本）、明文收发、XEP-0184 回执、XEP-0085 输入状态、XEP-0280 Carbons、drift 消息存储、最小 UI 均已接线；**MAM 未实现**（上游 master 缺失 XEP-0313，需从 `feat/mam` cherry-pick 或自写） |
| M2 标准 OMEMO | 🟡 moxxmpp `OmemoManager` + `omemo_dart` 已接线，设备/bundle 发布、指纹、TOFU 委托上游；**与 Conversations 的真实互通尚未验证**（需真机 + 测试账号 + 本地 prosody） |
| M3 PQ 内核 | 🟡 PQXDH KDF、ML-KEM-768 抽象与纯 Dart 实现、双轨 bundle/消息编解码已有测试覆盖；**liboqs FFI 尚未接入**，B 轨会话建立（ratchet 接线）未做 |
| M4 协商与回退 | 🟡 `decideEncMode` 状态机（纯函数，有测试）与 B 轨 PEP 能力查询已完成；UI 徽标为静态，尚未由能力驱动 |
| M5 存储与保护 | ⬜ 仅明文 SQLite + 路径；SQLCipher、Keystore、密钥备份未做（代码中留有 TODO） |
| M6 UI | ⬜ 当前为功能性最小 UI，主题 token 只是起始值，未做 Telegram 观感打磨 |
| M7 发布 | ⬜ |

## 关键待办（下一步优先级）

1. **MAM（XEP-0313）**：从上游 `feat/mam` 分支 cherry-pick，历史同步是 M1 验收项。
2. **M2 互通实测**：起本地 prosody + 两个账号，与 Conversations 双向加解密；这是整个项目的关键路径。
3. **OMEMO 设备持久化**：当前 `ensureOmemoDevice` 每次安装重新生成设备（M5 前也需先做，否则重启后设备列表膨胀）。
4. **B 轨会话接线**：PQXDH 已能派生 root/chain key，需接到 ratchet 与收发流程。
5. **liboqs FFI**：替换 `pqcrypto` 纯 Dart 实现，走 `OQS_MINIMAL_BUILD="KEM_ml_kem_768;SIG_ml_dsa_65"`。