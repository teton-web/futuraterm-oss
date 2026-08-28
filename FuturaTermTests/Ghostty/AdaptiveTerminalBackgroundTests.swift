import AppKit
import CoreVideo
@testable import FuturaTerm
@preconcurrency import IOSurface
import Testing

@MainActor
struct AdaptiveTerminalBackgroundTests {
    private func pixel(_ red: UInt8, _ green: UInt8, _ blue: UInt8, _ alpha: UInt8 = 255)
        -> AdaptiveTerminalBackgroundDetector.Pixel
    {
        .init(red: red, green: green, blue: blue, alpha: alpha)
    }

    @Test
    func dominantOpaqueColorWinsWhenItCoversMostOfFrame() throws {
        let background = Array(repeating: pixel(18, 20, 24), count: 70)
        let transparent = Array(repeating: pixel(220, 220, 220, 0), count: 30)

        let match = try #require(AdaptiveTerminalBackgroundDetector.dominantColor(in: background + transparent))

        #expect(match.red == 18)
        #expect(match.green == 20)
        #expect(match.blue == 24)
        #expect(match.coverage == 0.7)
    }

    @Test
    func sparseOpaqueTextCannotTriggerMatching() {
        let text = Array(repeating: pixel(230, 230, 240), count: 25)
        let transparent = Array(repeating: pixel(0, 0, 0, 0), count: 75)

        #expect(AdaptiveTerminalBackgroundDetector.dominantColor(in: text + transparent) == nil)
    }

    @Test
    func variedOpaqueFrameDoesNotProduceFalseDominantColor() {
        let first = Array(repeating: pixel(20, 20, 20), count: 50)
        let second = Array(repeating: pixel(80, 40, 120), count: 50)

        #expect(AdaptiveTerminalBackgroundDetector.dominantColor(in: first + second) == nil)
    }

    @Test
    func nearbyRendererValuesShareAQuantizedBucketAndReturnASampledColor() throws {
        let first = Array(repeating: pixel(17, 18, 19), count: 35)
        let second = Array(repeating: pixel(20, 21, 22), count: 35)
        let transparent = Array(repeating: pixel(0, 0, 0, 0), count: 30)

        let match = try #require(
            AdaptiveTerminalBackgroundDetector.dominantColor(in: first + second + transparent)
        )
        #expect(match.red == 17)
        #expect(match.green == 18)
        #expect(match.blue == 19)
        #expect(match.coverage == 0.7)
    }

    @Test
    func exactModeRepresentsAQuantizedBucket() throws {
        let lessFrequent = Array(repeating: pixel(17, 18, 19), count: 25)
        let mode = Array(repeating: pixel(20, 21, 22), count: 45)
        let transparent = Array(repeating: pixel(0, 0, 0, 0), count: 30)

        let match = try #require(
            AdaptiveTerminalBackgroundDetector.dominantColor(in: lessFrequent + mode + transparent)
        )
        #expect(match.red == 20)
        #expect(match.green == 21)
        #expect(match.blue == 22)
        #expect(match.coverage == 0.7)
    }

    @Test
    func samplingBurstStopsAfterItsRequestedRetries() {
        var burst = AdaptiveTerminalSamplingBurst()

        burst.request(retries: 2)
        let firstRetry = burst.consumeRetry()
        let secondRetry = burst.consumeRetry()
        let exhausted = burst.consumeRetry()

        #expect(firstRetry)
        #expect(secondRetry)
        #expect(!exhausted)
    }

    @Test
    func samplingBurstExtendsWithoutAccumulatingForever() {
        var burst = AdaptiveTerminalSamplingBurst()
        burst.request(retries: 3)
        let firstRetry = burst.consumeRetry()

        burst.request(retries: 2)

        #expect(firstRetry)
        #expect(burst.retriesRemaining == 2)
        burst.cancel()
        let retryAfterCancellation = burst.consumeRetry()
        #expect(!retryAfterCancellation)
    }

    @Test
    func samplesGhosttyBGRAIOSurface() throws {
        let properties = [
            kIOSurfaceWidth: NSNumber(value: 40),
            kIOSurfaceHeight: NSNumber(value: 30),
            kIOSurfaceBytesPerElement: NSNumber(value: 4),
            kIOSurfacePixelFormat: NSNumber(value: kCVPixelFormatType_32BGRA),
        ] as CFDictionary
        guard let surface = IOSurfaceCreate(properties) else {
            Issue.record("Could not create the test IOSurface")
            return
        }
        var seed: UInt32 = 0
        #expect(IOSurfaceLock(surface, [], &seed) == kIOReturnSuccess)
        let base = IOSurfaceGetBaseAddress(surface)
        let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        for y in 0 ..< IOSurfaceGetHeight(surface) {
            for x in 0 ..< IOSurfaceGetWidth(surface) {
                let offset = y * bytesPerRow + x * 4
                base.storeBytes(of: UInt8(31), toByteOffset: offset, as: UInt8.self)
                base.storeBytes(of: UInt8(21), toByteOffset: offset + 1, as: UInt8.self)
                base.storeBytes(of: UInt8(11), toByteOffset: offset + 2, as: UInt8.self)
                base.storeBytes(of: UInt8(255), toByteOffset: offset + 3, as: UInt8.self)
            }
        }
        #expect(IOSurfaceUnlock(surface, [], &seed) == kIOReturnSuccess)

        let match = try #require(AdaptiveTerminalBackgroundDetector.dominantColor(in: surface))
        #expect(match.red == 11)
        #expect(match.green == 21)
        #expect(match.blue == 31)
        #expect(match.coverage == 1)
    }

    @Test
    func rejectsIOSurfaceWithUnexpectedPixelFormat() throws {
        let properties = [
            kIOSurfaceWidth: NSNumber(value: 40),
            kIOSurfaceHeight: NSNumber(value: 30),
            kIOSurfaceBytesPerElement: NSNumber(value: 4),
            kIOSurfacePixelFormat: NSNumber(value: kCVPixelFormatType_32RGBA),
        ] as CFDictionary
        let surface = try #require(IOSurfaceCreate(properties))

        #expect(AdaptiveTerminalBackgroundDetector.dominantColor(in: surface) == nil)
    }

    @Test
    func configuredBackgroundIsSuppressedAsAnAdaptiveCandidate() throws {
        let configured = NSColor(srgbRed: 0.10, green: 0.20, blue: 0.30, alpha: 1)
        let near = NSColor(srgbRed: 0.11, green: 0.20, blue: 0.30, alpha: 1)
        let distinct = NSColor(srgbRed: 0.55, green: 0.20, blue: 0.30, alpha: 1)

        #expect(AdaptiveTerminalChrome.effectiveCandidate(nil, configuredBackground: configured) == nil)
        #expect(AdaptiveTerminalChrome.effectiveCandidate(near, configuredBackground: configured) == nil)
        let candidate = try #require(
            AdaptiveTerminalChrome.effectiveCandidate(distinct, configuredBackground: configured)
        )
        #expect(candidate.isVisuallyEqual(to: distinct))
    }

    @Test
    func stabilizerRequiresTwoMatchingObservationsToApplyAndClear() {
        var stabilizer = AdaptiveTerminalBackgroundStabilizer()
        let color = NSColor(srgbRed: 0.12, green: 0.18, blue: 0.24, alpha: 1)

        #expect(stabilizer.observe(color) == nil)
        #expect(stabilizer.hasPendingObservation)
        #expect(stabilizer.observe(color) == .applyColor)
        #expect(!stabilizer.hasPendingObservation)

        #expect(stabilizer.observe(nil) == nil)
        #expect(stabilizer.hasPendingObservation)
        #expect(stabilizer.observe(nil) == .clear)
        #expect(!stabilizer.hasPendingObservation)
    }

    @Test
    func stabilizerRejectsAnInterruptedCandidate() {
        var stabilizer = AdaptiveTerminalBackgroundStabilizer()
        let first = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 1)
        let second = NSColor(srgbRed: 0.7, green: 0.2, blue: 0.1, alpha: 1)

        #expect(stabilizer.observe(first) == nil)
        #expect(stabilizer.observe(second) == nil)
        #expect(stabilizer.observe(first) == nil)
        #expect(stabilizer.observe(first) == .applyColor)
    }

    @Test
    func stabilizerTreatsTinyRendererVarianceAsTheSameColor() {
        var stabilizer = AdaptiveTerminalBackgroundStabilizer()
        let first = NSColor(srgbRed: 0.200, green: 0.300, blue: 0.400, alpha: 1)
        let second = NSColor(srgbRed: 0.202, green: 0.302, blue: 0.402, alpha: 1)

        #expect(stabilizer.observe(first) == nil)
        #expect(stabilizer.observe(second) == .applyColor)
    }

    @Test
    func stabilizerResetAdoptsKnownStateWithoutAChange() {
        var stabilizer = AdaptiveTerminalBackgroundStabilizer()
        let color = NSColor(srgbRed: 0.3, green: 0.4, blue: 0.5, alpha: 1)

        stabilizer.reset(to: color)

        #expect(stabilizer.observe(color) == nil)
        #expect(!stabilizer.hasPendingObservation)
    }

    @Test
    func stabilizerSeededWithRememberedColorTreatsItAsCurrent() {
        let remembered = NSColor(srgbRed: 0.08, green: 0.09, blue: 0.12, alpha: 1)
        var stabilizer = AdaptiveTerminalBackgroundStabilizer(seededWith: remembered)

        // Re-observing the remembered color is a no-op (no re-detection flash)…
        #expect(stabilizer.observe(remembered) == nil)
        #expect(!stabilizer.hasPendingObservation)

        // …while a TUI that exited off-screen still clears via two observations.
        #expect(stabilizer.observe(nil) == nil)
        #expect(stabilizer.observe(nil) == .clear)
    }
}
