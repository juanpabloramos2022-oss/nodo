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
/// Se declara una vez por contexto de navegacion ACTIVO: la raiz para sus
/// propios campos y cada pantalla empujada que tenga campos suyos (por
/// ejemplo, `ChatView` con su caja de texto). Las barras no se fusionan entre
/// niveles de la pila: la de la raiz no aparece en la pantalla empujada.
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
    /// Se aplica sobre la raiz de cada contexto de navegacion activo: la raiz
    /// del `NavigationStack` para sus campos y tambien cada pantalla empujada
    /// que tenga campos propios. La barra de la raiz no se hereda.
    func conBarraTecladoListo() -> some View {
        modifier(BarraTecladoListo())
    }
}
