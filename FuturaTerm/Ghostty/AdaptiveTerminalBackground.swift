import AppKit
import CoreVideo
import IOSurface

/// Detects a flat, opaque background painted across most of a terminal frame.
/// Transparent theme pixels remain part of the denominator, so ordinary shell
/// content cannot win merely because its handful of glyph pixels are opaque.
enum AdaptiveTerminalBackgroundDetector {
    struct Pixel: Equatable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8
    }

    struct Match: Equatable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let coverage: Double

        var color: NSColor {
            NSColor(
                srgbRed: CGFloat(red) / 255,
                green: CGFloat(green) / 255,
                blue: CGFloat(blue) / 255,
                alpha: 1
            )
        }
    }

    private struct SampledColor: Hashable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8

        init(_ pixel: Pixel) {
            red = pixel.red
            green = pixel.green
            blue = pixel.blue
        }

        var packedValue: UInt32 {
            UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue)
        }
    }

    private struct Bucket {
        var count = 0
        var red = 0
        var green = 0
        var blue = 0
        var frequencies: [SampledColor: Int] = [:]

        mutating func add(_ pixel: Pixel) {
            count += 1
            red += Int(pixel.red)
            green += Int(pixel.green)
            blue += Int(pixel.blue)
            frequencies[SampledColor(pixel), default: 0] += 1
        }

        /// Prefer the exact mode. When renderer variance makes several colors
        /// equally frequent, choose the sampled color nearest the bucket mean.
        var representativeColor: SampledColor? {
            guard !frequencies.isEmpty else { return nil }
            let meanRed = Double(red) / Double(count)
            let meanGreen = Double(green) / Double(count)
            let meanBlue = Double(blue) / Double(count)

            func squaredDistance(_ color: SampledColor) -> Double {
                let redDelta = Double(color.red) - meanRed
                let greenDelta = Double(color.green) - meanGreen
                let blueDelta = Double(color.blue) - meanBlue
                return redDelta * redDelta + greenDelta * greenDelta + blueDelta * blueDelta
            }

            return frequencies.keys.min { lhs, rhs in
                let lhsFrequency = frequencies[lhs, default: 0]
                let rhsFrequency = frequencies[rhs, default: 0]
                if lhsFrequency != rhsFrequency { return lhsFrequency > rhsFrequency }

                let lhsDistance = squaredDistance(lhs)
                let rhsDistance = squaredDistance(rhs)
                if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
                return lhs.packedValue < rhs.packedValue
            }
        }
    }

    static func dominantColor(
        in pixels: [Pixel],
        minimumCoverage: Double = 0.60,
        minimumAlpha: UInt8 = 230
    ) -> Match? {
        guard !pixels.isEmpty else { return nil }

        var buckets: [Int: Bucket] = [:]
        for pixel in pixels where pixel.alpha >= minimumAlpha {
            // Four bits per component absorb tiny renderer/color-space
            // differences without merging visibly distinct backgrounds.
            let key = Int(pixel.red >> 4) << 8 | Int(pixel.green >> 4) << 4 | Int(pixel.blue >> 4)
            var bucket = buckets[key, default: Bucket()]
            bucket.add(pixel)
            buckets[key] = bucket
        }

        guard let winner = buckets.values.max(by: { $0.count < $1.count }) else { return nil }
        let coverage = Double(winner.count) / Double(pixels.count)
        guard coverage >= minimumCoverage, let representative = winner.representativeColor else { return nil }

        return Match(
            red: representative.red,
            green: representative.green,
            blue: representative.blue,
            coverage: coverage
        )
    }

    /// Sample a bounded grid rather than scanning every backing pixel. The
    /// current renderer uses BGRA8; fail closed if that private implementation
    /// detail changes instead of interpreting an unfamiliar layout.
    static func dominantColor(in surface: IOSurface) -> Match? {
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        let bytesPerElement = IOSurfaceGetBytesPerElement(surface)
        guard IOSurfaceGetPixelFormat(surface) == kCVPixelFormatType_32BGRA,
              width > 0,
              height > 0,
              bytesPerElement == 4
        else { return nil }

        let (minimumBytesPerRow, rowOverflow) = width.multipliedReportingOverflow(by: bytesPerElement)
        let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        let (minimumAllocation, allocationOverflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !rowOverflow,
              !allocationOverflow,
              bytesPerRow >= minimumBytesPerRow,
              IOSurfaceGetAllocSize(surface) >= minimumAllocation
        else { return nil }

        var seed: UInt32 = 0
        guard IOSurfaceLock(surface, [.readOnly], &seed) == kIOReturnSuccess else { return nil }
        defer { IOSurfaceUnlock(surface, [.readOnly], &seed) }

        let base = IOSurfaceGetBaseAddress(surface)
        let xStep = max(1, width / 80)
        let yStep = max(1, height / 50)
        let xInset = min(width / 20, xStep * 2)
        let yInset = min(height / 20, yStep * 2)
        guard width > xInset * 2, height > yInset * 2 else { return nil }

        var pixels: [Pixel] = []
        pixels.reserveCapacity(4000)
        for y in stride(from: yInset + yStep / 2, to: height - yInset, by: yStep) {
            for x in stride(from: xInset + xStep / 2, to: width - xInset, by: xStep) {
                let offset = y * bytesPerRow + x * bytesPerElement
                let blue = base.load(fromByteOffset: offset, as: UInt8.self)
                let green = base.load(fromByteOffset: offset + 1, as: UInt8.self)
                let red = base.load(fromByteOffset: offset + 2, as: UInt8.self)
                let alpha = base.load(fromByteOffset: offset + 3, as: UInt8.self)
                pixels.append(Pixel(red: red, green: green, blue: blue, alpha: alpha))
            }
        }
        return dominantColor(in: pixels)
    }
}

/// Rejects single-frame color changes in either direction. Entering a TUI,
/// leaving it, and changing between two full-screen colors all require two
/// matching observations, preventing chrome flashes during redraws.
struct AdaptiveTerminalBackgroundStabilizer {
    enum Change: Equatable {
        case applyColor
        case clear
    }

    private enum Token: Equatable {
        case clear
        case color(red: UInt8, green: UInt8, blue: UInt8)

        init(_ color: NSColor?) {
            guard let rgb = color?.usingColorSpace(.sRGB) else {
                self = .clear
                return
            }
            func quantize(_ component: CGFloat) -> UInt8 {
                UInt8((max(0, min(1, component)) * 31).rounded())
            }
            self = .color(
                red: quantize(rgb.redComponent),
                green: quantize(rgb.greenComponent),
                blue: quantize(rgb.blueComponent)
            )
        }
    }

    private var current: Token = .clear
    private var pending: Token?

    init() {}

    /// Start from a previously confirmed color (e.g. remembered across a
    /// pane's occlusion) so re-observing it is a no-op rather than a change.
    init(seededWith color: NSColor?) {
        current = Token(color)
    }

    var hasPendingObservation: Bool { pending != nil }

    mutating func reset(to color: NSColor?) {
        current = Token(color)
        pending = nil
    }

    mutating func observe(_ color: NSColor?) -> Change? {
        let observed = Token(color)
        guard observed != current else {
            pending = nil
            return nil
        }
        guard pending == observed else {
            pending = observed
            return nil
        }

        current = observed
        pending = nil
        return color == nil ? .clear : .applyColor
    }
}
