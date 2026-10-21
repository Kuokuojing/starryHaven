import Foundation

public struct StackProjectState: Codable, Sendable {
    public var lights: [String] = []
    public var bias: [String] = []
    public var dark: [String] = []
    public var flat: [String] = []
    public var referenceIndex = 0
    public var mode = StackMode.normal.rawValue
    public var method = StackMethod.sigmaClipped.rawValue
    public var lowSigma = 4.0
    public var highSigma = 5.0
    public var sceneMode = SceneMode.fullFrame.rawValue
    public var manualMask: String?
    public var cropToOverlap = false
    public var badPixelCorrection = false
    public var normalizeBackground = true
    public var vignetteCorrection = 0.0
    public var distortionCorrection = 0.0
    public var lensMode = "none"
    public var lcpPath: String?
    public var outputPath: String?
    public var outputFormat = OutputFormat.tiff16.rawValue
    public init() {}
}

public struct TrailProjectState: Codable, Sendable {
    public var frames: [String] = []
    public var method = StackMethod.maximum.rawValue
    public var landscape = LandscapeMotion.fixed.rawValue
    public var removeAircraft = false
    public var outputPath: String?
    public var outputFormat = OutputFormat.tiff16.rawValue
    public init() {}
}

public struct PanoramaProjectState: Codable, Sendable {
    public var frames: [String] = []
    public var referenceIndex = 0
    public var outputPath: String?
    public var outputFormat = OutputFormat.tiff16.rawValue
    public init() {}
}

public struct TimelapseProjectState: Codable, Sendable {
    public var frames: [String] = []
    public var deflickerWindow = 15
    public var fps = 24
    public var videoPath: String?
    public var keyframeDirectory: String?
    public init() {}
}

public struct NarrowbandProjectState: Codable, Sendable {
    public var ha: String?
    public var oiii: String?
    public var sii: String?
    public var palette = NarrowbandPalette.sho.rawValue
    public var removeStars = false
    public var outputPath: String?
    public init() {}
}

/// Native project document. `format`/`workspace` make project files
/// self-describing; paths are stored as strings so a project can be moved
/// between machines and repaired by the user.
public struct StarryHavenProject: Codable, Sendable {
    public static let formatIdentifier = "starryhaven-project"
    public var format = StarryHavenProject.formatIdentifier
    public var version = 1
    public var workspace = "stack"
    public var stack: StackProjectState?
    public var trails: TrailProjectState?
    public var panorama: PanoramaProjectState?
    public var timelapse: TimelapseProjectState?
    public var narrowband: NarrowbandProjectState?
    public var modified = Date()

    public init() {}

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public static func load(from url: URL) throws -> StarryHavenProject {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(StarryHavenProject.self, from: data)
        } catch {
            // Best-effort import of a bare legacy settings document:
            // {"frames": {...}} or {"stack": {...}} with frame arrays.
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                var project = StarryHavenProject()
                if let stack = object["stack"] as? [String: Any] {
                    project.stack = Self.decodeStackDict(stack)
                    project.workspace = "stack"
                } else if object["lights"] is [String] {
                    project.stack = Self.decodeStackDict(object)
                    project.workspace = "stack"
                }
                if project.stack != nil { return project }
            }
            throw error
        }
    }

    private static func decodeStackDict(_ dict: [String: Any]) -> StackProjectState {
        var s = StackProjectState()
        func strings(_ key: String) -> [String] { dict[key] as? [String] ?? [] }
        s.lights = strings("lights"); s.bias = strings("bias"); s.dark = strings("dark"); s.flat = strings("flat")
        if let v = dict["referenceIndex"] as? Int { s.referenceIndex = v }
        if let v = dict["method"] as? String { s.method = v }
        if let v = dict["lowSigma"] as? Double { s.lowSigma = v }
        if let v = dict["highSigma"] as? Double { s.highSigma = v }
        if let v = dict["sceneMode"] as? String { s.sceneMode = v }
        if let v = dict["manualMask"] as? String { s.manualMask = v }
        if let v = dict["cropToOverlap"] as? Bool { s.cropToOverlap = v }
        if let v = dict["outputPath"] as? String { s.outputPath = v }
        return s
    }
}
