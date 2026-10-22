import SwiftUI
import UIKit
import Foundation

public struct MessageBubbleView: View {
    public let message: Message
    public var onDelete: (() -> Void)?
    public var onRerun: (() -> Void)?
    public var onUndo: (() -> Void)?
    @State private var copied: Bool = false
    
    public init(
        message: Message,
        onDelete: (() -> Void)? = nil,
        onRerun: (() -> Void)? = nil,
        onUndo: (() -> Void)? = nil
    ) {
        self.message = message
        self.onDelete = onDelete
        self.onRerun = onRerun
        self.onUndo = onUndo
    }
    
    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .assistant {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(LinearGradient(colors: [Color.blue, Color.purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .clipShape(Circle())
            } else {
                Spacer(minLength: 40)
            }
            
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
                // Reasoning block
                if let reasoning = message.reasoningContent, !reasoning.isEmpty {
                    ThinkingView(text: reasoning, isStreaming: message.isStreaming && message.content.isEmpty)
                }
                
                // Tool calls
                if let tools = message.toolCalls, !tools.isEmpty {
                    ToolExecutionView(toolCalls: tools)
                }
                
                if let attachments = message.attachments, !attachments.isEmpty {
                    attachmentStrip(attachments)
                }

                // Main content
                if !message.content.isEmpty {
                    MessageContentText(content: message.content, rendersMarkdown: message.role == .assistant)
                        .font(.system(size: 15))
                        .foregroundColor(message.role == .user ? .white : .primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(message.role == .user ? Color.blue : Color(.secondarySystemBackground))
                        .cornerRadius(16)
                        .textSelection(.enabled)
                        .contextMenu {
                            Button(action: { UIPasteboard.general.string = message.content }) {
                                Label("Copy Text", systemImage: "doc.on.doc")
                            }
                            ShareLink(item: message.content) {
                                Label("Share Text", systemImage: "square.and.arrow.up")
                            }
                            if let onRerun = onRerun, message.role == .assistant {
                                Button(action: onRerun) {
                                    Label("Rerun Response", systemImage: "arrow.clockwise")
                                }
                            }
                            if let onUndo = onUndo, message.role == .user {
                                Button(action: onUndo) {
                                    Label("Undo & Edit Message", systemImage: "arrow.uturn.backward")
                                }
                            }
                            if let onDelete = onDelete {
                                Button(role: .destructive, action: onDelete) {
                                    Label("Delete Message", systemImage: "trash")
                                }
                            }
                        }
                } else if message.isStreaming && (message.reasoningContent == nil || message.reasoningContent!.isEmpty) {
                    HStack(spacing: 4) {
                        ForEach(0..<3) { i in
                            Circle()
                                .fill(Color.secondary)
                                .frame(width: 6, height: 6)
                        }
                    }
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(14)
                }
                
                // Message metadata and actions
                HStack(spacing: 8) {
                    if let model = message.modelName {
                        Text(model)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    
                    if message.role == .assistant && !message.content.isEmpty {
                        Button(action: {
                            UIPasteboard.general.string = message.content
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                copied = false
                            }
                        }) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        
                        if let onRerun = onRerun, !message.isStreaming {
                            Button(action: onRerun) {
                                HStack(spacing: 3) {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 11))
                                    Text("Rerun")
                                        .font(.system(size: 11))
                                }
                                .foregroundColor(.blue)
                            }
                        }
                    }
                    
                    if message.role == .user {
                        if let onUndo = onUndo {
                            Button(action: onUndo) {
                                HStack(spacing: 3) {
                                    Image(systemName: "arrow.uturn.backward")
                                        .font(.system(size: 11))
                                    Text("Undo")
                                        .font(.system(size: 11))
                                }
                                .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            
            if message.role == .user {
                Image(systemName: "person.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.secondary)
                    .clipShape(Circle())
            } else {
                Spacer(minLength: 40)
            }
        }
    }

    @ViewBuilder
    private func attachmentStrip(_ attachments: [MessageAttachment]) -> some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 5) {
            ForEach(attachments) { attachment in
                HStack(spacing: 7) {
                    Image(systemName: attachment.mimeType.hasPrefix("image/") ? "photo.fill" : "doc.fill")
                        .foregroundColor(message.role == .user ? .white : .blue)
                    Text(attachment.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if let data = Data(base64Encoded: attachment.dataBase64), attachment.mimeType.hasPrefix("image/"), let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 42, height: 42)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(message.role == .user ? Color.blue.opacity(0.82) : Color(.secondarySystemBackground))
                .foregroundColor(message.role == .user ? .white : .primary)
                .cornerRadius(10)
            }
        }
    }
}

private struct MessageContentText: View {
    let content: String
    let rendersMarkdown: Bool

    var body: some View {
        if rendersMarkdown, let attributed = try? AttributedString(markdown: content) {
            Text(attributed)
        } else {
            Text(content)
        }
    }
}
