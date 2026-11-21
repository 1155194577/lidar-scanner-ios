import CoreImage
import CoreML
import Foundation
import Vision

/// Photo -> STL on the iPhone, with no network, using the quantized TripoSR Core ML models
/// from https://github.com/1155194577/3d-print/tree/main/edge (encoder: image -> triplanes,
/// decoder: triplanes + points -> density).
enum OnDeviceTripoSR {
    static let enabledKey = "onDevicePhotoPrint"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var isAvailable: Bool { isEnabled && OnDeviceModelStore.isInstalled }

    static let imageSize = 512
    static let foregroundRatio: CGFloat = 0.85
    static let radius: Float = 0.87
    static let densityThreshold: Float = 25
    static let decoderPoints = 65536
    static let resolution = 256

    enum Failure: LocalizedError {
        case modelsMissing, unreadablePhoto, noObject, noSurface

        var errorDescription: String? {
            switch self {
            case .modelsMissing: return "Download the on-device model in Settings first."
            case .unreadablePhoto: return "Couldn't read the photo."
            case .noObject: return "Couldn't find the object in the photo. Retake it against a plain background."
            case .noSurface: return "The model found no solid shape in the photo. Retake it closer to the object."
            }
        }
    }

    /// Builds the object in `photo` (upright JPEG) and writes it as an STL `heightMM` tall, Z up, base on z = 0.
    static func makeSTL(photo: Data, heightMM: Double, onProgress: @escaping @Sendable (PrintProgress) -> Void) async throws -> URL {
        guard let urls = OnDeviceModelStore.compiledURLs else { throw Failure.modelsMissing }
        onProgress(PrintProgress(stage: "background", message: "Cutting out the object", progress: nil))
        let image = try preprocess(photo)
        try Task.checkCancellation()

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        onProgress(PrintProgress(stage: "reconstruct", message: "Building the shape on this iPhone", progress: nil))
        let encoder = try await MLModel.load(contentsOf: urls.encoder, configuration: configuration)
        let input = try MLFeatureValue(cgImage: image, constraint: encoder.modelDescription.inputDescriptionsByName["image"]!.imageConstraint!)
        let encoded = try await encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": input]))
        guard let triplanes = encoded.featureValue(for: "triplanes")?.multiArrayValue else { throw Failure.noSurface }
        try Task.checkCancellation()

        let decoder = try await MLModel.load(contentsOf: urls.decoder, configuration: configuration)
        let density = try await densityGrid(decoder: decoder, triplanes: triplanes, onProgress: onProgress)
        onProgress(PrintProgress(stage: "mesh", message: "Making the mesh", progress: nil))
        let surface = MarchingCubes.extract(density, resolution: resolution, isovalue: densityThreshold, lower: -radius, upper: radius)
        guard !surface.indices.isEmpty else { throw Failure.noSurface }
        let stl = PrintableMesh.stl(PrintableMesh.fitted(surface, heightMM: Float(heightMM)))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("stl")
        try stl.write(to: url, options: .atomic)
        return url
    }

    /// Density at every vertex of a `resolution`^3 grid over [-radius, radius]^3, x-major, in decoder-sized chunks.
    private static func densityGrid(decoder: MLModel, triplanes: MLMultiArray,
                                    onProgress: @escaping @Sendable (PrintProgress) -> Void) async throws -> [Float] {
        let n = resolution, total = n * n * n
        let step = 2 * radius / Float(n - 1)
        var density = [Float](repeating: 0, count: total)
        let chunks = (total + decoderPoints - 1) / decoderPoints
        for chunk in 0..<chunks {
            try Task.checkCancellation()
            let start = chunk * decoderPoints
            let count = min(decoderPoints, total - start)
            let points = try MLMultiArray(shape: [NSNumber(value: decoderPoints), 3], dataType: .float32)
            points.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
                for i in 0..<decoderPoints {
                    let index = start + min(i, count - 1)
                    buffer[3 * i] = -radius + Float(index / (n * n)) * step
                    buffer[3 * i + 1] = -radius + Float(index / n % n) * step
                    buffer[3 * i + 2] = -radius + Float(index % n) * step
                }
            }
            let output = try await decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "triplanes": MLFeatureValue(multiArray: triplanes), "points": MLFeatureValue(multiArray: points),
            ]))
            guard let logits = output.featureValue(for: "density_logit")?.multiArrayValue else { throw Failure.noSurface }
            logits.withUnsafeBufferPointer(ofType: Float.self) { buffer in
                for i in 0..<count { density[start + i] = exp(buffer[i]) }
            }
            if chunk % 16 == 15 {
                onProgress(PrintProgress(stage: "reconstruct", message: "Building the shape on this iPhone",
                                         progress: Double(chunk + 1) / Double(chunks)))
            }
        }
        return density
    }

    /// The input TripoSR was trained on: the object cut out, centred at 85 % of a 512 x 512 frame, on 50 % grey.
    static func preprocess(_ photo: Data) throws -> CGImage {
        guard let oriented = CIImage(data: photo, options: [.applyOrientationProperty: true]) else { throw Failure.unreadablePhoto }
        let image = oriented.transformed(by: CGAffineTransform(translationX: -oriented.extent.minX, y: -oriented.extent.minY))
        let handler = VNImageRequestHandler(ciImage: image)
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { throw Failure.noObject }
        let maskBuffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        guard let box = foregroundBox(maskBuffer) else { throw Failure.noObject }

        let mask = CIImage(cvPixelBuffer: maskBuffer)
        let grey = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: .infinite)
        let cutout = image.applyingFilter("CIBlendWithRedMask", parameters: [
            kCIInputBackgroundImageKey: grey, kCIInputMaskImageKey: mask,
        ])
        let side = max(box.width, box.height) / foregroundRatio
        let frame = CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side)
        let scale = CGFloat(imageSize) / side
        let framed = cutout.composited(over: grey)
            .cropped(to: frame)
            .transformed(by: CGAffineTransform(translationX: -frame.minX, y: -frame.minY).concatenating(CGAffineTransform(scaleX: scale, y: scale)))
        // No colour management, so the grey stays exactly 0.5 as in training.
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        guard let output = context.createCGImage(framed, from: CGRect(x: 0, y: 0, width: imageSize, height: imageSize)) else {
            throw Failure.unreadablePhoto
        }
        return output
    }

    /// Bounding box of mask values above 0.5, in Core Image coordinates (origin bottom left).
    private static func foregroundBox(_ mask: CVPixelBuffer) -> CGRect? {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let width = CVPixelBufferGetWidth(mask), height = CVPixelBufferGetHeight(mask)
        let rowBytes = CVPixelBufferGetBytesPerRow(mask)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = (base + y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in 0..<width where row[x] > 0.5 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return nil }
        return CGRect(x: minX, y: height - 1 - maxY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}

/// Downloads the TripoSR Core ML models from the 3d-print GitHub release and compiles them on the phone.
@MainActor
final class OnDeviceModelStore: ObservableObject {
    enum State: Equatable { case missing, downloading(Double), installing, ready, failed(String) }

    static let shared = OnDeviceModelStore()
    static let releaseURL = URL(string: "https://github.com/1155194577/3d-print/releases/download/triposr-coreml-v1/")!
    static let quantization = "int8"
    static let models = ["TripoSREncoder", "TripoSRDecoder"]
    /// Release asset suffix -> path inside the .mlpackage.
    private static let parts = [("Manifest.json", "Manifest.json"),
                                ("model.mlmodel", "Data/com.apple.CoreML/model.mlmodel"),
                                ("weight.bin", "Data/com.apple.CoreML/weights/weight.bin")]
    static let downloadMB = 411

    @Published private(set) var state: State = OnDeviceModelStore.isInstalled ? .ready : .missing
    private var task: Task<Void, Never>?
    private var progress: [Int: (written: Int64, expected: Int64)] = [:]

    nonisolated static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TripoSR", isDirectory: true)
    }

    nonisolated static var compiledURLs: (encoder: URL, decoder: URL)? {
        let encoder = directory.appendingPathComponent("TripoSREncoder.mlmodelc")
        let decoder = directory.appendingPathComponent("TripoSRDecoder.mlmodelc")
        let fm = FileManager.default
        return fm.fileExists(atPath: encoder.path) && fm.fileExists(atPath: decoder.path) ? (encoder, decoder) : nil
    }

    nonisolated static var isInstalled: Bool { compiledURLs != nil }

    func download() {
        guard task == nil else { return }
        state = .downloading(0)
        progress = [:]
        task = Task {
            do {
                try await install()
                state = .ready
            } catch is CancellationError {
                state = Self.isInstalled ? .ready : .missing
            } catch {
                state = .failed(error.localizedDescription)
            }
            task = nil
        }
    }

    func cancel() { task?.cancel() }

    func delete() {
        task?.cancel()
        try? FileManager.default.removeItem(at: Self.directory)
        state = .missing
    }

    private func install() async throws {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let session = URLSession(configuration: .default)
        defer { session.invalidateAndCancel() }
        var downloads: [(asset: URL, target: URL)] = []
        for model in Self.models {
            for (suffix, path) in Self.parts {
                downloads.append((Self.releaseURL.appendingPathComponent("\(model)-\(Self.quantization)-\(suffix)"),
                                  staging.appendingPathComponent("\(model).mlpackage").appendingPathComponent(path)))
            }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, item) in downloads.enumerated() {
                group.addTask {
                    let request = URLRequest(url: item.asset)
                    let tracker = ProgressTracker { written, expected in
                        Task { @MainActor in self.record(index, written: written, expected: expected) }
                    }
                    let (file, response) = try await session.download(for: request, delegate: tracker)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                    try FileManager.default.createDirectory(at: item.target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: file, to: item.target)
                }
            }
            try await group.waitForAll()
        }
        state = .installing
        var directory = Self.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        for model in Self.models {
            try Task.checkCancellation()
            let compiled = try await MLModel.compileModel(at: staging.appendingPathComponent("\(model).mlpackage"))
            let target = directory.appendingPathComponent("\(model).mlmodelc")
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: compiled, to: target)
        }
    }

    private func record(_ index: Int, written: Int64, expected: Int64) {
        guard case .downloading = state else { return }
        progress[index] = (written, max(expected, written))
        let total = progress.values.reduce(0) { $0 + $1.written }
        let size = max(Int64(Self.downloadMB) << 20, progress.values.reduce(0) { $0 + $1.expected })
        state = .downloading(Double(total) / Double(size))
    }

    private final class ProgressTracker: NSObject, URLSessionDownloadDelegate, Sendable {
        let report: @Sendable (Int64, Int64) -> Void
        init(report: @escaping @Sendable (Int64, Int64) -> Void) { self.report = report }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            report(totalBytesWritten, totalBytesExpectedToWrite)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }
}
