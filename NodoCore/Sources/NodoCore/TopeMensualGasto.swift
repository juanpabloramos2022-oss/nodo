import Foundation

/// Estado de la banda de tope mensual de gasto (IDEA4).
///
/// POR QUE un tipo aparte en NodoCore: la banda no calcula nada en la vista.
/// `EstadoApp` entrega este valor ya resuelto y la vista solo lo pinta; los
/// tests afirman los mismos estados sin presentar UI. El calculo es puro sobre
/// el acumulado sellado del mes, asi que cambiar de modelo activo no puede
/// moverlo.
public struct TopeMensualGasto: Equatable {
    /// Los cuatro estados posibles de la banda.
    public enum Estado: String, Equatable, CaseIterable {
        /// El dueno no fijo tope: no hay banda.
        case sinTope
        /// Hay tope y el acumulado esta por debajo del 80 %.
        case bajoUmbral
        /// El acumulado alcanzo el 80 % del tope y todavia no el 100 %.
        case aviso
        /// El acumulado alcanzo (o supero) el 100 % del tope.
        case alcanzado
    }

    /// Tope mensual guardado, en USD. `nil` cuando no hay tope.
    public let tope: Double?
    /// Gasto sellado del mes en curso, en USD.
    public let acumulado: Double
    /// Fraccion consumida del tope, acotada a 0...1 para la barra.
    public let fraccion: Double
    /// Estado de la banda.
    public let estado: Estado

    /// Nota visible de la configuracion. El tope NO refleja cargos fuera de
    /// esta app: solo el gasto que Nodo sello en este dispositivo.
    public static let nota =
        "Calculado sobre el gasto sellado en este dispositivo."

    /// True cuando la banda esta visible (aviso o tope alcanzado).
    public var visible: Bool {
        estado == .aviso || estado == .alcanzado
    }

    /// La banda NUNCA bloquea el envio: el dueno decide si sigue.
    ///
    /// Es una invariante del producto y se declara aqui para que ninguna vista
    /// pueda leer este tipo como una puerta de envio.
    public var bloqueaEnvio: Bool { false }

    /// Porcentaje entero consumido, para el texto de la banda.
    public var porcentajeEntero: Int {
        guard let tope, tope > 0, acumulado.isFinite else { return 0 }
        return Int((acumulado / tope * 100).rounded())
    }

    /// Texto de la banda. `nil` cuando no hay nada que avisar.
    public var texto: String? {
        switch estado {
        case .sinTope, .bajoUmbral:
            return nil
        case .aviso:
            return "Llevas el \(porcentajeEntero) % de tu tope mensual de gasto. "
                + "Puedes seguir enviando."
        case .alcanzado:
            return "Tope mensual alcanzado. Enviar sigue siendo tu decisión."
        }
    }

    /// Calcula el estado a partir del tope guardado y del acumulado sellado.
    ///
    /// Los umbrales son inclusivos: exactamente el 80 % ya es aviso y
    /// exactamente el 100 % ya es tope alcanzado.
    public static func calcular(
        tope: Double?,
        acumulado: Double
    ) -> TopeMensualGasto {
        let gasto = acumulado.isFinite ? max(0, acumulado) : 0

        guard let tope, tope.isFinite, tope > 0 else {
            return TopeMensualGasto(
                tope: nil,
                acumulado: gasto,
                fraccion: 0,
                estado: .sinTope
            )
        }

        let fraccion = min(max(gasto / tope, 0), 1)
        let estado: Estado
        if gasto >= tope {
            estado = .alcanzado
        } else if gasto >= tope * 0.8 {
            estado = .aviso
        } else {
            estado = .bajoUmbral
        }

        return TopeMensualGasto(
            tope: tope,
            acumulado: gasto,
            fraccion: fraccion,
            estado: estado
        )
    }
}
