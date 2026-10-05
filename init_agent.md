开工 Prompt：Cyberpunk 2077 引擎数据捕获 → 离线 DLSS 5 转换管线

一、项目目标

在 Ubuntu 开发环境下，通过修改 OptiScaler 和编写配套转换器，实现以下工作流：

1. 游戏期间：OptiScaler 在《赛博朋克2077》运行期间，通过 CET 控制台命令触发，将 DLSS 神经渲染所需的原始 GPU 数据（Color、Depth、Motion Vector、Exposure、Jitter、Frame timing）只采集、只写盘，不转换、不生成、不干预游戏内容。
2. 游戏结束后：由用户手动运行一个独立的转换器，将采集到的原始 GPU 数据转换为 ComfyUI-DLSS5-Enhancer 所需的输入格式。
3. 最终输出：由用户在 ComfyUI 中运行 DLSS5-Enhancer 节点，生成经过 DLSS 5 神经渲染增强的视频。

二、交付物

1. 修改版 OptiScaler 模组：包含捕获层 + CET 命令通信。
2. 转换器：独立可执行程序或 Python 脚本，将捕获数据转为 ComfyUI-DLSS5-Enhancer 输入格式。
3. ComfyUI-DLSS5-Enhancer 使用示例：一份 workflow JSON 或 Python 脚本，展示如何读取转换后的数据并生成 DLSS5 视频。

三、开发环境与编译约束

约束 说明
开发环境 Ubuntu。所有代码编写、仓库管理在 Ubuntu 完成。
编译环境 GitHub Actions（windows-latest）。不要在 Windows 机器上安装 MSVC 或任何开发工具。
游戏环境 仅用于运行游戏和最终 ComfyUI 渲染。游戏机器上不要求安装编译器、CMake、Python 开发环境。

四、前置步骤：克隆两个仓库并对比

/home/erashaperavm/文档/cp77dlss5gen/ComfyUI-DLSS5-Enhancer
/home/erashaperavm/文档/cp77dlss5gen/OptiScaler

然后阅读以下关键文件，理解两边的数据格式：

OptiScaler 侧（重点文件）：

· OptiScaler/inputs/NVNGX_DLSS_Dx12.cpp — DLSS 输入参数的处理位置，NVSDK_NGX_D3D12_DLSS_Eval_Params 结构体中包含 pInColor、pInDepth、pInMotionVectors、pInExposureTexture、InJitterOffsetX/Y。
· OptiScaler/framegen/IFGFeature_Dx12.h — 帧生成资源捕获逻辑，_frameResources[index] 中存储了 Depth、Motion Vectors、Color 等资源。
· OptiScaler/OptiScaler.ini — 确认 EnableDlssInputs 和 MotionVectorResourceBarrier 的配置项。

ComfyUI-DLSS5-Enhancer 侧（重点文件）：

· README.md — 明确协议：ComfyUI 节点发送 “RGBA8 frame + FP16 motion vectors + history reset flag” 给原生 D3D12 worker，worker 返回 “RGBA8 reconstructed frame”。
· nodes.py 或 __init__.py — 找到二进制协议的打包/解包逻辑，以及视频文件解码和光流估算的代码位置。
· 找到 worker 进程的启动入口（很可能是 subprocess 或 multiprocessing），理解它如何接收帧数据。

对比后的输出：AI agent 需要在代码注释或单独的 INTEGRATION_NOTES.md 中写清楚：OptiScaler 的 color.bin（什么格式）→ ComfyUI 期望的 RGBA8（需要什么转换）；OptiScaler 的 motion.bin（什么格式、什么方向）→ ComfyUI 期望的 FP16 motion vectors（需要什么校验和修正）。

五、OptiScaler 修改任务

5.1 捕获层实现

在 NVNGX_DLSS_Dx12.cpp 中，NVSDK_NGX_D3D12_EvaluateFeature 被调用之前，插入捕获钩子。捕获以下六类数据：

数据 来源 保存格式
Color ep.pInColor 原始二进制（记录 DXGI_FORMAT 和 rowPitch）
Depth ep.pInDepth 原始二进制
Motion Vector ep.pInMotionVectors 原始二进制
Exposure ep.pInExposureTexture 原始二进制（可能为 null，跳过）
Jitter ep.InJitterOffsetX/Y JSON
Frame timing delta_time JSON

回读逻辑要求：

1. 保存源资源的 D3D12_RESOURCE_DESC。
2. 用 GetCopyableFootprints 计算回读缓冲区大小和 rowPitch。
3. 创建 READBACK 堆（D3D12_HEAP_TYPE_READBACK）上的缓冲区。
4. 在命令列表中执行 ResourceBarrier（转换到 COPY_SOURCE）→ CopyTextureRegion → ResourceBarrier（转换回原状态）。
5. 提交命令列表，用 fence 同步，等待 GPU 完成。
6. Map 回读缓冲区，写入文件，Unmap。

关键约束：

· 必须使用 D3D12_HEAP_TYPE_READBACK，不能用 UPLOAD。
· 必须记录 rowPitch，不能用 width * bytesPerPixel 计算。
· 必须在复制前后正确管理资源状态，否则会破坏游戏渲染管线。
· 建议使用独立的命令队列 + 命令分配器专用于回读，避免干扰游戏主渲染队列。
· 捕获层必须默认关闭，只有通过 CET 命令显式启动后才激活。关闭时不能影响正常 DLSS 超采样逻辑。

5.2 CET 命令通信（文件轮询）

OptiScaler 是 C++ DX12 层，CET 是 Lua 脚本环境。两者通过文件轮询通信：

```
Cyberpunk 2077\bin\x64\plugins\cyber_engine_tweaks\mods\optiscaler_capture\
├── command.txt          # CET 写入命令，OptiScaler 轮询读取
└── status.json          # OptiScaler 写入状态，CET 轮询读取
```

命令格式：START / STOP / STATUS

OptiScaler 侧：在 Present 回调中每帧检查 command.txt，读取后立即清空。START 调用 StartCapture()，STOP 调用 StopCapture()，STATUS 写入 status.json。使用 CreateFile + FILE_SHARE_READ | FILE_SHARE_WRITE 避免读写冲突。状态文件每秒写入一次，不要每帧写。

CET 侧 Lua 脚本（optiscaler_capture/init.lua）：

```lua
local captureDir = "plugins/cyber_engine_tweaks/mods/optiscaler_capture/"
local commandFile = captureDir .. "command.txt"
local statusFile = captureDir .. "status.json"

registerForEvent("onInit", function()
    registerConsoleCommand("OptiCaptureStart", "开始 DLSS 输入资源捕获", function()
        local f = io.open(commandFile, "w")
        if f then f:write("START"); f:close()
            print("[OptiScaler Capture] 已发送 START") end
    end)
    registerConsoleCommand("OptiCaptureStop", "停止捕获", function()
        local f = io.open(commandFile, "w")
        if f then f:write("STOP"); f:close()
            print("[OptiScaler Capture] 已发送 STOP") end
    end)
    registerConsoleCommand("OptiCaptureStatus", "查询捕获状态", function()
        local f = io.open(commandFile, "w")
        if f then f:write("STATUS"); f:close() end
        local sf = io.open(statusFile, "r")
        if sf then print("[OptiScaler Capture] " .. sf:read("*a")); sf:close() end
    end)
end)
```

5.3 文件格式

```
capture/
├── manifest.json          # 全局信息：分辨率、总帧数、起始帧索引、捕获开始时间
├── frame_000000/
│   ├── color.bin
│   ├── depth.bin
│   ├── motion.bin
│   ├── exposure.bin       # 可能为空
│   └── frame.json         # 每帧元数据
├── frame_000001/
│   └── ...
└── ...
```

frame.json 必须包含：

```json
{
  "width": 2560,
  "height": 1440,
  "color_format": "DXGI_FORMAT_R11G11B10_FLOAT",
  "color_row_pitch": 10240,
  "depth_format": "DXGI_FORMAT_R32_FLOAT",
  "depth_row_pitch": 10240,
  "motion_format": "DXGI_FORMAT_R16G16_FLOAT",
  "motion_row_pitch": 10240,
  "motion_scale_x": 1.0,
  "motion_scale_y": 1.0,
  "jitter_x": 0.0,
  "jitter_y": 0.0,
  "frame_index": 0,
  "delta_time": 0.01667
}
```

六、GitHub Actions 工作流

在 OptiScaler 仓库的 .github/workflows/ 下创建 build-capture.yml。

参考现有工作流：OptiScaler 官方已有 GitHub Actions 构建流程，使用 MSBuild 和 setup-msbuild。AI agent 应该先查看 .github/workflows/ 下已有的 YAML 文件，复用它们的 MSVC 环境配置和 artifact 上传逻辑。

新工作流要求：

```yaml
name: Build Capture Mod
on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  build:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive
      - uses: microsoft/setup-msbuild@v3
      - name: Build
        run: msbuild OptiScaler.sln /p:Configuration=Release /p:Platform=x64
      - uses: actions/upload-artifact@v4
        with:
          name: OptiScaler-Capture-Release
          path: |
            **/OptiScaler.asi
            **/OptiScaler.dll
            **/*.dll
```

注意：实际的项目路径、解决方案文件名、输出目录需要 AI agent 根据仓库实际结构调整。如果官方已有 build.yml，优先复用，只添加 artifact 上传步骤。

七、转换器任务

转换器是一个独立的 Python 脚本（在 Ubuntu 上运行，或在 Windows 上运行但不依赖开发环境），负责将 capture/ 目录转换为 ComfyUI-DLSS5-Enhancer 可接受的输入。

必须完成的三件事：

1. 颜色格式转换：将 color.bin（R11G11B10_FLOAT 或其他 HDR 格式）转换为 RGBA8。如果游戏开了 HDR，需要做 tone mapping 后再转 8bit。
2. 运动矢量校验与转换：确认 motion.bin 的语义（归一化 UV 还是像素偏移）和方向（current-to-previous 还是 previous-to-current）。ComfyUI-DLSS5-Enhancer 期望的是 FP16 运动矢量，使用归一化的 UV 运动，方向为 current-to-previous。如果方向不对，取反；如果尺度不对，乘以或除以 (width, height)。
3. 打包为 ComfyUI 可读格式：根据 ComfyUI-DLSS5-Enhancer 的实际协议（AI agent 需要从 nodes.py 中读出确切的打包格式），将每帧的 RGBA8 frame + FP16 motion vector 打包成二进制流或中间文件。

推荐方案：转换器输出一个中间目录，包含 frame_%06d_rgba.bin 和 frame_%06d_mv.bin，以及一个 meta.json 记录分辨率和帧率。然后 fork ComfyUI-DLSS5-Enhancer 的节点代码，添加一个“从捕获目录读取”的输入模式，在节点内部完成协议打包。

不要做：不要在游戏运行时做任何转换。转换器只在游戏退出后运行。不要在转换器里引入 GPU 依赖（不需要 CUDA 或 D3D12），纯 CPU 格式转换即可。

八、ComfyUI-DLSS5-Enhancer 使用示例

交付一份 example_workflow.json，展示：

1. 加载转换后的捕获数据（通过一个自定义节点或修改后的现有节点）。
2. 传入 DLSS5-Enhancer 的渲染节点。
3. 输出增强后的视频。

AI agent 需要先读完 ComfyUI-DLSS5-Enhancer 的 nodes.py 和 README，理解它的节点输入类型（VIDEO、IMAGE 等）和参数，然后写一个最小可用的 workflow JSON。

九、AI Agent 的执行顺序

```
Step 1: clone OptiScaler + ComfyUI-DLSS5-Enhancer
Step 2: 读两个仓库的关键文件，输出 INTEGRATION_NOTES.md（两边格式差异 + 对接点）
Step 3: 修改 OptiScaler，实现捕获层 + CET 命令通信
Step 4: 添加 GitHub Actions 工作流
Step 5: 推送到 GitHub，等待 Actions 编译，下载 artifact
Step 6: 写转换器（Python）
Step 7: 写 ComfyUI 使用示例
Step 8: 输出 README-CAPTURE.md，说明完整工作流
```

第 2 步  Step 3 捕获层 + CET（不变，照原计划）
         └─ 务必把 depth 采上（Tier 2 需要）

第 3 步  Tier 1 打通（ComfyUI，Steps 6-8）
         └─ 目的不是交付，是验证捕获数据正确：
            color 能解、MV 方向/尺度对、无鬼影
         迭代成本最低，出问题最便宜

第 4 步  读 OptiScaler DLSS-NR 源码（0.5天）
         └─ 确认 NR pass 到底消费哪些缓冲 → 决定第 5 步值不值得

第 5 步  Route 1：fork DLSS5-Feeder 改离线
         └─ 此时引擎数据已被第 3 步验证过，只剩契约层要写

A. 捕获层编译 → 游戏机上采一小段（先决条件，阻塞后面所有事）
B. 纯 CPU 捕获校验器（Python）→ Ubuntu 上验证 color/motion/depth 正确   ← 替代 ComfyUI 的验证路径
C. DLSS5-Feeder 离线 host（读 B 确认过的数据）
并行 D. 确认 nvngx_dlssnr.dll + RenoDX add-on 能否拿到

另一个观察
renodx-dlss5.addon64 v8.5.0-rc10 是 release candidate。host 的版本探测把它标成 "(v4.7 lineage; neural pass measured working on driver 617.14)"——host 自己断言这个组合在 617.14 上是好的。如果后面渲染出现异常，第一个怀疑对象就是它，可以回退到 README 表格里明确 ✅ 的 v8.0.1 或 v7.0.0-rc8。



每一步完成后，AI agent 应该停下来，让你确认再继续。 不要一口气把三个交付物全写完再给你看。先确认仓库结构理解正确，再动代码。

十、关键约束回顾

约束 说明
游戏时只采集 不转换、不生成、不干预游戏内容。捕获层默认关闭。
Windows 不装开发环境 编译在 GitHub Actions，转换器是 Python 脚本，ComfyUI 用 portable 版本，Windows 有 RTX 显卡。
Ubuntu 开发 代码编写、仓库管理、转换器开发都在 Ubuntu，但 Ubuntu 没有 RTX 显卡。
利用引擎数据 运动矢量来自游戏引擎，不是光流估算。这是整个方案的质量优势来源。
不猜 ComfyUI 需求 AI agent 必须从 ComfyUI-DLSS5-Enhancer 的源码中读出实际协议，不要凭记忆或猜测。