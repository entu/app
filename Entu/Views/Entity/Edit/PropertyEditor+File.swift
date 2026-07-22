// File-property editors for `PropertyEditor` — saved-file preview row, the
// upload button (Files + Photos on iOS), file staging, and MIME lookup.
// Split out of `PropertyEditor.swift` to keep the core type-dispatch small.

import SwiftUI
import QuickLook
#if os(iOS)
import PhotosUI
#endif
import UniformTypeIdentifiers

extension PropertyEditor {

    /// Saved → name + size + delete; uploading → progress bar + name + size;
    /// empty → upload button.
    @ViewBuilder
    var fileEditor: some View {
        if value._id != nil {
            savedFileRow
        } else if value.isUploading {
            uploadingFileRow
        } else {
            uploadButton
        }
    }

    /// Same accent chip as the detail view (`FileChip` — thumbnail + name +
    /// size), plus the trailing ×; tap previews.
    @ViewBuilder
    var savedFileRow: some View {
        FileChip(
            propertyId: value._id ?? "",
            filename: value.stringValue,
            filesize: value.filesize,
            action: { Task { await downloadAndPreview() } },
            onDelete: { showingDeleteFileConfirm = true }
        )
        .quickLookPreview($previewURL)
        .confirmationDialog(
            Text("deleteFileConfirmTitle \(value.stringValue)"),
            isPresented: $showingDeleteFileConfirm,
            titleVisibility: .visible
        ) {
            // Question and action share the verb (ET: Kustuta fail …? → Kustuta).
            Button("delete", role: .destructive) {
                Task { await onDelete() }
            }
            Button("cancel", role: .cancel) {}
        }
    }

    /// Fetch the signed URL via `APIClient.downloadFileForPreview` and
    /// hand the temp file to QuickLook.
    func downloadAndPreview() async {
        guard let propId = value._id else { return }
        let filename = value.stringValue.isEmpty ? nil : value.stringValue
        previewURL = await api.downloadFileForPreview(propertyId: propId, filename: filename)
    }

    @ViewBuilder
    var uploadingFileRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: value.pendingFilename ?? "")
                    .foregroundStyle(.secondary)
                if value.uploadProgress >= 0 {
                    ProgressView(value: value.uploadProgress)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }
            if let size = value.pendingFilesize {
                Text(size.fileSizeString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    var uploadButton: some View {
        uploadButtonContent
            .dropDestination(for: URL.self) { urls, _ in
                let accepted = definition.list ? urls : Array(urls.prefix(1))
                let picks = accepted.compactMap { stageFile(at: $0) }
                guard !picks.isEmpty else { return false }
                onFilesPicked(picks)
                return true
            }
    }

    @ViewBuilder
    var uploadButtonContent: some View {
        #if os(iOS)
        // iOS — choice between Photos and Files. Multi-select when list.
        Menu {
            Button {
                photosPickerItems = []
                showingPickerChoice = true
            } label: {
                Label("chooseFromPhotos", systemImage: "photo")
            }
            Button {
                showingFileImporter = true
            } label: {
                Label("chooseFromFiles", systemImage: "folder")
            }
        } label: {
            uploadChipLabel
        }
        .photosPicker(
            isPresented: $showingPickerChoice,
            selection: $photosPickerItems,
            maxSelectionCount: definition.list ? 0 : 1,
            matching: .any(of: [.images, .videos])
        )
        .onChange(of: photosPickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadPhotosPickerItems(items) }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: definition.list
        ) { result in
            handleFileImporter(result)
        }
        #else
        // macOS — only fileImporter; Photos picker isn't available here.
        Button {
            showingFileImporter = true
        } label: {
            uploadChipLabel
        }
        .buttonStyle(.plain)
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: definition.list
        ) { result in
            handleFileImporter(result)
        }
        #endif
    }

    /// Dashed upload chip, per the design.
    var uploadChipLabel: some View {
        DashedAddLabel(
            titleKey: definition.list ? "uploadFiles" : "uploadFile",
            systemImage: "arrow.up"
        )
    }

    /// Copy each picked URL into the app's temp dir so it survives the
    /// security-scoped lifetime + lets the upload stream from disk.
    func handleFileImporter(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        let picks = urls.compactMap { stageFile(at: $0) }
        if !picks.isEmpty { onFilesPicked(picks) }
    }

    /// Copy a security-scoped picker URL into temp and return a `PickedFile`.
    func stageFile(at source: URL) -> PickedFile? {
        let needsAccess = source.startAccessingSecurityScopedResource()
        defer { if needsAccess { source.stopAccessingSecurityScopedResource() } }

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(source.pathExtension)
        do {
            try FileManager.default.copyItem(at: source, to: dest)
        } catch {
            return nil
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
        let size = (attrs?[.size] as? Int) ?? 0
        return PickedFile(
            filename: source.lastPathComponent,
            mimetype: source.mimeType(),
            url: dest,
            size: size
        )
    }

    #if os(iOS)
    /// Stream PhotosPicker items to temp files (we can't ask Photos for a
    /// URL, but `loadTransferable` can read in chunks via Data — write each
    /// chunk straight out so we don't keep the whole file in RAM).
    func loadPhotosPickerItems(_ items: [PhotosPickerItem]) async {
        var picks: [PickedFile] = []
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let type = item.supportedContentTypes.first
            let ext = type?.preferredFilenameExtension ?? "dat"
            let mime = type?.preferredMIMEType ?? "application/octet-stream"
            let filename = "photo-\(Int(Date().timeIntervalSince1970))-\(index + 1).\(ext)"
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            do {
                try data.write(to: dest)
            } catch { continue }
            picks.append(PickedFile(filename: filename, mimetype: mime, url: dest, size: data.count))
        }
        photosPickerItems = []
        if !picks.isEmpty { onFilesPicked(picks) }
    }
    #endif
}

private extension URL {
    /// MIME type from the URL's path extension via `UTType`. Falls back
    /// to `application/octet-stream` when the extension is unknown.
    func mimeType() -> String {
        guard let type = UTType(filenameExtension: pathExtension),
              let mime = type.preferredMIMEType else {
            return "application/octet-stream"
        }
        return mime
    }
}
