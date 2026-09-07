import Foundation

/// Flag set by `applicationShouldTerminate` once the user has confirmed quit
/// (or there's nothing to confirm). The custom `windowShouldClose` delegate
/// uses this to distinguish "user clicked the red close button" (keep the
/// app alive, just hide the window) from "AppKit is closing windows because
/// we're shutting down" (let it actually close so the process can exit).
@MainActor
enum AppTerminationState {
    static var isTerminating = false
}
