# XMPP PQ Client — 设计文档

一个基于 Flutter 的全平台 XMPP 客户端，在**不修改任何服务端、不引入任何新 XEP**的前提下，实现与 OMEMO 机制同构的**后量子加密**，同时**保持与标准 OMEMO 客户端的互通**。UI 采用 Telegram Android 的观感（移植其 GPLv2-or-later 代码），整体以 **GPLv3** 发布。

> 开发重心：**Android 优先**。

---

## 文档索引

| 文档 | 内容 | 状态 |
|---|---|---|
| [01-overview.md](01-overview.md) | 目标、非目标、硬约束、关键决策（ADR）、架构总览、仓库结构 | ✅ |
| [02-protocol-pqomemo.md](02-protocol-pqomemo.md) | **核心**：双轨 OMEMO、PQXDH、棘轮、消息与 bundle 格式 | ✅ |
| [03-xmpp-integration.md](03-xmpp-integration.md) | PEP 节点、能力协商、收发流程、EME 声明 | ✅ |
| [04-crypto-android.md](04-crypto-android.md) | liboqs/NDK 构建、密钥存储、性能基准、依赖清单 | ✅ |
| [05-ui-telegram.md](05-ui-telegram.md) | Telegram 观感规范、移植策略、组件映射 | ✅ |
| [06-android-milestones.md](06-android-milestones.md) | M0–M7 里程碑、任务拆解、验收标准 | ✅ |
| [07-licensing-compliance.md](07-licensing-compliance.md) | 许可证矩阵、GPL 合规、商标风险、发布清单 | ✅ |
| [08-risks-open-questions.md](08-risks-open-questions.md) | 风险登记、待决问题 | ✅ |
| [09-briar-lessons.md](09-briar-lessons.md) | 借鉴 Briar 的信任 UX / 省电设计，及必须拒绝的部分 | ✅ |
| [../README.dev.md](../README.dev.md) | 构建、测试、本地开发、当前实现状态与待办 | ✅ |

---

## TL;DR — 三条铁律

1. **双轨，不是替换**。标准 OMEMO（XEP-0384）必须完整实现以保持互通；PQ 是叠加在上面的第二轨道，仅在**对端全部设备**支持时启用，否则回退标准 OMEMO。
2. **零服务端改动**依靠「PEP 只是存储+转发」这一事实：PQ 轨道使用**自定义命名空间**的 PEP 节点，服务端不认识也不影响。
3. **PQ 只管握手**。ML-KEM 只用于 X3DH→PQXDH 的初始密钥协商（与 Signal PQXDH 一致），后续 Double Ratchet 仍是经典 DH。这样只有每个会话的第一条消息变大（+约 1.1 KB/设备），而非每条。

## 术语

- **OMEMO**：XEP-0384，基于 X3DH + Double Ratchet 的多端加密。
- **PQ-OMEMO / pomemo**：本项目定义的私有轨道，命名空间 `urn:xmpp:pomemo:0`。
- **PQXDH**：Post-Quantum X3DH，Signal 提出的混合后量子密钥协商（X25519 + ML-KEM-768）。
- **PQXDH Hybrid**：即使 ML-KEM 被攻破，经典 X25519 仍提供安全性。
