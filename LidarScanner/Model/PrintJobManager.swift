import SwiftUI
import UIKit
import UserNotifications

struct PrintJob: Identifiable, Codable {
    let id: String
    let name: String
    let kind: String
    let baseURL: String
    var sourceScanFileName: String?
    var optimise = false
    var optimisation: PrintOptimisation?
    var modelCheck: PrintModelCheck?
    var progress = PrintProgress.uploading
    var resultPath: String?
    var result: URL? {
        get { resultPath.map { PrintJobManager.directory.appendingPathComponent($0) } }
        set { resultPath = newValue.map { $0.path.replacingOccurrences(of: PrintJobManager.directory.path + "/", with: "") } }
    }
    var error: String?
    var accepted = false
    var retryFromStart = false
    /// The server refused the submission (a 4xx other than 404/408/429), so it holds no job to re-attach to.
    var rejected = false
    /// Built on the phone by `OnDeviceTripoSR`; never sent to the print server.
    var onDevice = false
    var isFinished: Bool { result != nil || error != nil }
}

extension PrintJob {
    private enum CodingKeys: String, CodingKey {
        case id, name, kind, baseURL, sourceScanFileName, optimise, optimisation, modelCheck, progress, resultPath, result, error, accepted, retryFromStart, rejected, onDevice
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        kind = try values.decode(String.self, forKey: .kind)
        baseURL = try values.decode(String.self, forKey: .baseURL)
        sourceScanFileName = try values.decodeIfPresent(String.self, forKey: .sourceScanFileName) ?? (kind == "scan" ? name + ".usdz" : nil)
        optimise = try values.decodeIfPresent(Bool.self, forKey: .optimise) ?? false
        optimisation = try values.decodeIfPresent(PrintOptimisation.self, forKey: .optimisation)
        modelCheck = try values.decodeIfPresent(PrintModelCheck.self, forKey: .modelCheck)
        progress = try values.decodeIfPresent(PrintProgress.self, forKey: .progress) ?? .uploading
        resultPath = try values.decodeIfPresent(String.self, forKey: .resultPath)
        if resultPath == nil, let legacy = try values.decodeIfPresent(URL.self, forKey: .result),
           let range = legacy.path.range(of: "/PrintJobs/", options: .backwards) {
            resultPath = String(legacy.path[range.upperBound...])
        }
        error = try values.decodeIfPresent(String.self, forKey: .error)
        accepted = try values.decodeIfPresent(Bool.self, forKey: .accepted) ?? false
        retryFromStart = try values.decodeIfPresent(Bool.self, forKey: .retryFromStart) ?? false
        rejected = try values.decodeIfPresent(Bool.self, forKey: .rejected) ?? false
        onDevice = try values.decodeIfPresent(Bool.self, forKey: .onDevice) ?? false
        if error == PrintError.serverChanged.localizedDescription { retryFromStart = false }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(kind, forKey: .kind)
        try values.encode(baseURL, forKey: .baseURL)
        try values.encodeIfPresent(sourceScanFileName, forKey: .sourceScanFileName)
        try values.encode(optimise, forKey: .optimise)
        try values.encodeIfPresent(optimisation, forKey: .optimisation)
        try values.encodeIfPresent(modelCheck, forKey: .modelCheck)
        try values.encode(progress, forKey: .progress)
        try values.encodeIfPresent(resultPath, forKey: .resultPath)
        try values.encodeIfPresent(error, forKey: .error)
        try values.encode(accepted, forKey: .accepted)
        try values.encode(retryFromStart, forKey: .retryFromStart)
        try values.encode(rejected, forKey: .rejected)
        try values.encode(onDevice, forKey: .onDevice)
    }
}

@MainActor
final class PrintJobManager: ObservableObject {
    static let shared = PrintJobManager(notifications: !LaunchArguments.contains(LaunchArguments.resetScans))
    @Published private(set) var jobs: [PrintJob] = []
    @Published private(set) var uploadConfirmations: [String: [String: PrintService.UploadReference]] = [:]
    private var confirmedJobs = Set<String>()
    private var shownUploads = Set<String>()
    private var shownResults = Set<String>()
    private var inputs: [String: PrintInput] = [:]
    private var retakeContexts: [String: PhotoRetakeContext] = [:]
    private var onDeviceInputs: [String: (photo: Data, heightMM: Double)] = [:]
    private var payloads: [String: PrintPayload] = [:]
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
        if defaults == .standard, LaunchArguments.contains(LaunchArguments.resetScans) {
            for key in ["printJobs", "printUploadConfirmations", "printConfirmedJobs"] { defaults.removeObject(forKey: key) }
        }
        if let data = defaults.data(forKey: "printJobs"), let saved = try? JSONDecoder().decode([PrintJob].self, from: data) {
            jobs = saved.map { job in
                var job = job
                // An on-device build stops with the app, so it can't be resumed after a relaunch.
                if job.onDevice, !job.isFinished { job.error = "Stopped before it finished. Take the photo again." }
                return job
            }
        }
        if let data = defaults.data(forKey: "printUploadConfirmations"),
           let saved = try? JSONDecoder().decode([String: [String: PrintService.UploadReference]].self, from: data) {
            uploadConfirmations = saved.filter { id, _ in jobs.contains { $0.id == id } }
        }
        confirmedJobs = Set((defaults.stringArray(forKey: "printConfirmedJobs") ?? []).filter { id in jobs.contains { $0.id == id } })
    }

    nonisolated static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PrintJobs", isDirectory: true)
    }

    func start(input: PrintInput, name: String, kind: String, allowsOptimisation: Bool = false, retakeContext: PhotoRetakeContext? = nil) {
        var sourceScanFileName: String?
        if case .mesh(let url) = input { sourceScanFileName = url.lastPathComponent }
        let optimise = allowsOptimisation && defaults.bool(forKey: PrintService.optimiseKey)
        start(payload: try? PrintService.payload(for: input, optimise: optimise), input: input, name: name, kind: kind, sourceScanFileName: sourceScanFileName, optimise: optimise, retakeContext: retakeContext)
    }

    private func start(payload: PrintPayload?, input: PrintInput?, name: String, kind: String, sourceScanFileName: String?, optimise: Bool, retakeContext: PhotoRetakeContext? = nil) {
        var job = PrintJob(id: UUID().uuidString, name: name, kind: kind, baseURL: PrintService.configuredBaseURL)
        job.sourceScanFileName = sourceScanFileName
        job.optimise = optimise
        jobs.append(job)
        inputs[job.id] = input
        retakeContexts[job.id] = retakeContext
        if let payload {
            payloads[job.id] = payload
            try? payload.save(to: Self.payloadFolder(job.id))
        }
        tokens[job.id] = currentToken()
        persist()
        run(job, submit: true)
    }

    /// Builds a photo print on the phone with `OnDeviceTripoSR`, with no print server.
    func startOnDevice(photo: Data, heightMM: Double, name: String) {
        var job = PrintJob(id: UUID().uuidString, name: name, kind: "photo", baseURL: PrintService.configuredBaseURL)
        job.onDevice = true
        job.progress = PrintProgress(stage: "background", message: "Building on this iPhone", progress: nil)
        jobs.append(job)
        onDeviceInputs[job.id] = (photo, heightMM)
        persist()
        runOnDevice(job)
    }

    private func runOnDevice(_ job: PrintJob) {
        guard tasks[job.id] == nil, let input = onDeviceInputs[job.id] else { return }
        // Backgrounding is covered by the scene-phase background task, which `complete` ends.
        tasks[job.id] = Task {
            if let authorize { await authorize() }
            else if notifications { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
            do {
                let url = try await OnDeviceTripoSR.makeSTL(photo: input.photo, heightMM: input.heightMM) { progress in
                    Task { @MainActor in self.update(job.id, progress: progress) }
                }
                complete(id: job.id, result: .success(url))
                try? FileManager.default.removeItem(at: url)
            } catch {
                complete(id: job.id, result: .failure(error))
            }
            tasks[job.id] = nil
        }
    }

    private static func payloadFolder(_ id: String) -> URL {
        directory.appendingPathComponent(id, isDirectory: true).appendingPathComponent("payload", isDirectory: true)
    }

    /// What step 3 (or the multipart POST) sends for the job, read back from disk after a relaunch.
    private func payload(for id: String) -> PrintPayload? {
        if let payload = payloads[id] { return payload }
        guard let payload = try? PrintPayload.load(from: Self.payloadFolder(id)) else { return nil }
        payloads[id] = payload
        return payload
    }

    /// Sends prints that were never accepted, e.g. after iOS relaunched the app for signed uploads that finished.
    func resumeUnaccepted() {
        if !active, backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Print stream") { [weak self] in
                Task { @MainActor in self?.endBackgroundTask() }
            }
        }
        for job in jobs where !job.isFinished && !job.accepted && tasks[job.id] == nil && uploadConfirmations[job.id] == nil
            && !job.onDevice && payload(for: job.id) != nil {
            run(job, submit: true)
        }
    }

    func canRetry(_ job: PrintJob) -> Bool {
        if job.onDevice { return onDeviceInputs[job.id] != nil }
        let restartable = inputs[job.id] != nil || payload(for: job.id) != nil
        if job.rejected && !restartable { return false }
        return !(job.retryFromStart || job.baseURL != PrintService.configuredBaseURL) || restartable
    }

    func printedModel(for job: PrintJob) -> PrintedModel? {
        job.result.map {
            PrintedModel(url: $0, sourceScanFileName: job.sourceScanFileName, kind: job.kind == "face" ? .face : .photo,
                         optimisationRequested: job.optimise, optimisation: job.optimisation,
                         modelCheck: job.modelCheck, retakeContext: retakeContexts[job.id])
        }
    }

    var pendingPresentation: String? {
        jobs.first { job in
            (uploadConfirmations[job.id] != nil && !shownUploads.contains(job.id)) ||
            (job.result != nil && confirmedJobs.contains(job.id) && !shownResults.contains(job.id))
        }?.id
    }

    func markPresented(_ id: String) {
        if uploadConfirmations[id] != nil { shownUploads.insert(id) }
        else { shownResults.insert(id) }
    }

    func refreshUpload(_ job: PrintJob) async throws -> [String: PrintService.UploadReference] {
        let references = try await service(job).confirmedUploads(jobID: job.id)
        if uploadConfirmations[job.id] != nil {
            uploadConfirmations[job.id] = references
        }
        return references
    }

    func confirmPrint(_ job: PrintJob) {
        guard uploadConfirmations.removeValue(forKey: job.id) != nil,
              let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        confirmedJobs.insert(job.id)
        jobs[index].progress = PrintProgress(stage: "waiting", message: "Waiting for print server", progress: nil)
        persist()
        run(jobs[index], submit: true)
    }

    func retry(_ job: PrintJob) {
        guard canRetry(job) else { return }
        if job.onDevice {
            guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
            jobs[index].error = nil
            jobs[index].progress = PrintProgress(stage: "background", message: "Building on this iPhone", progress: nil)
            persist()
            runOnDevice(jobs[index])
            return
        }
        if job.retryFromStart || job.baseURL != PrintService.configuredBaseURL {
            let input = inputs[job.id]
            guard let payload = payload(for: job.id) ?? input.flatMap({ try? PrintService.payload(for: $0, optimise: job.optimise) }) else {
                if let index = jobs.firstIndex(where: { $0.id == job.id }) {
                    jobs[index].error = "Original print input is no longer available; print again."
                    persist()
                }
                return
            }
            let retakeContext = retakeContexts.removeValue(forKey: job.id)
            start(payload: payload, input: input, name: job.name, kind: job.kind, sourceScanFileName: job.sourceScanFileName, optimise: job.optimise, retakeContext: retakeContext)
            dismiss(job)
            return
        }
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        tokens[job.id] = currentToken()
        jobs[index].error = nil
        jobs[index].rejected = false
        jobs[index].progress = PrintProgress(stage: "reconnecting", message: "Reconnecting to print server", progress: nil)
        persist()
        run(jobs[index], submit: payload(for: job.id) != nil && !jobs[index].accepted)
    }

    func dismiss(_ job: PrintJob) {
        tasks.removeValue(forKey: job.id)?.cancel()
        jobs.removeAll { $0.id == job.id }
        inputs.removeValue(forKey: job.id)
        retakeContexts.removeValue(forKey: job.id)?.releaseSession()
        onDeviceInputs.removeValue(forKey: job.id)
        payloads.removeValue(forKey: job.id)
        PrintUploadState.discard(job.id)
        uploadConfirmations.removeValue(forKey: job.id)
        confirmedJobs.remove(job.id)
        shownUploads.remove(job.id)
        shownResults.remove(job.id)
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
            for job in jobs where !job.isFinished && job.accepted && !job.onDevice { startDownload(job) }
        } else if phase == .active {
            endBackgroundTask()
            PrintBackgroundDownload.shared.connect { ids in
                Task { @MainActor in
                    self.downloads.formUnion(ids)
                    for job in self.jobs where !job.isFinished && !job.onDevice && self.tasks[job.id] == nil && self.uploadConfirmations[job.id] == nil {
                        self.run(job, submit: !job.accepted && self.payload(for: job.id) != nil)
                    }
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
        return try PrintService(baseURL: job.baseURL, token: token, uploader: PrintBackgroundUpload.shared)
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
            var resend = submit
            var uploaded = false
            for _ in 0..<3 {
                do {
                    let service = try service(job)
                    let progress: @Sendable (PrintProgress) -> Void = { progress in
                        Task { @MainActor in self.update(job.id, progress: progress) }
                    }
                    let output: PrintOutput
                    let accepted = jobs.first(where: { $0.id == job.id })?.accepted ?? false
                    let payload = resend && !accepted ? payload(for: job.id) : nil
                    uploaded = payload != nil
                    if let payload {
                        let state = PrintUploadState.forJob(job.id, in: Self.directory)
                        if !confirmedJobs.contains(job.id),
                           let references = try await service.prepareUploads(for: payload, jobID: job.id, state: state, onProgress: progress) {
                            guard !Task.isCancelled else { return }
                            tasks[job.id] = nil
                            uploadConfirmations[job.id] = references
                            persist()
                            return
                        }
                        output = try await service.requestSTL(for: payload, name: job.id, in: Self.directory, jobID: job.id,
                                                              uploads: state, onProgress: progress) { _ in
                            Task { @MainActor in
                                guard let index = self.jobs.firstIndex(where: { $0.id == job.id }) else { return }
                                self.jobs[index].accepted = true
                                self.persist()
                                if !self.active { self.startDownload(self.jobs[index]) }
                            }
                        }
                    } else {
                        output = try await service.reattach(id: job.id, name: job.id, in: Self.directory, onProgress: progress)
                    }
                    complete(id: job.id, result: .success(output))
                    tasks[job.id] = nil
                    return
                } catch {
                    if Task.isCancelled { return }
                    lastError = error
                    // An upload the server never answered left no job to re-attach to.
                    resend = error is URLError && !(jobs.first(where: { $0.id == job.id })?.accepted ?? true)
                    if case PrintError.serverChanged = error { break }
                    if case PrintError.invalidBaseURL = error { break }
                    if case PrintError.jobFailed = error { break }
                    if case PrintError.server(let status, _) = error, status != 404 && status != 200 { break }
                    if case PrintError.server(200, let detail) = error, !detail.contains("Lost contact") { break }
                    if case PrintError.server(404, _) = error { break }
                    if !active {
                        // Not yet accepted: the server holds no result to download, so the print is resent once the app is back.
                        if jobs.first(where: { $0.id == job.id })?.accepted ?? true { startDownload(job) }
                        tasks[job.id] = nil
                        return
                    }
                    update(job.id, progress: PrintProgress(stage: "reconnecting", message: "Reconnecting to print server", progress: nil))
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            // The server refused the upload itself, so it holds no job to re-attach to.
            if uploaded, case PrintError.server(let status, _) = lastError, (400..<500).contains(status),
               ![404, 408, 429].contains(status), let index = jobs.firstIndex(where: { $0.id == job.id }),
               !jobs[index].accepted {
                jobs[index].rejected = true
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
        if !jobs[index].onDevice, !jobs[index].accepted, !["uploading", "waiting", "reconnecting"].contains(progress.stage) {
            jobs[index].accepted = true
            persist()
            if !active { startDownload(jobs[index]) }
        }
    }

    enum Transfer { case stream, download }

    private func removeTransferFile(_ id: String) {
        try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(id).appendingPathExtension("stl"))
    }

    func complete(id: String, result: Result<PrintOutput, Error>, source: Transfer = .stream) {
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
        case .success(let output):
            do {
                let folder = Self.directory.appendingPathComponent(id, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let fileName = jobs[index].name.replacingOccurrences(of: "/", with: "-")
                let target = folder.appendingPathComponent(fileName).appendingPathExtension("stl")
                try Data(contentsOf: output.url).write(to: target, options: .atomic)
                jobs[index].result = target
                jobs[index].optimisation = output.optimisation
                jobs[index].modelCheck = output.modelCheck
                if output.modelCheck?.retakeSide == nil {
                    retakeContexts.removeValue(forKey: id)?.releaseSession()
                }
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
        if let data = try? JSONEncoder().encode(uploadConfirmations) { defaults.set(data, forKey: "printUploadConfirmations") }
        defaults.set(Array(confirmedJobs), forKey: "printConfirmedJobs")
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

    static func saveResponse(_ response: URLResponse?, file: URL, id: String) throws -> PrintOutput {
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
        let report = PrintReport.report(in: http)
        return PrintOutput(url: url, optimisation: report?.optimise, modelCheck: report?.modelCheck)
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

/// PUTs print files to their signed URLs in a background session, so an upload keeps going while the app is suspended.
final class PrintBackgroundUpload: NSObject, URLSessionDataDelegate, PrintUploading, @unchecked Sendable {
    static let shared = PrintBackgroundUpload()
    static let identifier = "com.lidarscanner.print-uploads"
    var completionHandler: (() -> Void)?
    private let lock = NSLock()
    private var pending: [Int: (continuation: CheckedContinuation<(status: Int, body: Data), Error>, onProgress: @Sendable (Int64) -> Void, body: Data)] = [:]
    private var session: URLSession!

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.timeoutIntervalForResource = 3600
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    private final class TaskBox: @unchecked Sendable {
        let lock = NSLock()
        var task: URLSessionTask?
        var cancelled = false
    }

    func upload(_ request: URLRequest, fromFile file: URL, onProgress: @escaping @Sendable (Int64) -> Void) async throws -> (status: Int, body: Data) {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.uploadTask(with: request, fromFile: file)
                task.taskDescription = file.deletingLastPathComponent().lastPathComponent + "/" + file.lastPathComponent
                lock.withLock { pending[task.taskIdentifier] = (continuation, onProgress, Data()) }
                let cancelled = box.lock.withLock {
                    box.task = task
                    return box.cancelled
                }
                task.resume()
                if cancelled { task.cancel() }
            }
        } onCancel: {
            box.lock.withLock {
                box.cancelled = true
                return box.task
            }?.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        lock.withLock { pending[task.taskIdentifier]?.onProgress }?(totalBytesSent)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { pending[dataTask.taskIdentifier]?.body.append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let entry = lock.withLock({ pending.removeValue(forKey: task.taskIdentifier) }) else {
            // Started before iOS relaunched the app: record the file as uploaded so step 3 can follow.
            let parts = task.taskDescription?.split(separator: "/").map(String.init) ?? []
            if error == nil, parts.count == 2, let status = (task.response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) {
                PrintUploadState.forJob(parts[0], in: PrintJobManager.directory).markUploaded(parts[1])
            }
            return
        }
        if let error { entry.continuation.resume(throwing: error); return }
        entry.continuation.resume(returning: ((task.response as? HTTPURLResponse)?.statusCode ?? 0, entry.body))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            // Claims background time before iOS is told the events are handled and may suspend the app.
            MainActor.assumeIsolated { PrintJobManager.shared.resumeUnaccepted() }
            self.completionHandler?()
            self.completionHandler = nil
        }
    }
}

final class PrintAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        if identifier == PrintBackgroundUpload.identifier {
            PrintBackgroundUpload.shared.completionHandler = completionHandler
            return
        }
        guard identifier == PrintBackgroundDownload.identifier else { completionHandler(); return }
        PrintBackgroundDownload.shared.completionHandler = completionHandler
        PrintBackgroundDownload.shared.connect()
    }
}
