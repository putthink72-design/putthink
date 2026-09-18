import Foundation

/// `CandidateSelector`가 후보를 찾은 단계. 경기 중 0후보 방지용 폴백 순서를 나타낸다.
public enum CandidateSearchTier: String, Sendable, Codable, Equatable {
    /// 캡처 반경 5.4cm, 기본 격자.
    case verified
    /// 캡처 반경 50cm 재탐색.
    case relaxedCapture
    /// v·β 범위 확대 + 완화 캡처.
    case expandedSearch
    /// 컵(5.4cm) 안을 지나는 물리 궤적. 홀인 캡처는 미검증.
    case proximityEstimate
    /// 거리·고도 기반 β=0 궤적. 마지막 표시용.
    case flatHeuristic
    /// 홀인 후보 없음. 조준 UI는 이 티어를 고객에게 보여 주지 않는다.
    case noPath

    public var isHoleInVerified: Bool {
        switch self {
        case .verified:
            return true
        case .relaxedCapture, .expandedSearch, .proximityEstimate, .flatHeuristic, .noPath:
            return false
        }
    }

    /// 높을수록 조준 화면에 남길 결과.
    public var displayPriority: Int {
        switch self {
        case .verified: return 5
        case .relaxedCapture: return 4
        case .expandedSearch: return 3
        case .proximityEstimate: return 2
        case .flatHeuristic: return 1
        case .noPath: return 0
        }
    }

    public var statusLabel: String {
        switch self {
        case .verified:
            return "홀인 검증"
        case .relaxedCapture:
            return "반경 완화"
        case .expandedSearch:
            return "확장 탐색"
        case .proximityEstimate:
            return "추정 경로 · 홀인 미검증"
        case .flatHeuristic:
            return "거리 추정 · 브레이크 미반영"
        case .noPath:
            return "추정 경로 · 홀인 미검증"
        }
    }
}
