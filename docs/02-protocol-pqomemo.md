# 02 — 双轨 OMEMO 协议规范（核心）

本文档定义本客户端使用的两套端到端加密轨道。

- **A 轨：Conversations / legacy OMEMO**（XEP-0384 **0.3.0** / axolotl，`eu.siacs.conversations.axolotl`；AES-128-GCM + libsignal）——与 Conversations、monocles legacy 互通。
- **B 轨：monocles PQ-OMEMO2**（`urn:monocles:omemo-pq:1`）——与 monocles 后量子栈对齐（ML-KEM-1024、ML-DSA-87 `pq-ik`/`pq-sig`、KMAC 载荷/commit）。规范见 `references/monocles_chat/docs/proto-xep-omemo-pqxdh.md`。

两轨**密钥分栈**：OMEMO2 经典 IK ≠ A/legacy IK（与 monocles 一致）。UI Hybrid 指纹 = SHA3-512(`monocles:omemo2:ik:v2` ‖ OMEMO2 IK.serialize ‖ ML-DSA-87)；Legacy = A 轨 Conversations 指纹。

---

## 1. 命名空间与 PEP 节点

| 用途 | A 轨（Conversations / 0.3.0） | B 轨（PQ-OMEMO2 / monocles） |
|---|---|---|
| 加密消息元素 | `eu.siacs.conversations.axolotl` | `urn:monocles:omemo-pq:1` |
| 设备列表节点 | `eu.siacs.conversations.axolotl.devicelist` | `urn:monocles:omemo-pq:1:devices` |
| Bundle 节点 | `eu.siacs.conversations.axolotl.bundles:<id>` | `urn:monocles:omemo-pq:1:bundles` |
| EME 声明 | `eu.siacs.conversations.axolotl` | `urn:monocles:omemo-pq:1` |

> B 轨使用独立节点，避免污染 A 轨设备列表。刻意**不是** `urn:xmpp:omemo:2`。

## 2. 密钥体系

### 2.1 标识

| 密钥 | A 轨（legacy） | B 轨（OMEMO2） | 用途 |
|---|---|---|---|
| IK | Curve25519（libsignal） | **独立** Curve25519 + Ed25519 | 身份（分栈） |
| PQ IK | — | **ML-DSA-87**（上线 `pq-ik`） | hybrid 指纹 / bundle 签名 |
| 指纹 | `hex(serialize(IK))` 去 `05` | SHA3-512 hybrid（IK + pq_ik） | UI 核对 |

### 2.2 A 轨（OMEMO 0.3.0 / Conversations）

- IK：Curve25519（libsignal，线格式 33 字节含 `0x05`）
- SPK / OPK：X25519，经 XEdDSA 风格签名（libsignal）
- 握手 / 棘轮：libsignal SessionBuilder / SessionCipher
- 载荷：AES-128-GCM

### 2.3 B 轨（PQ-OMEMO2 / monocles）

| 密钥 | 算法 | 说明 |
|---|---|---|
| kem-spk / kem-pk | **ML-KEM-1024**（wire tag `0x0A`） | 非身份；拒 Round-3 `0x08` |
| pq-ik / pq-sig | **ML-DSA-87** | 签 transcript（context `monocles:omemo2:pqid:v1`） |
| 载荷 | AES-256-GCM + **KMAC256** | labels `payload:v3` / `key-commitment:v3` |

- ML-KEM-1024 公钥 **1568** 字节，密文 **1568** 字节；wire 公钥为 `0x0A ‖ pk`。
- Bundle 元素：`spk`/`spks`/`ik`/`prekeys`/`kem-spk`/`kem-spks`/`kem-prekeys`/`pq-ik`/`pq-sig`。

## 3. B 轨握手：PQXDH（libsignal 参数，proto-XEP §5.3）

握手与 `<key>` 密文由 `omemo_dart` 的 `Omemo2Manager`（`package:libsignal` FFI）实现，对齐 libsignal ≥0.94：

```
secrets = 0xFF×32 ‖ DH1 ‖ DH2 ‖ DH3 ‖ [DH4 ‖] SS
HKDF-SHA-256-Extract(salt=0×32, ikm=secrets)
HKDF-Expand(info="WhisperText_X25519_SHA-256_CRYSTALS-KYBER-1024", L=96)
→ root(32) ‖ chain(32) ‖ pqr(32)

DH1=DH(IK_A,SPK_B)  DH2=DH(EK_A,IK_B)  DH3=DH(EK_A,SPK_B)
DH4=DH(EK_A,OPK_B) 若有 EC OPK
SS = ML-KEM-1024.Encaps(选中的 kem-pk 或 kem-spk)   # 仅一次 KEM
```

`<key>` 内容为 **不透明** base64：`PreKeySignalMessage` / `SignalMessage`（version 4，含 `kyber_pre_key_id` / `kyber_ciphertext`，以及 SPQR 的 `pq_ratchet` field 5）。KEM 密文在 protobuf field 8。本地需使用 `vendor/libsignal_dart` 的 ML-KEM-1024（`0x0A`）补丁构建。

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
