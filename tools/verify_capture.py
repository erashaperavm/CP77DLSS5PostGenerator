#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
离线校验 OptiScaler 捕获数据（纯 CPU，不需要 GPU / 游戏）。

用法:
    python3 verify_capture.py <session_dir> [--frames N] [--out DIR] [--gain G]

<session_dir> 可以是:
    · 含 frame_000000/ ... 的目录（会话根），或
    · 其父目录（会自动找 session_* / frame_*）

会做:
    1. 读 manifest.json：帧数 / 体积 / 分辨率 / 格式，并和实际帧目录数交叉校验
    2. 解码 color.bin（按 frame.json 的 color_format：RGBA16F 或 R11G11B10F）→ tone map + gamma → PNG
    3. 解码 motion.bin（按 motion_format：RGBA16F 或 RG16F）→ 可视化 PNG，并统计数值范围
    4. 汇总各通道体积占比，指出可优化的浪费

依赖: Pillow（仅此一个）。不需要 numpy —— half float 用「16 位数组 + 查找表」解。
"""

import argparse
import array
import json
import math
import os
import sys

try:
    from PIL import Image
except ImportError:
    print("需要 Pillow：pip install pillow")
    sys.exit(2)


# ----------------------------------------------------------------------------
# half float（IEEE 754 binary16）→ float
# 不依赖 array('e') / struct('e')：手动位运算建 65536 项查找表
# ----------------------------------------------------------------------------

def build_half_lut():
    lut = [0.0] * 65536
    for h in range(65536):
        s = (h >> 15) & 1
        e = (h >> 10) & 0x1F
        m = h & 0x3FF
        if e == 0:
            v = m * (2.0 ** -24)                 # 次正规数 / 0
        elif e == 31:
            v = float("inf") if m == 0 else float("nan")
        else:
            v = (1.0 + m / 1024.0) * (2.0 ** (e - 15))
        lut[h] = -v if s else v
    return lut


_HALF_LUT = build_half_lut()


def load_half(path):
    """读 binary16 数据，返回 array('H')（16 位字，本机字节序）。"""
    with open(path, "rb") as f:
        raw = f.read()
    if len(raw) % 2:
        raw = raw[:-1]
    a = array.array("H")
    a.frombytes(raw)
    if sys.byteorder == "big":
        a.byteswap()
    return a


def load_u32(path):
    """读 32 位字数据（R11G11B10 打包像素），返回 array('I')。"""
    with open(path, "rb") as f:
        raw = f.read()
    raw = raw[: len(raw) - (len(raw) % 4)]
    a = array.array("I")
    a.frombytes(raw)
    if sys.byteorder == "big":
        a.byteswap()
    return a


def unpack_r11g11b10(word):
    """DXGI_FORMAT_R11G11B10_FLOAT → (r, g, b)。R/G 为 5 位指数+6 位尾数，B 为 5 位指数+5 位尾数。"""
    out = []
    for shift, mask, mb in ((0, 0x7FF, 6), (11, 0x7FF, 6), (22, 0x3FF, 5)):
        v = (word >> shift) & mask
        e = (v >> mb) & 0x1F
        m = v & ((1 << mb) - 1)
        if e == 0:
            f = m * (2.0 ** (-14 - mb))
        elif e == 31:
            f = 3.0e38
        else:
            f = (1.0 + m / float(1 << mb)) * (2.0 ** (e - 15))
        out.append(f)
    return out[0], out[1], out[2]


# ----------------------------------------------------------------------------
# 工具
# ----------------------------------------------------------------------------

def read_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def find_session_root(path):
    """把用户给的路径归一到「直接含 frame_* 的那一层」。"""
    path = os.path.abspath(path)
    if not os.path.isdir(path):
        return None
    entries = os.listdir(path)
    if any(e.startswith("frame_") for e in entries):
        return path
    for e in sorted(entries):
        sub = os.path.join(path, e)
        if os.path.isdir(sub) and any(x.startswith("frame_") for x in os.listdir(sub)):
            return sub
    return None


def human(n):
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(n) < 1024.0:
            return "%.2f %s" % (n, unit)
        n /= 1024.0
    return "%.2f PiB" % n


_GAMMA = 1.0 / 2.2
_LUT = [int(round(255.0 * ((i / 1023.0) ** _GAMMA))) for i in range(1024)]


def tonemap_rgba16f(words, w, h, exposure=1.0):
    """RGBA16F → RGB8（Reinhard + gamma）。返回 bytes，长度 w*h*3。"""
    out = bytearray(w * h * 3)
    hl = _HALF_LUT
    lut = _LUT
    o = 0
    for i in range(w * h):
        b = i * 4
        for c in range(3):
            x = hl[words[b + c]] * exposure
            if x < 0.0:
                x = 0.0
            t = x / (1.0 + x)
            out[o + c] = lut[int(t * 1023.0)]
        o += 3
    return bytes(out)


def tonemap_r11g11b10(words, w, h, exposure=1.0):
    """R11G11B10_FLOAT → RGB8（Reinhard + gamma）。words 为 array('I')。"""
    out = bytearray(w * h * 3)
    lut = _LUT
    o = 0
    for i in range(w * h):
        for x in unpack_r11g11b10(words[i]):
            x *= exposure
            if x < 0.0:
                x = 0.0
            t = x / (1.0 + x)
            out[o] = lut[int(t * 1023.0)]
            o += 1
    return bytes(out)


def motion_stats(words, w, h, chan=4, stride=997):
    """采样统计 motion 的 R/G 范围。chan = 每像素 half 数（RG16F=2，RGBA16F=4）。"""
    hl = _HALF_LUT
    n = w * h
    xs, ys, mags = [], [], []
    for i in range(0, n, stride):
        b = i * chan
        x = hl[words[b]]
        y = hl[words[b + 1]]
        xs.append(x)
        ys.append(y)
        mags.append(math.hypot(x, y))
    if not xs:
        return None
    xs.sort()
    ys.sort()
    mags.sort()

    def pct(lst, p):
        return lst[min(len(lst) - 1, int(len(lst) * p))]

    return {
        "count": len(xs),
        "x_min": xs[0], "x_max": xs[-1],
        "y_min": ys[0], "y_max": ys[-1],
        "mag_p50": pct(mags, 0.50),
        "mag_p99": pct(mags, 0.99),
        "mag_max": mags[-1],
    }


def motion_preview(words, w, h, gain, chan=4):
    """把 motion 画成图：R→红、G→绿，0.5 为灰底。chan = 每像素 half 数。"""
    hl = _HALF_LUT
    out = bytearray(w * h * 3)
    o = 0
    for i in range(w * h):
        b = i * chan
        r = 0.5 + hl[words[b]] * gain
        g = 0.5 + hl[words[b + 1]] * gain
        r = 0.0 if r < 0.0 else (1.0 if r > 1.0 else r)
        g = 0.0 if g < 0.0 else (1.0 if g > 1.0 else g)
        out[o] = int(r * 255.0)
        out[o + 1] = int(g * 255.0)
        out[o + 2] = 128
        o += 3
    return bytes(out)


def save_rgb(data, w, h, path):
    Image.frombytes("RGB", (w, h), data).save(path)


# ----------------------------------------------------------------------------
# 主流程
# ----------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("session", help="会话目录（含 frame_*）")
    ap.add_argument("--frames", type=int, default=3, help="解码前 N 帧（默认 3）")
    ap.add_argument("--out", default=None, help="PNG 输出目录（默认 <session>/_verify）")
    ap.add_argument("--gain", default="auto", help="motion 可视化增益，'auto' 或数字")
    args = ap.parse_args()

    root = find_session_root(args.session)
    if not root:
        print("在 %s 下找不到 frame_* 目录" % args.session)
        return 2

    outdir = args.out or os.path.join(root, "_verify")
    os.makedirs(outdir, exist_ok=True)

    frames = sorted(e for e in os.listdir(root) if e.startswith("frame_"))
    print("=" * 74)
    print("会话目录 : %s" % root)
    if frames:
        print("帧目录数 : %d   (frame_%s .. frame_%s)" % (
            len(frames), frames[0].split("_")[1], frames[-1].split("_")[1]))
    else:
        print("帧目录数 : 0")
        return 1

    mf_path = os.path.join(root, "manifest.json")
    if os.path.isfile(mf_path):
        mf = read_json(mf_path)
        print("-" * 74)
        print("manifest : captured_frames=%s dropped_frames=%s message=%r" % (
            mf.get("captured_frames"), mf.get("dropped_frames"), mf.get("message")))
        print("           bytes_written=%s (%s)  stride=%s" % (
            mf.get("bytes_written"), human(mf.get("bytes_written") or 0), mf.get("frame_stride")))
        print("           render=%sx%s target=%sx%s is_hdr=%s feature=%s" % (
            mf.get("render_width"), mf.get("render_height"),
            mf.get("target_width"), mf.get("target_height"),
            mf.get("is_hdr"), mf.get("feature")))
        cap = mf.get("captured_frames") or 0
        if cap and len(frames) != cap:
            missing = cap - len(frames)
            # 每帧大小：优先用 manifest 的 bytes_written/captured_frames，
            # 没有则退化为首帧各通道文件之和（Compact 前后都能算对）
            per_frame = None
            bw = mf.get("bytes_written") or 0
            if bw:
                per_frame = bw / float(cap)
            else:
                f0dir = os.path.join(root, frames[0])
                per_frame = sum(
                    os.path.getsize(os.path.join(f0dir, n))
                    for n in ("color.bin", "motion.bin", "depth.bin", "exposure.bin")
                    if os.path.isfile(os.path.join(f0dir, n)))
            print()
            print("  [!] 帧数不符：manifest 说采了 %d 帧，这里只有 %d 帧，缺 %d 帧。" % (
                cap, len(frames), missing))
            print("      多半是拷贝没完成（不是采集失败）。%s" % (
                "按每帧 %s 算，缺约 %s。" % (human(per_frame), human(missing * per_frame))
                if per_frame else ""))
    else:
        print("  [!] 没有 manifest.json（只拷了 frame_* ？）")

    # ---- 体积分解 ----
    print("-" * 74)
    print("体积分解（第一帧实际文件大小）:")
    f0 = os.path.join(root, frames[0])
    sizes = {}
    for name in ("color.bin", "motion.bin", "depth.bin", "exposure.bin"):
        p = os.path.join(f0, name)
        if os.path.isfile(p):
            sizes[name] = os.path.getsize(p)
    total = sum(sizes.values()) or 1
    for name in sorted(sizes):
        print("   %-14s %12d B  %9s  %5.1f%%" % (name, sizes[name], human(sizes[name]), 100.0 * sizes[name] / total))
    print("   %-14s %12d B  %9s" % ("合计/帧", total, human(total)))

    # ---- 逐帧 ----
    n = min(args.frames, len(frames))
    print("-" * 74)
    print("解码前 %d 帧 -> %s" % (n, outdir))

    for idx in range(n):
        fdir = os.path.join(root, frames[idx])
        fj = os.path.join(fdir, "frame.json")
        meta = read_json(fj) if os.path.isfile(fj) else {}

        w = meta.get("render_width") or meta.get("width")
        h = meta.get("render_height") or meta.get("height")
        if not w or not h:
            print("   [%s] frame.json 缺分辨率，跳过" % frames[idx])
            continue

        print()
        print("frame %s  %dx%d" % (frames[idx], w, h))
        print("   color  : format=%s stride=%s rows=%s" % (
            meta.get("color_format"), meta.get("color_tight_stride"), meta.get("color_rows")))
        print("   motion : format=%s scale=(%s,%s) res=%s low_res=%s jittered=%s" % (
            meta.get("motion_format"), meta.get("motion_scale_x"), meta.get("motion_scale_y"),
            meta.get("motion_resolution"), meta.get("low_res_mv"), meta.get("jittered_mv")))
        print("   hdr=%s depth_inverted=%s auto_exposure=%s jitter=(%.5f, %.5f)" % (
            meta.get("is_hdr"), meta.get("depth_inverted"), meta.get("auto_exposure"),
            meta.get("jitter_x") or 0.0, meta.get("jitter_y") or 0.0))

        cpath = os.path.join(fdir, "color.bin")
        if os.path.isfile(cpath):
            cfmt = meta.get("color_format") or "DXGI_FORMAT_R16G16B16A16_FLOAT"
            ts = meta.get("color_tight_stride") or 0
            if ts and w:
                print("   color  : %.1f B/px" % (ts / float(w)))
            if cfmt == "DXGI_FORMAT_R11G11B10_FLOAT":
                words = load_u32(cpath)
                need = w * h
                if len(words) < need:
                    print("   [!] color.bin 只有 %d 个像素，期望 %d" % (len(words), need))
                else:
                    png = os.path.join(outdir, "%s_color.png" % frames[idx])
                    save_rgb(tonemap_r11g11b10(words, w, h), w, h, png)
                    print("   -> %s" % png)
            else:
                words = load_half(cpath)
                need = w * h * 4
                if len(words) < need:
                    print("   [!] color.bin 只有 %d 个 half，期望 %d" % (len(words), need))
                else:
                    png = os.path.join(outdir, "%s_color.png" % frames[idx])
                    save_rgb(tonemap_rgba16f(words, w, h), w, h, png)
                    print("   -> %s" % png)

        mpath = os.path.join(fdir, "motion.bin")
        if os.path.isfile(mpath):
            mfmt = meta.get("motion_format") or "DXGI_FORMAT_R16G16B16A16_FLOAT"
            chan = 2 if mfmt == "DXGI_FORMAT_R16G16_FLOAT" else 4
            words = load_half(mpath)
            st = motion_stats(words, w, h, chan)
            if st:
                print("   motion : |mv| p50=%.5f p99=%.5f max=%.5f  x∈[%.5f,%.5f] y∈[%.5f,%.5f]" % (
                    st["mag_p50"], st["mag_p99"], st["mag_max"],
                    st["x_min"], st["x_max"], st["y_min"], st["y_max"]))
                sx = meta.get("motion_scale_x") or 1.0
                sy = meta.get("motion_scale_y") or 1.0
                print("            ×scale 后 |mv_px| p99≈%.2f px（scale=(%.1f,%.1f)）" % (
                    st["mag_p99"] * max(abs(sx), abs(sy)), sx, sy))
                if st["mag_max"] < 1.0:
                    print("            判断: 数值<1，像**归一化** MV → scale=分辨率 合理")
                else:
                    print("            判断: 数值>1，像**已像素化** MV → scale 应为 1，需核对")

                gain = args.gain
                gain = (1.0 / st["mag_p99"] if st["mag_p99"] > 0 else 1.0) if gain == "auto" else float(gain)
                png = os.path.join(outdir, "%s_motion.png" % frames[idx])
                save_rgb(motion_preview(words, w, h, gain, chan), w, h, png)
                print("   -> %s   (gain=%.3g)" % (png, gain))

    print()
    print("=" * 74)
    print("看 PNG 判断：")
    print("  color  —— 画面是否正常、无错位/偏色（HDR 已 tone map，会比游戏里平）")
    print("  motion —— 是否有明显方向性纹理；纯灰=几乎没运动，噪点=尺度不对")
    return 0


if __name__ == "__main__":
    sys.exit(main())
