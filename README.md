# PilotAI for iOS

PilotAI is a native iOS client for the **PilotAI** mobile autonomous agent and AI assistant platform. Built from scratch with Swift & SwiftUI, it mirrors the design, chat interactions, model provider matrix, roleplay companions, persistent memories, and data backup schemas of the Android PilotAI APK.

---

## Features

- **Direct Chat & Autonomous Agent**:
  - Multi-turn conversation management with real-time SSE streaming.
  - Expandable **Thinking Process** blocks (DeepSeek-R1, OpenAI o1/o3-mini reasoning tokens).
  - Visual **Tool Invocation** status cards and tool output inspector.
  - Markdown formatting and one-tap code copying.
- **Model Providers**:
  - Out-of-the-box templates for **OpenAI**, **Anthropic**, **DeepSeek**, **Kimi (Moonshot)**, **Alibaba Bailian**, **MiniMax**, **SiliconFlow**, and **OpenRouter**.
  - Local endpoint support (**Ollama**, **LM Studio**) via LAN.
  - Custom HTTP request headers with per-header key/value pairs.
- **Roleplay Characters**:
  - Built-in personas including **Xiaoman**, **Traveler**, and **Kernel Pilot**.
  - Character detail inspector and dedicated conversation launcher.
- **Core Memory**:
  - Persistent user memory markdown editor.
  - Automatic prompt injection across all conversations with estimated token accounting.
- **Interactive Terminal**:
  - Honest iOS-sandboxed console with command history and monospace formatting; arbitrary commands are sent only through an explicitly configured remote gateway.
- **Shared Browser & Private Workspace**:
  - Persistent WebKit browser session shared by the UI and agent, with per-action approval, takeover, bounded page observations, and safe HTTP(S)-only navigation.
  - Revision-protected private workspace with bounded list/read/write/rename operations, secure path handling, and native file import/export.
- **MCP**:
  - Streamable HTTP discovery and tool calls with Bearer authentication, modern/legacy protocol negotiation, bounded results, per-tool enablement, and frozen per-run catalogs.
- **Cross-Platform Backup Compatibility**:
  - Imports and exports `.json` backups fully compatible with PilotAI / Eta Android backups (`format: "eta-backup"`, `schemaVersion: 2`).

---

## Architecture & Project Structure

```text
PilotAI-iOS/
├── .github/workflows/
│   └── ios-build.yml       # Automated GitHub Actions workflow for macOS CI & IPA export
├── PilotAI/
│   ├── App/
│   │   ├── PilotAIApp.swift    # @main application lifecycle
│   │   └── AppState.swift      # Global environment observable store
│   ├── Models/
│   │   ├── Message.swift       # Message, Role, ToolCall definitions
│   │   ├── Conversation.swift  # Conversation thread state
│   │   ├── Provider.swift      # Provider and Model configurations
│   │   ├── Character.swift     # Roleplay character specs
│   │   ├── Memory.swift        # Core memory schema
│   │   └── Settings.swift      # Application preferences
│   ├── Services/
│   │   ├── OpenAIService.swift      # Provider transport and model discovery
│   │   ├── ProviderRequestBuilder.swift
│   │   ├── ProviderStreamParser.swift
│   │   ├── AgentEngine.swift        # Agent loop and memory injection orchestrator
│   │   ├── IOSRuntimeToolService.swift
│   │   ├── IOSMCPService.swift
│   │   ├── IOSBrowserService.swift
│   │   ├── WorkspaceService.swift
│   │   ├── RoleplayContext.swift
│   │   ├── StorageService.swift     # Local document persistence
│   │   └── BackupService.swift      # JSON backup import/export
│   ├── Views/
│   │   ├── MainTabView.swift        # Tab bar navigation
│   │   ├── Chat/                    # ChatView, MessageBubble, ThinkingView, InputBar
│   │   ├── Characters/              # Character list and detail views
│   │   ├── Memory/                  # Markdown memory editor
│   │   ├── Terminal/                # Console interface
│   │   ├── Providers/               # Model provider credentials and endpoints
│   │   └── Settings/                # Appearance, backup, tools, MCP, and app info
│   └── Resources/
│       ├── Info.plist               # Permissions, identifiers, and device configs
│       ├── LaunchScreen.storyboard  # System launch interface
│       └── Assets.xcassets/         # App icons and color palettes
├── PilotAI.xcodeproj/
│   └── project.pbxproj              # Native Xcode project
├── scripts/
│   └── package_ipa.sh               # Local IPA packaging script (Linux & macOS)
└── build/
    └── PilotAI.ipa                  # Generated iOS Application Archive
```

---

## Building

### Option A: Native macOS & Xcode
1. Open `PilotAI.xcodeproj` in Xcode 15.0 or later on macOS.
2. Select your development team under **Signing & Capabilities**.
3. Select an iOS device or simulator, and press **Cmd + R** to run.
4. To export an archive: **Product &rarr; Archive &rarr; Distribute App &rarr; Ad Hoc or Sideloading**.

### Option B: GitHub Actions Cloud CI
Push to `main`, open **Actions → Build SwiftUI PilotAI iOS IPA**, or start it with **Run workflow**. The macOS runner runs the XCTest target, archives the native SwiftUI `PilotAI` Xcode target, packages the archived `.app` as an unsigned IPA, and uploads `PilotAI-unsigned.ipa` as the `PilotAI-iOS-IPA` artifact.

The Linux script is only a packaging/bootstrap smoke check; it does not compile the SwiftUI sources and must not be used as evidence of an iOS build.

### Option C: GitHub Actions details
The workflow also runs on pull requests targeting `main`, so source and project-file changes are checked before merge. Signing is disabled in CI; install the artifact only after signing it with your chosen distribution or sideloading workflow.

---

## Installation / Sideloading
The GitHub Actions artifact is an **unsigned** `PilotAI-unsigned.ipa`; sign it with your sideloading/distribution tool before installing on a device:
- **TrollStore** (iOS 14.0 &ndash; 17.0)
- **AltStore / SideStore**
- **Scarlet / Sideloadly**
