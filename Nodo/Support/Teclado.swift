import SwiftUI
import UIKit

/// Baja el teclado en el acto, sin tocar el texto que se esta escribiendo.
///
/// Se hace por el first responder de UIKit porque los teclados `.decimalPad` y
/// `.numberPad` no traen tecla de retorno: sin esta salida, un campo numerico
/// puede dejar al usuario atrapado con el teclado abierto.
func bajarTeclado() {
    _ = UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder),
        to: nil,
        from: nil,
        for: nil
    )
}

/// Barra pegada sobre el teclado con el boton "Listo" (ley n. 4).
///
/// Se declara una sola vez en la raiz de cada jerarquia de navegacion. Si se
/// repite en una vista hija, UIKit acaba pintando barras accesorias duplicadas.
struct BarraTecladoListo: ViewModifier {
    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Listo") {
                    bajarTeclado()
                }
                .fontWeight(.semibold)
                // Identificador estable para que el test de captura compruebe
                // la barra sin depender del idioma ni del arbol de UIKit.
                .accessibilityIdentifier("teclado-listo")
            }
        }
    }
}

extension View {
    /// Anade la barra de teclado con "Listo" a la vista que la aplica.
    ///
    /// El sitio correcto es la raiz de cada `NavigationStack` (la vista que
    /// contiene el stack), no cada pantalla hija.
    func conBarraTecladoListo() -> some View {
        modifier(BarraTecladoListo())
    }
}
