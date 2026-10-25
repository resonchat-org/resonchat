# 11 — PQ 发送路径与设备列表缓存（P0）

> 状态：**已定案，待实施**。本文冻结 P0 范围，只记录已确认的架构、接口契约与验收条件；实施过程中不继续扩大设计范围。

本文解决两个问题：

1. PQ 发送在设备列表和 bundle 上重复、串行地做 PEP I/O；
2. 入站解密前额外等待发送方 bundle。

不涉及 ML-KEM / ML-DSA / SPQR 算法本身，也不改变用户选择轨道的规则。轨道选择仍以 [10-track-selection.md](10-track-selection.md) 为准。

---

## 1. 问题与测量

来自真实账号发送日志：

| 发送 | 设备列表 | Bundle 拉取 | 加密/提交 |
|---|---:|---:|---:|
| `...-7` | 754 ms | 2.85 s | 145 ms |
| `...-8` | 778 ms | 2.93 s | 139 ms |
| `...-9` | 930 ms | 2.71 s | 140 ms |

入站另有一条约 **6.9 s** 的延迟：`PqMessageLayer.decrypt` 在解密前等待 `senderIkOf`，即再拉一次发送方 bundle。该值 crypto 并不使用。

根因：

1. `BTrackManager.encryptForPeers` 先读一次设备列表；
2. `DualTrackManager.loadPqDevices` 内又读一次设备列表；
3. 然后**无条件**串行拉取所有设备 bundle，即使本地已有 session；
4. `Omemo2Manager.onOutgoingStanza` 本身已经会跳过有 session 的设备，所以第 3 步大部分是重复工作；
5. 结果为 `null` 时可能静默丢掉某个已公布设备，形成“发给子集”。

Classic OMEMO 看起来快，是因为应用侧不做全量 bundle 预取，`OmemoManager` 只给没有 session 的设备取 bundle。

---

## 2. 目标与验收

| 场景 | 目标 |
|---|---|
| 5 分钟内的后续发送 | 0 次设备列表读、0 次 bundle 拉取，总耗时约 150–300 ms |
| 首次发送 / 新设备 | 最多 1 次设备列表读 + 缺失 bundle 并发拉取，约 1.3–2.0 s |
| 入站解密 | 不等待发送方 bundle |
| bundle 缺失 | 新会话材料缺失时禁止发送；不得静默发给子集 |
| PEP 变化 | 相关 peer 的缓存立即失效，下一次发送刷新一次 |

设备列表 TTL 固定为 **5 分钟**。这是已接受的性能与新鲜度取舍：PEP 通知是主要新鲜度来源；通知丢失时，不保证立即发现远端新增设备。

---

## 3. 三个集合必须严格区分

P0 中每个发送请求都同时存在三个不同概念，禁止互相反向生成：

| 名称 | 含义 | 来源 |
|---|---|---|
| `requestedJids` | 本次发送的原始目标集合 | 调用方传入的 peer/room 目标，统一规范化为 bare JID 并去重 |
| `announcedDeviceIds` | 服务端 PEP 公布的完整设备列表 | `CapabilityService` 维护的设备列表快照 |
| `allowedDeviceIds` | 本次实际允许加密的设备集合 | Resolver 经过 session、bundle、指纹、信任策略后的结果 |

约束：

- `requestedJids` **不能**由 `allowedDeviceIds.keys` 反向生成。
- `announcedDeviceIds` 保留服务器公布的完整列表，不能写入 trust 过滤后的 allowed 列表。
- `allowedDeviceIds` 可以包含空集合；空集合表示“明确没有允许设备”，不是回退信号。
- 所有 JID 在进入 Resolver 前统一转为 bare JID 并去重。

**实际加密目标**是 `allowedDeviceIds` 中“非空且未被策略排除”的 JID，也就是最终传给 vendor 的 `recipientJids`。`requestedJids` 中因明确 `untrusted` 被排除的成员保留空集合并进入报告，但不进入实际加密目标。除 explicit `untrusted` 外，空集合必须伴随 `blocked`，不能进入发送路径。

发送报告中的“实际加密目标”不等于 `requestedJids`，更不等于实际送达结果。

---

## 4. 设备列表缓存：CapabilityService 唯一负责

### 4.1 快照类型

新增：

`app/lib/crypto/dual/pq_device_list_snapshot.dart`

```dart
class PqDeviceListSnapshot {
  const PqDeviceListSnapshot({
    required this.devices,
    required this.fetchedAt,
    required this.expiresAt,
    required this.reliable,
    required this.generation,
  });

  final Set<int> devices;
  final DateTime fetchedAt;
  final DateTime expiresAt;
  final bool reliable;
  final int generation;

  bool get isFresh =>
      reliable && DateTime.now().isBefore(expiresAt);
}
```

### 4.2 唯一 owner

`CapabilityService`（`app/lib/xmpp/encryption/capabilities.dart`）是设备列表缓存和刷新请求的唯一责任方：

```dart
Future<PqDeviceListSnapshot> pqSnapshotFor(JID jid);
```

要求：

- 缓存项同时保存设备 ID、`fetchedAt`、`expiresAt`、`reliable`、`generation`。
- TTL 为 5 分钟。过期快照必须由 CapabilityService 刷新。
- PEP 更新立即失效对应 peer 的缓存。
- `forChat` 与 PQ 发送路径共用同一份 PQ 快照，不重复读取 PQ 设备列表。
- Resolver 不持有独立的设备列表读取缓存，也不直接调用 `fetchPqDeviceIds`；设备列表只通过 CapabilityService 提供的 snapshot/refresh 接口获取。Resolver 自己只保留 announced 视图和指纹缓存。

### 4.3 generation 与 in-flight

每个 peer 独立维护 generation：

- 请求开始时记录当前 generation；
- 请求返回后只有 generation 未变化才允许写缓存；
- `invalidate(peer)` 递增该 peer 的 generation，并清除缓存与 in-flight 记录；
- 旧 Future 完成时不得删除或覆盖新请求的记录。

in-flight 清理必须做身份校验，而不是无条件 `remove(key)`：

```dart
final future = _resolvePqSnapshot(jid);
_pqInflight[key] = future;
future.whenComplete(() {
  if (identical(_pqInflight[key], future)) {
    _pqInflight.remove(key);
  }
});
```

同一 peer 的并发查询共享一个 in-flight Future；invalidate 之后的新请求不得复用旧 Future。

### 4.4 过期与不可靠快照

- `reliable == false`：不得使用其中的设备 ID，必须刷新；刷新失败则发送阻断。
- `expiresAt` 已过：必须刷新，不能因为调用方传入了 `devices` 就跳过 TTL。
- 通知丢失时接受最长 5 分钟的窗口；不把“缓存未更新”当成“对方设备列表未变化”。

---

## 5. 发送路径

### 5.1 总体流程

```text
sendOnTrack / sendGroupchatOnTrack
  │
  ├─ CapabilityService.pqSnapshotFor(peer)
  │     唯一设备列表缓存；5 分钟 TTL；PEP 失效
  │
  ├─ PqPeerResolver.resolve(
  │      sessions,
  │      requestedJids,
  │      snapshots,
  │   )
  │     ├─ announcedDeviceIds：完整公布列表
  │     ├─ allowedDeviceIds：实际允许加密的设备
  │     ├─ newDevices：只包含需要新建 session 的设备
  │     └─ blocked / excluded 报告
  │
  ├─ PqMessageLayer.encrypt
  │     ├─ setPeerAnnouncedDeviceIds(announced)
  │     ├─ registerPeerBundle(newDevices)
  │     └─ encryptOutgoing(
  │            recipientJids = 实际加密目标（allowed 中非空项）,
  │            recipientDeviceIds = allowed（完整映射，含空集合）,
  │        )
  │
  └─ Omemo2Manager.onOutgoingStanza
        ├─ 全量预校验覆盖表
        ├─ 有 session：直接加密
        ├─ 无 session：从已注册 bundle 建链
        └─ 最后 commitDevice
```

### 5.2 session-aware bundle

`PqSessionManager` 新增：

```dart
Future<bool> hasSession(String jid, int deviceId);
Future<void> registerPeerBundle(PqDevice peer);
Future<void> setPeerAnnouncedDeviceIds(String jid, Iterable<int> ids);
Future<void> forgetSession(String jid, int deviceId);
```

`BTrackManager.initialise` 必须在创建 `PqSessionManager` 后立即：

```dart
await sessions.bindOwn(device);
```

否则 Resolver 调用 `hasSession` 时 `_own` 尚未绑定，会把已有 session 误判为不存在。

bundle 获取规则：

- 有 session 且指纹缓存可用：不取 bundle；
- 有 session 但需要校验指纹：取 bundle；
- 无 session：**必须**取新 bundle，不能用缓存 bundle 建立新 session；
- bundle 获取使用 `loadPqDevicesDetailed`，最多 `kBundleFetchConcurrency = 3` 并发；
- 单个 bundle 有超时（`kPqBundleDeadline`，8 秒）；
- 失败设备进入 `failed` 集合，不能静默忽略。

### 5.3 指纹

指纹只依据稳定的身份密钥材料计算：

- OMEMO2 经典 IK：`identityPublicSerialized()`；
- PQ IK：`peerPqIdentityKey`（ML-DSA-87）；
- 使用现有 `hybridOmemo2Fingerprint`。

**普通 SPK / OPK / KEM prekey 轮换不得改变指纹**，也不得触发身份变化处理或删除有效 Session。只有身份密钥材料变化才允许 `forgetSession` 并重新建链。

指纹缓存有独立 TTL（默认 30 分钟，PEP 立即失效）。设备列表的 5 分钟 TTL 不适用于指纹缓存。

Resolver 侧的 announced / 指纹缓存同样按 peer 维护 generation；PEP 失效时与 `CapabilityService` 一起清除。旧解析请求返回后 generation 不匹配则不得写回。

---

## 6. vendor 覆盖表契约

### 6.1 三态语义

`vendor/omemo_dart/lib/src/omemo2/stanza.dart`：

```dart
class Omemo2OutgoingStanza {
  const Omemo2OutgoingStanza({
    required this.recipientJids,
    required this.payload,
    this.recipientDeviceIds,
  });

  final List<String> recipientJids;
  final List<int>? payload;

  /// null：旧调用方，沿用 getDevicesFor(jid)。
  /// 非 null：必须为每个 recipientJid 提供明确授权集合。
  final Map<String, Set<int>>? recipientDeviceIds;
}
```

`Omemo2Manager.onOutgoingStanza` 中：

```dart
final overrides = stanza.recipientDeviceIds;

final List<int> devices;

if (overrides == null) {
  devices = await getDevicesFor(jid);
} else {
  devices = List<int>.from(overrides[jid]!);
}
```

但 `overrides[jid]` **不能在循环里靠 `!` 兜底**。必须在任何加密、Ratchet 状态修改和提交之前做全量预校验。

### 6.2 预校验与失败模型

在 `_lock.synchronized` 内、生成 message key / ciphertext 之前：

```dart
final overrides = stanza.recipientDeviceIds;

if (overrides != null) {
  final missing = stanza.recipientJids
      .where((jid) => !overrides.containsKey(jid))
      .toSet();

  if (missing.isNotEmpty) {
    return Omemo2EncryptionResult(
      ciphertext: null,
      commit: null,
      encryptedKeys: const {},
      deviceEncryptionErrors: {
        for (final jid in missing)
          jid: [
            EncryptToJidError(
              null,
              const MissingRecipientDeviceOverrideError(),
            ),
          ],
      },
      newSessions: const {},
      canSend: false,
    );
  }
}
```

新增错误：

```dart
class MissingRecipientDeviceOverrideError extends OmemoError {
  const MissingRecipientDeviceOverrideError();
}
```

语义：

| `recipientDeviceIds` | 当前 jid 的值 | 行为 |
|---|---|---|
| `null` | — | 旧调用方，回退 `getDevicesFor(jid)` |
| 非 null | 不包含当前 jid | 失败，`MissingRecipientDeviceOverrideError` |
| 非 null | 包含当前 jid，值为空集合 | 明确不允许该 jid 的任何设备；普通 peer 触发 `NoKeyMaterialAvailableError`，不回退 |
| 非 null | 包含当前 jid，值为 `{1}` | 只加密给设备 1 |

失败时：

- 不生成 `encryptedKeys`；
- 不建立或 ratchet 任何 session；
- 不调用 `commitDevice`；
- `canSend == false`。

**已核实**：`onOutgoingStanza` 的 `_lock.synchronized` 覆盖整个加密循环与 `commitDevice`。预校验必须放在该锁内、任何状态修改之前。

### 6.3 App 层双重校验

vendor 只能看到 `stanza.recipientJids`。如果 app 在构造覆盖表时漏掉某个 peer，并同时把它从 `recipientJids` 漏掉，vendor 无法发现。

因此 `PqMessageLayer.encrypt` 还需要独立接收 `requestedJids`：

```dart
Future<PqEncryptedOutgoing?> encrypt({
  required String plaintext,
  required List<PqDevice> recipients,
  List<String>? requestedJids,
  Map<String, Set<int>>? announcedDeviceIds,
  Map<String, Set<int>>? recipientDeviceIds,
});
```

严格模式（`recipientDeviceIds != null`）：

- `requestedJids` 必须非空；
- 每个 `requestedJids` 都必须在 `recipientDeviceIds` 中有 key；
- 每个 `recipients` 里的设备，其 JID 也必须在覆盖表中有 key；
- 空集合算“有 key”，允许通过完整性校验；
- 缺任何一个 key，直接返回 `null`，不调用 `encryptOutgoing`。

完整性校验通过后，只把覆盖表中**非空且未被策略排除**的 JID 作为实际 `recipientJids` 传给 `encryptOutgoing`。因 explicit `untrusted` 被排除的成员保留空集合用于报告，不进入 vendor；若实际目标为空，直接返回 `null`。空集合本身不能作为 vendor 的实际目标，否则会被 `NoKeyMaterialAvailableError` 阻断。

只有 `recipientDeviceIds == null` 时才允许 legacy 回退。

---

## 7. 发送策略矩阵

| 条件 | 处理 |
|---|---|
| 设备列表不可读 | 整条消息阻断 |
| 已公布设备，无 session，bundle 缺失/超时 | 整条消息阻断 |
| 有 session，bundle 刷新失败，但 trust DB 有可信旧指纹 | 允许使用现有 session；不写缓存，下次重试 |
| 有 session，bundle 刷新失败，且没有任何可信指纹 | 整条消息阻断 |
| 设备被用户明确标记 `untrusted` | 排除该设备；其他可信设备继续 |
| 设备为 `undecided` | 按既定安全策略阻断整条发送 |
| 身份无法验证 | 阻断整条发送 |
| trust DB 读写异常 | 阻断整条发送 |
| 身份密钥变化 | `forgetSession`；有可用新 bundle 时重新建链，否则阻断 |
| 群聊成员全部设备 untrusted | 排除该成员；其他合格成员继续（方案 A） |
| 群聊成员存在 undecided / 无法验证 / 缺材料设备 | 阻断整条群聊发送 |
| 排除后没有任何实际加密目标 | 整条发送失败 |

`untrusted` 是唯一允许“继续发给其他人”的设备级排除原因。`undecided` 不等同于 `untrusted`，不能按排除处理。

### 7.1 群聊方案 A

- `requestedJids` 仍保留完整原始目标，用于校验和报告；
- 明确 `untrusted` 的成员可以从实际加密目标中排除；
- 剩余合格成员继续接收；
- 如果排除后实际加密目标为空，整条发送失败；
- 报告必须描述“加密给了哪些设备/成员”，不能描述为“已送达”。

---

## 8. 发送报告

Resolver 产出：

```dart
class PqPeerResolution {
  final List<String> requestedJids;
  final Map<String, Set<int>> announcedDeviceIds;
  final Map<String, Set<int>> allowedDeviceIds;
  final List<PqDevice> newDevices;
  final Map<String, Map<int, PqDeviceExclusion>> excluded;
  final PqBlockReason? blockedReason;
  final String? blockedJid;
  final int? blockedDeviceId;
}
```

`PqDeviceExclusion` 至少包含：

- `untrusted`（允许排除并继续）；
- 其余导致阻断的状态进入 `PqBlockReason`，不放进“excluded 但仍发送”的集合。

P0 先将报告写入日志；UI 展示属于后续工作，但数据结构不得把“加密目标”命名为“送达”。

---

## 9. 入站路径

删除 `PqMessageLayer` 的 `senderIkOf` 字段、构造参数和 `decrypt` 中的等待：

```dart
await senderIkOf(senderBareJid, message.senderDeviceId);
```

更新：

- `app/lib/xmpp/encryption/b_track_manager.dart`
- `app/tool/pq_interop.dart`
- `app/test/crypto/pq_wire_roundtrip_test.dart`

如果 `DualTrackManager.deviceById` 最终没有其他调用者，一并删除，避免被重新接回发送/接收路径。

---

## 10. 涉及文件

| 文件 | 责任 |
|---|---|
| `app/lib/crypto/dual/pq_device_list_snapshot.dart` | 新增：带 TTL/generation/reliable 的设备列表快照 |
| `app/lib/crypto/omemo2/pq_peer_resolver.dart` | 新增：session-aware 设备解析、指纹/信任、blocked/excluded 报告 |
| `app/lib/xmpp/encryption/capabilities.dart` | 唯一设备列表缓存 owner、5 分钟 TTL、PEP 失效、in-flight/generation |
| `app/lib/crypto/omemo2/pq_session.dart` | `hasSession`、`registerPeerBundle`、`setPeerAnnouncedDeviceIds`、`forgetSession` |
| `app/lib/crypto/omemo2/pq_message_layer.dart` | announced/allowed 分离、`requestedJids` 校验、删除 `senderIkOf` |
| `app/lib/xmpp/encryption/b_track_manager.dart` | 接入 Resolver、初始化时 `bindOwn`、缓存失效入口 |
| `app/lib/xmpp/connection.dart` | 传递 snapshot、群聊真实目标、PEP 同时失效 caps 与 Resolver |
| `app/lib/crypto/dual/dual_track_manager.dart` | `getPqBundle` 超时、`loadPqDevicesDetailed` 并发 |
| `app/lib/crypto/dual/fingerprint_trust.dart` | 后续快路径/批量读；P0 先避免重复写 |
| `vendor/omemo_dart/lib/src/omemo2/stanza.dart` | `Omemo2OutgoingStanza.recipientDeviceIds` |
| `vendor/omemo_dart/lib/src/omemo2/manager.dart` | 三态覆盖、全量预校验、无部分提交 |
| `vendor/omemo_dart/lib/src/common/errors.dart` | `MissingRecipientDeviceOverrideError` |

---

## 11. 测试

### 11.1 单元测试

1. **TTL**：过期 snapshot 必须刷新，不能用调用方传入的旧 ID。
2. **不可靠 snapshot**：`reliable == false` 时必须刷新/阻断。
3. **generation 竞态**：旧 in-flight 在新请求开始后返回，不得写缓存；新 Future 不被旧 Future 的清理删除。
4. **请求合并**：两个并发 `pqSnapshotFor` 只产生一次读取。
5. **Resolver 不直接读设备列表**：fake provider 记录调用；Resolver 只走 provider。
6. **session-aware**：已有 session 且指纹缓存有效时，bundle 读取次数为 0。
7. **缺失 bundle**：无 session + bundle 失败 → `blocked`；有 session + 可信旧指纹 → 允许。
8. **requestedJids**：独立于 `allowedDeviceIds.keys`；缺少覆盖 key 必须失败。
9. **空集合**：空集合是明确无授权，不能回退到完整列表。
10. **指纹稳定**：轮换 SPK/OPK/KEM prekey 后指纹不变、session 保留；身份密钥变化才删除 session。
11. **群聊方案 A**：untrusted 成员可排除；undecided/无法验证/缺材料阻断整条；无实际目标时失败。
12. **入站**：删除 `senderIkOf` 后仍能解密，且不触发发送方 bundle 读取。

### 11.2 vendor 测试

1. 覆盖表缺少 peer → `canSend == false`，错误为 `MissingRecipientDeviceOverrideError`。
2. 缺少 peer 时不产生 `encryptedKeys`、不建立 session、commit 回调次数为 0。
3. 空集合 → 不回退 `getDevicesFor`，普通 peer `canSend == false`。
4. `recipientDeviceIds == null` → legacy 行为不变。
5. `_lock.synchronized` 覆盖预校验、加密循环与 `commitDevice`。

### 11.3 集成测试

- 真实账号间 PQ 互操作。
- 首次发送：列表最多一次，bundle 并发，峰值并发不超过 3。
- 连续发送：`fetched=0`、`bundle=0`。
- 对端新增设备：PEP 后下一次发送只刷新受影响 peer。
- 并发发送：同一 peer 的 in-flight 被合并；旧 generation 结果不回写。
- 入站：不再出现发送方 bundle 等待。

### 11.4 验收命令

```bash
cd app
flutter test

cd ../vendor/omemo_dart
dart test

cd ../..
cd app
flutter build linux --release
```

再执行真实账号 PQ 互操作与并发发送测试。

---

## 12. 已接受的风险与取舍

1. **设备列表 5 分钟 TTL**：PEP 通知丢失时，远端新增设备最多延迟 5 分钟被发现。已接受。
2. **首次发送仍需 bundle**：没有 session 的设备必须取新 bundle；P0 只保证并发、超时和只取缺失设备。
3. **指纹缓存独立 TTL**：默认 30 分钟；PEP 立即失效。它不是设备列表 TTL。
4. **群聊排除 untrusted 成员**：这是方案 A 的有意行为，不是“全员送达”保证。
5. **报告语义**：只报告实际加密目标，不把加密成功写成送达成功。

---

## 13. 实施顺序

1. 设备列表快照 + `CapabilityService` 唯一 owner、TTL、generation、in-flight。
2. vendor 覆盖表三态 + 预校验 + `MissingRecipientDeviceOverrideError`。
3. `PqSessionManager` / `PqMessageLayer` 的 announced/allowed 分离。
4. `PqPeerResolver` 与发送策略矩阵。
5. `BTrackManager` 接入、连接层 snapshot 传递、PEP 失效。
6. 入站 `senderIkOf` 删除。
7. 单元/vendor/集成测试与 Linux Release 构建。
8. 真实账号互操作与并发发送；按实际失败证据修复，不再扩设计。
