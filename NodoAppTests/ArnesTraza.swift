import Foundation

@testable import Nodo
import NodoCore

/// Volcado de la proyeccion visible (P0.2) a la traza de texto de P0.3.
///
/// POR QUE un archivo de texto y no una captura: la traza es evidencia
/// revisable linea a linea por la coordinacion, sin simulador ni pixeles. Cada
/// linea es UN elemento del catalogo cerrado de `UI_INVARIANTS.md`, en orden y
/// con tiempo relativo al inicio del turno. Los segmentos de una respuesta van
/// anidados bajo su `AssistantBubble` con sangria.
///
/// Este tipo no inventa elementos: recibe la lista que devuelve
/// `EstadoApp.elementosVisiblesDelHilo()` (o las proyecciones de Tarea y
/// Busqueda) y la serializa. La exclusion de resultados de herramienta, JSON,
/// UUIDs y nombres tecnicos ya ocurrio en la proyeccion; aqui no hay ningun
/// caso capaz de representarlos.
enum TrazaVista {
    /// Sangria de las lineas anidadas de una burbuja de asistente.
    static let sangriaSegmento = "  "

    /// Tiempo relativo al inicio del turno, con un decimal y en segundos.
    static func tiempo(_ fecha: Date, desde inicio: Date) -> String {
        let segundos = max(0, fecha.timeIntervalSince(inicio))
        return String(
            format: "%.1f",
            locale: Locale(identifier: "en_US_POSIX"),
            segundos
        )
    }

    /// Escapa el contenido de una cadena para que la traza siga siendo una
    /// linea por elemento: comillas, barra invertida y saltos de linea.
    static func escapar(_ valor: String) -> String {
        var salida = ""
        salida.reserveCapacity(valor.count)
        for caracter in valor {
            switch caracter {
            case "\\": salida += "\\\\"
            case "\"": salida += "\\\""
            case "\n": salida += "\\n"
            case "\r": salida += "\\r"
            case "\t": salida += "\\t"
            default: salida.append(caracter)
            }
        }
        return salida
    }

    // MARK: - Hilo del Chat

    /// Lineas de una lista de elementos del hilo, todas con el mismo `t`.
    static func lineasHilo(
        _ elementos: [ElementoHiloVisible],
        t: String
    ) -> [String] {
        elementos.flatMap { lineasDeElemento($0, t: t) }
    }

    /// Lineas de un elemento; `AssistantBubble` aporta ademas sus segmentos.
    static func lineasDeElemento(
        _ elemento: ElementoHiloVisible,
        t: String
    ) -> [String] {
        switch elemento {
        case .burbujaUsuario(let texto):
            return ["[t=\(t)s] UserBubble(\"\(escapar(texto))\")"]

        case .burbujaAsistente(let segmentos):
            var salida = [
                "[t=\(t)s] AssistantBubble(\"\(escapar(textoPlano(segmentos)))\")"
            ]
            for segmento in segmentos {
                switch segmento {
                case .texto(let texto):
                    salida.append(
                        "\(sangriaSegmento)[t=\(t)s] "
                            + "TextSegment(\"\(escapar(texto))\")"
                    )
                case .codigo(let lenguaje, let textoCrudo):
                    let lenguajeTexto = lenguaje.map {
                        "\"\(escapar($0))\""
                    } ?? "nil"
                    salida.append(
                        "\(sangriaSegmento)[t=\(t)s] "
                            + "CodeBlock(lenguaje: \(lenguajeTexto), "
                            + "textoCrudo: \"\(escapar(textoCrudo))\")"
                    )
                }
            }
            return salida

        case .lineaMemoria(let texto, let puedeDeshacer, _):
            return [
                "[t=\(t)s] MemoryLineNotice(text: \"\(escapar(texto))\", "
                    + "hasUndo: \(puedeDeshacer ? "true" : "false"))"
            ]

        case .divisor(let texto):
            return ["[t=\(t)s] Divider(\"\(escapar(texto))\")"]

        case .burbujaEnCurso(let texto):
            return ["[t=\(t)s] StreamingBubble(\"\(escapar(texto))\")"]

        case .errorTurno(let texto):
            return ["[t=\(t)s] ErrorBubble(\"\(escapar(texto))\")"]

        case .hojaAprobacionMemoria(let texto, let categoria, let estado):
            return [
                "[t=\(t)s] MemoryApprovalSheet(texto: \"\(escapar(texto))\", "
                    + "categoria: \"\(escapar(categoria.etiquetaVisible))\", "
                    + "estado: \"\(escapar(estado.rawValue))\")"
            ]
        }
    }

    /// Vuelca la proyeccion del hilo completa a `ruta`.
    ///
    /// La ruta es parametro obligatorio: CI y la coordinacion deciden donde se
    /// archiva (`~/workspace/nodo/humos/ui_transcript_<ID>.txt`).
    static func volcarHilo(
        _ elementos: [ElementoHiloVisible],
        desde inicio: Date,
        a ruta: URL,
        hasta fin: Date = Date()
    ) throws {
        try escribir(lineasHilo(elementos, t: tiempo(fin, desde: inicio)), a: ruta)
    }

    // MARK: - Tarea

    static func lineasTarea(
        _ elementos: [ElementoTareaVisible],
        t: String
    ) -> [String] {
        elementos.map { elemento in
            switch elemento {
            case .cabeceraTarea(
                let estado,
                let pasoActual,
                let pasosTotales,
                let costoSellado
            ):
                return "[t=\(t)s] TaskHeader(estado: "
                    + "\"\(escapar(estado.titulo))\", "
                    + "pasoActual: \(pasoActual), "
                    + "pasosTotales: \(pasosTotales), "
                    + "costoSellado: \"\(decimal(costoSellado))\")"

            case .tarjetaPlan(let pasos, let version):
                let textos = pasos
                    .map { "\"\(escapar($0.texto))\"" }
                    .joined(separator: ", ")
                return "[t=\(t)s] PlanCard(pasos: [\(textos)], "
                    + "version: \(version))"

            case .filaPaso(
                let paso,
                let estado,
                let etiquetaDinamica,
                let duracion,
                let costo
            ):
                let duracionTexto = duracion.map {
                    String(
                        format: "%.1f",
                        locale: Locale(identifier: "en_US_POSIX"),
                        $0
                    )
                } ?? "nil"
                let costoTexto = costo.map { "\"\(decimal($0))\"" } ?? "nil"
                return "[t=\(t)s] StepRow(paso: \(paso), "
                    + "estado: \"\(escapar(estado.titulo))\", "
                    + "etiqueta: \"\(escapar(etiquetaDinamica))\", "
                    + "duracion: \(duracionTexto), costo: \(costoTexto))"
            }
        }
    }

    static func volcarTarea(
        _ elementos: [ElementoTareaVisible],
        desde inicio: Date,
        a ruta: URL,
        hasta fin: Date = Date()
    ) throws {
        try escribir(lineasTarea(elementos, t: tiempo(fin, desde: inicio)), a: ruta)
    }

    // MARK: - Busqueda

    static func lineasBusqueda(
        _ elementos: [ElementoBusquedaVisible],
        t: String
    ) -> [String] {
        elementos.map { elemento in
            switch elemento {
            case .resultadoBusqueda(let titulo, let vistaPrevia):
                return "[t=\(t)s] SearchResultRow(titulo: "
                    + "\"\(escapar(titulo))\", vistaPrevia: "
                    + "\"\(escapar(vistaPrevia))\")"

            case .sinResultados(let termino):
                return "[t=\(t)s] SearchEmptyState(termino: "
                    + "\"\(escapar(termino))\")"
            }
        }
    }

    static func volcarBusqueda(
        _ elementos: [ElementoBusquedaVisible],
        desde inicio: Date,
        a ruta: URL,
        hasta fin: Date = Date()
    ) throws {
        try escribir(
            lineasBusqueda(elementos, t: tiempo(fin, desde: inicio)),
            a: ruta
        )
    }

    // MARK: - Utilidades

    /// Contenido visible completo de una burbuja, sin separar prosa y codigo.
    private static func textoPlano(_ segmentos: [SegmentoRespuesta]) -> String {
        segmentos.map { segmento in
            switch segmento {
            case .texto(let texto): return texto
            case .codigo(_, let textoCrudo): return textoCrudo
            }
        }.joined(separator: "\n")
    }

    private static func decimal(_ valor: Decimal) -> String {
        String(describing: valor)
    }

    /// Escribe las lineas; una lista vacia deja el archivo vacio.
    static func escribir(_ lineas: [String], a ruta: URL) throws {
        let carpeta = ruta.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: carpeta,
            withIntermediateDirectories: true
        )
        let contenido = lineas.isEmpty
            ? ""
            : lineas.joined(separator: "\n") + "\n"
        try contenido.write(to: ruta, atomically: true, encoding: .utf8)
    }
}

/// Sesion de traza de un turno: acumula las transiciones y reescribe el
/// archivo en cada una, para que la evidencia exista aunque el test falle
/// despues.
///
/// Solo emite elementos NUEVOS o CAMBIADOS respecto a la captura anterior. Un
/// volcado completo por transicion repetiria la misma `MemoryLineNotice` en
/// cada captura y romperia el conteo 3 de la Puerta C, que exige exactamente
/// una linea por turno con guardado. El archivo final es, por tanto, la
/// cronologia de aparicion de cada elemento, no una copia de la ultima foto.
///
/// `incluirBurbujaEnCurso` queda en `false` para las trazas que no miden
/// progreso vivo: la burbuja en curso es un estado transitorio que se
/// sustituye por la burbuja final y no es un artefacto del turno cerrado. El
/// regimen de progreso vivo del Bloque 3 la conserva pasando `true`.
final class SesionTraza {
    private let ruta: URL
    private let inicio: Date
    private let incluirBurbujaEnCurso: Bool
    private var anterior: [ElementoHiloVisible] = []
    private var lineas: [String] = []

    init(
        ruta: URL,
        inicio: Date = Date(),
        modo: String? = nil,
        incluirBurbujaEnCurso: Bool = false
    ) throws {
        self.ruta = ruta
        self.inicio = inicio
        self.incluirBurbujaEnCurso = incluirBurbujaEnCurso
        if let modo = modo {
            lineas.append("modo: \(modo)")
        }
        try escribir()
    }

    /// Vuelca la proyeccion actual. Llamar antes de enviar (foto vacia), tras
    /// cada herramienta, al cerrar la respuesta y tras deshacer si aplica.
    func capturar(
        _ elementos: [ElementoHiloVisible],
        en fecha: Date = Date()
    ) throws {
        var visibles = elementos
        if !incluirBurbujaEnCurso {
            visibles = elementos.filter { elemento in
                if case .burbujaEnCurso = elemento { return false }
                return true
            }
        }

        let t = TrazaVista.tiempo(fecha, desde: inicio)
        for elemento in nuevas(visibles) {
            lineas.append(contentsOf: TrazaVista.lineasDeElemento(elemento, t: t))
        }
        anterior = visibles
        try escribir()
    }

    var contenido: String {
        lineas.isEmpty ? "" : lineas.joined(separator: "\n") + "\n"
    }

    private func nuevas(
        _ actuales: [ElementoHiloVisible]
    ) -> [ElementoHiloVisible] {
        // Camino normal: la proyeccion solo crece (antes de enviar, tras la
        // herramienta, al cerrar). Se emite la cola nueva.
        if actuales.count >= anterior.count,
           Array(actuales.prefix(anterior.count)) == anterior {
            return Array(actuales.dropFirst(anterior.count))
        }

        // Un cambio en medio (por ejemplo, deshacer una linea de memoria) no
        // encaja en el prefijo: se emite lo que difiere por posicion.
        var resultado: [ElementoHiloVisible] = []
        for (indice, elemento) in actuales.enumerated() {
            if indice >= anterior.count || anterior[indice] != elemento {
                resultado.append(elemento)
            }
        }
        return resultado
    }

    private func escribir() throws {
        try TrazaVista.escribir(lineas, a: ruta)
    }
}
