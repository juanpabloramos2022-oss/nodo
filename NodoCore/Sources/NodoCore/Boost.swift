import Foundation

/// Fase de la tuberia /boost dentro de la ejecucion de una Tarea.
///
/// BOOST.1 no cambia el modelo del turno ni abre un chat paralelo: es una
/// tuberia de tres fases que corre EN LUGAR del bucle normal cuando la
/// instruccion de la tarea empieza con /boost. Cada fase es un `Paso` del libro
/// con su estado y su sello de costo (COST), para que la vista y el dueno vean
/// exactamente que se pago y con que combo.
public enum FaseBoost: String, Codable, CaseIterable, Identifiable, Equatable {
    /// FASE 1: una sola llamada al combo fuerte que descompone el problema.
    case orquestacion
    /// FASE 2: una llamada separada por angulo, con combos baratos distintos.
    case angulo
    /// FASE 3: una sola llamada al combo fuerte que cruza y sintetiza.
    case sintesis

    public var id: String { rawValue }

    public var titulo: String {
        switch self {
        case .orquestacion: return "Orquestación"
        case .angulo: return "Ángulo"
        case .sintesis: return "Síntesis"
        }
    }
}

/// Reglas y textos de la tuberia /boost.
///
/// Vive en NodoCore (Foundation puro) para que la app y `swift test` compartan
/// la misma decision de combos, el mismo parseo de angulos y los mismos
/// mensajes. La ejecucion (llamadas, libro y cancelacion) vive en `EstadoApp`,
/// que es donde ya existe el transporte y el almacen de tareas.
public enum Boost {
    /// Tope de angulos. Mas de tres deja de ser contraste y pasa a ser ruido:
    /// cada angulo es una llamada pagada y la sintesis tiene que poder cruzarlos.
    public static let maxAngulos = 3
    /// Minimo que se le pide al orquestador. Si devuelve uno solo, se respeta:
    /// inventar angulos vacios gastaria cuota sin aportar contraste.
    public static let minAngulos = 2

    // MARK: - Eleccion de combos

    /// Combo FUERTE: el proveedor configurado de mayor precio de salida.
    ///
    /// La regla es determinista y esta escrita aqui, no escondida en la vista:
    /// orquestar y sintetizar son las fases que cargan con el juicio, asi que
    /// se pagan al combo mas caro por token de salida. Los empates se rompen
    /// por precio de entrada, luego nombre y luego id, para que dos corridas
    /// con la misma configuracion elijan el mismo proveedor. Si ningun
    /// proveedor tiene precio de salida, no hay forma honesta de comparar: se
    /// usa el proveedor de la tarea (o el primero configurado) y se declara en
    /// el libro con el que se corrio.
    public static func proveedorFuerte(
        en proveedores: [ProviderConfig],
        preferido: ProviderConfig?
    ) -> ProviderConfig? {
        let conPrecio = proveedores.filter { $0.precioSalidaPorMillon != nil }
        if let fuerte = conPrecio.sorted(by: ordenAscendente).last {
            return fuerte
        }
        if let preferido { return preferido }
        return proveedores.first
    }

    /// Combos baratos, de menor a mayor precio de salida.
    ///
    /// Se excluye el combo fuerte: un angulo resuelto por el mismo modelo que
    /// orquesto y sintetiza no aporta independencia, que es justo lo que la
    /// verificacion cruzada necesita.
    public static func proveedoresBaratos(
        en proveedores: [ProviderConfig],
        excluyendo fuerte: ProviderConfig?
    ) -> [ProviderConfig] {
        proveedores
            .filter { proveedor in
                guard proveedor.id != fuerte?.id else { return false }
                return proveedor.precioSalidaPorMillon != nil
            }
            .sorted(by: ordenAscendente)
    }

    /// Un combo por angulo, distintos entre si mientras existan.
    ///
    /// Con dos combos baratos y tres angulos, el tercero repite el primero: es
    /// preferible repetir a inventar un proveedor o a dejar un angulo sin
    /// correr. Sin combos baratos se cae al fuerte, y entonces la independencia
    /// se pierde; el libro lo deja visible con el proveedor de cada paso.
    public static func combosDeAngulos(
        cantidad: Int,
        proveedores: [ProviderConfig],
        fuerte: ProviderConfig?
    ) -> [ProviderConfig] {
        guard cantidad > 0 else { return [] }
        var base = proveedoresBaratos(en: proveedores, excluyendo: fuerte)
        if base.isEmpty, let fuerte {
            base = [fuerte]
        }
        guard !base.isEmpty else { return [] }
        return (0..<cantidad).map { base[$0 % base.count] }
    }

    /// Orden estable por precio de salida, entrada, nombre e id.
    ///
    /// POR QUE tantos desempates: el resultado decide que proveedor paga cada
    /// fase y dos configuraciones con precios iguales no pueden elegir distinto
    /// segun el orden en que el dueno las creo.
    private static func ordenAscendente(
        _ izquierda: ProviderConfig,
        _ derecha: ProviderConfig
    ) -> Bool {
        let salidaIzquierda = izquierda.precioSalidaPorMillon ?? 0
        let salidaDerecha = derecha.precioSalidaPorMillon ?? 0
        if salidaIzquierda != salidaDerecha {
            return salidaIzquierda < salidaDerecha
        }
        let entradaIzquierda = izquierda.precioEntradaPorMillon ?? 0
        let entradaDerecha = derecha.precioEntradaPorMillon ?? 0
        if entradaIzquierda != entradaDerecha {
            return entradaIzquierda < entradaDerecha
        }
        let nombreIzquierda = izquierda.nombre.lowercased()
        let nombreDerecha = derecha.nombre.lowercased()
        if nombreIzquierda != nombreDerecha {
            return nombreIzquierda < nombreDerecha
        }
        return izquierda.id.uuidString < derecha.id.uuidString
    }

    // MARK: - Angulos

    /// Resultado de partir la respuesta del orquestador.
    public struct DesgloseAngulos: Equatable {
        public var angulos: [String]
        /// True cuando no se reconocio ninguna linea de lista y se tomo la
        /// respuesta entera como un solo angulo. La fase lo declara en el libro.
        public var parseoFallido: Bool

        public init(angulos: [String], parseoFallido: Bool) {
            self.angulos = angulos
            self.parseoFallido = parseoFallido
        }
    }

    /// Parte la respuesta del orquestador en angulos verificables.
    ///
    /// El formato pedido es una lista, uno por linea. Se aceptan numeracion
    /// ("1.", "1)"), viñetas y "Ángulo 1:"/"Paso 1:" porque los modelos alternan
    /// entre esos formatos aunque se les pida uno. Si no aparece NINGUNA linea
    /// de lista, no se pierde la respuesta: el texto completo es un unico
    /// angulo y se marca `parseoFallido` para declararlo.
    public static func angulos(
        desde texto: String,
        maximo: Int = Boost.maxAngulos
    ) -> DesgloseAngulos {
        let limpio = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpio.isEmpty else {
            return DesgloseAngulos(angulos: [], parseoFallido: true)
        }

        var encontrados: [String] = []
        for linea in limpio.components(separatedBy: .newlines) {
            let recortada = linea.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !recortada.isEmpty else { continue }
            guard let contenido = sinMarcaDeLista(recortada) else { continue }
            encontrados.append(contenido)
            if encontrados.count == maximo { break }
        }

        if encontrados.isEmpty {
            return DesgloseAngulos(angulos: [limpio], parseoFallido: true)
        }
        return DesgloseAngulos(angulos: encontrados, parseoFallido: false)
    }

    /// Texto de una linea si lleva marca de lista reconocible; nil si no.
    private static func sinMarcaDeLista(_ linea: String) -> String? {
        guard let primero = linea.first else { return nil }

        if "-*•—".contains(primero) {
            let resto = String(linea.dropFirst())
                .trimmingCharacters(in: .whitespaces)
            return resto.isEmpty ? nil : resto
        }

        // "1. texto", "1) texto", "1 - texto".
        var indice = linea.startIndex
        while indice < linea.endIndex, linea[indice].isNumber {
            indice = linea.index(after: indice)
        }
        if indice > linea.startIndex, indice < linea.endIndex {
            let separador = linea[indice]
            if separador == "." || separador == ")" || separador == "-" || separador == ":" {
                let resto = String(linea[linea.index(after: indice)...])
                    .trimmingCharacters(in: .whitespaces)
                if !resto.isEmpty { return resto }
            }
        }

        // "Ángulo 1: texto", "Angulo 1 - texto", "Paso 1: texto".
        let minusculas = linea.lowercased()
        for prefijo in ["ángulo ", "angulo ", "paso "] where minusculas.hasPrefix(prefijo) {
            let trasPrefijo = String(linea.dropFirst(prefijo.count))
                .trimmingCharacters(in: .whitespaces)
            var cursor = trasPrefijo.startIndex
            while cursor < trasPrefijo.endIndex, trasPrefijo[cursor].isNumber {
                cursor = trasPrefijo.index(after: cursor)
            }
            guard cursor > trasPrefijo.startIndex, cursor < trasPrefijo.endIndex else {
                continue
            }
            let separador = trasPrefijo[cursor]
            guard separador == ":" || separador == "."
                || separador == "-" || separador == ")"
            else {
                continue
            }
            let resto = String(trasPrefijo[trasPrefijo.index(after: cursor)...])
                .trimmingCharacters(in: .whitespaces)
            if !resto.isEmpty { return resto }
        }

        return nil
    }

    // MARK: - Tope de gasto

    /// True cuando la tuberia ya no puede empezar otra fase.
    ///
    /// El costo de una llamada no se conoce antes de hacerla, asi que el tope se
    /// comprueba ANTES de cada fase con lo ya sellado: si la fase anterior dejo
    /// el acumulado en o por encima del tope, la siguiente no arranca. Es la
    /// unica frontera honesta sin adivinar tokens. Un tope nil, cero o negativo
    /// significa "sin tope", igual que en el aviso de chat.
    public static func excedeTope(acumulado: Double, tope: Double?) -> Bool {
        guard let tope, tope > 0 else { return false }
        return acumulado >= tope
    }

    // MARK: - Mensajes de las fases

    public static let instruccionesOrquestacion = """
    Eres un orquestador. Descompón el problema del usuario en 2 o 3 ángulos de análisis VERIFICABLES, cada uno con una afirmación que otro modelo pueda confirmar o refutar. Devuelve SOLO la lista, uno por línea, con el formato "1. ángulo". No resuelvas el problema, no ejecutes herramientas y no añadas texto antes ni después de la lista.
    """

    public static let instruccionesAngulo = """
    Eres un analista. Resuelve SOLO el ángulo que se te asigna sobre el problema completo, en español y con afirmaciones concretas que otro modelo pueda comprobar. No ejecutes herramientas, no inventes datos ni fuentes: si algo no se puede verificar, dilo. No repitas los demás ángulos.
    """

    public static let instruccionesSintesis = """
    Eres el sintetizador. Recibes un problema y los resultados de varios ángulos resueltos por modelos distintos. Cruza los resultados, señala y DESCARTA lo que no sobreviva a la verificación cruzada (contradicciones, afirmaciones sin apoyo, datos que solo aparecen en un ángulo y no se pueden comprobar) y entrega UNA sola respuesta final en español, breve y sin repetir el proceso. Frontera honesta: la verificación es contraste crítico entre modelos, no pruebas ejecutadas; no afirmes que algo se ejecutó o se comprobó empíricamente si no consta en los resultados.
    """

    public static func mensajesOrquestacion(problema: String) -> [ChatMessage] {
        [
            ChatMessage(rol: .sistema, texto: instruccionesOrquestacion),
            ChatMessage(
                rol: .usuario,
                texto: "Problema:\n\(problema.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        ]
    }

    public static func mensajesAngulo(
        problema: String,
        angulo: String,
        indice: Int,
        total: Int
    ) -> [ChatMessage] {
        let cuerpo = """
        Problema completo:
        \(problema.trimmingCharacters(in: .whitespacesAndNewlines))

        Ángulo \(indice) de \(total):
        \(angulo)
        """
        return [
            ChatMessage(rol: .sistema, texto: instruccionesAngulo),
            ChatMessage(rol: .usuario, texto: cuerpo)
        ]
    }

    /// Un resultado de angulo ya resuelto, con el combo que lo produjo.
    public struct ResultadoAngulo: Equatable {
        public var indice: Int
        public var proveedor: String
        public var texto: String

        public init(indice: Int, proveedor: String, texto: String) {
            self.indice = indice
            self.proveedor = proveedor
            self.texto = texto
        }
    }

    public static func mensajesSintesis(
        problema: String,
        angulos: [ResultadoAngulo]
    ) -> [ChatMessage] {
        var lineas: [String] = [
            "Problema:",
            problema.trimmingCharacters(in: .whitespacesAndNewlines),
            "",
            "Resultados por ángulo:"
        ]
        for angulo in angulos {
            lineas.append("")
            lineas.append("### Ángulo \(angulo.indice) — \(angulo.proveedor)")
            lineas.append(angulo.texto.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return [
            ChatMessage(rol: .sistema, texto: instruccionesSintesis),
            ChatMessage(rol: .usuario, texto: lineas.joined(separator: "\n"))
        ]
    }
}
