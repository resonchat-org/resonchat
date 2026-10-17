# ResonChat — 设计文档

Flutter XMPP 客户端：**不修改服务端、不引入新 XEP**，在标准 OMEMO 之上叠加后量子轨道（X25519 + ML-KEM-768），与 Conversations 等客户端互通；UI 采用 Telegram Android 观感。Android 优先，并提供 Web 与 Linux AppImage 构建路径。

实现状态、构建与验证以仓库根目录 [`README.md`](../README.md) 与 [`README.dev.md`](../README.dev.md) 为准。

---

## 文档索引

| 文档 | 内容 |
|---|---|
| [01-overview.md](01-overview.md) | 目标、硬约束、关键决策（ADR）、架构与仓库结构、不变量 |
| [02-protocol-pqomemo.md](02-protocol-pqomemo.md) | 双轨 OMEMO：PQXDH、棘轮、消息与 bundle 格式 |
| [03-xmpp-integration.md](03-xmpp-integration.md) | PEP、能力协商、收发流程、EME |
| [04-crypto-android.md](04-crypto-android.md) | pqcrypto / libsignal、密钥存储、依赖 |
| [05-ui-telegram.md](05-ui-telegram.md) | Telegram 观感规范、组件映射、分期 |
| [06-android-milestones.md](06-android-milestones.md) | M0–M7 里程碑与验收（状态镜像根 README） |
| [07-licensing-compliance.md](07-licensing-compliance.md) | 许可证矩阵、GPL 合规、商标与发布 |
| [08-risks-open-questions.md](08-risks-open-questions.md) | 风险登记、待决问题、当前限制 |
| [09-briar-lessons.md](09-briar-lessons.md) | 借鉴 Briar 的信任 UX / 省电设计 |
| [10-track-selection.md](10-track-selection.md) | 三轨协调：用户选定、可行性判定、提示与标签 |
| [../README.dev.md](../README.dev.md) | 构建、测试、本地开发、实现状态与待办 |

---

## 三条铁律

1. **双轨叠加**。A 轨（Conversations / axolotl）完整实现以保持互通；B 轨（`urn:xmpp:pomemo:0`）在对端设备支持时可用。发送走哪条轨由用户选择，可行性由 `TrackResolver` 判定并告知（见 [10-track-selection.md](10-track-selection.md)）。
2. **零服务端改动**。PQ 轨道使用自定义命名空间的 PEP 节点；服务端按不透明 XML 存储与转发。
3. **PQ 用于握手**。ML-KEM 只进入 X3DH→PQXDH 的初始密钥协商；后续 Double Ratchet 仍为经典 DH。首条消息体积约增加 1.1 KB/设备。

## 术语

- **OMEMO**：XEP-0384；线格式以 Conversations 的 `eu.siacs.conversations.axolotl`（0.3.0 / axolotl）为主，规范节点 `urn:xmpp:omemo:2` 为辅。
- **PQ-OMEMO / pomemo**：本项目私有轨道，命名空间 `urn:xmpp:pomemo:0`。
- **PQXDH**：Post-Quantum X3DH（X25519 + ML-KEM-768）。
- **Track**：用户选定的发送轨道——后量子（PO）、标准 OMEMO（OM）、明文（NO）。
