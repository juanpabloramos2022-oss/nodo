import SwiftUI

import NodoCore

/// Edicion rapida de la Memoria sin salir de la conversacion.
///
/// POR QUE un borrador local: Cancelar debe descartar sin tocar la
/// configuracion. Solo Guardar escribe `config.systemPrompt` y cierra la hoja
/// (leyes n. 2 y n. 3).
struct HojaMemoriaRapidaView: View {
    @EnvironmentObject private var estado: EstadoApp
    @Environment(\.dismiss) private var dismiss

    @State private var borrador: String
    @State private var original: String
    @State private var cargada: Bool
    /// Titulo de la hoja: "Memoria rapida" desde el chat, "Editar memoria"
    /// cuando se abre desde Mi Contexto.
    private let titulo: String

    /// La presentacion puede pasar el texto actual ya en la mano; si no, la
    /// hoja lo lee al aparecer para no depender del orden de creacion.
    init(textoInicial: String? = nil, titulo: String = "Memoria rápida") {
        let texto = textoInicial ?? ""
        self.titulo = titulo
        _borrador = State(initialValue: texto)
        _original = State(initialValue: texto)
        _cargada = State(initialValue: textoInicial != nil)
    }

    private var hayCambios: Bool {
        borrador != original
    }

    private var estaVacia: Bool {
        borrador.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Misma heuristica ligera que usara Mi Contexto: caracteres / 4, minimo 1.
    private var tokensEstimados: Int {
        max(1, borrador.count / 4)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ZStack(alignment: .topLeading) {
                        if estaVacia {
                            Text("Escribe aquí lo que Nodo debe saber siempre...")
                                .foregroundStyle(Tema.textoSuave)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }

                        TextEditor(text: $borrador)
                            .frame(minHeight: 260)
                            .foregroundStyle(.white)
                            .scrollContentBackground(.hidden)
                            .accessibilityIdentifier("memoria-rapida-editor")
                    }

                    if !estaVacia {
                        HStack {
                            Text("Peso estimado")
                                .foregroundStyle(.white)
                            Spacer()
                            Text("~\(tokensEstimados) tokens est.")
                                .font(.footnote)
                                .monospacedDigit()
                                .foregroundStyle(Tema.textoSuave)
                        }
                    }
                } header: {
                    Text("Memoria")
                } footer: {
                    Text("Se aplica desde el siguiente mensaje que envíes en los chats con Memoria activa.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Tema.fondo.ignoresSafeArea())
            .navigationTitle(titulo)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") {
                        cancelar()
                    }
                    .accessibilityIdentifier("memoria-rapida-cancelar")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Guardar") {
                        guardar()
                    }
                    .fontWeight(.semibold)
                    // Ley n. 3: sin cambios no hay nada que guardar.
                    .disabled(!hayCambios)
                    .accessibilityIdentifier("memoria-rapida-guardar")
                }
            }
            // Hoja propia: declara la barra Listo una sola vez (contrato §4).
            .conBarraTecladoListo()
            .scrollDismissesKeyboard(.interactively)
            .onAppear(perform: cargarSiHaceFalta)
        }
        // Con cambios sin guardar, arrastrar hacia abajo solo esconde el
        // teclado; la hoja no se cierra perdiendo lo escrito.
        .interactiveDismissDisabled(hayCambios)
    }

    private func cargarSiHaceFalta() {
        guard !cargada else { return }
        borrador = estado.config.systemPrompt
        original = estado.config.systemPrompt
        cargada = true
    }

    /// Cancelar descarta el borrador, baja el teclado y cierra la hoja.
    private func cancelar() {
        borrador = original
        cargada = false
        bajarTeclado()
        dismiss()
    }

    /// Guardar escribe la Memoria real y da el cierre normal de hoja.
    private func guardar() {
        estado.config.systemPrompt = borrador
        original = borrador
        cargada = false
        bajarTeclado()
        dismiss()
    }
}
