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

验证：`dart analyze lib test tool integration_test` 无告警 · `flutter test` 79 项通过 ·
`flutter build apk --debug` 成功 · liboqs 参考程序构建 · 设备端 native 集成测试通过。

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
| adb 输入法 | 中文 TTS IME 会吞掉 `@` 和 `.` | 用 `--dart-define` 注入凭据做无人值守测试 |

| 里程碑 | 状态 |
|---|---|
| M0 工程骨架 | ✅ 应用/包结构、fork 接线、CI、分析与测试全绿、Android debug APK 可构建 |
| M1 通信基线 | ✅ 连接/SASL SCRAM-SHA-256、资源绑定、roster（drift 持久化 + RFC 6121 版本）、明文收发、XEP-0184 回执、XEP-0085 输入状态、XEP-0280 Carbons、**XEP-0313 MAM**（已从上游 `feat/mam` 并入）、drift 消息存储、最小 UI。剩余验证项：与真实服务端/客户端的双账号互发 |
| M2 标准 OMEMO | 🟡 moxxmpp `OmemoManager` + `omemo_dart` 已接线，设备/bundle 发布、指纹、TOFU 委托上游，**设备密钥已持久化**（Keystore 封存 + drift 存储）；**与 Conversations 的真实互通尚未验证**（需真机 + 测试账号 + 本地 prosody） |
| M3 PQ 内核 | ✅ PQXDH → Double Ratchet 接线完成；liboqs FFI 在设备实测（`backend: liboqs (native)`）且与纯 Dart 逐字节等价；**双账号跨服务器真实互测通过**（conversations.im ↔ jabber.fr，10/10 检查）；PQ bundle 已真实发布到服务器 |
| M4 协商与回退 | 🟡 `decideEncMode` 状态机（穷举测试）、B 轨 PEP 能力查询、`CapabilityService`（缓存 + 并发去重 + `reliable` 标记）均已接到发送路径：A 轨自动加密，B 轨优先、失败回落。**PEP 变更订阅触发缓存失效仍未做**（目前只靠 TTL） |
| M5 存储与保护 | 🟡 OMEMO 设备密钥已用 Keystore 封存后落库（M5 的骨架就位）；SQLCipher 加密数据库、密钥备份/恢复、「不保存明文」选项未做 |
| M6 UI | 🟡 已按 docs/05 重做：TG 色板（真实采样自 ThemeColors.java）、CustomPainter 气泡带尾角、日期分隔、未读线、会话列表两行布局、滚动到底 FAB、输入栏（空输入变麦克风）。动画、平板适配、资料页未做 |
| M7 发布 | ⬜ |

## 关键待办（下一步优先级）

1. **M2 互通实测（仍未完成，优先级最高）**：与**真实 Conversations 客户端**双向加解密。已验证登录、roster、OMEMO bundle 发布与线格式合规，但从未与真正的 Conversations 交换过一条加密消息。docs/06 明确要求此验收先行，需要一台装了 Conversations 的设备。
2. **PEP 变更订阅**：收到对端设备列表/bundle 变更通知时调用 `CapabilityService.invalidate`，目前缓存只靠 TTL 过期。
3. **SQLCipher 加密数据库**：消息与棘轮状态目前仍是明文 SQLite。
4. **PQ 预密钥补充**：A 轨已有 `replenishPrekeys`；B 轨的 ML-KEM 一次性预密钥池尚无低水位补充。
5. **liboqs on iOS**：当前只编译了 arm64-v8a 与 x86_64 两个 Android ABI。
6. **UI 打磨**：见 docs/05，当前为主题 token + 气泡 + 两页布局，未做动画与平板适配。

## 已完成的验证工具

| 工具 | 用途 |
|---|---|
| `tool/smoke_test.sh <jid> <pass>` | 无人值守登录冒烟（`--dart-define` 注入凭据，仅 debug 生效） |
| `tool/interop_probe.dart <jid> <pass> [peer]` | A 轨 bundle 线格式与 PEP 发布校验 |
| `tool/pq_interop.dart <jidA> <passA> <jidB> <passB>` | **B 轨双账号真实互测**：PQ 加解密 + PEP 能力发现 |
| `tool/build_liboqs.sh` | 构建 liboqs 静态库与 KAT 参考程序 |
| `tool/previews/` | 把 UI 渲染成 PNG 供设计评审 |
| `integration_test/native_pq_test.dart` | 设备上确认实际加载的是 native liboqs 还是纯 Dart |