# resonchat

一个基于 Flutter 的 XMPP 客户端：在**不修改服务端、不引入新 XEP** 的前提下，实现与 OMEMO 同构的**后量子加密**（X25519 + ML-KEM-768），同时**保持与标准 OMEMO 客户端互通**；UI 采用 Telegram Android 观感。Android 优先。

## 特性（规划中）

- 🔐 **双轨端到端加密**
  - A 轨：标准 OMEMO（XEP-0384），与 Conversations / Moxxy / Dino 等互通
  - B 轨：PQ-OMEMO（X25519 + ML-KEM-768 混合，PQXDH），对端全部设备支持时自动升级
- 🧩 零服务端改动 / 零新 XEP（复用 PEP、EME 等既有标准）
- 📱 Android 优先，后续扩展至其他平台
- 🎨 Telegram Android 观感

## 状态

早期设计阶段。目前仅有设计文档，尚无可用代码。

## 文档

完整设计文档见 [`docs/`](docs/README.md)：

| 文档 | 内容 |
|---|---|
| [总览与关键决策](docs/01-overview.md) | 目标、约束、ADR、架构 |
| [协议规范](docs/02-protocol-pqomemo.md) | 双轨 OMEMO、PQXDH、消息格式 |
| [XMPP 集成](docs/03-xmpp-integration.md) | PEP 节点、收发流程 |
| [密码学实现](docs/04-crypto-android.md) | liboqs/NDK、密钥存储 |
| [UI 规范](docs/05-ui-telegram.md) | Telegram 观感与移植 |
| [里程碑](docs/06-android-milestones.md) | M0–M7 |
| [合规](docs/07-licensing-compliance.md) | 许可证与商标 |
| [风险](docs/08-risks-open-questions.md) | 风险与待决问题 |

## 许可证

[GPL-3.0-or-later](LICENSE)。

> 本项目**不是** Telegram 官方客户端，与 Telegram 无关；Telegram 名称与 Logo 为其各自所有者的商标。

## 免责声明

加密协议为自定义的 OMEMO 后量子扩展，**尚未经过第三方安全审计**。在完成独立审计之前，请勿用于高敏感场景，也不应对外宣称其安全性。
