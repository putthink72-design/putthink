import simd

/// yaw·위치는 유지하고 pitch/roll만 입장 기준 + 저역 통과로 안정화.
/// LiDAR depth 역투영(스캔)용.
struct CameraTiltStabilizer {
    struct Configuration: Sendable {
        var smoothAlpha: Float
        var deadZoneDegrees: Float
        var maxSlowDegrees: Float

        /// 걸음 떨림 억제 — LiDAR depth → 높이맵 융합용.
        static let scanDepth = Configuration(
            smoothAlpha: 0.10,
            deadZoneDegrees: 5,
            maxSlowDegrees: 20
        )
    }

    var configuration: Configuration

    private var referencePitch: Float?
    private var referenceRoll: Float?
    private var smoothedPitchDelta: Float = 0
    private var smoothedRollDelta: Float = 0

    init(configuration: Configuration = .scanDepth) {
        self.configuration = configuration
    }

    mutating func reset() {
        referencePitch = nil
        referenceRoll = nil
        smoothedPitchDelta = 0
        smoothedRollDelta = 0
    }

    /// 볼 확정·HUD 진입 등 안정된 순간의 기준 자세.
    mutating func captureReference(from transform: simd_float4x4) {
        let (_, pitch, roll) = Self.extractYawPitchRoll(transform)
        referencePitch = pitch
        referenceRoll = roll
        smoothedPitchDelta = 0
        smoothedRollDelta = 0
    }

    mutating func stabilizedTransform(from raw: simd_float4x4) -> simd_float4x4 {
        let position = SIMD3<Float>(raw.columns.3.x, raw.columns.3.y, raw.columns.3.z)
        let (yaw, pitch, roll) = Self.extractYawPitchRoll(raw)

        if referencePitch == nil {
            captureReference(from: raw)
        }

        let refPitch = referencePitch ?? pitch
        let refRoll = referenceRoll ?? roll
        let deltaPitch = pitch - refPitch
        let deltaRoll = roll - refRoll

        smoothedPitchDelta += (deltaPitch - smoothedPitchDelta) * configuration.smoothAlpha
        smoothedRollDelta += (deltaRoll - smoothedRollDelta) * configuration.smoothAlpha

        let maxSlow = configuration.maxSlowDegrees * .pi / 180
        var stablePitchDelta = Self.applyDeadZone(
            smoothedPitchDelta,
            deadZoneDegrees: configuration.deadZoneDegrees
        )
        var stableRollDelta = Self.applyDeadZone(
            smoothedRollDelta,
            deadZoneDegrees: configuration.deadZoneDegrees
        )
        stablePitchDelta = min(max(stablePitchDelta, -maxSlow), maxSlow)
        stableRollDelta = min(max(stableRollDelta, -maxSlow), maxSlow)

        return Self.buildTransform(
            position: position,
            yaw: yaw,
            pitch: refPitch + stablePitchDelta,
            roll: refRoll + stableRollDelta
        )
    }

    private static func applyDeadZone(_ delta: Float, deadZoneDegrees: Float) -> Float {
        let dead = deadZoneDegrees * .pi / 180
        if abs(delta) <= dead { return 0 }
        return delta > 0 ? delta - dead : delta + dead
    }

    private static func extractYawPitchRoll(_ transform: simd_float4x4) -> (yaw: Float, pitch: Float, roll: Float) {
        let forward = -SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        let up = SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)
        let yaw = atan2(forward.x, forward.z)
        let pitch = atan2(forward.y, max(hypot(forward.x, forward.z), 1e-6))
        let fwdNorm = simd_normalize(forward)
        var refUp = SIMD3<Float>(0, 1, 0) - fwdNorm * simd_dot(SIMD3<Float>(0, 1, 0), fwdNorm)
        if simd_length(refUp) < 1e-4 {
            refUp = SIMD3<Float>(0, 1, 0)
        } else {
            refUp = simd_normalize(refUp)
        }
        let refRight = simd_normalize(simd_cross(refUp, fwdNorm))
        let roll = atan2(simd_dot(up, refUp), simd_dot(up, refRight))
        return (yaw, pitch, roll)
    }

    private static func buildTransform(
        position: SIMD3<Float>,
        yaw: Float,
        pitch: Float,
        roll: Float
    ) -> simd_float4x4 {
        let sy = sin(yaw), cy = cos(yaw)
        let sp = sin(pitch), cp = cos(pitch)
        var forward = SIMD3<Float>(sy * cp, sp, cy * cp)
        forward = simd_normalize(forward)

        var right = simd_cross(SIMD3<Float>(0, 1, 0), forward)
        if simd_length(right) < 1e-4 {
            right = SIMD3<Float>(1, 0, 0)
        } else {
            right = simd_normalize(right)
        }
        var up = simd_normalize(simd_cross(forward, right))
        let qRoll = simd_quatf(angle: roll, axis: forward)
        right = simd_act(qRoll, right)
        up = simd_act(qRoll, up)

        var transform = matrix_identity_float4x4
        transform.columns.0 = SIMD4(right.x, right.y, right.z, 0)
        transform.columns.1 = SIMD4(up.x, up.y, up.z, 0)
        transform.columns.2 = SIMD4(-forward.x, -forward.y, -forward.z, 0)
        transform.columns.3 = SIMD4(position.x, position.y, position.z, 1)
        return transform
    }
}
