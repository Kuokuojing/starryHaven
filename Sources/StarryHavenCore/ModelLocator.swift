import Foundation

/// Finds optional third-party model artifacts. Weights are not part of this
/// repository and are never copied or redistributed by the app.
public enum ModelLocator {
    public static var applicationSupport: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("StarryHaven", isDirectory: true)
    }

    public static var searchRoots: [URL] {
        var roots: [URL] = []
        if let env = ProcessInfo.processInfo.environment["STARRYHAVEN_MODELS_DIR"], !env.isEmpty {
            roots.append(URL(fileURLWithPath: env, isDirectory: true))
        }
        if let support = applicationSupport?.appendingPathComponent("Models", isDirectory: true) {
            roots.append(support)
        }
        if let bundleResources = Bundle.main.resourceURL {
            roots.append(bundleResources.appendingPathComponent("Models", isDirectory: true))
        }
        return roots
    }

    public static func find(_ relativePath: String) -> URL? {
        for root in searchRoots {
            let candidate = root.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    public static var starNet2: URL? {
        if let env = ProcessInfo.processInfo.environment["STARNET2_MODEL"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return find("split/StarNet2_weights.mlpackage")
    }

    public static var deepSNR: URL? {
        if let env = ProcessInfo.processInfo.environment["DEEPSNR_MODEL"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return find("clean/DeepSNR_weights_v2.mlpackage")
    }

    public static var skySeg: URL? {
        if let env = ProcessInfo.processInfo.environment["SKYSEG_MODEL"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return find("skyseg/skyseg.onnx")
    }

    public static var onnxRuntime: URL? {
        if let env = ProcessInfo.processInfo.environment["ONNXRUNTIME_LIB"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        var candidates: [URL] = []
        if let support = applicationSupport {
            candidates.append(support.appendingPathComponent("libonnxruntime.dylib"))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("libonnxruntime.dylib"))
            candidates.append(resources.appendingPathComponent("Models/libonnxruntime.dylib"))
        }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/lib/libonnxruntime.dylib"))
        candidates.append(URL(fileURLWithPath: "/usr/local/lib/libonnxruntime.dylib"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func artifactDescription(_ url: URL?) -> String {
        guard let url = url else { return "missing" }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return "missing" }
        var size: Int64 = 0
        if isDirectory.boolValue {
            if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
                for case let file as URL in enumerator {
                    size += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
            }
        } else {
            size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return "\(url.lastPathComponent) (\(size) bytes)"
    }

    public static var statusDescription: String {
        func state(_ url: URL?) -> String { url == nil ? "未找到" : url!.path }
        return "StarNet2: \(state(starNet2))\nDeepSNR: \(state(deepSNR))\nSkySeg: \(state(skySeg))\nONNX Runtime: \(state(onnxRuntime))"
    }
}
