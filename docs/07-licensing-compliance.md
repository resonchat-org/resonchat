# 07 — 许可证、合规与发布

## 1. 许可证矩阵

| 组件 | 许可证 | 与 GPLv3 兼容 | 备注 |
|---|---|---|---|
| moxxmpp | **MIT** | ✅ | Copyright 2022 Alexander "PapaTutuWawa" |
| omemo_dart | MIT | ✅ | |
| Telegram for Android（移植的 UI 代码） | **GPL-2.0-or-later** | ✅ | 「or later」使其可并入 GPLv3 |
| moxlib | **GPL-3.0** | ✅ | `packages/moxlib/LICENSE` |
| `cryptography` (Dart) | Apache-2.0 | ✅ | 以包内 LICENSE 为准 |
| `pqcrypto` (Dart) | MIT | ✅ | 纯 Dart ML-KEM / ML-DSA |
| `libsignal` (`libsignal_dart`) | AGPL-3.0 | ⚠️ | 与 GPLv3 并入后二进制整体按 AGPL 义务对待 |
| drift | MIT | ✅ | |
| SQLCipher（经 sqlite3 hooks） | BSD-style | ✅ | 使用 OpenSSL |
| flutter_secure_storage | BSD-3-Clause | ✅ | |
| riverpod / flutter_riverpod | MIT | ✅ | |

**结论**：整个项目以 **GPL-3.0-or-later** 发布。

## 2. GPL 合规义务清单

- [x] 根目录 `LICENSE` = GPLv3 全文
- [x] 本项目自有文件头部含 `SPDX-License-Identifier: GPL-3.0-or-later`
- [x] **fork 的上游文件保留原 license 头**：moxxmpp / omemo_dart 为 MIT，moxlib 为 GPL-3.0；标注本地修改点
- [ ] **移植自 Telegram Android 的文件**：
  - 保留原始版权声明
  - 显著标注「此文件修改自 Telegram for Android，GPL-2.0-or-later」及修改日期（GPLv2 §2a）
  - 不得移除原有 NOTICE
- [ ] 分发 APK 时**提供完整对应源码**（含构建脚本）
- [ ] 不得对接收者施加额外限制（GPLv2 §6 / GPLv3 §10）
- [ ] 若使用 OpenSSL（SQLCipher），注意第三方许可声明文件

## 3. 商标与品牌风险（重要）

| 项 | 风险 | 处置 |
|---|---|---|
| 名称「Telegram」 | 商标侵权 | ❌ 禁止使用，另取名称 |
| Telegram Logo / 纸飞机图标 | 商标 | ❌ 禁止使用，制作自有 Logo |
| 官方表情/贴纸包 | 独立授权 | ❌ 不使用，改用开源表情集 |
| 整体 UI「几乎一样」 | 可能构成混淆/trade dress | ⚠️ 布局可相似；品牌元素、图标、配色微调需差异化；商业发布前做法律评估 |
| `telegram.org` 相关资源 | 版权 | ❌ 不打包 |

### 上游地址对照（以各包 `pubspec.yaml` 的 `homepage` 为准）

| 包 | 上游地址 |
|---|---|
| `moxxmpp` | https://codeberg.org/moxxy/moxxmpp |
| `omemo_dart` | https://github.com/PapaTutuWawa/omemo_dart |
| `moxlib` | https://codeberg.org/moxxy/moxlib |

**设计边界建议**：保留 Telegram 的**布局与交互范式**（这是行业通用的聊天 UI 语言），但：
1. 替换所有品牌标识（应用名 **resonchat**，包名 `org.resonchat.resonchat`，图标见 `assets/icons/`）
2. 主色调做出可辨识差异
3. 图标使用自绘或 MIT/Apache 授权图标集
4. 应用内不出现任何指向 Telegram 的文案

## 4. 隐私与安全声明

- 必须在应用内明确说明：
  - 这是**独立**客户端，与 Telegram 无关
  - 加密协议为本项目自定义的 PQ 扩展，**未经第三方安全审计**
  - 数据存储位置（本地 SQLCipher / Web Drift WASM）与备份行为（历史导出不含密钥）
- 不得在未审计的情况下宣称「军用级」「绝对安全」等
- 崩溃上报如启用，必须可关闭且说明收集内容

## 5. 发布形态

| 渠道 | 要求 |
|---|---|
| 自签名 APK | 提供源码下载链接（GPL 义务）；CD 在 GitHub Release 挂 APK / AppImage |
| F-Droid | 接受 GPLv3；需全部依赖可复现构建（含 `libsignal` / Rust 工具链） |
| Google Play | ⚠️ 需处理「与知名应用混淆」的审核风险，且 GPL 源码须可获取 |

## 6. 参与贡献（DCO/CLA）

贡献者提交即表示同意以项目许可证（GPL-3.0-or-later）授权其贡献；上游 fork 内的修改保留各包原许可证。
