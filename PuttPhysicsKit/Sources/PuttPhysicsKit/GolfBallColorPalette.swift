import Foundation

/// 시판 골프공 커버 컬러(Titleist / Callaway / TaylorMade / Srixon / Bridgestone / Volvik 등).
///
/// 조사 요약(소매·브랜드 SKU 기준):
/// - White: 거의 모든 투어/레저 볼
/// - Yellow / High Optic Yellow: Pro V1, Chrome Tour, Soft Feel, e6 등
/// - Orange / Neon Orange / Apricot: Velocity, Soft Feel Brite, Tour Response Stripe, Volvik
/// - Pink / Neon Pink / Lady Pink: Soft Feel Lady, Tour Response Stripe, Volvik, Supersoft
/// - Red / Brite Red: Soft Feel Brite, Volvik Vivid
/// - Green / Lime / Matte Green / Brite Green: Velocity green, Bridgestone matte, Volvik, Soft Feel Brite
/// - Blue / Neon Blue / Navy: Tour Response Stripe, Volvik Vivid
/// - Purple: Volvik Vivid
/// - Black (matte): Volvik Vivid 등 — 잔디 대비가 어두움
public enum GolfBallMarketColor: String, CaseIterable, Sendable, Equatable {
    case white
    case yellow
    case orange
    case pink
    case red
    case green
    case blue
    case purple
    case black
}

/// HSV-ish 판정. hue는 0…179 (degree/2, OpenCV 스타일).
public enum GolfBallColorPalette {
    public struct Spec: Sendable, Equatable {
        public var color: GolfBallMarketColor
        /// inclusive start, exclusive end in 0…360 (wrap 허용).
        public var hueStartDeg: Int
        public var hueEndDeg: Int
        public var minSaturation: Int
        public var maxSaturation: Int
        public var minLuma: Int
        public var maxLuma: Int

        public init(
            color: GolfBallMarketColor,
            hueStartDeg: Int,
            hueEndDeg: Int,
            minSaturation: Int,
            maxSaturation: Int,
            minLuma: Int,
            maxLuma: Int
        ) {
            self.color = color
            self.hueStartDeg = hueStartDeg
            self.hueEndDeg = hueEndDeg
            self.minSaturation = minSaturation
            self.maxSaturation = maxSaturation
            self.minLuma = minLuma
            self.maxLuma = maxLuma
        }
    }

    /// 시판 팔레트. 흰 공은 채도만으로, 유색은 hue 밴드로 본다.
    public static let specs: [Spec] = [
        // White / optic white
        Spec(color: .white, hueStartDeg: 0, hueEndDeg: 360, minSaturation: 0, maxSaturation: 88, minLuma: 145, maxLuma: 255),
        // Yellow / high-optic yellow / neon yellow
        Spec(color: .yellow, hueStartDeg: 38, hueEndDeg: 78, minSaturation: 36, maxSaturation: 255, minLuma: 105, maxLuma: 255),
        // Orange / neon orange / apricot
        Spec(color: .orange, hueStartDeg: 12, hueEndDeg: 42, minSaturation: 48, maxSaturation: 255, minLuma: 88, maxLuma: 255),
        // Pink / neon pink / lady pink
        Spec(color: .pink, hueStartDeg: 300, hueEndDeg: 348, minSaturation: 36, maxSaturation: 255, minLuma: 95, maxLuma: 255),
        // Red / brite red (wraps across 0°)
        Spec(color: .red, hueStartDeg: 348, hueEndDeg: 18, minSaturation: 48, maxSaturation: 255, minLuma: 70, maxLuma: 255),
        // Green / lime / matte green / brite green — 잔디와 겹치므로 luma·sat를 높게
        Spec(color: .green, hueStartDeg: 78, hueEndDeg: 165, minSaturation: 70, maxSaturation: 255, minLuma: 118, maxLuma: 255),
        // Blue / neon blue / navy(밝기 낮은 쪽)
        Spec(color: .blue, hueStartDeg: 175, hueEndDeg: 255, minSaturation: 40, maxSaturation: 255, minLuma: 55, maxLuma: 255),
        // Purple / violet
        Spec(color: .purple, hueStartDeg: 255, hueEndDeg: 305, minSaturation: 40, maxSaturation: 255, minLuma: 55, maxLuma: 255),
        // Matte black
        Spec(color: .black, hueStartDeg: 0, hueEndDeg: 360, minSaturation: 0, maxSaturation: 70, minLuma: 0, maxLuma: 58)
    ]

    public static func hueByte(fromDegrees deg: Double) -> UInt8 {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return UInt8(min(179, max(0, Int((d * 0.5).rounded()))))
    }

    /// YCbCr → hue byte (0…179). BT.601 근사로 RGB 복원 후 HSV hue.
    public static func hueByte(luma y: Int, cb: Int, cr: Int) -> UInt8 {
        let yf = Double(y)
        let dCb = Double(cb - 128)
        let dCr = Double(cr - 128)
        let r = min(255, max(0, yf + 1.402 * dCr))
        let g = min(255, max(0, yf - 0.344136 * dCb - 0.714136 * dCr))
        let b = min(255, max(0, yf + 1.772 * dCb))
        return hueByte(r: r, g: g, b: b)
    }

    /// 레거시: Cb/Cr만으로 추정(테스트·폴백). 가능하면 `hueByte(luma:cb:cr:)` 사용.
    public static func hueByte(cb: Int, cr: Int) -> UInt8 {
        hueByte(luma: 160, cb: cb, cr: cr)
    }

    /// BGRA/RGB → hue byte.
    public static func hueByte(r: Double, g: Double, b: Double) -> UInt8 {
        let maxC = max(r, max(g, b))
        let minC = min(r, min(g, b))
        let delta = maxC - minC
        guard delta > 1, maxC > 1 else { return 0 }
        var h: Double
        if maxC == r {
            h = (g - b) / delta
        } else if maxC == g {
            h = 2 + (b - r) / delta
        } else {
            h = 4 + (r - g) / delta
        }
        h *= 60
        if h < 0 { h += 360 }
        return hueByte(fromDegrees: h)
    }

    public static func matches(
        luma: Int,
        saturation: Int,
        hueByte: UInt8
    ) -> GolfBallMarketColor? {
        let hueDeg = Int(hueByte) * 2
        for spec in specs {
            guard luma >= spec.minLuma, luma <= spec.maxLuma else { continue }
            guard saturation >= spec.minSaturation, saturation <= spec.maxSaturation else { continue }
            if spec.color == .white || spec.color == .black {
                return spec.color
            }
            if hueInRange(hueDeg, start: spec.hueStartDeg, end: spec.hueEndDeg) {
                return spec.color
            }
        }
        return nil
    }

    public static func isBallPixel(luma: Int, saturation: Int, hueByte: UInt8) -> Bool {
        matches(luma: luma, saturation: saturation, hueByte: hueByte) != nil
    }

    /// 디스크 평균으로 유색/암색 여부. 링 대비를 절대값으로 볼지 결정.
    public static func prefersAbsoluteRingContrast(color: GolfBallMarketColor?) -> Bool {
        switch color {
        case .black, .blue, .purple, .red, .green:
            return true
        default:
            return false
        }
    }

    private static func hueInRange(_ hue: Int, start: Int, end: Int) -> Bool {
        let h = ((hue % 360) + 360) % 360
        if start <= end {
            return h >= start && h < end
        }
        // wrap (e.g. red 348…18)
        return h >= start || h < end
    }
}
