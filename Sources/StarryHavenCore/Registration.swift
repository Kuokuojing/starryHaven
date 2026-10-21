import Foundation

public struct RegistrationOptions: Sendable {
    public var maxStars: Int = 180
    public var maxTriangles: Int = 8000
    public var triangleBin: Double = 0.02
    public var votePositionBin: Double = 2.0
    public var voteScaleBin: Double = 0.005
    public var voteAngleBin: Double = 0.01
    public var matchRadius: Double = 3.0
    public var ransacThreshold: Double = 1.0
    public var ransacIterations: Int = 1500
    public var rejectionRMS: Double = 2.5
    public var seed: UInt64 = 0x5EED1234

    public init() {}
}

public enum RegistrationError: Error, CustomStringConvertible {
    case insufficientStars(count: Int, needed: Int)
    case insufficientEvidence(String)

    public var description: String {
        switch self {
        case .insufficientStars(let c, let n): return "检测到的星点不足：\(c) < \(n)"
        case .insufficientEvidence(let s): return "对齐证据不足：\(s)"
        }
    }
}

public struct RegistrationResult: Sendable {
    public var transform: Matrix3
    public var modelType: TransformModel
    public var rms: Double
    public var inliers: Int
    public var matches: Int
    public var detectedStars: Int
    public var referenceStars: Int
    public var referenceTriangles: Int
    public var imageTriangles: Int
    public var candidateTriangles: Int
    public var votes: Int
    public var message: String
}

private struct Triangle {
    var v: [Int]
    var s1: Double
    var s2: Double
    var s3: Double
    var r1: Double
    var r2: Double
    var orientation: Double
}

private struct VoteKey: Hashable {
    var tx: Int
    var ty: Int
    var scale: Int
    var angle: Int
}

/// Siril-style global registration: flux-ranked detections, triangle invariants
/// with Valdes-style voting, iterative catalogue re-matching, and a final
/// RANSAC similarity/affine/homography model.
public enum StarRegistration {
    public static func register(reference: StarField,
                                image: StarField,
                                referenceWidth: Int,
                                referenceHeight: Int,
                                imageWidth: Int,
                                imageHeight: Int,
                                options: RegistrationOptions = RegistrationOptions()) throws -> RegistrationResult {
        let refStars = Array(reference.stars.prefix(options.maxStars))
        let imgStars = Array(image.stars.prefix(options.maxStars))
        guard imgStars.count >= 12 else {
            throw RegistrationError.insufficientStars(count: imgStars.count, needed: 12)
        }
        guard refStars.count >= 12 else {
            throw RegistrationError.insufficientStars(count: refStars.count, needed: 12)
        }

        let refTri = buildTriangles(stars: refStars, bin: options.triangleBin)
        let imgTri = buildTriangles(stars: imgStars, bin: options.triangleBin)
        guard refTri.count >= 3, imgTri.count >= 3 else {
            throw RegistrationError.insufficientEvidence("三角形不足 (\(refTri.count)/\(imgTri.count))")
        }

        var index: [TriKey: [Int]] = [:]
        for (i, t) in refTri.enumerated() {
            index[triKey(t, bin: options.triangleBin), default: []].append(i)
        }

        var votes: [VoteKey: [Matrix3]] = [:]
        var candidateCount = 0
        for it in imgTri {
            let baseKey = triKey(it, bin: options.triangleBin)
            for dx in -1...1 {
                for dy in -1...1 {
                    let key = TriKey(a: baseKey.a + Int64(dx), b: baseKey.b + Int64(dy))
                    guard let refs = index[key] else { continue }
                    for ri in refs {
                        let rt = refTri[ri]
                        guard (rt.orientation > 0) == (it.orientation > 0) else { continue }
                        let refPts = rt.v.map { (x: refStars[$0].x, y: refStars[$0].y) }
                        let imgPts = it.v.map { (x: imgStars[$0].x, y: imgStars[$0].y) }
                        guard let h = TransformFit.similarity(from: imgPts, to: refPts) else { continue }
                        let scale = h.affineScale
                        guard scale > 0.5, scale < 2.0 else { continue }
                        let angle = h.rotationRadians
                        let vk = VoteKey(
                            tx: Int(round(h.m[2] / options.votePositionBin)),
                            ty: Int(round(h.m[5] / options.votePositionBin)),
                            scale: Int(round(log(scale) / options.voteScaleBin)),
                            angle: Int(round(angle / options.voteAngleBin))
                        )
                        votes[vk, default: []].append(h)
                        candidateCount += 1
                    }
                }
            }
        }

        guard let bestVote = votes.max(by: { $0.value.count < $1.value.count }), bestVote.value.count >= 3 else {
            throw RegistrationError.insufficientEvidence("三角投票没有形成一致峰")
        }

        // Try the strongest vote bins, then refine each candidate.
        let orderedBins = votes.sorted { $0.value.count > $1.value.count }.prefix(6)
        var best: (h: Matrix3, stencil: (s: Double, a: Double, tx: Double, ty: Double), rms: Double, inliers: Int, pairs: Int, votes: Int)?

        for (_, bucket) in orderedBins {
            let sample = Array(bucket.prefix(40))
            for h0 in sample {
                guard let initial = refine(initial: h0, refStars: refStars, imgStars: imgStars, options: options) else { continue }
                if best == nil || initial.inliers > best!.inliers || (initial.inliers == best!.inliers && initial.rms < best!.rms) {
                    best = (initial.h, initial.params, initial.rms, initial.inliers, initial.pairs, bucket.count)
                }
            }
            if let b = best, b.inliers >= max(8, refStars.count / 3) { break }
        }

        guard let result = best, result.inliers >= 6 else {
            throw RegistrationError.insufficientEvidence("匹配内点不足")
        }

        // Final RANSAC with similarity / affine / homography models.
        let pairs = matchPairs(refStars: refStars, imgStars: imgStars, transform: result.h, radius: 1.5)
        guard pairs.count >= 6 else {
            throw RegistrationError.insufficientEvidence("最终匹配点不足")
        }
        let modelCandidates = ransacModels(pairs: pairs, options: options)
        guard !modelCandidates.isEmpty else {
            throw RegistrationError.insufficientEvidence("RANSAC 未找到一致模型")
        }
        var chosen = modelCandidates[0]
        for candidate in modelCandidates.dropFirst() {
            // Prefer the simplest model unless a richer model explains materially more stars.
            if candidate.inliers >= chosen.inliers + 2 {
                chosen = candidate
            }
        }

        var inlierPairs: [(src: (x: Double, y: Double), dst: (x: Double, y: Double))] = []
        for p in pairs {
            let q = chosen.h.apply(p.src.x, p.src.y)
            if hypot(q.x - p.dst.x, q.y - p.dst.y) <= options.ransacThreshold { inlierPairs.append(p) }
        }
        guard inlierPairs.count >= 6 else {
            throw RegistrationError.insufficientEvidence("RANSAC 内点不足")
        }
        let finalFit: Matrix3
        switch chosen.model {
        case .similarity: finalFit = TransformFit.similarity(from: inlierPairs.map { $0.src }, to: inlierPairs.map { $0.dst }) ?? chosen.h
        case .affine: finalFit = TransformFit.affine(from: inlierPairs.map { $0.src }, to: inlierPairs.map { $0.dst }) ?? chosen.h
        case .homography: finalFit = TransformFit.homography(from: inlierPairs.map { $0.src }, to: inlierPairs.map { $0.dst }) ?? chosen.h
        }
        let rms = TransformFit.residualRMS(finalFit, src: inlierPairs.map { $0.src }, dst: inlierPairs.map { $0.dst })
        guard rms <= options.rejectionRMS else {
            throw RegistrationError.insufficientEvidence(String(format: "残差过大 %.3f px", rms))
        }

        let message = String(format: "%@ 模型, RMS %.3f px, 内点 %d/%d, 星点 %d/%d, 三角形 %d/%d, 投票峰 %d",
                             chosen.model.rawValue, rms, inlierPairs.count, pairs.count, imgStars.count, refStars.count,
                             imgTri.count, refTri.count, result.votes)
        return RegistrationResult(transform: finalFit,
                                  modelType: chosen.model,
                                  rms: rms,
                                  inliers: inlierPairs.count,
                                  matches: pairs.count,
                                  detectedStars: image.stars.count,
                                  referenceStars: reference.stars.count,
                                  referenceTriangles: refTri.count,
                                  imageTriangles: imgTri.count,
                                  candidateTriangles: candidateCount,
                                  votes: result.votes,
                                  message: message)
    }

    // MARK: - Triangle construction

    private struct TriKey: Hashable {
        var a: Int64
        var b: Int64
    }

    private static func triKey(_ t: Triangle, bin: Double) -> TriKey {
        TriKey(a: Int64(floor(t.r1 / bin)), b: Int64(floor(t.r2 / bin)))
    }

    private static func buildTriangles(stars: [Star], bin: Double) -> [Triangle] {
        guard stars.count >= 3 else { return [] }
        let n = stars.count
        var triangles: [Triangle] = []
        var seen = Set<Int64>()
        // Keep the field size bounded so a sparse cluster does not dominate.
        for i in 0..<min(n, 120) {
            var dists: [(Int, Double)] = []
            dists.reserveCapacity(n - 1)
            for j in 0..<n where j != i {
                let d = hypot(stars[i].x - stars[j].x, stars[i].y - stars[j].y)
                if d > 2 { dists.append((j, d)) }
            }
            dists.sort { $0.1 < $1.1 }
            let neighbours = dists.prefix(8)
            if neighbours.count < 2 { continue }
            let arr = Array(neighbours)
            for a in 0..<(arr.count - 1) {
                for b in (a + 1)..<arr.count {
                    let idx = [i, arr[a].0, arr[b].0].sorted()
                    let code = Int64(idx[0]) * 1_000_000 + Int64(idx[1]) * 1000 + Int64(idx[2])
                    if !seen.insert(code).inserted { continue }
                    let p0 = stars[idx[0]], p1 = stars[idx[1]], p2 = stars[idx[2]]
                    let d01 = hypot(p0.x - p1.x, p0.y - p1.y)
                    let d12 = hypot(p1.x - p2.x, p1.y - p2.y)
                    let d20 = hypot(p2.x - p0.x, p2.y - p0.y)
                    // Opposite sides.
                    var opp = [(idx[0], d12), (idx[1], d20), (idx[2], d01)]
                    opp.sort { $0.1 < $1.1 }
                    let s1 = opp[0].1, s2 = opp[1].1, s3 = opp[2].1
                    if s1 < 4 { continue }
                    let r1 = s1 / s2, r2 = s2 / s3
                    if r1 < 0.2 || r2 < 0.2 { continue }
                    let v0 = stars[opp[0].0], v1 = stars[opp[1].0], v2 = stars[opp[2].0]
                    let cross = (v1.x - v0.x) * (v2.y - v0.y) - (v1.y - v0.y) * (v2.x - v0.x)
                    triangles.append(Triangle(v: [opp[0].0, opp[1].0, opp[2].0], s1: s1, s2: s2, s3: s3,
                                              r1: r1, r2: r2, orientation: cross))
                    if triangles.count > 12000 { return triangles }
                }
            }
        }
        return triangles
    }

    // MARK: - Pair matching / refinement

    private static func matchPairs(refStars: [Star], imgStars: [Star], transform: Matrix3, radius: Double) -> [(src: (x: Double, y: Double), dst: (x: Double, y: Double))] {
        var candidates: [(ii: Int, ri: Int, d: Double)] = []
        for i in 0..<imgStars.count {
            let p = transform.apply(imgStars[i].x, imgStars[i].y)
            for r in 0..<refStars.count {
                let d = hypot(p.x - refStars[r].x, p.y - refStars[r].y)
                if d <= radius { candidates.append((i, r, d)) }
            }
        }
        candidates.sort { $0.d < $1.d }
        var usedI = Set<Int>()
        var usedR = Set<Int>()
        var out: [(src: (x: Double, y: Double), dst: (x: Double, y: Double))] = []
        for c in candidates {
            if usedI.contains(c.ii) || usedR.contains(c.ri) { continue }
            usedI.insert(c.ii); usedR.insert(c.ri)
            out.append(((imgStars[c.ii].x, imgStars[c.ii].y), (refStars[c.ri].x, refStars[c.ri].y)))
        }
        return out
    }

    private static func refine(initial: Matrix3, refStars: [Star], imgStars: [Star], options: RegistrationOptions)
        -> (h: Matrix3, rms: Double, inliers: Int, pairs: Int, params: (s: Double, a: Double, tx: Double, ty: Double))? {
        var pairs = matchPairs(refStars: refStars, imgStars: imgStars, transform: initial, radius: options.matchRadius)
        guard pairs.count >= 6 else { return nil }
        var h = initial
        for iteration in 0..<2 {
            guard let fit = TransformFit.similarity(from: pairs.map { $0.src }, to: pairs.map { $0.dst }) else { return nil }
            h = fit
            // Sigma-clip residuals, refit, then re-match the full catalog.
            var residuals: [Double] = []
            for p in pairs {
                let q = h.apply(p.src.x, p.src.y)
                residuals.append(hypot(q.x - p.dst.x, q.y - p.dst.y))
            }
            let med = RGBMath.median(residuals.map { Float($0) })
            let mad = RGBMath.mad(residuals.map { Float($0) }, median: med)
            let limit = max(0.35, Double(med) + 3.0 * Double(max(mad, 1e-4)) * 1.4826)
            let filtered = zip(pairs, residuals).filter { $0.1 <= limit }.map { $0.0 }
            if filtered.count >= 6 { pairs = filtered }
            guard let refit = TransformFit.similarity(from: pairs.map { $0.src }, to: pairs.map { $0.dst }) else { return nil }
            h = refit
            let newPairs = matchPairs(refStars: refStars, imgStars: imgStars, transform: h, radius: iteration == 0 ? 2.0 : 1.2)
            if newPairs.count >= 6 { pairs = newPairs }
        }
        guard let fit = TransformFit.similarity(from: pairs.map { $0.src }, to: pairs.map { $0.dst }) else { return nil }
        h = fit
        let rms = TransformFit.residualRMS(h, src: pairs.map { $0.src }, dst: pairs.map { $0.dst })
        let scale = h.affineScale
        return (h, rms, pairs.count, pairs.count, (scale, h.rotationRadians, h.m[2], h.m[5]))
    }

    private struct ModelCandidate {
        var h: Matrix3
        var model: TransformModel
        var inliers: Int
        var rms: Double
    }

    private static func ransacModels(pairs: [(src: (x: Double, y: Double), dst: (x: Double, y: Double))], options: RegistrationOptions) -> [ModelCandidate] {
        guard pairs.count >= 6 else { return [] }
        var rng = SplitMix64(seed: options.seed)
        var models: [ModelCandidate] = []

        func run(model: TransformModel, sampleSize: Int) -> ModelCandidate? {
            var best: ModelCandidate?
            let iterations = min(options.ransacIterations, max(200, pairs.count * 20))
            for _ in 0..<iterations {
                var idx = Set<Int>()
                while idx.count < sampleSize { idx.insert(Int(rng.next() % UInt64(pairs.count))) }
                let sample = idx.map { pairs[$0] }
                let src = sample.map { $0.src }
                let dst = sample.map { $0.dst }
                let h: Matrix3?
                switch model {
                case .similarity: h = TransformFit.similarity(from: src, to: dst)
                case .affine: h = TransformFit.affine(from: src, to: dst)
                case .homography: h = TransformFit.homography(from: src, to: dst)
                }
                guard let candidate = h, candidate.affineScale > 0.5, candidate.affineScale < 2.0 else { continue }
                var inliers = 0
                for p in pairs {
                    let q = candidate.apply(p.src.x, p.src.y)
                    if hypot(q.x - p.dst.x, q.y - p.dst.y) <= options.ransacThreshold { inliers += 1 }
                }
                if best == nil || inliers > best!.inliers {
                    best = ModelCandidate(h: candidate, model: model, inliers: inliers, rms: 0)
                }
            }
            guard var b = best else { return nil }
            var inlierPairs = pairs.filter {
                let q = b.h.apply($0.src.x, $0.src.y)
                return hypot(q.x - $0.dst.x, q.y - $0.dst.y) <= options.ransacThreshold
            }
            guard inlierPairs.count >= sampleSize + 2 else { return nil }
            for _ in 0..<2 {
                let src = inlierPairs.map { $0.src }
                let dst = inlierPairs.map { $0.dst }
                let fit: Matrix3?
                switch model {
                case .similarity: fit = TransformFit.similarity(from: src, to: dst)
                case .affine: fit = TransformFit.affine(from: src, to: dst)
                case .homography: fit = TransformFit.homography(from: src, to: dst)
                }
                guard let f = fit else { return nil }
                b.h = f
                inlierPairs = pairs.filter {
                    let q = f.apply($0.src.x, $0.src.y)
                    return hypot(q.x - $0.dst.x, q.y - $0.dst.y) <= options.ransacThreshold
                }
                if inlierPairs.count < sampleSize + 2 { return nil }
            }
            b.inliers = inlierPairs.count
            b.rms = TransformFit.residualRMS(b.h, src: inlierPairs.map { $0.src }, dst: inlierPairs.map { $0.dst })
            return b
        }

        if let s = run(model: .similarity, sampleSize: 3) { models.append(s) }
        if let a = run(model: .affine, sampleSize: 3) { models.append(a) }
        if let h = run(model: .homography, sampleSize: 4) { models.append(h) }
        // Order: simplest first.
        let order: [TransformModel: Int] = [.similarity: 0, .affine: 1, .homography: 2]
        models.sort { (order[$0.model] ?? 0) < (order[$1.model] ?? 0) }
        return models
    }
}

struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
