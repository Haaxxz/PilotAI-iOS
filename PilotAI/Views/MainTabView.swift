import SwiftUI

public struct MainTabView: View {
    @EnvironmentObject private var state: AppState

    public init() {}

    public var body: some View {
        TabView(selection: selectedTabBinding) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(0)

            ChatView()
                .tabItem { Label("Chat", systemImage: "message.fill") }
                .tag(1)

            CharacterListView()
                .tabItem { Label("Characters", systemImage: "person.crop.circle.fill") }
                .tag(2)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(3)
        }
    }

    private var selectedTabBinding: Binding<Int> {
        Binding(
            get: { state.selectedTab },
            set: { state.selectedTab = min(max($0, 0), 3) }
        )
    }
}
