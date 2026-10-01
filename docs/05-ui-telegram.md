# 05 — UI：Telegram 观感规范

目标：**Android 端与 Telegram 手机版观感高度一致**。实现方式为**移植/翻译** Telegram Android 的 UI 代码（GPLv2-or-later → 本项目 GPLv3），并在 Flutter 中重绘。

## 1. 移植策略

| 方式 | 说明 | 采用 |
|---|---|---|
| 逐组件翻译 Kotlin → Dart | 保留布局结构、尺寸、动画曲线、交互语义 | ✅ 主策略 |
| 直接嵌入 Kotlin 视图 | 通过 PlatformView | ❌ 复杂、性能差、难维护 |
| 仅截图临摹 | 容易走样，但工作量小 | ⚠️ 仅用于难以定位的细节 |

**关键资源来源**

- 布局与尺寸：`Telegram/src/main/res/layout/*.xml`、`values/dimens.xml`
- 颜色：`values/colors.xml` + 各主题 `ThemeColors`
- 图标：`res/drawable*`（注意部分为第三方素材，见 07 文档）
- 动画：`org.telegram.ui.Components.*` 中的 `AnimatorSet` / 插值器

> 所有移植文件需在头部注明来源（`Telegram for Android, GPL-2.0-or-later`）与修改说明。

## 2. 设计 Token（起始值，必须逐项采样确认）

> ⚠️ 下表为**近似起始值**，正式实现时必须从 TG 源码/真机截图精确采样。TG 主题随版本变化，且有 Blue/Green 等多套主题。

| Token | 浅色（Blue 主题） | 深色主题 |
|---|---|---|
| 顶部栏背景 | `#517DA2`（旧）/ 主题色 | `#242F3D` |
| 页面背景 | `#FFFFFF` | `#17212B` |
| 聊天背景 | 渐变 + 图案 | 渐变 + 图案 |
| 对方气泡 | `#FFFFFF` | `#182533` |
| 自己气泡 | `#EFFDFF` | `#2B5278` |
| 主文字 | `#000000` | `#FFFFFF` |
| 次文字/时间 | `#A8A8A8` | `#6D7F8F` |
| 强调色 | `#168ACD` / `#419FD9` | `#5EB5F7` |
| 分隔线 | `#E5E5E5` | `#101921` |

**聊天气泡**

- 圆角约 `12dp`（小气泡），气泡尾部用 CustomPainter/Path 绘制
- 内边距约 `8dp horizontal`，消息文字与时间同一基线对齐
- 群聊中自己/他人气泡颜色区分，发送者名字着色
- 时间戳在右下角，已读用双勾

**字体与尺寸**

- 系统默认字体（Android 上为 Roboto），消息字号 `16sp`
- 会话列表标题 `16sp`、副标题 `14sp`
- 头像：会话列表 `54dp`、聊天页 `40dp`、联系人列表 `46dp`

## 3. 组件映射（Kotlin → Flutter）

| Telegram Android | Flutter 实现 |
|---|---|
| `DialogsActivity` / 会话列表 | `ChatsListPage` + `CustomScrollView` |
| `ChatActivity` | `ChatPage` |
| `ChatMessageCell` | `MessageBubble`（`CustomPaint` 画尾角） |
| `ActionBar` | 自定义 `SliverAppBar` / `AppBar` |
| `DrawerLayoutContainer` | `Scaffold.drawer` / `endDrawer` |
| `ChatAttachAlert` | `AttachmentSheet`（`showModalBottomSheet`） |
| `PhotoViewer` | `PhotoView` + `Hero` 转场 |
| `ProfileActivity` | `ProfilePage` |
| `SettingsActivity` | `SettingsPage` |
| `Theme` / `ThemeColors` | `AppThemeTokens` + `ThemeExtension` |
| `AnimatedEmojiDrawable` | `Lottie` / `Rive`（自制或授权素材） |
| `BottomPagesView`（顶部分页） | `TabBar` |
| 双击/长按/滑动回复 | `GestureDetector` + `Dismissible` |
| 录音按住说话 | 自定义 `LongPressDraggable` + 波形 |

## 4. 关键交互（必须还原）

1. **会话列表**：长按多选、滑动归档/删除、未读计数徽标、置顶/静音图标、在线状态点
2. **聊天页**：
   - 发送按钮 → 变成麦克风（输入框为空时）
   - 上滑到底部按钮（FAB）
   - 长按消息弹出上下文菜单，可滑动回复
   - 双击消息快捷回复（可选）
   - 日期分隔气泡、未读分隔线
3. **顶栏**：返回手势、头像点击进资料页、右上角菜单
4. **导航**：会话 ↔ 聊天 的 Hero/共享元素转场
5. **主题**：浅色/深色/跟随系统；聊天背景可选

## 5. 分期实现（与里程碑对应）

| 期 | 范围 |
|---|---|
| UI-1 | 主题 Token、字体、会话列表（静态数据） |
| UI-2 | 聊天页：气泡、输入栏、日期分隔、滚动到底 |
| UI-3 | 接入真实 XMPP 数据（roster/MAM） |
| UI-4 | 附件、图片查看器、录音、表情面板 |
| UI-5 | 资料页、设置页、加密/指纹页 |
| UI-6 | 动画打磨、暗色主题、横屏/平板适配 |

## 6. 必须避免

- ❌ 使用「Telegram」名称、Logo、蓝色纸飞机图标（商标）
- ❌ 使用 Telegram 的官方表情/贴纸包（有独立授权）
- ❌ 让用户误认为这是官方 Telegram 客户端
- ✅ 界面布局可以相似，但品牌标识必须替换为自有资产
