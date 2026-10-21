import Foundation

public enum FITSError: Error, CustomStringConvertible {
    case invalidHeader
    case unsupported(String)
    case truncated
    public var description: String {
        switch self {
        case .invalidHeader: return "FITS: invalid header"
        case .unsupported(let s): return "FITS: unsupported \(s)"
        case .truncated: return "FITS: truncated data"
        }
    }
}

/// Minimal FITS reader/writer: 1-3 axes, BITPIX 8/16/32/-32/-64, BZERO/BSCALE.
public enum FITS {
    public struct HeaderInfo {
        public var width = 0
        public var height = 0
        public var naxis = 0
        public var planes = 1
        public var bitpix = 0
        public var bzero: Double = 0
        public var bscale: Double = 1
        public var dataOffset = 0
    }

    public static func readHeader(_ data: Data) throws -> HeaderInfo {
        var info = HeaderInfo()
        var offset = 0
        var sawEnd = false
        var cards: [String] = []
        while offset + 80 <= data.count {
            let cardData = data.subdata(in: offset..<(offset + 80))
            guard let card = String(data: cardData, encoding: .ascii) else { throw FITSError.invalidHeader }
            cards.append(card)
            offset += 80
            if card.hasPrefix("END") { sawEnd = true; break }
            if offset >= 2880 * 100 { break }
        }
        guard sawEnd else { throw FITSError.invalidHeader }
        // Header is padded to 2880-byte blocks.
        info.dataOffset = ((offset + 2879) / 2880) * 2880

        var naxis3: Int?
        for card in cards {
            let key = String(card.prefix(8)).trimmingCharacters(in: .whitespaces)
            guard key != "END", key != "COMMENT", key != "HISTORY" else { continue }
            guard card.count >= 10, card[card.index(card.startIndex, offsetBy: 8)] == "=" else { continue }
            let valuePart = String(card.dropFirst(10))
            if key == "NAXIS" { info.naxis = parseAxisCount(valuePart) ?? info.naxis }
            if key == "NAXIS1" { info.width = parseInt(valuePart) ?? 0 }
            if key == "NAXIS2" { info.height = parseInt(valuePart) ?? 0 }
            if key == "NAXIS3" { naxis3 = parseInt(valuePart) }
            if key == "BITPIX" { info.bitpix = parseInt(valuePart) ?? 0 }
            if key == "BZERO" { info.bzero = parseDouble(valuePart) ?? 0 }
            if key == "BSCALE" { info.bscale = parseDouble(valuePart) ?? 1 }
        }
        // NAXIS is the number of axes, not the plane count. A 2D FITS file has
        // exactly one image plane; only a 3D file (NAXIS=3) has NAXIS3 planes.
        if info.naxis >= 3 {
            info.planes = max(naxis3 ?? 1, 1)
        } else if naxis3 != nil {
            info.planes = max(naxis3!, 1)
        } else {
            info.planes = 1
        }
        guard info.width > 0, info.height > 0 else { throw FITSError.invalidHeader }
        return info
    }

    private static func parseInt(_ s: String) -> Int? {
        let trimmed = s.split(separator: "/").first.map(String.init) ?? s
        return Int(trimmed.trimmingCharacters(in: .whitespaces))
    }

    private static func parseDouble(_ s: String) -> Double? {
        let trimmed = s.split(separator: "/").first.map(String.init) ?? s
        return Double(trimmed.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "D", with: "E"))
    }

    private static func parseAxisCount(_ s: String) -> Int? {
        let t = s.split(separator: "/").first.map(String.init) ?? s
        return Int(t.trimmingCharacters(in: .whitespaces))
    }

    public static func read(url: URL) throws -> ImageBuffer {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try read(data: data)
    }

    public static func read(data: Data) throws -> ImageBuffer {
        let info = try readHeader(data)
        let n = info.width * info.height
        let planes = max(info.planes, 1)
        let bytesPerSample: Int
        switch info.bitpix {
        case 8: bytesPerSample = 1
        case 16: bytesPerSample = 2
        case 32: bytesPerSample = 4
        case -32: bytesPerSample = 4
        case -64: bytesPerSample = 8
        default: throw FITSError.unsupported("BITPIX \(info.bitpix)")
        }
        let total = n * planes
        guard data.count >= info.dataOffset + total * bytesPerSample else { throw FITSError.truncated }

        let channels = planes >= 3 ? 3 : 1
        let readPlanes = channels == 3 ? min(planes, 3) : 1
        var out = ImageBuffer(width: info.width, height: info.height, channels: channels)
        let scale = Float(info.bscale)
        let zero = Float(info.bzero)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for plane in 0..<readPlanes {
                for i in 0..<n {
                    let off = info.dataOffset + (plane * n + i) * bytesPerSample
                    var v: Float
                    switch info.bitpix {
                    case 8:
                        v = Float(raw[off])
                    case 16:
                        let bits = UInt16(raw[off]) << 8 | UInt16(raw[off + 1])
                        v = Float(Int16(bitPattern: bits))
                    case 32:
                        var bits: UInt32 = 0
                        for b in 0..<4 { bits = (bits << 8) | UInt32(raw[off + b]) }
                        v = Float(Int32(bitPattern: bits))
                    case -32:
                        var bits: UInt32 = 0
                        for b in 0..<4 { bits = (bits << 8) | UInt32(raw[off + b]) }
                        v = Float(bitPattern: bits)
                    case -64:
                        var bits: UInt64 = 0
                        for b in 0..<8 { bits = (bits << 8) | UInt64(raw[off + b]) }
                        v = Float(Double(bitPattern: bits))
                    default: v = 0
                    }
                    let value = v * scale + zero
                    if channels == 3 {
                        let c = min(plane, 2)
                        out.pixels[i * 3 + c] = value
                    } else {
                        out.pixels[i] = value
                    }
                }
            }
        }
        if channels == 1 {
            // Replicate mono to RGB.
            var rgb = ImageBuffer(width: info.width, height: info.height, channels: 3)
            for i in 0..<n {
                let v = out.pixels[i]
                rgb.pixels[i * 3] = v; rgb.pixels[i * 3 + 1] = v; rgb.pixels[i * 3 + 2] = v
            }
            return rgb
        }
        return out
    }

    public static func write(_ image: ImageBuffer, url: URL, metadata: [String: String] = [:]) throws {
        let header = try makeHeader(image: image, metadata: metadata)
        var data = Data(header.utf8)
        var floatData = Data(capacity: image.width * image.height * 3 * 4)
        // FITS stores planar data: R plane, G plane, B plane.
        for c in 0..<3 {
            var channel = [Float](repeating: 0, count: image.count)
            for i in 0..<image.count { channel[i] = image.pixels[i * image.channels + min(c, image.channels - 1)] }
            channel.withUnsafeBufferPointer { buf in
                for v in buf {
                    var be = v.bitPattern.bigEndian
                    withUnsafeBytes(of: &be) { floatData.append(contentsOf: $0) }
                }
            }
        }
        data.append(floatData)
        // Every FITS HDU is padded to a 2880-byte record boundary.
        let pad = (2880 - data.count % 2880) % 2880
        if pad > 0 { data.append(Data(repeating: 0, count: pad)) }
        try data.write(to: url, options: .atomic)
    }

    private static func makeHeader(image: ImageBuffer, metadata: [String: String]) throws -> String {
        func card(_ key: String, _ value: String) -> String {
            let k = key.padding(toLength: 8, withPad: " ", startingAt: 0)
            let v = value.count > 60 ? String(value.prefix(60)) : value
            let line = k + "= " + v
            return line.padding(toLength: 80, withPad: " ", startingAt: 0)
        }
        func number(_ v: Int) -> String { String(format: "%20d", v) }
        func real(_ v: Double) -> String { String(format: "%20.12E", v) }

        var cards: [String] = []
        cards.append(card("SIMPLE", "T"))
        cards.append(card("BITPIX", number(-32)))
        cards.append(card("NAXIS", number(3)))
        cards.append(card("NAXIS1", number(image.width)))
        cards.append(card("NAXIS2", number(image.height)))
        cards.append(card("NAXIS3", number(3)))
        cards.append(card("BZERO", real(0)))
        cards.append(card("BSCALE", real(1)))
        cards.append(card("CTYPE1", "'X       '"))
        cards.append(card("CTYPE2", "'Y       '"))
        cards.append(card("CTYPE3", "'RGB     '"))
        let formatter = ISO8601DateFormatter()
        cards.append(card("DATE", "'\(formatter.string(from: Date()))'"))
        cards.append(card("CREATOR", "'StarryHaven'"))
        for (k, v) in metadata.sorted(by: { $0.key < $1.key }) {
            let key = String(k.uppercased().prefix(8))
            if ["SIMPLE", "BITPIX", "NAXIS", "NAXIS1", "NAXIS2", "NAXIS3", "BZERO", "BSCALE", "DATE", "CREATOR"].contains(key) { continue }
            cards.append(card(key, "'\(v.replacingOccurrences(of: "'", with: " "))'"))
        }
        cards.append("END".padding(toLength: 80, withPad: " ", startingAt: 0))
        var header = cards.joined()
        let pad = (2880 - header.count % 2880) % 2880
        header += String(repeating: " ", count: pad)
        return header
    }
}
