import Foundation

/// Contadores globales de gasto (§3.5).
///
/// Son dos acumuladores locales que suman cada `usage` de cualquier chat:
/// - `delDia`: gasto del dia indicado en `fechaDelDia`.
/// - `desdeReinicio`: gasto desde que se pulso [Reiniciar contador].
///
/// La fecha se recibe como parametro en `registrar(costo:hoy:)`; la logica no
/// lee el reloj, para que los tests sean deterministas. El contador vive en
/// `AppConfig`, no en las conversaciones: borrar un chat no resta su gasto.
public struct ContadoresGasto: Codable, Equatable {
    /// Gasto acumulado del dia `fechaDelDia`.
    public var delDia: Double
    /// Dia del contador diario, en formato "yyyy-MM-dd".
    public var fechaDelDia: String
    /// Gasto acumulado desde el ultimo reinicio manual.
    public var desdeReinicio: Double

    public init(
        delDia: Double = 0,
        fechaDelDia: String = "",
        desdeReinicio: Double = 0
    ) {
        self.delDia = delDia
        self.fechaDelDia = fechaDelDia
        self.desdeReinicio = desdeReinicio
    }

    /// Contadores a cero, tal como nacen en una configuracion limpia.
    public static let vacio = ContadoresGasto()

    /// Suma un costo a los dos contadores.
    ///
    /// Si `hoy` no es el dia guardado, el contador del dia arranca de cero con
    /// ese costo y se anota la fecha nueva; el acumulado desde el reinicio
    /// siempre suma, porque reiniciar el dia no equivale a reiniciar el total.
    public mutating func registrar(costo: Double, hoy: String) {
        if hoy != fechaDelDia {
            delDia = costo
            fechaDelDia = hoy
        } else {
            delDia += costo
        }
        desdeReinicio += costo
    }

    /// Pone a cero solo el acumulado desde el reinicio.
    ///
    /// El contador del dia no se toca: ese se reinicia solo al cambiar la fecha.
    public mutating func reiniciar() {
        desdeReinicio = 0
    }
}
