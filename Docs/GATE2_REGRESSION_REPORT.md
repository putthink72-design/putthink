# 게이트 2 — 평면 물리엔진 포팅 및 회귀검증 보고서

## 구현 범위

- 원본 Mathematica `Golf_Putting_01.txt`의 마찰 접점 모델과 가속도 블록을 `computeAcceleration` 순수 함수로 이식
- 홀 캡처 조건을 `checkHoleCapture` 순수 함수로 이식
- 위치 `x + v·dt + ½a·dt²`, 속도 명시적 오일러, 판정 순서와 `dt=0.01` 보존
- Break 종료 시 마지막 상태 교체가 실행되지 않는 원본의 `finalPosition`/`finalVelocity` quirk 보존
- Mathematica `Do`와 같은 부동소수 누적 순서의 초기속도·방향 격자 탐색 구현

## 기준 데이터

제공된 세 CSV는 Mathematica 직접 출력이 아니라 `putt_reference.py`가 생성한 독립 Python 재현값이다. 따라서 현재 검증은 “Mathematica 원본과의 직접 회귀검증”이 아니라 “원본을 독립적으로 재현한 Python과 Swift의 교차검증”이다. 향후 Mathematica를 사용할 수 있으면 동일 입력으로 CSV를 교체해야 한다.

## 자동검증 결과

- 궤적 69개: 최종 위치·속도·arcLength·플래그·스텝 수 일치
- 체크포인트 345개: 같은 스텝의 위치·arcLength·속도 일치
- 격자 탐색 4종:
  - S1 52개
  - S2 15개
  - S3 8개
  - S4 244개
  - 총 319개 홀인 조합 및 상세 결과 일치
- `β ≠ 0 ∧ α ≠ 0` 케이스가 전체의 50% 이상
- 최종 위치 허용치 1mm, arcLength 상대오차 0.1%, 플래그 완전 일치 기준 통과

## 기준 README 집계 (수정 반영)

초기 `README_regression_reference.md` / `generate_reference.py` 요약은 종료 경로와 `ballPassOverHoleIf`를 섞어 “정지 55개”로 잘못 적혀 있었다. 수정 후 CSV와 일치하는 집계는 다음과 같다.

| 구분 | 개수 |
|---|---|
| 홀인 (`ballHoleIf=1`, 항상 `ballStopIf=1` 동반) | 12 |
| 순수 정지 (`ballStopIf=1`, `ballHoleIf=0`) | 52 |
| 타임아웃 (`ballHoleIf=0`, `ballStopIf=0`) | 5 |
| `ballStopIf=1` 합계 | 64 |
| `ballPassOverHoleIf=1` (위와 독립 플래그) | 2 |

자동테스트는 처음부터 CSV 값을 기준으로 하며, 위 집계와 일치한다.

## 의도적으로 생략한 항목

원본의 `ycutIf`와 `ycutValue`는 구현 프롬프트에서 파일럿에 불필요하여 생략 가능하다고 명시되어 있어 포팅하지 않았다.
