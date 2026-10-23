import SwiftUI
import UIKit

import NodoCore

/// Hoja de compartir del sistema para /exportar.
///
/// Se envuelve `UIActivityViewController` porque el comando se ejecuta desde la
/// caja y no hay un boton `ShareLink` visible que tocar: la hoja tiene que
/// presentarse sola con el texto de la conversacion.
struct HojaCompartir: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let texto: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controlador = UIActivityViewController(
            activityItems: [texto],
            applicationActivities: nil
        )
        // Al terminar (o cancelar) se cierra tambien la hoja de SwiftUI.
        controlador.completionWithItemsHandler = { _, _, _, _ in
            dismiss()
        }
        return controlador
    }

    func updateUIViewController(_ controlador: UIActivityViewController, context: Context) {}
}
