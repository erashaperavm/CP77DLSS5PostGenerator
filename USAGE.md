# USAGE — 修改版 OptiScaler 捕获 → 离线 DLSS 5 视频

本文件描述整条管线的**实际操作**。分三段：

```
① 游戏内捕获（本仓库已实现）        ② 离线后处理（Step 2，待实现）        ③ 输出视频
   改版 OptiScaler + CET 命令   →    dlss5-feed-host64.exe --capture   →   PNG/EXR 序列 → mp4
   写出 color/depth/motion.bin     读盘 → 上传 GPU → NGX DLSS-NR 求值       ffmpeg
```

> ⚠️ **状态声明**：第 ① 段（捕获层 + CET）代码已完成。第 ② 段的 `--capture` 模式**尚未写入 `DLSS5-Feeder/host/dlss5-feed-host64.cpp`**（当前 host 只有 `--test` 与 `<pid>` 两种模式）。本文件把第 ② 段的命令与契约**先定义清楚**，实现时照此执行即可。

---

## 0. 前置条件

### 0.1 文件安装位置（游戏机 = Windows）

《赛博朋克 2077》的 `bin\x64\` 目录：

| 文件 | 来源 | 说明 |
| --- | --- | --- |
| `OptiScaler.asi` | GitHub Actions 产物 `x64\Release\a\OptiScaler.dll` 改名 | 改版 DLL |
| `OptiScaler.ini` | 同上，随 DLL 一起 | 含新增 `[Capture]` 段 |
| `plugins\cyber_engine_tweaks\mods\optiscaler_capture\init.lua` | 仓库 `OptiScaler/cet-mod/optiscaler_capture/init.lua` | CET 命令端 |
| `dlss5-feed-host64.exe` + `ReShade64.dll`(改名 `dxgi.dll`) + `renodx-dlss5.addon64` | DLSS5-Feeder | 离线渲染 host，**与游戏不同目录也行** |

### 0.2 两个 ini 必改项

**(a) `OptiScaler.ini` → `[Capture]`**（总开关必须手动打开）

```ini
[Capture]
Enabled=true          ; 默认 auto(=false)。不设 true，CET 的 START 会被忽略
FrameStride=2         ; 每 2 帧采 1 帧。全采 60fps ≈ 2 GB/s，勿设 1
MaxFrames=0           ; 0 = 不限
CaptureColor=true
CaptureMotion=true
CaptureDepth=false    ; 离线 host 的 NR 求值不需要 depth；Tier 2 想用才开
CaptureExposure=false ; 通常 1x1 或 null
```

**(b) `OptiScaler.ini` → `[Hotfix]`**（捕获层需要知道每个源资源"被复制前"所处的状态，未配置的通道会被静默跳过）

```ini
[Hotfix]
ColorResourceBarrier=...
MotionVectorResourceBarrier=...
DepthResourceBarrier=...
ExposureResourceBarrier=...
```

- 值取 `D3D12_RESOURCE_STATES` 整数（`COMMON=0`、`RENDER_TARGET=4`、`UNORDERED_ACCESS=8`、`DEPTH_WRITE=16`、`NON_PIXEL_SHADER_RESOURCE=64`、`PIXEL_SHADER_RESOURCE=128`）。
- 2077 是 REDengine，**不是** UE，所以通常不是 `4`/`8` 那套。以实测为准：若某通道在 `OptiScaler.log` 里出现
  `[Capture] channel 'color' unavailable: missing [Hotfix] barrier config`，就说明该键没设或设错。
- 若游戏本身已由 OptiScaler 的 quirk 自动填了值（`dllmain.cpp` 里 `set_volatile_value`），捕获层能读到，无需手填。

---

## 1. 第 ① 段：游戏内捕获

### 1.1 CET 控制台命令

进入游戏、载入存档后，`~` 打开 CET 控制台：

| 命令 | 作用 |
| --- | --- |
| `OptiCaptureStart` | 写 `command.txt=START`。OptiScaler 在**下一个 DLSS 求值帧**开始采集 |
| `OptiCaptureStop` | 写 `command.txt=STOP`。当前帧采完后收尾并写 `manifest.json` |
| `OptiCaptureStatus` | 查询一次：`state / frames / dropped / inflight / bytes / 分辨率 / 输出目录` |
| `OptiCaptureWatch` | 开关"捕获中每 5 秒自动打印一次状态" |

通信不经过游戏渲染路径：CET 写 `command.txt`，OptiScaler 后台线程每 100 ms 轮询、读完即删；OptiScaler 每 1 s 写 `status.json`。

### 1.2 通信目录

```
<游戏 bin\x64>\plugins\cyber_engine_tweaks\mods\optiscaler_capture\
    ├── init.lua        (CET mod)
    ├── command.txt     (CET → OptiScaler，读完即删)
    ├── status.json     (OptiScaler → CET)
    └── session_<YYYYMMDD_HHMMSS>\   ← 捕获输出
```

> 注：`OptiScaler.ini` 的注释里写成 `...\optiscaler_capture\capture\session_...\`，**多了一层 `capture\`**。以源码为准（`DlssCapture.cpp` 的 `EnsureStarted()`）：**没有 `capture\` 这一层**。实际目录以 `OptiCaptureStatus` 打印的"输出目录"为准。

### 1.3 捕获输出布局

```
session_<时间戳>\
    ├── manifest.json                 # 会话级：分辨率、feature、stride、帧数、字节数
    ├── frame_000000\
    │   ├── frame.json                # 该帧全部元数据（见下表）
    │   ├── color.bin                 # 紧凑（去 rowPitch padding）逐行数据
    │   ├── motion.bin
    │   ├── depth.bin                 # 若 CaptureDepth=true
    │   └── exposure.bin              # 若 CaptureExposure=true 且资源非 null
    └── frame_000001\ ...
```

**`frame.json` 关键字段**（后处理端就是靠它决定解码方式）：

| 字段 | 用途 |
| --- | --- |
| `color_format` / `color_format_value` | DXGI 格式枚举名 + 数值。**必须按它分支解码**，2077 常见 `R11G11B10_FLOAT` |
| `color_row_pitch` / `color_tight_stride` / `color_rows` | 行对齐信息（文件内是 tight，无 padding） |
| `render_width` / `render_height` | DLSS 渲染分辨率 = color/motion 的尺寸 |
| `target_width` / `target_height` | 输出分辨率 |
| `is_hdr` | 为真则后处理**必须先 tone map**（host 内部不做，否则高光直接炸） |
| `low_res_mv` | true = motion 已是 render 分辨率；false = 是 target 分辨率，**需降采样** |
| `jittered_mv` | MV 是否已含 jitter |
| `depth_inverted` | 深度是否反相（写进 NGX feature flags） |
| `auto_exposure` | 是否有自动曝光（写进 NGX feature flags） |
| `motion_scale_x` / `motion_scale_y` | `mv_pixels = raw_mv * scale` |
| `motion_units` | 固定 `"pixels"` |
| `motion_direction` | 固定 `"current_to_previous"` |
| `motion_resolution` | `"render"` 或 `"target"` |
| `jitter_x` / `jitter_y` | 亚像素抖动，存档 |
| `frame_time_ms` / `delta_time` | 帧时间（毫秒 / 秒） |

### 1.4 建议采样流程

1. 游戏内把 DLSS 超分开到你想采的档位，关闭帧生成。
2. `OptiCaptureStart` → `OptiCaptureWatch`。
3. 走一段**有明确相机运动**的镜头（横移/推进），10~20 秒足够（stride=2、60fps → 约 300~600 帧）。
4. `OptiCaptureStop`，等 `status.json` 显示 `state=stopped`。
5. 退出游戏，把整个 `session_<时间戳>\` 拷到渲染机。

---

## 2. 第 ② 段：离线后处理为 DLSS 5 视频

### 2.1 命令（Step 2 待实现，契约已冻结）

```bat
:: 与 --test 同一个 host、同一个目录（旁边必须有 ReShade + renodx-dlss5 add-on）
dlss5-feed-host64.exe --capture "D:\cap\session_20261005_213000" --out "D:\out\dlss5" --fps 30
```

| 参数 | 含义 |
| --- | --- |
| `--capture <dir>` | 捕获会话目录（含 `manifest.json`） |
| `--out <dir>` | 输出目录，写 `frame_%06d.png`（或 `.exr`）序列 + `result.json` |
| `--fps <n>` | 仅写进 `result.json` 供 ffmpeg 用；不影响渲染 |
| `--flip-motion` | 可选。方向实测不符时取反（见 §2.4） |
| `--no-tone-map` | 可选。跳过 tone map（调试用） |

### 2.2 host 内部逐帧做什么（复用 `RunTest()` 的骨架）

`RunTest()` 已经证明整条链可用（`300/300`、`feature 18 created`、NR `ENGAGED`）。`--capture` 只需把它的**帧来源从合成图案换成磁盘**：

```
for each frame_NNNNNN/:
    read frame.json
    1. color:  按 color_format 解码 → RGBA8 纹理（is_hdr → 先 tone map）
    2. motion: 读 FP16(H×W×2) → 若 motion_resolution=="target" 则降采样到 render
               → mv *= motion_scale → 写 R16G16_FLOAT 纹理
    3. depth:  可选（默认关）
    4. flags = 由 frame.json 推导（见 §2.3）
    5. Evaluate(color, output, depth, mv, render_w, render_h,
                reset = (index==0), mvsx, mvsy, jitter_x, jitter_y)
    6. 读回 output → 写 frame_%06d.png
```

### 2.3 NGX 契约（来自你机器上 `ReShade.log` 的实测，不是猜的）

| 项 | 值 |
| --- | --- |
| `flags` | `0x4a` = `MVLowRes(2) | DepthInverted(8) | AutoExposure(64)` |
| `mvec` | `render`（低分辨率，与 ComfyUI/host 期望一致） |
| `scale` | `1, 1` |
| `encoding` | `linear` |
| `exposure` | `none` |

**实现要点（也是"设计已冻结、只改一处"的那一处）**：当前 `--test` 把 `MVLowRes|AutoExposure|DepthInverted` **硬编码**。`--capture` 改为从 `frame.json` 推导：

```
flags = 0
if low_res_mv:      flags |= MVLowRes
if depth_inverted:  flags |= DepthInverted
if auto_exposure:   flags |= AutoExposure
if is_hdr:          flags |= IsHDR          // 注意：若 is_hdr 为真，color 侧必须已 tone map 到 SDR
```

### 2.4 两个必须实测校正的量（只能在游戏机上定）

1. **motion 方向**：`frame.json` 写死 `current_to_previous`（与 NGX 约定一致，理论上无需取反）。若输出出现**拖影/反向抖动**，加 `--flip-motion` 重跑对比。
2. **motion 尺度**：`motion_scale_x/y` 由捕获层从 `MV.Scale.X/Y` 读取，正常为 `1.0`。若输出时间不稳定，检查 `low_res_mv` 与 scale 是否被正确应用（`mv_pixels = raw * scale`）。

### 2.5 合成视频

```bash
# 渲染机（Ubuntu 或 Windows 均可，ffmpeg 即可）
ffmpeg -framerate 30 -i frame_%06d.png -c:v libx264 -crf 16 -pix_fmt yuv420p dlss5_out.mp4
```

---

## 3. 不依赖 host 的快速校验（强烈建议先做）

后处理链路里有两个未知数（捕获对不对 + host 对不对）纠缠在一起。先用纯 CPU 脚本单独验证捕获数据：

| 校验 | 方法 | 判据 |
| --- | --- | --- |
| color 解码 | 读 `frame.json` → 按 `color_format` 解码 `color.bin` → 出 PNG（HDR 时 tone map） | 肉眼画面正常、无错位/偏色 |
| motion | 解码 `motion.bin` → 画色轮/箭头图 | 方向与相机运动一致、尺度合理 |
| depth | 统计 min/max/直方图 | 范围合理（近处小/远处大，或反之，看 `depth_inverted`） |
| 完整性 | 数 `frame_*/` 目录数 vs `manifest.json` 的 `captured_frames` | 相等 |

这一步在 Ubuntu 上就能做，不需要 GPU/游戏。

---

## 4. 排错

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| CET 执行 START 无反应 | `[Capture] Enabled` 不是 `true` | 改成 `true` 后重启游戏 |
| `status.json` 里 `dropped` 持续增长 | 回读环（6 槽）跟不上 | 增大 `FrameStride` |
| 日志 `channel 'x' unavailable: missing [Hotfix] barrier config` | `[Hotfix]` 对应键没设 | 补上正确的 resource state 整数 |
| `color.bin` 存在但解码花屏 | `color_format` 分支未覆盖 | 看 `frame.json` 里的实际枚举名再补分支 |
| 输出视频高光炸白 | `is_hdr=true` 但没 tone map | 后处理端加 tone map 算子 |
| 输出拖影 | motion 方向反了 | 加 `--flip-motion` |
| 输出抖动/时间不稳 | motion scale 或分辨率没处理 | 检查 `motion_scale_x/y` 与 `motion_resolution` |

---

## 5. 一句话速查

```text
改 ini:  [Capture] Enabled=true, FrameStride=2, CaptureColor/Motion=true
         [Hotfix] ColorResourceBarrier / MotionVectorResourceBarrier 设对
游戏内:  OptiCaptureStart → 走一段镜头 → OptiCaptureStop
输出:    bin\x64\plugins\cyber_engine_tweaks\mods\optiscaler_capture\session_<ts>\
离线:    dlss5-feed-host64.exe --capture <session> --out <out> --fps 30     [Step 2 待实现]
合成:    ffmpeg -framerate 30 -i frame_%06d.png -c:v libx264 -crf 16 dlss5_out.mp4
```
