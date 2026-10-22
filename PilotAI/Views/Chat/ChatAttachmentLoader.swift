import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Only formats actually consumed by the provider adapters are accepted. PDF/Office/archive
/// imports are intentionally excluded instead of pretending their filenames are document content.
enum ChatAttachmentLoader {
    static let maximumCount = 4
    static let maximumImageBytes = 10 * 1024 * 1024
    static let maximumTextBytes = 120_000
    static let maximumTotalBytes = 20 * 1024 * 1024
    static let allowedTypes: [UTType] = [.image, .plainText, .json, .commaSeparatedText]
    static let limitsDescription = "Up to 4 images or UTF-8 text/JSON/CSV files. Images: 10 MB each; text: 120 KB each; total: 20 MB. Images are resized to 2048 px. PDF and Office documents are not supported."

    static func photo(data: Data, name: String = "Photo.jpg") throws -> MessageAttachment {
        guard !data.isEmpty else { throw ImportError.unreadable }
        guard data.count <= maximumImageBytes else { throw ImportError.imageTooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary),
              let jpeg = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.85),
              jpeg.count <= maximumImageBytes else { throw ImportError.unreadable }
        let stem = (name as NSString).deletingPathExtension
        return MessageAttachment(name: "\(stem.isEmpty ? "Photo" : stem).jpg", mimeType: "image/jpeg", dataBase64: jpeg.base64EncodedString())
    }

    static func text(data: Data, name: String, mimeType: String) throws -> MessageAttachment {
        guard !data.isEmpty else { throw ImportError.unreadable }
        guard data.count <= maximumTextBytes else { throw ImportError.textTooLarge }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw ImportError.invalidText
        }
        return MessageAttachment(name: name, mimeType: mimeType, dataBase64: data.base64EncodedString())
    }

    static func file(url: URL) throws -> MessageAttachment {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey])
        guard values.isDirectory != true else { throw ImportError.unsupportedType }
        let type = values.contentType ?? UTType(filenameExtension: url.pathExtension)
        let isImage = type?.conforms(to: .image) == true
        let isJSON = type?.conforms(to: .json) == true
        let isText = type?.conforms(to: .plainText) == true || type?.conforms(to: .commaSeparatedText) == true || isJSON
        guard isImage || isText else { throw ImportError.unsupportedType }
        let limit = isImage ? maximumImageBytes : maximumTextBytes
        guard (values.fileSize ?? 0) <= limit else {
            throw isImage ? ImportError.imageTooLarge : ImportError.textTooLarge
        }
        // Read at most the limit + 1 even when a document provider supplies no size metadata.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        if isImage { return try photo(data: data, name: url.lastPathComponent) }
        return try text(data: data, name: url.lastPathComponent, mimeType: isJSON ? "application/json" : "text/plain")
    }

    static func validateAdding(_ attachment: MessageAttachment, to existing: [MessageAttachment]) throws {
        guard existing.count < maximumCount else { throw ImportError.tooMany }
        let total = (existing + [attachment]).reduce(0) { $0 + (Data(base64Encoded: $1.dataBase64)?.count ?? 0) }
        guard total <= maximumTotalBytes else { throw ImportError.totalTooLarge }
    }

    enum ImportError: LocalizedError {
        case unreadable, unsupportedType, invalidText, imageTooLarge, textTooLarge, totalTooLarge, tooMany
        var errorDescription: String? {
            switch self {
            case .unreadable: return "The attachment is empty or could not be decoded."
            case .unsupportedType: return "Choose an image or UTF-8 text, JSON, or CSV file. PDF, Office documents, folders, and archives are not supported."
            case .invalidText: return "Text files must contain valid UTF-8 text without binary data."
            case .imageTooLarge: return "Images must be 10 MB or smaller."
            case .textTooLarge: return "Text files must be 120 KB or smaller."
            case .totalTooLarge: return "Attachments must total 20 MB or less."
            case .tooMany: return "You can send up to 4 attachments per message."
            }
        }
    }
}
