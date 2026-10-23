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

/// Las dos pantallas principales de esta fase.
///
/// La lista de chats y la conversacion viven en la MISMA pila (ley n. 1): la
/// raiz es la lista y la conversacion se empuja encima. La raiz definitiva de
/// tres pestanas es la Fase 4; aqui no se adelanta.
struct RaizView: View {
    @State private var seleccion: PestanaRaiz = .chats

    var body: some View {
        TabView(selection: $seleccion) {
            ChatsRaizView(seleccion: $seleccion)
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right.fill") }
                .tag(PestanaRaiz.chats)

            SettingsView()
                .tabItem { Label("Ajustes", systemImage: "gearshape.fill") }
                .tag(PestanaRaiz.ajustes)
        }
    }
}

/// Pestanas de la raiz mientras dure la Fase 2-B1.
enum PestanaRaiz: Hashable {
    case chats
    case ajustes
}
