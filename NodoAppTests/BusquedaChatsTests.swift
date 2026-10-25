import Foundation
import XCTest

@testable import Nodo
import NodoCore

/// Pruebas de la busqueda de la pestana Chats (B4-BUS, BUS.1 y BUS.2).
///
/// POR QUE: la ficha exige que buscar sea SOLO LECTURA, local y en vivo, que
/// no toque la red, que no pueda devolver un chat temporal y que con el campo
/// vacio la lista sea exactamente la de siempre. Todo eso se prueba contra un
/// almacen REAL de tres conversaciones en un directorio temporal, no contra
/// una copia paralela del historial.
@MainActor
final class BusquedaChatsTests: XCTestCase {

    // MARK: - Almacen de prueba

    private static func conversacion(
        titulo: String,
        textos: [String],
        actualizada: TimeInterval,
        fijada: Bool = false,
        archivada: Bool = false
    ) -> Conversation {
        Conversation(
            titulo: titulo,
            mensajes: textos.map { texto in
                ChatMessage(
                    rol: .usuario,
                    texto: texto,
                    // La actividad de una conversacion es la fecha de su
                    // ultimo mensaje: se fija aqui para que el orden no
                    // dependa del reloj de la corrida.
                    fecha: Date(timeIntervalSince1970: actualizada)
                )
            },
            creada: Date(timeIntervalSince1970: actualizada),
            actualizada: Date(timeIntervalSince1970: actualizada),
            fijada: fijada,
            archivada: archivada
        )
    }

    /// La que lleva la palabra clave en el TEXTO de un mensaje.
    private static func enMensaje() -> Conversation {
        conversacion(
            titulo: "Notas del taller",
            textos: ["La piedra zafiro brilla"],
            actualizada: 200
        )
    }

    /// La que lleva la palabra clave SOLO en el titulo.
    private static func enTitulo() -> Conversation {
        conversacion(
            titulo: "Zafiro y oro",
            textos: ["Hablemos de joyas"],
            actualizada: 100
        )
    }

    /// La que no la lleva por ningun lado.
    private static func sinLaPalabra() -> Conversation {
        conversacion(
            titulo: "Recetas",
            textos: ["Hablemos de sopas"],
            actualizada: 300
        )
    }

    /// Siembra el almacen real del arnes con las tres conversaciones.
    private func sembrarAlmacen(_ arnes: ArnesApp) throws {
        let almacen = try ConversationStore(directorio: arnes.directorioStore)
        try almacen.guardar(Self.enMensaje())
        try almacen.guardar(Self.enTitulo())
        try almacen.guardar(Self.sinLaPalabra())
        arnes.estado.recargarConversaciones()
    }

    /// Contenido byte a byte de cada archivo del almacen.
    private func huellaDelAlmacen(_ directorio: URL) throws -> [String: Data] {
        let nombres = try FileManager.default.contentsOfDirectory(
            atPath: directorio.path
        ).filter { $0.hasSuffix(".json") }
        var huella: [String: Data] = [:]
        for nombre in nombres {
            huella[nombre] = try Data(
                contentsOf: directorio.appendingPathComponent(nombre)
            )
        }
        return huella
    }

    // MARK: - (1) Las 3 conversaciones: filtrar por ZAFIRO

    func testFiltrarPorZafiroDevuelveExactamenteLasDosPrimeras() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        try sembrarAlmacen(arnes)

        let filas = arnes.estado.filasDeBusqueda("ZAFIRO", segmento: .activos)

        XCTAssertEqual(
            filas.map { fila -> String in
                guard case .resultadoBusqueda(let titulo, _) = fila.elemento else {
                    return "<sin resultados>"
                }
                return titulo
            },
            ["Notas del taller", "Zafiro y oro"]
        )

        let elementos = arnes.estado.elementosVisiblesDeBusqueda(
            "ZAFIRO",
            segmento: .activos
        )
        XCTAssertEqual(elementos.count, 2)
        XCTAssertEqual(
            elementos,
            [
                .resultadoBusqueda(
                    titulo: "Notas del taller",
                    vistaPrevia: "La piedra zafiro brilla"
                ),
                .resultadoBusqueda(
                    titulo: "Zafiro y oro",
                    vistaPrevia: "Hablemos de joyas"
                )
            ]
        )
    }

    func testLaFilaSeIdentificaPorTituloYVistaPreviaSinIdentificadores() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        try sembrarAlmacen(arnes)

        for elemento in arnes.estado.elementosVisiblesDeBusqueda(
            "zafiro",
            segmento: .activos
        ) {
            let descripcion = String(describing: elemento)
            XCTAssertFalse(descripcion.contains("id:"), descripcion)
            for conversacion in arnes.estado.conversaciones {
                XCTAssertFalse(
                    descripcion.contains(conversacion.id.uuidString),
                    descripcion
                )
            }
        }
    }

    // MARK: - (2) Sin coincidencias: estado vacio explicito con el termino

    func testSinCoincidenciasDevuelveElEstadoVacioConElTermino() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        try sembrarAlmacen(arnes)

        XCTAssertEqual(
            arnes.estado.elementosVisiblesDeBusqueda(
                "ESMERALDA",
                segmento: .activos
            ),
            [.sinResultados(termino: "ESMERALDA")],
            "Sin coincidencias la pestana no queda en blanco: dice el termino"
        )
        XCTAssertTrue(
            arnes.estado.filasDeBusqueda("ESMERALDA", segmento: .activos).isEmpty
        )
    }

    // MARK: - (3) Campo vacio: la lista completa de siempre

    func testConElCampoVacioLaListaEsLaCompletaYEnSuOrdenHabitual() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let fijada = Self.conversacion(
            titulo: "Zafiro y oro",
            textos: ["Hablemos de joyas"],
            actualizada: 100,
            fijada: true
        )
        let almacen = try ConversationStore(directorio: arnes.directorioStore)
        try almacen.guardar(Self.enMensaje())
        try almacen.guardar(fijada)
        try almacen.guardar(Self.sinLaPalabra())
        arnes.estado.recargarConversaciones()

        let filas = arnes.estado.filasDeBusqueda("", segmento: .activos)
        XCTAssertEqual(
            filas.map(\.conversacion.titulo),
            ["Zafiro y oro", "Recetas", "Notas del taller"],
            "Fijadas primero y, dentro de cada grupo, actividad reciente"
        )
        XCTAssertEqual(
            filas.map(\.conversacion),
            HistorialConversaciones.ordenar(arnes.estado.conversaciones),
            "Sin busqueda la lista es exactamente la de siempre"
        )
        XCTAssertEqual(
            arnes.estado.elementosVisiblesDeBusqueda("", segmento: .activos).count,
            3
        )
    }

    func testElSegmentoActivosNoMezclaArchivados() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let almacen = try ConversationStore(directorio: arnes.directorioStore)
        try almacen.guardar(Self.enMensaje())
        var archivada = Self.enTitulo()
        archivada.archivada = true
        try almacen.guardar(archivada)
        try almacen.guardar(Self.sinLaPalabra())
        arnes.estado.recargarConversaciones()

        XCTAssertEqual(
            arnes.estado.filasDeBusqueda("zafiro", segmento: .activos)
                .map(\.conversacion.titulo),
            ["Notas del taller"]
        )
        XCTAssertEqual(
            arnes.estado.filasDeBusqueda("zafiro", segmento: .archivados)
                .map(\.conversacion.titulo),
            ["Zafiro y oro"]
        )
    }

    // MARK: - (4) Buscar es solo lectura: el almacen queda byte a byte intacto

    func testBuscarNoCambiaNiUnByteDelAlmacenEnDisco() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        try sembrarAlmacen(arnes)

        let antes = try huellaDelAlmacen(arnes.directorioStore)
        XCTAssertEqual(antes.count, 3)

        _ = arnes.estado.elementosVisiblesDeBusqueda("ZAFIRO", segmento: .activos)
        _ = arnes.estado.elementosVisiblesDeBusqueda("", segmento: .activos)
        _ = arnes.estado.elementosVisiblesDeBusqueda("esmeralda", segmento: .activos)
        _ = arnes.estado.filasDeBusqueda("zafiro", segmento: .archivados)

        XCTAssertEqual(
            try huellaDelAlmacen(arnes.directorioStore),
            antes,
            "Filtrar no escribe: el almacen queda byte a byte igual"
        )
    }

    // MARK: - (5) Buscar no sale a la red

    func testBuscarNoHaceNingunaPeticionDeRed() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        try sembrarAlmacen(arnes)

        XCTAssertEqual(arnes.transporte.cantidadDePeticiones, 0)

        _ = arnes.estado.elementosVisiblesDeBusqueda("zafiro", segmento: .activos)
        _ = arnes.estado.elementosVisiblesDeBusqueda("z", segmento: .activos)
        _ = arnes.estado.elementosVisiblesDeBusqueda(
            "no existe",
            segmento: .activos
        )

        XCTAssertEqual(
            arnes.transporte.cantidadDePeticiones,
            0,
            "El transporte no recibe ni una llamada al filtrar"
        )
        XCTAssertEqual(arnes.transporte.guionesPendientes, 0)
    }

    // MARK: - (6) Un chat temporal no puede resultar

    func testUnChatTemporalNoApareceComoResultado() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        // El hilo temporal contiene la palabra clave en memoria...
        arnes.transporte.guionar(
            texto: "La palabra de prueba de búsqueda es ZAFIRO-4.",
            uso: UsoTokens(entrada: 20, salida: 10)
        )
        arnes.estado.nuevaConversacionTemporal()
        arnes.estado.enviar("Di solo esto: la palabra de prueba de búsqueda es ZAFIRO-4.")
        try await arnes.esperarTurno()

        let idTemporal = arnes.estado.conversacion.id
        XCTAssertTrue(
            arnes.estado.conversacion.mensajes.contains {
                $0.texto.contains("ZAFIRO-4")
            },
            "El turno ocurrio de verdad en el hilo temporal"
        )

        // ...pero no existe en el almacen: no se persiste y no puede resultar.
        let almacen = try ConversationStore(directorio: arnes.directorioStore)
        XCTAssertThrowsError(
            try almacen.guardar(arnes.estado.conversacion)
        ) { error in
            XCTAssertEqual(
                error as? ErrorConversationStore,
                .conversacionTemporal
            )
        }
        XCTAssertNil(almacen.cargar(id: idTemporal))
        arnes.estado.recargarConversaciones()
        XCTAssertFalse(
            arnes.estado.conversaciones.contains { $0.id == idTemporal }
        )
        XCTAssertEqual(
            arnes.estado.elementosVisiblesDeBusqueda("ZAFIRO-4", segmento: .activos),
            [.sinResultados(termino: "ZAFIRO-4")],
            "Un chat temporal no puede salir en la busqueda"
        )
        let archivos = (try? FileManager.default.contentsOfDirectory(
            atPath: arnes.directorioStore.path
        )) ?? []
        XCTAssertTrue(
            archivos.filter { $0.hasSuffix(".json") }.isEmpty,
            "El hilo temporal no dejo archivo: \(archivos)"
        )
    }

    // MARK: - (7) Tocar un resultado abre ESA conversacion

    func testTocarUnResultadoAbreEsaConversacion() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        try sembrarAlmacen(arnes)

        let filas = arnes.estado.filasDeBusqueda("zafiro", segmento: .activos)
        let fila = try XCTUnwrap(
            filas.first { $0.conversacion.titulo == "Notas del taller" }
        )

        let abierta = try XCTUnwrap(
            arnes.estado.conversacionParaAbrir(fila.conversacion.id)
        )
        XCTAssertEqual(abierta.id, fila.conversacion.id)
        XCTAssertEqual(abierta.titulo, "Notas del taller")

        arnes.estado.abrir(abierta)
        XCTAssertEqual(arnes.estado.conversacion.id, fila.conversacion.id)
        XCTAssertNil(
            arnes.estado.conversacionParaAbrir(UUID()),
            "Un id que no esta en la lista no abre nada"
        )
    }
}
