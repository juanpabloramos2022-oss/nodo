import SwiftUI
import UIKit

import NodoCore

/// Ajustes generales.
struct SettingsView: View {
    @EnvironmentObject private var estado: EstadoApp
    @State private var aviso: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Proveedores") {
                    ForEach(estado.config.proveedores) { proveedor in
                        NavigationLink {
                            EditorProveedorView(proveedor: proveedor)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(proveedor.nombre)
                                        .foregroundStyle(.white)
                                    Text(proveedor.modelo.isEmpty ? "sin modelo" : proveedor.modelo)
                                        .font(.caption)
                                        .foregroundStyle(Tema.textoSuave)
                                }
                                Spacer()
                                if estado.config.proveedorActivo == proveedor.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Tema.acento)
                                }
                            }
                        }
                    }
                    .onDelete { indices in
                        for indice in indices {
                            estado.borrarProveedor(estado.config.proveedores[indice])
                        }
                    }

                    Button {
                        estado.anadirProveedor()
                    } label: {
                        Label("Anadir proveedor", systemImage: "plus.circle")
                    }
                }

                Section("Servidor remoto") {
                    NavigationLink {
                        ServerView()
                    } label: {
                        HStack {
                            Text("Herramientas por MCP")
                            Spacer()
                            Text(estado.config.servidor.estaConfigurado ? "activo" : "sin configurar")
                                .font(.caption)
                                .foregroundStyle(
                                    estado.config.servidor.estaConfigurado
                                        ? Tema.acento
                                        : Tema.textoSuave
                                )
                        }
                    }
                }

                Section {
                    NavigationLink {
                        MemoriaView()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Memoria")
                                    .foregroundStyle(.white)
                                Text(vistaPreviaMemoria)
                                    .font(.caption)
                                    .foregroundStyle(Tema.textoSuave)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                    }
                } header: {
                    Text("Contexto")
                } footer: {
                    Text("Esto se incluye en todos tus chats.")
                }

                Section {
                    Button {
                        copiarConfig()
                    } label: {
                        Label("Copiar configuracion", systemImage: "doc.on.doc")
                    }

                    Button {
                        pegarConfig()
                    } label: {
                        Label("Importar del portapapeles", systemImage: "doc.on.clipboard")
                    }
                } header: {
                    Text("Mover a otro telefono")
                } footer: {
                    Text("La configuracion no incluye claves: se vuelven a introducir en el telefono nuevo.")
                }

                Section {
                    Text(NodoVersion.descripcion)
                        .foregroundStyle(Tema.textoSuave)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Tema.fondo.ignoresSafeArea())
            .navigationTitle("Ajustes")
            .alert(
                "Nodo",
                isPresented: Binding(
                    get: { aviso != nil },
                    set: { if !$0 { aviso = nil } }
                )
            ) {
                Button("Vale") { aviso = nil }
            } message: {
                Text(aviso ?? "")
            }
        }
    }

    /// Primera linea de la memoria, para asomarla en la fila de Ajustes.
    private var vistaPreviaMemoria: String {
        let limpio = estado.config.systemPrompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return limpio.isEmpty ? "vacia" : limpio
    }

    private func copiarConfig() {
        guard let texto = estado.exportarConfig() else {
            aviso = "No se pudo generar la configuracion."
            return
        }
        UIPasteboard.general.string = texto
        aviso = "Configuracion copiada. No contiene claves."
    }

    private func pegarConfig() {
        guard let texto = UIPasteboard.general.string, !texto.isEmpty else {
            aviso = "El portapapeles esta vacio."
            return
        }
        aviso = estado.importarConfig(texto)
            ? "Configuracion importada."
            : "El texto del portapapeles no es una configuracion."
    }
}
