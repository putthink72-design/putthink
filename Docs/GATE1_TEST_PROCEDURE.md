# 게이트 1 실기기 검증 절차

## 준비

- LiDAR가 있는 iPhone 12 Pro 이상, iOS 17 이상
- Xcode에서 개인 Development Team과 고유 Bundle Identifier 설정
- 실외 잔디 또는 잔디와 표면 특성이 유사한 3~10m 구간
- 시작 볼 위치와 홀 위치를 반복해서 찾을 수 있는 마커
- 세 번의 스캔에서 휴대폰 높이와 방향을 최대한 같게 유지할 보조 지그 또는 스트랩

현재 드리프트 값은 구현 명세에 따라 시작·복귀 카메라 pose의 높이 차입니다. 손 높이가 달라지면 VIO 드리프트와 섞이므로, 시작과 종료 때 휴대폰을 같은 마커 위의 같은 높이에 놓고 버튼을 누릅니다.

## 단일 왕복 스캔

1. `MultibreakPutt.xcodeproj`를 열고 LiDAR 실기기를 실행 대상으로 선택합니다.
2. 앱을 실행하고 카메라 권한을 허용합니다.
3. 휴대폰을 시작 마커의 정해진 높이에 두고 `스캔 시작`을 누릅니다.
4. 트래킹 상태가 `정상`인지 확인하면서 홀까지 천천히 걷습니다.
5. 홀 마커 위에서 `홀 도착 마킹`을 누릅니다.
6. 같은 경로를 따라 시작 마커로 복귀합니다.
7. 시작 때와 같은 자세·높이에서 `볼 복귀 · 스캔 종료`를 누릅니다.
8. 보정 후/스무딩 후 히트맵, 왕복 드리프트, 빈 셀 비율, limited 비율을 확인합니다.
9. 평탄해 보이는 구역에 맞춰 가로·세로 중심과 영역 크기를 조절하고 `선택 영역으로 진단 다시 내보내기`를 누릅니다.

## 3회 반복과 RMS

1. 같은 시작·홀 마커, 같은 보행 경로로 위 절차를 세 번 수행합니다.
2. 세 번째 스캔 결과의 `최근 3회 격자별 RMS`에 세 쌍의 비교값과 공통 셀 수가 표시되는지 확인합니다.
3. RMS는 원측정 셀끼리만, 5cm 로컬 좌표 키가 같은 셀에서 계산됩니다. 공통 셀 수가 지나치게 작으면 세 스캔의 범위와 시작·홀 마킹을 확인하고 다시 측정합니다.

## σ 비교

각 스캔은 σ 0.75, 1.50, 2.25셀의 detrend 후 높이 표준편차를 자동 산출합니다. 결과 화면과 `sigma-noise-comparison.csv`에서 세 값이 모두 기록됐는지 확인합니다. 앱 시작 화면의 σ 슬라이더는 최종 스무딩 높이맵과 기울기 필드에 적용할 값을 정합니다.

## 내보내기 파일

앱 Documents의 `MultibreakPuttScans/scan-날짜-시간/`에 다음 파일이 생성됩니다.

- 드리프트 보정 전·후 및 스무딩 높이맵 JSON/CSV
- 기울기 필드 JSON/CSV
- 스무딩 전·후 히트맵 PNG
- `diagnostics.json`
- `tracking-events.json`
- `sigma-noise-comparison.csv`
- `repeat-scan-rms.csv`
- 전체 재현용 `scan-archive.json`

Finder의 Xcode Devices and Simulators 창에서 설치된 앱 컨테이너를 내려받아 파일을 회수할 수 있습니다.

## 합격 증거 기록표

- 왕복 스캔 완료 및 높이맵 생성: 스크린샷과 스캔 폴더
- 왕복 드리프트 기록: `diagnostics.json`의 `driftMillimeters`
- 보정 전후 저장: `heightmap-before-drift.*`, `heightmap-after-drift.*`
- 3회 RMS: 세 번째 스캔의 `repeat-scan-rms.csv`
- σ 3개 이상 비교: 각 스캔의 `sigma-noise-comparison.csv`
- limited 구간: `tracking-events.json`과 `limitedTrackingRatio`

실기기 측정값이 확보되기 전에는 게이트 1의 현장 합격 기준을 통과한 것으로 판정하지 않습니다.
