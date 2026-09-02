import Foundation
import simd
import XCTest
@testable import PuttPhysicsKit

final class GolfBallVisualLockTests: XCTestCase {
    func testFastDetectorFindsWhiteDiskNearReticle() {
        var image = Self.makeGreenField(width: 80, height: 60)
        Self.stampWhiteCircle(&image, cx: 42, cy: 38, radius: 6)
        let hint = GolfBallDetectionHint.aroundReticle(
            centerX: 41,
            centerY: 39,
            width: 80,
            height: 60,
            expectedRadiusPixels: 6,
            farRadiusPixels: 10
        )
        let blob = GolfBallFastDetector.detect(image: image, hint: hint)
        XCTAssertNotNil(blob)
        XCTAssertEqual(blob!.centerX, 42, accuracy: 1.8)
        XCTAssertEqual(blob!.centerY, 38, accuracy: 1.8)
        XCTAssertGreaterThan(blob!.score, GolfBallFastDetector.minScore)
    }

    func testFastDetectorIgnoresEmptyGreen() {
        let image = Self.makeGreenField(width: 80, height: 60)
        let hint = GolfBallDetectionHint.aroundReticle(
            centerX: 40,
            centerY: 40,
            width: 80,
            height: 60,
            expectedRadiusPixels: 6,
            farRadiusPixels: 10
        )
        XCTAssertNil(GolfBallFastDetector.detect(image: image, hint: hint))
    }

    func testDetectsWhiteCircleOnGreenNearHint() {
        var image = Self.makeGreenField(width: 80, height: 60)
        Self.stampWhiteCircle(&image, cx: 42, cy: 38, radius: 6)
        let hint = GolfBallDetectionHint(
            expectedCenterX: 41,
            expectedCenterY: 39,
            expectedRadiusPixels: 6,
            searchRadiusPixels: 22
        )
        let blob = GolfBallRGBDetector.detect(image: image, hint: hint)
        XCTAssertNotNil(blob)
        XCTAssertEqual(blob!.centerX, 42, accuracy: 1.6)
        XCTAssertEqual(blob!.centerY, 38, accuracy: 1.6)
        XCTAssertGreaterThan(blob!.score, GolfBallRGBDetector.minScore)
    }

    func testIgnoresEmptyGreen() {
        let image = Self.makeGreenField(width: 80, height: 60)
        let hint = GolfBallDetectionHint(
            expectedCenterX: 40,
            expectedCenterY: 40,
            expectedRadiusPixels: 6,
            searchRadiusPixels: 20
        )
        XCTAssertNil(GolfBallRGBDetector.detect(image: image, hint: hint))
    }

    func testPrefersBlobCloserToHint() {
        var image = Self.makeGreenField(width: 100, height: 80)
        Self.stampWhiteCircle(&image, cx: 22, cy: 50, radius: 6)
        Self.stampWhiteCircle(&image, cx: 70, cy: 48, radius: 6)
        let hint = GolfBallDetectionHint(
            expectedCenterX: 68,
            expectedCenterY: 48,
            expectedRadiusPixels: 6,
            searchRadiusPixels: 36
        )
        let blob = GolfBallRGBDetector.detect(image: image, hint: hint)
        XCTAssertNotNil(blob)
        XCTAssertEqual(blob!.centerX, 70, accuracy: 2.0)
    }

    func testRejectsBrightNonCircularPatch() {
        var image = Self.makeGreenField(width: 80, height: 60)
        Self.stampWhiteRect(&image, x0: 20, y0: 20, x1: 58, y1: 28)
        let hint = GolfBallDetectionHint(
            expectedCenterX: 39,
            expectedCenterY: 24,
            expectedRadiusPixels: 6,
            searchRadiusPixels: 24
        )
        XCTAssertNil(GolfBallRGBDetector.detect(image: image, hint: hint))
    }

    func testRejectsTinySpeckThatIsNotABall() {
        var image = Self.makeGreenField(width: 80, height: 60)
        Self.stampWhiteCircle(&image, cx: 40, cy: 38, radius: 2)
        let blob = GolfBallRGBDetector.detect(
            image: image,
            hint: .openSearch(width: 80, height: 60)
        )
        XCTAssertNil(blob)
    }

    func testDetectsDimButClearlyWhiteBall() {
        var image = Self.makeGreenField(width: 80, height: 60)
        Self.stampCircle(&image, cx: 44, cy: 36, radius: 6, luma: 175, sat: 28)
        let blob = GolfBallRGBDetector.detect(
            image: image,
            hint: .openSearch(width: 80, height: 60)
        )
        XCTAssertNotNil(blob)
        XCTAssertEqual(blob!.centerX, 44, accuracy: 2.5)
    }

    func testPrefersLargeHighContrastBallOverTinySpeck() {
        var image = Self.makeGreenField(width: 100, height: 80)
        Self.stampWhiteCircle(&image, cx: 22, cy: 30, radius: 2)
        Self.stampWhiteCircle(&image, cx: 62, cy: 48, radius: 8)
        let blob = GolfBallRGBDetector.detect(
            image: image,
            hint: .openSearch(width: 100, height: 80)
        )
        XCTAssertNotNil(blob)
        XCTAssertEqual(blob!.centerX, 62, accuracy: 3.0)
        XCTAssertEqual(blob!.centerY, 48, accuracy: 3.0)
    }

    func testConsensusPlacesImmediatelyWithMinAgree1() {
        var filter = GolfBallLockConsensus()
        let action = filter.ingest(
            contact: GolfBallWorldContact(worldX: 0.5, worldY: 0.3, worldZ: 1.2, confidence: 0.8),
            currentBallX: nil,
            currentBallZ: nil,
            physicsBallX: nil,
            physicsBallZ: nil,
            minAgree: 1
        )
        guard case .apply(let fix) = action else {
            return XCTFail("expected immediate apply, got \(action)")
        }
        XCTAssertEqual(fix.worldX, 0.5, accuracy: 0.01)
    }

    func testAroundReticleFindsNearbyBallAndIgnoresFarCircle() {
        var image = Self.makeGreenField(width: 160, height: 120)
        Self.stampWhiteCircle(&image, cx: 22, cy: 22, radius: 10)
        Self.stampWhiteCircle(&image, cx: 88, cy: 70, radius: 10)
        let blob = GolfBallRGBDetector.detect(
            image: image,
            hint: .aroundReticle(
                centerX: 86,
                centerY: 68,
                width: 160,
                height: 120,
                expectedRadiusPixels: 10
            )
        )
        XCTAssertNotNil(blob)
        XCTAssertEqual(blob!.centerX, 88, accuracy: 3.0)
        XCTAssertEqual(blob!.centerY, 70, accuracy: 3.0)
    }

    func testAroundReticleFindsStandingSizeBallInNativeCrop() {
        var image = Self.makeGreenField(width: 400, height: 400)
        Self.stampWhiteCircle(&image, cx: 200, cy: 205, radius: 22)
        let blob = GolfBallRGBDetector.detect(
            image: image,
            hint: .aroundReticle(
                centerX: 200,
                centerY: 200,
                width: 400,
                height: 400,
                expectedRadiusPixels: 24,
                farRadiusPixels: 20
            )
        )
        XCTAssertNotNil(blob)
        XCTAssertEqual(blob!.centerX, 200, accuracy: 4.0)
        XCTAssertEqual(blob!.centerY, 205, accuracy: 4.0)
    }

    func testReticleCropFindsGreenTintedBall() {
        var image = Self.makeGreenField(width: 200, height: 200)
        Self.stampCircle(&image, cx: 102, cy: 98, radius: 16, luma: 168, sat: 102)
        let blob = GolfBallRGBDetector.detect(
            image: image,
            hint: .aroundReticle(
                centerX: 100,
                centerY: 100,
                width: 200,
                height: 200,
                expectedRadiusPixels: 18,
                farRadiusPixels: 14
            )
        )
        XCTAssertNotNil(blob)
        XCTAssertEqual(blob!.centerX, 102, accuracy: 4.0)
        XCTAssertEqual(blob!.centerY, 98, accuracy: 4.0)
    }

    func testOpenSearchFindsBallWithoutTightHint() {
        var image = Self.makeGreenField(width: 80, height: 60)
        Self.stampWhiteCircle(&image, cx: 28, cy: 40, radius: 6)
        let blob = GolfBallRGBDetector.detect(
            image: image,
            hint: .openSearch(width: 80, height: 60)
        )
        XCTAssertNotNil(blob)
        XCTAssertEqual(blob!.centerX, 28, accuracy: 2.0)
        XCTAssertEqual(blob!.centerY, 40, accuracy: 2.0)
    }

    func testDetectsStandingHeightBallOnDetectionBuffer() {
        var image = Self.makeGreenField(width: 640, height: 480)
        Self.stampWhiteCircle(&image, cx: 330, cy: 290, radius: 9)
        let blob = GolfBallRGBDetector.detect(
            image: image,
            hint: .openSearch(width: 640, height: 480, focalX: 530)
        )
        XCTAssertNotNil(blob)
        XCTAssertEqual(blob!.centerX, 330, accuracy: 3.0)
        XCTAssertEqual(blob!.centerY, 290, accuracy: 3.0)
    }

    func testStandingBallNotRejectedWhenCloseRangeHintIsTooLarge() {
        var image = Self.makeGreenField(width: 640, height: 480)
        Self.stampWhiteCircle(&image, cx: 300, cy: 310, radius: 8)
        let blob = GolfBallRGBDetector.detect(
            image: image,
            hint: .openSearch(width: 640, height: 480, expectedRadiusPixels: 22, focalX: 530)
        )
        XCTAssertNotNil(blob)
        XCTAssertEqual(blob!.centerX, 300, accuracy: 3.0)
    }

    func testLocalizerAcceptsSteepStandingLookDown() {
        var cameraToWorld = matrix_identity_float4x4
        let origin = SIMD3<Float>(0, 1.32, 0.04)
        let look = simd_normalize(SIMD3<Float>(0, 0.321 - origin.y, 0.18 - origin.z))
        let worldUp = SIMD3<Float>(0, 1, 0)
        let right = simd_normalize(simd_cross(look, worldUp))
        let up = simd_cross(right, look)
        cameraToWorld.columns.0 = SIMD4<Float>(right.x, right.y, right.z, 0)
        cameraToWorld.columns.1 = SIMD4<Float>(up.x, up.y, up.z, 0)
        cameraToWorld.columns.2 = SIMD4<Float>(-look.x, -look.y, -look.z, 0)
        cameraToWorld.columns.3 = SIMD4<Float>(origin.x, origin.y, origin.z, 1)

        let fx: Float = 700
        let fy: Float = 700
        let cx: Float = 160
        let cy: Float = 120
        var intrinsics = matrix_identity_float3x3
        intrinsics[0, 0] = fx
        intrinsics[1, 1] = fy
        intrinsics[2, 0] = cx
        intrinsics[2, 1] = cy
        let sphere = SIMD4<Float>(0, 0.32133, 0.18, 1)
        let local = cameraToWorld.inverse * sphere
        let u = fx * (local.x / -local.z) + cx
        let v = -fy * (local.y / -local.z) + cy

        let contact = GolfBallWorldLocalizer.localize(
            imageX: Double(u),
            imageY: Double(v),
            imageWidth: 320,
            imageHeight: 240,
            sourceWidth: 320,
            sourceHeight: 240,
            rgbIntrinsics: intrinsics,
            cameraToWorld: cameraToWorld,
            groundYSamples: [0.30, 0.30, 0.31],
            fallbackGroundY: 0.30,
            expectedWorldX: nil,
            expectedWorldZ: nil
        )
        XCTAssertNotNil(contact)
        XCTAssertEqual(contact!.worldX, 0, accuracy: 0.05)
        XCTAssertEqual(contact!.worldZ, 0.18, accuracy: 0.05)
    }

    func testPlausibleDiameterAcceptsGolfBall() {
        let fx = 700.0
        let depth = 1.2
        let radiusPx = fx * GolfBallVisualLock.radiusMeters / depth
        let diameter = GolfBallWorldLocalizer.apparentDiameterMeters(
            radiusSourcePixels: radiusPx,
            depthMeters: depth,
            focalX: fx
        )
        XCTAssertNotNil(diameter)
        XCTAssertTrue(GolfBallWorldLocalizer.isPlausibleGolfBallDiameter(diameter!))
        XCTAssertFalse(GolfBallWorldLocalizer.isPlausibleGolfBallDiameter(0.16))
        XCTAssertFalse(GolfBallWorldLocalizer.isPlausibleGolfBallDiameter(0.01))
    }

    func testLocalizerWorksWithoutExpectedARBall() {
        // 카메라 (0, 1.5, -1.2), 지면 Y=0.30, 공은 원점.
        var cameraToWorld = matrix_identity_float4x4
        let origin = SIMD3<Float>(0, 1.5, -1.2)
        let look = simd_normalize(SIMD3<Float>(0, 0.321 - 1.5, 0 - (-1.2)))
        let worldUp = SIMD3<Float>(0, 1, 0)
        let right = simd_normalize(simd_cross(look, worldUp))
        let up = simd_cross(right, look)
        cameraToWorld.columns.0 = SIMD4<Float>(right.x, right.y, right.z, 0)
        cameraToWorld.columns.1 = SIMD4<Float>(up.x, up.y, up.z, 0)
        cameraToWorld.columns.2 = SIMD4<Float>(-look.x, -look.y, -look.z, 0)
        cameraToWorld.columns.3 = SIMD4<Float>(origin.x, origin.y, origin.z, 1)

        let fx: Float = 700
        let fy: Float = 700
        let cx: Float = 160
        let cy: Float = 120
        var intrinsics = matrix_identity_float3x3
        intrinsics[0, 0] = fx
        intrinsics[1, 1] = fy
        intrinsics[2, 0] = cx
        intrinsics[2, 1] = cy
        // 구 중심을 카메라 로컬로 투영해 감지 픽셀을 만든다.
        let sphere = SIMD4<Float>(0, 0.32133, 0, 1)
        let local = cameraToWorld.inverse * sphere
        let u = fx * (local.x / -local.z) + cx
        let v = -fy * (local.y / -local.z) + cy

        let contact = GolfBallWorldLocalizer.localize(
            imageX: Double(u),
            imageY: Double(v),
            imageWidth: 320,
            imageHeight: 240,
            sourceWidth: 320,
            sourceHeight: 240,
            rgbIntrinsics: intrinsics,
            cameraToWorld: cameraToWorld,
            groundYSamples: [0.29, 0.30, 0.31, 0.30, 0.295],
            fallbackGroundY: 0.30,
            expectedWorldX: nil,
            expectedWorldZ: nil
        )
        XCTAssertNotNil(contact)
        XCTAssertEqual(contact!.worldX, 0, accuracy: 0.03)
        XCTAssertEqual(contact!.worldZ, 0, accuracy: 0.03)
        XCTAssertEqual(contact!.worldY, 0.30, accuracy: 0.02)
    }

    func testGroundRingIgnoresBallCenterAndFarPoints() {
        let ys = GolfBallWorldLocalizer.filterGroundRingY(
            samples: [
                (0.00, 0.34, 0.00),   // 공 위치 — 제외
                (0.15, 0.30, 0.02),   // 고리 — 포함
                (0.90, 0.30, 0.00),   // 너무 멀음
                (-0.12, 0.31, 0.08)   // 고리 — 포함
            ],
            expectedX: 0,
            expectedY: 0.30,
            expectedZ: 0
        )
        XCTAssertEqual(ys.count, 2)
        XCTAssertEqual(ys[0], 0.30, accuracy: 0.001)
    }

    func testConsensusRequiresAgreeingFramesThenDeadzones() {
        var filter = GolfBallLockConsensus()
        let current = (x: 0.0, z: 0.0)
        func contact(_ x: Double, _ z: Double) -> GolfBallWorldContact {
            GolfBallWorldContact(worldX: x, worldY: 0.3, worldZ: z, confidence: 0.9)
        }
        XCTAssertEqual(
            filter.ingest(
                contact: contact(0.12, 0.01),
                currentBallX: current.x,
                currentBallZ: current.z,
                physicsBallX: 0,
                physicsBallZ: 0
            ),
            .none
        )
        XCTAssertEqual(
            filter.ingest(
                contact: contact(0.125, 0.008),
                currentBallX: current.x,
                currentBallZ: current.z,
                physicsBallX: 0,
                physicsBallZ: 0
            ),
            .none
        )
        let third = filter.ingest(
            contact: contact(0.118, 0.012),
            currentBallX: current.x,
            currentBallZ: current.z,
            physicsBallX: 0,
            physicsBallZ: 0
        )
        guard case .apply(let fix) = third else {
            return XCTFail("expected apply, got \(third)")
        }
        XCTAssertEqual(fix.worldX, 0.12, accuracy: 0.02)

        let fourth = filter.ingest(
            contact: contact(0.121, 0.011),
            currentBallX: fix.worldX,
            currentBallZ: fix.worldZ,
            physicsBallX: 0,
            physicsBallZ: 0
        )
        XCTAssertEqual(fourth, .none)
    }

    func testConsensusPlacesFirstBallWithoutARHint() {
        var filter = GolfBallLockConsensus()
        var last: GolfBallLockAction = .none
        for _ in 0..<3 {
            last = filter.ingest(
                contact: GolfBallWorldContact(worldX: 0.4, worldY: 0.3, worldZ: 1.1, confidence: 0.9),
                currentBallX: nil,
                currentBallZ: nil,
                physicsBallX: nil,
                physicsBallZ: nil
            )
        }
        guard case .apply(let fix) = last else {
            return XCTFail("expected apply, got \(last)")
        }
        XCTAssertEqual(fix.worldX, 0.4, accuracy: 0.02)
        XCTAssertTrue(filter.locked)
    }

    func testConsensusConfirmsWhenAlreadyAligned() {
        var filter = GolfBallLockConsensus()
        var last: GolfBallLockAction = .none
        for _ in 0..<3 {
            last = filter.ingest(
                contact: GolfBallWorldContact(worldX: 0.004, worldY: 0.3, worldZ: -0.003, confidence: 1),
                currentBallX: 0,
                currentBallZ: 0,
                physicsBallX: 0,
                physicsBallZ: 0
            )
        }
        XCTAssertEqual(last, .confirmAligned)
        XCTAssertTrue(filter.locked)
    }

    func testConsensusRejectsFarFromPhysicsOrigin() {
        var filter = GolfBallLockConsensus()
        let action = filter.ingest(
            contact: GolfBallWorldContact(worldX: 1.2, worldY: 0.3, worldZ: 0, confidence: 1),
            currentBallX: 1.2,
            currentBallZ: 0,
            physicsBallX: 0,
            physicsBallZ: 0
        )
        XCTAssertEqual(action, .none)
        XCTAssertTrue(filter.recent.isEmpty)
    }

    private static func makeGreenField(width: Int, height: Int) -> GolfBallImageBuffer {
        let count = width * height
        return GolfBallImageBuffer(
            width: width,
            height: height,
            luma: [UInt8](repeating: 88, count: count),
            saturation: [UInt8](repeating: 90, count: count)
        )
    }

    private static func stampWhiteCircle(_ image: inout GolfBallImageBuffer, cx: Int, cy: Int, radius: Int) {
        stampCircle(&image, cx: cx, cy: cy, radius: radius, luma: 230, sat: 8)
    }

    private static func stampCircle(
        _ image: inout GolfBallImageBuffer,
        cx: Int,
        cy: Int,
        radius: Int,
        luma: UInt8,
        sat: UInt8
    ) {
        let r2 = radius * radius
        for y in max(0, cy - radius - 1)..<min(image.height, cy + radius + 2) {
            for x in max(0, cx - radius - 1)..<min(image.width, cx + radius + 2) {
                let dx = x - cx
                let dy = y - cy
                if dx * dx + dy * dy <= r2 {
                    image.luma[y * image.width + x] = luma
                    image.saturation[y * image.width + x] = sat
                }
            }
        }
    }

    private static func stampWhiteRect(
        _ image: inout GolfBallImageBuffer,
        x0: Int,
        y0: Int,
        x1: Int,
        y1: Int
    ) {
        for y in max(0, y0)...min(image.height - 1, y1) {
            for x in max(0, x0)...min(image.width - 1, x1) {
                image.luma[y * image.width + x] = 235
                image.saturation[y * image.width + x] = 6
            }
        }
    }
}
