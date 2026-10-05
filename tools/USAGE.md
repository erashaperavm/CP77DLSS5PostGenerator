# USAGE — 修改版 OptiScaler 捕获 → 离线 DLSS 5 视频

本文件描述整条管线的**实际操作**。分三段：

```
① 游戏内捕获（已实现）            ② 离线后处理（已实现）              ③ 输出视频
   改版 OptiScaler + CET 命令   →    dlss5-feed-host64.exe --capture   →   BMP 序列 → mp4
   写出 color/motion.bin           读盘 → 上传 GPU → NGX DLSS-NR 求值       ffmpeg
```

> ✅ **状态**：第 ① 段（捕获层 + CET）与第 ② 段（`--capture` 模式）均已在 `DLSS5-Feeder/host/dlss5-feed-host64.cpp` 实现。下面第 ② 段的命令与契约即当前实现，照此运行即可。本会话实测：`--test` 跑出 `300/300`、`feature 18 created`、`NR ENGAGED`；`--capture` 复用同一套代码路径。

---

## 0. 前置条件

> **想省事？** §0.1~0.3 的全部手工步骤（解压、改名代理、改 ini、备份）已由 **§0.4 的一键脚本**自动完成，并自带卸载。手工流程保留在下面，供理解原理 / 排查用。

### 0.1 两个 CI 产物分别放哪（游戏机 = Windows）

产物来自 `erashaperavm/OptiScaler` → Actions → **Build Capture Mod**：

**① `OptiScaler-Capture-Release`（~125 MB）** → 整个解压到游戏 exe 目录：

```
Cyberpunk 2077\bin\x64\
```

里面是 OptiScaler 全套运行时（`OptiScaler.dll`、`OptiScaler.ini`、`setup_windows.bat`、`Licenses\`、`OptiScaler\plugins\`、各代理 dll 等），**整包平铺**进去，不要套一层文件夹。解压后**双击 `setup_windows.bat`**，在"选代理文件名"处选：

| 选项 | 文件名 | 说明 |
| --- | --- | --- |
| `1` | `dxgi.dll` | **推荐，最兼容**（CP2077 选这个，回车即默认） |
| `2` | `winmm.dll` | Vulkan / MS Store 版 |
| `8` | `OptiScaler.asi` | 用 ASI Loader 的场合 |

bat 会把 `OptiScaler.dll` **改名**成 `dxgi.dll`，并按 GPU 情况配置 spoofing。**不要**自己手工改名——让 bat（或 §0.4 的脚本）来做。

**② `CET-optiscaler_capture`（~2 KB）** → 解压到 CET 的 mods 目录（注意是**两层**）：

```
Cyberpunk 2077\bin\x64\plugins\cyber_engine_tweaks\mods\optiscaler_capture\
    └── init.lua            ← 正确：mods\optiscaler_capture\init.lua

# 错误示范：mods\init.lua     ← CET 不认
```

> 前提：Cyber Engine Tweaks 本体已装好（否则没有 `plugins\cyber_engine_tweaks\` 目录）。

离线渲染端（**与游戏不同目录也行**）来自 **DLSS5-Feeder** 的 CI 产物，放在**同一目录**里：

```
<离线机某目录>\
  ├── dlss5-feed-host64.exe      ← host（已含 --capture，见 §2）
  ├── ReShade64.dll  改名 dxgi.dll   ← 提供 DLSS 5 add-on 的加载壳
  ├── renodx-dlss5.addon64        ← DLSS 5 add-on 本体
  └── OptiScaler 运行时            ← 神经消费者，提供 feature 18（DLSS-NR）
```

> ⚠️ 离线机目录 = 你跑 `--test` 能出 `300/300` 的那套环境。三者缺一不可：ReShade（壳）+ renodx-dlss5 add-on（DLSS 5）+ OptiScaler（feature 18 的提供方）。`--capture` 与 `--test` 共用同一 host 代码，环境要求完全相同。

### 0.2 两个 ini 必改项（手工做法；§0.4 脚本会自动完成）

**(a) `OptiScaler.ini` → `[Capture]`**（总开关必须手动打开）

```ini
[Capture]
Enabled=true          ; 默认 auto(=false)。不设 true，CET 的 START 会被忽略
FrameStride=2         ; 每 2 帧采 1 帧。全采 60fps ≈ 2 GB/s，勿设 1
MaxFrames=0           ; 0 = 不限
CaptureColor=true
CaptureMotion=true
CaptureDepth=false    ; 离线 host 的 NR 求值默认不需要 depth（缺了 host 会喂常量平面）；想用 Tier 2 再开
CaptureExposure=false ; 通常 1x1 或 null
Compact=true          ; 写盘压缩：motion→RG16F、color(RGBA16F)→R11G11B10F，体积减半（见 §1.3）
```

> `auto` 在这里等于 `false`。不改 `Enabled=true`，`OptiCaptureStart` 会被静默忽略，日志写 `START ignored: [Capture] Enabled is false`。

**(b) `OptiScaler.ini` → `[Hotfix]`**（捕获层需要知道每个源资源"被复制前"所处的状态，未配置的通道会被静默跳过）

找到 `[Hotfix]` 段（ini 第 ~1468 行）里的这几行：

```ini
ColorResourceBarrier=auto
MotionVectorResourceBarrier=auto
DepthResourceBarrier=auto
ColorMaskResourceBarrier=auto
ExposureResourceBarrier=auto
OutputResourceBarrier=auto
```

**只改前两行**，其余保持 `auto`：

```ini
ColorResourceBarrier=64          ; D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE
MotionVectorResourceBarrier=64   ; DLSS 输入最可能的原始状态
DepthResourceBarrier=auto
ColorMaskResourceBarrier=auto
ExposureResourceBarrier=auto
OutputResourceBarrier=auto
```

- 值取 `D3D12_RESOURCE_STATES` 整数（`COMMON=0`、`RENDER_TARGET=4`、`UNORDERED_ACCESS=8`、`DEPTH_WRITE=16`、`NON_PIXEL_SHADER_RESOURCE=64`、`PIXEL_SHADER_RESOURCE=128`）。
- **为什么必须填**：CP2077 的 quirk 只有 `CyberpunkHudlessState / FSRFGHudlessMismatchFixup / DisableHudfix / DisableDxgiSpoofing`，**没有** `DontUseUnrealColorBarriers`（那是 UE 专用，见 `dllmain.cpp:1451-1458`）。所以 OptiScaler 不会自动填这两个值；捕获层逻辑是"读不到 barrier 配置 → 跳过该通道"。留 `auto` = 一个字节都采不到。
- **怎么知道 64 对不对**：进游戏后看 `OptiScaler.log`。若某通道写 `channel 'color' unavailable: missing [Hotfix] barrier config` → 没填对。若画面闪烁/错位或游戏崩溃（device removed）→ 值不符真实状态，依次试 `192`（PIXEL|NON_PIXEL）、`8`（UNORDERED_ACCESS）。

### 0.3 验证安装成功

1. 启动游戏，进主菜单。
2. 看 `bin\x64\OptiScaler.log`，应出现：
   ```
   [Capture] mod dir: ...\optiscaler_capture
   ```
   （只有 `[Capture] Enabled=true` 时才会启动后台线程。）
3. 触发一次查询看状态：**CET 控制台里裸敲命令是不行的**（见 §1.1），改用
   - 热键 `OptiCaptureStatus`（需先在 CET Bindings 页绑定），或
   - 在 mod 目录建 `command.txt` 写 `STATUS`，或
   - 控制台里带括号 `OptiCaptureStatus()`（仅当日志提示"控制台可用"）。
   应打印 `state=idle | frames=0 ...` 及输出目录路径。若报"未找到 status.json"，说明 OptiScaler 没加载或 `Enabled` 不是 `true`。

### 0.4 一键安装 / 卸载脚本（推荐）

上面 0.1~0.3 是手工步骤。仓库 `tools\` 下有个 PowerShell 脚本把整套做完，并**自带卸载**：

```
tools\
  ├── opti-capture-install.ps1    主脚本（install / uninstall / status）
  ├── install.bat                 一键安装
  ├── uninstall.bat               一键撤回
  └── status.bat                  查询安装状态
```

**先手动解压**（脚本**不解压**，用什么都行：7-Zip / Windows 自带 / 在 Ubuntu 上解好再拷过来）：

```
OptiScaler-Capture-Release.zip  →  D:\testdlss5\OptiScaler-Capture-Release\    （里面直接是 OptiScaler.dll / OptiScaler.ini / ...）
CET-optiscaler_capture.zip      →  D:\testdlss5\CET-optiscaler_capture\        （里面是 optiscaler_capture\init.lua）
```

> 之所以让脚本收文件夹而不是 zip：绕开 7z / zip64 / .NET `Expand-Archive` 的各种格式坑（Windows 报 `找不到中央目录结尾记录` 而 Linux 能解，多半就是这个）。

**安装**（传两个**解压后的文件夹** + 游戏目录）：

```bat
tools\install.bat "D:\testdlss5\OptiScaler-Capture-Release" "D:\testdlss5\CET-optiscaler_capture" "D:\Steam\steamapps\common\Cyberpunk 2077"
```

游戏目录可省略——脚本会自动探测 Steam（读注册表 + `libraryfolders.vdf`）/ GOG / Epic 常见路径。

脚本做的事：
1. 把 OptiScaler 运行时复制进 `bin\x64\`，`OptiScaler.dll` 按代理名改名（默认 `dxgi.dll`，镜像官方 `setup_windows.bat` 布局）；
2. CET mod 复制进 `plugins\cyber_engine_tweaks\mods\optiscaler_capture\`；
3. 改 `OptiScaler.ini`：`[Capture] Enabled=true, FrameStride=2, …` + `[Hotfix]` 两个 barrier `=64`（**段内定位**，不会误改其它段的同名键）；
4. 把所有「新增 / 被覆盖」的文件记进 `bin\x64\.opti-capture-install\manifest.json`，被覆盖的原文件备份到同目录 `backup\`。

**撤回**：

```bat
tools\uninstall.bat "D:\Steam\steamapps\common\Cyberpunk 2077"
```

按 manifest 删除新增文件、还原被覆盖文件、清理空目录、删掉状态目录。**不需要 git**，也不用手工记清单。

**查询状态**（是否已装、代理名、条目数）：

```bat
tools\status.bat "D:\Steam\steamapps\common\Cyberpunk 2077"
```

**冲突保护**：若 `bin\x64\dxgi.dll` 已被别的程序占用（如 ReShade；脚本查其 `OriginalFilename` 不是 `OptiScaler.dll`），安装会中止并提示；确要覆盖加 `-Force`，或用 `-Proxy winmm` 换代理名。

**可选参数**（PS 脚本）：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-Proxy <name>` | `dxgi` | 代理名：`dxgi`/`winmm`/`version`/`dbghelp`/`d3d12`/`wininet`/`winhttp`/`OptiScaler.asi` |
| `-FrameStride <n>` | `2` | 每 n 帧采 1 帧 |
| `-CaptureDepth` | 关 | 打开 depth 采集（Tier 2 才需要） |
| `-CaptureExposure` | 关 | 打开 exposure 采集 |
| `-NoIni` | 关 | 只铺文件，不改 ini |
| `-Force` | 关 | 覆盖已有安装记录 / 顶掉占用的代理 dll |

> 需要 PowerShell 5.1+（Win10/11 自带）。`.bat` 已带 `-ExecutionPolicy Bypass`，首次运行不会被执行策略拦。

> ⚠️ **维护提示（别改坏编码）**：`tools\*.bat` 必须保持 **纯 ASCII + CRLF**，`opti-capture-install.ps1` 必须保持 **UTF-8 with BOM + CRLF**。
> 中文 Windows 的 cmd 用 **GBK(936)** 读 `.bat`，若 `.bat` 里混入 UTF-8 中文，会串行（行尾多字节序列吃掉下一行首字符，报 `'nstall.bat' 不是内部或外部命令` 之类）。
> 而 PowerShell 5.1 读**无 BOM** 的 `.ps1` 会按 ANSI 解码，中文输出变乱码——所以 ps1 需要 BOM。

---

## 1. 第 ① 段：游戏内捕获

### 1.1 怎么触发（CET **没有**"控制台命令"）

**先说结论**：CET **不存在** `registerConsoleCommand` 这类 API。它的控制台只是一个 **Lua REPL** —— 输入原样交给 `ExecuteLua()` 执行，没有命令表。所以：

- 裸敲 `OptiCaptureStatus` **必然**报 `syntax error: '=' expected near '<eof>'`（裸标识符不是合法 Lua 语句）；
- 任何"自定义控制台命令"都注册不上。

证据（CET 源码）：`Console.cpp`（无命令表）、`ScriptContext.cpp`（只注入 `registerForEvent` / `registerHotkey` / `registerInput`，且 `init.lua` 跑完即置 nil）、`LuaSandbox.cpp`（每 mod 独立沙箱，控制台是独立的 sandbox 0）。

因此 mod 提供 **三种入口**：

**0. 屏幕 HUD + Page Up（默认，最省事）**

mod 用 CET 的 ImGui 在**屏幕中轴线顶端（距顶 60 px）**常驻一个鲜绿色小方块，黑字显示：
`状态（捕获中 / 捕获结束 / 待命）`、`已捕获秒数`、`帧数 · 体积`，触顶时显示原因。

- **Page Up**：开始 / 结束采集（在 `onDraw` 里用 `ImGui.IsKeyPressed(ImGuiKey.PageUp)` 检测；
  若你已在 Bindings 页把 `OptiCaptureToggle` 绑了键，则改由绑定回调触发，不会双触发）。
- **单次录制上限**：**5 分钟或 50 GiB，先到先停**（mod 强制，自动发 STOP）。

**A. 热键（Bindings 页绑定）**

mod 用 `registerHotkey` 注册了 5 个 id，去 **CET 覆盖层 → Bindings** 页绑定按键：

| id | 作用 |
| --- | --- |
| `OptiCaptureToggle` | 开始/结束（同 Page Up）。**若绑了它，内置 Page Up 检测会自动让位** |
| `OptiCaptureStart` | 写 `command.txt=START`。OptiScaler 在**下一个 DLSS 求值帧**开始采集 |
| `OptiCaptureStop` | 写 `command.txt=STOP`。当前帧采完后收尾并写 `manifest.json` |
| `OptiCaptureStatus` | 查询一次：`state / frames / dropped / inflight / bytes / 分辨率 / 输出目录` |
| `OptiCaptureWatch` | 开关"捕获中每 5 秒自动打印一次状态" |

**B. 控制台（尽力而为，注意要带括号）**

mod 会尝试把函数注入 CET 各沙箱共用的回退表。**加载时看 CET 日志**：

- 打印 `控制台可用（记得带括号）` → 控制台里这样调：

  ```lua
  OptiCaptureStatus()
  ```

  **必须带 `()`**。也可以试 `GetMod("optiscaler_capture"):Status()`。
- 打印 `控制台注入不可用` → 只能用 A 或 C。

**C. 完全不用 CET（零依赖）**

OptiScaler 侧只是**轮询 `command.txt`**。直接在

```
<游戏>\bin\x64\plugins\cyber_engine_tweaks\mods\optiscaler_capture\
```

新建 `command.txt`，内容写 `START` / `STOP` / `STATUS`，保存即可。OptiScaler 100 ms 内读到并**自动删掉**该文件。

通信不经过游戏渲染路径：OptiScaler 后台线程每 100 ms 轮询 `command.txt`、读完即删；每 1 s 写 `status.json`。

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
| `color_format` / `color_format_value` | **落盘**格式（枚举名 + 数值）。**必须按它分支解码**：`Compact=true` 时 color 落盘为 `R11G11B10_FLOAT`（4 B/px），`Compact=false` 时保留源格式 `R16G16B16A16_FLOAT`（8 B/px） |
| `color_source_format`（motion 同理 `motion_source_format`） | 源纹理格式，仅记录供溯源。motion 落盘在 Compact 时为 `R16G16_FLOAT`（4 B/px） |
| `color_row_pitch` / `color_tight_stride` / `color_rows` | 行对齐信息（文件内是 tight，无 padding） |
| `render_width` / `render_height` | DLSS 渲染分辨率 = color/motion 的尺寸 |
| `target_width` / `target_height` | 输出分辨率（host 会 `CreateFeature(render, target)` 上采样到此） |
| `is_hdr` | 为真则后处理**必须先 tone map**。host **内部已做** Reinhard tone map（除非 `--no-tone-map`） |
| `low_res_mv` | true = motion 已是 render 分辨率；false = 是 target 分辨率，**需降采样** |
| `jittered_mv` | MV 是否已含 jitter |
| `depth_inverted` | 深度是否反相（写进 NGX feature flags） |
| `auto_exposure` | 是否有自动曝光（写进 NGX feature flags） |
| `motion_scale_x` / `motion_scale_y` | `mv_pixels = raw_mv × scale`，由 `Evaluate` 的 `InMVScale` 完成。本会话实测 = 渲染分辨率 `1505, 847`（**不是 1.0**，因为是像素单位×分辨率） |
| `motion_units` | 固定 `"pixels"` |
| `motion_direction` | 固定 `"current_to_previous"` |
| `motion_resolution` | `"render"` 或 `"target"` |
| `jitter_x` / `jitter_y` | 亚像素抖动，存档 |
| `frame_time_ms` / `delta_time` | 帧时间（毫秒 / 秒） |

> **体积（本会话实测，源都是 `R16G16B16A16_FLOAT` = 8 B/px）**：
> - **`Compact=true`（默认）**：color `R11G11B10_FLOAT`(4) + motion `R16G16_FLOAT`(4) = **8 B/px** → `1505×847×8 ≈ 9.7 MiB/帧`
> - `Compact=false`（旧行为）：color + motion 都 8 B/px = **16 B/px** → `≈ 19.45 MiB/帧`
> stride=2、60fps 下前者约 `292 MiB/s ≈ 17 GiB/分钟`；838 帧对应 `manifest.json` 的 `bytes_written`。
> 无损性：motion 只丢未用的 B/A；color 用 R11G11B10 保留 HDR 范围，相对误差 R/G<0.8%、B<1.6%（离线还要 tone map 到 8-bit，无感）。

### 1.4 建议采样流程

1. 游戏内把 DLSS 超分开到你想采的档位，关闭帧生成。
2. `OptiCaptureStart` → `OptiCaptureWatch`。
3. 走一段**有明确相机运动**的镜头（横移/推进），10~20 秒足够（stride=2、60fps → 约 300~600 帧）。
4. `OptiCaptureStop`，等 `status.json` 显示 `state=stopped`。
5. 退出游戏，把整个 `session_<时间戳>\` 拷到渲染机。

---

## 2. 第 ② 段：离线后处理为 DLSS 5 视频

### 2.0 先把 host 编译好（含 `--capture`）

`--capture` 代码已进 `DLSS5-Feeder/host/dlss5-feed-host64.cpp`，需重新编译：

- **CI**：`DLSS5-Feeder` 的 build 流程已含 `call host\build-host.bat`，推到 main 后即产出新的 `dlss5-feed-host64.exe`。
- **本地**（Windows + VS）：在「Developer Command Prompt」里 `cd host && build-host.bat`（需要 NGX SDK 在 `external\ngx`）。

### 2.1 命令（已实现，与 `--test` 同一套 host 代码）

```bat
:: 离线机用与 --test 同一目录布局：旁边必须有 ReShade(dxgi.dll) + renodx-dlss5 add-on + OptiScaler（feature 18 的神经消费者）
:: 即 --test 能跑出 300/300 的那套环境
dlss5-feed-host64.exe --capture "D:\cap\session_20261005_213000" --out "D:\out\dlss5" --fps 30
```

| 参数 | 含义 |
| --- | --- |
| `--capture <dir>` | 捕获会话目录（含 `manifest.json`） |
| `--out <dir>` | 输出目录，写 `frame_%06d.bmp` 序列 + `result.json`（24-bit BMP：双击可看、ffmpeg 可读；host 内**无 PNG/EXR 编码器**，故用 BMP） |
| `--fps <n>` | 仅写进 `result.json` 供 ffmpeg 用；不影响渲染 |
| `--max-frames <n>` | 最多跑前 n 帧后停（默认跑到首个缺失帧为止） |
| `--flip-motion` | 可选。方向实测不符时取反（见 §2.4） |
| `--no-tone-map` | 可选。跳过 tone map（debug 用；HDR 源不 map 会高光炸白） |

host 启动时无窗口（headless，同 `--test`），frame 逐帧读盘 → 上传 GPU（`CopyTextureRegion`）→ NGX 求值 → 回读 → 写 BMP。帧目录断在哪就停在哪（拷了 60 帧就跑 60 帧）。

### 2.2 host 内部逐帧做什么（复用 `RunTest()` 的骨架，另起 `RunCapture()`）

```
for each frame_NNNNNN/:
    read frame.json
    1. color:  按 frame.json 的 color_format 解码（R11G11B10_FLOAT 或 R16G16B16A16_FLOAT）
               → Reinhard tone map（除非 --no-tone-map）→ RGBA8 纹理
    2. motion: 按 motion_format 解码（R16G16_FLOAT 直接是 RG；R16G16B16A16_FLOAT 取 RG 两通道）
               → 写 R16G16_FLOAT 纹理
               （mv ×= motion_scale 由 Evaluate 的 InMVScale 完成，host 原样传 frame.json 的 scale）
    3. depth:  会话未采集(CaptureDepth=false)时，host 喂一张常量平面（日志会说明）
               —— 若输出明显异常，重采时开 CaptureDepth=true
    4. flags = 由 frame.json 推导（见 §2.3）
    5. CreateFeature(render_w, render_h, flags, &rf, target_w, target_h)  // 上采样到 target
       Evaluate(color, output, depth, mv, render_w, render_h,
                reset = (index==0), mvsx, mvsy, jitter_x, jitter_y, settle=0, hold=0)
    6. 读回 output（target 分辨率）→ 写 frame_%06d.bmp
```

### 2.3 NGX 契约（来自你机器上 `ReShade.log` 的实测，不是猜的）

| 项 | 值 |
| --- | --- |
| `flags` | `0x4a` = `MVLowRes(2) \| DepthInverted(8) \| AutoExposure(64)` |
| `mvec` | `render`（低分辨率，与 ComfyUI/host 期望一致） |
| `scale` | 由 frame.json 的 `motion_scale_x/y` 决定（本会话实测 = 渲染分辨率 `1505, 847`，即像素单位×分辨率，**不是 1.0**；`mv_pixels = raw × scale` 由 `Evaluate` 的 `InMVScale` 完成） |
| `encoding` | `linear` |
| `exposure` | `none` |

**flags 推导**（host 从 `frame.json` 读，不再硬编码）：

```
flags = 0
if low_res_mv:      flags |= MVLowRes
if depth_inverted:  flags |= DepthInverted
if auto_exposure:   flags |= AutoExposure
# is_hdr 不进 flags：HDR 由 color 侧 tone map 处理，NGX 拿到的已是 SDR
```

### 2.4 两个必须实测校正的量（只能在游戏机上定）

1. **motion 方向**：`frame.json` 写死 `current_to_previous`（与 NGX 约定一致，理论上无需取反）。若输出出现**拖影/反向抖动**，加 `--flip-motion` 重跑对比。
2. **motion 尺度**：`motion_scale_x/y` 由捕获层从 `MV.Scale.X/Y` 读取，本会话实测 = 渲染分辨率（**非 1.0**）。若输出时间不稳定，检查 `low_res_mv` 与 scale 是否被正确应用（`mv_pixels = raw × scale`）。

### 2.5 合成视频

```bash
# 渲染机（Ubuntu 或 Windows 均可，ffmpeg 即可）
ffmpeg -framerate 30 -i frame_%06d.bmp -c:v libx264 -crf 16 -pix_fmt yuv420p dlss5_out.mp4
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

仓库 `tools/verify_capture.py` 已实现离线校验（**纯 CPU，Ubuntu 直接跑，无需 GPU/游戏**）：

```bash
python3 tools/verify_capture.py "D:\cap\session_20261005_213000"   # 路径在 WSL/Ubuntu 下换成 /mnt/...
```

它会逐帧解码 `color.bin`/`motion.bin`、统计 motion 分布、核对帧数。本会话实测：`captured_frames=838`、`dropped=0`；motion p99≈0.00007 → 归一化 MV（scale=分辨率是对的）；每帧位移极小（2 秒镜头本就动得少，正常）。

这一步在 Ubuntu 上就能做，不需要 GPU/游戏。如果校验不过，先别动 host——是捕获层的问题。

---

## 4. 排错

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| CET 控制台报 `syntax error: '=' expected near '<eof>'` | CET 没有自定义命令，裸敲标识符不是合法 Lua | 用热键；或带括号 `OptiCaptureStatus()`；或手写 `command.txt`（见 §1.1） |
| CET 执行 START 无反应 | `[Capture] Enabled` 不是 `true` | 改成 `true` 后重启游戏 |
| `status.json` 里 `dropped` 持续增长 | 回读环（6 槽）跟不上 | 增大 `FrameStride` |
| 日志 `channel 'x' unavailable: missing [Hotfix] barrier config` | `[Hotfix]` 对应键没设 | 补上正确的 resource state 整数 |
| `color.bin` 存在但解码花屏 | `color_format` 分支未覆盖 | 看 `frame.json` 里的实际枚举名再补分支 |
| 输出视频高光炸白 | HDR 源未 tone map | host 默认已 tone map；确认没误加 `--no-tone-map`，或加 `--no-tone-map` 对比找原因 |
| 输出拖影 | motion 方向反了 | 加 `--flip-motion` |
| 输出抖动/时间不稳 | motion scale 或分辨率没处理 | 检查 `motion_scale_x/y` 与 `motion_resolution`（见 §2.3） |
| 输出整体发灰/无 NR 痕迹 | depth 是常量平面（CaptureDepth=false） | 重采时开 `CaptureDepth=true`（见 §0.2 / §2.2 第 3 步） |
| 离线 host 报 `feature 18` 没创建 | 离线目录缺 OptiScaler / renodx-dlss5 add-on | 与 `--test` 同环境（见 §0.1 / §2.1） |
| 旧 host 读新会话报 `has no usable color.bin` | `Compact=true` 改了落盘格式（4 B/px），旧 host 按 8 B/px 读 | 用配套的新 host；或把 ini 的 `Compact=false` 关掉重采 |
| 日志 `device adapter: Intel(R) UHD Graphics … (DXGI's default adapter)` + `NGX unavailable` | hybrid 笔记本上 DXGI 默认适配器是核显，NGX 是 NVIDIA 专用运行时 | 已修复：host 现在优先选 NVIDIA 适配器（`PickNgxAdapter`）。旧版可在 Windows 设置→显示→图形里给 exe 指定"高性能"，或 NVIDIA 控制面板指定独显 |
| 装脚本报 `dxgi.dll 已存在，且不是 OptiScaler` | 代理名被 ReShade 等占用 | 换 `-Proxy winmm`；确认要顶掉才加 `-Force` |
| 装脚本报 `已存在安装记录` | 上次没卸载 | 先 `uninstall.bat`，或 `-Force`（会丢弃旧备份） |
| `uninstall.bat` 报 `没找到安装记录` | 游戏目录不对，或记录被删 | 传对游戏目录；否则只能手工删 |
| 卸载后仍剩 `session_*` / `OptiScaler.log` | 设计如此（采集数据不自动删） | 手工删 |
| cmd 报 `此时不应有 <`（`< was unexpected at this time`） | 命令/注释里的 `< >` 被 cmd 当重定向解析 | 占位符改用 `[ ]`；`.bat` 注释里也别写裸 `< >` |

---

## 5. 一句话速查

```text
占位符一律用 [ ] 表示，别用 < > —— cmd 会把尖括号当重定向，直接报"此时不应有 <"

一键装:  tools\install.bat [已解压的 OptiScaler 目录] [已解压的 CET 目录] [游戏目录]
一键卸:  tools\uninstall.bat [游戏目录]
查状态:  tools\status.bat [游戏目录]
        （等价手工：解压到 bin\x64\ + 跑 setup_windows.bat 选 dxgi.dll；
          CET mod → plugins\cyber_engine_tweaks\mods\optiscaler_capture\init.lua）
改 ini:  [Capture] Enabled=true, FrameStride=2, CaptureColor/Motion=true, Compact=true
         [Hotfix] ColorResourceBarrier=64, MotionVectorResourceBarrier=64
游戏内:  Page Up 开始/结束（屏幕顶端绿框显示 秒数/状态/体积；单次上限 5min 或 50GiB）
         （或热键 OptiCaptureToggle；手写 command.txt 写 START / STOP；CET 控制台无自定义命令）
输出:    bin\x64\plugins\cyber_engine_tweaks\mods\optiscaler_capture\session_[时间戳]\
离线:    dlss5-feed-host64.exe --capture [session] --out [out] --fps 30
         （同 --test 环境：ReShade(dxgi.dll)+renodx-dlss5 add-on+OptiScaler）
合成:    ffmpeg -framerate 30 -i frame_%06d.bmp -c:v libx264 -crf 16 -pix_fmt yuv420p dlss5_out.mp4
校验:    python3 tools/verify_capture.py [session]
```
