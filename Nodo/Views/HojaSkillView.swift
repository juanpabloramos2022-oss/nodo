import SwiftUI

import NodoCore

/// Editor de una skill local: nombre e instrucciones (§4.4).
///
/// Patron de la casa: trabaja sobre un borrador y solo Guardar escribe en la
/// configuracion. Los errores del nucleo (nombre reservado o slug duplicado) se
/// ensenan dentro de la hoja y no guardan nada. Si la skill ya existe, la hoja
/// ofrece tambien borrarla.
struct HojaSkillView: View {
    @EnvironmentObject private var estado: EstadoApp
    @Environment(\.dismiss) private var dismiss

    private let skill: SkillLocal?
    private let originalNombre: String
    private let originalInstrucciones: String

    @State private var nombre: String
    @State private var instrucciones: String
    @State private var aviso: String?

    init(skill: SkillLocal? = nil) {
        self.skill = skill
        let nombreOriginal = skill?.nombre ?? ""
        let instruccionesOriginales = skill?.instrucciones ?? ""
        self.originalNombre = nombreOriginal
        self.originalInstrucciones = instruccionesOriginales
        _nombre = State(initialValue: nombreOriginal)
        _instrucciones = State(initialValue: instruccionesOriginales)
    }

    private var titulo: String {
        skill == nil ? "Nueva skill" : "Editar skill"
    }

    private var hayCambios: Bool {
        nombre != originalNombre || instrucciones != originalInstrucciones
    }

    /// Ley n. 3: sin cambios (o sin nombre/instrucciones) no hay nada que guardar.
    private var puedeGuardar: Bool {
        hayCambios
            && !nombre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !instrucciones.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// El slug se normaliza igual que lo hara el nucleo al guardar.
    private var slug: String {
        AnalizadorComandos.normalizarSlug(nombre)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let aviso {
                    Section {
                        Text(aviso)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("skill-aviso")
                    }
                }

                Section {
                    TextField("Nombre", text: $nombre)
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("skill-nombre")

                    ZStack(alignment: .topLeading) {
                        if instrucciones.isEmpty {
                            Text("Escribe aquí las instrucciones de la skill...")
                                .foregroundStyle(Tema.textoSuave)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }

                        TextEditor(text: $instrucciones)
                            .frame(minHeight: 200)
                            .foregroundStyle(.white)
                            .scrollContentBackground(.hidden)
                            .accessibilityIdentifier("skill-instrucciones")
                    }
                } header: {
                    Text("Skill")
                } footer: {
                    Text(
                        slug.isEmpty
                            ? "El nombre no genera un identificador invocable."
                            : "Se invocará como /\(slug)."
                    )
                }

                if skill != nil {
                    Section {
                        Button(role: .destructive) {
                            borrar()
                        } label: {
                            Label("Borrar skill", systemImage: "trash")
                        }
                        .accessibilityIdentifier("skill-borrar")
                    }
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
                    .accessibilityIdentifier("skill-cancelar")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Guardar") {
                        guardar()
                    }
                    .fontWeight(.semibold)
                    .disabled(!puedeGuardar)
                    .accessibilityIdentifier("skill-guardar")
                }
            }
            // Hoja propia: declara la barra Listo una sola vez (contrato §4).
            .conBarraTecladoListo()
            .scrollDismissesKeyboard(.interactively)
        }
        // Con cambios sin guardar, arrastrar solo esconde el teclado.
        .interactiveDismissDisabled(hayCambios)
    }

    private func cancelar() {
        bajarTeclado()
        dismiss()
    }

    /// Guarda con las reglas del nucleo. Un error se queda visible en la hoja.
    private func guardar() {
        let resultado = estado.guardarSkill(
            nombre: nombre,
            instrucciones: instrucciones,
            idExistente: skill?.id
        )

        switch resultado {
        case .success:
            aviso = nil
            bajarTeclado()
            dismiss()
        case .failure(let error):
            aviso = error.errorDescription ?? "No se pudo guardar la skill."
        }
    }

    private func borrar() {
        guard let skill else { return }
        estado.borrarSkill(skill)
        bajarTeclado()
        dismiss()
    }
}
