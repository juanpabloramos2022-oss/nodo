import SwiftUI

import NodoCore

/// Pantalla de Memoria: el texto que Nodo recibe como contexto en todos los chats.
///
/// Es una vista sobre `AppConfig.systemPrompt`, el mismo campo que antes se
/// editaba como "Instrucciones permanentes". No hay campo nuevo: lo que ya
/// estuviera escrito sigue aqui y se guarda solo al cambiar la configuracion.
struct MemoriaView: View {
    @EnvironmentObject private var estado: EstadoApp

    /// Caracteres del texto, contando espacios y saltos de linea.
    private var caracteres: Int {
        estado.config.systemPrompt.count
    }

    private var estaVacia: Bool {
        estado.config.systemPrompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    var body: some View {
        Form {
            Section {
                ZStack(alignment: .topLeading) {
                    if estaVacia {
                        Text("Escribe aqui lo que Nodo debe saber siempre...")
                            .foregroundStyle(Tema.textoSuave)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $estado.config.systemPrompt)
                        .frame(minHeight: 220)
                        .foregroundStyle(.white)
                        .scrollContentBackground(.hidden)
                }
            } header: {
                Text("Memoria")
            } footer: {
                Text("Esto se incluye en todos tus chats. Se aplica desde el siguiente mensaje que envies, tambien en conversaciones ya abiertas.")
            }

            Section {
                HStack {
                    Text("Tamano")
                    Spacer()
                    Text(estaVacia ? "vacia" : "\(caracteres) caracteres")
                        .foregroundStyle(Tema.textoSuave)
                        .monospacedDigit()
                }

                if !estaVacia {
                    Button(role: .destructive) {
                        estado.config.systemPrompt = ""
                    } label: {
                        Label("Borrar memoria", systemImage: "trash")
                    }
                }
            } footer: {
                Text("Si la dejas vacia, no se envia nada.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Tema.fondo.ignoresSafeArea())
        .navigationTitle("Memoria")
        .navigationBarTitleDisplayMode(.inline)
    }
}
