import Foundation
import XCTest
#if canImport(PilotAI)
@testable import PilotAI
#endif

final class BrowserURLPolicyTests: XCTestCase {
    func testOnlyCredentialFreeBoundedHTTPURLsAreAccepted() {
        for text in ["https://example.com/path?q=one&two=2#section", "http://localhost:8080/", "https://example.com", "HTTPS://example.com/"] {
            XCTAssertNotNil(BrowserURLPolicy.allowedURL(text), text)
        }
        for text in ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,hello", "about:blank", "ftp://example.com", "//example.com",
                     "https://user:password@example.com/", "https://user@example.com", "https:///", "https://example.com:0", "https://example.com:65536",
                     "https://example.com/\nnext", "https://exa mple.com", "https://example.com\\@other.com", "", "https://example.com/" + String(repeating: "a", count: 2048)] {
            XCTAssertNil(BrowserURLPolicy.allowedURL(text), text)
        }
    }

    func testAddressSearchUsesQueryItemsAndRejectsUnsafeSchemes() {
        XCTAssertEqual(BrowserURLPolicy.addressURL(" example.com/path ")?.absoluteString, "https://example.com/path")
        let search = BrowserURLPolicy.addressURL("cats & dogs #today")
        XCTAssertEqual(search?.host, "www.google.com")
        XCTAssertEqual(search.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems, [URLQueryItem(name: "q", value: "cats & dogs #today")])
        for input in ["javascript:alert(1)", "file:///tmp/notes.txt", "data:text/plain,hello", "https://user:password@example.com", "about:blank", ""] {
            XCTAssertNil(BrowserURLPolicy.addressURL(input), input)
        }
    }

    #if os(Linux)
    static let linuxTests = [
        ("testOnlyCredentialFreeBoundedHTTPURLsAreAccepted", testOnlyCredentialFreeBoundedHTTPURLsAreAccepted),
        ("testAddressSearchUsesQueryItemsAndRejectsUnsafeSchemes", testAddressSearchUsesQueryItemsAndRejectsUnsafeSchemes)
    ]
    #endif
}

#if canImport(WebKit) && canImport(UIKit)
@MainActor
final class BrowserApprovalTests: XCTestCase {
    func testUnsupportedNavigationDoesNotPresentApproval() async {
        let browser = IOSBrowserService.shared
        browser.setTakeover(false)
        let output = await IOSBrowserService.execute(toolName: "browser_navigate", arguments: "{\"url\":\"file:///etc/passwd\"}")
        XCTAssertTrue(output.hasPrefix("BROWSER_ERROR:"))
        XCTAssertNil(browser.pendingApproval)
    }

    func testManualTakeoverRejectsAgentNavigationBeforeDispatch() async {
        let browser = IOSBrowserService.shared
        browser.setTakeover(true)
        defer { browser.setTakeover(false) }
        let before = browser.currentURL
        let output = await IOSBrowserService.execute(toolName: "browser_navigate", arguments: "{\"url\":\"https://example.com/\"}")
        XCTAssertTrue(output.contains("paused"))
        XCTAssertNil(browser.pendingApproval)
        XCTAssertEqual(browser.currentURL, before)
    }

    func testDeniedNavigationDoesNotDispatch() async throws {
        let browser = IOSBrowserService.shared
        browser.setTakeover(false)
        let before = browser.currentURL
        let request = Task { await IOSBrowserService.execute(toolName: "browser_navigate", arguments: "{\"url\":\"https://example.com/\"}") }
        defer { request.cancel() }
        for _ in 0..<100 where browser.pendingApproval == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        let approval = try XCTUnwrap(browser.pendingApproval)
        browser.deny(approval.id)
        let output = await request.value
        XCTAssertTrue(output.contains("not approved"))
        XCTAssertEqual(browser.currentURL, before)
        XCTAssertNil(browser.pendingApproval)
    }

    func testCancelledApprovalNeverNavigates() async throws {
        let browser = IOSBrowserService.shared
        browser.setTakeover(false)
        let before = browser.currentURL
        let request = Task { await IOSBrowserService.execute(toolName: "browser_navigate", arguments: "{\"url\":\"https://example.com/\"}") }
        for _ in 0..<100 where browser.pendingApproval == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(browser.pendingApproval)
        request.cancel()
        let output = await request.value
        XCTAssertTrue(output.hasPrefix("TOOL_CANCELLED:"))
        XCTAssertEqual(browser.currentURL, before)
        XCTAssertNil(browser.pendingApproval)
    }
}
#endif
