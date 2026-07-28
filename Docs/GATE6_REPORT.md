# 게이트 6 — RGB+깊이 융합 볼/홀컵 인식 (섀도 모드)

날짜: 2026-07-19  
범위: 자동 인식 **관측·기록·단위테스트**만. 실제 스캔 볼·홀 좌표에는 사용하지 않음.

## 격리 원칙

| 경로 | 역할 |
|------|------|
| 수동 중앙 raycast | **유일한** `ballAnchor` / `holeAnchor` 소스 → TerrainPipeline·Gate 5.5 |
| 게이트 6 자동 인식 | 오버레이 + `Documents/.../gate6/*.csv` 비교 기록만 |

자동 검출 결과가 `confirmBallAnchor` / `confirmHoleAnchor` / `CompletedScan`에 주입되지 않는다.

## 구현 요약

| 항목 | 내용 |
|------|------|
| 순수 코어 | `PuttPhysicsKit/Gate6Detection.swift` — 깊이 돌출(볼)/함몰(홀) 교차검증, 합성 RGB 후보 |
| 단위테스트 | `Gate6DetectionTests` — 진양성·평탄 오탐 기각·필터 비율 |
| 실기기 파이프라인 | `Gate6RGBDepthDetector` — ARFrame RGB luma + sceneDepth → 월드 unproject |
| 기록 | `Gate6ExperimentRecorder` — `ball_attempts.csv` / `hole_attempts.csv` / `summary.json` |
| UI | 지정 단계에서 후보 원 오버레이 + 보라 배너. 탭해도 앵커 미반영 |

## 단위테스트 결과

`swift test --filter Gate6DetectionTests` 로 검증:

- 볼 돌출·홀 함몰 깊이 통과
- 평탄 그림자 → `rejectedFlat`
- 부호 불일치 → `rejectedWrongSign`
- RGB 오탐 10개 중 깊이 필터 기각 비율 100% (합성 fixture)

## 실외 성공률 기록 템플릿 (현장)

합격선 없음 — 수치 확보가 목적. 각 20회.

| 대상 | 시도 | RGB 후보 있음 | 깊이 통과 | 수동과 8cm 이내 | 비고(그림자/낙엽 등) |
|------|------|---------------|-----------|---------------|----------------------|
| 볼 | /20 | | | | |
| 홀컵 | /20 | | | | |

깊이 교차검증이 걸러낸 RGB 오탐 비율: `false_positive_rejected / rgb_candidates` (CSV·summary.json)

## 수동 폴백

기존 중앙 십자선 + raycast 지정 경로가 주 경로로 유지된다. 자동 인식 실패·기각과 무관하게 스캔이 진행된다.

## CSV 위치

`Documents/MultibreakPuttScans/<gate6-session-id>/gate6/`

- `ball_attempts.csv` / `hole_attempts.csv`
- `summary.json` (`mode: shadow`)
