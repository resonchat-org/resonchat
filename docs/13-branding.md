# 13 — 品牌与图标

ResonChat 的标志是一个**聊天气泡 + 一个完整正弦周期**：气泡是聊天，正弦波是 “resonance（共振）”。画法遵循 [Lawnicons](https://github.com/LawnchairLauncher/lawnicons) 规范，因此可以直接作为 Android 主题图标（单色层）使用。

![ResonChat 标志](../app/assets/icons/app_icon_192.png)

## 1. 几何

| 项目 | 取值 |
|---|---|
| 画布 | 192 × 192 |
| 内容长边 | 160（气泡 160 × 108，尾巴到 y = 162） |
| 线宽 | 12 |
| 填充 | 无（`fill="none"`） |
| 端点 / 转角 | 圆头、圆角 |
| 90° 圆角半径 | 28 |
| 最小线间距 | 18（规范要求 ≥ 8） |

几何以脚本中的 `BUBBLE` / `WAVE` 常量为唯一来源，`scripts/generate_brand_assets.py` 生成所有位图与 Android 资源。

## 2. 颜色

默认主题色为蓝色。应用内标志读取 `context.appColors.accent`：

- Material You / 系统强调色可用时 → 系统色；
- 否则 → 固定蓝色强调色 `#3D9BD4`（`AccentColor.blue`，也是 `kResonChatBrandBlue`）。

| 名称 | HEX | RGB | 用途 |
|---|---|---|---|
| Brand Blue | `#3D9BD4` | 61, 155, 212 | 默认强调色、标志回落色 |
| Icon Blue | `#4FA8DD` | 79, 168, 221 | 浅蓝辅助色（旧图标 / 强调） |
| Blue Strong | `#1F6FA8` | 31, 111, 168 | 浅色底上的小字号文字 / 按下态 |
| Blue Soft | `#E6F4FB` | 230, 244, 251 | 浅蓝容器、选中底色 |
| Ice | `#F4F7FB` | 244, 247, 251 | 浅色界面背景（图标取色不使用固定值） |
| Ink | `#0C1324` | 12, 19, 36 | 深色界面背景（图标取色不使用固定值） |
| White | `#FFFFFF` | 255, 255, 255 | 蓝底上的图形 |

应用图标使用 **Material 3 dynamic color**：从系统主题色取 seed，经 HCT 生成色调板，再按 M3 role 取色。图标固定使用 `primaryContainer` 作底色、`onPrimaryContainer` 作线条（浅色为“浅色块 + 深色线”，深色自动反转），因此主题色换成绿、橙、紫时图标会跟着变色。引擎是 vendored 的 `materialyoucolor`（见 `scripts/_vendor/materialyoucolor/LICENSE`），`scripts/m3_theme.py` 是唯一取色入口。Android 12+ 映射到 `system_accent1_100/900`（浅色）与 `system_accent1_700/100`（深色）。品牌蓝只作为读不到系统色时的 fallback seed；标志是粗线条图形，小字号正文使用 `#1F6FA8`（对浅色底 5.33:1）。

## 3. 资产

| 路径 | 说明 |
|---|---|
| `app/assets/icons/resonchat_logo.svg` | 主标志，品牌蓝，192 × 192 |
| `app/assets/icons/resonchat_logo_white.svg` | 白色标志，深色背景用 |
| `app/assets/icons/resonchat_logo_black.svg` | Lawnicons 提交版：纯黑、无填充、192 × 192 |
| `app/assets/icons/app_icon.png` / `app_icon_192.png` | M3 `primaryContainer` 底 + `onPrimaryContainer` 线；标志占图标宽度 50% |
| `app/assets/icons/app_icon_maskable_*.png` | 满幅版本，图形位于 maskable 安全区内 |
| `app/assets/icons/favicon.png` | Web favicon |
| `app/assets/icons/app_icon.ico` | Windows / Inno Setup |
| `app/android/app/src/main/res/mipmap-*/ic_launcher.png` | Android 旧版图标（API < 26；构建时由 `app_icon.png` 生成，Git 忽略） |
| `app/linux/packaging/org.resonchat.resonchat.desktop` | Linux 桌面项；文件名必须等于 GTK app-id，`Icon=` / `StartupWMClass=` 同值 |
| `app/android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml` | Android 自适应图标 |
| `app/android/app/src/main/res/drawable/ic_launcher_foreground.xml` | M3 `onPrimaryContainer` 前景层（v31 / night-v31 取系统色调资源） |
| `app/android/app/src/main/res/drawable/ic_launcher_monochrome.xml` | 单色层；Android 13+ 主题图标由此取系统色 |
| `app/lib/ui/resonchat_logo.dart` | `ResonChatLogo` 组件（无额外依赖） |
| `scripts/m3_theme.py` | M3 dynamic color 取色入口（HCT / tonal spot） |
| `scripts/_vendor/materialyoucolor/` | vendored M3 颜色引擎（MIT） |

## 4. 各平台如何跟随系统色

应用主题与标志都消费解析后的 `AppColors.accent`。Android 12+ 走 `DynamicColorBuilder` 的 Monet 调色板；桌面端先读 freedesktop portal 的 `org.freedesktop.appearance / accent-color`，取不到再用 `dynamic_color` 的 GTK / Windows / macOS 强调色。

Linux 启动器图标由 `scripts/install_linux_desktop.py` 生成：seed 优先读 GTK 主题 CSS 里的 `@accent_bg_color`（非 GNOME 会话下比 portal 更接近实际界面），再回退 portal，再回退品牌蓝。加 `--service` 会安装 systemd 用户服务 `resonchat-icon.service`，每 3 秒检查主题色/深浅，变化时自动重渲染 hicolor 图标并刷新缓存，不需要重装。

| 平台 | 系统色 | 标志行为 | 取不到时 |
|---|---|---|---|
| Android 12+ | ✅ Material You | 应用内 `appColors.accent`；启动器主题图标走 `monochrome` 层 | `#3D9BD4` |
| Android ≤ 11 | ❌ | M3 roles 静态生成，night 资源反转 | `#3D9BD4` seed |
| Web | ⚠️ 浏览器不暴露系统强调色 | 页面可用 CSS 变量覆盖 `resonchat_logo.svg` 的颜色 | `#3D9BD4` |
| Windows | ✅ | portal / `dynamic_color` → 主题 accent | `#3D9BD4` |
| macOS | ✅ | portal / `dynamic_color` → 主题 accent | `#3D9BD4` |
| Linux | ✅（GTK 主题 CSS / portal） | seed + scheme → M3 roles；`--service` 自动跟随变化 | `#3D9BD4` seed |
| iOS / iPadOS | ⚠️ 图标不可 tint | 应用内主题色；桌面图标用 fallback seed | `#3D9BD4` seed |

桌面/浏览器无法取到系统色时，主题回落 `AccentColor.blue`，标志回落品牌蓝。

Linux 下 GTK 的 `APPLICATION_ID` 是 `org.resonchat.resonchat`。Wayland（GNOME / KDE / niri 等）按这个 app-id 找桌面项，因此 `.desktop` 文件名、`Icon=`、`StartupWMClass=` 必须都用 `org.resonchat.resonchat`；否则任务栏只能显示通用齿轮占位图标。AppImage 首次运行若未集成到菜单，可用 `AppImageLauncher` 或手动把 `.desktop` 与 hicolor 图标装进 `~/.local/share`。

## 5. Web 变色

`resonchat_logo.svg` 使用固定品牌蓝。需要在网页里跟随主题时，用 mask 只取形状：

```css
.rc-logo {
  display: inline-block;
  inline-size: 48px;
  block-size: 48px;
  background: var(--rc-logo-color, #3D9BD4);
  -webkit-mask: url("./resonchat_logo.svg") center / contain no-repeat;
          mask: url("./resonchat_logo.svg") center / contain no-repeat;
}
```

```html
<span class="rc-logo" role="img" aria-label="ResonChat"></span>
```

## 6. 使用

- 裸标志最小 24 px；16 px 使用圆形色调底 favicon。
- 应用图标为圆形底，标志宽度固定为图标宽度的 50%；不要单独放大标志。
- 标志内容按 Lawnicons C02：160 px（含 12 px 描边）/ 192 画布；独立 SVG 即此规格。
- 留白 ≥ 图形宽度的 10%；192 画布已自带 16 px 边距。
- 不要加渐变、填充、阴影或外描边；不要把 12 px 线宽改细。
- 只允许改颜色，不要改形状与比例。
- Lawnicons 提交版必须纯黑 `#000000`、无填充；本项目不维护单独的 Lawnicons 仓库文件，单色层 `ic_launcher_monochrome.xml` 即同形。

## 7. 重新生成

```bash
./scripts/generate_brand_assets.py
```

需要 `rsvg-convert` 与 Pillow（`python3-pil`）。生成结果已提交，普通构建不依赖这两个工具。

Linux 桌面图标（按当前系统主题色生成用户级图标）：

```bash
./scripts/install_linux_desktop.py                  # 自动找 AppImage
./scripts/install_linux_desktop.py --service        # 再加 systemd 用户服务，持续跟随主题色
./scripts/install_linux_desktop.py --accent '#7B4E9E'  # 手动指定 seed
./scripts/install_linux_desktop.py --uninstall      # 同时停用并删除服务
```

seed 优先读 GTK 主题 CSS 的 `@accent_bg_color`，其次 portal `accent-color`，最后回退品牌蓝。需要 `rsvg-convert`。脚本同时写入 `~/.local/share/applications/org.resonchat.resonchat.desktop` 与 hicolor 图标；文件名必须与 GTK app-id 一致。`--watch` 是前台轮询模式，`--service` 会以 systemd 用户服务运行它。
