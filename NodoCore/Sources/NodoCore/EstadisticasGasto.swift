import Foundation

/// Una fila del reparto por modelo de las estadisticas locales (IDEA5).
///
/// `mensajes` es el numero de llamadas cerradas que el libro de cada
/// conversacion atribuye a ese modelo; `usd` es la suma de sus sellos. El
/// nombre se limpia para ensenar (`vendedor/modelo` -> `modelo`) sin tocar la
/// clave cruda, la misma que usa el libro por modelo.
public struct FilaModeloEstadistica: Equatable, Identifiable {
    /// Identificador crudo del modelo tal como lo tenia el proveedor.
    public let clave: String
    /// Nombre listo para pantalla. "Sin modelo" si la llamada no traia uno.
    public let nombre: String
    /// Llamadas cerradas de ese modelo en el tramo.
    public let mensajes: Int
    /// Suma de los sellos de esas llamadas, en USD.
    public let usd: Double

    public var id: String { clave }

    public init(
        clave: String,
        nombre: String,
        mensajes: Int,
        usd: Double
    ) {
        self.clave = clave
        self.nombre = nombre
        self.mensajes = mensajes
        self.usd = usd
    }
}

/// Un tramo de las estadisticas: Hoy, Este mes o el Total historico.
///
/// POR QUE un tipo aparte y no tres propiedades sueltas: la vista pinta el
/// mismo bloque tres veces (conteo + reparto por modelo) y los tests afirman la
/// misma forma en los tres periodos.
public struct TramoEstadistica: Equatable {
    /// Numero de mensajes/pasos sellados del tramo.
    public let mensajes: Int
    /// Suma de los sellos del tramo, en USD.
    public let usd: Double
    /// Reparto por modelo, ordenado de mayor a menor gasto.
    public let modelos: [FilaModeloEstadistica]

    public init(
        mensajes: Int,
        usd: Double,
        modelos: [FilaModeloEstadistica]
    ) {
        self.mensajes = mensajes
        self.usd = usd
        self.modelos = modelos
    }
}

/// Estadisticas locales de uso y gasto (IDEA5).
///
/// POR QUE un tipo puro en NodoCore: la agregacion corre SOLO al presentar la
/// vista Gasto, nunca por token de streaming, y no se persiste ningun agregado
/// derivado. Se calcula sobre los sellos y los metadatos (fecha y modelo) de
/// las conversaciones QUE SE PERSISTEN: un Chat Temporal no aparece nunca en
/// el desglose, porque `Conversation.sePersiste` lo deja fuera antes de contar.
///
/// El dolar de cada mensaje sale del lector unico `CostoEstimado.costoSellado`:
/// si el mensaje ya tiene sello, ese sello manda; si es legado sin sellar, se
/// valora con los precios de SU proveedor, nunca con el activo. El mensaje sin
/// costo resoluble igual se cuenta (es una llamada real) y aporta USD cero.
public struct EstadisticasGasto: Equatable {
    /// Hoy (misma clave de dia local que usa el libro).
    public let hoy: TramoEstadistica
    /// El mes en curso (misma clave de mes local que usa el libro).
    public let mes: TramoEstadistica
    /// Todo el historial persistido.
    public let total: TramoEstadistica

    /// Rotulo visible de los agregados. NUNCA se presentan como factura del
    /// proveedor: son los sellos de este dispositivo.
    public static let rotulo = "Gasto sellado local"

    public init(
        hoy: TramoEstadistica,
        mes: TramoEstadistica,
        total: TramoEstadistica
    ) {
        self.hoy = hoy
        self.mes = mes
        self.total = total
    }

    /// Agrega los sellos de las conversaciones persistidas en los tres tramos.
    ///
    /// `ahora` se recibe por parametro para que las pruebas sean
    /// deterministas; la app pasa la fecha real. El unico filtro de entrada es
    /// `sePersiste`: los hilos temporales se descartan aqui, antes de contar,
    /// de modo que no pueden dejar ni un mensaje en el desglose (B2.2).
    public static func desde(
        conversaciones: [Conversation],
        proveedores: [ProviderConfig],
        ahora: Date = Date()
    ) -> EstadisticasGasto {
        let claveHoy = UsoApp.claveDia(ahora)
        let claveMes = UsoApp.claveMes(ahora)

        var hoy = Acumulador()
        var mes = Acumulador()
        var total = Acumulador()

        for conversacion in conversaciones where conversacion.sePersiste {
            let proveedorDelChat = conversacion.proveedorID

            for mensaje in conversacion.mensajes where mensaje.uso != nil {
                let modeloID = mensaje.proveedorID ?? proveedorDelChat
                let clave = proveedores
                    .first(where: { $0.id == modeloID })?
                    .modelo ?? ""
                let usd = CostoEstimado.costoSellado(
                    de: mensaje,
                    proveedores: proveedores,
                    proveedorDelChat: proveedorDelChat
                ) ?? 0

                total.sumar(clave: clave, usd: usd)
                if UsoApp.claveMes(mensaje.fecha) == claveMes {
                    mes.sumar(clave: clave, usd: usd)
                }
                if UsoApp.claveDia(mensaje.fecha) == claveHoy {
                    hoy.sumar(clave: clave, usd: usd)
                }
            }
        }

        return EstadisticasGasto(
            hoy: hoy.tramo(),
            mes: mes.tramo(),
            total: total.tramo()
        )
    }

    /// Sumador privado de un tramo: conteo, dolares y reparto por modelo.
    private struct Acumulador {
        private var mensajes = 0
        private var usd = 0.0
        private var porModelo: [String: (mensajes: Int, usd: Double)] = [:]

        mutating func sumar(clave: String, usd: Double) {
            mensajes += 1
            self.usd += usd
            var fila = porModelo[clave] ?? (mensajes: 0, usd: 0)
            fila.mensajes += 1
            fila.usd += usd
            porModelo[clave] = fila
        }

        func tramo() -> TramoEstadistica {
            let filas = porModelo.map { clave, fila in
                FilaModeloEstadistica(
                    clave: clave,
                    nombre: nombreDeModelo(clave),
                    mensajes: fila.mensajes,
                    usd: fila.usd
                )
            }
            let ordenadas = filas.sorted { izquierda, derecha in
                if izquierda.usd != derecha.usd {
                    return izquierda.usd > derecha.usd
                }
                if izquierda.mensajes != derecha.mensajes {
                    return izquierda.mensajes > derecha.mensajes
                }
                if izquierda.nombre != derecha.nombre {
                    return izquierda.nombre < derecha.nombre
                }
                return izquierda.clave < derecha.clave
            }
            return TramoEstadistica(
                mensajes: mensajes,
                usd: usd,
                modelos: ordenadas
            )
        }

        /// Nombre de pantalla; el cajon vacio se rotula "Sin modelo".
        private func nombreDeModelo(_ clave: String) -> String {
            let limpio = NombresLimpios.modelo(clave)
            return limpio.isEmpty ? "Sin modelo" : limpio
        }
    }
}