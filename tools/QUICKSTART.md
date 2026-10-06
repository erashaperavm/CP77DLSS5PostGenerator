# QUICKSTART — 极简命令版

> 报错 / 排错 / 原理 / 参数：看 **[USAGE.md](tools/USAGE.md)**（完整技术文档）

## 1 · 安装（游戏机）

```bat
install.bat "D:\testdlss5\OptiScaler-Capture-Release" "D:\testdlss5\CET-optiscaler_capture" "D:\Steam\steamapps\common\Cyberpunk 2077" --force
```

ini（Enabled / FrameStride / 深度 / barrier）自动写好。卸载：

```bat
uninstall.bat "D:\Steam\steamapps\common\Cyberpunk 2077"
```

## 2 · 录制（游戏内）

**Page Up** 开始，再按一次结束。

数据在下面这个目录（整个目录拷到离线机）：

```
bin\x64\plugins\cyber_engine_tweaks\mods\optiscaler_capture\session_<时间戳>\
```

屏幕顶端绿框实时显示：状态 / 秒数 / FPS / 帧数 / 体积。上限 100 GiB，时间不限。

## 3 · 离线 DLSS5 处理

```bat
dlss5-feed-host64.exe --capture "<session 目录>" --out "D:\out\dlss5"
```

> 运行目录必须与 `--test` 相同：旁边要有 ReShade(dxgi.dll) + renodx-dlss5 add-on + OptiScaler

## 4 · 合成视频

```bash
ffmpeg -f concat -safe 0 -i frames.txt -i audio.wav -c:v libx264 -crf 16 -pix_fmt yuv420p -c:a aac -b:a 192k -shortest dlss5_out.mp4
```

无音频：去掉 `-i audio.wav -c:a aac -b:a 192k -shortest`。

## 出问题？

先看 `OptiScaler.log` 和 host 的 `dlss5-feed-host.log`；完整排错表在 [USAGE.md](USAGE.md) §4。
