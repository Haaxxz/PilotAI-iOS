import SwiftUI

public struct TerminalView: View {
    @EnvironmentObject private var state: AppState
    @State private var inputCommand: String = ""
    @FocusState private var isFocused: Bool
    
    public init() {}
    
    public var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Terminal Console Area
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(state.terminalOutput.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(line.hasPrefix("$") ? .green : .white)
                                    .textSelection(.enabled)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(Color.black)
                    .scrollDismissesKeyboard(.interactively)
                    .onTapGesture { hideKeyboard() }
                    .onChange(of: state.terminalOutput.count) { _ in
                        withAnimation {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
                
                // Terminal Input Line
                HStack(spacing: 8) {
                    Text("$")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.green)
                    
                    TextField("Enter command…", text: $inputCommand)
                        .font(.system(size: 14, design: .monospaced))
                        .focused($isFocused)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit {
                            submit()
                        }
                    
                    Button(action: submit) {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.green)
                    }
                    .disabled(inputCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))
            }
            .navigationTitle("Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        state.terminalOutput.removeAll()
                    }) {
                        Text("Clear")
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
    
    private func submit() {
        let cmd = inputCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cmd.isEmpty {
            state.runTerminalCommand(cmd)
            inputCommand = ""
        }
    }
}
