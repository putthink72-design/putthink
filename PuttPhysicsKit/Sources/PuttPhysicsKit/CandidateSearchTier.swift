import Foundation

/// `CandidateSelector`가 후보를 찾은 단계. 경기 중 0후보 방지용 폴백 순서를 나타낸다.
public enum CandidateSearchTier: String, Sendable, Codable, Equatable {
    /// 캡처 반경 5.4cm, 기본 격자.
    case verified
    /// 캡처 반경 50cm 재탐색.
    case relaxedCapture
    /// v·β 범위 확대 + 완화 캡처.
    case expandedSearch
    /// 홀 통과 lateral miss 최소 — 홀인 미검증 추정.
    case proximityEstimate
    /// 평지 거리·고도만 반영, β=0.
    case flatHeuristic

    public var isHoleInVerified: Bool {
        switch self {
        case .verified, .relaxedCapture, .expandedSearch:
            return true
        case .proximityEstimate, .flatHeuristic:
            return false
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
        }
    }
}
