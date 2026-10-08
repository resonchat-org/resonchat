# 02 — 双轨 OMEMO 协议规范（核心）

本文档定义本客户端使用的两套端到端加密轨道。

- **A 轨：Conversations 互通 OMEMO**（XEP-0384 **0.3.0** / axolotl，命名空间 `eu.siacs.conversations.axolotl`；AES-128-GCM + libsignal）——与 Conversations 等主流客户端互通。实现见 `packages/omemo_dart/lib/omemo_dart_axolotl.dart`；PEP 方言见 `app/lib/omemo/defacto.dart`。
- **B 轨：PQ-OMEMO / pomemo**（命名空间 `urn:xmpp:pomemo:0`）——本项目私有，后量子混合。底层经典 Double Ratchet 对齐 XEP-0384 **0.9.1**（`omemo_dart.dart`：AES-256-CBC+HMAC / OMEMO protobuf）。

两轨差异在**握手算法**、**消息命名空间**与 **A 轨身份密钥线格式**（A：Curve25519/libsignal；B：复用经典 Ed25519+X25519 材料 + ML-KEM）。

---

## 1. 命名空间与 PEP 节点

| 用途 | A 轨（Conversations / 0.3.0，主） | A 轨（XEP-0384 v2，辅） | B 轨（PQ） |
|---|---|---|---|
| 加密消息元素 | `eu.siacs.conversations.axolotl` | （同左方言优先） | `urn:xmpp:pomemo:0` |
| 设备列表节点 | `eu.siacs.conversations.axolotl.devicelist` | `urn:xmpp:omemo:2:devices` | `urn:xmpp:pomemo:0:devices` |
| Bundle 节点 | `eu.siacs.conversations.axolotl.bundles:<id>` | `urn:xmpp:omemo:2:bundles` | `urn:xmpp:pomemo:0:bundles` |
| EME 声明 | `namespace='eu.siacs.conversations.axolotl'` | `urn:xmpp:omemo:1` / `:2` | `namespace='urn:xmpp:pomemo:0'` |

> B 轨使用独立节点，避免污染 A 轨的设备列表（否则标准客户端会尝试给我们的 PQ bundle 发消息并失败）。

## 2. 密钥体系

### 2.1 标识

| 密钥 | A 轨 | B 轨 | 用途 |
|---|---|---|---|
| IK | Curve25519（libsignal，指纹为 66 hex） | IK_dh X25519 + IK_sig Ed25519 | 身份 |
| 指纹 | `hex(serialize(IK))`（含 `0x05`） | SHA-256(IK_dh) 分组 hex | UI 核对 |

A/B 轨身份密钥**不强制同一私钥**（A 为 axolotl 设备，B 为 PQ 设备）；跨客户端核对指纹时以 A 轨 Conversations 指纹为准。

### 2.2 A 轨（OMEMO 0.3.0 / Conversations）

- IK：Curve25519（libsignal，线格式 33 字节含 `0x05`）
- SPK / OPK：X25519，经 XEdDSA 风格签名（libsignal）
- 握手 / 棘轮：libsignal SessionBuilder / SessionCipher（`PreKeySignalMessage` / `SignalMessage`）
- 载荷：AES-128-GCM，auth-tag 拼入 per-device key（Conversations `PUT_AUTH_TAG_INTO_KEY`）

### 2.3 B 轨（PQ-OMEMO）

| 密钥 | 算法 | 说明 |
|---|---|---|
| PQSPK | **ML-KEM-768** | 签名预密钥，由混合签名保护 |
| PQOPK | **ML-KEM-768** | 一次性预密钥，批量上传，用后即弃 |
| 签名 | **混合**：Ed25519 ‖ ML-DSA-65 | 同时覆盖经典与后量子可信性 |

- PQSPK/PQOPK 的公钥各 **1184 字节**，密文 **1088 字节**。
- Bundle 中同时携带 A 轨与 B 轨密钥（见 §4），因此单个设备只需一个 bundle 节点。

## 3. B 轨握手：PQXDH

对 Alice → Bob 的会话初始化（沿用 Signal PQXDH 结构）：

```
输入：
  IK_A, IK_B        双方 X25519 身份密钥
  EK_A              Alice 一次性 X25519 临时密钥
  SPK_B             Bob 的 X25519 签名预密钥
  OPK_B             Bob 的 X25519 一次性预密钥（可选）
  PQSPK_B           Bob 的 ML-KEM-768 签名预密钥
  PQOPK_B           Bob 的 ML-KEM-768 一次性预密钥（可选）

DH1 = DH(IK_A,  SPK_B)
DH2 = DH(EK_A,  IK_B)
DH3 = DH(EK_A,  SPK_B)
DH4 = DH(EK_A,  OPK_B)          # 若 OPK_B 存在

# 后量子部分（对同一目标做两次封装以提升安全裕度，可选其一）
(ct1, ss1) = ML-KEM.Encaps(PQSPK_B)
(ct2, ss2) = ML-KEM.Encaps(PQOPK_B)   # 若 PQOPK_B 存在

F  = 32 字节 0xFF 前缀（域分隔，与 Signal 一致）

SK = HKDF-SHA512(
        ikm  = F ‖ DH1 ‖ DH2 ‖ DH3 ‖ DH4 ‖ ss1 ‖ ss2,
        salt = 全零(32) ,
        info = "urn:xmpp:pomemo:0:pqxdh"
     )  -> 64 字节

(root_key, chain_key) = SK[0..32], SK[32..64]
```

**线路上需要传输**（放在首条消息的 per-device key 中）：
`EK_A` 公钥、`SPK_B`/`OPK_B` 的 id、`PQSPK_B`/`PQOPK_B` 的 id、`ct1`（与可选 `ct2`）。

**Bob 侧**用相同公式重算 `SK`，用对应的私钥解封装。若 id 指向的一次性预密钥已被消耗，则退回使用 PQSPK/SPK。

> **安全论证**：`root_key` 含 `ss1/ss2`，量子攻击者若要还原会话密钥，必须破解 ML-KEM；经典攻击者则需破解 X25519。二者任一安全，则握手安全。后续棘轮从前一 root 派生，故 PQ 安全性贯穿整个会话。

## 4. Bundle 内容（B 轨）

B 轨 bundle 节点 `urn:xmpp:pomemo:0:bundles`，每个设备一个 item：

```xml
<bundle xmlns="urn:xmpp:pomemo:0" device="4242">
  <!-- A 轨部分（保证标准客户端也能从这里取到经典密钥） -->
  <spk id="1">base64(X25519 SPK 32B)</spk>
  <spsk>base64(Ed25519 sig 64B)</spsk>
  <prekeys>
    <pk id="10">base64(X25519 OPK 32B)</pk>
    <pk id="11">base64(X25519 OPK 32B)</pk>
  </prekeys>

  <!-- B 轨后量子部分 -->
  <pqspk id="1">base64(ML-KEM-768 pk 1184B)</pqspk>
  <pqspks>base64(hybrid sig: Ed25519 64B ‖ ML-DSA-65 3309B)</pqspks>
  <pqprekeys>
    <pqpk id="20">base64(ML-KEM-768 pk 1184B)</pqpk>
  </pqprekeys>
</bundle>
```

- 建议预密钥池大小：X25519 OPK 100 个、ML-KEM OPK 20 个（后者体积大，按需补充）。
- 服务端 PEP `max_items` 与单 item 大小需实测；必要时把 bundle 拆分为经典/后量子两个节点。

## 5. 加密消息元素（B 轨）

```xml
<encrypted xmlns="urn:xmpp:pomemo:0">
  <header sid="SENDER_DEVICE_ID">
    <keys>
      <!-- 每个接收设备一个；kex="true" 表示携带握手参数 -->
      <key rid="RECV_DEVICE_ID" kex="true">
        <ek>base64(X25519 EK_A 32B)</ek>
        <spkid>1</spkid>
        <pkid>10</pkid>
        <pqspkid>1</pqspkid>
        <pqpkid>20</pqpkid>
        <pqct>base64(ML-KEM-768 ct 1088B)</pqct>
        <wrap>base64(AES-256-GCM(message_key) 16+16B)</wrap>
      </key>
      <!-- 已建立会话的设备：无 kex 参数 -->
      <key rid="OTHER_DEVICE_ID">
        <wrap>base64(AES-256-GCM(message_key))</wrap>
      </key>
    </keys>
    <iv>base64(12B)</iv>
  </header>
  <payload>base64(AES-256-GCM 密文 ‖ 16B tag)</payload>
</encrypted>
```

**流程**

1. 发送方生成随机 `message_key`（32B）与 `iv`（12B）。
2. 对**每个**接收设备：
   - 若已有会话：用当前 sending chain key 加密 `message_key` → `wrap`。
   - 若无会话（kex 消息）：执行 §3 PQXDH，派生 `root_key/chain_key`，用 chain key 加密 `message_key` → `wrap`，并附带握手参数。
3. 用 `message_key` 对明文做 AES-256-GCM，结果放 `<payload>`。
4. 明文同时在 `<body>` 中给出降级提示（见 §7）。

**A 轨**线格式为 Conversations axolotl：命名空间 `eu.siacs.conversations.axolotl`，`key` 内不含 PQ 字段，握手为 libsignal X3DH；载荷 AES-128-GCM（auth-tag 拼入 per-device key）。规范节点 `urn:xmpp:omemo:2` 同时发布/读取作辅路径。

## 6. 能力天花板与发送策略

`decideEncMode` / `CapabilityService` 根据对端设备列表与 bundle 计算**当前最高可达轨道**（PQ → 标准 OMEMO → 无），供 UI 提示与能力变化横幅使用。四个 PEP 节点（两种 A 轨方言 × 两轨）任一变更即失效缓存。

**发送哪条轨**由用户全局默认与会话覆盖决定，经 `resolveTrack` 对照能力快照；不可行则阻断发送并说明原因，由用户改选。完整规则见 [10-track-selection.md](10-track-selection.md)。

**接收**：解析 `<encrypted>` 的命名空间决定用哪条轨道解密。两条轨道都必须始终可用。

**UI 呈现**：顶栏协议选择 + 气泡旁 `PO` / `OM` / `NO` 标识；「加密信息」页展示当前选择、最高可达、指纹与设备列表。

## 7. EME 声明与降级

在加密消息中同时附带（XEP-0380，既有标准）：

```xml
<encryption xmlns="urn:xmpp:eme:0"
            namespace="urn:xmpp:pomemo:0"
            name="OMEMO-PQ"/>
<body>This message is encrypted. Use a supported client to read it.</body>
```

标准客户端看到未知命名空间时会展示 `<body>` 的降级文案，而不会崩溃。

## 8. 信任模型

| 机制 | 说明 |
|---|---|
| TOFU | 首次见到的身份密钥记为可信 |
| BTBV | 逐会话逐设备信任标记（类似 Conversations） |
| 指纹验证 | 手动比对 / QR 扫码；**跨客户端核对以 A 轨 axolotl 指纹为准**（A/B 身份密钥材料相互独立） |
| 变更告警 | 身份密钥变化时高亮警告并要求重新确认 |

## 9. 待定项

- ML-DSA-65 签名的公开密钥/签名体积较大（pk 1952B / sig 3309B），是否在 bundle 中默认携带需权衡；可先只签经典部分，PQ 部分用「TOFU + 一次性预密钥」缓解。
- 是否需要 `ct2`（双封装）——安全裕度 vs 体积。
- 群聊（MUC）下的 fan-out 策略与成员设备发现频率。
