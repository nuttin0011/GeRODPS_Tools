#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
sendtostring_layer_stack_calc.py  (v2 — calibrated กับผลวัดจริงในเกม)
====================================================================
หา: ซ้อน SendToString layer ได้สูงสุดกี่ชั้น โดย AHK อ่าน pixel เดียว (R,G,B)
แล้ว decode กลับเป็น "ชั้นไหนเปิดอยู่บ้าง" ได้ 100% (ทุก combination 2^N ไม่ซ้ำ)

ผลวัดจริง (GeRODPS_Tools > Color Half-Step Viewer + ColorAtCursor.ahk, 2026-06-10):
  A) Direct float  SetColorTexture(1/2^k, a=1)    -> 255 128 64 32 16 8 4 2 1
  B) Alpha stack   ฐาน 255 + ดำ a=0.5 ซ้อน k ชั้น  -> 255 127 63 31 15 7 3 1 0
  C) Alpha stack   ฐาน 128 + ดำ a=0.5 ซ้อน k ชั้น  -> 128 64 32 16 8 4 2 1 0
  D) Direct alpha  SetColorTexture(C/255, a=0.5) บนดำ
     C = 255 253 192 129 127 65 64 3 1            -> 128 127 96 65 64 33 32 2 1

Model เดียวที่ fit ครบ 36 จุด (selftest ยืนยันทุกครั้งก่อนรัน):
  - quantize float->8bit = ปัดครึ่งขึ้น (127.5 -> 128)
  - vertex alpha 0.5 โดน quantize เหมือนกัน -> a = 128/255
  - blend ต่อการทับ 1 ครั้ง (ต่อ channel):
        out = round( (src*128 + dst*127) / 255 )
    เศษ .5 พอดีเกิดไม่ได้ (255 คี่) -> deterministic, ไม่ต้องมี floor/round mode

กติกา layer:
  - Layer 1 = บนสุด ... Layer N = ล่างสุด
  - ชั้นล่างสุดวาด alpha 1 -> ค่า = C ตรงๆ (เต็ม 0..255)
  - ชั้นอื่น alpha 0.5 -> ผ่านสูตร blend; ชั้นที่ทับทำให้ข้างล่างเหลือ ~x0.498
  - แต่ละชั้นใช้สี 1 channel (R/G/B), ความเข้ม 1..255, เปิด/ปิดอิสระ

Search (ตามที่สั่ง): ทำทีละ N แยกอิสระ —
  N=1: หา solution แรกที่ใช้งานได้ (ทุก combination 2^1 ไม่ซ้ำ) -> report -> N=2
  N=2: ค้นใหม่ทั้งกระดาน (fresh, ไม่ใช่ต่อยอดคำตอบ N=1) หาแค่ 1 solution -> ...
  terminate เมื่อ N ใดค้นจนหมด (DFS + backtracking ครบทุกทาง) แล้วไม่มี
  solution เลย -> N สูงสุด = N-1
ความถูกต้องของ DFS:
  - prune sound 100%: ถ้า readout ของ 2 combination ชนกันที่ชั้นใด มันชนตลอดไป
    (combination ที่ไม่เปิดชั้นถัดไปเก็บค่าเดิมไว้เสมอ) -> ตัดกิ่งได้ทันที
  - dedup state ที่เหมือนกัน (รวม R/G/B permutation) -> ไม่สำรวจซ้ำ
  - เรียงกิ่งด้วย heuristic ช่องว่างสีกว้างสุดก่อน -> เจอ solution เร็ว
  - ถ้า DFS หมดทุกกิ่ง = พิสูจน์ว่า N นั้นไม่มี solution จริง
"""

import argparse
import itertools
import sys
import time

CH_NAMES = "RGB"
PERMS = list(itertools.permutations(range(3)))

# ---------------------------------------------------------------- model

def blend(dst, src):
    """GPU blend ที่วัดได้จริง: round((src*128 + dst*127)/255) — ไม่มี tie"""
    n = src * 128 + dst * 127
    return (2 * n + 255) // 510


def selftest():
    """ยืนยันว่า model ตรงกับผลวัดจริงครบทั้ง 36 จุด — fail = ห้ามเชื่อผลคำนวณ"""
    # A) direct float quantize round(255/2^k)
    a = [int(255.0 / (2 ** k) + 0.5) for k in range(9)]
    assert a == [255, 128, 64, 32, 16, 8, 4, 2, 1], ("A mismatch", a)
    # B) ฐาน 255 โดนดำ a=0.5 ทับ k ชั้น
    ch = [255]
    for _ in range(8):
        ch.append(blend(ch[-1], 0))
    assert ch == [255, 127, 63, 31, 15, 7, 3, 1, 0], ("B mismatch", ch)
    # C) ฐาน 128
    ch = [128]
    for _ in range(8):
        ch.append(blend(ch[-1], 0))
    assert ch == [128, 64, 32, 16, 8, 4, 2, 1, 0], ("C mismatch", ch)
    # D) เขียน C ด้วย a=0.5 บนดำ
    cs = [255, 253, 192, 129, 127, 65, 64, 3, 1]
    got = [blend(0, c) for c in cs]
    assert got == [128, 127, 96, 65, 64, 33, 32, 2, 1], ("D mismatch", got)

# ---------------------------------------------------------------- packing

def pack(r, g, b):
    return (r << 18) | (g << 9) | b


def unpack(p):
    return ((p >> 18) & 511, (p >> 9) & 511, p & 511)


def t_overlay(p, ch, C):
    """ทับด้วย layer alpha 0.5 สี C ที่ channel ch"""
    r, g, b = unpack(p)
    r = blend(r, C if ch == 0 else 0)
    g = blend(g, C if ch == 1 else 0)
    b = blend(b, C if ch == 2 else 0)
    return pack(r, g, b)


def permute_packed(p, perm):
    c = unpack(p)
    return pack(c[perm[0]], c[perm[1]], c[perm[2]])

# ---------------------------------------------------------------- verify

def composite(layers_topfirst, mask):
    """readout ของ subset; bit i (0-based) = Layer i+1 เปิด
    Layer N (ล่างสุด, index n-1) = alpha 1; ชั้นอื่น alpha 0.5"""
    n = len(layers_topfirst)
    v = 0
    for i in range(n - 1, -1, -1):
        if not (mask >> i) & 1:
            continue
        ch, C = layers_topfirst[i]
        if i == n - 1:
            v = pack(C if ch == 0 else 0, C if ch == 1 else 0,
                     C if ch == 2 else 0)
        else:
            v = t_overlay(v, ch, C)
    return v


def mask_label(mask, n):
    shown = [str(i + 1) for i in range(n) if (mask >> i) & 1]
    return ("L" + "+L".join(shown)) if shown else "(none)"


def verify_assignment(layers_topfirst):
    owner = {}
    n = len(layers_topfirst)
    for mask in range(1 << n):
        val = composite(layers_topfirst, mask)
        if val in owner:
            return False, (owner[val], mask, unpack(val))
        owner[val] = mask
    return True, None

# ---------------------------------------------------------------- search

def canon_state(keys):
    best = None
    best_perm = None
    for perm in PERMS:
        tup = tuple(sorted(permute_packed(p, perm) for p in keys))
        if best is None or tup < best:
            best, best_perm = tup, perm
    return best, best_perm


def remap_path(path, perm):
    inv = [perm.index(k) for k in range(3)]
    return [(inv[ch], C) for ch, C in path]


def state_min_gap(ckey):
    """heuristic คัด beam: ช่องว่างต่ำสุดระหว่างค่าใน channel เดียวกัน"""
    vals = [unpack(p) for p in ckey]
    gap = 999
    for chn in range(3):
        s = sorted(v[chn] for v in vals)
        for x, y in zip(s, s[1:]):
            d = y - x
            if d and d < gap:
                gap = d
    return gap


def fmt_path_bottomfirst(path):
    """path (ล่างขึ้นบน) -> สรุป 1 บรรทัด; ชั้นแรก = ล่างสุด (alpha 1)"""
    parts = []
    for i, (ch, C) in enumerate(path):
        a = "a1" if i == 0 else "a.5"
        parts.append(f"{CH_NAMES[ch]}{C}({a})")
    return "ล่างสุด -> บนสุด: " + " | ".join(parts)


def fmt_solution(layers_topfirst):
    n = len(layers_topfirst)
    rows = []
    for i, (ch, C) in enumerate(layers_topfirst):
        if i == n - 1:
            pos = " (bottom, alpha 1)"
        elif i == 0:
            pos = " (top, alpha 0.5)"
        else:
            pos = " (alpha 0.5)"
        rows.append(f"   Layer {i+1:<2}{pos:<19}: {CH_NAMES[ch]} {C}")
    return "\n".join(rows)


# ชุดสีที่อนุญาตต่อชั้น — default ทุกค่า 1..255; ปรับได้ผ่าน --even
ALLOWED_COLORS = list(range(1, 256))


def bottom_children(keys_unused=None):
    """กิ่งของชั้นล่างสุด (alpha 1): state = {ดำ, สีชั้นล่าง}"""
    out = []
    for chn in range(3):
        for C in ALLOWED_COLORS:
            keys = frozenset({0, pack(C if chn == 0 else 0,
                                      C if chn == 1 else 0,
                                      C if chn == 2 else 0)})
            out.append((chn, C, keys))
    return out


def overlay_children(keys):
    """กิ่งของชั้น alpha 0.5: ลองทุก (channel, สี) — คืนเฉพาะที่ readout ไม่ชน"""
    out = []
    for chn in range(3):
        for C in ALLOWED_COLORS:
            new = set()
            dead = False
            for p in keys:
                np_ = t_overlay(p, chn, C)
                if np_ in new:
                    dead = True
                    break
                new.add(np_)
            if dead or not new.isdisjoint(keys):
                continue
            out.append((chn, C, keys | new))
    return out


# จำกัดขนาด visited-set ต่อ depth กันหน่วยความจำบาน — เกิน cap แล้วหยุด dedup
# (search ยัง complete อยู่ แค่ช้าลงเพราะอาจสำรวจ state ซ้ำ)
VISITED_CAP = 2_000_000


def dfs_solve(n_target, emit):
    """หา solution แรกของ N ชั้นแบบ fresh DFS + backtracking
    คืน path (ล่างขึ้นบน) หรือ None = พิสูจน์แล้วว่าไม่มี solution"""
    visited = [set() for _ in range(n_target + 1)]
    stats = {"nodes": 0, "t0": time.time(), "t_last": time.time(),
             "deepest": 0}

    def rec(keys, path, depth):
        stats["nodes"] += 1
        if depth > stats["deepest"]:
            stats["deepest"] = depth
        now = time.time()
        if now - stats["t_last"] >= 2:
            stats["t_last"] = now
            emit(f"    [N={n_target}] DFS: nodes={stats['nodes']} "
                 f"depth ปัจจุบัน={depth} ลึกสุดที่เคยถึง={stats['deepest']} "
                 f"({now - stats['t0']:.0f}s)")
        if depth == n_target:
            return path
        raw = bottom_children() if depth == 0 else overlay_children(keys)
        children = []
        vis = visited[depth + 1]
        for chn, C, full in raw:
            ck, perm = canon_state(full)
            if ck in vis:
                continue
            if len(vis) < VISITED_CAP:
                vis.add(ck)
            children.append((state_min_gap(ck), ck,
                             remap_path(path + [(chn, C)], perm)))
        # เรียงช่องว่างสีกว้างสุดก่อน — ทนการบีบจากชั้นถัดไปได้ดีสุด เจอเร็ว
        children.sort(key=lambda c: c[0], reverse=True)
        for _gap, ck, p in children:
            res = rec(frozenset(ck), p, depth + 1)
            if res is not None:
                return res
        return None

    sol = rec(frozenset({0}), [], 0)
    dt = time.time() - stats["t0"]
    if sol is None:
        emit(f"    [N={n_target}] DFS หมดทุกกิ่ง ({stats['nodes']} nodes, "
             f"{dt:.1f}s) — พิสูจน์แล้ว: ไม่มี solution")
    else:
        emit(f"    [N={n_target}] เจอ solution ({stats['nodes']} nodes, "
             f"{dt:.1f}s)")
    return sol

# ---------------------------------------------------------------- main

def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

    ap = argparse.ArgumentParser(description="SendToString layer-stack calc v2")
    ap.add_argument("--nmax", type=int, default=20,
                    help="เพดานจำนวนชั้นที่ลอง (กัน loop ไม่จบ)")
    ap.add_argument("--out", default="sendtostring_layer_stack_result.txt")
    args = ap.parse_args()

    filelines = []

    def emit(s=""):
        print(s, flush=True)
        filelines.append(s)

    def femit(s=""):
        filelines.append(s)

    emit("=" * 72)
    emit("SendToString layer-stack calculator v2 — measured-model")
    emit("blend: out = round((src*128 + dst*127)/255); bottom layer alpha 1")
    emit("=" * 72)

    try:
        selftest()
        emit("selftest: PASS — model ตรงผลวัดจริงครบ 36 จุด (A/B/C/D)")
    except AssertionError as e:
        emit(f"selftest: FAIL {e.args} — model ไม่ตรงผลวัด ห้ามใช้ผลคำนวณ")
        sys.exit(2)

    # ---- ทำทีละ N แยกอิสระ: เจอ 1 solution -> report -> N ถัดไป ----
    n_max = 0
    best_path = None
    for n in range(1, args.nmax + 1):
        emit()
        emit(f"[N={n}] เริ่มหา solution (fresh search, เอาแค่ 1 แบบ)")
        sol = dfs_solve(n, emit)
        if sol is None:
            emit(f"[N={n}] FAIL — ไม่มี solution -> terminate "
                 f"(N สูงสุด = {n - 1})")
            break
        layers = list(reversed(sol))
        ok, det = verify_assignment(layers)
        if not ok:
            emit(f"[N={n}] INTERNAL BUG — solution ไม่ผ่าน verify: {det}")
            sys.exit(2)
        n_max = n
        best_path = sol
        emit(f"[N={n}] PASS — ชุดสีที่ใช้ได้ (verify ครบ 2^{n} = {2 ** n} "
             f"combinations ไม่ซ้ำ):")
        emit(f"    {fmt_path_bottomfirst(sol)}")
    else:
        emit(f"(ถึงเพดาน nmax={args.nmax} โดยยังไม่เจอ N ที่ fail)")

    emit()
    emit("=" * 72)
    emit("ANSWER")
    emit("=" * 72)
    if best_path is None:
        emit("ไม่มี N ไหนใช้ได้เลย (?)")
        sys.exit(1)
    layers = list(reversed(best_path))
    emit(f"จำนวน layer N = {n_max} สามารถใช้ solution นี้ได้:")
    emit(fmt_solution(layers))
    emit(f"   ตรวจครบ 2^{n_max} = {2 ** n_max} combinations — "
         "pixel (R,G,B) ไม่ซ้ำกันเลย 100%")

    femit()
    femit("decode table (mask -> RGB):")
    n = len(layers)
    for mask in range(1 << n):
        femit(f"   {mask_label(mask, n):<32} -> "
              f"RGB{unpack(composite(layers, mask))}")

    with open(args.out, "w", encoding="utf-8") as f:
        f.write("\n".join(filelines) + "\n")
    emit()
    emit(f"ผลถูกบันทึกที่: {args.out}")


if __name__ == "__main__":
    main()
