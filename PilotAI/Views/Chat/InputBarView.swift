import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

public extension View {
    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

/// Native attachment limits keep memory use predictable while matching the Android picker's file-oriented contract.
private enum AttachmentLimits {
    static let imageBytes = 10 * 1024 * 1024
    static let fileBytes = 10 * 1024 * 1024
}

public struct InputBarView: View {
    @EnvironmentObject private var state: AppState
    @Binding public var text: String
    public let isGenerating: Bool
    public let onSend: ([MessageAttachment], Bool, Bool) -> Void
    public let onStop: () -> Void

    @State private var webSearchEnabled = false
    @State private var reasoningEnabled = false
    @State private var showAttachmentOptions = false
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var attachments: [MessageAttachment] = []
    @State private var attachmentError: String?
    @FocusState private var isFocused: Bool

    public init(
        text: Binding<String>,
        isGenerating: Bool,
        onSend: @escaping ([MessageAttachment], Bool, Bool) -> Void,
        onStop: @escaping () -> Void
    ) {
        self._text = text
        self.isGenerating = isGenerating
        self.onSend = onSend
        self.onStop = onStop
    }

    public var body: some View {
        VStack(spacing: 6) {
            Divider()

            if !attachments.isEmpty {
                attachmentStrip
            }

            HStack(alignment: .bottom, spacing: 6) {
                Button { showAttachmentOptions = true } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary)
                }
                .accessibilityLabel("Add attachment")
                .padding(.bottom, 6)
                .confirmationDialog("Add Attachment", isPresented: $showAttachmentOptions, titleVisibility: .visible) {
                    Button("Photo / Image") { showPhotoPicker = true }
                    Button("Document / File") { showFileImporter = true }
                    Button("Cancel", role: .cancel) {}
                }

                toggleButton("globe", enabled: webSearchEnabled, color: .blue, label: "Web search") {
                    webSearchEnabled.toggle()
                }
                .padding(.bottom, 4)

                toggleButton("brain", enabled: reasoningEnabled, color: .purple, label: "Reasoning") {
                    reasoningEnabled.toggle()
                }
                .padding(.bottom, 4)

                if let conv = state.selectedConversation, !conv.messages.isEmpty {
                    let tokenEstimate = conv.messages.reduce(0) { $0 + $1.content.count } / 4
                    if tokenEstimate > 0 {
                        Text("~\(tokenEstimate < 1000 ? "\(tokenEstimate)" : String(format: "%.1fk", Double(tokenEstimate) / 1000.0)) tks")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color(.tertiarySystemBackground))
                            .cornerRadius(6)
                            .padding(.bottom, 6)
                    }
                }

                HStack {
                    TextField(isGenerating ? "Generating…" : "Ask PilotAI anything…", text: $text, axis: .vertical)
                        .focused($isFocused)
                        .lineLimit(1...5)
                        .onSubmit {
                            if state.settings.sendOnEnter {
                                handleSend()
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .disabled(isGenerating)
                }
                .background(Color(.secondarySystemBackground))
                .cornerRadius(20)

                if isFocused {
                    Button { isFocused = false } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.system(size: 20))
                            .foregroundColor(.secondary)
                            .padding(.bottom, 6)
                    }
                    .accessibilityLabel("Dismiss keyboard")
                }

                if isGenerating {
                    Button(action: onStop) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.red)
                    }
                    .accessibilityLabel("Stop generating")
                } else {
                    Button(action: handleSend) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(canSend ? .blue : .secondary.opacity(0.5))
                    }
                    .disabled(!canSend)
                    .accessibilityLabel("Send message")
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            .background(Color(.systemBackground))
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItem, matching: .images)
        .onChange(of: selectedPhotoItem) { item in
            guard let item else { return }
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw AttachmentImportError.unreadable
                    }
                    guard data.count <= AttachmentLimits.imageBytes else {
                        throw AttachmentImportError.tooLarge(limit: AttachmentLimits.imageBytes)
                    }
                    guard let image = UIImage(data: data) else {
                        throw AttachmentImportError.unsupportedType
                    }
                    let originalMime = imageFormat(for: data)
                    let uploadData: Data
                    let mime: String
                    if let originalMime {
                        uploadData = data
                        mime = originalMime
                    } else if let jpegData = image.jpegData(compressionQuality: 0.9) {
                        uploadData = jpegData
                        mime = "image/jpeg"
                    } else {
                        throw AttachmentImportError.unreadable
                    }
                    guard uploadData.count <= AttachmentLimits.imageBytes else {
                        throw AttachmentImportError.tooLarge(limit: AttachmentLimits.imageBytes)
                    }
                    let ext = mime.split(separator: "/").last.map(String.init) ?? "jpg"
                    let attachment = MessageAttachment(
                        name: "Photo_\(Int(Date().timeIntervalSince1970)).\(ext)",
                        mimeType: mime,
                        dataBase64: uploadData.base64EncodedString()
                    )
                    await MainActor.run {
                        attachments.append(attachment)
                        selectedPhotoItem = nil
                    }
                } catch {
                    await MainActor.run {
                        attachmentError = error.localizedDescription
                        selectedPhotoItem = nil
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.plainText, .pdf, .image, .json, .commaSeparatedText],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                importFiles(urls)
            case .failure(let error):
                attachmentError = error.localizedDescription
            }
        }
        .alert("Attachment not added", isPresented: Binding(
            get: { attachmentError != nil },
            set: { if !$0 { attachmentError = nil } }
        )) {
            Button("OK", role: .cancel) { attachmentError = nil }
        } message: {
            Text(attachmentError ?? "Unknown attachment error")
        }
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 7) {
                        Image(systemName: attachment.mimeType.hasPrefix("image/") ? "photo.fill" : "doc.fill")
                            .foregroundColor(.blue)
                        Text(attachment.name)
                            .font(.caption)
                            .lineLimit(1)
                        Button {
                            attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .accessibilityLabel("Remove \(attachment.name)")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(.tertiarySystemBackground))
                    .cornerRadius(9)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func toggleButton(_ icon: String, enabled: Bool, color: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(enabled ? color : .secondary)
                .padding(5)
                .background(enabled ? color.opacity(0.15) : .clear)
                .clipShape(Circle())
        }
        .accessibilityLabel(label)
    }

    private func handleSend() {
        guard canSend else { return }
        let outgoing = attachments
        onSend(outgoing, webSearchEnabled, reasoningEnabled)
        text = ""
        attachments.removeAll()
        webSearchEnabled = false
        reasoningEnabled = false
        isFocused = false
    }

    private func importFiles(_ urls: [URL]) {
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isDirectoryKey])
                guard values.isDirectory != true else {
                    throw AttachmentImportError.unsupportedType
                }
                let size = values.fileSize ?? 0
                guard size <= AttachmentLimits.fileBytes else {
                    throw AttachmentImportError.tooLarge(limit: AttachmentLimits.fileBytes)
                }
                guard let contentType = values.contentType,
                      isSupported(contentType) else {
                    throw AttachmentImportError.unsupportedType
                }
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                guard data.count <= AttachmentLimits.fileBytes else {
                    throw AttachmentImportError.tooLarge(limit: AttachmentLimits.fileBytes)
                }
                attachments.append(MessageAttachment(
                    name: url.lastPathComponent,
                    mimeType: contentType.preferredMIMEType ?? "application/octet-stream",
                    dataBase64: data.base64EncodedString()
                ))
            } catch {
                attachmentError = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    private func isSupported(_ type: UTType) -> Bool {
        type.conforms(to: .image) || type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .json)
    }

    private func imageFormat(for data: Data) -> String? {
        guard data.count >= 12 else { return nil }
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if bytes.starts(with: [0x52, 0x49, 0x46, 0x46]) && Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
        return nil
    }
}

private enum AttachmentImportError: LocalizedError {
    case tooLarge(limit: Int)
    case unsupportedType
    case unreadable

    var errorDescription: String? {
        switch self {
        case .tooLarge(let limit): return "This attachment is larger than \(limit / (1024 * 1024)) MB."
        case .unsupportedType: return "Choose an image, PDF, JSON, or text file."
        case .unreadable: return "The selected attachment could not be read."
        }
    }
}
