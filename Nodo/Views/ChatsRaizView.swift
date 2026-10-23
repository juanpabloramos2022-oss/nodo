import Foundation
import SwiftUI

import NodoCore

/// Raiz de la pestana Chats: una sola pila para la lista y la conversacion.
///
/// La lista es la raiz y la conversacion se empuja con `navigationDestination`.
/// Asi el boton nativo de volver dice "Chats" y el gesto de borde izquierdo
/// funciona igual con el teclado abierto (ley n. 1).
struct ChatsRaizView: View {
    @EnvironmentObject private var estado: EstadoApp
    @Binding var seleccion: PestanaRaiz

    /// La ruta guarda ids, no conversaciones: es lo que espera la pila.
    @State private var ruta: [UUID] = []

    var body: some View {
        NavigationStack(path: $ruta) {
            ConversationsView(
                alAbrir: abrir,
                alNuevo: nueva
            )
            .navigationDestination(for: UUID.self) { id in
                if estado.conversacion.id == id {
                    ChatView(
                        alGestionarModelos: {
                            bajarTeclado()
                            seleccion = .ajustes
                        },
                        alVolverALista: { ruta.removeAll() }
                    )
                } else {
                    // La conversacion se borro o la ruta quedo obsoleta.
                    EstadoVacio(
                        icono: "bubble.left",
                        titulo: "Chat no disponible",
                        detalle: "Vuelve a Chats para abrir otra conversacion."
                    )
                    .background(Tema.fondo.ignoresSafeArea())
                }
            }
        }
        // La barra Listo se declara UNA sola vez en la raiz de esta jerarquia
        // (contrato §4): cubre el buscador de la lista y la caja del chat.
        .conBarraTecladoListo()
    }

    private func abrir(_ conversacion: Conversation) {
        bajarTeclado()
        estado.abrir(conversacion)
        ruta.append(conversacion.id)
    }

    private func nueva(sinMemoria: Bool) {
        bajarTeclado()
        estado.nuevaConversacion(sinMemoria: sinMemoria)
        ruta.append(estado.conversacion.id)
    }
}
