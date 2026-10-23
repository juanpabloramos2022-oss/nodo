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

/// Raiz definitiva de la app: tres pestanas, cada una con su propia pila.
///
/// Chats conserva la pila de la Fase 2 (lista -> conversacion). Mi Contexto
/// reune Memoria, Tope y Skills. Conexiones queda como fontaneria; su
/// reconstruccion completa llega en la sesion 4.5/4.7.
struct RaizView: View {
    @State private var seleccion: PestanaRaiz = .chats

    var body: some View {
        TabView(selection: $seleccion) {
            ChatsRaizView(seleccion: $seleccion)
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right.fill") }
                .tag(PestanaRaiz.chats)

            MiContextoView()
                .tabItem { Label("Mi Contexto", systemImage: "brain") }
                .tag(PestanaRaiz.contexto)

            ConexionesView()
                .tabItem { Label("Conexiones", systemImage: "network") }
                .tag(PestanaRaiz.conexiones)
        }
    }
}

/// Pestanas de la raiz definitiva (SPEC §3).
enum PestanaRaiz: Hashable {
    case chats
    case contexto
    case conexiones
}
