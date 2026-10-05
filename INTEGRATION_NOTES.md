# INTEGRATION_NOTES.md — OptiScaler 捕获 → ComfyUI-DLSS5-Enhancer 对接分析

> Step 2 交付物。本文档只做**事实核对**与**格式差异分析**，不包含实现代码。
> 所有结论均来自两个仓库的实际源码，凡与原始 Prompt 假设不一致处，均以 `⚠️ 修正` 标出。

---

## 0. 仓库状态（Step 1 完成）

| 仓库 | 路径 | remote | HEAD |
| --- | --- | --- | --- |
| OptiScaler | `./OptiScaler` | `https://github.com/optiscaler/OptiScaler.git` | `500ed335 Slopification of dx12 hooks` |
| ComfyUI-DLSS5-Enhancer | `./ComfyUI-DLSS5-Enhancer` | `https://github.com/Blueforcer/ComfyUI-DLSS5-Enhancer.git` | `796ed59 Update README.md` |

两个仓库都已是完整 git 仓库，Step 1 无需重新 clone。

---

## 1. ComfyUI-DLSS5-Enhancer 侧：真实协议（从源码读出）

### 1.1 进程模型

`dlss5/session.py:67` 使用 `subprocess.Popen([str(layout.worker), "--video"], cwd=layout.root, stdin=PIPE, stdout=PIPE, stderr=PIPE)`。
即 **一个原生 D3D12 worker 进程，通过 stdin/stdout 二进制管道通信**，不是 socket、不是共享内存。每次渲染启动一次（`DlssSession` 每个节点执行构造一个）。

worker 文件名固定为 `nvngx.dll`（README 明确说明这是签名调用契约要求），**Windows only**。

### 1.2 线上格式（`dlss5/protocol.py`，协议版本 4，全部小端、紧凑打包）

常量 magic：
- `VIDEO_MAGIC = 0x34563544`、`SETUP_MAGIC = 0x34505553`
- `FRAME_MAGIC = 0x314D5246`、`OUT_MAGIC = 0x3154554F`

| 结构 | struct | 大小 | 方向 | 字段 |
| --- | --- | --- | --- | --- |
| `VIDEO_HEADER` | `<14I4f` | 72 B | client→worker（一次） | magic, input_w, input_h, output_w, output_h, warmup_frames, frame_count, perf_quality, dlss_model_preset, profile, preset, style, auto_mask, ui_correction, intensity, local_tone, local_structure, skin_structure |
| `SETUP_RESPONSE` | `<12I` | 48 B | worker→client（一次） | magic, ok, result, render_w, render_h, output_w, output_h, min_w, min_h, max_w, max_h, applied_model_preset |
| `FRAME_HEADER` | `<4Iq` | 24 B | client→worker（每帧） | magic, index, reset(0/1), 保留0, pts(int64) |
| `RESULT_HEADER` | `<5Iq` | 28 B | worker→client（每帧） | magic, index, ok, byte_count, ngx_result, pts(int64) |

### 1.3 每帧实际负载（这是最关键的事实）

client→worker（`session.py:238-241`）：

```
FRAME_HEADER(24B)
+ RGBA8 像素 : render_height * render_width * 4 字节   (uint8, 连续)
+ motion     : render_height * render_width * 2 * 2 字节 (float16, 连续)
```

worker→client（`session.py:261`）：

```
RESULT_HEADER(28B)
+ RGBA8 像素 : output_height * output_width * 4 字节
```

注意点：
1. **输入帧尺寸是 `setup.render_width × render_height`（协商出来的 render 分辨率），不是 VIDEO_HEADER 里的 input_width/input_height**。节点侧 `nodes/enhance_images.py:89` 先 `fit_frame(..., session.render_width, session.render_height)` 再提交。
2. **motion 是每个像素 2 个 float16**（H×W×2），不是 1 个通道。
3. **没有 depth、没有 exposure、没有 jitter 字段**。

### 1.4 motion 的确切语义（`dlss5/motion.py`）

这是本次集成最容易出错的地方，源码给出了明确答案：

```python
# motion.py:3-6 docstring
"""A decoded video has no motion vectors, so they are estimated with dense optical
flow.  DLSS expects backward motion (where a pixel came from), computed at the
render resolution and stored as FP16."""

# motion.py:87  flow from the current frame back to the previous one
flow = self._flow.calc(current, self._previous_gray, None)
...
flow[..., 0] *= self.width / self.flow_width
flow[..., 1] *= self.height / self.flow_height
motion = np.ascontiguousarray(flow.astype(np.float16))
```

由此**确定**：

| 属性 | 结论 |
| --- | --- |
| 方向 | **backward = current-to-previous**（当前帧像素 → 它在上帧的位置） |
| 单位 | **像素（pixel）**，不是归一化 UV。`flow` 是 OpenCV DIS 的像素位移，只做分辨率缩放，没有除以 width/height |
| 分辨率 | **render 分辨率**（`TemporalGuide(session.render_width, session.render_height, ...)`，`enhance_images.py:74`） |
| dtype | `float16` |
| 布局 | 连续 `(H, W, 2)`，x 在前、y 在后 |

> ⚠️ **修正（相对原始 Prompt）**：Prompt 第五节写“ComfyUI 期望的是 FP16 运动矢量，使用**归一化的 UV 运动**，方向为 current-to-previous”。
> 源码证明后半句（方向）正确，但**前半句错误**：ComfyUI worker 期望的是 **render 分辨率下的像素位移**，不是归一化 UV。
> 若转换器按 UV 归一化输出，运动矢量会小 2~3 个数量级，时间累积会直接失效。

### 1.5 其他会影响转换器的行为

- `reset` 标志：第一帧强制 `True`；场景切换（`scene_score > scene_change_threshold`，默认 0.24）也置 `True`（`motion.py:79-82`）。捕获数据里没有这个判断，转换器需要自己算，或统一每帧传 `False` 只在首帧 `True`。**建议转换器实现与 `motion.py` 等价的场景切换检测**，否则历史会串帧。
- `pts`：节点传的是帧序号 `index`（`enhance_images.py:100`）。捕获侧用引擎的真实帧时间戳更有意义，但要注意单调递增。
- `motion = none` 模式下 ComfyUI 发全零运动矢量且只 reset 一次（`motion.py:68-74`）。
- 节点会校验 `header.ngx_result != 1` 直接报错（`session.py:256`），即 worker 内部 NGX 失败会中断。
- `keep_alpha`：4 通道输入会保留 alpha 并旁路（`enhance_images.py:102-106`）。捕获侧没有 alpha，转换器输出 RGB 即可，节点会自动补 255。

### 1.6 节点输入类型（写 example workflow 时用）

- `DLSS5Settings`（`nodes/settings_node.py`）→ 输出自定义类型 `DLSS5_SETTINGS`。
- `DLSS5EnhanceImages`：输入 `IMAGE` + `DLSS5_SETTINGS` + `verify_neural_rendering(bool)`，输出 `IMAGE`（`node_id="DLSS5EnhanceImages"`，category `image/upscaling`）。
- `DLSS5EnhanceVideoFile`：文件进、文件出，输出 `STRING`(路径) + `INT`(帧数)。
- **没有**任何“从目录读取帧序列”的节点。因此原 Prompt 建议的“fork 节点加输入模式”是必要的，或者写一个前置的自定义 IMAGE 加载节点。

---

## 2. OptiScaler 侧：DLSS 输入的真正来源

### 2.1 ⚠️ 关键修正：不存在 `NVSDK_NGX_D3D12_DLSS_Eval_Params` 这个入口

原始 Prompt 说“`NVNGX_DLSS_Dx12.cpp` 中 `NVSDK_NGX_D3D12_EvaluateFeature` 被调用之前……`NVSDK_NGX_D3D12_DLSS_Eval_Params` 结构体中包含 `pInColor`、`pInDepth`……”。

实际源码（`inputs/NVNGX_DLSS_Dx12.cpp:1086`）：

```cpp
NVSDK_NGX_Result NVSDK_NGX_D3D12_EvaluateFeature(
    ID3D12GraphicsCommandList* InCmdList,
    const NVSDK_NGX_Handle* InFeatureHandle,
    NVSDK_NGX_Parameter* InParameters,     // <-- 不透明参数表，不是 Eval_Params 结构体
    PFN_NVSDK_NGX_ProgressCallback InCallback)
```

`NVSDK_NGX_D3D12_DLSS_Eval_Params` 只存在于 **Vulkan** 头文件 `external/nvngx_dlss_sdk/nvsdk_ngx_helpers_vk.h`（用于 `NVSDK_NGX_VULKAN_EvaluateFeature_C` 的 helper）。D3D12 路径下，游戏是**逐字段**把资源塞进 `InParameters` 的。

**结论**：捕获钩子必须从 `NVSDK_NGX_Parameter* InParameters` 里按 key 取值，而不是读结构体成员。

### 2.2 正确的插入点

`NVNGX_DLSS_Dx12.cpp` → `TryEvaluateOptiFeature()`，在 `feature->Evaluate(...)` **之前**（现文件 1053~1061 行附近）：

```cpp
    // Prepare upscaling inputs
    UpscalerInputsDx12::UpscaleStart(InCmdList, InParameters, feature);   // 1054
    FSR3FG::SetUpscalerInputs(InCmdList, InParameters, feature);          // 1055

    // >>> 捕获钩子插入点：InCmdList 与 InParameters 都在手，资源处于本帧最终状态 <<<

    bool evalSuccess = false;
    {
        ScopedSkipHeapCapture skip {};
        evalSuccess = feature->Evaluate(InCmdList, InParameters);         // 1061
        UpscalerInputsDx12::UpscaleEnd(InCmdList, InParameters, feature); // 1064
    }
```

不选 `UpscalerInputsDx12::UpscaleStart` 的原因：该函数在 `inputs/FG/Upscaler_Inputs_Dx12.cpp:96-97` 处提前 return——

```cpp
auto fg = State::Instance().currentFG;
if (fg == nullptr || State::Instance().activeFgInput != FGInput::Upscaler || _device == nullptr)
    return;
```

也就是说**只有开启帧生成且 FG 输入源为 Upscaler 时**才会走到资源提取，普通 DLSS 超分场景根本不会执行。不能依赖它。

### 2.3 参数 key 名（`external/nvngx_dlss_sdk/nvsdk_ngx_defs.h`）

| 数据 | key 宏 | 字符串 | 取值方式 |
| --- | --- | --- | --- |
| Color | `NVSDK_NGX_Parameter_Color` | `"Color"` | `Get(key, &ID3D12Resource* ptr)`，失败再 `Get(key, (void**)&ptr)` |
| Depth | `NVSDK_NGX_Parameter_Depth` | `"Depth"` | 同上 |
| Motion Vector | `NVSDK_NGX_Parameter_MotionVectors` | `"MotionVectors"` | 同上 |
| Exposure | `NVSDK_NGX_Parameter_ExposureTexture` | `"ExposureTexture"` | 1×1 纹理，**可能为 null，必须跳过** |
| Jitter X/Y | `NVSDK_NGX_Parameter_Jitter_Offset_X/Y` | `"Jitter.Offset.X"` / `"Jitter.Offset.Y"` | `Get(key, &float)` |
| MV Scale X/Y | `NVSDK_NGX_Parameter_MV_Scale_X/Y` | `"MV.Scale.X"` / `"MV.Scale.Y"` | `Get(key, &float)` |
| Reset | `NVSDK_NGX_Parameter_Reset` | `"Reset"` | `Get(key, &int)` |
| 帧时间 | `NVSDK_NGX_Parameter_FrameTimeDeltaInMsec` | `"FrameTimeDeltaInMsec"` | `Get(key, &float)`，单位**毫秒** |
| Output | `NVSDK_NGX_Parameter_Output` | `"Output"` | 上采样输出（不需要捕获） |

双段式取指针写法是仓库里的既有惯例，例如 `inputs/FG/Upscaler_Inputs_Dx12.cpp:162`：

```cpp
ID3D12Resource* paramVelocity = nullptr;
if (InParameters->Get(NVSDK_NGX_Parameter_MotionVectors, &paramVelocity) != NVSDK_NGX_Result_Success)
    InParameters->Get(NVSDK_NGX_Parameter_MotionVectors, (void**) &paramVelocity);
```

### 2.4 分辨率与语义信息（来自 `IFeature`，`upscalers/IFeature.h`）

| Getter | 含义 | 捕获用途 |
| --- | --- | --- |
| `RenderWidth()/RenderHeight()` | DLSS 渲染分辨率 | color/depth 的预期尺寸；写进 `frame.json` |
| `TargetWidth()/TargetHeight()` | 输出分辨率 | 参考 |
| `DisplayWidth()/DisplayHeight()` | 显示分辨率 | 参考 |
| `LowResMV()` | **MV 是否在 render 分辨率** | ⚠️ 决定 motion.bin 是否需要缩放 |
| `JitteredMV()` | MV 是否已含 jitter | 写进元数据 |
| `DepthInverted()` | 深度是否反相 | 写进元数据 |
| `IsHdr()` | 是否 HDR 管线 | 决定 color 转换是否要 tone map |
| `FrameCount()` | 帧计数 | frame_index |

> ⚠️ **重要**：`LowResMV() == false` 时，游戏提供的 MV 是 **display/target 分辨率**，而 ComfyUI 要求 render 分辨率。转换器必须把 MV 从 target 分辨率降到 render 分辨率（或至少缩放位移量）。这一点必须写进 `frame.json`，否则转换器无从判断。
> 另：`_resourceMutex`/`Dx12Resource` 那套是 **framegen 专用**，捕获层不要复用，自己管理回读资源。

### 2.5 Present 回调（CET 轮询用）

仓库里**没有**一个“始终存在”的通用 Present 钩子：
- `hooks/FG_Hooks.h:74-78` 的 `hkFGPresent` / `hkFGPresent1` 只在帧生成激活时安装。
- `wrapped/wrapped_swapchain.cpp:272 LocalPresent()` 是 OptiScaler 包装 swapchain 的路径，但同样依赖特定 swapchain 包装条件。

> ⚠️ **修正（相对原始 Prompt）**：Prompt 5.2 要求“在 Present 回调中每帧检查 command.txt”。
> 更稳妥且更符合“关闭时不得影响渲染”约束的做法是：**在捕获模块内起一个独立轮询线程**（如每 100 ms 读一次 `command.txt`，每 1 s 写一次 `status.json`），完全不进渲染路径。建议采纳此方案，除非你坚持 Present 方案（Present 方案需要在 `LocalPresent` 里额外挂钩，侵入性更大）。

---

## 3. 格式对照表：OptiScaler 捕获 → ComfyUI 期望

| 数据 | 捕获源 | 原始格式 | ComfyUI worker 是否需要 | 转换动作 |
| --- | --- | --- | --- | --- |
| **Color** | `"Color"` 资源 | 由游戏决定：`DXGI_FORMAT_R11G11B10_FLOAT`、`R10G10B10A2_UNORM`、`R16G16B16A16_FLOAT` 等 | ✅ 需要，**RGBA8** | 解码 float/10-10-10 → linear；HDR 时先 tone map；再转 8-bit sRGB。**必须按 rowPitch 逐行读** |
| **Motion** | `"MotionVectors"` 资源 | 通常 `R16G16_FLOAT`（也可能 `R16G16B16A16_FLOAT`） | ✅ 需要，**FP16 H×W×2，render 分辨率，像素单位，current→previous** | ① 若 `LowResMV()==false` → 从 target 分辨率降到 render 分辨率；② 若 `MV.Scale.X/Y != 1` → `mv *= scale`（见 §4.2）；③ 方向校验（见 §4.3）；④ 转 float16 |
| **Depth** | `"Depth"` 资源 | `R32_FLOAT` 等 | ❌ **协议里没有 depth 字段** | 仅存档。转换器**无法**把它喂给 worker |
| **Exposure** | `"ExposureTexture"` | 1×1 float | ❌ **协议里没有 exposure 字段** | 仅存档；若为 null 跳过 |
| **Jitter** | `"Jitter.Offset.X/Y"` | float（像素单位） | ❌ 协议里没有字段 | 写进 `frame.json` 存档；仅用于分析 |
| **Frame timing** | `"FrameTimeDeltaInMsec"` | float，**毫秒** | ❌ 协议里没有字段 | 写进 `frame.json`（注意转秒：`delta_time = ms / 1000.0`） |

> **落盘格式（捕获层 `[Capture] Compact`，默认 true）**：写盘时会压缩已知源格式以省空间——
> color `R16G16B16A16_FLOAT` → `R11G11B10_FLOAT`，motion `R16G16B16A16_FLOAT` → `R16G16_FLOAT`（只留 RG，无损）。
> 该契约由 `manifest.json` 的 **`capture_version=2`** 标识（=1 是压缩前的旧行为）。
> 因此 `frame.json` 的 `color_format`/`motion_format` 是**落盘**格式，源格式另记在 `color_source_format`/`motion_source_format`。
> 转换器**一律以 `color_format`/`motion_format` 为准**，不要假设 RGBA16F。关掉压缩用 `Compact=false`。

### 3.1 ⚠️ 最重要的结论：ComfyUI worker 只吃 Color + Motion

README 自己就承认了这一点（`README.md:31-35`）：

> “In games, DLSS 5 runs as "3D-Guided" Neural Rendering: the engine hands the model its rendered frame together with geometry, texture and lighting buffers, and motion vectors. Video has none of that. What reaches the model here is the decoded frame plus motion vectors estimated from the footage itself, so the guidance is weaker than in a game”

也就是说，**当前 ComfyUI worker 协议只有 color + motion + reset 三个输入**。原始 Prompt 设想的“把引擎的 depth/exposure/jitter 喂给 DLSS 5 以获得 3D-Guided 质量”**在现有 worker 协议下做不到**。

这不影响项目可行性，但需要明确预期：
- ✅ 用引擎 MV 替代光流估算 → **这是真实的质量提升**（运动矢量精确、无光流噪声），是本方案的核心价值，成立。
- ❌ 引擎 depth/exposure 无法进入 worker → 捕获它们只对存档/未来 worker 版本有意义。

**建议**：捕获层仍然采集六类数据（成本低、有存档价值、未来协议升级可用），但转换器只需输出 color→RGBA8 与 motion→FP16 两条链路。

---

## 4. 需要重点验证/决策的三个技术点

### 4.1 Color 格式：运行时才能确定

`Color` 资源的 `DXGI_FORMAT` 只能在实际游戏中通过 `ID3D12Resource::GetDesc()` 读到。Cyberpunk 2077 在 HDR 关闭时通常是 `R11G11B10_FLOAT`（scRGB/线性），开启 HDR 时可能不同。

- 捕获层**必须**把 `DXGI_FORMAT` 的枚举名和数值都写进 `frame.json`（Prompt 给的 `"color_format": "DXGI_FORMAT_R11G11B10_FLOAT"` 是对的）。
- 转换器**必须**按格式分支处理，不能假设只有一种。
- `IsHdr()` 为真 → 转换器需先 tone map（README `known limitations` 也指出“HDR sources are converted to 8-bit SDR without a tone-mapping operator, so highlights clip”——worker 内部不做 tone map，**所以 tone map 必须由我们的转换器做**，否则高光直接炸掉）。

### 4.2 Motion Scale 语义

`MV.Scale.X/Y` 是 NGX 用来把游戏 MV 换算到像素的乘子。NGX 期望的最终 MV 是**像素单位**。

- 若游戏给的是像素位移 → `MV.Scale = 1.0`。
- 若游戏给的是归一化 UV → `MV.Scale = width/height`。

转换器必须做 `mv_pixels = raw_mv * mv_scale`。**但需要实测确认 Cyberpunk 2077 走的是哪条路径**——这就是为什么捕获层要把 `motion_scale_x/y` 写进 `frame.json`，并在转换器里做成可配置。

### 4.3 方向校验（current→previous vs previous→current）

NGX DLSS 的 MV 约定与 ComfyUI worker 一致（都是 current→previous，backward）。理论上**无需取反**。但这必须验证：

- 捕获层写一个 `motion_direction` 字段（默认 `"current_to_previous"`）。
- 转换器提供 `--flip-motion` 开关。
- 验证方法：对一段相机平移的素材，分别用正向/反向 MV 跑一次，看 worker 输出的时间稳定性（错误方向会产生拖影/抖动）。这一步必须在游戏机上做，Ubuntu 无法验证。

---

## 5. 捕获层回读的技术约束（Step 3 实现要点）

### 5.1 资源状态管理（最高风险项）

`Color`/`Depth`/`MotionVectors` 在本帧被游戏当作 SRV/UAV 使用。要回读必须：

```
Transition(原状态 → D3D12_RESOURCE_STATE_COPY_SOURCE)
CopyTextureRegion(...)
Transition(COPY_SOURCE → 原状态)
```

关键问题：**这段 barrier 记录在哪个命令列表上？**

- 记录在**游戏的 `InCmdList`**（即 `TryEvaluateOptiFeature` 的 `InCmdList`）上，顺序天然正确、状态一致，风险最低。但要在 `feature->Evaluate` 之后做（此时 DLSS 已读完 color），否则会和 DLSS 的读取冲突。
- Prompt 建议的“独立命令队列 + 独立命令分配器”在 D3D12 legacy barrier 模型下**跨队列转状态是不安全的**：游戏队列可能仍在以 SRV 使用该资源，而你在另一个队列上把它转成 COPY_SOURCE，会产生数据竞争。

**建议方案（供 Step 3 确认）**：
1. 在游戏 `InCmdList` 上、`feature->Evaluate` 之后，记录 `barrier → CopyTextureRegion → barrier 还原`，目标是**每帧复用的 readback 缓冲区环**（`D3D12_HEAP_TYPE_READBACK`）。
2. 不在同帧 Map。用 fence 环记录“第 N 帧已提交”，延迟 2~3 帧后再 Map + 写盘，避免阻塞游戏主队列。
3. 写盘放**独立线程**，不与渲染线程竞争。

这样既满足“READBACK 堆、记录 rowPitch、正确状态管理、不干扰主渲染”的全部约束，也规避了跨队列状态风险。

### 5.2 GetCopyableFootprints 的正确用法

```cpp
D3D12_RESOURCE_DESC desc = src->GetDesc();
D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint;
UINT numRows = 0; UINT64 rowSize = 0; UINT64 totalBytes = 0;
device->GetCopyableFootprints(&desc, 0, 1, 0, &footprint, &numRows, &rowSize, &totalBytes);
// 用 footprint.Footprint.RowPitch 作为 rowPitch，绝不自己算 width*bpp
```

- 必须用 `footprint.Footprint.RowPitch`（256 字节对齐后的值）。
- 写盘时是 **rowPitch 步长的紧凑拷贝**还是**去掉 padding 的紧凑数据**需要明确：建议**写紧凑数据**（去掉 padding）以减小文件体积，同时在 `frame.json` 里同时记录 `row_pitch`（GPU 侧）和 `tight_stride`（文件内）。Prompt 里 `"color_row_pitch": 10240` 暗示保留了 padding——需要二选一并统一。

> ⚠️ 注意 Prompt 示例里 `"color_row_pitch": 10240` 对 2560 宽的 `R11G11B10_FLOAT`（4 B/px）来说 = 2560×4 = 10240，正好是 tight，不含对齐 padding。真实 `GetCopyableFootprints` 返回值通常 ≥ 这个数。以实际返回值为准。

### 5.3 每帧开销

每帧要回读 color（2560×1440×4 ≈ 14.7 MB）+ depth（≈14.7 MB）+ motion（≈7.4 MB）≈ **37 MB/帧**。60 fps 下 ≈ 2.2 GB/s 落盘。必须：
- 提供“只采 color+motion”的选项（跳过 depth，因为 worker 用不到）。
- 考虑按固定间隔抽帧（例如每 2 帧采 1 帧），因为 DLSS 5 离线渲染本来就不需要游戏实时帧率。
- 文件体积：1 分钟 60fps 全采 ≈ 130 GB，**不可接受**。必须默认抽帧 + 可配置。

---

## 6. GitHub Actions 复用结论

已有工作流（`.github/workflows/`）：`build.yml`、`just_build.yml`、`just_build_no_signature.yml`、`release_debug.yml`、`test.yml`、`clang-format.yml`。

- `build.yml` 是 nightly 定时构建 + 自动发 Release，**不适合**我们要的“push 即出 artifact”。
- **`just_build_no_signature.yml` 最接近需求**（无 SignPath 签名依赖）。`just_build.yml` 依赖 `secrets.SIGNPATH_API_TOKEN`，在 fork 仓库里会失败——**不要复用 `just_build.yml`**。
- 构建命令：`msbuild /m /p:Configuration=Release . /verbosity:minimal`（`SOLUTION_FILE_PATH: .`，即根目录的 `OptiScaler.sln`）。
- **产物路径确认为 `x64\Release\a\OptiScaler.dll`**（`just_build.yml:108`）。`.asi` 不是构建产物，是安装脚本改名得来的。
- 需要 `submodules: 'true'`（不是 `recursive`，官方用的是 `'true'`）。
- `Platform` 不用显式指定：解决方案默认平台就是 x64（vcxproj 里 x64 是主配置）。

→ Step 4 将基于 `just_build_no_signature.yml` 新建 `build-capture.yml`，只保留 build + upload-artifact，去掉签名与 Release 逻辑。

---

## 7. 对接点清单（Step 3~7 的实现边界）

| # | 位置 | 动作 |
| --- | --- | --- |
| 1 | `OptiScaler/inputs/NVNGX_DLSS_Dx12.cpp` `TryEvaluateOptiFeature()`，`feature->Evaluate` 之后 | 插入 `Capture::OnFrame(InCmdList, InParameters, feature)` 调用（默认空实现/关闭） |
| 2 | 新增 `OptiScaler/inputs/DlssCapture/DlssCapture.{h,cpp}` | 捕获模块：命令轮询线程、readback 环、fence 同步、写盘线程、manifest/frame.json |
| 3 | `OptiScaler/OptiScaler.vcxproj` + `.filters` | 注册新增文件 |
| 4 | `OptiScaler/OptiScaler.ini` + `Config.h/.cpp` | 新增 `[Capture]` 段：`Enabled`(默认 false)、`OutputDir`、`CaptureDepth`、`FrameStride`、`MaxFrames` |
| 5 | CET mod `optiscaler_capture/init.lua` | 按 Prompt 5.2 的命令脚本（START/STOP/STATUS） |
| 6 | `.github/workflows/build-capture.yml` | 基于 `just_build_no_signature.yml`，产物 `x64\Release\a\OptiScaler.dll` |
| 7 | `tools/capture_to_comfy.py` | 转换器：color→RGBA8（含 tone map）、motion→FP16（含 scale/方向/分辨率处理）、场景切换 reset、输出 `frame_%06d_rgba.bin` + `frame_%06d_mv.bin` + `meta.json` |
| 8 | ComfyUI 侧新增 `DLSS5LoadCapture` 节点 | 读取转换器输出目录 → 组成 `IMAGE` 批次；**或**直接喂给改造后的 `DLSS5EnhanceImages` |
| 9 | `example_workflow.json` | `DLSS5LoadCapture → DLSS5EnhanceImages → (Save/VideoCombine)` |
| 10 | `README-CAPTURE.md` | 完整工作流说明 |

---

## 8. 待你确认的决策点

1. **抽帧策略**：全采每帧 ≈ 37 MB、60fps ≈ 2.2 GB/s，1 分钟 ≈ 130 GB。建议默认 `FrameStride=2` 或按目标输出帧率采（DLSS5 离线渲染只需 24~30 fps）。需要你定默认值。
2. **是否采集 depth**：worker 用不到，但每帧多 14.7 MB。建议默认**不采**，保留开关。
3. **CET 轮询方式**：独立轮询线程（推荐，零渲染侵入）vs Present 钩子（Prompt 原方案，侵入大）。倾向哪个？
4. **回读 barrier 位置**：记录在游戏 `InCmdList` 上（推荐，安全）vs 独立队列（Prompt 原方案，有跨队列状态风险）。倾向哪个？
5. **color.bin 是否保留 rowPitch padding**：保留（转置简单，文件大）vs 去 padding（文件小，转换器需按 rowPitch 逐行读）。倾向哪个？
6. **MV 语义实测**：`MV.Scale`、`LowResMV`、方向这三项只能在游戏机上验证。是否接受“先按理论实现 + 转换器提供开关 + 游戏机实测后校正”的流程？

---

## 9. 一句话总结

- **协议真相**：worker 只吃 `RGBA8(render res) + FP16 像素位移 MV(H×W×2, render res, current→previous) + reset`，**没有 depth/exposure/jitter**。
- **OptiScaler 真相**：DLSS 输入从 `NVSDK_NGX_Parameter*` 按 key 取，插入点在 `TryEvaluateOptiFeature()` 里 `feature->Evaluate` 前后，**不是** `DLSS_Eval_Params` 结构体。
- **核心价值成立**：用引擎 MV 替代光流估算 → 真实质量提升。
- **预期需要修正**：depth/exposure 无法进入当前 worker；“归一化 UV”是错的，实际是像素单位。

---

*Step 2 完成。请确认以上分析（尤其是第 8 节的 6 个决策点），确认后我再进入 Step 3 开始改 OptiScaler 代码。*
