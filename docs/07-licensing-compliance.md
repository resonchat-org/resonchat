# 07 — 许可证、合规与发布

## 1. 许可证矩阵

| 组件 | 许可证 | 与 GPLv3 兼容 | 备注 |
|---|---|---|---|
| moxxmpp | **MIT** | ✅ | 仓库 LICENSE 为 MIT（Copyright 2022 Alexander "PapaTutuWawa"），非文档早期记录的 MPL-2.0；已按实测更正 |
| omemo_dart | MIT | ✅ | 宽松 |
| Telegram for Android（移植的 UI 代码） | **GPL-2.0-or-later** | ✅ | 「or later」使其可并入 GPLv3 |
| moxlib | **GPL-3.0** | ✅ | `packages/moxlib/LICENSE` 为 GPL-3.0 全文（早期文档记为 MIT，以实测为准）；与本项目许可证相同 |
| liboqs | MIT | ✅ | |
| `cryptography` (Dart) | Apache-2.0 | ✅ | 早期文档记为 BSD-3-Clause，以包内 LICENSE 为准 |
| `pqcrypto` (Dart) | MIT | ✅ | 纯 Dart ML-KEM / ML-DSA，当前 B 轨 KEM 实现 |
| drift | MIT | ✅ | |
| sqlcipher_flutter_libs / SQLCipher | BSD-style | ✅ | 使用 OpenSSL |
| flutter_secure_storage | BSD-3-Clause | ✅ | |
| riverpod / flutter_riverpod | MIT | ✅ | |

**结论**：整个项目以 **GPL-3.0-or-later** 发布。

## 2. GPL 合规义务清单

- [ ] 根目录 `LICENSE` = GPLv3 全文
- [ ] 每个源文件头部含版权与许可证声明（本项目自有文件已加 `SPDX-License-Identifier: GPL-3.0-or-later`）
- [ ] **fork 的上游文件保留原 license 头**：moxxmpp / omemo_dart 为 MIT，moxlib 为 GPL-3.0；均保留原版权声明并标注本地修改点
- [ ] **移植自 Telegram Android 的文件**：
  - 保留原始版权声明
  - 显著标注「此文件修改自 Telegram for Android，GPL-2.0-or-later」及修改日期（GPLv2 §2a）
  - 不得移除原有 NOTICE
- [ ] **MPL-2.0 文件（moxxmpp fork）**：~~不适用~~（实测为 MIT，保留 MIT 头即可）
- [ ] **GPL-3.0 文件（moxlib）**：保留原 GPL-3.0 license 头与版权声明
- [ ] 分发 APK 时**提供完整对应源码**（含构建脚本）
- [ ] 不得对接收者施加额外限制（GPLv2 §6 / GPLv3 §10）
- [ ] 若使用 OpenSSL，注意第三方许可声明文件

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

> 早期文档将 `omemo_dart` 的上游记为 Codeberg，实为 GitHub，已更正。

**设计边界建议**：保留 Telegram 的**布局与交互范式**（这是行业通用的聊天 UI 语言），但：
1. 替换所有品牌标识
2. 主色调做出可辨识差异
3. 图标使用自绘或 MIT/Apache 授权图标集
4. 应用内不出现任何指向 Telegram 的文案

## 4. 隐私与安全声明

- 必须在应用内明确说明：
  - 这是**独立**客户端，与 Telegram 无关
  - 加密协议为本项目自定义的 PQ 扩展，**未经第三方安全审计**
  - 数据存储位置（本地 SQLCipher）与备份行为
- 不得在未审计的情况下宣称「军用级」「绝对安全」等
- 崩溃上报如启用，必须可关闭且说明收集内容

## 5. 发布形态

| 渠道 | 要求 |
|---|---|
| 自签名 APK | 提供源码下载链接（GPL 义务） |
| F-Droid | 接受 GPLv3；需全部依赖可复现构建（liboqs 需能从源码构建） |
| Google Play | ⚠️ 需处理「与知名应用混淆」的审核风险，且 GPL 源码须可获取 |

## 6. 参与贡献（DCO/CLA）

- 采用 **DCO**（Developer Certificate of Origin）即可，避免 CLA 与 GPL 冲突。
- 贡献者须签署 `Signed-off-by`。

## 7. 发布前检查表

- [ ] `LICENSE` 与所有第三方许可声明齐全
- [ ] 无 Telegram 商标/Logo/名称残留（全仓库 grep）
- [ ] 移植文件均标注来源与修改
- [ ] 源码可复现构建 APK
- [ ] 隐私政策与安全免责声明就位
- [ ] 未做未经证实的加密强度宣传
