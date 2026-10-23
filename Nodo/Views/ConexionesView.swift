import Foundation
import SwiftUI
import UIKit

import NodoCore

/// Pestana Conexiones: solo fontaneria.
///
/// En esta sesion conserva la pantalla de proveedores y MCP que ya existia, sin
/// las secciones de Memoria y Tope: esos controles viven unicamente en Mi
/// Contexto (§3.5/§3.6). La reconstruccion completa de la pestana (tarjetas
/// agrupadas y Respaldo) es la sesion 4.5/4.7.
struct ConexionesView: View {
    @EnvironmentObject private var estado: EstadoApp
    @State private var aviso: String?
    @State private var proveedorEnEdicion: ProviderConfig?

    var body: some View {
        NavigationStack {
            Form {
                Section("Proveedores") {
                    ForEach(estado.config.proveedores) { proveedor in
                        Button {
                            // Al abrir el editor el teclado de Conexiones se
                            // baja: la hoja empieza con su propia barra Listo.
                            bajarTeclado()
                            proveedorEnEdicion = proveedor
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
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(Tema.textoSuave)
                                    .accessibilityHidden(true)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("proveedor-fila")
                        .accessibilityLabel("Editar \(proveedor.nombre)")
                    }
                    .onDelete { indices in
                        for indice in indices {
                            estado.borrarProveedor(estado.config.proveedores[indice])
                        }
                    }

                    Button {
                        // El proveedor nuevo se crea como borrador: solo entra
                        // en la configuracion si el editor confirma Guardar.
                        bajarTeclado()
                        proveedorEnEdicion = estado.proveedorNuevo()
                    } label: {
                        Label("Anadir proveedor", systemImage: "plus.circle")
                    }
                    .accessibilityIdentifier("anadir-proveedor")
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
            .navigationTitle("Conexiones")
            // La barra Listo vive aqui, una sola vez para toda la jerarquia de
            // Conexiones. Su rediseno completo es la sesion 4.5/4.7.
            .conBarraTecladoListo()
            .scrollDismissesKeyboard(.interactively)
            .sheet(item: $proveedorEnEdicion) { proveedor in
                EditorProveedorView(proveedor: proveedor)
            }
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
        if estado.importarConfig(texto) {
            aviso = "Configuracion importada."
        } else {
            aviso = "El texto del portapapeles no es una configuracion."
        }
    }
}
