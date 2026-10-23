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
    /// Chats recien creados que aun no se han guardado (sin mensajes).
    ///
    /// La lista solo conoce lo persistido; esta copia en memoria permite volver
    /// atras a un chat vacio recien abierto sin que la ruta lo pierda.
    @State private var nuevas: [UUID: Conversation] = [:]

    var body: some View {
        NavigationStack(path: $ruta) {
            ConversationsView(alNuevo: nueva)
            .navigationDestination(for: UUID.self) { id in
                // El destino se resuelve contra la LISTA, no contra la
                // conversacion abierta: la ruta solo guarda ids y la
                // conversacion abierta puede ser otra (o ninguna). Un chat
                // recien creado por /nuevo aun no esta guardado en la lista,
                // asi que se acepta la conversacion abierta si su id coincide.
                let conversacion = estado.conversaciones.first(where: { $0.id == id })
                    ?? (estado.conversacion.id == id ? estado.conversacion : nuevas[id])

                if let conversacion {
                    ChatView(
                        alGestionarModelos: {
                            bajarTeclado()
                            seleccion = .conexiones
                        },
                        alVolverALista: { ruta.removeAll() }
                    )
                    // La sincronizacion del estado abierto se hace al aparecer
                    // el destino, que es el punto fiable del empuje.
                    .onAppear {
                        if estado.conversacion.id != id {
                            estado.abrir(conversacion)
                        }
                    }
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
        // /nuevo crea la conversacion en EstadoApp y deja aqui su id. La raiz
        // la empuja a la misma pila que usa el boton + Nuevo.
        .onChange(of: estado.idParaAbrir) { _, id in
            guard let id else { return }
            estado.idParaAbrir = nil
            bajarTeclado()
            nuevas[id] = estado.conversacion
            if ruta.last != id {
                ruta.append(id)
            }
        }
        // La barra Listo se declara UNA sola vez en la raiz de esta jerarquia
        // (contrato §4): cubre el buscador de la lista y la caja del chat.
        .conBarraTecladoListo()
    }

    private func nueva(sinMemoria: Bool) {
        bajarTeclado()
        estado.nuevaConversacion(sinMemoria: sinMemoria)
        let id = estado.conversacion.id
        nuevas[id] = estado.conversacion
        ruta.append(id)
    }
}
