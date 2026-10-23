import Foundation
import SwiftUI

import NodoCore

/// Lista de modelos compartida por la pildora, la Tarjeta de Bienvenida y la
/// hoja de /modelos.
///
/// Es una funcion `@ViewBuilder` y no una vista contenedora a proposito: al
/// emitir los botones directamente, el `Menu` nativo y la `List` los tratan
/// como filas independientes y no como un unico elemento compuesto.
@ViewBuilder
func listaModelos(
    proveedores: [ProviderConfig],
    activo: UUID?,
    alElegir: @escaping (ProviderConfig) -> Void,
    alGestionar: @escaping () -> Void
) -> some View {
    ForEach(proveedores) { proveedor in
        Button {
            alElegir(proveedor)
        } label: {
            if activo == proveedor.id {
                Label(nombreDeModelo(proveedor), systemImage: "checkmark")
            } else {
                Text(nombreDeModelo(proveedor))
            }
        }
        .accessibilityIdentifier("modelo-\(proveedor.id.uuidString)")
    }

    Divider()

    Button {
        alGestionar()
    } label: {
        Label("Gestionar modelos…", systemImage: "slider.horizontal.3")
    }
    .accessibilityIdentifier("gestionar-modelos")
}

private func nombreDeModelo(_ proveedor: ProviderConfig) -> String {
    let limpio = NombresLimpios.modelo(proveedor.modelo)
    guard limpio.isEmpty else { return limpio }
    return NombresLimpios.proveedor(
        nombre: proveedor.nombre,
        baseURL: proveedor.baseURL
    )
}

/// Hoja modal con la misma lista de modelos de la pildora (/modelos, §4.2).
///
/// Elegir cambia el modelo y cierra; Gestionar modelos… cierra y salta a
/// Conexiones por el callback que ya usa la cabecera.
struct HojaModelosView: View {
    @EnvironmentObject private var estado: EstadoApp
    @Environment(\.dismiss) private var dismiss

    let alGestionarModelos: () -> Void

    var body: some View {
        NavigationStack {
            List {
                listaModelos(
                    proveedores: estado.config.proveedores,
                    activo: estado.config.proveedorSeleccionado?.id,
                    alElegir: { proveedor in
                        estado.cambiarProveedor(proveedor)
                        dismiss()
                    },
                    alGestionar: {
                        dismiss()
                        alGestionarModelos()
                    }
                )
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Tema.fondo.ignoresSafeArea())
            .navigationTitle("Modelos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cerrar") {
                        dismiss()
                    }
                    .accessibilityIdentifier("modelos-cerrar")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
