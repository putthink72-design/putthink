# 게이트 4 — 회전 래퍼 + 다중브랙 통합 보고서

## 판정

**합격.** 이중평면 단일 평면 케이스(θ=0, θ≠0)가 게이트 2 평면엔진과 0.1mm 이내로
일치하고, 방위 0/90/180/270° 및 임의각 2개에서도 회전된 평면엔진 기준과 일치한다.
θ=180° 궤적은 θ=0° 궤적의 X축 거울상이다. 경계 통과 시각화 3종을 제출한다.

## 구현

기존 게이트 2 API(`FlatPuttPhysics`)는 변경하지 않았다. 추가만 했다.

| 파일 | 역할 |
|---|---|
| `TerrainField.swift` | 높이·∇H 양선형보간, `localSlope`(`alpha=atan(|∇H|)`), 이중평면 합성 지형 |
| `MultibreakPuttPhysics.swift` | 가속도만 회전 래퍼, 위치/캡처/정지는 전역 프레임 |
| `TrajectoryOverlayRenderer.swift` | 높이맵 히트맵 + 궤적 PNG |
| `Gate4RotationWrapperTests.swift` | 등가·대칭·보간·시각화 테스트 |

### 회전 관례

원본 `computeAcceleration`은 중력을 국소 **−X**에 둔다. `descentAzimuth` d(Y축
기준 하강방위, 하강 단위벡터 `(sin d, cos d)`)에 대해

`ψ = atan2(-cos d, -sin d)`

로 국소 (−1, 0)을 전역 하강방향에 맞춘다. 하강 = −X(`d = −π/2`)일 때 ψ=0이라
θ=0 평면은 게이트 2 엔진과 항등 일치한다.

> **수정 (2026-07-20):** 이전 식 `d + π/2`는 하강 −X에서만 맞고, 오르막(+Y) 등
> 다른 방위에서는 중력이 상승 방향으로 뒤집혀 “홀이 높은데 내리막 보정”이
> 나왔다. Gate4 참조 시뮬레이터도 동일 식으로 동기화했다.

캡처 판정은 홀 위치의 국소 α와, 같은 국소 프레임에서 잰 β를 사용한다.

## 검증 결과

- 게이트 4 테스트 7개 통과
- 전체 패키지 테스트(게이트 1~4) 통과
- 기존 `MultibreakPutt` iPhoneOS Release 빌드 성공

### 경계 통과 시각화

`Docs/gate4/`

1. `boundary-cross-downhill-then-sidehill.png` — 하강 후 사이드힐로 전환
2. `boundary-cross-opposite-sideslope.png` — 반대 사이드슬로프 접합
3. `boundary-cross-skewed-break.png` — 비스듬한 이중 브레이크

흰 가로선이 평면 경계, 초록선이 궤적, 흰 점=볼 출발, 검은 원=홀이다.
