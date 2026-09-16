import AVFoundation
import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum ShowcaseCategory: String, CaseIterable, Identifiable {
    case longPutt = "long_putt"
    case multiBreak = "multi_break"
    case recovery = "recovery"
    case firstHoled = "first_holed"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .longPutt: return L10n.showcaseCategoryLongPutt
        case .multiBreak: return L10n.showcaseCategoryMultiBreak
        case .recovery: return L10n.showcaseCategoryRecovery
        case .firstHoled: return L10n.showcaseCategoryFirstHoled
        }
    }
}

@MainActor
final class ShowcaseUploadModel: ObservableObject {
    @Published var pickerItems: [PhotosPickerItem] = []
    @Published var localVideoURL: URL?
    @Published var category: ShowcaseCategory = .longPutt
    @Published var nickname = ""
    @Published var caption: String {
        didSet { ShowcaseMetaPersistence.saveCaption(caption) }
    }
    @Published var clubName: String {
        didSet { ShowcaseMetaPersistence.saveClub(clubName) }
    }
    @Published var courseName: String {
        didSet { ShowcaseMetaPersistence.saveCourse(courseName) }
    }
    @Published var holeNumber = 1
    @Published var isPreparing = false
    @Published var isUploading = false
    @Published var prepareProgress: Double = 0
    @Published var uploadProgress: Double = 0
    @Published var statusMessage: String?
    @Published var didSucceed = false

    init() {
        caption = ShowcaseMetaPersistence.loadCaption()
        clubName = ShowcaseMetaPersistence.loadClub()
        courseName = ShowcaseMetaPersistence.loadCourse()
    }

    var canSubmit: Bool {
        localVideoURL != nil
            && !nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !clubName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !courseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (1...18).contains(holeNumber)
            && !isPreparing
            && !isUploading
    }

    var canUploadQuick: Bool {
        localVideoURL != nil && !isPreparing && !isUploading
    }

    func loadPickedVideo() async {
        guard let pickerItem = pickerItems.first else { return }
        statusMessage = nil
        didSucceed = false
        localVideoURL = nil
        prepareProgress = 0
        uploadProgress = 0
        isPreparing = true
        defer {
            isPreparing = false
            if localVideoURL == nil { prepareProgress = 0 }
        }
        do {
            guard let raw = try await pickerItem.loadTransferable(type: VideoFileTransferable.self) else {
                statusMessage = L10n.showcaseUploadPickFailed
                return
            }
            try await compressAndSet(sourceURL: raw.url)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func loadVideo(from sourceURL: URL) async {
        statusMessage = nil
        didSucceed = false
        localVideoURL = nil
        prepareProgress = 0
        uploadProgress = 0
        isPreparing = true
        defer {
            isPreparing = false
            if localVideoURL == nil { prepareProgress = 0 }
        }
        do {
            try await compressAndSet(sourceURL: sourceURL)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func compressAndSet(sourceURL: URL) async throws {
        let compressed = try await ShowcaseVideoEncoder.exportForUpload(sourceURL: sourceURL) { [weak self] p in
            Task { @MainActor in
                self?.prepareProgress = p
                self?.statusMessage = L10n.showcaseUploadCompressingPct(Int((p * 100).rounded()))
            }
        }
        localVideoURL = compressed
        prepareProgress = 1
        let bytes = (try? FileManager.default.attributesOfItem(atPath: compressed.path)[.size] as? NSNumber)?.intValue ?? 0
        let mb = Double(bytes) / (1024 * 1024)
        statusMessage = L10n.showcaseUploadReadyMB(mb)
    }

    func upload(accessToken: String, userID: String) async {
        guard let localVideoURL else { return }
        didSucceed = false
        isUploading = true
        uploadProgress = 0
        statusMessage = L10n.showcaseUploadUploadingPct(0)
        defer { isUploading = false }
        do {
            let result = try await ShowcaseSupabaseUploader.upload(
                fileURL: localVideoURL,
                userID: userID,
                accessToken: accessToken,
                category: category.rawValue,
                nickname: nickname.trimmingCharacters(in: .whitespacesAndNewlines),
                caption: caption.trimmingCharacters(in: .whitespacesAndNewlines),
                clubName: clubName.trimmingCharacters(in: .whitespacesAndNewlines),
                courseName: courseName.trimmingCharacters(in: .whitespacesAndNewlines),
                holeNumber: holeNumber,
                onProgress: { [weak self] p in
                    Task { @MainActor in
                        self?.uploadProgress = p
                        self?.statusMessage = L10n.showcaseUploadUploadingPct(Int((p * 100).rounded()))
                    }
                }
            )
            uploadProgress = 1
            didSucceed = true
            statusMessage = L10n.showcaseUploadSuccess
            _ = result
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func clearSelection() {
        pickerItems = []
        localVideoURL = nil
        prepareProgress = 0
        uploadProgress = 0
    }
}

/// Survives across upload sheet opens (club/course rarely change on the same round).
enum ShowcaseMetaPersistence {
    private static let captionKey = "putthink.showcase.meta.caption"
    private static let clubKey = "putthink.showcase.meta.club"
    private static let courseKey = "putthink.showcase.meta.course"

    static func loadCaption() -> String {
        UserDefaults.standard.string(forKey: captionKey) ?? ""
    }

    static func loadClub() -> String {
        UserDefaults.standard.string(forKey: clubKey) ?? ""
    }

    static func loadCourse() -> String {
        UserDefaults.standard.string(forKey: courseKey) ?? ""
    }

    static func saveCaption(_ value: String) {
        UserDefaults.standard.set(value, forKey: captionKey)
    }

    static func saveClub(_ value: String) {
        UserDefaults.standard.set(value, forKey: clubKey)
    }

    static func saveCourse(_ value: String) {
        UserDefaults.standard.set(value, forKey: courseKey)
    }
}

private struct VideoFileTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { file in
            SentTransferredFile(file.url)
        } importing: { received in
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: temp)
            return VideoFileTransferable(url: temp)
        }
    }
}

enum ShowcaseVideoEncoder {
    /// Re-encode Control Center recordings to ~720p H.264 before upload.
    static func exportForUpload(
        sourceURL: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        let preferred = [
            AVAssetExportPreset1280x720,
            AVAssetExportPreset960x540,
            AVAssetExportPresetMediumQuality,
        ]
        // Prefer creating a session over deprecated `exportPresets(compatibleWith:)`.
        guard let preset = preferred.first(where: { AVAssetExportSession(asset: asset, presetName: $0) != nil }),
              let session = AVAssetExportSession(asset: asset, presetName: preset)
        else {
            throw ShowcaseUploadError.encodeFailed
        }

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        if FileManager.default.fileExists(atPath: out.path) {
            try? FileManager.default.removeItem(at: out)
        }
        session.outputURL = out
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        let progressTask = Task {
            while !Task.isCancelled {
                let p = Double(session.progress)
                onProgress?(min(max(p, 0), 0.99))
                if session.status != .waiting && session.status != .unknown && session.status != .exporting {
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously {
                cont.resume()
            }
        }
        progressTask.cancel()
        onProgress?(1)

        guard session.status == .completed, FileManager.default.fileExists(atPath: out.path) else {
            throw ShowcaseUploadError.encodeFailed
        }
        return out
    }
}

enum ShowcaseUploadError: LocalizedError {
    case notConfigured
    case missingToken
    case encodeFailed
    case auth(String)
    case storage(Int, String)
    case database(Int, String)
    case http(Int, String)
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return L10n.showcaseUploadNotConfigured
        case .missingToken:
            return L10n.showcaseUploadNeedSignIn
        case .encodeFailed:
            return L10n.showcaseUploadEncodeFailed
        case .auth(let body):
            return "Auth failed: \(body)"
        case .storage(let code, let body):
            return "Storage failed (\(code)): \(body)"
        case .database(let code, let body):
            return "DB insert failed (\(code)): \(body)"
        case .http(let code, let body):
            return "Upload failed (\(code)): \(body)"
        case .tooLarge:
            return L10n.showcaseUploadTooLarge
        }
    }
}

enum ShowcaseSupabaseUploader {
    private static let maxBytes = 400 * 1024 * 1024

    static func upload(
        fileURL: URL,
        userID: String,
        accessToken: String,
        category: String,
        nickname: String,
        caption: String,
        clubName: String,
        courseName: String,
        holeNumber: Int,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        guard PutthinkSupabaseConfig.isConfigured,
              let base = URL(string: PutthinkSupabaseConfig.urlString)
        else { throw ShowcaseUploadError.notConfigured }

        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        if size > maxBytes { throw ShowcaseUploadError.tooLarge }

        var ext = fileURL.pathExtension.lowercased()
        if ext.isEmpty { ext = "mp4" }
        if ext == "qt" { ext = "mov" }
        let fileName = "\(UUID().uuidString.lowercased()).\(ext)"
        let mime: String
        switch ext {
        case "mov": mime = "video/quicktime"
        case "m4v": mime = "video/mp4"
        default: mime = "video/mp4"
        }

        let uploadURL = base
            .appendingPathComponent("storage")
            .appendingPathComponent("v1")
            .appendingPathComponent("object")
            .appendingPathComponent(PutthinkSupabaseConfig.storageBucket)
            .appendingPathComponent(userID)
            .appendingPathComponent(fileName)

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue(PutthinkSupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(mime, forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "x-upsert")

        let (data, response) = try await uploadFile(request: request, fileURL: fileURL, onProgress: onProgress)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(code) else {
            throw ShowcaseUploadError.storage(code, String(data: data, encoding: .utf8) ?? "")
        }

        let publicURLString =
            "\(PutthinkSupabaseConfig.urlString)/storage/v1/object/public/\(PutthinkSupabaseConfig.storageBucket)/\(userID)/\(fileName)"
        guard let publicURL = URL(string: publicURLString) else {
            throw ShowcaseUploadError.notConfigured
        }

        try await ensureProfile(userID: userID, accessToken: accessToken, base: base)

        let insertURL = base
            .appendingPathComponent("rest")
            .appendingPathComponent("v1")
            .appendingPathComponent("putt_showcase")
        var insert = URLRequest(url: insertURL)
        insert.httpMethod = "POST"
        insert.setValue(PutthinkSupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        insert.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        insert.setValue("application/json", forHTTPHeaderField: "Content-Type")
        insert.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        let payload: [String: Any] = [
            "user_id": userID,
            "video_url": publicURL.absoluteString,
            "category": category,
            "nickname": nickname,
            "caption": caption,
            "club_name": clubName,
            "course_name": courseName,
            "hole_number": holeNumber,
        ]
        insert.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (insertData, insertResponse) = try await URLSession.shared.data(for: insert)
        let insertCode = (insertResponse as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(insertCode) else {
            throw ShowcaseUploadError.database(insertCode, String(data: insertData, encoding: .utf8) ?? "")
        }
        return publicURL
    }

    private static func uploadFile(
        request: URLRequest,
        fileURL: URL,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            final class Box: @unchecked Sendable {
                var observation: NSKeyValueObservation?
                var resumed = false
            }
            let box = Box()
            let task = URLSession.shared.uploadTask(with: request, fromFile: fileURL) { data, response, error in
                box.observation?.invalidate()
                guard !box.resumed else { return }
                box.resumed = true
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, let response {
                    onProgress?(1)
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: ShowcaseUploadError.http(-1, "empty response"))
                }
            }
            box.observation = task.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
                onProgress?(min(max(progress.fractionCompleted, 0), 0.99))
            }
            onProgress?(0)
            task.resume()
        }
    }

    private static func ensureProfile(userID: String, accessToken: String, base: URL) async throws {
        let url = base
            .appendingPathComponent("rest")
            .appendingPathComponent("v1")
            .appendingPathComponent("profiles")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(PutthinkSupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("resolution=ignore-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "id": userID,
            "free_runs_balance": 3,
            "free_tier_claimed": false,
        ])
        let (_, response) = try await URLSession.shared.data(for: req)
        _ = response
    }

    /// Upsert `profiles.display_nickname`. On unique conflict, redraw digits via `onCollision`.
    static func syncDisplayNickname(
        userID: String,
        accessToken: String,
        nickname: String,
        onCollision: () -> String
    ) async {
        guard PutthinkSupabaseConfig.isConfigured,
              let base = URL(string: PutthinkSupabaseConfig.urlString)
        else { return }

        var candidate = nickname
        for _ in 0..<5 {
            let ok = await patchDisplayNickname(
                base: base,
                userID: userID,
                accessToken: accessToken,
                nickname: candidate
            )
            if ok { return }
            candidate = await MainActor.run { onCollision() }
        }
    }

    private static func patchDisplayNickname(
        base: URL,
        userID: String,
        accessToken: String,
        nickname: String
    ) async -> Bool {
        var comps = URLComponents(
            url: base
                .appendingPathComponent("rest")
                .appendingPathComponent("v1")
                .appendingPathComponent("profiles"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [URLQueryItem(name: "id", value: "eq.\(userID)")]
        guard let url = comps.url else { return false }

        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue(PutthinkSupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "display_nickname": nickname,
        ])
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            return true
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        if (200...299).contains(code) { return true }
        let body = String(data: data, encoding: .utf8) ?? ""
        // Unique violation → retry with new digits.
        if body.contains("23505") || body.lowercased().contains("duplicate") {
            return false
        }
        // Column missing / RLS — ignore for upload path.
        return true
    }
}
