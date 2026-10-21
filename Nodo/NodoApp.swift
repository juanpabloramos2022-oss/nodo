import SwiftUI

import NodoCore

@main
struct NodoApp: App {
    @StateObject private var estado = EstadoApp()

    var body: some Scene {
        WindowGroup {
            RaizView()
                .environmentObject(estado)
                .preferredColorScheme(.dark)
                .tint(Tema.acento)
        }
    }
}

/// Las tres pantallas principales.
struct RaizView: View {
    var body: some View {
        TabView {
            ChatView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }

            ConversationsView()
                .tabItem { Label("Historial", systemImage: "clock.fill") }

            SettingsView()
                .tabItem { Label("Ajustes", systemImage: "gearshape.fill") }
        }
    }
}
