//
//  JobCenter.swift
//  WorseFiles
//
//  Keeps one user-started operation alive after the app goes to the
//  background. iOS 26's BGContinuedProcessingTask shows a system progress
//  indicator and gives the process runtime until the job finishes or the
//  person stops it. Older systems simply run in the foreground as before.
//

import Foundation
import BackgroundTasks
import UIKit

@MainActor
final class JobCenter: ObservableObject {
    static let shared = JobCenter()
    static let taskIdentifier = "com.kestrel.worsefiles.continued"

    private enum State {
        case idle
        case submitted
        case attached
        case finished
    }

    private var state: State = .idle
    private var token: CancelToken?
    private var bgTask: AnyObject?
    private var title = ""
    private var subtitle = ""
    private var total: Int64 = 0
    private var completed: Int64 = 0
    private var finishSuccess = false
    private var timeoutTask: Task<Void, Never>?
    private var registered = false

    private init() {}

    func register() {
        guard !registered else { return }
        registered = true
        guard #available(iOS 26.0, *) else { return }
        let accepted = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                JobCenter.shared.attach(task)
            }
        }
        Log.info("bg continued register: \(accepted ? "yes" : "no")")
    }

    @discardableResult
    func begin(title: String, subtitle: String, token: CancelToken, total: Int64 = 0) -> Bool {
        guard state == .idle else {
            Log.info("bg job skipped: \(title); another job is active")
            return false
        }
        self.title = title
        self.subtitle = subtitle
        self.token = token
        self.total = max(0, total)
        self.completed = 0
        state = .submitted

        guard #available(iOS 26.0, *) else {
            reset()
            return false
        }

        let request = BGContinuedProcessingTaskRequest(identifier: Self.taskIdentifier,
                                                       title: title,
                                                       subtitle: subtitle)
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
            Log.info("bg job submitted: \(title)")
            return true
        } catch {
            Log.info("bg job submit failed: \(title): \(error.localizedDescription)")
            reset()
            return false
        }
    }

    func update(phase: String, completed: Int64, total: Int64, detail: String? = nil) {
        guard state != .idle else { return }
        self.completed = max(0, completed)
        self.total = max(0, total)
        if let detail, !detail.isEmpty {
            subtitle = "\(phase) · \(detail)"
        } else if total > 0 {
            subtitle = "\(phase) \(min(completed, total))/\(total)"
        } else {
            subtitle = phase
        }
        guard #available(iOS 26.0, *),
              let task = bgTask as? BGContinuedProcessingTask else { return }
        apply(to: task)
    }

    func finish(success: Bool) {
        guard state != .idle else {
            token = nil
            return
        }
        finishSuccess = success
        state = .finished
        token = nil

        if #available(iOS 26.0, *),
           let task = bgTask as? BGContinuedProcessingTask {
            task.setTaskCompleted(success: success)
            reset()
            return
        }

        // The handler may not have attached yet. Give it a short window,
        // then release the slot so a later job can submit.
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.reset()
            }
        }
    }

    var isActive: Bool { state != .idle }

    var diagnostic: String {
        if #available(iOS 26.0, *) {
            return registered ? (isActive ? "已注册，任务进行中" : "已注册") : "未注册"
        }
        return "iOS < 26，仅前台运行"
    }

    @available(iOS 26.0, *)
    private func attach(_ task: BGContinuedProcessingTask) {
        guard state == .submitted || state == .finished else {
            task.setTaskCompleted(success: false)
            return
        }
        bgTask = task
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.token?.cancel()
                self.finish(success: false)
            }
        }
        apply(to: task)

        if state == .finished {
            task.setTaskCompleted(success: finishSuccess)
            reset()
        } else {
            state = .attached
        }
    }

    @available(iOS 26.0, *)
    private func apply(to task: BGContinuedProcessingTask) {
        if total > 0 {
            task.progress.totalUnitCount = total
            task.progress.completedUnitCount = min(total, max(0, completed))
        } else {
            // Unknown total (backup/export): leave the system indicator
            // indeterminate instead of showing 100% at the first byte.
            task.progress.totalUnitCount = 0
            task.progress.completedUnitCount = 0
        }
        task.updateTitle(title, subtitle: subtitle)
    }

    private func reset() {
        timeoutTask?.cancel()
        timeoutTask = nil
        bgTask = nil
        token = nil
        title = ""
        subtitle = ""
        total = 0
        completed = 0
        finishSuccess = false
        state = .idle
    }
}
