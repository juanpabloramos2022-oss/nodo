import Foundation
import SwiftUI

import NodoCore

/// Revisión de compactación de la Memoria (B2.5).
///
/// Es la MISMA lista de Mi Contexto agrupada por categoría, con el editor y el
/// borrado que ya existen por entrada: no añade controles nuevos ni una forma
/// distinta de gestionar la memoria. La banda de aviso de Mi Contexto lleva
/// aquí en un solo toque cuando N llega a 40.
///
/// Nada se borra, fusiona ni resume solo: compactar es un acto del dueño, y
/// esta pantalla solo le pone delante lo que ocupa espacio y cómo liberarlo.
struct RevisionCompactacionView: View {
    @EnvironmentObject private var estado: EstadoApp

    @State private var entradaEnEdicion: EntradaMemoria?
    @State private var entradaAConfirmar: EntradaMemoria?

    private var grupos: [GrupoMemoria] {
        estado.estadoMemoria.grupos
    }

    var body: some View {
        Form {
            Section {
                Text(estado.estadoMemoria.contador)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("compactacion-contador")

                if estado.estadoMemoria.enTope {
                    Text("Tope alcanzado: borra una entrada para que se puedan guardar datos nuevos.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("compactacion-tope")
                }
            } header: {
                Text("Revisión de compactación")
            } footer: {
                Text("Toca una entrada para editarla o desliza para borrarla. Nada se borra solo: liberar espacio es tu decisión.")
            }

            if grupos.isEmpty {
                Section {
                    Text("Tu memoria está vacía.")
                        .font(.footnote)
                        .foregroundStyle(Tema.textoSuave)
                        .accessibilityIdentifier("compactacion-vacia")
                }
            } else {
                ForEach(grupos) { grupo in
                    Section {
                        ForEach(grupo.entradas) { entrada in
                            Button {
                                entradaEnEdicion = entrada
                            } label: {
                                FilaEntradaMemoria(entrada: entrada)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("compactacion-entrada")
                            .accessibilityLabel(
                                "Editar entrada de Memoria: \(entrada.texto)"
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    entradaAConfirmar = entrada
                                } label: {
                                    Label("Borrar", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        Text(grupo.titulo)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Tema.fondo.ignoresSafeArea())
        .navigationTitle("Revisar memoria")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $entradaEnEdicion) { entrada in
            HojaEntradaMemoriaView(entrada: entrada)
        }
        .confirmationDialog(
            "¿Borrar esta entrada de Memoria?",
            isPresented: Binding(
                get: { entradaAConfirmar != nil },
                set: { presentado in
                    if !presentado { entradaAConfirmar = nil }
                }
            ),
            titleVisibility: .visible,
            presenting: entradaAConfirmar
        ) { entrada in
            Button("Borrar", role: .destructive) {
                estado.borrarEntradaMemoria(id: entrada.id)
                entradaAConfirmar = nil
            }
            Button("Cancelar", role: .cancel) {
                entradaAConfirmar = nil
            }
        } message: { entrada in
            Text("Se quitará de la Memoria: \(entrada.texto)")
        }
    }
}
