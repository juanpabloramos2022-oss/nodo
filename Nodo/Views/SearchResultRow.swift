import Foundation
import SwiftUI

/// Fila de resultado de la busqueda de Chats (B4-BUS).
///
/// Catalogo de `UI_INVARIANTS.md`: `.resultadoBusqueda(titulo:, vistaPrevia:)`.
/// Se identifica por titulo y vista previa de texto: no recibe ni pinta
/// identificadores. Las pastillas de costo y de modelo, el pin de fijado y la
/// marca del chat abierto son los mismos datos ya resueltos de la lista de
/// siempre (los calcula el nucleo en `datosFila`); esta vista solo los pinta.
struct SearchResultRow: View {
    let titulo: String
    let vistaPrevia: String
    /// La conversacion esta fijada: se pinta el pin de la fila.
    var fijada = false
    /// Costo acumulado del chat, si el nucleo pudo resolverlo con sus precios.
    var costo: Double?
    /// Nombre limpio del ultimo modelo usado. "" si no hay ninguno.
    var modelo = ""
    /// La conversacion es la que esta abierta ahora mismo.
    var esActual = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if esActual {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Tema.acento)
                }

                Text(titulo)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .layoutPriority(1)

                if fijada {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Fijado")
                        .accessibilityIdentifier("fijado-fila")
                }

                Spacer(minLength: 8)

                // Solo se pinta la pastilla cuando el nucleo pudo resolver el
                // costo con los precios del proveedor de ESTE chat.
                if let costo {
                    Text("≈$\(String(format: "%.4f", costo))")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Tema.acento)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Tema.acento.opacity(0.15))
                        .clipShape(Capsule())
                        .layoutPriority(2)
                        .accessibilityIdentifier("costo-fila")
                }
            }

            HStack(spacing: 8) {
                Text(vistaPrevia)
                    .font(.caption)
                    .foregroundStyle(Tema.textoSuave)
                    .lineLimit(1)
                    .layoutPriority(1)

                Spacer(minLength: 8)

                // Etiqueta del ultimo modelo usado en esta conversacion, con
                // el nombre limpio que ya resolvio el nucleo.
                if !modelo.isEmpty {
                    Text(modelo)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Tema.acento.opacity(0.9))
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Tema.acento.opacity(0.12))
                        .clipShape(Capsule())
                        .layoutPriority(2)
                        .accessibilityIdentifier("modelo-fila")
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
