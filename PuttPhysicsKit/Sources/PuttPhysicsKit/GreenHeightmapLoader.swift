import Foundation
import zlib

public enum GreenHeightmapError: LocalizedError, Equatable {
    case cannotReadFile
    case gzipFailed
    case invalidMagic
    case unsupportedVersion(UInt16)
    case truncated
    case emptyValidCells

    public var errorDescription: String? {
        switch self {
        case .cannotReadFile: return "그린 높이맵 파일을 읽을 수 없습니다."
        case .gzipFailed: return "gzip 압축 해제에 실패했습니다."
        case .invalidMagic: return "GRNH 매직 헤더가 올바르지 않습니다."
        case .unsupportedVersion(let version): return "지원하지 않는 GRNH 버전입니다: \(version)"
        case .truncated: return "GRNH 파일이 잘렸습니다."
        case .emptyValidCells: return "유효한 높이 셀이 없습니다."
        }
    }
}

public struct GreenHeightmap: Sendable, Equatable {
    public static let missingSentinel: Int16 = -32768

    public var version: UInt16
    public var originX: Double
    public var originY: Double
    public var cellSize: Double
    public var zOrigin: Double
    public var width: Int
    public var height: Int
    public var cells: [Int16]

    public init(
        version: UInt16,
        originX: Double,
        originY: Double,
        cellSize: Double,
        zOrigin: Double,
        width: Int,
        height: Int,
        cells: [Int16]
    ) {
        precondition(width > 0 && height > 0)
        precondition(cells.count == width * height)
        self.version = version
        self.originX = originX
        self.originY = originY
        self.cellSize = cellSize
        self.zOrigin = zOrigin
        self.width = width
        self.height = height
        self.cells = cells
    }

    public var cellCount: Int { width * height }

    public func isMissing(column: Int, row: Int) -> Bool {
        cells[row * width + column] == Self.missingSentinel
    }

    public func heightMeters(column: Int, row: Int) -> Double? {
        let raw = cells[row * width + column]
        guard raw != Self.missingSentinel else { return nil }
        return zOrigin + Double(raw) / 1000.0
    }

    public func worldX(column: Int) -> Double {
        originX + Double(column) * cellSize
    }

    public func worldY(row: Int) -> Double {
        originY + Double(row) * cellSize
    }

    public var missingRatio: Double {
        guard cellCount > 0 else { return 1 }
        let missing = cells.reduce(0) { $0 + ($1 == Self.missingSentinel ? 1 : 0) }
        return Double(missing) / Double(cellCount)
    }

    public var reliefMeters: Double {
        var minimum = Double.greatestFiniteMagnitude
        var maximum = -Double.greatestFiniteMagnitude
        for row in 0..<height {
            for column in 0..<width {
                guard let value = heightMeters(column: column, row: row) else { continue }
                minimum = min(minimum, value)
                maximum = max(maximum, value)
            }
        }
        guard minimum <= maximum else { return 0 }
        return maximum - minimum
    }

    public func validCentroid() throws -> PuttVector2 {
        var sumX = 0.0
        var sumY = 0.0
        var count = 0
        for row in 0..<height {
            for column in 0..<width where !isMissing(column: column, row: row) {
                sumX += worldX(column: column)
                sumY += worldY(row: row)
                count += 1
            }
        }
        guard count > 0 else { throw GreenHeightmapError.emptyValidCells }
        return PuttVector2(x: sumX / Double(count), y: sumY / Double(count))
    }
}

public enum GreenHeightmapLoader {
    public static func load(from url: URL) throws -> GreenHeightmap {
        let compressed: Data
        do {
            compressed = try Data(contentsOf: url)
        } catch {
            throw GreenHeightmapError.cannotReadFile
        }
        return try load(gzipData: compressed)
    }

    public static func load(gzipData: Data) throws -> GreenHeightmap {
        let raw = try gunzip(gzipData)
        return try parse(raw)
    }

    public static func parse(_ data: Data) throws -> GreenHeightmap {
        guard data.count >= 38 else { throw GreenHeightmapError.truncated }
        return try data.withUnsafeBytes { buffer -> GreenHeightmap in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else {
                throw GreenHeightmapError.truncated
            }
            let magic = String(bytes: UnsafeBufferPointer(start: base, count: 4), encoding: .ascii)
            guard magic == "GRNH" else { throw GreenHeightmapError.invalidMagic }

            let version = readUInt16(base, offset: 4)
            guard version == 1 else { throw GreenHeightmapError.unsupportedVersion(version) }
            let originX = readDouble(base, offset: 6)
            let originY = readDouble(base, offset: 14)
            let cellSize = Double(readFloat(base, offset: 22))
            let zOrigin = Double(readFloat(base, offset: 26))
            let width = Int(readUInt32(base, offset: 30))
            let height = Int(readUInt32(base, offset: 34))
            let expected = 38 + width * height * 2
            guard data.count >= expected else { throw GreenHeightmapError.truncated }

            var cells = [Int16](repeating: 0, count: width * height)
            for index in 0..<(width * height) {
                cells[index] = readInt16(base, offset: 38 + index * 2)
            }
            return GreenHeightmap(
                version: version,
                originX: originX,
                originY: originY,
                cellSize: cellSize,
                zOrigin: zOrigin,
                width: width,
                height: height,
                cells: cells
            )
        }
    }

    private static func gunzip(_ data: Data) throws -> Data {
        if data.count >= 4,
           let magic = String(bytes: data.prefix(4), encoding: .ascii),
           magic == "GRNH" {
            return data
        }

        var stream = z_stream()
        var status = data.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.bindMemory(to: Bytef.self).baseAddress else { return Z_DATA_ERROR }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(raw.count)
            return inflateInit2_(&stream, 16 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        }
        guard status == Z_OK else { throw GreenHeightmapError.gzipFailed }

        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        defer { inflateEnd(&stream) }

        repeat {
            status = chunk.withUnsafeMutableBytes { raw -> Int32 in
                stream.next_out = raw.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(raw.count)
                return inflate(&stream, Z_NO_FLUSH)
            }
            let produced = chunk.count - Int(stream.avail_out)
            if produced > 0 {
                output.append(chunk, count: produced)
            }
            if status == Z_STREAM_END {
                break
            }
            guard status == Z_OK else { throw GreenHeightmapError.gzipFailed }
        } while true

        return output
    }

    private static func readUInt16(_ base: UnsafePointer<UInt8>, offset: Int) -> UInt16 {
        UnsafeRawPointer(base.advanced(by: offset)).loadUnaligned(as: UInt16.self)
    }

    private static func readUInt32(_ base: UnsafePointer<UInt8>, offset: Int) -> UInt32 {
        UnsafeRawPointer(base.advanced(by: offset)).loadUnaligned(as: UInt32.self)
    }

    private static func readInt16(_ base: UnsafePointer<UInt8>, offset: Int) -> Int16 {
        UnsafeRawPointer(base.advanced(by: offset)).loadUnaligned(as: Int16.self)
    }

    private static func readFloat(_ base: UnsafePointer<UInt8>, offset: Int) -> Float {
        UnsafeRawPointer(base.advanced(by: offset)).loadUnaligned(as: Float.self)
    }

    private static func readDouble(_ base: UnsafePointer<UInt8>, offset: Int) -> Double {
        UnsafeRawPointer(base.advanced(by: offset)).loadUnaligned(as: Double.self)
    }
}
