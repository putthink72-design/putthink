#!/usr/bin/env python3
"""게이트6 섀도 → 실경로 승격 판정 리포트.

승격 기준(확정):
- 전체 표본 합계 ≥ 100건
- 볼 ≥ 40, 홀 ≥ 40 (나머지는 혼합 가능)
- 볼 P90(수동 대비 |delta_m|) ≤ 0.03 m
- 홀 P90 ≤ 0.02 m
- 오탐율 = false_positive_rejected / 자동검출시도(RGB 후보 이벤트) < 0.05
  ※ 분모는 수동 지정 횟수가 아니라 자동 검출 시도(행) 수
- 위 P90·오탐은 **장소마다 개별 충족** (3곳 이상)

입력: gate6 세션 폴더들(…/gate6/ball_attempts.csv, hole_attempts.csv)
"""

from __future__ import annotations

import argparse
import csv
import math
from dataclasses import dataclass
from pathlib import Path


def percentile(sorted_vals: list[float], p: float) -> float:
    if not sorted_vals:
        return float("nan")
    if len(sorted_vals) == 1:
        return sorted_vals[0]
    t = min(max(p, 0.0), 1.0)
    idx = t * (len(sorted_vals) - 1)
    lo = int(math.floor(idx))
    hi = int(math.ceil(idx))
    if lo == hi:
        return sorted_vals[lo]
    w = idx - lo
    return sorted_vals[lo] * (1 - w) + sorted_vals[hi] * w


def load_attempts(path: Path) -> list[dict]:
    if not path.is_file():
        return []
    with path.open(newline="") as f:
        return list(csv.DictReader(f))


@dataclass
class KindStats:
    n: int = 0
    p90_m: float = float("nan")
    false_pos: int = 0
    fp_rate: float = float("nan")

    @property
    def ok_ball(self) -> bool:
        return self.n >= 1 and self.p90_m <= 0.03 and self.fp_rate < 0.05

    @property
    def ok_hole(self) -> bool:
        return self.n >= 1 and self.p90_m <= 0.02 and self.fp_rate < 0.05


def summarize(rows: list[dict]) -> KindStats:
    deltas = []
    false_pos = 0
    for row in rows:
        try:
            false_pos += int(float(row.get("false_positive_rejected") or 0))
        except ValueError:
            pass
        d = row.get("delta_m") or ""
        if d == "":
            continue
        try:
            deltas.append(abs(float(d)))
        except ValueError:
            continue
    deltas.sort()
    n = len(rows)  # 자동 검출 시도 = CSV 행 수
    return KindStats(
        n=n,
        p90_m=percentile(deltas, 0.90) if deltas else float("nan"),
        false_pos=false_pos,
        fp_rate=(false_pos / n) if n else float("nan"),
    )


def discover_sites(roots: list[Path]) -> dict[str, Path]:
    """site_id -> gate6 directory."""
    sites: dict[str, Path] = {}
    for root in roots:
        if (root / "ball_attempts.csv").is_file():
            sites[root.parent.name if root.name == "gate6" else root.name] = root
            continue
        for ball in root.rglob("ball_attempts.csv"):
            gate6 = ball.parent
            site = gate6.parent.name
            sites[site] = gate6
    return sites


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("inputs", nargs="+", type=Path)
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=Path("Docs/gate6_promotion_report.md"),
    )
    args = parser.parse_args()

    sites = discover_sites(args.inputs)
    lines = [
        "# 게이트6 실경로 승격 판정",
        "",
        "## 기준",
        "",
        "- 전체 표본 합계 ≥ 100",
        "- 볼 ≥ 40, 홀 ≥ 40",
        "- 볼 P90 ≤ 3 cm, 홀 P90 ≤ 2 cm (수동 대비 |delta_m|)",
        "- 오탐율 = false_positive_rejected / 자동검출시도(행) < 5%",
        "- P90·오탐은 **장소마다** 개별 충족",
        "",
        "## 장소별",
        "",
        "| 장소 | 볼 n | 볼 P90(cm) | 볼 오탐 | 홀 n | 홀 P90(cm) | 홀 오탐 | 장소 합격 |",
        "|---|---:|---:|---:|---:|---:|---:|:---:|",
    ]

    total_ball = 0
    total_hole = 0
    site_pass = []

    for site, gate6 in sorted(sites.items()):
        ball = summarize(load_attempts(gate6 / "ball_attempts.csv"))
        hole = summarize(load_attempts(gate6 / "hole_attempts.csv"))
        total_ball += ball.n
        total_hole += hole.n
        passed = ball.ok_ball and hole.ok_hole
        site_pass.append(passed)
        lines.append(
            f"| {site} | {ball.n} | {ball.p90_m * 100:.2f} | {ball.fp_rate:.1%} | "
            f"{hole.n} | {hole.p90_m * 100:.2f} | {hole.fp_rate:.1%} | "
            f"{'Y' if passed else 'N'} |"
        )

    total = total_ball + total_hole
    volume_ok = total >= 100 and total_ball >= 40 and total_hole >= 40
    places_ok = len(site_pass) >= 3 and all(site_pass)
    promote = volume_ok and places_ok

    lines += [
        "",
        "## 합계",
        "",
        f"- 볼 {total_ball} + 홀 {total_hole} = **{total}** (목표 ≥100, 볼≥40, 홀≥40) → {'OK' if volume_ok else '미달'}",
        f"- 장소 수 {len(site_pass)} (목표 ≥3, 전부 합격) → {'OK' if places_ok else '미달'}",
        "",
        f"## 승격 판정: **{'검토 대상(기준 충족)' if promote else '섀도 유지(미충족)'}**",
        "",
        "미충족 시: 표본 추가 또는 검출 로직 개선. 기준 수치 자체는 낮추지 않음.",
        "",
    ]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(lines), encoding="utf-8")
    print(f"wrote {args.output}")
    print("PROMOTE" if promote else "KEEP_SHADOW")


if __name__ == "__main__":
    main()
