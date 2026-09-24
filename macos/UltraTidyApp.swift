import AppKit
import Photos
import SwiftUI

@_silgen_name("image_signature")
private func imageSignature(_ pixels: UnsafePointer<UInt8>, _ length: Int, _ color: UnsafeMutablePointer<UInt32>) -> UInt64

@_silgen_name("group_photos")
private func groupPhotos(_ hashes: UnsafePointer<UInt64>, _ colors: UnsafePointer<UInt32>, _ timestamps: UnsafePointer<Int64>, _ count: Int, _ output: UnsafeMutablePointer<UInt32>) -> Int

struct PhotoGroup: Identifiable {
    let id: UInt32
    let assetIDs: [String]
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published var groups: [PhotoGroup] = []
    @Published var scanned = 0
    @Published var total = 0
    @Published var skipped = 0
    @Published var isScanning = false
    @Published var isDeleting = false
    @Published var deletionError: String?
    @Published var message = "Нажмите «Сканировать», чтобы найти похожие фото."

    func scan() {
        guard !isScanning && !isDeleting else { return }
        isScanning = true
        groups = []
        scanned = 0
        total = 0
        skipped = 0
        message = "Запрашиваем доступ к Фото…"

        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            guard let self else { return }
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    self.isScanning = false
                    self.message = "Доступ к Фото не предоставлен. Разрешите его в Системных настройках → Конфиденциальность и безопасность → Фото."
                }
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                self.scanLibrary(limited: status == .limited)
            }
        }
    }

    func deletePhotos(_ ids: Set<String>, completion: @escaping (Bool) -> Void) {
        guard !isDeleting else { return }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: nil)
        var assets: [PHAsset] = []
        fetched.enumerateObjects { asset, _, _ in assets.append(asset) }
        guard !assets.isEmpty else {
            deletionError = "Отмеченные фотографии больше не найдены в медиатеке."
            completion(false)
            return
        }
        let deletedIDs = Set(assets.map(\.localIdentifier))
        isDeleting = true
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        } completionHandler: { success, error in
            DispatchQueue.main.async {
                self.isDeleting = false
                if success {
                    self.groups = self.groups.compactMap { group in
                        let remaining = group.assetIDs.filter { !deletedIDs.contains($0) }
                        return remaining.count >= 2 ? PhotoGroup(id: group.id, assetIDs: remaining) : nil
                    }
                    self.message = "Удалено фото из медиатеки: \(deletedIDs.count)."
                } else {
                    self.deletionError = error?.localizedDescription ?? "Фото не удалось удалить."
                }
                completion(success)
            }
        }
    }

    nonisolated private func scanLibrary(limited: Bool) {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        let total = assets.count
        DispatchQueue.main.async {
            self.total = total
            self.message = "Анализируем фотографии…"
        }

        let requestOptions = PHImageRequestOptions()
        requestOptions.isSynchronous = true
        requestOptions.isNetworkAccessAllowed = true
        requestOptions.deliveryMode = .highQualityFormat
        requestOptions.resizeMode = .exact
        requestOptions.version = .current

        var ids: [String] = []
        var hashes: [UInt64] = []
        var colors: [UInt32] = []
        var timestamps: [Int64] = []
        ids.reserveCapacity(total)
        hashes.reserveCapacity(total)
        colors.reserveCapacity(total)
        timestamps.reserveCapacity(total)

        for position in 0..<total {
            autoreleasepool {
                let asset = assets.object(at: position)
                var received: NSImage?
                PHImageManager.default().requestImage(
                    for: asset,
                    targetSize: CGSize(width: 96, height: 96),
                    contentMode: .aspectFill,
                    options: requestOptions
                ) { image, _ in
                    received = image
                }
                if let image = received, let (hash, color) = Self.signature(for: image) {
                    ids.append(asset.localIdentifier)
                    hashes.append(hash)
                    colors.append(color)
                    timestamps.append(asset.creationDate.map { Int64($0.timeIntervalSince1970) } ?? Int64.min)
                }
            }
            if position % 25 == 0 || position == total - 1 {
                let done = position + 1
                let unavailable = done - ids.count
                DispatchQueue.main.async {
                    self.scanned = done
                    self.skipped = unavailable
                }
            }
        }

        var labels = [UInt32](repeating: 0, count: ids.count)
        let count: Int
        if ids.isEmpty {
            count = 0
        } else {
            count = hashes.withUnsafeBufferPointer { hashesBuffer in
                colors.withUnsafeBufferPointer { colorsBuffer in
                    timestamps.withUnsafeBufferPointer { timestampsBuffer in
                        labels.withUnsafeMutableBufferPointer { labelsBuffer in
                            groupPhotos(hashesBuffer.baseAddress!, colorsBuffer.baseAddress!, timestampsBuffer.baseAddress!, ids.count, labelsBuffer.baseAddress!)
                        }
                    }
                }
            }
        }
        var grouped: [UInt32: [String]] = [:]
        for (index, label) in labels.enumerated() where label != 0 {
            grouped[label, default: []].append(ids[index])
        }
        let results = grouped.map { PhotoGroup(id: $0.key, assetIDs: $0.value) }
            .sorted { $0.assetIDs.count > $1.assetIDs.count }
        DispatchQueue.main.async {
            self.groups = results
            self.isScanning = false
            if limited {
                self.message = "Найдено \(count) групп среди доступных фото. В настройках Фото выбран ограниченный доступ."
            } else {
                self.message = "Найдено \(count) групп среди \(ids.count) фото. Пропущено: \(total - ids.count)."
            }
        }
    }

    nonisolated private static func signature(for image: NSImage) -> (UInt64, UInt32)? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let source = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        var pixels = [UInt8](repeating: 0, count: 9 * 8 * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: 9,
                height: 8,
                bitsPerComponent: 8,
                bytesPerRow: 9 * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: 9, height: 8))
            return true
        }
        guard rendered else { return nil }
        var color: UInt32 = 0
        let hash = pixels.withUnsafeBufferPointer { buffer in
            imageSignature(buffer.baseAddress!, buffer.count, &color)
        }
        return (hash, color)
    }
}

struct AssetThumbnail: View {
    let id: String
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.12))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .task(id: "\(id):\(Int((size / 100).rounded(.up)))") {
            image = nil
            let assetID = id
            let requestSize = (size / 100).rounded(.up) * 100
            let requestedSize = requestSize * (NSScreen.main?.backingScaleFactor ?? 2)
            DispatchQueue.global(qos: .utility).async {
                let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
                guard let asset = fetched.firstObject else { return }
                let options = PHImageRequestOptions()
                options.isSynchronous = true
                options.isNetworkAccessAllowed = true
                options.deliveryMode = .highQualityFormat
                PHImageManager.default().requestImage(
                    for: asset,
                    targetSize: CGSize(width: requestedSize, height: requestedSize),
                    contentMode: .aspectFill,
                    options: options
                ) { result, _ in
                    DispatchQueue.main.async { image = result }
                }
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var model = LibraryModel()
    @AppStorage("thumbnailSize") private var thumbnailSize = 260.0
    @State private var pinchStartSize: Double?
    @State private var selectedGroupID: UInt32?
    @State private var markedIDs: Set<String> = []

    private var selectedGroup: PhotoGroup? {
        model.groups.first { $0.id == selectedGroupID }
    }

    private func deleteMarkedPhotos() {
        guard !markedIDs.isEmpty else { return }
        model.deletePhotos(markedIDs) { success in
            guard success else { return }
            markedIDs.removeAll()
            if !model.groups.contains(where: { $0.id == selectedGroupID }) {
                selectedGroupID = model.groups.first?.id
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                List(model.groups, selection: $selectedGroupID) { group in
                    HStack(spacing: 12) {
                        AssetThumbnail(id: group.assetIDs[0], size: 56)
                        VStack(alignment: .leading) {
                            Text("Группа \(group.id)").font(.headline)
                            Text("\(group.assetIDs.count) фото").foregroundStyle(.secondary)
                        }
                    }
                    .tag(group.id)
                    .padding(.vertical, 3)
                }
                .overlay {
                    if model.groups.isEmpty && !model.isScanning {
                        ContentUnavailableView("Нет групп", systemImage: "square.stack.3d.up", description: Text("После сканирования здесь появятся похожие снимки."))
                    }
                }
                Divider()
                HStack {
                    Button("Сканировать") {
                        selectedGroupID = nil
                        markedIDs.removeAll()
                        model.scan()
                    }
                        .disabled(model.isScanning || model.isDeleting)
                    Spacer()
                    if model.isScanning { ProgressView().controlSize(.small) }
                }
                .padding(12)
            }
            .navigationTitle("Похожие фото")
        } detail: {
            if let group = selectedGroup {
                VStack(spacing: 12) {
                    HStack {
                        Text("Выберите фото для удаления · \(group.assetIDs.count) в группе")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "minus.magnifyingglass")
                            .foregroundStyle(.secondary)
                        Slider(value: $thumbnailSize, in: 140...400, step: 20)
                            .frame(width: 160)
                            .accessibilityLabel("Размер миниатюр")
                        Image(systemName: "plus.magnifyingglass")
                            .foregroundStyle(.secondary)
                        Button("Удалить отмеченные (\(markedIDs.count))", role: .destructive) {
                            deleteMarkedPhotos()
                        }
                        .disabled(markedIDs.isEmpty || model.isDeleting || model.isScanning)
                    }
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSize), spacing: 16)], spacing: 16) {
                            ForEach(group.assetIDs, id: \.self) { id in
                                Button {
                                    if markedIDs.contains(id) {
                                        markedIDs.remove(id)
                                    } else {
                                        markedIDs.insert(id)
                                    }
                                } label: {
                                    AssetThumbnail(id: id, size: thumbnailSize)
                                        .id("\(id):\(Int((thumbnailSize / 100).rounded(.up)))")
                                        .frame(width: thumbnailSize, height: thumbnailSize)
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(markedIDs.contains(id) ? Color.red : .clear, lineWidth: 4)
                                                .allowsHitTesting(false)
                                        }
                                        .overlay(alignment: .topTrailing) {
                                            if markedIDs.contains(id) {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .font(.title)
                                                    .foregroundStyle(.red)
                                                    .padding(12)
                                                    .allowsHitTesting(false)
                                            }
                                        }
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(model.isDeleting || model.isScanning)
                            }
                        }
                        .padding(4)
                    }
                    .simultaneousGesture(
                        MagnificationGesture(minimumScaleDelta: 0.01)
                            .onChanged { scale in
                                let start = pinchStartSize ?? thumbnailSize
                                if pinchStartSize == nil { pinchStartSize = start }
                                thumbnailSize = min(400, max(140, (start * Double(scale) / 20).rounded() * 20))
                            }
                            .onEnded { _ in pinchStartSize = nil }
                    )
                }
                .padding(12)
                .navigationTitle("Группа \(group.id) · \(group.assetIDs.count) фото")
            } else {
                ContentUnavailableView("Выберите группу", systemImage: "photo.on.rectangle.angled", description: Text("Похожие снимки появятся здесь."))
            }
        }
        .toolbar {
            ToolbarItem {
                Text(model.message)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(model.message)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.isScanning {
                ProgressView(value: Double(model.scanned), total: Double(max(model.total, 1)))
                    .padding(.horizontal)
                    .padding(.bottom, 4)
            }
        }
        .frame(minWidth: 1050, minHeight: 700)
        .onChange(of: model.groups.count) { _, newCount in
            if newCount > 0 && selectedGroupID == nil {
                selectedGroupID = model.groups[0].id
            }
        }
        .alert("Не удалось удалить фото", isPresented: Binding(
            get: { model.deletionError != nil },
            set: { if !$0 { model.deletionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.deletionError ?? "")
        }
    }
}

@main
struct UltraTidyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1300, height: 850)
    }
}
