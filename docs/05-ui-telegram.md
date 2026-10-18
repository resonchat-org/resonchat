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

> ⚠️ 下表为**近似起始值**，正式实现时必须从 TG 源码/真机截图精确采样。TG 主题随版本变化，且有 Blue/Green 等多套主题。当前色板已按 ThemeColors.java 采样接入 `design_tokens.dart` / `theme.dart`。

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
- 时间戳在右下角；发送中时钟，发完无勾，送达单勾，已读双勾

**字体与尺寸**

- 系统默认字体（Android 上为 Roboto），消息字号 `16sp`
- 会话列表标题 `16sp`、副标题 `14sp`
- 头像：会话列表 `54dp`、聊天页 `40dp`、联系人列表 `46dp`

## 3. 组件映射（Kotlin → Flutter）

| Telegram Android | Flutter 实现 |
|---|---|
| `DialogsActivity` / 会话列表 | `ChatsPage` + `ChatRow` |
| `ChatActivity` | `ChatPage` |
| `ChatMessageCell` | `MessageBubble`（`CustomPaint` 画尾角） |
| `ActionBar` | 自定义 `AppBar` |
| `DrawerLayoutContainer` | `Scaffold.drawer` / 账号入口 |
| `ChatAttachAlert` | `MediaAttachment` / bottom sheet |
| `ProfileActivity` | `ProfilePage` |
| `SettingsActivity` | `SettingsPage` / `SecurityPage` |
| 多账号 | `ManageAccountsPage` + `AccountHub` |
| 订阅请求 | `RequestsPage` |
| `Theme` / `ThemeColors` | `design_tokens.dart` + `theme.dart` |
| 双击/长按/滑动回复 | `message_actions.dart` + 手势 |
| 录音按住说话 | `_InputBar` 按住麦克风 + `VoiceRecorder`（见 §3.1） |

### 3.1 语音消息与麦克风静音检测

交互对齐 Telegram `ChatActivityEnterView`：输入框为空时显示麦克风，**按住录音、左滑取消、松手发送**（过短丢弃）；上传走既有 XEP-0363 附件路径（`sendAttachmentBytes`）。

录音**开始前**做一次「输入是否可用」探测（`VoiceRecorder.isSystemMicMuted` → `isDefaultMicMuted`）。只有返回 `true` 才拦截并提示；返回 `null`（该平台查不到）则**不阻塞**，照常开录。

桌面设置里「关闭麦克风」常见两种表现：`Mute: yes`，或 **Mute 仍为 no 但音量为 0%**（GNOME 等）。Linux 必须两种都拦。

| 平台 | 实现 | 说明 |
|---|---|---|
| Linux | 优先 `wpctl get-volume`；否则 `pactl`。CLI 缺失 → SnackBar 提示并跳过检测，仍可开录 | 录音另需 `pw-record`/`parecord` + `ffmpeg`；缺则 SnackBar，不崩溃 |
| Android | `AudioManager.isMicrophoneMute`（MethodChannel `org.resonchat.resonchat/audio`） | 软静音，非隐私开关 |
| Windows | WASAPI 默认捕获端点 `GetMute` + 主音量 0%（同 channel） | `app/windows/runner/audio_mute.cpp` |
| Web | 不检测（stub → `null`） | 浏览器无可靠系统麦静音 API |
| iOS / macOS | 不检测（`null`） | 无对等的简单软静音查询 |

代码入口：

- `app/lib/platform/voice_recorder.dart`
- `app/lib/platform/voice_mic_check_io.dart` / `voice_mic_check_stub.dart`
- `app/android/.../MainActivity.kt`（Android channel）
- `app/windows/runner/audio_mute.cpp`（Windows WASAPI）

### 3.2 输入栏（`ChatActivityEnterView` + `ChatInputViewsContainer`）

现行 Telegram 的输入栏是浮在聊天记录上的**圆角玻璃岛（input island）**，不再是满宽面板。岛本身**不是** `ChatActivityEnterView` 画的（它只填内容矩形），而是外层 `ChatInputViewsContainer` 画的：

| 元素 | 规格 | 出处 |
|---|---|---|
| 卡片圆角 / 边距 | 圆角 **22dp**，左右各 **7dp**，距底部系统 inset **9dp**（键盘弹起时改为上圆角 29dp 的整块） | `ChatInputViewsContainer.java:27`—`:30`（`INPUT_BUBBLE_RADIUS` / `INPUT_KEYBOARD_RADIUS` / `INPUT_BUBBLE_BOTTOM`）；`ChatActivity.java:8431` |
| 毛玻璃 | `BlurredBackgroundDrawable`，`setPadding(dp(7))`、`setRadius(dp(22))`，颜色 provider = `key_chat_messagePanelBackground` | `ChatInputViewsContainer.java:79`—`:88`；`ChatActivity.java:4935` |
| 栏高 / 各图标槽位 | `44dp`（`DEFAULT_HEIGHT`），顶部 1dp 内边距 | `ChatActivityEnterView.java:6551`、`:2663` |
| 左侧表情 | 44dp 槽位、`dp(7.5)` 内边距 → 29dp 字形；**另有一个 42×38、圆角 19 的 `key_listSelector`（6% 墨）底块** | `:2723`、`:2760`（`createInsetRoundRectDrawable(key_listSelector, dp(19), dp(1), dp(3))`） |
| 文字 | 18dp，上 `dp(9)` / 下 `dp(10)`，最多 6 行；距表情槽 8dp、距回形针槽 6dp | `:5890`—`:5901` |
| 回形针 | 44dp 槽位、24dp 字形（`msg_input_attach2`） | `:2845` |
| 最右槽位 | 有文字时：44dp 列内缩 3dp 的 **38dp 圆**，填充 `chat_messagePanelSend`、白色字形 | `:3230`—`:3258`、`:10609` |
| 按住录音 | 红色 10dp 闪烁圆点 + 15dp 计时 + 居中「左滑取消」 | `:1074`—`:1107`、`:14304`—`:14313` |

两处刻意背离，均已与用户确认：

- **最右槽位空输入时画 ⋮**（无圆底）。这来自实机截图（Nagram 12.10.3.0，界面与同期上游一致）：空输入框的右槽是会话菜单的 ⋮，语义未验证（13.0.2 源码里该位置是麦克风，⋮ 是 `botButton`，位于回形针左侧）。目前 ⋮ **只有外观、点击无动作**；按住的录音手势保留，否则语音没有入口。服务端不支持语音/附件（无 XEP-0363）时 ⋮ 退化为灰色字形。
- **取消阈值固定 64dp**。参考实现是 `distCanMove = min(宽度 35%, 140dp)`（`:731`、`:3188`），手机上约 126dp，实测手感明显偏钝，改为固定 64dp。

毛玻璃在 Flutter 侧用 Material 的 `BackdropGroup` + `BackdropFilter.grouped`（`app/lib/ui/chat/glass_panel.dart`）：一份模糊快照在顶栏与输入栏之间共享，不重复糊。岛需要「背后有东西」才看得出玻璃，因此聊天背景（`ChatWallpaper`）被提到页面最底层。

品牌仍为自有（§6）：圆底用应用主题强调色，字形用 Material 图标，不使用 Telegram 官方蓝色与纸飞机图标。

### 3.3 顶栏（`ActionBar.setupGlass`）

顶栏同样改成浮在聊天记录上的玻璃面，而且是**三个独立的卡片**，不是一条通栏：

| 元素 | 规格 | 出处（`ActionBar.java`） |
|---|---|---|
| 卡片半径 | **23dp**（46dp 的方块即是圆），上下各 6dp 留白 | `:2269`—`:2279`（`p = dp(6)`、`s = dp(46)`）、`:228`、`:230` |
| 返回 / 菜单 | 各自一块玻璃圆（`glassDrawableBack` / `glassDrawableMenu`），半径 23dp、内边距 6dp | `:239`、`:246`、`:250` |
| 标题 | 中间一块玻璃胶囊（`glassDrawable`），边长 ≥ `s + 2p`，随头像容器宽度居中 | `:2285`—`:2310` |
| 颜色 provider | `topPanelChatActivity`（`key_chat_messagePanelBackground`） | `ChatActivity.java:4911` |
| 状态栏 | 顶栏不再画底色，状态栏图标按明暗主题切换 | `setOccupyStatusBar`，`ChatActivity.java:4909` |

Flutter 实现（`app/lib/ui/chat/chat_page.dart` + `glass_panel.dart`）：`Scaffold` 开启 `extendBodyBehindAppBar`，`AppBar` 透明，`leading` / `title` / `actions` 各自包一层 `GlassPanel`；标题胶囊内是头像 + 名称 + 状态，加密轨 `EncBadge` 移到名称右侧（对齐 Telegram 把锁/认证标贴在名字旁的做法），右侧玻璃胶囊里放搜索 / 外观 / 置顶三个动作。

## 4. 关键交互（必须还原）

1. **会话列表**：长按多选、滑动归档/删除、未读计数徽标、置顶/静音图标、在线状态点；统一收件箱跨账号（`AccountHub`）；「发现公开群聊」对齐 Conversations（jabber.network Muclumbus 或本服 XEP-0030 disco）
2. **聊天页**：
   - 发送按钮：有文字时是 38dp 圆形发送钮；空输入框时右槽是会话菜单的 ⋮（仅外观，见 §3.2）；按住 ⋮ / 发送槽录音、左滑取消（§3.1）
   - 上滑到底部按钮（FAB）
   - 长按消息弹出上下文菜单（含「选择消息」进入多选、「翻译」等），可滑动回复；翻译经外部 LibreTranslate 兼容或 DeepL API，目标语言跟随界面语言，结果显示在气泡下方
   - 日期分隔气泡、未读分隔线
   - 顶栏 EncBadge → 协议选择（O2 / OM / NO）
3. **顶栏**：返回手势、头像点击进资料页、右上角菜单
4. **导航**：会话 ↔ 聊天；账号管理与登录
5. **主题**：浅色/深色/跟随系统；聊天背景可选

## 5. 分期实现（与里程碑对应）

| 期 | 范围 | 状态 |
|---|---|---|
| UI-1 | 主题 Token、字体、会话列表 | 已完成 |
| UI-2 | 聊天页：气泡、输入栏、日期分隔、滚动到底 | 已完成 |
| UI-3 | 接入真实 XMPP 数据（roster/MAM） | 已完成 |
| UI-4 | 附件、图片查看器、录音、表情面板 | 部分完成（录音已接；Linux/Android/Windows 静音检测已接） |
| UI-5 | 资料页、设置页、加密/指纹页、账号管理 | 已完成骨架 |
| UI-6 | 动画打磨、暗色主题、横屏/平板适配 | 进行中 |

## 6. 必须避免

- ❌ 使用「Telegram」名称、Logo、蓝色纸飞机图标（商标）
- ❌ 使用 Telegram 的官方表情/贴纸包（有独立授权）
- ❌ 让用户误认为这是官方 Telegram 客户端
- ✅ 界面布局可以相似，但品牌标识必须替换为自有资产（`assets/icons/`）
