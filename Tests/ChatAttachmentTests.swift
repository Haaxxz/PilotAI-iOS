import XCTest
@testable import PilotAI

final class ChatAttachmentTests: XCTestCase {
    func testAttachmentRoundTripsAsCodableData() throws {
        let attachment = MessageAttachment(
            name: "notes.txt",
            mimeType: "text/plain",
            dataBase64: Data("hello".utf8).base64EncodedString()
        )
        let encoded = try JSONEncoder().encode(attachment)
        let decoded = try JSONDecoder().decode(MessageAttachment.self, from: encoded)
        XCTAssertEqual(decoded, attachment)
        XCTAssertEqual(Data(base64Encoded: decoded.dataBase64), Data("hello".utf8))
    }

    func testAttachmentIdentityIsStableWhenCopied() {
        let attachment = MessageAttachment(
            id: "attachment-1",
            name: "image.png",
            mimeType: "image/png",
            dataBase64: "aGVsbG8="
        )
        XCTAssertEqual(attachment.id, "attachment-1")
        XCTAssertEqual(attachment.name, "image.png")
    }
}
