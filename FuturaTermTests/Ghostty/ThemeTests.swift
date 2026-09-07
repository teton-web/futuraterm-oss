import AppKit
@testable import FuturaTerm
import Observation
import SwiftUI
import Testing

@MainActor
private final class ObservationFlag {
    var wasInvalidated = false
}

@MainActor
struct ThemeTests {
    /// Regression: the adaptive tint feeding `.preferredColorScheme` made the
    /// app-wide scheme flap whenever a full-screen TUI's background was
    /// adopted or cleared, which destabilized SwiftUI window management (the
    /// closed Settings window reopened on every app activation, and hotkeys
    /// broke because the WindowGroup window lost its cached identity).
    @Test
    func colorSchemeIgnoresTheTransientAdaptiveTint() {
        let configScheme = FuturaTermTheme.colorScheme
        let opposite: NSColor = configScheme == .dark ? .white : .black

        let previous = GhosttyApp.shared.adaptiveBackgroundColor
        GhosttyApp.shared.adoptAdaptiveBackgroundColor(opposite)
        defer { GhosttyApp.shared.adoptAdaptiveBackgroundColor(previous) }

        // The in-window chrome color follows the tint…
        #expect(FuturaTermTheme.nsBg.isVisuallyEqual(to: opposite))
        // …but the scene-level scheme must not.
        #expect(FuturaTermTheme.colorScheme == configScheme)
    }

    /// Regression: SwiftUI reaches the observable adaptive tint through the
    /// static `FuturaTermTheme.nsBg` accessor. Keep that dependency intact so a
    /// tint change invalidates in-window chrome without pretending the user's
    /// persisted Ghostty configuration changed.
    @Test
    func adaptiveTintInvalidatesThemeBackgroundObservation() {
        let previous = GhosttyApp.shared.adaptiveBackgroundColor
        let replacement = previous?.isVisuallyEqual(to: .black) == true ? NSColor.white : .black
        defer { GhosttyApp.shared.adoptAdaptiveBackgroundColor(previous) }

        let flag = ObservationFlag()
        withObservationTracking {
            _ = FuturaTermTheme.nsBg
        } onChange: {
            MainActor.assumeIsolated {
                flag.wasInvalidated = true
            }
        }

        GhosttyApp.shared.adoptAdaptiveBackgroundColor(replacement)

        #expect(flag.wasInvalidated)
    }
}
