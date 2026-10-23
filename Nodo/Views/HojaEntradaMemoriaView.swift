import SwiftUI

import NodoCore

/// Editor de UNA entrada de la Memoria (MEM.4).
///
/// POR QUE hoja con borrador: Cancelar no puede tocar la configuracion y solo
/// Guardar escribe la entrada. Es el editor que abre tanto Mi Contexto (MEM.4)
/// como la hoja rapida del chat (H6.3): siempre es UNA entrada, nunca el bloque
/// completo.
struct HojaEntradaMemoriaView: View {
    @EnvironmentObject private var estado: EstadoApp
    @Environment(\.dismiss) private var dismiss

    /// nil = entrada nueva.
    private let entrada: EntradaMemoria?

    @State private var borrador: String
    @State private var original: String

    init(entrada: EntradaMemoria?) {
        self.entrada = entrada
        let texto = entrada?.texto ?? ""
        _borrador = State(initialValue: texto)
        _original = State(initialValue: texto)
    }

    private var esNueva: Bool {
        entrada == nil
    }

    private var hayCambios: Bool {
        borrador != original
    }

    private var estaVacia: Bool {
        borrador.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ZStack(alignment: .topLeading) {
                        if estaVacia {
                            Text("Escribe aquí lo que Nodo debe recordar...")
                                .foregroundStyle(Tema.textoSuave)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }

                        TextEditor(text: $borrador)
                            .frame(minHeight: 180)
                            .foregroundStyle(.white)
                            .scrollContentBackground(.hidden)
                            .accessibilityIdentifier("memoria-entrada-editor")
                    }
                } header: {
                    Text("Entrada de Memoria")
                } footer: {
                    Text("Se aplica desde el siguiente mensaje que envíes en los chats con Memoria activa.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Tema.fondo.ignoresSafeArea())
            .navigationTitle(esNueva ? "Nueva entrada" : "Editar entrada")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") {
                        dismiss()
                    }
                    .accessibilityIdentifier("memoria-entrada-cancelar")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Guardar") {
                        guardar()
                    }
                    .fontWeight(.semibold)
                    // Sin texto no hay entrada que guardar, y sin cambios no
                    // hay nada que escribir.
                    .disabled(estaVacia || !hayCambios)
                    .accessibilityIdentifier("memoria-entrada-guardar")
                }
            }
            // Hoja propia: declara la barra Listo una sola vez (contrato §4).
            .conBarraTecladoListo()
            .scrollDismissesKeyboard(.interactively)
        }
        // Con cambios sin guardar, arrastrar hacia abajo solo esconde el
        // teclado; la hoja no se cierra perdiendo lo escrito.
        .interactiveDismissDisabled(hayCambios)
    }

    private func guardar() {
        let texto = borrador.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !texto.isEmpty else { return }

        if let entrada {
            estado.actualizarEntradaMemoria(id: entrada.id, texto: texto)
        } else {
            estado.agregarEntradaMemoria(texto)
        }

        bajarTeclado()
        dismiss()
    }
}
