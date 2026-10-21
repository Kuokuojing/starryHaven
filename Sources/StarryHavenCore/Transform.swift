import Foundation

/// Row-major 3x3 homogeneous transform mapping image coordinates to reference coordinates.
public struct Matrix3: Sendable, Equatable {
    public var m: [Double]

    public init(_ m: [Double]) {
        precondition(m.count == 9)
        self.m = m
    }

    public static let identity = Matrix3([1, 0, 0, 0, 1, 0, 0, 0, 1])

    public func apply(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
        let w = m[6] * x + m[7] * y + m[8]
        let ww = abs(w) < 1e-12 ? 1e-12 : w
        return ((m[0] * x + m[1] * y + m[2]) / ww, (m[3] * x + m[4] * y + m[5]) / ww)
    }

    public var inverse: Matrix3? {
        let a = m[0], b = m[1], c = m[2]
        let d = m[3], e = m[4], f = m[5]
        let g = m[6], h = m[7], i = m[8]
        let A = e * i - f * h
        let B = -(d * i - f * g)
        let C = d * h - e * g
        let det = a * A + b * B + c * C
        if abs(det) < 1e-14 { return nil }
        let inv = 1.0 / det
        return Matrix3([
            A * inv, -(b * i - c * h) * inv, (b * f - c * e) * inv,
            B * inv, (a * i - c * g) * inv, -(a * f - c * d) * inv,
            C * inv, -(a * h - b * g) * inv, (a * e - b * d) * inv,
        ])
    }

    public var affineScale: Double {
        let sx = sqrt(m[0] * m[0] + m[3] * m[3])
        let sy = sqrt(m[1] * m[1] + m[4] * m[4])
        return sqrt(sx * sy)
    }

    public var rotationRadians: Double {
        atan2(m[3], m[0])
    }
}

public enum TransformModel: String, Sendable {
    case similarity
    case affine
    case homography
}

public enum TransformFit {
    public static func similarity(from src: [(x: Double, y: Double)], to dst: [(x: Double, y: Double)]) -> Matrix3? {
        guard src.count == dst.count, src.count >= 2 else { return nil }
        let n = Double(src.count)
        var cpx = 0.0, cpy = 0.0, cqx = 0.0, cqy = 0.0
        for i in 0..<src.count {
            cpx += src[i].x; cpy += src[i].y
            cqx += dst[i].x; cqy += dst[i].y
        }
        cpx /= n; cpy /= n; cqx /= n; cqy /= n
        var dot = 0.0, cross = 0.0, norm = 0.0
        for i in 0..<src.count {
            let px = src[i].x - cpx, py = src[i].y - cpy
            let qx = dst[i].x - cqx, qy = dst[i].y - cqy
            dot += px * qx + py * qy
            cross += px * qy - py * qx
            norm += px * px + py * py
        }
        guard norm > 1e-12 else { return nil }
        let scale = sqrt(dot * dot + cross * cross) / norm
        let angle = atan2(cross, dot)
        let cosA = cos(angle), sinA = sin(angle)
        let a = scale * cosA, b = -scale * sinA
        let c = scale * sinA, d = scale * cosA
        let tx = cqx - (a * cpx + b * cpy)
        let ty = cqy - (c * cpx + d * cpy)
        return Matrix3([a, b, tx, c, d, ty, 0, 0, 1])
    }

    public static func affine(from src: [(x: Double, y: Double)], to dst: [(x: Double, y: Double)]) -> Matrix3? {
        guard src.count == dst.count, src.count >= 3 else { return nil }
        var ata = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
        var bx = [Double](repeating: 0, count: 3)
        var by = [Double](repeating: 0, count: 3)
        for i in 0..<src.count {
            let row = [src[i].x, src[i].y, 1.0]
            for r in 0..<3 {
                bx[r] += row[r] * dst[i].x
                by[r] += row[r] * dst[i].y
                for c in 0..<3 { ata[r][c] += row[r] * row[c] }
            }
        }
        guard let ax = solveLinear(ata, bx), let ay = solveLinear(ata, by) else { return nil }
        return Matrix3([ax[0], ax[1], ax[2], ay[0], ay[1], ay[2], 0, 0, 1])
    }

    public static func homography(from src: [(x: Double, y: Double)], to dst: [(x: Double, y: Double)]) -> Matrix3? {
        guard src.count == dst.count, src.count >= 4 else { return nil }
        // Hartley normalization for conditioning.
        func normalizer(_ pts: [(x: Double, y: Double)]) -> (Matrix3, Matrix3) {
            let n = Double(pts.count)
            var cx = 0.0, cy = 0.0
            for p in pts { cx += p.x; cy += p.y }
            cx /= n; cy /= n
            var dist = 0.0
            for p in pts { dist += hypot(p.x - cx, p.y - cy) }
            dist /= n
            let s = dist > 1e-9 ? sqrt(2.0) / dist : 1.0
            let t = Matrix3([s, 0, -s * cx, 0, s, -s * cy, 0, 0, 1])
            return (t, t.inverse ?? Matrix3.identity)
        }
        let (ts, _) = normalizer(src)
        let (td, tdInv) = normalizer(dst)
        let sp = src.map { ts.apply($0.x, $0.y) }
        let dp = dst.map { td.apply($0.x, $0.y) }

        var ata = [[Double]](repeating: [Double](repeating: 0, count: 8), count: 8)
        var atb = [Double](repeating: 0, count: 8)
        for i in 0..<sp.count {
            let x = sp[i].x, y = sp[i].y, u = dp[i].x, v = dp[i].y
            let row1 = [x, y, 1, 0, 0, 0, -u * x, -u * y]
            let row2 = [0, 0, 0, x, y, 1, -v * x, -v * y]
            let b1 = u, b2 = v
            for r in 0..<8 {
                atb[r] += row1[r] * b1 + row2[r] * b2
                for c in 0..<8 {
                    ata[r][c] += row1[r] * row1[c] + row2[r] * row2[c]
                }
            }
        }
        guard let h = solveLinear(ata, atb) else { return nil }
        let hN = Matrix3([h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7], 1])
        return tdInv.multiply(hN).multiply(ts)
    }

    public static func residualRMS(_ h: Matrix3, src: [(x: Double, y: Double)], dst: [(x: Double, y: Double)]) -> Double {
        guard !src.isEmpty else { return .infinity }
        var sum = 0.0
        for i in 0..<src.count {
            let p = h.apply(src[i].x, src[i].y)
            let dx = p.x - dst[i].x, dy = p.y - dst[i].y
            let r2 = dx * dx + dy * dy
            if r2.isFinite { sum += r2 }
        }
        return sqrt(sum / Double(src.count))
    }

    public static func solveLinear(_ aIn: [[Double]], _ bIn: [Double]) -> [Double]? {
        let n = bIn.count
        guard n > 0, aIn.count == n else { return nil }
        var a = aIn
        var b = bIn
        for col in 0..<n {
            var pivot = col
            var best = abs(a[col][col])
            for row in (col + 1)..<n where abs(a[row][col]) > best {
                best = abs(a[row][col]); pivot = row
            }
            if best < 1e-13 { return nil }
            if pivot != col { a.swapAt(pivot, col); b.swapAt(pivot, col) }
            let d = a[col][col]
            for j in col..<n { a[col][j] /= d }
            b[col] /= d
            for row in 0..<n where row != col {
                let f = a[row][col]
                if f == 0 { continue }
                for j in col..<n { a[row][j] -= f * a[col][j] }
                b[row] -= f * b[col]
            }
        }
        return b
    }
}

extension Matrix3 {
    public func multiply(_ o: Matrix3) -> Matrix3 {
        var r = [Double](repeating: 0, count: 9)
        for i in 0..<3 {
            for j in 0..<3 {
                var s = 0.0
                for k in 0..<3 { s += m[i * 3 + k] * o.m[k * 3 + j] }
                r[i * 3 + j] = s
            }
        }
        return Matrix3(r)
    }
}
