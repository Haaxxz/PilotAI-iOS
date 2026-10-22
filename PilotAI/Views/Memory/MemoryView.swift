import SwiftUI

public struct MemoryView: View {
    @EnvironmentObject private var state: AppState
    @State private var markdownText: String = ""
    @State private var autoInject: Bool = true
    @State private var showSaveAlert: Bool = false
    @State private var memoryRevision: String = ""
    @State private var saveError: String?
    
    public init() {}
    
    public var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Configuration"), footer: Text("When enabled, this core memory block will be automatically injected into system prompts across all conversations.")) {
                    Toggle("Auto-Inject Memories", isOn: $autoInject)
                }
                
                Section(header: Text("Core Memories (Markdown)")) {
                    TextEditor(text: $markdownText)
                        .font(.system(size: 14, design: .monospaced))
                        .frame(minHeight: 280)
                }
                
                Section {
                    HStack {
                        Text("Characters")
                        Spacer()
                        Text("\(markdownText.count)")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Estimated Tokens")
                        Spacer()
                        Text("~\(markdownText.count / 4)")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Memory")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        do {
                            var draft = state.memory
                            draft.isAutoInjectEnabled = autoInject
                            let snapshot = try IOSRuntimeToolService.MemoryStore.shared.write(
                                markdown: markdownText,
                                mode: "replace",
                                expectedRevision: memoryRevision,
                                fallback: draft,
                                autoInjectEnabled: autoInject
                            )
                            state.memory = snapshot.document
                            markdownText = snapshot.document.markdown
                            memoryRevision = snapshot.revision
                            showSaveAlert = true
                        } catch {
                            saveError = error.localizedDescription
                        }
                    }
                }
            }
            .onAppear {
                markdownText = state.memory.markdown
                autoInject = state.memory.isAutoInjectEnabled
                memoryRevision = (try? IOSRuntimeToolService.MemoryStore.shared.read(fallback: state.memory).revision) ?? ""
            }
            .alert("Memory Saved", isPresented: $showSaveAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Your core memories are now active and synchronized.")
            }
            .alert("Memory Not Saved", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveError ?? "The memory changed elsewhere. Reload it before saving again.")
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}
