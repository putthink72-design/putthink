# 게이트 5.5 — 실측 검증 준비 보고

날짜: 2026-07-19  
범위: 실험용 디버그 UI·기록 도구 + 볼·홀 AR 지면 기준점 고도화 (물리엔진 변경 없음)

## 구현 요약

기존 `MultibreakPutt` LiDAR 스캔 앱에 게이트 5.5 조준·기록 기능을 통합했다.  
**볼·홀 기준은 카메라 위치가 아니라 화면 중앙 raycast로 지정한 지면 좌표**다.

| 항목 | 내용 |
|------|------|
| 공용 러너 | `PuttPhysicsKit/Gate55Validation.swift` — 모드1(순검증), 모드2(추천), 직접격자/`.grnh`/LiDAR 어댑터 |
| 기준점 | 중앙 십자선 + AR 지면 raycast → 볼/홀 앵커. 카메라 pose는 드리프트 전용 |
| ARSession | **화면 진입 시 사전 워밍업**(트래킹+메시+raw depth 미리 가동) → 시작 버튼은 상태 리셋만, 재시작 히칭 없음. 구성은 `.mesh`(분류 미사용)+`sceneDepth`만(smoothed 미요청). 스캔 종료 후에는 **메시·depth를 끄고** 월드 트래킹(+수평면)만 유지 → 조준선·재앵커용 |
| Polycam형 커버리지 | 스캔 중 `sceneDepth`+confidence로 5cm 셀 누적. **파란 선(100%)+파란 면(50%)=추가 스캔**, **흰 메시선=안정(완료)**. 이동 속도·거리·트래킹 안내 + 안정화 햅틱. **높이맵·볼·홀·Gate6에 미주입** |
| 메시 렌더링 | **ARKit 원본 삼각 메시**를 그대로 표시(수직 벽면 포함). 끊김·진동 방지: 프레임마다 transform만 갱신, 무거운 지오메트리 재생성은 **앵커당 스로틀 + 프레임당 1개(라운드로빈) + 백그라운드 큐**. Unlit 리본선(픽셀폭 슬라이더), 미확정=파란 선+면, 안정=흰 선 |
| 표면 고도화 | **물리**: raw `sceneDepth`(고신뢰)를 **1cm 셀·독립 3프레임 이상·서로 다른 시점 2곳 이상** 융합(median/MAD). 볼→홀 주변 지면만 선택, 평면 강제 없음(그린 언듈레이션 보존). 커버리지는 프레임당 셀 1회만 누적 |
| detrend 진단 | 선택 영역 최소자승 평면 fit → 기울기(%)·잔차 표준편차(mm) 산출. `surface-detrend.csv`로 노이즈/미세 언듈레이션 분리 기록 |
| 추천 탐색 | 기본 **130×130** 격자(각도 0.46° ≈ 5m에서 홀 위치 4cm < 홀 반지름 → 홀인 창 누락 방지). 지형 격자 탐색·후보별 오버런 시뮬레이션을 **속도 행 병렬**(`scanExactGridParallel`)로 실행 — 직렬과 후보·순서 동일(회귀 테스트). Release 기준 실그린 추천 1회 ≈ 0.2초(Mac), 필드 테스트는 **Release 빌드 필수**(Debug는 물리 루프 비최적화로 수십 배 느림) |
| 조준 UI | 상단 50% AR: **흰 등고선(1cm)** + 흰 조준(β) + **녹색 퍼팅경로** + 회색 0° 참고 + 볼/홀 마커. PuttView형 그린 읽기 오버레이 |
| 기록 | `Documents/MultibreakPuttScans/<scan-id>/` 및 `gate55/` CSV |

## 화면 워크플로우 (기준점 고도화 후)

시작 화면에서 **스캔 경로**를 고른다. 기본은 **왕복**.

1. **스캔 시작**
2. **볼 기준점 지정** — 십자선을 실제 골프공 중심에 맞추고 버튼 → 흰 공 마커 고정
3. 홀까지 걸어 메시 스캔 — **파란 반투명 면을 천천히 채워 흰 메시선으로 전환**. 너무 빠르거나 멀면 안내 문구 표시
4. **홀 기준점 지정** — 십자선을 홀컵 중심에 맞추고 버튼 → 깃대 마커 고정
5. **왕복(기본)**: 볼로 복귀 후 스캔 종료 → 드리프트 보정 적용  
   **편도**: 홀 지정 직후 바로 계산 → 드리프트 미보정(간편)
6. Gate 5.5 조준 화면 자동 전환
7. 상단 AR: 흰 기준선(볼→홀 0°) + 형광 β 선. 하단에서 평지환산·v0·β 확인
8. 조준 중 limited 발생 시 **홀 재앵커링 (중앙 조준)** 가능
9. 게이트 1 진단은 **진단** 시트

시뮬레이터: 볼 `(0, 0.3, 0)` · 홀 `(0, 0.33, 3)` 데모 기준점 사용.

## CSV 산출물

| 파일 | 용도 |
|------|------|
| `reference-anchors.csv` | `reference_method=ar_raycast`, 볼/홀 월드좌표, tracking_ok, 카메라 Y |
| `gate55/reference_anchors.csv` | 동일 메타 (실험 폴더) |
| `ramp_calibration.csv` | 램프 높이→v0 캘리브레이션 |
| `overhead_tracking_<run_id>.csv` | 요청 v0/β, 실행 β, tracking_ok |
| `slope_spotcheck_<run_id>.csv` | 경사계 vs 높이맵 |
| `indoor_scaled_terrain.csv` / `indoor_run_results.csv` | 실내 축소재현 |
| `aim_snapshot.csv` | 조준 시점 스냅샷 |

`reference-anchors.csv`의 `surface_source`는 다중 프레임 융합 사용 시
`temporal_scene_depth`, 관측 부족으로 기존 ARKit 메시를 사용하면
`arkit_mesh_fallback`이다.

## 검증

- `Gate55ValidationTests` 7개: **통과** (드리프트=카메라 Y, 원점=지면 볼 앵커, **오르막/내리막 평지환산 부호**)
- `ScanCoverageTests` 9개: **통과** (셀 전환·confidence·품질·unproject·격리·프레임 독립)
- `TemporalSurfaceFusionTests` 7개: **통과** (프레임 독립성·MAD 이상치·경사 보존·벽/ROI 제외·다중 시점 강제)
- `PuttPhysicsKit` 전체 64개 테스트: **통과** (지형 병렬 탐색 = 직렬 결과 동일성 포함, 2026-07-22)
- `MultibreakPutt` iOS Simulator **Debug: BUILD SUCCEEDED** (2026-07-22, 추천 탐색 130×130·병렬화 포함)

### 알려진 수정: β AR↔나침반 좌우 불일치 (2026-07-20)

`ScanCoordinateTransform` 우측 기저가 `up × look`(실제 좌측)로 잡혀 있어
물리/나침반의 +β(우)가 AR 화면에서는 왼쪽으로 그려졌다. `look × up`으로
교정해 AR 녹색 조준선·노란 궤적과 하단 나침반(우+)이 같은 쪽을 가리킨다.

## 실기기 확인 항목 (시뮬레이터에서 대체 불가)

- [ ] 볼/홀 지정 시 마커가 실제 공·컵 중심에 붙는지
- [ ] 조준선이 볼 지면 앵커에서 시작해 잔디 위에 보이는지
- [ ] 흰 0° 선과 형광 β 선이 구분되는지
- [ ] 홀 재앵커링이 중앙 raycast로 동작하는지
- [ ] `reference-anchors.csv`에 카메라 Y와 지면 앵커 Y가 분리 기록되는지

## 기존 기능 영향

- 게이트 2~5 물리·후보 API: **변경 없음**
- 게이트 1 `TerrainPipeline.process`: 선택 인자 `cameraStartPose`/`cameraReturnPose` 추가 (기본값 nil → 기존 동작 유지)
- `GreenSimulator`: 수정 없음
