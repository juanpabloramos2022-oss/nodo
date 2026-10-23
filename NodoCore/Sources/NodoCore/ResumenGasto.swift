import Foundation

/// Una fila del desglose por modelo de la vista Gasto (SPEND.1).
///
/// `usd` y `porcentaje` salen del libro sellado; la vista solo los pinta. El
/// nombre se limpia para ensenar (`vendedor/modelo` -> `modelo`) sin tocar la
/// clave cruda con la que se guardo la historia.
public struct FilaModeloGasto: Equatable, Identifiable {
    /// Identificador crudo del modelo tal como lo tenia el proveedor.
    public let clave: String
    /// Nombre listo para pantalla. "Sin modelo" si la llamada no traia uno.
    public let nombre: String
    public let uso: UsoTokens
    public let usd: Double
    /// Porcentaje del total del mes (0...100). Cero si el mes no tiene USD.
    public let porcentaje: Double

    public var id: String { clave }

    public init(
        clave: String,
        nombre: String,
        uso: UsoTokens,
        usd: Double,
        porcentaje: Double
    ) {
        self.clave = clave
        self.nombre = nombre
        self.uso = uso
        self.usd = usd
        self.porcentaje = porcentaje
    }
}

/// Un dia del mes en curso con su gasto sellado, para las barras de SPEND.2.
public struct DiaDeGasto: Equatable, Identifiable {
    /// Numero de dia del mes (1...31).
    public let dia: Int
    public let usd: Double

    public var id: Int { dia }

    public init(dia: Int, usd: Double) {
        self.dia = dia
        self.usd = usd
    }
}

/// Todo lo que pinta la vista Gasto, derivado SOLO del libro de sellos.
///
/// POR QUE un tipo aparte: la vista no debe calcular nada ni mirar el proveedor
/// activo. `ResumenGasto.desde` lee el libro una vez y entrega cifras ya
/// resueltas, de modo que cambiar de modelo no puede mover ni un centavo de lo
/// que se ensena (contrato SPEND.1).
public struct ResumenGasto: Equatable {
    /// Tramo del dia en curso.
    public let hoy: TramoDeGasto
    /// Tramo del mes en curso.
    public let mes: TramoDeGasto
    /// Desglose por modelo del mes, ordenado de mayor a menor gasto.
    public let modelos: [FilaModeloGasto]
    /// Tokens del mes sin precio configurado. Se pinta aparte y solo si existe.
    public let sinPrecio: UsoTokens
    /// El dia mas caro de los ultimos 30 dias: la escala de la barra de HOY.
    public let maximoDiario30: Double
    /// Una barra por dia del mes en curso.
    public let diasDelMes: [DiaDeGasto]

    /// True si hay usos sin precio que declarar en la vista.
    public var tieneSinPrecio: Bool { sinPrecio.total > 0 }

    public init(
        hoy: TramoDeGasto,
        mes: TramoDeGasto,
        modelos: [FilaModeloGasto],
        sinPrecio: UsoTokens,
        maximoDiario30: Double,
        diasDelMes: [DiaDeGasto]
    ) {
        self.hoy = hoy
        self.mes = mes
        self.modelos = modelos
        self.sinPrecio = sinPrecio
        self.maximoDiario30 = maximoDiario30
        self.diasDelMes = diasDelMes
    }

    /// Construye el resumen leyendo el libro y nada mas.
    ///
    /// `ahora` y `calendario` se reciben por parametro para que las pruebas
    /// sean deterministas; la app pasa la fecha real y el calendario local, el
    /// mismo con el que el libro formo sus claves.
    public static func desde(
        libro: UsoApp,
        ahora: Date = Date(),
        calendario: Calendar = Calendar(identifier: .gregorian)
    ) -> ResumenGasto {
        var calendarioLocal = calendario
        calendarioLocal.timeZone = TimeZone.current

        let tramoHoy = libro.dia(ahora)
        let tramoMes = libro.mes(ahora)
        let totalMes = tramoMes.usd

        // El desglose se arma desde el reparto que ya guarda el libro: aqui no
        // se valora ningun token, solo se ordena y se calcula su porcentaje.
        var filas = tramoMes.porModelo.map { (clave, tramo) -> FilaModeloGasto in
            let porcentaje = totalMes > 0 && totalMes.isFinite && tramo.usd.isFinite
                ? min(max(tramo.usd / totalMes * 100, 0), 100)
                : 0
            return FilaModeloGasto(
                clave: clave,
                nombre: nombreDeModelo(clave),
                uso: tramo.uso,
                usd: tramo.usd,
                porcentaje: porcentaje
            )
        }

        // Los libros escritos antes de SPEND.1 no traen reparto por modelo. Para
        // que el desglose siga cuadrando con el total, se declara la diferencia
        // como "Sin modelo" en vez de esconderla. Los tokens sin precio ya se
        // restan aqui porque se pintan en su propia linea.
        if let residual = filaResidual(de: tramoMes, modelos: filas) {
            filas.append(residual)
        }

        let modelos = filas
            .filter { $0.usd > 0 || $0.uso.total > 0 }
            .sorted { izquierda, derecha in
                if izquierda.usd != derecha.usd {
                    return izquierda.usd > derecha.usd
                }
                if izquierda.nombre != derecha.nombre {
                    return izquierda.nombre < derecha.nombre
                }
                return izquierda.clave < derecha.clave
            }

        return ResumenGasto(
            hoy: tramoHoy,
            mes: tramoMes,
            modelos: modelos,
            sinPrecio: tramoMes.sinPrecio,
            maximoDiario30: maximoDiario(libro: libro, ahora: ahora, calendario: calendarioLocal),
            diasDelMes: diasDelMes(libro: libro, ahora: ahora, calendario: calendarioLocal)
        )
    }

    /// Fila que explica la parte del mes que el libro no atribuye a un modelo.
    ///
    /// Solo aparece con libros viejos (anteriores al reparto por modelo) o si
    /// una escritura futura dejara el total por encima de la suma de modelos.
    /// Devuelve nil cuando el reparto ya cuadra, que es el caso normal.
    private static func filaResidual(
        de tramo: TramoDeGasto,
        modelos: [FilaModeloGasto]
    ) -> FilaModeloGasto? {
        var usoAtribuido = UsoTokens()
        var usdAtribuido = 0.0
        for fila in modelos {
            usoAtribuido = usoAtribuido.sumando(fila.uso)
            usdAtribuido += fila.usd
        }

        let uso = UsoTokens(
            entrada: max(
                0,
                tramo.uso.entrada - usoAtribuido.entrada - tramo.sinPrecio.entrada
            ),
            salida: max(
                0,
                tramo.uso.salida - usoAtribuido.salida - tramo.sinPrecio.salida
            )
        )
        let usd = tramo.usd - usdAtribuido

        // El umbral evita una fila fantasma por el redondeo de los Double.
        guard uso.total > 0 || usd > 1e-12 else { return nil }

        let porcentaje = tramo.usd > 0 && tramo.usd.isFinite && usd.isFinite
            ? min(max(usd / tramo.usd * 100, 0), 100)
            : 0
        // Si el libro ya tenia un cajon vacio, la fila residual usa una clave
        // distinta para que SwiftUI no vea dos identificadores iguales.
        let clave = modelos.contains { $0.clave.isEmpty } ? "__sin_modelo__" : ""
        return FilaModeloGasto(
            clave: clave,
            nombre: "Sin modelo",
            uso: uso,
            usd: max(0, usd),
            porcentaje: porcentaje
        )
    }

    /// Nombre de pantalla de un modelo; el cajon vacio se rotula "Sin modelo".
    private static func nombreDeModelo(_ clave: String) -> String {
        let limpio = NombresLimpios.modelo(clave)
        return limpio.isEmpty ? "Sin modelo" : limpio
    }

    /// Dia mas caro de la ventana de 30 dias que termina hoy.
    ///
    /// La barra de HOY se declara contra este valor: una barra llena significa
    /// "tu dia mas alto de los ultimos 30 dias", no una cuota inventada.
    private static func maximoDiario(
        libro: UsoApp,
        ahora: Date,
        calendario: Calendar
    ) -> Double {
        let inicioHoy = calendario.startOfDay(for: ahora)
        var maximo = 0.0

        for atras in 0..<30 {
            guard let fecha = calendario.date(
                byAdding: .day,
                value: -atras,
                to: inicioHoy
            ) else {
                continue
            }
            maximo = max(maximo, libro.dia(fecha).usd)
        }
        return maximo
    }

    /// Una entrada por dia del mes en curso, con cero en los dias sin llamadas.
    ///
    /// Se leen las claves "yyyy-MM-dd" del propio libro en vez de reconstruir
    /// fechas: asi la vista no puede desviarse del calendario con el que se
    /// anoto cada sello.
    private static func diasDelMes(
        libro: UsoApp,
        ahora: Date,
        calendario: Calendar
    ) -> [DiaDeGasto] {
        let claveMes = UsoApp.claveMes(ahora)
        let rango = calendario.range(of: .day, in: .month, for: ahora) ?? 1..<2

        return (1...rango.count).map { dia in
            let clave = String(format: "%@-%02d", claveMes, dia)
            return DiaDeGasto(dia: dia, usd: libro.dias[clave]?.usd ?? 0)
        }
    }
}
