import SwiftUI
import UIKit
import UserNotifications

struct PrintJob: Identifiable, Codable {
    let id: String
    let name: String
    let kind: String
    let baseURL: String
    var sourceScanFileName: String?
    var progress = PrintProgress.uploading
    var resultPath: String?
    var result: URL? {
        get { resultPath.map { PrintJobManager.directory.appendingPathComponent($0) } }
        set { resultPath = newValue.map { $0.path.replacingOccurrences(of: PrintJobManager.directory.path + "/", with: "") } }
    }
    var error: String?
    var accepted = false
    var retryFromStart = false
    var isFinished: Bool { result != nil || error != nil }
}

extension PrintJob {
    private enum CodingKeys: String, CodingKey {
        case id, name, kind, baseURL, sourceScanFileName, progress, resultPath, result, error, accepted, retryFromStart
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        kind = try values.decode(String.self, forKey: .kind)
        baseURL = try values.decode(String.self, forKey: .baseURL)
        sourceScanFileName = try values.decodeIfPresent(String.self, forKey: .sourceScanFileName) ?? (kind == "scan" ? name + ".usdz" : nil)
        progress = try values.decodeIfPresent(PrintProgress.self, forKey: .progress) ?? .uploading
        resultPath = try values.decodeIfPresent(String.self, forKey: .resultPath)
        if resultPath == nil, let legacy = try values.decodeIfPresent(URL.self, forKey: .result),
           let range = legacy.path.range(of: "/PrintJobs/", options: .backwards) {
            resultPath = String(legacy.path[range.upperBound...])
        }
        error = try values.decodeIfPresent(String.self, forKey: .error)
        accepted = try values.decodeIfPresent(Bool.self, forKey: .accepted) ?? false
        retryFromStart = try values.decodeIfPresent(Bool.self, forKey: .retryFromStart) ?? false
        if error == PrintError.serverChanged.localizedDescription { retryFromStart = false }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(kind, forKey: .kind)
        try values.encode(baseURL, forKey: .baseURL)
        try values.encodeIfPresent(sourceScanFileName, forKey: .sourceScanFileName)
        try values.encode(progress, forKey: .progress)
        try values.encodeIfPresent(resultPath, forKey: .resultPath)
        try values.encodeIfPresent(error, forKey: .error)
        try values.encode(accepted, forKey: .accepted)
        try values.encode(retryFromStart, forKey: .retryFromStart)
    }
}

@MainActor
final class PrintJobManager: ObservableObject {
    static let shared = PrintJobManager(notifications: !LaunchArguments.contains(LaunchArguments.resetScans))
    @Published private(set) var jobs: [PrintJob] = []
    private var inputs: [String: PrintInput] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var downloads = Set<String>()
    private var tokens: [String: String] = [:]
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var active = UIApplication.shared.applicationState == .active
    private let defaults: UserDefaults
    private let notifications: Bool
    private let makeService: ((PrintJob, String?) throws -> PrintService)?
    private let currentToken: () -> String?
    private let authorize: (() async -> Void)?
    private let notify: ((String, String, String) -> Void)?

    init(defaults: UserDefaults = .standard, notifications: Bool = true, makeService: ((PrintJob, String?) throws -> PrintService)? = nil, authorize: (() async -> Void)? = nil, notify: ((String, String, String) -> Void)? = nil, currentToken: @escaping () -> String? = { PrintService.configuredToken }) {
        self.defaults = defaults
        self.notifications = notifications
        self.makeService = makeService
        self.currentToken = currentToken
        self.authorize = authorize
        self.notify = notify
        if defaults == .standard, LaunchArguments.contains(LaunchArguments.resetScans) { defaults.removeObject(forKey: "printJobs") }
        if let data = defaults.data(forKey: "printJobs"), let saved = try? JSONDecoder().decode([PrintJob].self, from: data) {
            jobs = saved
        }
    }

    nonisolated static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PrintJobs", isDirectory: true)
    }

    func start(input: PrintInput, name: String, kind: String) {
        var job = PrintJob(id: UUID().uuidString, name: name, kind: kind, baseURL: PrintService.configuredBaseURL)
        if case .mesh(let url) = input { job.sourceScanFileName = url.lastPathComponent }
        jobs.append(job)
        inputs[job.id] = input
        tokens[job.id] = currentToken()
        persist()
        run(job, submit: true)
    }

    func canRetry(_ job: PrintJob) -> Bool {
        !(job.retryFromStart || job.baseURL != PrintService.configuredBaseURL) || inputs[job.id] != nil
    }

    func printedModel(for job: PrintJob) -> PrintedModel? {
        job.result.map { PrintedModel(url: $0, sourceScanFileName: job.sourceScanFileName) }
    }

    func retry(_ job: PrintJob) {
        guard canRetry(job) else { return }
        if job.retryFromStart || job.baseURL != PrintService.configuredBaseURL {
            guard let input = inputs[job.id] else {
                if let index = jobs.firstIndex(where: { $0.id == job.id }) {
                    jobs[index].error = "Original print input is no longer available; print again."
                    persist()
                }
                return
            }
            dismiss(job)
            start(input: input, name: job.name, kind: job.kind)
            return
        }
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        tokens[job.id] = currentToken()
        jobs[index].error = nil
        jobs[index].progress = PrintProgress(stage: "reconnecting", message: "Reconnecting to print server", progress: nil)
        persist()
        run(jobs[index], submit: inputs[job.id] != nil)
    }

    func dismiss(_ job: PrintJob) {
        tasks.removeValue(forKey: job.id)?.cancel()
        jobs.removeAll { $0.id == job.id }
        inputs.removeValue(forKey: job.id)
        tokens.removeValue(forKey: job.id)
        PrintBackgroundDownload.shared.cancel(id: job.id)
        downloads.remove(job.id)
        try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(job.id, isDirectory: true))
        removeTransferFile(job.id)
        persist()
    }

    func sceneChanged(_ phase: ScenePhase) {
        guard phase != .inactive else { return }
        active = phase == .active
        if phase == .background {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Print stream") { [weak self] in
                Task { @MainActor in self?.endBackgroundTask() }
            }
            for job in jobs where !job.isFinished && job.accepted { startDownload(job) }
        } else if phase == .active {
            endBackgroundTask()
            PrintBackgroundDownload.shared.connect { ids in
                Task { @MainActor in
                    self.downloads.formUnion(ids)
                    for job in self.jobs where !job.isFinished && self.tasks[job.id] == nil { self.run(job, submit: false) }
                }
            }
        }
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func service(_ job: PrintJob) throws -> PrintService {
        guard job.baseURL == PrintService.configuredBaseURL else { throw PrintError.serverChanged }
        let token = tokens[job.id] ?? currentToken()
        if let makeService { return try makeService(job, token) }
        return try PrintService(baseURL: job.baseURL, token: token)
    }

    private func run(_ job: PrintJob, submit: Bool) {
        guard tasks[job.id] == nil else { return }
        tasks[job.id] = Task {
            if submit {
                if let authorize { await authorize() }
                else if notifications { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
                if Task.isCancelled { return }
            }
            var lastError: Error = PrintError.server(status: 404, message: "Lost contact with the print server")
            for attempt in 0..<3 {
                do {
                    let service = try service(job)
                    let progress: @Sendable (PrintProgress) -> Void = { progress in
                        Task { @MainActor in self.update(job.id, progress: progress) }
                    }
                    let url: URL
                    if attempt == 0, submit, let input = inputs[job.id] {
                        url = try await service.requestSTL(for: input, name: job.id, in: Self.directory, jobID: job.id, onProgress: progress) { _ in
                            Task { @MainActor in
                                guard let index = self.jobs.firstIndex(where: { $0.id == job.id }) else { return }
                                self.jobs[index].accepted = true
                                self.persist()
                                if !self.active { self.startDownload(self.jobs[index]) }
                            }
                        }
                    } else {
                        url = try await service.reattach(id: job.id, name: job.id, in: Self.directory, onProgress: progress)
                    }
                    complete(id: job.id, result: .success(url))
                    tasks[job.id] = nil
                    return
                } catch {
                    if Task.isCancelled { return }
                    lastError = error
                    if case PrintError.serverChanged = error { break }
                    if case PrintError.invalidBaseURL = error { break }
                    if case PrintError.jobFailed = error { break }
                    if case PrintError.server(let status, _) = error, status != 404 && status != 200 { break }
                    if case PrintError.server(200, let detail) = error, !detail.contains("Lost contact") { break }
                    if case PrintError.server(404, _) = error { break }
                    if !active {
                        startDownload(job)
                        tasks[job.id] = nil
                        return
                    }
                    update(job.id, progress: PrintProgress(stage: "reconnecting", message: "Reconnecting to print server", progress: nil))
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            if case PrintError.server(404, _) = lastError {
                complete(id: job.id, result: .failure(PrintError.lostContact))
            } else { complete(id: job.id, result: .failure(lastError)) }
            tasks[job.id] = nil
        }
    }

    private func update(_ id: String, progress: PrintProgress) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), !jobs[index].isFinished else { return }
        jobs[index].progress = progress
        if !jobs[index].accepted, !["uploading", "waiting", "reconnecting"].contains(progress.stage) {
            jobs[index].accepted = true
            persist()
            if !active { startDownload(jobs[index]) }
        }
    }

    enum Transfer { case stream, download }

    private func removeTransferFile(_ id: String) {
        try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(id).appendingPathExtension("stl"))
    }

    func complete(id: String, result: Result<URL, Error>, source: Transfer = .stream) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), !jobs[index].isFinished else {
            if case .success = result { removeTransferFile(id) }
            return
        }
        if source == .download { downloads.remove(id) }
        if case .failure(let error) = result {
            if source == .stream { tasks[id] = nil }
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            var terminal = false
            if case PrintError.jobFailed = error { terminal = true }
            if case PrintError.server(422, _) = error { terminal = true }
            if case PrintError.serverChanged = error { terminal = true }
            if !terminal, tasks[id] != nil || downloads.contains(id) { return }
            if !terminal, source == .download, (error as NSError).domain == NSURLErrorDomain {
                update(id, progress: PrintProgress(stage: "reconnecting", message: "Waiting to reconnect to print server", progress: nil))
                if active, tasks[id] == nil { run(jobs[index], submit: false) }
                return
            }
        }
        switch result {
        case .success(let url):
            do {
                let folder = Self.directory.appendingPathComponent(id, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let fileName = jobs[index].name.replacingOccurrences(of: "/", with: "-")
                let target = folder.appendingPathComponent(fileName).appendingPathExtension("stl")
                try Data(contentsOf: url).write(to: target, options: .atomic)
                jobs[index].result = target
                removeTransferFile(id)
            } catch { jobs[index].error = error.localizedDescription }
        case .failure(let error):
            jobs[index].error = PrintService.failureMessage(error)
            if case PrintError.jobFailed = error { jobs[index].retryFromStart = true }
            if case PrintError.invalidBaseURL = error { jobs[index].retryFromStart = true }
            if case PrintError.server(422, _) = error { jobs[index].retryFromStart = true }
        }
        persist()
        tasks.removeValue(forKey: id)?.cancel()
        PrintBackgroundDownload.shared.cancel(id: id)
        downloads.remove(id)
        if jobs.allSatisfy(\.isFinished) { endBackgroundTask() }
        if !active, notifications || notify != nil {
            let content = UNMutableNotificationContent()
            content.title = jobs[index].error == nil ? "STL ready" : "Printing failed"
            content.body = jobs[index].error ?? "\(jobs[index].name) is ready to share."
            content.sound = .default
            if let notify { notify(id, content.title, content.body) }
            else { UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) }
        }
    }

    private func startDownload(_ job: PrintJob) {
        guard let request = try? service(job).jobRequest(id: job.id, route: .result) else { return }
        downloads.insert(job.id)
        PrintBackgroundDownload.shared.start(id: job.id, request: request)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(jobs) { defaults.set(data, forKey: "printJobs") }
    }
}

final class PrintBackgroundDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = PrintBackgroundDownload()
    static let identifier = "com.lidarscanner.print-results"
    var completionHandler: (() -> Void)?
    private let lock = NSLock()
    private var starting = Set<String>()
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.timeoutIntervalForRequest = 86400
        configuration.timeoutIntervalForResource = 86400
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    func connect(restored: @escaping @Sendable (Set<String>) -> Void = { _ in }) {
        session.getAllTasks { tasks in restored(Set(tasks.compactMap(\.taskDescription))) }
    }

    func start(id: String, request: URLRequest) {
        lock.lock()
        guard starting.insert(id).inserted else { lock.unlock(); return }
        lock.unlock()
        session.getAllTasks { tasks in
            defer {
                self.lock.lock()
                self.starting.remove(id)
                self.lock.unlock()
            }
            guard !tasks.contains(where: { $0.taskDescription == id }) else { return }
            let task = self.session.downloadTask(with: request)
            task.taskDescription = id
            task.resume()
        }
    }

    func cancel(id: String) {
        session.getAllTasks { tasks in tasks.filter { $0.taskDescription == id }.forEach { $0.cancel() } }
    }

    static func saveResponse(_ response: URLResponse?, file: URL, id: String) throws -> URL {
        guard let http = response as? HTTPURLResponse else { throw PrintError.unexpectedResponse("no HTTP response") }
        if http.statusCode == 404 { throw PrintError.server(status: 404, message: PrintError.lostContact.localizedDescription) }
        guard (200..<300).contains(http.statusCode) else {
            throw PrintError.server(status: http.statusCode, message: PrintService.errorMessage(from: try Data(contentsOf: file)))
        }
        guard ["model/stl", "application/octet-stream", "application/sla", "application/vnd.ms-pki.stl"].contains(http.mimeType ?? "") else {
            throw PrintError.unexpectedResponse(http.mimeType ?? "no content type")
        }
        let data = try Data(contentsOf: file)
        guard !data.isEmpty else { throw PrintError.unexpectedResponse("empty body") }
        let directory = PrintJobManager.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(id).appendingPathExtension("stl")
        try data.write(to: url, options: .atomic)
        return url
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        let result = Result { try Self.saveResponse(downloadTask.response, file: location, id: id) }
        Task { @MainActor in PrintJobManager.shared.complete(id: id, result: result, source: .download) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        Task { @MainActor in PrintJobManager.shared.complete(id: id, result: .failure(error), source: .download) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.completionHandler?()
            self.completionHandler = nil
        }
    }
}

final class PrintAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == PrintBackgroundDownload.identifier else { completionHandler(); return }
        PrintBackgroundDownload.shared.completionHandler = completionHandler
        PrintBackgroundDownload.shared.connect()
    }
}
