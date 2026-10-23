import Foundation
import SwiftUI
import UIKit

import NodoCore

/// Ajustes generales.
struct SettingsView: View {
    @EnvironmentObject private var estado: EstadoApp
    @State private var aviso: String?
    @State private var topeAviso = ""
    @State private var proveedorEnEdicion: ProviderConfig?

    var body: some View {
        NavigationStack {
            Form {
                Section("Proveedores") {
                    ForEach(estado.config.proveedores) { proveedor in
                        Button {
                            // Al abrir el editor el teclado de Ajustes se baja:
                            // la hoja empieza con su propia barra Listo.
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
                    HStack {
                        Text("Tope de aviso por chat")
                            .foregroundStyle(.white)
                        Spacer()
                        TextField("1.00", text: $topeAviso)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.white)
                            .frame(maxWidth: 120)
                            .onChange(of: topeAviso) { _, nuevo in
                                actualizarTope(nuevo)
                            }
                    }
                } header: {
                    Text("Gasto")
                } footer: {
                    Text("Dolares estimados. 0 = sin aviso.")
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
            // Blindaje de la pantalla vieja: la barra Listo vive aqui, una sola
            // vez para toda la jerarquia de Ajustes. Su rediseno es la Fase 4.
            .conBarraTecladoListo()
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                topeAviso = Self.textoDe(estado.config.topeAvisoCostoEfectivo)
            }
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

    /// Primera linea de la memoria, para asomarla en la fila de Ajustes.
    private var vistaPreviaMemoria: String {
        let limpio = estado.config.systemPrompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return limpio.isEmpty ? "vacia" : limpio
    }

    private static func textoDe(_ valor: Double) -> String {
        // Sin redondear: el valor guardado puede tener mas decimales que los
        // que se ven en el campo, y no queremos pisarlo al abrir Ajustes.
        if valor == valor.rounded() {
            return String(format: "%.0f", valor)
        }
        return String(valor)
    }

    /// Guarda el tope mientras se escribe. Un texto invalido no pisa el valor
    /// anterior; vacio vuelve al tope por defecto.
    private func actualizarTope(_ texto: String) {
        let limpio = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        if limpio.isEmpty {
            estado.config.topeAvisoCosto = nil
            return
        }

        let normalizado = limpio.replacingOccurrences(of: ",", with: ".")
        guard let valor = Double(normalizado), valor.isFinite, valor >= 0 else {
            return
        }
        estado.config.topeAvisoCosto = valor
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
            topeAviso = Self.textoDe(estado.config.topeAvisoCostoEfectivo)
            aviso = "Configuracion importada."
        } else {
            aviso = "El texto del portapapeles no es una configuracion."
        }
    }
}
