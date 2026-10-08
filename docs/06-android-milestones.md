# 06 — 里程碑与验收

开发顺序：通信基线（M1）→ 互通加密（M2）→ PQ（M3–M4）→ 存储/UI（M5–M6）→ 发布（M7）。

> 实时状态以根目录 [`README.md`](../README.md) / [`README.dev.md`](../README.dev.md) 为准。下文为里程碑定义与当前完成情况。

**总览：M0–M5 已完成，M6 进行中，M7 未开始。**

## M0 — 工程骨架 ✅

**任务**
- [x] Flutter 稳定版 + Android SDK/NDK 环境
- [x] 建立 mono-repo 结构（见 01 文档 §6）
- [x] fork `moxxmpp`、`omemo_dart`、`moxlib` 至 `packages/`（git 子模块）
- [x] 添加 GPLv3 LICENSE、各文件来源标注规范
- [x] GitHub Actions：analyze + test + `./tool/build_android.sh`；CD 挂 APK / AppImage

**验收**
- Android debug APK 可构建；CI 全绿

## M1 — XMPP 通信基线 ✅

**任务**
- [x] 连接、SASL SCRAM-SHA-256（及降级）、资源绑定、断线重连
- [x] roster 获取与展示（drift + RFC 6121 版本控制）
- [x] 1:1 明文消息收发
- [x] XEP-0184 送达回执、XEP-0085 输入状态、XEP-0333 已读回执
- [x] MAM（XEP-0313）历史拉取（上线 catch-up + 会话内翻页）
- [x] Carbons（XEP-0280）
- [x] 消息持久化（后续由 M5 加密）
- [x] 最小可用 UI：会话列表 + 聊天页

**验收**
- 两账号互发明文；重启后历史仍在
- 与标准 XMPP 客户端互发明文

## M2 — 标准 OMEMO 互通 ✅

**任务**
- [x] omemo_dart axolotl 集成：设备 ID、device list、bundle 发布/获取
- [x] X3DH 会话建立 + Double Ratchet（libsignal 路径）
- [x] OPK 消耗与补充、指纹、信任（TOFU + BTBV）
- [x] EME（XEP-0380）声明与 `<body>` 降级
- [x] 线格式对齐 Conversations：`eu.siacs.conversations.axolotl`、bundle 元素名、公钥 `0x05` 前缀

**验收**
- ✅ 与 **Conversations 2.20.4** 互通：本客户端加密的消息被对方解密显示（`tool/m2_verify_conversations.sh`）
- ⚠️ 反向互通（Conversations → 本客户端）待两台真实设备补齐（非双向订阅时服务端拒投递）
- 己方多设备 / Carbons 路径已接线

## M3 — PQ 内核 ✅

**任务**
- [x] liboqs NDK 交叉编译（`arm64-v8a`、`x86_64`）
- [x] Dart FFI 封装：ML-KEM-768 keygen/encaps/decaps
- [x] 纯 Dart 回退（`pqcrypto`）与共享秘密互操作测试
- [x] PQXDH + B 轨设备列表/bundle 发布
- [x] 双账号跨服务器真实互测（`tool/pq_interop.dart`）

**验收**
- FFI 与纯 Dart 共享秘密一致；设备端 `backend: liboqs (native)`
- 两本客户端建立 B 轨会话并加解密；PQ bundle 已发布到服务器

## M4 — 双轨能力与发送策略 ✅

**任务**
- [x] `decideEncMode` / `CapabilityService`（最高可达轨道、缓存、PEP 订阅失效）
- [x] 用户轨道选择 + `TrackResolver`（见 [10-track-selection.md](10-track-selection.md)）
- [x] UI：EncBadge、气泡 `PO`/`OM`/`NO`、阻断对话框
- [x] 加密信息页与能力变化提示

**验收**
- 选定轨道与实际发出一致；不可行时阻断并说明
- 能力查询失败不得当作可发明文（`reliable`）

## M5 — 存储与密钥保护 ✅（密钥备份待做）

**任务**
- [x] SQLCipher 加密数据库（口令在 Keystore）
- [x] OMEMO 设备密钥经 Keystore 封存落库
- [x] 数据库迁移与版本管理（当前 `schemaVersion` 19）
- [x] 聊天历史备份格式（`backup_format.dart`；允许列表，不含密钥材料）
- [ ] 设备密钥备份/恢复（口令派生 + AEAD）
- [ ] 「不保存明文」选项

**验收**
- 直接读数据库文件无法获得明文消息与私钥（已有验收测试）
- 密钥备份可在新设备恢复 — 待完成

## M6 — Telegram 观感 UI 🔄

**任务**
- [x] 主题 Token 与气泡 CustomPainter、会话列表两行布局
- [x] 聊天页：日期分隔、未读线、滚动到底 FAB、输入栏态
- [x] 资料页、设置页、安全页、账号管理骨架
- [ ] 附件/录音/表情完整面板
- [ ] 过渡动画、平板适配

**验收**
- 与 Telegram Android 并排对比，核心页面观感高度一致
- 无 Telegram 商标/Logo 残留

## M7 — 发布准备

**任务**
- [ ] 后台长连接（前台服务/推送策略）
- [ ] 电池优化白名单引导
- [ ] 崩溃上报（可选，需隐私说明）
- [ ] 隐私政策与开源声明（GPL 源码提供）
- [ ] 正式签名 APK + F-Droid 提交（可选）；CD 已挂 debug 签名产物
- [ ] 安全自查清单

**验收**
- 后台 30 分钟仍能收到消息
- 完整源码可复现构建

## 时间预估（粗，规划用）

| 阶段 | 人周 |
|---|---|
| M0 | 1 |
| M1 | 2–3 |
| M2 | 3–4（关键路径） |
| M3 | 3–4 |
| M4 | 2 |
| M5 | 2 |
| M6 | 4–6（最大工作量） |
| M7 | 1–2 |
| **合计** | **约 18–25 人周** |
