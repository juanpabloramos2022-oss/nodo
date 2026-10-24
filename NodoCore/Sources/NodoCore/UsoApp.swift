import Foundation

/// Consumo y costo sellado de UN modelo dentro de un tramo del libro.
///
/// POR QUE se guarda por modelo: la vista Gasto tiene que ensenar en que se fue
/// el mes sin volver a valorar nada. El nombre es el identificador crudo que
/// tenia el proveedor cuando se cerro la llamada; si luego se renombra el
/// modelo, la historia no cambia.
public struct TramoDeModelo: Codable, Equatable {
    public var uso: UsoTokens
    public var usd: Double

    public init(uso: UsoTokens = UsoTokens(), usd: Double = 0) {
        self.uso = uso
        self.usd = usd
    }

    public mutating func registrar(uso: UsoTokens, usd: Double) {
        self.uso = self.uso.sumando(uso)
        self.usd += usd
    }
}

/// Consumo y costo de un tramo del libro: un dia o un mes.
///
/// `usd` es el dolar SELLADO de las llamadas del tramo, no una valoracion con
/// los precios de hoy. Si una llamada no se pudo valorar, sus tokens suman
/// igual y su USD no se inventa: queda en cero y se anotan aparte en
/// `sinPrecio`.
public struct TramoDeGasto: Codable, Equatable {
    public var uso: UsoTokens
    public var usd: Double
    /// Desglose por modelo. La suma de sus USD es `usd`: los usos sin precio
    /// no entran aqui porque no tienen dolares que repartir.
    public var porModelo: [String: TramoDeModelo]
    /// Tokens de llamadas cuyo proveedor no tenia precios configurados.
    ///
    /// POR QUE aparte: son tokens reales, pero su dolar es desconocido. Meterlos
    /// en el desglose con USD cero haria creer que ese modelo costo cero.
    public var sinPrecio: UsoTokens

    public init(
        uso: UsoTokens = UsoTokens(),
        usd: Double = 0,
        porModelo: [String: TramoDeModelo] = [:],
        sinPrecio: UsoTokens = UsoTokens()
    ) {
        self.uso = uso
        self.usd = usd
        self.porModelo = porModelo
        self.sinPrecio = sinPrecio
    }

    private enum CodingKeys: String, CodingKey {
        case uso
        case usd
        case porModelo
        case sinPrecio
    }

    /// Lectura tolerante: los tramos guardados antes del desglose no traen las
    /// claves nuevas y se leen como un tramo sin reparto por modelo.
    public init(from decoder: Decoder) throws {
        let contenedor = try decoder.container(keyedBy: CodingKeys.self)
        uso = try contenedor.decodeIfPresent(UsoTokens.self, forKey: .uso) ?? UsoTokens()
        usd = try contenedor.decodeIfPresent(Double.self, forKey: .usd) ?? 0
        porModelo = try contenedor.decodeIfPresent(
            [String: TramoDeModelo].self,
            forKey: .porModelo
        ) ?? [:]
        sinPrecio = try contenedor.decodeIfPresent(
            UsoTokens.self,
            forKey: .sinPrecio
        ) ?? UsoTokens()
    }

    /// Suma una llamada real a los totales del tramo.
    public mutating func registrar(uso: UsoTokens, usd: Double) {
        self.uso = self.uso.sumando(uso)
        self.usd += usd
    }

    /// Suma una llamada ya valorada al total y a su modelo.
    ///
    /// El modelo vacio agrupa las llamadas de proveedores sin identificador de
    /// modelo (por ejemplo, la generacion de un plan): es preferible un cajon
    /// "Sin modelo" honesto a repartir ese gasto entre modelos al azar.
    public mutating func registrar(uso: UsoTokens, usd: Double, modelo: String) {
        registrar(uso: uso, usd: usd)
        var tramo = porModelo[modelo] ?? TramoDeModelo()
        tramo.registrar(uso: uso, usd: usd)
        porModelo[modelo] = tramo
    }

    /// Suma una llamada cuyo proveedor no tiene precios configurados.
    ///
    /// Los tokens son un hecho y se conservan; el USD no se inventa.
    public mutating func registrarSinPrecio(uso: UsoTokens) {
        registrar(uso: uso, usd: 0)
        sinPrecio = sinPrecio.sumando(uso)
    }

    /// Fusiona otro tramo completo, con su desglose y sus usos sin precio.
    public mutating func fusionar(_ otro: TramoDeGasto) {
        registrar(uso: otro.uso, usd: otro.usd)
        sinPrecio = sinPrecio.sumando(otro.sinPrecio)
        for (modelo, tramo) in otro.porModelo {
            var actual = porModelo[modelo] ?? TramoDeModelo()
            actual.registrar(uso: tramo.uso, usd: tramo.usd)
            porModelo[modelo] = actual
        }
    }

    /// True si el tramo no tiene ni tokens ni dolares.
    public var vacio: Bool {
        uso.total == 0 && usd == 0
    }
}

/// Libro de gasto de la app: uso y USD sellado por dia y por mes (COST.2).
///
/// POR QUE existe ademas de `ContadoresGasto`: los contadores solo guardan el
/// dia en curso y el total desde el ultimo reinicio, y al cambiar de dia
/// pierden el detalle. Este libro conserva el gasto dia a dia y mes a mes para
/// poder ensenarlo sin recalcularlo desde las conversaciones, que se pueden
/// borrar.
///
/// Se alimenta SOLO desde `EstadoApp.registrarGasto`, el embudo unico de cada
/// llamada real al modelo. Los chats no escriben aqui directamente.
public struct UsoApp: Codable, Equatable {
    /// Tramo por dia, con la clave "yyyy-MM-dd" en la zona local.
    public var dias: [String: TramoDeGasto]
    /// Tramo por mes, con la clave "yyyy-MM" en la zona local.
    public var meses: [String: TramoDeGasto]
    /// True cuando el mes en curso ya se relleno con la factura que existia
    /// antes de este libro. Evita repetir la migracion en cada arranque.
    public var migrado: Bool

    public init(
        dias: [String: TramoDeGasto] = [:],
        meses: [String: TramoDeGasto] = [:],
        migrado: Bool = false
    ) {
        self.dias = dias
        self.meses = meses
        self.migrado = migrado
    }

    private enum CodingKeys: String, CodingKey {
        case dias
        case meses
        case migrado
    }

    /// Decodificacion tolerante: una configuracion guardada antes de existir el
    /// libro no trae estas claves y arranca con el libro vacio.
    public init(from decoder: Decoder) throws {
        let contenedor = try decoder.container(keyedBy: CodingKeys.self)
        dias = try contenedor.decodeIfPresent(
            [String: TramoDeGasto].self,
            forKey: .dias
        ) ?? [:]
        meses = try contenedor.decodeIfPresent(
            [String: TramoDeGasto].self,
            forKey: .meses
        ) ?? [:]
        migrado = try contenedor.decodeIfPresent(Bool.self, forKey: .migrado) ?? false
    }

    // MARK: - Claves de fecha

    /// Clave del dia local, "yyyy-MM-dd".
    public static func claveDia(_ fecha: Date) -> String {
        clave(fecha, formato: "yyyy-MM-dd")
    }

    /// Clave del mes local, "yyyy-MM".
    public static func claveMes(_ fecha: Date) -> String {
        clave(fecha, formato: "yyyy-MM")
    }

    /// La fecha se formatea con el calendario gregoriano y la zona del
    /// dispositivo, que es la misma que usa `ContadoresGasto` para su dia.
    private static func clave(_ fecha: Date, formato: String) -> String {
        let formateador = DateFormatter()
        formateador.calendar = Calendar(identifier: .gregorian)
        formateador.locale = Locale(identifier: "en_US_POSIX")
        formateador.timeZone = TimeZone.current
        formateador.dateFormat = formato
        return formateador.string(from: fecha)
    }

    // MARK: - Alimentacion

    /// Anota una llamada real en su dia y en su mes.
    ///
    /// La fecha la pasa quien llama; el libro no lee el reloj, para que las
    /// pruebas sean deterministas. `modelo` es el identificador del proveedor
    /// que genero la llamada y `conPrecio` dice si su USD se pudo sellar: sin
    /// precio, los tokens se guardan pero el dolar no se inventa.
    public mutating func registrar(
        uso: UsoTokens,
        usd: Double,
        fecha: Date,
        modelo: String? = nil,
        conPrecio: Bool = true
    ) {
        let dia = Self.claveDia(fecha)
        var tramoDia = dias[dia] ?? TramoDeGasto()
        Self.anotar(
            en: &tramoDia,
            uso: uso,
            usd: usd,
            modelo: modelo,
            conPrecio: conPrecio
        )
        dias[dia] = tramoDia

        let mes = Self.claveMes(fecha)
        var tramoMes = meses[mes] ?? TramoDeGasto()
        Self.anotar(
            en: &tramoMes,
            uso: uso,
            usd: usd,
            modelo: modelo,
            conPrecio: conPrecio
        )
        meses[mes] = tramoMes
    }

    /// Reparte una llamada dentro de un tramo segun se haya podido valorar.
    ///
    /// Vive en un helper para que el dia y el mes apliquen exactamente la misma
    /// regla: si se separan, los totales de la vista Gasto dejarian de cuadrar
    /// con sus barras.
    private static func anotar(
        en tramo: inout TramoDeGasto,
        uso: UsoTokens,
        usd: Double,
        modelo: String?,
        conPrecio: Bool
    ) {
        if conPrecio {
            tramo.registrar(uso: uso, usd: usd, modelo: modelo ?? "")
        } else {
            tramo.registrarSinPrecio(uso: uso)
        }
    }

    // MARK: - Migracion

    /// Vuelca al mes en curso la factura que ya existia antes del libro.
    ///
    /// POR QUE solo al mes: las conversaciones viejas guardan cuanto se gasto,
    /// pero no cuando se pago cada llamada. El mes en curso es lo unico que se
    /// puede afirmar; repartirlo hacia atras por dias seria inventar historia.
    /// El libro diario arranca hoy, con el dia vacio, y se llena con la
    /// siguiente llamada real. Queda marcado `migrado` para no repetirlo.
    public mutating func migrar(uso: UsoTokens, usd: Double, fecha: Date) {
        guard !migrado else { return }

        let mes = Self.claveMes(fecha)
        var tramoMes = meses[mes] ?? TramoDeGasto()
        // La migracion no sabe que modelo genero cada llamada vieja, pero si
        // sabe su dolar sellado. Se guarda bajo el cajon "Sin modelo" para que
        // la suma del desglose siga cuadrando con el total del mes.
        tramoMes.registrar(uso: uso, usd: usd, modelo: "")
        meses[mes] = tramoMes

        let dia = Self.claveDia(fecha)
        if dias[dia] == nil {
            dias[dia] = TramoDeGasto()
        }

        migrado = true
    }

    // MARK: - Consulta

    /// Tramo del dia de `fecha`; vacio si ese dia no tuvo llamadas.
    public func dia(_ fecha: Date) -> TramoDeGasto {
        dias[Self.claveDia(fecha)] ?? TramoDeGasto()
    }

    /// Tramo del mes de `fecha`; vacio si ese mes no tuvo llamadas.
    public func mes(_ fecha: Date) -> TramoDeGasto {
        meses[Self.claveMes(fecha)] ?? TramoDeGasto()
    }

    /// Totales de todo el libro, dia a dia.
    public var totalDias: TramoDeGasto {
        dias.values.reduce(TramoDeGasto()) { total, tramo in
            var acumulado = total
            acumulado.fusionar(tramo)
            return acumulado
        }
    }

    /// Totales de todo el libro, mes a mes.
    public var totalMeses: TramoDeGasto {
        meses.values.reduce(TramoDeGasto()) { total, tramo in
            var acumulado = total
            acumulado.fusionar(tramo)
            return acumulado
        }
    }
}
