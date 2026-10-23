# 01 — 总览与关键决策

## 1. 项目目标

| # | 目标 |
|---|---|
| G1 | 基于 Flutter 的 XMPP 客户端，**Android 优先**，并提供 Web 与 Linux AppImage 构建路径 |
| G2 | 与 **标准 OMEMO 客户端**（Conversations / Moxxy / Dino / Gajim）完全互通 |
| G3 | 在双方均为本客户端且用户选定后量子轨道时，使用**后量子混合加密**（X25519 + ML-KEM-1024；握手 PQXDH、棘轮 SPQR） |
| G4 | **不修改服务端**、**不引入新 XEP**、**不依赖服务端特殊支持** |
| G5 | UI 为**自有设计**；输入栏等**局部组件**参考 Telegram Android |
| G6 | 以 **GPLv3** 开源发布 |

## 2. 非目标（明确排除）

- ❌ 不做 Telegram 协议的客户端（不用 TDLib、不连 Telegram 服务器）；UI 整体自有，只在输入栏等局部组件上参考 Telegram Android。
- ❌ 不发明或提交新的 XEP。
- ❌ 不修改 Prosody / ejabberd / Openfire 等任何服务端。
- ❌ 不与标准 OMEMO 客户端共享 PQ 会话（它们不可能解密，这是物理限制）。

## 3. 硬约束

| 约束 | 含义 | 影响 |
|---|---|---|
| C1 | 服务端不可改 | 加密负载必须是服务端可存储的不透明 XML |
| C2 | 不加 XEP | 能力协商必须复用既有 XEP（PEP 0163/0060、EME 0380、disco 0030） |
| C3 | 必须互通 | 标准 OMEMO 轨道必须完整、正确 |
| C4 | 后量子 | 初始密钥协商必须混合 ML-KEM-1024；棘轮必须并行运行 SPQR（libsignal v0.105.0 默认行为） |
| C5 | 移动端优先 | 密码学实现需适配 Android NDK/ABI |

## 4. 关键决策记录（ADR）

### ADR-001：双轨（标准 OMEMO + PQ 轨道）而非单一方案
- **决定**：同时实现标准 OMEMO 和 PQ-OMEMO 两条轨道；发送轨道由用户选择，可行性由 `TrackResolver` 判定（见 [10-track-selection.md](10-track-selection.md)）。
- **理由**：C3（互通）与 C4（后量子）在逻辑上互斥，除非分层。标准客户端只认 Conversations/axolotl 线格式。
- **后果**：实现与测试成本约翻倍；需要一套健壮的能力查询、提示与标签一致性规则。

### ADR-002：PQ 覆盖握手与棘轮（PQXDH + SPQR）
- **决定**：会话建立用 PQXDH（X25519 + ML-KEM-1024）派生 root/chain key；此后每条消息的消息密钥**同时**混入 SPQR（Signal Sparse Post-Quantum Ratchet，ML-KEM Braid）的输出。经典 DH 棘轮仍为 X25519，两者并行。
- **理由**：与 Signal 当前协议一致。B 轨会话直接使用上游 `signalapp/libsignal` v0.105.0，其 Double Ratchet 无条件初始化 SPQR（`min_version: V1`），本项目不做关闭。只做 PQXDH 只能防「握手被抓包即解」；SPQR 另外提供 PQ 前向保密与 PQ 后妥协安全（post-compromise security）。
- **后果**：对端必须同样支持 SPQR（同代 libsignal）；`SignalMessage` 头部携带分块的 `pq_ratchet`（field 5），KEM 公钥按块摊薄而非每条消息 1 KB。首条消息体积仍增大。
- **修订记录**：原 ADR 写于仅预期 PQXDH 的阶段（「棘轮保持经典」）；libsignal v0.105.0 起 SPQR 默认启用，措辞与实现不符，故修订。

### ADR-003：能力发现复用 PEP 节点存在性，不新增 disco 特性
- **决定**：设备是否支持 PQ = 其 JID 是否在 PQ device list 中且 bundle 节点存在。
- **理由**：避免新增 XEP；PEP 是既有标准。disco 只能反映「当前在线资源」，而 bundle 是持久化的，更适合离线设备。
- **后果**：需要处理 bundle 过期/清理（服务端 max_items 与 TTL）。

### ADR-004：Fork `moxxmpp` + `omemo_dart` + `moxlib`
- **决定**：以 moxxmpp、omemo_dart、moxlib 为基础，以 git 子模块置于 `vendor/`，`app` 用 path 依赖引用。
- **理由**：三者均为纯 Dart、跨平台；moxxmpp / omemo_dart 为 MIT，moxlib 为 GPL-3.0，与 GPLv3 兼容。上游不在 pub.dev，fork 删除 `publish_to`，由 `dependency_overrides` 指向本地路径。
- **要点**：
  - moxxmpp 上游：`codeberg.org/moxxy/moxxmpp`（MIT）。
  - omemo_dart 上游：`github.com/PapaTutuWawa/omemo_dart`（MIT）；A 轨走 axolotl（`omemo_dart_axolotl`）；B 轨 PQXDH/SessionCipher 走 `omemo_dart_omemo2`。
  - moxlib 上游：`codeberg.org/moxxy/moxlib`（GPL-3.0）。
  - MAM（XEP-0313）已从上游 `feat/mam` 并入 moxxmpp fork。
  - TCP 传输在 `package:moxxmpp/socket_tcp.dart`（`dart:io`，不进主库导出）。
  - 两轨会话密码学都在 `omemo_dart`（axolotl 与 OMEMO2 同一形状：设备、会话、bundle 模型、指纹、KMAC 密封）。moxxmpp 做 A 轨 stanza 与规范 `urn:xmpp:omemo:2` PEP。B 轨 XML 还不是 XEP，留在应用；成为 XEP 后再进 moxxmpp。应用保留 ML-DSA 身份（`pqcrypto`，因为主库仍要直接依赖它）和双轨策略。ML-KEM 由 `omemo_dart` 里的 native `libsignal` 生成消费；纯 Dart KEM 仅供测试/诊断。
- **后果**：需跟进上游变更；A 轨保持与上游最小差异，便于合并。

### ADR-005：UI 局部移植 Telegram Android（输入栏等），整体 GPLv3
- **决定**：输入栏等**局部组件**参考/翻译 TG Android 的 UI 代码；整体视觉与布局为自有设计；不使用其名称与 Logo。
- **理由**：TG Android 是 GPLv2-or-later，可合法并入 GPLv3 工程。
- **后果**：需逐文件标注来源与修改；商标问题需人工审查。

### ADR-006：ML-KEM 走 native `libsignal`，`pqcrypto` 只管 ML-DSA
- **决定**：OMEMO2 设备密钥与 PQXDH 会话 KEM 一律由 native `libsignal`（ML-KEM-1024，wire tag `0x0A`，依赖在 `omemo_dart`）生成与消费；纯 Dart `pqcrypto` 只承担 ML-DSA-87 身份签名。Hybrid 指纹的 SHA3-512 在 `omemo_dart`（`pointycastle`），与 A 轨指纹放在同一层。
- **理由**：monocles 对齐 ML-KEM-1024；libsignal 已随 Flutter 插件打包，`flutter build apk` 无需额外 NDK/CMake 步骤；KEM 复用上游实现，缩小自定义密码学面。
- **后果**：`lib/crypto/omemo2/` 的纯 Dart KEM provider 在生产路径上不再被调用（仅为测试/诊断保留）。
- **已定**：Q1 结论为「默认携带 ML-DSA-87」——`pq-ik`/`pq-sig` 是 OMEMO2 会话的强制条件，缺失即拒绝建会话（never-downgrade），不做「只签经典部分」的降级。

## 5. 架构总览

```
┌──────────────────────────────────────────────────────────────┐
│              Flutter App（Android / Web / Linux）              │
│                                                               │
│  ┌───────────┐   ┌───────────────┐   ┌───────────────────┐   │
│  │  ui/      │   │  state/       │   │  store/           │   │
│  │ 自有 UI   │◄─►│ Riverpod      │◄─►│ drift + SQLCipher │   │
│  └───────────┘   └───────┬───────┘   │ (Web: Drift WASM) │   │
│                          │           └───────────────────┘   │
│  ┌───────────┐   ┌───────▼───────────────────────────────┐   │
│  │ account/  │   │        omemo/ 双轨 + TrackResolver     │   │
│  │ 多账号枢纽 │   │  ┌──────────────┐  ┌───────────────┐  │   │
│  └───────────┘   │  │ A轨 axolotl  │  │ B轨 PQ-OMEMO  │  │   │
│                  │  └──────┬───────┘  └───────┬───────┘  │   │
│                  └─────────┼──────────────────┼──────────┘   │
│                            ▼                  ▼              │
│                  ┌──────────────────────────────────────┐    │
│                  │  crypto/  +  pq/（pqcrypto ML-KEM）     │  │
│                  └──────────────────┬───────────────────┘    │
│                                     ▼                        │
│                  ┌──────────────────────────────────────┐    │
│                  │  xmpp/  moxxmpp（TCP 或 WebSocket）    │    │
│                  └──────────────────┬───────────────────┘    │
└─────────────────────────────────────┼────────────────────────┘
                                      ▼
                          XMPP 服务端（零改动）
                     PEP 存储 / 消息转发 / MAM
```

## 6. 仓库结构

```
resonchat/
├─ docs/                        # 本设计文档集
├─ app/                         # Flutter 应用
│  ├─ android/                  # Android 构建配置
│  ├─ web/                      # Web 入口；Drift WASM 由 build_web 拉取
│  ├─ tool/                     # 互操作探针、prepare_web_assets 等
│  └─ lib/
│     ├─ main.dart
│     ├─ account/               # 多账号枢纽（AccountHub）
│     ├─ xmpp/                  # 连接与协议；子目录 muc/ inbound/ socket/ media/ chat/ encryption/ roster/；横切单文件留根下
│     ├─ crypto/                # axolotl 方言 XML、OMEMO2 XML、ML-DSA、双轨策略
│     ├─ domain/                # 落库用例：协议无关输入 → 编排 AppDatabase（无 XML / 不发 stanza）
│     ├─ persistence/           # Drift AppDatabase（SQL）、备份、平台 DB 连接
│     ├─ state/                 # Riverpod providers；流订阅并调用 domain
│     ├─ net/ / platform/ / l10n/
│     └─ ui/                    # 登录、会话、聊天、设置、账号管理等
└─ vendor/                    # git 子模块（path 依赖）
   ├─ moxxmpp/                  # XMPP 库（含 TCP socket，MIT）
   ├─ omemo_dart/               # MIT；axolotl + omemo2（PQXDH/SessionCipher）
   └─ moxlib/                   # GPL-3.0
```

## 7. 不变量（Invariants，实现时必须始终成立）

1. 轨道由用户选择。程序判断可行性、如实告知后果，**不阻止、不静默替换**。消息上显示的轨道永远反映实际使用的轨道（见 [10-track-selection.md](10-track-selection.md)）。
2. PQ 会话的 root key **必须**包含 ML-KEM 的共享秘密；每条消息的消息密钥**必须**混入 SPQR 输出（libsignal v0.105.0 默认行为，不得关闭）。
3. 任何加密负载都必须是服务端可存储的合法 XML（无自定义 stanza 类型）。
4. 指纹展示：Legacy 覆盖 A 轨 Conversations 身份密钥；Hybrid（默认）覆盖 OMEMO2 经典 IK + 已发布 ML-DSA-87（与 monocles 一致）。两套 IK **分栈不共享**。
5. 私钥**永不**离开设备明文存储；Android 上由 Keystore 封存对称密钥保护落库材料，Web 走平台存储模型。
