// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import SwiftUI

@main
struct PodBridgeApp: App {
    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        AppLogger.app("Application launched version=\(version) build=\(build)", level: .info)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
