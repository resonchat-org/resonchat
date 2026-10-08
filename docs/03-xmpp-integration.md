# 03 — XMPP 集成层

基础库：**moxxmpp**（MIT，git 子模块 `packages/moxxmpp`，path 依赖 `packages/moxxmpp/packages/moxxmpp`）。

## 1. 依赖能力（moxxmpp 已具备）

| 功能 | XEP | 用途 |
|---|---|---|
| 连接/SASL | XEP-0368, SASL SCRAM-SHA-256（及强度降级） | 认证 |
| 传输 | TCP + SOCKS5（原生）；RFC 7395 WebSocket + XEP-0156（Web，在 moxxmpp 内） | 建连 |
| Roster | RFC 6121 | 联系人（含版本控制；无变更时保留本地缓存） |
| 消息回执 | XEP-0184 | 送达状态 |
| 输入状态 | XEP-0085 | 「正在输入」 |
| 已读标记 | XEP-0333 | displayed |
| 历史归档 | XEP-0313 (MAM) | 历史同步（fork 已并入上游 `feat/mam`）；归档消息带 `MAMData` |
| 消息副本 | XEP-0280 (Carbons) | 多设备同步 |
| 实体能力 | XEP-0115 | 缓存能力（辅助） |
| 服务发现 | XEP-0030 (disco) | 能力查询（辅助） |
| PEP | XEP-0163 | 发布/订阅设备与 bundle |
| PubSub | XEP-0060 | PEP 底层 |
| 加密标记 | XEP-0380 (EME) | 加密方式声明（`EmeManager` 已注册） |
| 加密 | XEP-0384 / Conversations axolotl | A 轨 |
| MUC | XEP-0045 | 群聊 |

应用侧另有 **MAM 保留策略**（`urn:xmpp:mam:prefs:0`，`app/lib/xmpp/mam_prefs.dart`）与**多账号枢纽**（`app/lib/account/`）。

## 2. PEP 节点清单

| 节点 | 轨道 | 内容 | max_items | 访问模型 |
|---|---|---|---|---|
| `eu.siacs.conversations.axolotl.devicelist` | A（主） | `<list><device id=…/></list>` 方言 | 1 | open |
| `eu.siacs.conversations.axolotl.bundles:<id>` | A（主） | 每设备一个 bundle | 依设备数 | open |
| `urn:xmpp:omemo:2:devices` | A（辅） | 规范设备列表 | 1 | open |
| `urn:xmpp:omemo:2:bundles` | A（辅） | 规范 bundle | 依设备数 | open |
| `urn:xmpp:pomemo:0:devices` | B | PQ 设备列表 | 1 | open |
| `urn:xmpp:pomemo:0:bundles` | B | 含经典 + PQ 字段的 bundle | 依设备数 | open |

**要点**

- 访问模型设为 `open`（`presence` 会导致离线设备取不到 bundle）。
- 设备列表节点用「单 item 覆盖」方式更新（真实客户端常见 item id `current`；解析时谁能读就用谁）。
- Bundle 节点的 item id = 设备 id（或 `current`，按对端实际）。
- 服务端 `max_items` 默认可能不足；若不支持足够 item 数，退化为「设备列表 + 独立 bundle 节点」方案。
- A 轨公钥线格式为 libsignal 33 字节（`0x05` 前缀）；读写时剥/加前缀，见 `defacto.dart`。

## 3. 上线流程（序列）

```
1. 连接并完成 SASL
2. 绑定资源，发送初始 presence
3. 加载/生成本地设备密钥（A 轨 axolotl + B 轨 IK/SPK/OPK/PQSPK/PQOPK）
4. 发布 A 轨设备列表与 bundle（axolotl 主节点 + 规范辅节点）
5. 发布 B 轨设备列表与 bundle（含 PQ 字段）
6. 订阅联系人的相关 PEP 节点，接收变更通知
7. 拉取 roster，并对账户 MAM 归档做 catch-up（XEP-0313：本端 bare JID + RSM `after`，首登无游标时用近 5 天 `start`，页大小 50 / 最多约 750 条，对齐 Conversations）
8. 初始化数据库中的会话状态
```

**设备 id**：随机 31 位正整数（与 OMEMO 一致），持久化，不随重装保留（重装即新设备）。

## 4. 发送一条加密消息

```
UI 提交明文 + 用户选定 Track（会话覆盖 ?: 全局默认）
   │
   ▼
[TrackResolver] resolveTrack(requested, capabilities)
   │
   ├─ canSend → 按 requested 加密（pq / standard / none）
   └─ blocked → 弹窗说明后果与可选替代轨，用户改选后再发
   │
   ▼
构造 <message type='chat'>
  <body>降级文案</body>
  <encryption xmlns='urn:xmpp:eme:0' .../>
  <encrypted xmlns='…'/>   <!-- axolotl 或 urn:xmpp:pomemo:0 -->
  <store xmlns='urn:xmpp:hints'/>
   │
   ▼
moxxmpp 发送 → 服务端转发 → 各设备
   │
   ▼
本地写入数据库（enc_mode = 实际发出的轨道）
```

**注意 Carbons**：给「己方其他设备」也要各生成一份 `<key>`，否则多设备看不到自己的消息。moxxmpp 的 OMEMO 管理器已处理此逻辑，B 轨平行实现。

`ShouldEncrypt` 回调只对 `message` 回答，避免为每个 PubSub IQ 再发能力查询形成级联。

## 5. 接收一条加密消息

```
收到 <message>
   │
   ├─ 含 <encrypted xmlns='eu.siacs.conversations.axolotl'> → A 轨解密
   ├─ 含 <encrypted xmlns='urn:xmpp:omemo:2'>（若出现）→ A 轨辅路径
   ├─ 含 <encrypted xmlns='urn:xmpp:pomemo:0'> → B 轨解密
   └─ 无 encrypted → 明文
   │
   ▼
解密得明文 + 发送方设备信息；enc_mode 从 EME / 命名空间写入
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

缓存策略：订阅 PEP 通知；收到变更即失效缓存。为避免每条消息都拉网络，内存缓存 + 短 TTL，并在发送失败时强制刷新重试一次。`CapabilityService` 带并发去重与 `reliable` 标记：查询失败不得当作「可发明文」。

## 7. 与标准 OMEMO 的差异处理

| 场景 | 处理 |
|---|---|
| 用户选 OM，对方有 A 轨 | 走 A 轨；气泡标 `OM` |
| 用户选 PO，对方全部设备 PQ 可用 | 走 B 轨；气泡标 `PO` |
| 用户选 PO，存在非 PQ 设备 | `TrackBlocked.pqUnavailable`：阻断发送，提示改用 OM |
| 用户选 OM，存在无 OMEMO bundle 的设备 | `TrackBlocked.standardUnavailable`：阻断，提示改用 NO |
| 能力快照不可靠 | `TrackBlocked.unknownPeers`：阻断，直至可读 |
| 收到未知设备的 A 轨消息 | 正常解密（双轨都实现） |
| 收到 B 轨消息但己方无对应私钥 | 「无法解密」占位，标签仍反映 EME |

## 8. 服务端兼容性测试清单

| 服务端 | 必测项 |
|---|---|
| Prosody (mod_pep) | PEP 节点创建/覆盖、bundle item 数、stanza 大小上限 |
| ejabberd | 同上 + Carbons + MAM |
| Openfire | 同上 |
| 自建（可选） | 同上 |

关键指标：单条 `<message>` 的字节数不得超过服务端限制（一般为 64KB 以上，但需实测）；B 轨首条消息在有 N 个设备时约为 `N × 1.2KB + 明文`，N=10 时约 12KB，需重点验证。
