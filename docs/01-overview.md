# 01 — 总览与关键决策

## 1. 项目目标

| # | 目标 |
|---|---|
| G1 | 基于 Flutter 的 XMPP 客户端，**Android 优先**，并提供 Web 与 Linux AppImage 构建路径 |
| G2 | 与 **标准 OMEMO 客户端**（Conversations / Moxxy / Dino / Gajim）完全互通 |
| G3 | 在双方均为本客户端且用户选定后量子轨道时，使用**后量子混合加密**（X25519 + ML-KEM-768） |
| G4 | **不修改服务端**、**不引入新 XEP**、**不依赖服务端特殊支持** |
| G5 | UI 观感与 **Telegram Android 高度一致** |
| G6 | 以 **GPLv3** 开源发布 |

## 2. 非目标（明确排除）

- ❌ 不做 Telegram 协议的客户端（不用 TDLib、不连 Telegram 服务器）——UI 只是「外观参考」。
- ❌ 不发明或提交新的 XEP。
- ❌ 不修改 Prosody / ejabberd / Openfire 等任何服务端。
- ❌ 不与标准 OMEMO 客户端共享 PQ 会话（它们不可能解密，这是物理限制）。

## 3. 硬约束

| 约束 | 含义 | 影响 |
|---|---|---|
| C1 | 服务端不可改 | 加密负载必须是服务端可存储的不透明 XML |
| C2 | 不加 XEP | 能力协商必须复用既有 XEP（PEP 0163/0060、EME 0380、disco 0030） |
| C3 | 必须互通 | 标准 OMEMO 轨道必须完整、正确 |
| C4 | 后量子 | 初始密钥协商必须混合 ML-KEM-768 |
| C5 | 移动端优先 | 密码学实现需适配 Android NDK/ABI |

## 4. 关键决策记录（ADR）

### ADR-001：双轨（标准 OMEMO + PQ 轨道）而非单一方案
- **决定**：同时实现标准 OMEMO 和 PQ-OMEMO 两条轨道；发送轨道由用户选择，可行性由 `TrackResolver` 判定（见 [10-track-selection.md](10-track-selection.md)）。
- **理由**：C3（互通）与 C4（后量子）在逻辑上互斥，除非分层。标准客户端只认 Conversations/axolotl 线格式。
- **后果**：实现与测试成本约翻倍；需要一套健壮的能力查询、提示与标签一致性规则。

### ADR-002：PQ 仅用于初始握手（PQXDH），棘轮保持经典
- **决定**：ML-KEM 只在会话建立时使用；Double Ratchet 的 DH 棘轮继续用 X25519。
- **理由**：与 Signal PQXDH 一致；会话密钥的保密性由初始 PQ 秘密保护，后续棘轮提供前向保密。避免每条消息都携带 1 KB 的 KEM 密文。
- **后果**：首条消息体积增大；需要保证 PQ 秘密确实混入 root key。

### ADR-003：能力发现复用 PEP 节点存在性，不新增 disco 特性
- **决定**：设备是否支持 PQ = 其 JID 是否在 PQ device list 中且 bundle 节点存在。
- **理由**：避免新增 XEP；PEP 是既有标准。disco 只能反映「当前在线资源」，而 bundle 是持久化的，更适合离线设备。
- **后果**：需要处理 bundle 过期/清理（服务端 max_items 与 TTL）。

### ADR-004：Fork `moxxmpp` + `omemo_dart` + `moxlib`
- **决定**：以 moxxmpp、omemo_dart、moxlib 为基础，以 git 子模块置于 `packages/`，`app` 用 path 依赖引用。
- **理由**：三者均为纯 Dart、跨平台；moxxmpp / omemo_dart 为 MIT，moxlib 为 GPL-3.0，与 GPLv3 兼容。上游不在 pub.dev，fork 删除 `publish_to`，由 `dependency_overrides` 指向本地路径。
- **要点**：
  - moxxmpp 上游：`codeberg.org/moxxy/moxxmpp`（MIT）。
  - omemo_dart 上游：`github.com/PapaTutuWawa/omemo_dart`（MIT）；A 轨走 axolotl（`omemo_dart_axolotl`）；B 轨 PQXDH/SessionCipher 走 `omemo_dart_omemo2`。
  - moxlib 上游：`codeberg.org/moxxy/moxlib`（GPL-3.0）。
  - MAM（XEP-0313）已从上游 `feat/mam` 并入 moxxmpp fork。
  - `moxxmpp_socket_tcp` 的 SDK 约束提升到 Dart 3。
  - OMEMO 密码学由 `omemo_dart` 提供，moxxmpp 做 stanza 编解码/传输；app 侧保留 PEP/XML、KMAC 载荷、ML-DSA、以及 ML-KEM 平台后端（`lib/crypto/pq/`）。
- **后果**：需跟进上游变更；A 轨保持与上游最小差异，便于合并。

### ADR-005：UI 移植 Telegram Android（Kotlin → Dart），整体 GPLv3
- **决定**：参考/翻译 TG Android 的 UI 代码与资源；不使用其名称与 Logo。
- **理由**：TG Android 是 GPLv2-or-later，可合法并入 GPLv3 工程。
- **后果**：需逐文件标注来源与修改；商标问题需人工审查。

### ADR-006：ML-KEM 用纯 Dart `pqcrypto`
- **决定**：OMEMO2 密钥材料走 `pqcrypto` ML-KEM-1024；会话层 PQXDH 走 `libsignal`（native）。
- **理由**：monocles 对齐的是 ML-KEM-1024；纯 Dart 路径与 Web/桌面一致，日常 `flutter build apk` 无额外 NDK/CMake 步骤。
- **后果**：构建路径统一；体积与许可面更小。
- **待定**：Q1（ML-DSA-65 是否默认携带）仍按「先不携带」推进。

## 5. 架构总览

```
┌──────────────────────────────────────────────────────────────┐
│              Flutter App（Android / Web / Linux）              │
│                                                               │
│  ┌───────────┐   ┌───────────────┐   ┌───────────────────┐   │
│  │  ui/      │   │  state/       │   │  store/           │   │
│  │ TG 观感   │◄─►│ Riverpod      │◄─►│ drift + SQLCipher │   │
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
│     ├─ xmpp/                  # 连接、收发、MAM prefs、MUC 等
│     ├─ omemo/                 # 双轨常量、编解码、能力、TrackResolver
│     ├─ crypto/                # 指纹、KMAC 载荷、双轨编排
│     ├─ pq/                    # MlKem1024Provider、pqcrypto
│     ├─ store/                 # drift、备份格式、平台条件导入的 DB 连接
│     ├─ state/                 # Riverpod providers
│     ├─ net/ / platform/ / l10n/
│     └─ ui/                    # 登录、会话、聊天、设置、账号管理等
└─ packages/                    # git 子模块（path 依赖）
   ├─ moxxmpp/                  # monorepo：moxxmpp + moxxmpp_socket_tcp（MIT）
   ├─ omemo_dart/               # MIT；axolotl + omemo2（PQXDH/SessionCipher）
   └─ moxlib/                   # GPL-3.0
```

## 7. 不变量（Invariants，实现时必须始终成立）

1. 轨道由用户选择。程序判断可行性、如实告知后果，**不阻止、不静默替换**。消息上显示的轨道永远反映实际使用的轨道（见 [10-track-selection.md](10-track-selection.md)）。
2. PQ 会话的 root key **必须**包含 ML-KEM 的共享秘密。
3. 任何加密负载都必须是服务端可存储的合法 XML（无自定义 stanza 类型）。
4. 指纹展示：Legacy 覆盖 A 轨 Conversations 身份密钥；Hybrid（默认）覆盖 OMEMO2 经典 IK + 已发布 ML-DSA-87（与 monocles 一致）。两套 IK **分栈不共享**。
5. 私钥**永不**离开设备明文存储；Android 上由 Keystore 封存对称密钥保护落库材料，Web 走平台存储模型。
