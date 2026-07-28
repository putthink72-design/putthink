#!/usr/bin/env python3
"""현재 전체 스택 재측정 집계.

입력: 스캔 디렉터리들(diagnostics.json + reference-anchors.csv)
출력: gate1_retest_temporal_fusion.csv (+ 요약 비교표 템플릿)

규칙:
- path_mode가 roundTrip(또는 round_trip)인 회차만 포함
- 편도(oneWay)는 자동 제외
- surface_source 비율을 함께 보고
"""

from __future__ import annotations

import argparse
import csv
import json
import statistics
from collections import Counter
from pathlib import Path


def read_kv_csv(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.is_file():
        return out
    with path.open(newline="") as f:
        reader = csv.reader(f)
        header = next(reader, None)
        if not header:
            return out
        for row in reader:
            if len(row) >= 2:
                out[row[0].strip()] = row[1].strip()
    return out


def normalize_path_mode(raw: str | None) -> str:
    if not raw:
        return "unknown"
    v = raw.strip().lower().replace("-", "").replace("_", "")
    if v in {"roundtrip"}:
        return "roundTrip"
    if v in {"oneway"}:
        return "oneWay"
    return raw


def load_scan(scan_dir: Path) -> dict | None:
    diag_path = scan_dir / "diagnostics.json"
    if not diag_path.is_file():
        return None
    with diag_path.open() as f:
        diag = json.load(f)

    anchors = read_kv_csv(scan_dir / "reference-anchors.csv")
    # Prefer anchors CSV (always written), then diagnostics fields (newer exports).
    path_mode = normalize_path_mode(
        anchors.get("path_mode") or diag.get("pathMode") or diag.get("path_mode")
    )
    surface_source = (
        anchors.get("surface_source")
        or diag.get("surfaceSource")
        or diag.get("surface_source")
        or "unknown"
    )

    rms_list = diag.get("repeatScanRMS") or diag.get("repeat_scan_rms") or []
    rms_vals = [float(x["rmsMillimeters"]) for x in rms_list if "rmsMillimeters" in x]

    sigma_rows = diag.get("sigmaNoiseMeasurements") or []
    noise_15 = None
    for row in sigma_rows:
        if abs(float(row.get("sigma", 0)) - 1.5) < 1e-9:
            noise_15 = float(row["detrendedStandardDeviationMM"])
            break
    if noise_15 is None:
        noise_15 = float(diag.get("noiseStandardDeviationMM") or 0)

    return {
        "scan_id": scan_dir.name,
        "path_mode": path_mode,
        "surface_source": surface_source,
        "drift_mm": float(diag.get("driftMillimeters") or 0),
        "empty_cell_ratio": float(diag.get("emptyCellRatio") or 0),
        "limited_tracking_ratio": float(diag.get("limitedTrackingRatio") or 0),
        "detrend_noise_sigma15_mm": noise_15,
        "pairwise_rms_mean_mm": statistics.mean(rms_vals) if rms_vals else "",
        "pairwise_rms_count": len(rms_vals),
    }


def discover_scans(roots: list[Path]) -> list[Path]:
    scans: list[Path] = []
    for root in roots:
        if (root / "diagnostics.json").is_file():
            scans.append(root)
            continue
        for child in sorted(root.rglob("diagnostics.json")):
            scans.append(child.parent)
    return scans


def main() -> None:
    parser = argparse.ArgumentParser(description="Aggregate gate1 full-stack retest scans")
    parser.add_argument(
        "inputs",
        nargs="+",
        type=Path,
        help="Scan folders or parent folders containing scan-*/diagnostics.json",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=Path("Docs/gate1_retest_temporal_fusion.csv"),
        help="Per-scan CSV output path",
    )
    parser.add_argument(
        "--summary",
        type=Path,
        default=Path("Docs/gate1_retest_stack_summary.md"),
        help="Markdown summary with previous-vs-current comparison template",
    )
    args = parser.parse_args()

    rows = []
    excluded = Counter()
    for scan_dir in discover_scans(args.inputs):
        row = load_scan(scan_dir)
        if row is None:
            continue
        if row["path_mode"] != "roundTrip":
            excluded[row["path_mode"]] += 1
            continue
        rows.append(row)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "scan_id",
        "path_mode",
        "surface_source",
        "drift_mm",
        "empty_cell_ratio",
        "limited_tracking_ratio",
        "detrend_noise_sigma15_mm",
        "pairwise_rms_mean_mm",
        "pairwise_rms_count",
    ]
    with args.output.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    source_counts = Counter(r["surface_source"] for r in rows)
    drifts = [abs(r["drift_mm"]) for r in rows]
    noises = [r["detrend_noise_sigma15_mm"] for r in rows]
    empties = [r["empty_cell_ratio"] for r in rows]
    limited = [r["limited_tracking_ratio"] for r in rows]
    rms = [r["pairwise_rms_mean_mm"] for r in rows if r["pairwise_rms_mean_mm"] != ""]

    def avg(xs):
        return statistics.mean(xs) if xs else float("nan")

    lines = [
        "# 현재 전체 스택 재측정 요약",
        "",
        "> 명칭: 융합만의 before/after가 아니라 **현재 전체 스택**(시간축 깊이 융합·발 필터·메시 상한 등) 재측정.",
        "",
        f"- 포함 회차(roundTrip만): **{len(rows)}**",
        f"- 제외 회차: {dict(excluded) if excluded else '없음'}",
        f"- surface_source 비율: { {k: f'{v}/{len(rows)}' for k, v in source_counts.items()} }",
        "",
        "## 이번 측정(현재 스택)",
        "",
        f"| 지표 | 값 |",
        f"|---|---:|",
        f"| \\|왕복 드리프트\\| 평균 (mm) | {avg(drifts):.2f} |",
        f"| 회차 간 RMS 평균 (mm) | {avg(rms):.2f} |" if rms else "| 회차 간 RMS 평균 (mm) | n/a |",
        f"| detrend 노이즈 σ1.5 평균 (mm) | {avg(noises):.2f} |",
        f"| 빈 셀 비율 평균 | {avg(empties):.3f} |",
        f"| limited 비율 평균 | {avg(limited):.3f} |",
        "",
        "## 이전(문서 6.1 참고치) vs 이후 — 개선율",
        "",
        "| 지표 | 이전(6.1) | 이후(이번) | 개선율(%) |",
        "|---|---:|---:|---:|",
        "| \\|왕복 드리프트\\| (mm) | 22~32 |  |  |",
        "| 회차 간 RMS (mm) | ~20 |  |  |",
        "| detrend 노이즈 σ1.5 (mm) | (현장값) |  |  |",
        "",
        f"원시 CSV: `{args.output}`",
        "",
        "기술이전 문서 6.1/9.10 갱신은 CSV·본 표를 받아 별도 워드 문서에서 처리.",
        "",
    ]
    args.summary.write_text("\n".join(lines), encoding="utf-8")
    print(f"wrote {args.output} ({len(rows)} roundTrip scans)")
    print(f"wrote {args.summary}")
    if excluded:
        print(f"excluded non-roundTrip: {dict(excluded)}")


if __name__ == "__main__":
    main()
