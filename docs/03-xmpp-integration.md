# 03 — XMPP 集成层

基础库：**moxxmpp**（MPL-2.0，fork 至 `packages/moxxmpp`）。

## 1. 依赖能力（moxxmpp 已具备）

> 补充（2026-10 实测）：上表 `MAM (XEP-0313)` 一项**上游 master 并不存在**——moxxmpp master 无 `xep_0313.dart`，未合并的实现位于上游 `feat/mam` 分支。本项目已从该分支取增量并入 fork（详见 `packages/README.md`），集成后按 XEP-0313 拉取历史，归档消息携带 `MAMData` 扩展（含原始发送时间），与实时消息走同一条解密与入库管线。其余项（Carbons、PubSub/PEP、EME、0384、0045、0085、0184、0030）已核实存在。
>
> 另：OMEMO 相关代码已核实在 moxxmpp `lib/src/xeps/xep_0384/`，命名空间为 `urn:xmpp:omemo:2`（与 docs/02 一致）。

| 功能 | XEP | 用途 |
|---|---|---|
| 连接/SASL | XEP-0368, SASL SCRAM-SHA-256 | 认证 |
| Roster | RFC 6121 | 联系人 |
| 消息回执 | XEP-0184 | 送达状态 |
| 输入状态 | XEP-0085 | 「正在输入」 |
| 历史归档 | XEP-0313 (MAM) | 历史同步（经 fork 并入上游 `feat/mam`） |
| 消息副本 | XEP-0280 (Carbons) | 多设备同步 |
| 实体能力 | XEP-0115 | 缓存能力（辅助） |
| 服务发现 | XEP-0030 (disco) | 能力查询（辅助） |
| PEP | XEP-0163 | 发布/订阅设备与 bundle |
| PubSub | XEP-0060 | PEP 底层 |
| 加密标记 | XEP-0380 (EME) | 加密方式声明 |
| 加密 | XEP-0384 | A 轨 |
| MUC | XEP-0045 | 群聊（后期） |

## 2. PEP 节点清单

| 节点 | 轨道 | 内容 | max_items | 访问模型 |
|---|---|---|---|---|
| `urn:xmpp:omemo:2:devices` | A | `<devices><device id=…/></devices>` | 1 | open |
| `urn:xmpp:omemo:2:bundles` | A | 每设备一个 bundle item | 依设备数 | open |
| `urn:xmpp:pomemo:0:devices` | B | 同上 | 1 | open |
| `urn:xmpp:pomemo:0:bundles` | B | 含 PQ 字段的 bundle | 依设备数 | open |

**要点**

- 访问模型设为 `open`（`presence` 会导致离线设备取不到 bundle）。
- 设备列表节点用「单 item 覆盖」方式更新（item id 固定，如 `current`），避免竞态。
- Bundle 节点的 item id = 设备 id。
- 服务端 `max_items` 默认可能不足；若不支持足够 item 数，退化为「设备列表 + 独立 bundle 节点」方案。

## 3. 上线流程（序列）

```
1. 连接并完成 SASL
2. 绑定资源，发送初始 presence
3. 加载/生成本地设备密钥（IK_dh/IK_sig/SPK/OPK/PQSPK/PQOPK）
4. 发布 A 轨设备列表（把自己的 device id 加入）
5. 发布 A 轨 bundle（SPK + 签名 + OPK 池）
6. 发布 B 轨设备列表
7. 发布 B 轨 bundle（含 PQSPK/PQOPK/hybrid sig）
8. 订阅联系人的 4 个 PEP 节点，接收变更通知
9. 拉取 roster，并对账户 MAM 归档做 catch-up（XEP-0313：本端 bare JID + RSM `after`，首登无游标时用近 5 天 `start`，页大小 50 / 最多约 750 条，对齐 Conversations）
10. 初始化数据库中的会话状态
```

**设备 id**：随机 31 位正整数（与 OMEMO 一致），持久化，不随重装保留（重装即新设备）。

## 4. 发送一条加密消息

```
UI 提交明文
   │
   ▼
[omemo 管理器] 计算 EncMode（见 02 文档 §6）
   │
   ├─ mode = pqOmemo       → 用 B 轨加密
   ├─ mode = standardOmemo → 用 A 轨加密
   └─ mode = none          → 提示用户
   │
   ▼
构造 <message type='chat'>
  <body>降级文案</body>
  <encryption xmlns='urn:xmpp:eme:0' .../>
  <encrypted xmlns='urn:xmpp:pomemo:0'>…</encrypted>
  <store xmlns='urn:xmpp:hints'/>          <!-- 请求服务端归档 -->
   │
   ▼
moxxmpp 发送 → 服务端转发 → 各设备
   │
   ▼
本地写入数据库（加密后的 payload + 明文缓存，视设置）
```

**注意 Carbons**：给「己方其他设备」也要各生成一份 `<key>`，否则多设备看不到自己的消息。moxxmpp 的 OMEMO 管理器已处理此逻辑，B 轨需平行实现。

## 5. 接收一条加密消息

```
收到 <message>
   │
   ├─ 含 <encrypted xmlns='urn:xmpp:omemo:2'>  → A 轨解密
   ├─ 含 <encrypted xmlns='urn:xmpp:pomemo:0'> → B 轨解密
   └─ 无 encrypted                             → 明文
   │
   ▼
解密得明文 + 发送方设备信息
   │
   ▼
更新会话棘轮状态、解密状态（成功/失败/未知设备）
   │
   ▼
写入数据库并推送 UI
```

解密失败时**不得**崩溃或丢弃消息：显示「无法解密」占位，保留原始 payload 以便设备密钥恢复后重试（OMEMO 常见问题，需专门处理）。

## 6. 能力协商的具体实现

```
Future<Set<int>> _getPqCapableDevices(Jid jid) async {
  final devices = await _pep.getDevices(jid, PqOmemo.namespace);   // B 轨设备列表
  if (devices == null) return {};
  final result = <int>{};
  for (final d in devices) {
    final bundle = await _pep.getBundle(jid, PqOmemo.namespace, d.id);
    if (bundle != null && bundle.hasPqKeys) result.add(d.id);
  }
  return result;
}
```

缓存策略：订阅 PEP 通知；收到变更即失效缓存。为避免每条消息都拉网络，内存缓存 + 短 TTL（如 5 分钟），并在发送失败时强制刷新重试一次。

## 7. 与标准 OMEMO 的差异处理

| 场景 | 处理 |
|---|---|
| 对方只有 A 轨 | 走 A 轨；UI 显示 `🔒 OMEMO` |
| 对方 A+B 轨 | 走 B 轨；UI 显示 `🔒 PQ` |
| 对方 A 轨设备 + B 轨设备混合 | 整条走 A 轨（回退），保证全部可解 |
| 收到未知设备的 A 轨消息 | 正常解密（双轨都实现） |
| 收到 B 轨消息但己方无对应私钥 | 尝试用目标设备私钥；失败则「无法解密」 |

## 8. 服务端兼容性测试清单

| 服务端 | 必测项 |
|---|---|
| Prosody (mod_pep) | PEP 节点创建/覆盖、bundle item 数、stanza 大小上限 |
| ejabberd | 同上 + Carbons + MAM |
| Openfire | 同上 |
| 自建（可选） | 同上 |

关键指标：单条 `<message>` 的字节数不得超过服务端限制（一般为 64KB 以上，但需实测）；B 轨首条消息在有 N 个设备时约为 `N × 1.2KB + 明文`，N=10 时约 12KB，需重点验证。
