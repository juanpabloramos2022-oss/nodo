import SwiftUI

import NodoCore

@main
struct NodoApp: App {
    // El gancho de capturas solo devuelve un estado si la app se lanzo con
    // `-CapturasPrueba`; en cualquier otro arranque vale nil y todo sigue igual.
    @StateObject private var estado = EstadoApp(
        estadoDePrueba: EstadosDePrueba.estadoSolicitado()
    )

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
