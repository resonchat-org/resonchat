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

验证：`dart analyze lib test tool integration_test` 无告警 · `flutter test` 123 项通过 ·
`flutter build apk --debug` 成功 · liboqs 参考程序构建 · 设备端 native 集成测试通过 ·
与真实 Conversations 的互通验收通过（两次运行，见 `tool/m2_verify_conversations.sh`）。

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
| XEP-0384 线格式 | 规范节点名 `urn:xmpp:omemo:2:*` 没有任何客户端实现；真实世界是 `eu.siacs.conversations.axolotl.*` | 出入站都同时支持两种方言（`lib/omemo/defacto.dart`） |
| Signal 公钥序列化 | 公钥是「1 字节类型前缀 0x05 + 32 字节密钥」= 33 字节；omemo_dart 用裸 32 字节 | 读时剥前缀、写时加前缀（`stripKeyTypeByte`/`addKeyTypeByte`） |
| PubSub item id | 真实客户端把 bundle 挂在 `current` 上，moxxmpp 用设备号 | 取整节点，谁的 item 能解析就用谁 |
| `ShouldEncrypt` 回调 | moxxmpp 对**每个**出站 stanza 都问一次「要不要加密」 | 只对 `message` 回答；否则能力解析会为每个 PubSub IQ 再发 IQ，形成无界级联把登录饿死 |
| RFC 6121 版本控制 | 服务器无变更时回不含 `<query/>` 的 `<iq/>`，moxxmpp 转成**空**增量 | 联系人列表必须从本地缓存读，不能直接用 IQ 返回值 |

| 里程碑 | 状态 |
|---|---|
| M0 工程骨架 | ✅ 应用/包结构、fork 接线、CI、分析与测试全绿、Android debug APK 可构建 |
| M1 通信基线 | ✅ 连接/SASL SCRAM-SHA-256、资源绑定、roster（drift 持久化 + RFC 6121 版本）、明文收发、XEP-0184 回执、XEP-0085 输入状态、XEP-0280 Carbons、**XEP-0313 MAM**（已从上游 `feat/mam` 并入）、drift 消息存储、最小 UI。剩余验证项：与真实服务端/客户端的双账号互发 |
| M2 标准 OMEMO | ✅ **与真实 Conversations 2.20.4 互通验收通过**：我们加密的消息被第三方客户端解密并显示（唯一标记 + 抓第三方 view hierarchy 自动判定，见 `tool/m2_verify_conversations.sh`）。为此修掉 3 处「按规范实现但真实世界不认」的互不兼容：PEP 节点名、bundle 元素名、Signal 公钥类型字节 |
| M3 PQ 内核 | ✅ PQXDH → Double Ratchet 接线完成；liboqs FFI 在设备实测（`backend: liboqs (native)`）且与纯 Dart 逐字节等价；**双账号跨服务器真实互测通过**（conversations.im ↔ jabber.fr，10/10 检查）；PQ bundle 已真实发布到服务器 |
| M4 协商与回退 | ✅ `decideEncMode` 状态机（穷举测试）、B 轨 PEP 能力查询、`CapabilityService`（缓存 + 并发去重 + `reliable` 标记）接到发送路径：A 轨自动加密，B 轨优先、失败回落。**PEP 变更订阅已完成**：四个节点（两种方言 × 两轨）任一变化即失效缓存 |
| M5 存储与保护 | ✅ OMEMO 设备密钥经 Keystore 封存落库；数据库用 SQLCipher 加密（口令在 Keystore，验收测试直接搜原始文件证明明文不外泄）。**密钥备份/恢复、「不保存明文」选项仍未做** |
| M6 UI | 🟡 已按 docs/05 重做：TG 色板（真实采样自 ThemeColors.java）、CustomPainter 气泡带尾角、日期分隔、未读线、会话列表两行布局、滚动到底 FAB、输入栏（空输入变麦克风）。动画、平板适配、资料页未做 |
| M7 发布 | ⬜ |

## 关键待办（下一步优先级）

1. **反向互通（Conversations → 我们）**：验收已证明我们发出去的消息能被真实
   客户端解密；反方向在本环境不可测，因为 conversations.im 对非双向订阅拒绝
   投递，且模拟器上前台切换会直接切断 TCP 连接。换成两台真实设备即可补齐。
2. **密钥备份与恢复**：设备密钥目前只在本机 Keystore，换机即全部会话失效。
3. **liboqs on iOS**：当前只编译了 arm64-v8a 与 x86_64 两个 Android ABI。
4. **「不保存明文」选项**与消息删除：目前消息一律落库（虽已加密）。
5. **UI 打磨**：见 docs/05，动画、平板适配、资料页未做。

## 已完成的验证工具

| 工具 | 用途 |
|---|---|
| `tool/smoke_test.sh <jid> <pass>` | 无人值守登录冒烟（`--dart-define` 注入凭据，仅 debug 生效） |
| `tool/m2_verify_conversations.sh <jid> <pass> <peer>` | **M2 验收**：发一条带唯一标记的加密消息，再抓第三方客户端的界面确认它解出来了 |
| `tool/send_text.dart <jid> <pass> <peer> <text>` | 绕开本客户端的明文发送工具，用来判定「服务器不路由」还是「客户端处理错」 |
| `tool/peek_pep.dart <jid> <pass> <peer>` | 直读对端 PEP 节点与自身 roster，并打印服务器原始 IQ 回复 |
| `integration_test/a_track_interop_test.dart` | 两个独立客户端实例跨服务器交换真实 OMEMO 消息（可复现回归） |
| `integration_test/m2_interop_test.dart` | 与真实客户端的能力协商全流程：读它的 bundle、判定轨道、发消息、等入站 |
| `tool/interop_probe.dart <jid> <pass> [peer]` | A 轨 bundle 线格式与 PEP 发布校验 |
| `tool/pq_interop.dart <jidA> <passA> <jidB> <passB>` | **B 轨双账号真实互测**：PQ 加解密 + PEP 能力发现 |
| `tool/build_liboqs.sh` | 构建 liboqs 静态库与 KAT 参考程序 |
| `tool/previews/` | 把 UI 渲染成 PNG 供设计评审 |
| `integration_test/native_pq_test.dart` | 设备上确认实际加载的是 native liboqs 还是纯 Dart |