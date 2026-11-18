# windows截屏

两个自用的 Windows 截屏小工具，写在 AutoHotkey v2 + PowerShell 5.1 上，加起来不到 60 KB，没有安装包、没有依赖。

| 工具 | 作用 | 触发方式 |
|---|---|---|
| **LongShot** | 滚动长截图：拖一个选区，一边滚轮一边截帧，松开鼠标自动拼接成一张长图 | `Ctrl+Alt+A` |
| **PasteImage** | 把剪贴板里的图片直接存成 PNG 文件（像文件一样贴在桌面上） | 在资源管理器/桌面按 `Ctrl+V` |

两个脚本互相独立，可以只装其中一个。

---

## 一、LongShot（长截图）

### 用法

1. 按 `Ctrl+Alt+A` 进入截屏模式（左上角会出现提示）。
2. 按住左键拖出要截的区域（红框）。
3. **在框里滚动滚轮**——上滚下滚都行，但一次只用一个方向。第一次滚动会把选区锁定（框变绿），之后一边滚一边自动截帧。
4. 松开左键，脚本自动拼接，结果保存到 `图片\LongShots\LongShot_<时间>.png`，并复制到剪贴板（可以直接 `Ctrl+V` 粘出文件）。
5. `Esc` 取消。

### 关键约束

**每次滚动的距离必须小于选区高度。** 相邻两帧必须有重叠像素，没有重叠的内容物理上没被拍到，拼不回来。

- 选区尽量拉高（600px 以上比较稳）；
- 滚慢一点，别一格格猛滚；
- 拼不起来时脚本会明确告诉你是哪一类问题：`noscroll`（画面根本没动）还是 `nooverlap`（滚太快，帧间零重叠）。

### 可选参数

`LongShot.ahk` 开头：

| 参数 | 默认 | 说明 |
|---|---|---|
| `SettleMs` | 160 | 滚动后等多少毫秒再截帧。越小帧越密、重叠越多；太大会导致零重叠 |
| `MinSelect` | 40 | 选区最小边长 |
| `CropTop` | 0 | 每帧忽略顶部多少像素（应对吸顶栏） |
| `DebugHUD` | true | 左上角状态条，稳定后可关 |
| `KeepFrames` | true | 拼接成功后保留原始帧（调试用，稳定后建议改 false） |
| `FocusOnStart` | true | 开始拖选时激活鼠标下的窗口 |

### 原理简述

- 截帧：GDI `BitBlt` 抓屏幕 + GDI+ 存 PNG，逐像素无损，支持副屏负坐标。
- 选框：四块 `WS_EX_LAYERED | WS_EX_TRANSPARENT` 的置顶小窗，保证不挡滚轮。
- 拼接（`stitch.ps1`，PowerShell 5.1 + 内嵌 C#）：
  1. SHA256 去掉完全相同的连续帧；
  2. 行哈希全扫描做粗对齐（支持向上滚）；
  3. 在 ±16px 内做逐行置信度精对齐，只让"有纹理的行"投票，纯色行不当证据（避免白底页面被错误重叠、内容塌缩）；
  4. 自动识别顶部不滚动的固定 UI 带，单独处理；
  5. 对齐失败的位置保守地整段追加，宁可多一条接缝，也不丢内容。

更详细的开发与踩坑记录见 [`docs/HANDOVER.md`](docs/HANDOVER.md)。

### 已知限制

- 只能截"屏幕上看得见的那一层"（`BitBlt` 的物理限制）；窗口被别的窗口挡住不行。试过 `PrintWindow`，Chrome 返回全黑，已放弃。
- 不滚动的左右侧栏会每屏重复一次。
- 固定 UI 带的检测上限是 `effH/3`。

---

## 二、PasteImage（剪贴板图片存文件）

### 用法

在**资源管理器窗口或桌面**按 `Ctrl+V`：

- 剪贴板里是文件 → 走系统原本的粘贴，不拦截；
- 剪贴板里是图片 → 存成 `Screenshot_yyyyMMdd_HHmmss.png` 到**当前打开的那个文件夹**（桌面就存桌面），左上角提示 `Saved: ...`；
- 剪贴板里既不是文件也不是图片 → 走系统原本的粘贴。

### 说明

- 只在资源管理器/桌面生效，在浏览器、聊天软件里按 `Ctrl+V` 不受影响。
- 同名文件自动加毫秒后缀，不会覆盖。
- 保存失败会退回系统默认粘贴行为，不会卡住。

---

## 三、安装

1. 安装 [AutoHotkey v2](https://www.autohotkey.com/)（脚本头有 `#Requires AutoHotkey v2.0`）。
2. 把本仓库放到一个固定目录，例如 `D:\Tools\PasteImage`。
3. 双击对应的 `.ahk` 即可运行。

### 开机自启（可选）

在 `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup` 里建快捷方式：

- 目标：`AutoHotkey64.exe`
- 参数：`"<你的路径>\LongShot.ahk"`（PasteImage 同理）
- 起始位置：脚本所在目录

两个脚本各建一个就行，互不影响。

---

## 四、文件说明

```text
windows截屏\
├─ LongShot.ahk    主交互：快捷键、拖选、截帧调度
├─ stitch.ps1      拼接算法（PowerShell 5.1 + 内嵌 C#）
├─ PasteImage.ahk  资源管理器 Ctrl+V 存图
├─ save_image.ps1  PasteImage 的保存辅助（-STA 读剪贴板）
└─ docs\
   └─ HANDOVER.md  开发记录、参数、踩坑清单
```

开发者环境：Windows 11、AutoHotkey v2.0.28、PowerShell 5.1、双显示器（含上方负坐标副屏）。

---

## 五、许可证

[MIT](LICENSE)。随便用、随便改，出事概不负责。
