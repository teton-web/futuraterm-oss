import Foundation

/// Compile-time distribution channel. `APP_STORE` is set only on the AppStore
/// xcodegen configuration; Debug and Release stay false.
enum AppDistribution {
    static var isAppStore: Bool {
        #if APP_STORE
        true
        #else
        false
        #endif
    }
}
