import SwiftUI

@main
struct DioramHAApp: App {
    @State private var store = DioramHAApp.makeStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    switch phase {
                    case .active: store.start()
                    case .background: store.stop()
                    default: break
                    }
                }
        }
    }

    private static func makeStore() -> HomeStore {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        // First install from a Mac: the token arrives at launch and moves to the Keychain,
        // so it is never written into the source or the app bundle.
        if let url = env["HA_BOOTSTRAP_URL"], let token = env["HA_BOOTSTRAP_TOKEN"] {
            var settings = ConnectionSettings()
            settings.mode = .local
            settings.localURL = url
            settings.token = token
            try? KeychainStore.save(settings)
        }
        // Simulator testing only: credentials come from the environment and are not stored.
        if let url = env["HA_DEBUG_URL"], let token = env["HA_DEBUG_TOKEN"] {
            var settings = ConnectionSettings()
            settings.mode = .local
            settings.localURL = url
            settings.token = token
            return HomeStore(settings: settings, persist: false)
        }
        #endif
        return HomeStore()
    }
}
