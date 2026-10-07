// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import SwiftUI
import UIKit
#if os(iOS) && !targetEnvironment(macCatalyst)
import BackgroundTasks
#endif

@MainActor
final class TransferBackgroundExecution {
    @MainActor
    final class Handle {
#if os(iOS) && !targetEnvironment(macCatalyst)
        fileprivate var continuedTask: AnyObject?
        fileprivate var legacyTaskID: UIBackgroundTaskIdentifier = .invalid
#endif
        private var finished = false
        private let previousIdleTimerState: Bool?

        fileprivate init() {
#if os(iOS) && !targetEnvironment(macCatalyst)
            previousIdleTimerState = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
#else
            previousIdleTimerState = nil
#endif
        }

        func update(completed: Int, total: Int) {
#if os(iOS) && !targetEnvironment(macCatalyst)
            if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
                task.progress.totalUnitCount = Int64(max(total, 1))
                task.progress.completedUnitCount = Int64(min(completed, total))
                task.updateTitle(
                    "Copying music to iPod",
                    subtitle: "Copied \(completed) of \(total) tracks"
                )
            }
#endif
        }

        func finish(success: Bool) {
            guard !finished else { return }
            finished = true
#if os(iOS) && !targetEnvironment(macCatalyst)
            if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
                task.setTaskCompleted(success: success)
                continuedTask = nil
            }
            if legacyTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(legacyTaskID)
                legacyTaskID = .invalid
            }
            if let previousIdleTimerState {
                UIApplication.shared.isIdleTimerDisabled = previousIdleTimerState
            }
#endif
        }

        fileprivate func expire(_ cancel: @escaping @MainActor () -> Void) {
            guard !finished else { return }
            AppLogger.sync("Background execution expired; cancelling sync for rollback", level: .error)
            cancel()
            finish(success: false)
        }
    }

    static let shared = TransferBackgroundExecution()

#if os(iOS) && !targetEnvironment(macCatalyst)
    @available(iOS 26.0, *)
    private struct PendingContinuedTask {
        let continuation: CheckedContinuation<BGContinuedProcessingTask?, Never>
        let cancel: @MainActor () -> Void
        let total: Int
    }

    // Type-erased because the concrete task type is unavailable before iOS 26.
    private var pendingContinuedTask: Any?
#endif

    private init() {}

    func register() {
#if os(iOS) && !targetEnvironment(macCatalyst)
        guard #available(iOS 26.0, *), let identifier = taskIdentifier else { return }
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            Task { @MainActor in
                guard let task = task as? BGContinuedProcessingTask,
                      let pending = TransferBackgroundExecution.shared.pendingContinuedTask as? PendingContinuedTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                TransferBackgroundExecution.shared.pendingContinuedTask = nil
                task.progress.totalUnitCount = Int64(max(pending.total, 1))
                task.expirationHandler = {
                    Task { @MainActor in pending.cancel() }
                }
                pending.continuation.resume(returning: task)
            }
        }
        AppLogger.app("Continuous background transfer registration=\(registered)", level: registered ? .info : .error)
#endif
    }

    func begin(total: Int, onExpiration: @escaping @MainActor () -> Void) async -> Handle {
        let handle = Handle()
#if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *), let task = await requestContinuedTask(total: total, onExpiration: onExpiration) {
            handle.continuedTask = task
            task.expirationHandler = { [weak handle] in
                Task { @MainActor in handle?.expire(onExpiration) }
            }
            AppLogger.sync("Using iOS continuous background processing for transfer", level: .info)
            return handle
        }

        handle.legacyTaskID = UIApplication.shared.beginBackgroundTask(withName: "Copy music to iPod") { [weak handle] in
            Task { @MainActor in handle?.expire(onExpiration) }
        }
        AppLogger.sync("Using limited UIKit background time for transfer", level: .info)
#endif
        return handle
    }

#if os(iOS) && !targetEnvironment(macCatalyst)
    @available(iOS 26.0, *)
    private var taskIdentifier: String? {
        Bundle.main.bundleIdentifier.map { "\($0).continued-processing.transfer" }
    }

    @available(iOS 26.0, *)
    private func requestContinuedTask(
        total: Int,
        onExpiration: @escaping @MainActor () -> Void
    ) async -> BGContinuedProcessingTask? {
        guard let identifier = taskIdentifier else { return nil }
        return await withCheckedContinuation { continuation in
            pendingContinuedTask = PendingContinuedTask(
                continuation: continuation,
                cancel: onExpiration,
                total: total
            )
            let request = BGContinuedProcessingTaskRequest(
                identifier: identifier,
                title: "Copying music to iPod",
                subtitle: "Preparing \(total) tracks"
            )
            request.strategy = .fail
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                pendingContinuedTask = nil
                AppLogger.sync("Continuous background processing unavailable: \(error.localizedDescription)", level: .error)
                continuation.resume(returning: nil)
            }
        }
    }
#endif
}

@main
struct PodBridgeApp: App {
    init() {
        TransferBackgroundExecution.shared.register()
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
