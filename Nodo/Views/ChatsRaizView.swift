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
            ConversationsView(
                alNuevo: nueva,
                alTemporal: { nuevaTemporal() }
            )
            .navigationDestination(for: UUID.self) { id in
                // El destino se resuelve con la misma regla que usa el estado
                // (lista persistida, conversacion abierta o chat recien creado
                // aun sin guardar). Un resultado de busqueda abre ESA
                // conversacion; la ruta solo guarda ids.
                if let conversacion = estado.conversacionParaAbrir(id, nuevas: nuevas) {
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
        // /nuevo deja aqui el id de la conversacion que hay que mostrar. La
        // raiz la empuja a la misma pila que usa el boton + Nuevo.
        .onChange(of: estado.idParaAbrir) { _, id in
            guard let id else { return }
            estado.idParaAbrir = nil
            bajarTeclado()
            nuevas[id] = estado.conversacion
            if ruta.last != id {
                ruta.append(id)
            }
        }
        // Ramificar reinicia la pila a raiz -> copia, la misma profundidad que
        // abrir un chat desde la lista. El boton de volver dice "Chats" (ley
        // n. 1) y el gesto de borde funciona como siempre.
        .onChange(of: estado.idParaAbrirReiniciandoRuta) { _, id in
            guard let id else { return }
            estado.idParaAbrirReiniciandoRuta = nil
            bajarTeclado()
            nuevas[id] = estado.conversacion
            ruta = [id]
        }
        // La barra Listo se declara UNA sola vez en la raiz de esta jerarquia
        // (contrato §4): cubre el buscador de la lista y la caja del chat.
        .conBarraTecladoListo()
        // B2.2: la salida del Chat Temporal. El boton de volver y el gesto de
        // borde sacan su id de la ruta; cuando el hilo temporal deja de estar
        // en pantalla se cierra y no queda rastro (ni borrador ni copia en
        // `nuevas`). Un chat normal no pasa por aqui: se guarda como siempre.
        .onChange(of: ruta) { _, nuevaRuta in
            guard estado.conversacion.esTemporal,
                  !nuevaRuta.contains(estado.conversacion.id)
            else { return }
            nuevas.removeValue(forKey: estado.conversacion.id)
            estado.cerrarHiloTemporal()
        }
    }

    private func nueva(sinMemoria: Bool) {
        bajarTeclado()
        estado.nuevaConversacion(sinMemoria: sinMemoria)
        let id = estado.conversacion.id
        nuevas[id] = estado.conversacion
        ruta.append(id)
    }

    /// Abre el hilo temporal: un toque desde la lista (R41).
    private func nuevaTemporal() {
        bajarTeclado()
        estado.nuevaConversacionTemporal()
        let id = estado.conversacion.id
        nuevas[id] = estado.conversacion
        ruta.append(id)
    }
}
