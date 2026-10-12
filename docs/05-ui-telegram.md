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
- 时间戳在右下角，已读用双勾

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
| Web | 不检测（stub → `null`） | 浏览器无可靠系统麦静音 API |
| iOS / macOS | 不检测（`null`） | 无对等的简单软静音查询 |
| **Windows** | **尚未适配（`null`）** | **日后做 Windows / 其他桌面构建时必须补上等价检测**（静音与/或 0% 音量，WinRT / WASAPI 等），并写入本表；在适配完成前不得假定「开录即有声」 |

代码入口：

- `app/lib/platform/voice_recorder.dart`
- `app/lib/platform/voice_mic_check_io.dart` / `voice_mic_check_stub.dart`
- `app/android/.../MainActivity.kt`（Android channel）

## 4. 关键交互（必须还原）

1. **会话列表**：长按多选、滑动归档/删除、未读计数徽标、置顶/静音图标、在线状态点；统一收件箱跨账号（`AccountHub`）；「发现公开群聊」对齐 Conversations（jabber.network Muclumbus 或本服 XEP-0030 disco）
2. **聊天页**：
   - 发送按钮 → 变成麦克风（输入框为空时）；按住录音 / 左滑取消（§3.1）
   - 上滑到底部按钮（FAB）
   - 长按消息弹出上下文菜单（含「选择消息」进入多选、「翻译」等），可滑动回复；翻译经外部 LibreTranslate 兼容或 DeepL API，目标语言跟随界面语言，结果显示在气泡下方
   - 日期分隔气泡、未读分隔线
   - 顶栏 EncBadge → 协议选择（PO / OM / NO）
3. **顶栏**：返回手势、头像点击进资料页、右上角菜单
4. **导航**：会话 ↔ 聊天；账号管理与登录
5. **主题**：浅色/深色/跟随系统；聊天背景可选

## 5. 分期实现（与里程碑对应）

| 期 | 范围 | 状态 |
|---|---|---|
| UI-1 | 主题 Token、字体、会话列表 | 已完成 |
| UI-2 | 聊天页：气泡、输入栏、日期分隔、滚动到底 | 已完成 |
| UI-3 | 接入真实 XMPP 数据（roster/MAM） | 已完成 |
| UI-4 | 附件、图片查看器、录音、表情面板 | 部分完成（录音已接；Windows 静音检测待适配） |
| UI-5 | 资料页、设置页、加密/指纹页、账号管理 | 已完成骨架 |
| UI-6 | 动画打磨、暗色主题、横屏/平板适配 | 进行中 |

## 6. 必须避免

- ❌ 使用「Telegram」名称、Logo、蓝色纸飞机图标（商标）
- ❌ 使用 Telegram 的官方表情/贴纸包（有独立授权）
- ❌ 让用户误认为这是官方 Telegram 客户端
- ✅ 界面布局可以相似，但品牌标识必须替换为自有资产（`assets/icons/`）
