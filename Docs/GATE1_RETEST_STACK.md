# 현재 전체 스택 재측정 절차

게이트1과 동일한 방법론으로, **시간축 깊이 융합·발 필터·메시 상한 등이 포함된 현재 파이프라인**을 재측정한다.  
(“융합 이전/이후”가 아니라 **현재 전체 스택 재측정**으로 문서화한다.)

## 스캔 강제 조건

1. 앱 시작 화면에서 **「재측정(왕복 고정)」** 을 켠다 → `pathMode`가 `roundTrip`으로 고정된다.
2. 편도 회차는 집계에서 자동 제외된다. (`path_mode=oneWay` 필터)
3. 각 스캔의 `reference-anchors.csv` / `diagnostics.json`에 `path_mode`, `surface_source`가 기록된다.

## 현장

- 가능하면 원래 측정했던 **페어웨이 유사 잔디** + **그린 인접** 두 곳
- 왕복 스캔: 잔디 **7회 이상**, 그린 인접 **11회 이상**
- 회차마다: 드리프트, 스무딩 후 회차 간 RMS, detrend 노이즈(σ1.5), 빈 셀, limited, `surface_source`

## 집계

디바이스에서 뽑아 온 스캔 폴더를 모은 뒤:

```bash
python3 Scripts/aggregate_gate1_retest.py /path/to/scans \
  -o Docs/gate1_retest_temporal_fusion.csv \
  --summary Docs/gate1_retest_stack_summary.md
```

산출물 CSV·비교표를 기술이전 문서 담당자에게 전달하면 6.1 / 9.10 절은 워드 문서에서 갱신한다.
