import Foundation
import XCTest

@testable import Nodo
import NodoCore

/// Pruebas de la cláusula de crecimiento en la capa app (B2.5).
///
/// Cubren el contador y la banda de Mi Contexto sobre `EstadoApp`, el rechazo
/// de creación en un turno real guionizado (chat normal, interruptor en ON), la
/// corrección permitida, el alta sensible tras [Aprobar] y la importación de
/// las semillas por la ruta real de respaldo.
@MainActor
final class TopeMemoriaAppTests: XCTestCase {
    private let promptB25 = "Mi color favorito de prueba es el verde"

    // MARK: - Semillas sintéticas

    private func id(_ numero: Int) -> UUID {
        UUID(
            uuidString: String(
                format: "%08X-0000-4000-8000-%012X",
                UInt32(numero),
                UInt32(numero)
            )
        )!
    }

    private func semilla(_ cantidad: Int) -> [EntradaMemoria] {
        let categorias = CategoriaMemoria.paraActualizar
        return (1...cantidad).map { numero in
            EntradaMemoria(
                id: id(numero),
                texto: String(format: "prueba-%02d", numero),
                fecha: Date(timeIntervalSince1970: TimeInterval(numero)),
                categoria: categorias[numero % categorias.count]
            )
        }
    }

    private func avisos(_ elementos: [ElementoHiloVisible]) -> Int {
        elementos.filter { elemento in
            if case .lineaMemoria = elemento { return true }
            return false
        }.count
    }

    private func cuerpoDelPrimerPayload(_ arnes: ArnesApp) throws -> String {
        let cuerpo = try XCTUnwrap(
            arnes.transporte.peticionesRegistradas.first?.cuerpo
        )
        return try XCTUnwrap(String(data: cuerpo, encoding: .utf8))
    }

    // MARK: - Contador y banda

    func testElContadorEsVisibleEn39SinBandaYEn40ConBanda() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        arnes.estado.config.memoria = semilla(39)
        XCTAssertEqual(
            arnes.estado.estadoMemoria.contador,
            "Memoria en 39 de 50 entradas"
        )
        XCTAssertFalse(arnes.estado.estadoMemoria.muestraBanda)

        arnes.estado.config.memoria = semilla(40)
        XCTAssertEqual(
            arnes.estado.estadoMemoria.contador,
            "Memoria en 40 de 50 entradas"
        )
        XCTAssertTrue(arnes.estado.estadoMemoria.muestraBanda)
        XCTAssertFalse(arnes.estado.estadoMemoria.enTope)

        arnes.estado.config.memoria = semilla(50)
        XCTAssertEqual(
            arnes.estado.estadoMemoria.contador,
            "Memoria en 50 de 50 entradas"
        )
        XCTAssertTrue(arnes.estado.estadoMemoria.muestraBanda)
        XCTAssertTrue(arnes.estado.estadoMemoria.enTope)
    }

    func testLaRevisionAgrupadaUsaLaMismaListaYNoBorraNada() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        arnes.estado.config.memoria = semilla(40)
        let grupos = arnes.estado.estadoMemoria.grupos
        XCTAssertEqual(
            grupos.reduce(0) { $0 + $1.entradas.count },
            40,
            "La revisión muestra las 40 entradas, sin fusionar ni resumir"
        )
        XCTAssertEqual(
            arnes.estado.config.memoria.count,
            40,
            "Agrupar para revisar no muta la Memoria"
        )

        // Borrar desde la revisión baja el contador y rehabilita la creación.
        arnes.estado.borrarEntradaMemoria(id: id(1))
        XCTAssertEqual(
            arnes.estado.estadoMemoria.contador,
            "Memoria en 39 de 50 entradas"
        )
        XCTAssertFalse(arnes.estado.estadoMemoria.muestraBanda)
    }

    // MARK: - Turno 1: creación rechazada en tope

    func testConCincuentaEntradasElTurnoNoCreaNadaYNoDejaAviso() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        let entradas = semilla(50)
        arnes.estado.config.memoria = entradas
        arnes.estado.config.memoriaInteligente = true
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                ToolCall(
                    id: "call-b25-turno1",
                    nombre: Memoria.nombreGuardar,
                    argumentos: #"{"content":"mi color favorito de prueba es el verde","category":"preference"}"#
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "Entendido: tu color de prueba es el verde.",
            uso: UsoTokens(entrada: 60, salida: 8)
        )

        arnes.estado.enviar(promptB25)
        try await arnes.esperarTurno()

        XCTAssertEqual(
            arnes.estado.config.memoria.count,
            50,
            "El tope rechaza la creación: 0 entradas nuevas"
        )
        XCTAssertEqual(
            arnes.estado.config.memoria.map(\.id),
            entradas.map(\.id),
            "El registro queda byte a byte como estaba"
        )
        XCTAssertEqual(
            avisos(arnes.estado.elementosVisiblesDelHilo()),
            0,
            "Sin guardado no hay línea de aviso en el hilo"
        )
        let rechazo = try XCTUnwrap(
            arnes.estado.conversacion.mensajes.last { $0.rol == .herramienta }
        )
        XCTAssertEqual(rechazo.toolCallId, "call-b25-turno1")
        XCTAssertTrue(rechazo.texto.contains("memoria en tope"), rechazo.texto)

        // El payload inyecta exactamente 50 entradas, ni una más.
        let cuerpo = try cuerpoDelPrimerPayload(arnes)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(cuerpo.utf8))
                as? [String: Any]
        )
        let mensajes = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let mensajeSistema = try XCTUnwrap(
            mensajes.first { $0["role"] as? String == "system" }
        )
        let sistema = try XCTUnwrap(mensajeSistema["content"] as? String)
        XCTAssertEqual(
            sistema.components(separatedBy: "\n- id: ").count - 1,
            50,
            "El bloque inyectado suma exactamente 50 entradas"
        )
        XCTAssertFalse(sistema.contains("mi color favorito de prueba es el verde"))
    }

    // MARK: - Turno 2: corrección permitida con el tope lleno

    func testConCincuentaEntradasLaCorreccionSiguePermitida() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        arnes.estado.config.memoria = semilla(50)
        arnes.estado.config.memoriaInteligente = true
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                ToolCall(
                    id: "call-b25-update",
                    nombre: Memoria.nombreActualizar,
                    argumentos: #"{"entry_id":"\#(id(1).uuidString)","content":"prueba-01 corregida","category":"correction"}"#
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "Corregido.",
            uso: UsoTokens(entrada: 60, salida: 4)
        )

        arnes.estado.enviar("Corrige la entrada prueba-01")
        try await arnes.esperarTurno()

        XCTAssertEqual(arnes.estado.config.memoria.count, 50)
        XCTAssertEqual(
            arnes.estado.config.memoria.first { $0.id == id(1) }?.texto,
            "prueba-01 corregida"
        )
        XCTAssertEqual(
            avisos(arnes.estado.elementosVisiblesDelHilo()),
            1,
            "La corrección deja su línea única"
        )
    }

    // MARK: - Turno 3: alta sensible tras [Aprobar] rechazada en tope

    func testElAltaSensibleTrasAprobarNoCreaNadaEnTopeYLaHojaAvisa() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        arnes.estado.config.memoria = semilla(50)
        arnes.estado.config.memoriaInteligente = true
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                ToolCall(
                    id: "call-b25-sensible",
                    nombre: Memoria.nombreProponerSensible,
                    argumentos: #"{"content":"mi presión arterial de prueba es 120 sobre 80","sensitive_category":"health"}"#
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "Entendido: es una lectura normal de prueba.",
            uso: UsoTokens(entrada: 60, salida: 9)
        )

        arnes.estado.enviar(
            "Dato de prueba de salud: mi presión arterial de prueba es 120 "
                + "sobre 80, ¿qué significa?"
        )
        try await arnes.esperar(
            { arnes.estado.propuestaMemoriaSensible != nil },
            mensaje: "La hoja de la propuesta sensible no apareció"
        )

        XCTAssertTrue(
            arnes.estado.avisoTopeEnPropuestaSensible,
            "La hoja tiene que avisar del tope antes de decidir"
        )
        XCTAssertEqual(arnes.estado.config.memoria.count, 50)

        arnes.estado.aprobarPropuestaSensible()
        try await arnes.esperarTurno()

        XCTAssertEqual(
            arnes.estado.config.memoria.count,
            50,
            "[Aprobar] no puede crear por encima de 50"
        )
        XCTAssertEqual(
            avisos(arnes.estado.elementosVisiblesDelHilo()),
            0,
            "No hubo guardado: no puede haber línea de aviso"
        )
        let rechazo = try XCTUnwrap(
            arnes.estado.conversacion.mensajes.last { $0.rol == .herramienta }
        )
        XCTAssertEqual(rechazo.toolCallId, "call-b25-sensible")
        XCTAssertTrue(rechazo.texto.contains("memoria en tope"), rechazo.texto)
    }

    // MARK: - Borrar en el hilo rehabilita la creación

    func testBorrarEnElHiloConTopeLlenoBajaAYRehabilitaLaCreacion() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        arnes.estado.config.memoria = semilla(50)
        arnes.estado.config.memoriaInteligente = true
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                ToolCall(
                    id: "call-b25-borrar",
                    nombre: Memoria.nombreBorrar,
                    argumentos: #"{"entry_id":"\#(id(1).uuidString)"}"#
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "Borrado.",
            uso: UsoTokens(entrada: 60, salida: 3)
        )
        arnes.estado.enviar("Olvida la entrada prueba-01")
        try await arnes.esperarTurno()

        XCTAssertEqual(arnes.estado.config.memoria.count, 49)
        XCTAssertEqual(
            arnes.estado.estadoMemoria.contador,
            "Memoria en 49 de 50 entradas"
        )
        XCTAssertFalse(arnes.estado.estadoMemoria.enTope)

        // Turno nuevo: ya cabe una creación.
        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                ToolCall(
                    id: "call-b25-crear-tras-borrar",
                    nombre: Memoria.nombreGuardar,
                    argumentos: #"{"content":"dato nuevo tras borrar","category":"durable_fact"}"#
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "Guardado.",
            uso: UsoTokens(entrada: 60, salida: 3)
        )
        arnes.estado.enviar("Guarda un dato nuevo")
        try await arnes.esperarTurno()

        XCTAssertEqual(arnes.estado.config.memoria.count, 50)
        XCTAssertEqual(
            arnes.estado.config.memoria.last?.texto,
            "dato nuevo tras borrar"
        )
    }

    // MARK: - Semillas importables

    /// Respaldo con solo entradas sintéticas, construido por el MISMO
    /// exportador de la app (`RespaldoConfiguracion.hacerRespaldo` + `json()`).
    ///
    /// Es el formato exacto que produce «Exportar respaldo». La prueba lo
    /// escribe a un archivo y lo vuelve a leer por `desde(json:)` y
    /// `importarRespaldoTotal`, que es la ruta real de importación.
    private func respaldoSemilla(_ cantidad: Int) throws -> Data {
        var config = AppConfig.inicial()
        config.memoria = semilla(cantidad)
        let respaldo = RespaldoConfiguracion.hacerRespaldo(
            config: config,
            ventanas: [:],
            conversaciones: [],
            tareas: []
        )
        return try respaldo.json()
    }

    /// Ruta de la semilla real: `NODO_SEMILLAS_DIR` o `~/workspace/nodo/semillas`.
    ///
    /// En CI no existe y la prueba usa el respaldo construido por el
    /// exportador; en la mesa del lead, si las semillas están, se importan los
    /// archivos reales.
    private func rutaDeSemilla(_ nombre: String) -> URL? {
        let base: URL
        if let directorio = ProcessInfo.processInfo.environment[
            "NODO_SEMILLAS_DIR"
        ], !directorio.isEmpty {
            base = URL(fileURLWithPath: directorio, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("workspace/nodo/semillas", isDirectory: true)
        }
        let ruta = base.appendingPathComponent(nombre)
        return FileManager.default.fileExists(atPath: ruta.path) ? ruta : nil
    }

    private func probarSemilla(_ cantidad: Int, nombre: String) throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let datos: Data
        if let ruta = rutaDeSemilla(nombre) {
            datos = try Data(contentsOf: ruta)
        } else {
            datos = try respaldoSemilla(cantidad)
        }

        let respaldo = try RespaldoConfiguracion.desde(json: datos)
        let manifiesto = try arnes.estado.importarRespaldoTotal(respaldo)

        XCTAssertEqual(manifiesto.memoria, cantidad)
        XCTAssertEqual(arnes.estado.config.memoria.count, cantidad)
        XCTAssertEqual(
            arnes.estado.estadoMemoria.contador,
            "Memoria en \(cantidad) de 50 entradas"
        )
        XCTAssertEqual(
            arnes.estado.estadoMemoria.muestraBanda,
            cantidad >= Memoria.umbralAvisoEntradas
        )
        XCTAssertEqual(
            arnes.estado.config.memoria.first?.texto,
            "prueba-01"
        )
        XCTAssertEqual(
            arnes.estado.config.memoria.last?.texto,
            String(format: "prueba-%02d", cantidad)
        )
    }

    func testLaSemillaDeCuarentaSeImportaYElContadorLoRefleja() throws {
        try probarSemilla(40, nombre: "semilla-40.json")
    }

    func testLaSemillaDeCincuentaSeImportaYElContadorLoRefleja() throws {
        try probarSemilla(50, nombre: "semilla-50.json")
    }
}
