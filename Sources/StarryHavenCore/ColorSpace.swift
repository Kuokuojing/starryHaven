import Foundation

/// sRGB transfer functions. Linear data is what the processing core works in.
public enum SRGB {
    @inline(__always)
    public static func decode(_ v: Float) -> Float {
        if v <= 0.04045 { return v / 12.92 }
        return pow((v + 0.055) / 1.055, 2.4)
    }

    @inline(__always)
    public static func encode(_ v: Float) -> Float {
        let x = max(v, 0)
        if x <= 0.0031308 { return x * 12.92 }
        return 1.055 * pow(x, 1.0 / 2.4) - 0.055
    }

    public static func decodeBuffer(_ image: ImageBuffer) -> ImageBuffer {
        var out = image
        for i in out.pixels.indices { out.pixels[i] = decode(out.pixels[i]) }
        return out
    }

    public static func encodeBuffer(_ image: ImageBuffer) -> ImageBuffer {
        var out = image
        for i in out.pixels.indices { out.pixels[i] = encode(out.pixels[i]) }
        return out
    }
}

/// Midtone transfer function used by previews and post-processing.
public enum DisplayTransform {
    public static func mtfApply(_ x: Float, _ m: Float) -> Float {
        guard m > 0, m < 1 else { return x }
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        return ((m - 1) * x) / ((2 * m - 1) * x - m)
    }

}
