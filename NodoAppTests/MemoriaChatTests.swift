import Foundation
import XCTest

@testable import Nodo
import NodoCore

/// Pruebas de la ejecucion real de `memoria_chat` (MEM.3).
///
/// El turno se guioniza con el mismo transporte de la app: una respuesta SSE
/// que pide la herramienta y otra con la confirmacion del modelo. Asi se
/// ejercita el bucle completo, la escritura en `config.memoria`, la linea de
/// evento y su Deshacer sin red ni claves reales.
@MainActor
final class MemoriaChatTests: XCTestCase {
    private let idExistente = UUID(
        uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    )!
    private let idDesconocido = UUID(
        uuidString: "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF"
    )!

    // MARK: - Guardar

    func testGuardarEjecutaLaHerramientaCreaLaLineaYDeshacerLaElimina() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        arnes.estado.config.memoria = []
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                llamada(accion: "guardar", texto: "Vive en Madrid")
            ]
        )
        arnes.transporte.guionar(
            texto: "Listo: lo guarde en tu Memoria.",
            uso: UsoTokens(entrada: 30, salida: 8)
        )

        arnes.estado.enviar("Guarda en mi memoria que vivo en Madrid")
        try await arnes.esperarTurno()

        XCTAssertNil(arnes.estado.errorDeTurno)
        XCTAssertEqual(arnes.estado.config.memoria.count, 1)

        let entrada = try XCTUnwrap(arnes.estado.config.memoria.first)
        XCTAssertEqual(entrada.texto, "Vive en Madrid")

        let linea = try XCTUnwrap(eventoDeMemoria(arnes))
        XCTAssertEqual(linea.cambioMemoria, CambioMemoria.guardada(entrada))
        XCTAssertTrue(linea.texto.hasPrefix("Guardado en memoria: "))
        XCTAssertFalse(linea.deshecho)

        // El resultado de la herramienta volvio al modelo en la segunda
        // peticion: sin eso no podria confirmar lo que hizo.
        let segunda = try cuerpoDeLaPeticion(arnes, indice: 1)
        let mensajes = try mensajesDe(segunda)
        let hayResultadoDeHerramienta = mensajes.contains { mensaje in
            guard mensaje["role"] as? String == "tool" else { return false }
            return (mensaje["content"] as? String)?.contains("Guarde") == true
        }
        XCTAssertTrue(
            hayResultadoDeHerramienta,
            "El resultado de memoria_chat no volvio al modelo: \(segunda)"
        )

        XCTAssertTrue(arnes.estado.deshacerCambioDeMemoria(id: linea.id))
        XCTAssertTrue(arnes.estado.config.memoria.isEmpty)

        let deshecha = try XCTUnwrap(eventoDeMemoria(arnes))
        XCTAssertTrue(deshecha.deshecho)

        // Lo deshecho no se puede deshacer dos veces.
        XCTAssertFalse(arnes.estado.deshacerCambioDeMemoria(id: linea.id))
        XCTAssertTrue(arnes.estado.config.memoria.isEmpty)
    }

    // MARK: - Actualizar

    func testActualizarEjecutaLaHerramientaYDeshacerRestauraElTextoAnterior() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let original = EntradaMemoria(
            id: idExistente,
            texto: "Vive en Madrid",
            fecha: Date(timeIntervalSince1970: 100)
        )
        arnes.estado.config.memoria = [original]
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                llamada(
                    accion: "actualizar",
                    texto: "Vive en Barcelona",
                    id: idExistente
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "Actualizado en tu Memoria.",
            uso: UsoTokens(entrada: 30, salida: 8)
        )

        arnes.estado.enviar("Actualiza mi memoria: ahora vivo en Barcelona")
        try await arnes.esperarTurno()

        XCTAssertNil(arnes.estado.errorDeTurno)
        let actualizada = try XCTUnwrap(arnes.estado.config.memoria.first)
        XCTAssertEqual(actualizada.id, idExistente)
        XCTAssertEqual(actualizada.texto, "Vive en Barcelona")

        let linea = try XCTUnwrap(eventoDeMemoria(arnes))
        XCTAssertEqual(linea.texto, "Memoria actualizada: Vive en Barcelona")

        XCTAssertTrue(arnes.estado.deshacerCambioDeMemoria(id: linea.id))
        XCTAssertEqual(arnes.estado.config.memoria, [original])

        XCTAssertFalse(arnes.estado.deshacerCambioDeMemoria(id: linea.id))
        XCTAssertEqual(arnes.estado.config.memoria, [original])
    }

    // MARK: - Borrar

    func testBorrarEjecutaLaHerramientaYDeshacerReinsertaLaEntradaConSuId() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let primera = EntradaMemoria(
            id: idExistente,
            texto: "Vive en Madrid",
            fecha: Date(timeIntervalSince1970: 100)
        )
        let segunda = EntradaMemoria(
            id: UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!,
            texto: "Prefiere respuestas breves",
            fecha: Date(timeIntervalSince1970: 200)
        )
        arnes.estado.config.memoria = [primera, segunda]
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        arnes.transporte.guionar(
            texto: "",
            toolCalls: [llamada(accion: "borrar", id: idExistente)]
        )
        arnes.transporte.guionar(
            texto: "Borrado de tu Memoria.",
            uso: UsoTokens(entrada: 30, salida: 8)
        )

        arnes.estado.enviar("Borra de mi memoria que vivo en Madrid")
        try await arnes.esperarTurno()

        XCTAssertNil(arnes.estado.errorDeTurno)
        XCTAssertEqual(arnes.estado.config.memoria, [segunda])

        let linea = try XCTUnwrap(eventoDeMemoria(arnes))
        XCTAssertEqual(linea.texto, "Memoria: entrada borrada · Vive en Madrid")

        XCTAssertTrue(arnes.estado.deshacerCambioDeMemoria(id: linea.id))
        XCTAssertEqual(
            arnes.estado.config.memoria,
            [primera, segunda],
            "Deshacer un borrado reinserta la entrada completa y en su sitio"
        )

        XCTAssertFalse(arnes.estado.deshacerCambioDeMemoria(id: linea.id))
        XCTAssertEqual(arnes.estado.config.memoria, [primera, segunda])
    }

    // MARK: - Sin llamada

    func testUnTurnoSinLlamadaALaHerramientaNoCambiaLaMemoria() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let original = EntradaMemoria(
            id: idExistente,
            texto: "Vive en Madrid",
            fecha: Date(timeIntervalSince1970: 100)
        )
        arnes.estado.config.memoria = [original]
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        arnes.transporte.guionar(
            texto: "Hola, ¿en que puedo ayudarte?",
            uso: UsoTokens(entrada: 20, salida: 6)
        )

        arnes.estado.enviar("Hola")
        try await arnes.esperarTurno()

        XCTAssertNil(arnes.estado.errorDeTurno)
        XCTAssertEqual(arnes.estado.config.memoria, [original])
        XCTAssertNil(eventoDeMemoria(arnes))
    }

    // MARK: - Errores

    func testUnIdDesconocidoDevuelveErrorYDejaLaListaIntacta() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let original = EntradaMemoria(
            id: idExistente,
            texto: "Vive en Madrid",
            fecha: Date(timeIntervalSince1970: 100)
        )
        arnes.estado.config.memoria = [original]
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                llamada(
                    accion: "actualizar",
                    texto: "No debe entrar",
                    id: idDesconocido
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "No pude actualizar esa entrada.",
            uso: UsoTokens(entrada: 30, salida: 8)
        )

        arnes.estado.enviar("Actualiza la entrada que no existe")
        try await arnes.esperarTurno()

        XCTAssertNil(arnes.estado.errorDeTurno)
        XCTAssertEqual(
            arnes.estado.config.memoria,
            [original],
            "Un id desconocido no puede tocar la lista"
        )
        XCTAssertNil(eventoDeMemoria(arnes))

        let resultado = try XCTUnwrap(
            arnes.estado.conversacion.mensajes.last { $0.rol == .herramienta }
        )
        XCTAssertTrue(resultado.texto.contains("Error"))
        XCTAssertTrue(resultado.texto.contains(idDesconocido.uuidString))
    }

    func testUnaAccionInvalidaDevuelveErrorYNoTocaLaMemoria() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let original = EntradaMemoria(
            id: idExistente,
            texto: "Vive en Madrid",
            fecha: Date(timeIntervalSince1970: 100)
        )
        arnes.estado.config.memoria = [original]
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        arnes.transporte.guionar(
            texto: "",
            toolCalls: [llamada(accion: "renombrar", texto: "No debe entrar")]
        )
        arnes.transporte.guionar(
            texto: "No reconozco esa accion.",
            uso: UsoTokens(entrada: 30, salida: 8)
        )

        arnes.estado.enviar("Haz algo raro con mi memoria")
        try await arnes.esperarTurno()

        XCTAssertNil(arnes.estado.errorDeTurno)
        XCTAssertEqual(arnes.estado.config.memoria, [original])
        XCTAssertNil(eventoDeMemoria(arnes))

        let resultado = try XCTUnwrap(
            arnes.estado.conversacion.mensajes.last { $0.rol == .herramienta }
        )
        XCTAssertTrue(resultado.texto.contains("Error"))
        XCTAssertTrue(resultado.texto.contains("renombrar"))
    }

    // MARK: - Ayudas

    /// Ultima linea de Memoria del hilo, deshecha o no.
    private func eventoDeMemoria(_ arnes: ArnesApp) -> EventoVisual? {
        arnes.estado.eventosVisuales.last { $0.cambioMemoria != nil }
    }

    /// Construye la llamada a `memoria_chat` con sus argumentos JSON.
    private func llamada(
        accion: String,
        texto: String? = nil,
        id: UUID? = nil,
        idLlamada: String = "llamada-memoria"
    ) -> ToolCall {
        var argumentos: [String: Any] = ["accion": accion]
        if let texto { argumentos["texto"] = texto }
        if let id { argumentos["id"] = id.uuidString }

        let datos = (try? JSONSerialization.data(withJSONObject: argumentos))
            ?? Data("{}".utf8)
        return ToolCall(
            id: idLlamada,
            nombre: Memoria.nombreHerramientaChat,
            argumentos: String(decoding: datos, as: UTF8.self)
        )
    }

    private func cuerpoDeLaPeticion(_ arnes: ArnesApp, indice: Int) throws -> String {
        let peticiones = arnes.transporte.peticionesRegistradas
        XCTAssertGreaterThan(peticiones.count, indice)
        let datos = try XCTUnwrap(peticiones[indice].cuerpo)
        return try XCTUnwrap(String(data: datos, encoding: .utf8))
    }

    private func mensajesDe(_ cuerpo: String) throws -> [[String: Any]] {
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(cuerpo.utf8)) as? [String: Any]
        )
        return try XCTUnwrap(json["messages"] as? [[String: Any]])
    }
}
