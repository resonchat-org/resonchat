# 07 — 许可证、合规与发布

## 1. 许可证矩阵

| 组件 | 许可证 | 与 GPLv3 兼容 | 备注 |
|---|---|---|---|
| moxxmpp | MPL-2.0 | ✅ | 文件级 copyleft；修改的文件需继续 MPL |
| omemo_dart | MIT | ✅ | 宽松 |
| Telegram for Android（移植的 UI 代码） | **GPL-2.0-or-later** | ✅ | 「or later」使其可并入 GPLv3 |
| liboqs | MIT | ✅ | |
| `cryptography` (Dart) | BSD-3-Clause | ✅ | |
| `pqcrypto` (Dart) | MIT（需确认） | ✅ | 纯 Dart ML-KEM |
| drift | MIT | ✅ | |
| sqlcipher_flutter_libs / SQLCipher | BSD-style | ✅ | 使用 OpenSSL |
| flutter_secure_storage | BSD-3-Clause | ✅ | |
| riverpod | MIT | ✅ | |

**结论**：整个项目以 **GPL-3.0-or-later** 发布。

## 2. GPL 合规义务清单

- [ ] 根目录 `LICENSE` = GPLv3 全文
- [ ] 每个源文件头部含版权与许可证声明
- [ ] **移植自 Telegram Android 的文件**：
  - 保留原始版权声明
  - 显著标注「此文件修改自 Telegram for Android，GPL-2.0-or-later」及修改日期（GPLv2 §2a）
  - 不得移除原有 NOTICE
- [ ] **MPL-2.0 文件（moxxmpp fork）**：修改过的文件以 MPL-2.0 分发，并保留许可证头
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
