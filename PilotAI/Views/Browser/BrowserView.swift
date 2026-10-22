import SwiftUI
import WebKit

@MainActor
public struct BrowserView: View {
    @ObservedObject private var browser = IOSBrowserService.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var urlString = ""
    @State private var confirmReset = false
    @FocusState private var editingAddress: Bool

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: browser.goBack) { Image(systemName: "chevron.left") }
                    .disabled(!browser.canGoBack || browser.isResetting)
                    .accessibilityLabel("Go back")

                Button(action: browser.goForward) { Image(systemName: "chevron.right") }
                    .disabled(!browser.canGoForward || browser.isResetting)
                    .accessibilityLabel("Go forward")

                HStack {
                    Image(systemName: browser.currentURL?.scheme?.lowercased() == "https" ? "lock.fill" : "globe")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .accessibilityLabel(browser.currentURL?.scheme?.lowercased() == "https" ? "HTTPS" : "Web address")
                    TextField("Search or enter URL", text: $urlString)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .font(.system(size: 14))
                        .submitLabel(.go)
                        .focused($editingAddress)
                        .onSubmit(loadURL)
                        .disabled(browser.isResetting)
                    if !urlString.isEmpty {
                        Button(action: { urlString = "" }) {
                            Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                        }
                        .accessibilityLabel("Clear address")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(10)

                Button(action: browser.reloadOrStop) {
                    Image(systemName: browser.isLoading ? "xmark" : "arrow.clockwise")
                }
                .disabled(browser.isResetting || browser.currentURL == nil)
                .accessibilityLabel(browser.isLoading ? "Stop loading" : "Reload page")

                Menu {
                    Button {
                        if let address = browser.currentURL?.absoluteString,
                           let url = BrowserURLPolicy.allowedURL(address) { UIApplication.shared.open(url) }
                    } label: {
                        Label("Open in Safari", systemImage: "safari")
                    }
                    .disabled(browser.currentURL == nil || browser.isResetting)
                    Button(role: .destructive) { confirmReset = true } label: {
                        Label("Reset Browser Session", systemImage: "trash")
                    }
                    .disabled(browser.isResetting)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Browser actions")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.systemBackground))

            HStack {
                Image(systemName: browser.isTakenOver ? "hand.raised.fill" : "checkmark.shield")
                Text(browser.isTakenOver ? "Manual control · agent paused" : "Shared session · approval per action")
                    .font(.caption)
                Spacer(minLength: 4)
                Button(browser.isTakenOver ? "Resume Agent" : "Take Over") { browser.setTakeover(!browser.isTakenOver) }
                    .font(.caption.weight(.semibold)).disabled(browser.isResetting)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(.secondarySystemBackground))

            if let error = browser.errorMessage {
                Text(error).font(.caption).foregroundColor(.red).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            } else if let status = browser.statusMessage {
                Text(status).font(.caption).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }

            if browser.isLoading {
                ProgressView(value: browser.progress)
                    .progressViewStyle(.linear)
                    .frame(height: 2)
            }

            if browser.isResetting {
                VStack { Spacer(); ProgressView("Clearing browser data…"); Spacer() }.frame(maxWidth: .infinity)
            } else {
                WebViewRepresentable(webView: browser.webView)
                    .id(ObjectIdentifier(browser.webView))
                    .overlay {
                        if browser.currentURL == nil {
                            VStack(spacing: 10) {
                                Image(systemName: "globe").font(.largeTitle)
                                Text("Your Shared Browser").font(.headline)
                                Text("Enter an address to begin. The agent uses this same session. Return here to approve requests or take over.")
                                    .font(.callout).multilineTextAlignment(.center)
                            }.foregroundColor(.secondary).padding(32).allowsHitTesting(false)
                        }
                    }
            }
        }
        // An overlay preserves the page viewport while approval appears/disappears; resizing
        // the WebView here would itself invalidate every observed element's geometry.
        .overlay(alignment: .bottom) { approvalPanel }
        .navigationTitle(browser.title.isEmpty ? "Agent Browser" : browser.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { browser.browserAppeared(); urlString = browser.currentURL?.absoluteString ?? "" }
        .onDisappear { browser.browserDisappeared() }
        .onChange(of: browser.currentURL) { url in if !editingAddress { urlString = url?.absoluteString ?? "" } }
        .onChange(of: scenePhase) { phase in if phase != .active { browser.suspendApprovals() } }
        .confirmationDialog("Reset Browser Session?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Clear Cookies, Storage & History", role: .destructive) { Task { await browser.resetSession(); urlString = "" } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This signs you out of websites in this app and clears the browser's persistent cookies, website storage, cache and in-app history. This cannot be undone.")
        }
    }

    @ViewBuilder
    private var approvalPanel: some View {
        if let approval = browser.pendingApproval {
            VStack(alignment: .leading, spacing: 8) {
                Text(approval.title).font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(approval.pageURL).font(.caption.monospaced()).textSelection(.enabled)
                        Text(approval.detail).font(.callout).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                HStack {
                    Button("Approve This Action") { editingAddress = false; browser.approve(approval.id) }.buttonStyle(.borderedProminent)
                    Button("Deny", role: .cancel) { browser.deny(approval.id) }.buttonStyle(.bordered)
                }
                Text("Approval expires after 2 minutes. Sign in and enter sensitive information yourself using Take Over.")
                    .font(.caption2).foregroundColor(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
            .cornerRadius(12)
            .shadow(radius: 6)
            .padding(8)
        }
    }

    private func loadURL() {
        editingAddress = false
        browser.navigate(address: urlString)
    }
}

@MainActor
private struct WebViewRepresentable: UIViewRepresentable {
    let webView: WKWebView
    // Attaching the shared view does not reload it or replace the service's delegates.
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
