import AVFoundation
import Photos
import SwiftUI
import UIKit

/// Single-select video library (radio) — commit only via Add.
struct SingleVideoLibraryPicker: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = SingleVideoLibraryModel()
    var onPicked: (URL) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4),
    ]

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .loading:
                    ProgressView()
                        .tint(OSDPalette.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .denied:
                    ContentUnavailableView {
                        Label(L10n.showcaseUploadPickerPermissionTitle, systemImage: "photo.on.rectangle.angled")
                    } description: {
                        Text(L10n.showcaseUploadPickerPermissionBody)
                    } actions: {
                        Button(L10n.showcaseUploadPickerOpenSettings) {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                case .ready:
                    if model.assets.isEmpty {
                        ContentUnavailableView(
                            L10n.showcaseUploadPickerEmpty,
                            systemImage: "video.slash",
                            description: Text(L10n.showcaseUploadPickerEmptyBody)
                        )
                    } else {
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: 4) {
                                ForEach(model.assets, id: \.localIdentifier) { asset in
                                    VideoAssetCell(
                                        asset: asset,
                                        isSelected: model.selectedID == asset.localIdentifier
                                    ) {
                                        model.selectedID = asset.localIdentifier
                                    }
                                }
                            }
                            .padding(4)
                        }
                    }
                }
            }
            .background(Color(red: 8 / 255, green: 12 / 255, blue: 10 / 255))
            .navigationTitle(L10n.showcaseUploadPickTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.showcaseUploadPickerCancel) { dismiss() }
                        .foregroundStyle(OSDPalette.accent)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.showcaseUploadPickerAdd) {
                        Task { await confirm() }
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(OSDPalette.accent)
                    .disabled(model.selectedID == nil || model.isExporting)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let msg = model.statusMessage, !msg.isEmpty {
                    Text(msg)
                        .font(.system(size: 12))
                        .foregroundStyle(OSDPalette.accent)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.black.opacity(0.7))
                }
            }
            .overlay {
                if model.isExporting {
                    ZStack {
                        Color.black.opacity(0.35).ignoresSafeArea()
                        ProgressView()
                            .tint(OSDPalette.accent)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await model.load() }
    }

    private func confirm() async {
        do {
            let url = try await model.exportSelected()
            onPicked(url)
            dismiss()
        } catch {
            model.statusMessage = error.localizedDescription
        }
    }
}

@MainActor
private final class SingleVideoLibraryModel: ObservableObject {
    enum Phase {
        case loading
        case denied
        case ready
    }

    @Published var phase: Phase = .loading
    @Published var assets: [PHAsset] = []
    @Published var selectedID: String?
    @Published var isExporting = false
    @Published var statusMessage: String?

    func load() async {
        phase = .loading
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            phase = .denied
            return
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(
            format: "mediaType == %d",
            PHAssetMediaType.video.rawValue
        )
        let result = PHAsset.fetchAssets(with: options)
        var list: [PHAsset] = []
        list.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            list.append(asset)
        }
        assets = list
        selectedID = nil
        phase = .ready
    }

    func exportSelected() async throws -> URL {
        guard let selectedID,
              let asset = assets.first(where: { $0.localIdentifier == selectedID })
        else {
            throw ShowcaseUploadError.encodeFailed
        }
        isExporting = true
        defer { isExporting = false }

        let avAsset: AVAsset = try await withCheckedThrowingContinuation { cont in
            let opts = PHVideoRequestOptions()
            opts.isNetworkAccessAllowed = true
            opts.deliveryMode = .highQualityFormat
            PHImageManager.default().requestAVAsset(forVideo: asset, options: opts) { asset, _, info in
                if let err = info?[PHImageErrorKey] as? Error {
                    cont.resume(throwing: err)
                    return
                }
                guard let asset else {
                    cont.resume(throwing: ShowcaseUploadError.encodeFailed)
                    return
                }
                cont.resume(returning: asset)
            }
        }

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        if let urlAsset = avAsset as? AVURLAsset {
            if FileManager.default.fileExists(atPath: temp.path) {
                try FileManager.default.removeItem(at: temp)
            }
            try FileManager.default.copyItem(at: urlAsset.url, to: temp)
            return temp
        }

        guard let session = AVAssetExportSession(asset: avAsset, presetName: AVAssetExportPresetPassthrough)
                ?? AVAssetExportSession(asset: avAsset, presetName: AVAssetExportPresetHighestQuality)
        else {
            throw ShowcaseUploadError.encodeFailed
        }
        session.outputURL = temp
        session.outputFileType = .mov
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }
        guard session.status == .completed else {
            throw ShowcaseUploadError.encodeFailed
        }
        return temp
    }
}

private struct VideoAssetCell: View {
    let asset: PHAsset
    let isSelected: Bool
    let onTap: () -> Void
    @State private var image: UIImage?

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.white.opacity(0.08)
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipped()

                Text(Self.formatDuration(asset.duration))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(5)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(
                        isSelected ? OSDPalette.accentInk : Color.white,
                        isSelected ? OSDPalette.accent : Color.white.opacity(0.85)
                    )
                    .padding(6)
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(OSDPalette.accent, lineWidth: 3)
                }
            }
        }
        .buttonStyle(.plain)
        .task(id: asset.localIdentifier) {
            image = await Self.thumbnail(for: asset)
        }
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private static func thumbnail(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { cont in
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .highQualityFormat
            opts.resizeMode = .fast
            opts.isNetworkAccessAllowed = true
            opts.isSynchronous = false
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 240, height: 240),
                contentMode: .aspectFill,
                options: opts
            ) { image, _ in
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: image)
            }
        }
    }
}
