import SwiftUI

import NodoCore

/// Filas que la hoja rapida de Memoria pinta (H6.3).
///
/// POR QUE un modelo aparte de la vista: la ley pide UNA fila por entrada y esa
/// garantia tiene que poder probarse sin renderizar SwiftUI. El modelo solo
/// traduce `config.memoria` a la lista que se pinta; no toca la configuracion
/// ni el chat.
struct MemoriaRapidaModelo: Equatable {
    /// Una entrada ya lista para pintar, con su identidad y su texto.
    struct Fila: Equatable, Identifiable {
        let id: UUID
        let texto: String
    }

    let filas: [Fila]

    init(memoria: [EntradaMemoria]) {
        filas = memoria.map { Fila(id: $0.id, texto: $0.texto) }
    }

    var vacia: Bool { filas.isEmpty }
}

/// Edicion rapida de la Memoria sin salir de la conversacion (H6.3).
///
/// La hoja ya no edita la Memoria como un bloque unico: muestra la MISMA lista
/// de entradas que Mi Contexto (MEM.1/MEM.4), una fila por entrada. El texto se
/// cambia en el editor de UNA entrada concreta, que tiene su propio Cancelar y
/// Guardar. Cerrar esta hoja no guarda nada: es una lista de consulta.
struct HojaMemoriaRapidaView: View {
    @EnvironmentObject private var estado: EstadoApp
    @Environment(\.dismiss) private var dismiss

    /// Hoja anidada que se esta presentando: editar una entrada o crear otra.
    @State private var hoja: HojaMemoriaRapida?

    private var modelo: MemoriaRapidaModelo {
        MemoriaRapidaModelo(memoria: estado.config.memoria)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Cada entrada se envía por separado a los chats con Memoria activa. Toca una para editarla.")
                        .font(.footnote)
                        .foregroundStyle(Tema.textoSuave)
                        .fixedSize(horizontal: false, vertical: true)

                    if modelo.vacia {
                        Text("Tu memoria está vacía. Añade una entrada para que Nodo la use.")
                            .font(.footnote)
                            .foregroundStyle(Tema.textoSuave)
                            .accessibilityIdentifier("memoria-rapida-vacia")
                    } else {
                        ForEach(modelo.filas) { fila in
                            Button {
                                abrir(fila)
                            } label: {
                                filaEntrada(fila)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("memoria-rapida-entrada")
                            .accessibilityLabel("Editar entrada de Memoria: \(fila.texto)")
                        }
                    }
                } header: {
                    Text("Memoria")
                } footer: {
                    Text("Se aplica desde el siguiente mensaje que envíes en los chats con Memoria activa.")
                }

                Section {
                    Button {
                        hoja = .nueva
                    } label: {
                        Label("Añadir entrada", systemImage: "plus.circle")
                    }
                    .accessibilityIdentifier("memoria-rapida-anadir")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Tema.fondo.ignoresSafeArea())
            .navigationTitle("Memoria rápida")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // H6.6: salida explicita. Cerrar no escribe nada: la lista solo
                // consulta y cada edicion se confirma en su propia hoja.
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cerrar") {
                        cerrar()
                    }
                    .accessibilityIdentifier("memoria-rapida-cerrar")
                }
            }
            // Hoja propia: declara la barra Listo una sola vez (contrato §4).
            .conBarraTecladoListo()
            .scrollDismissesKeyboard(.interactively)
            .sheet(item: $hoja) { hoja in
                switch hoja {
                case .entrada(let entrada):
                    HojaEntradaMemoriaView(entrada: entrada)
                case .nueva:
                    HojaEntradaMemoriaView(entrada: nil)
                }
            }
        }
    }

    /// Fila de una entrada: texto completo (hasta 3 lineas) y acceso al editor.
    private func filaEntrada(_ fila: MemoriaRapidaModelo.Fila) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(fila.texto)
                .foregroundStyle(.white)
                .lineLimit(3)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Tema.textoSuave)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }

    /// Abre el editor buscando la entrada vigente por id.
    ///
    /// No se reusa la copia de la fila como si fuera la entrada: si el texto
    /// cambio mientras la lista estaba en pantalla, el editor tiene que leer el
    /// valor actual, no uno viejo.
    private func abrir(_ fila: MemoriaRapidaModelo.Fila) {
        guard let entrada = estado.config.memoria.first(where: { $0.id == fila.id }) else {
            return
        }
        hoja = .entrada(entrada)
    }

    /// Cerrar solo descarta la hoja; nada se guarda al salir (H6.6).
    private func cerrar() {
        bajarTeclado()
        dismiss()
    }
}

/// Hoja que puede abrir la Memoria rapida: el editor de una entrada concreta o
/// el de una entrada nueva.
private enum HojaMemoriaRapida: Identifiable {
    case entrada(EntradaMemoria)
    case nueva

    var id: String {
        switch self {
        case .entrada(let entrada):
            return "entrada-\(entrada.id.uuidString)"
        case .nueva:
            return "nueva"
        }
    }
}