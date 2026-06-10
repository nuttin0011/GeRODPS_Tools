#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
sendtostring_layer_adjust.py
============================
ปรับคำตอบ layer stack ทีละ +-1 แล้วตรวจว่ายัง decode ได้ 100% ไหม
(ใช้ model เดียวกับ sendtostring_layer_stack_calc.py — import มาตรงๆ
selftest 36 จุดรันก่อนทุกครั้ง)

วิธีใช้:
  python sendtostring_layer_adjust.py
      ใช้ solution N=9 ที่หาได้เป็นค่าตั้งต้น แล้วลองขยับแต่ละชั้น -1 / +1
      (ชั้นอื่นคงค่าเดิม) รายงาน PASS/FAIL ต่อการขยับ

  python sendtostring_layer_adjust.py --scan
      เพิ่ม: สแกนทุกค่า 1..255 ของแต่ละชั้น (ชั้นอื่นคงเดิม)
      เพื่อดูว่าชั้นนั้นมีอิสระเลือกค่าอะไรได้บ้าง

  python sendtostring_layer_adjust.py --solution "R255,G253,B125,R63,R222,R48,G3,G38,B2"
      ป้อน solution เอง — เรียงจาก "ล่างสุด -> บนสุด"
      ตัวแรก = ชั้นล่างสุด (alpha 1), ที่เหลือ alpha 0.5
      แก้ค่าแล้วรันซ้ำไปเรื่อยๆ เพื่อ "เดินทีละก้าว" ไปหาชุดเลขที่ชอบ

หมายเหตุ: การขยับแต่ละชั้นทดสอบแบบอิสระ (ทีละชั้น) — ถ้าจะขยับพร้อมกัน
หลายชั้น ให้แก้ --solution แล้วรันใหม่ ผลตรวจจะครอบคลุมเอง
"""

import argparse
import sys

from sendtostring_layer_stack_calc import (
    CH_NAMES, selftest, verify_assignment, fmt_solution,
    pack, t_overlay,
)

# คำตอบ N=9 จากการ search (2026-06-10) — ล่างสุด -> บนสุด
DEFAULT_SOLUTION = "R255,G253,B125,R63,R222,R48,G3,G38,B2"


def parse_solution(s):
    """'R255,G253,...' (ล่างสุด -> บนสุด) -> list[(ch, C)] bottom-first"""
    out = []
    for tok in s.split(","):
        tok = tok.strip().upper()
        if not tok or tok[0] not in CH_NAMES:
            raise ValueError(f"token ไม่ถูกต้อง: '{tok}' (ต้องเป็น R/G/B ตามด้วยตัวเลข)")
        ch = CH_NAMES.index(tok[0])
        C = int(tok[1:])
        if not (1 <= C <= 255):
            raise ValueError(f"ความเข้มต้องอยู่ใน 1..255: '{tok}'")
        out.append((ch, C))
    return out


def compress_ranges(vals):
    """[1,2,3,7,9,10] -> '1-3, 7, 9-10'"""
    if not vals:
        return "(ไม่มี)"
    parts = []
    start = prev = vals[0]
    for v in vals[1:]:
        if v == prev + 1:
            prev = v
            continue
        parts.append(f"{start}-{prev}" if start != prev else f"{start}")
        start = prev = v
    parts.append(f"{start}-{prev}" if start != prev else f"{start}")
    return ", ".join(parts)


# ============================================================
# --make-even : ปรับคำตอบให้เหลือเฉพาะ เลขคู่ + 255 + 1
# ============================================================

# ค่าที่อนุญาตใน mode make-even (ตาม spec: เลขคู่ทั้งหมด ยกเว้น 255 กับ 1 ที่ยอมให้ใช้)
EVEN_ALLOWED = sorted(set(range(2, 256, 2)) | {1, 255})


def make_even(bottom_first):
    """ปรับความเข้มแต่ละชั้น (channel คงเดิม) ให้อยู่ในเซ็ต EVEN_ALLOWED
    โดยขยับจากค่าเดิมน้อยที่สุดก่อน + backtracking ถ้าชุดที่เลือกชนกันเอง
    คืน path bottom-first หรือ None ถ้าไม่มีทางเลย"""
    n = len(bottom_first)

    def candidates(C):
        vals = sorted(EVEN_ALLOWED, key=lambda v: (abs(v - C), v))
        return vals

    def rec(i, keys, acc):
        ch, C = bottom_first[i]
        for C2 in candidates(C):
            if i == 0:
                vec = pack(C2 if ch == 0 else 0,
                           C2 if ch == 1 else 0,
                           C2 if ch == 2 else 0)
                if vec == 0:
                    continue
                new_keys = frozenset({0, vec})
            else:
                new = set()
                dead = False
                for p in keys:
                    q = t_overlay(p, ch, C2)
                    if q in new:
                        dead = True
                        break
                    new.add(q)
                if dead or not new.isdisjoint(keys):
                    continue
                new_keys = keys | new
            nxt = acc + [(ch, C2)]
            if i == n - 1:
                return nxt
            res = rec(i + 1, new_keys, nxt)
            if res is not None:
                return res
        return None

    return rec(0, frozenset({0}), [])


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

    ap = argparse.ArgumentParser(description="ปรับคำตอบ layer stack ทีละ +-1")
    ap.add_argument("--solution", default=DEFAULT_SOLUTION,
                    help="ล่างสุด -> บนสุด เช่น R255,G253,... (ตัวแรก alpha 1)")
    ap.add_argument("--scan", action="store_true",
                    help="สแกนทุกค่า 1..255 ต่อชั้นด้วย (ชั้นอื่นคงเดิม)")
    ap.add_argument("--make-even", action="store_true",
                    help="ปรับคำตอบให้ใช้เฉพาะ เลขคู่ + 255 + 1 (channel คงเดิม)")
    args = ap.parse_args()

    selftest()

    bottom_first = parse_solution(args.solution)
    n = len(bottom_first)
    layers = list(reversed(bottom_first))  # -> top-first สำหรับ verify

    print("=" * 70)
    print(f"solution ตั้งต้น (N={n}) — ล่างสุด -> บนสุด: " + ", ".join(
        f"{CH_NAMES[ch]}{C}" + ("(a1)" if i == 0 else "")
        for i, (ch, C) in enumerate(bottom_first)))
    ok, det = verify_assignment(layers)
    if not ok:
        a, b, v = det
        print(f"  ตั้งต้น: FAIL — combination {a} กับ {b} อ่านได้ {v} ซ้ำกัน")
        print("  (แก้ --solution ก่อน แล้วค่อยลองขยับ)")
        sys.exit(1)
    print(f"  ตั้งต้น: PASS — ตรวจครบ 2^{n} = {2 ** n} combinations ไม่ซ้ำ")
    print("=" * 70)

    if args.make_even:
        sol = make_even(bottom_first)
        if sol is None:
            print("make-even: FAIL — ไม่มีชุด (เลขคู่ + 255 + 1) ที่ decode ได้"
                  " บน channel ลำดับนี้")
            sys.exit(1)
        layers2 = list(reversed(sol))
        ok2, det2 = verify_assignment(layers2)
        if not ok2:
            print(f"make-even: INTERNAL BUG — ไม่ผ่าน verify: {det2}")
            sys.exit(2)
        print(f"make-even: PASS — ชุดใหม่ (เลขคู่ + 255 + 1, ขยับน้อยสุดก่อน):")
        print("  ล่างสุด -> บนสุด: " + ", ".join(
            f"{CH_NAMES[ch]}{C}" + ("(a1)" if i == 0 else "")
            for i, (ch, C) in enumerate(sol)))
        changed = [f"ชั้น {i+1}: {CH_NAMES[ch]}{c0} -> {CH_NAMES[ch]}{c1}"
                   for i, ((ch, c0), (_, c1))
                   in enumerate(zip(bottom_first, sol)) if c0 != c1]
        print("  ที่ขยับ: " + ("; ".join(changed) if changed else "(ไม่มี)"))
        print(fmt_solution(layers2))
        print(f"  verify ครบ 2^{n} = {2 ** n} combinations ไม่ซ้ำ 100%")
        return

    for i, (ch, C) in enumerate(bottom_first):
        ti = n - 1 - i  # index ใน layers (top-first)
        tag = "ล่างสุด alpha1" if i == 0 else "alpha0.5"
        results = []
        for delta in (-1, +1):
            C2 = C + delta
            if not (1 <= C2 <= 255):
                results.append(f"{delta:+d} -> ออกช่วง")
                continue
            mod = list(layers)
            mod[ti] = (ch, C2)
            ok2, _ = verify_assignment(mod)
            results.append(
                f"{delta:+d} -> {CH_NAMES[ch]}{C2} "
                f"{'PASS' if ok2 else 'FAIL'}")
        print(f"ชั้นที่ {i+1} จากล่าง [{CH_NAMES[ch]}{C} {tag}]: "
              + " | ".join(results))

        if args.scan:
            valid = []
            for C2 in range(1, 256):
                if C2 == C:
                    continue
                mod = list(layers)
                mod[ti] = (ch, C2)
                if verify_assignment(mod)[0]:
                    valid.append(C2)
            print(f"    ค่าอื่นที่ใช้แทนได้ ({CH_NAMES[ch]} เดิม, ชั้นอื่นคงเดิม): "
                  + compress_ranges(valid))

    print()
    print("เคล็ด: เลือกค่าใหม่ที่ชอบ -> แก้ --solution -> รันซ้ำ เพื่อเดินทีละก้าว")


if __name__ == "__main__":
    main()
