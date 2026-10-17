# 10 — 三轨协调：后量子 / 标准 / 无加密

本文件规定三条轨道（PQ-OMEMO、标准 OMEMO、无加密）在真实会话中如何协调。
发送策略以本文件为准；`docs/02` §6 的 `decideEncMode` 只描述**最高可达能力**提示。

## 1. 根本决定：选择权在用户

与 Conversations 一致：**用户选择加密协议，客户端负责判断可行性并如实告知后果，
但不阻止、不静默替换。**

安全模型表述见 §8 / `docs/01` §7。要点：

1. 加密强度取决于用户的明确选择与知情
2. 「程序自动降级」本身是一个攻击面：能力判定失败时静默降级会让用户不知情
3. 用户选错的后果是**他自己**的消息收不到或发不出去，代价明确且可见

## 2. 轨道标识与显示

| 轨道 | 简写 | 图标 | 含义 |
|---|---|---|---|
| 后量子 PQ-OMEMO | `PO` | 护盾带对钩 | 自研混合轨道，ResonChat 之间可读 |
| 标准 OMEMO | `OM` | 护盾 | Conversations/axolotl，第三方客户端可读 |
| 无加密 | `NO` | 叉 | 明文 |

三条轨道**不在同一条消息里混装**。一条消息两种保护强度会让接收端语义含糊，载荷接近翻倍。代价是「最小公分母」：一台设备读不了，整条消息按选定轨判定不可行。

## 3. 选择的作用域

- **全局默认**：设置项，默认 `OM`（标准）。存于 `Meta` 表，`key='global_track'`。
- **会话覆盖**：`chats.track_override`（`TEXT`，`''` 表示继承全局）。优先级高于全局默认。

新会话继承全局默认。群聊遵循同一套规则（房间侧另有 `muc.dart` 解析入口）。

## 4. 数据模型

### 4.1 全局默认

`Meta`：`key='global_track'`，`value` 为 `Track.storageToken`（如 `standard` / `pq` / `none`）。读写见 `providers.dart`。

### 4.2 会话覆盖

`chats.track_override`：空串继承全局；非空为该会话选定轨。

### 4.3 消息的实际轨道

`messages.enc_mode` 存**实际发出或入站识别到的**轨道，词表经 `EncModeToken`：`pq` / `standard` / `none` / `error`（亦接受历史别名 `pqOmemo`、`standardOmemo` 等解析）。

| 方向 | 规则 |
|---|---|
| 出站 | 写入实际发送使用的轨道 |
| 入站 | 从 EME `namespace` 与 `<encrypted>` 命名空间识别 |

## 5. EME：跨客户端传递轨道信息

「每条消息底下标出协议」依赖 EME（XEP-0380）。连接层注册 `EmeManager`；发送侧附带对应 namespace。

| EME `namespace` | 显示 |
|---|---|
| `eu.siacs.conversations.axolotl` | **OM**（Conversations 实际发送） |
| `urn:xmpp:omemo:1` / `urn:xmpp:omemo:2` | OM |
| `urn:xmpp:pomemo:0` | **PO** |
| 无 `<encryption>` 元素 | NO |

未知 namespace 落 `NO`，不崩溃。

## 6. `TrackResolver`：唯一判定入口

实现：`app/lib/crypto/omemo/track_resolver.dart` 的 `resolveTrack`。

```
resolveTrack(requested, capabilities) -> TrackResolution {
  track:    始终等于 requested（从不改写选择）,
  blocked:  null | unknownPeers | unreachableDevices
            | standardUnavailable | pqUnavailable,
  canSend:  blocked == null,
  alternative: 弹窗可建议的替代轨（须用户确认）,
}
```

`desired` 与可行性分离：可行性只检查，**不修改**用户选择。

规则摘要：

- `requested == none` → 可发（警告在 UI 选定时刻）
- 能力快照缺失或 `!reliable` → `unknownPeers`，阻断
- `standard`：全部收件设备具备可用 OMEMO，否则 `standardUnavailable`
- `pq`：全部收件设备具备可用 PQ，否则 `pqUnavailable`

## 7. 发送流程

```
desired = none
  └ 本会话未确认过 → 危险警告（可继续）→ 明文，enc_mode='none'

desired = standard
  ├ 收件设备全部支持 OMEMO → 标准 OMEMO，enc_mode='standard'
  └ 否则 → 弹窗说明谁不可用；用户改选 NO 后才能明文发出

desired = pq
  ├ 全部设备 PQ 可用 → 尝试发送
  │   ├ 成功 → enc_mode='pq'
  │   └ 失败 → **不发**，弹窗报错，给「重试 / 改用 OM」
  └ 否则 → 弹窗「对方将完全看不到这条消息」；用户可改选 OM
```

**贯穿全流程：标签与实际发出的轨道必须一致。** PQ 发送失败时不产生任何消息。

### 7.1 两类失败必须分开，措辞不能混

| 场景 | 弹窗主体 | 副行 |
|---|---|---|
| 对方解不开（能力问题） | **对方将完全看不到这条消息**（PQ）或说明明文是唯一可读路径（OM） | 列出卡住的设备与原因 |
| 我们发送失败（bundle 抓不到、竞态冲突） | **消息没有发出去** | 原因 + 「重试」/「改用 OM」 |

## 8. 能力变化：不自动切换，只提示

对方新增支持 PQ 的设备、或掉了设备时：

- 升级方向：会话页出现一次性提示条「现在可以使用后量子」+「切换」按钮
- 降级方向：立刻说明哪台设备掉了

**不自动改设置。**

## 9. UI

### 9.1 顶栏 EncBadge → 协议选择弹层

三行 PO / OM / NO；底部「设为全局默认」。实现见 `track_dialogs.dart`。

### 9.2 气泡下方标识

`PO` / `OM` / `NO`，与时间戳同行。入站解不开时标签仍反映对方实际使用的协议（EME），并保留占位符。

### 9.3 加密信息页

同时给出：

- 当前：用户选定轨
- 最高可达：`decideEncMode` / 能力服务结果，并说明卡住的设备

## 10. 不变量（与 docs/01 §7 对齐）

> 轨道由用户选择。程序负责判断可行性、如实告知后果（对方是否会完全收不到），
> **不阻止、不静默替换**。消息上显示的轨道永远反映实际使用的轨道。

> 任何情况下都不得出现「标签标着 PQ 而实际发出的是 OM」这类不一致；发送失败
> 就不发送。

其余：不变量 2（PQ root key 含 ML-KEM）、3（合法 XML）、4（A 轨指纹可跨客户端核对）、5（私钥不落明文）。

## 11. 测试

| # | 断言 |
|---|---|
| 1 | 标签一致性：∀ 消息 `enc_mode` == 实际发出的轨道；PQ 发送失败时不产生消息 |
| 2 | EME 映射全覆盖；未知 namespace 落 `NO` 不崩溃 |
| 3 | 会话覆盖优先于全局默认 |
| 4 | PQ 发送失败 → 不发 + 报错 |
| 5 | 入站 EME 说是 PQ 但解不开 → 保留 `PO` 标签 + 占位符 |
| 6 | 能力变化只提示、不改设置 |
| 7 | 无加密的确认状态按会话记忆 |
| 8 | 选定 PO/OM 但有设备不支持 → 阻断直至用户改选 |
| 9 | `Meta` `global_track` + `chats.track_override` 读写往返 |

覆盖见 `app/test/crypto/track_*.dart` 等。

## 12. 实现清单

1. EME 收发双向 + namespace 映射
2. `enc_mode` / `EncModeToken` 语义
3. 轨道设置存储（`global_track` + `track_override`）
4. `TrackResolver`
5. 发送流程 + 两类弹窗
6. 气泡标识 + 顶栏选择器
7. 能力变化提示
8. 单元与集成测试
