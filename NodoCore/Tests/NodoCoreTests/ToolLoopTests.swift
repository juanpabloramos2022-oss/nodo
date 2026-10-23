import XCTest

@testable import NodoCore

final class ToolLoopTests: XCTestCase {
    func testSinHerramientasDevuelveElTexto() async throws {
        let motor = MotorFalso([RespuestaModelo(texto: "respuesta directa")])
        let bucle = ToolLoop(motor: motor, herramientas: [])

        let resultado = try await bucle.ejecutar(
            historial: [ChatMessage(rol: .usuario, texto: "hola")]
        )

        XCTAssertEqual(resultado.texto, "respuesta directa")
        XCTAssertEqual(resultado.iteraciones, 1)
        XCTAssertFalse(resultado.seAgotoElLimite)
        XCTAssertEqual(resultado.mensajesNuevos.count, 1)
        XCTAssertEqual(resultado.mensajesNuevos.first?.rol, .asistente)
    }

    func testEjecutaHerramientaYVuelveAlModelo() async throws {
        let motor = MotorFalso([
            RespuestaModelo(
                texto: "",
                toolCalls: [ToolCall(id: "c1", nombre: "probar", argumentos: "{\"x\":\"1\"}")]
            ),
            RespuestaModelo(texto: "listo")
        ])
        let herramienta = HerramientaFalsa(resultado: "ok")
        let bucle = ToolLoop(motor: motor, herramientas: [herramienta])

        let resultado = try await bucle.ejecutar(
            historial: [ChatMessage(rol: .usuario, texto: "usa la herramienta")]
        )

        XCTAssertEqual(resultado.iteraciones, 2)
        XCTAssertEqual(resultado.texto, "listo")
        XCTAssertEqual(herramienta.argumentosRecibidos, ["{\"x\":\"1\"}"])

        // asistente + herramienta + asistente
        XCTAssertEqual(resultado.mensajesNuevos.count, 3)
        XCTAssertEqual(resultado.mensajesNuevos[1].rol, .herramienta)
        XCTAssertEqual(resultado.mensajesNuevos[1].texto, "ok")
        XCTAssertEqual(resultado.mensajesNuevos[1].toolCallId, "c1")
    }

    func testElHistorialCreceConElResultadoDeLaHerramienta() async throws {
        let motor = MotorFalso([
            RespuestaModelo(texto: "", toolCalls: [ToolCall(id: "c1", nombre: "probar", argumentos: "{}")]),
            RespuestaModelo(texto: "fin")
        ])
        let bucle = ToolLoop(motor: motor, herramientas: [HerramientaFalsa()])

        _ = try await bucle.ejecutar(historial: [ChatMessage(rol: .usuario, texto: "x")])

        // Si el resultado no viaja al modelo, este repite la misma llamada para
        // siempre. Esta prueba es la que evita ese bucle infinito.
        let segundo = motor.historiales[1]
        XCTAssertEqual(segundo.count, 3)
        XCTAssertEqual(segundo.last?.rol, .herramienta)
    }

    func testSeDetieneAlLlegarAlLimite() async throws {
        let motor = MotorFalso([
            RespuestaModelo(texto: "", toolCalls: [ToolCall(id: "c1", nombre: "probar", argumentos: "{}")])
        ])
        let bucle = ToolLoop(motor: motor, herramientas: [HerramientaFalsa()], maxIteraciones: 3)

        let resultado = try await bucle.ejecutar(
            historial: [ChatMessage(rol: .usuario, texto: "x")]
        )

        XCTAssertTrue(resultado.seAgotoElLimite)
        XCTAssertEqual(resultado.iteraciones, 3)
        XCTAssertEqual(motor.llamadas, 3)
    }

    func testHerramientaQueFallaDevuelveErrorAlModelo() async throws {
        let motor = MotorFalso([
            RespuestaModelo(texto: "", toolCalls: [ToolCall(id: "c1", nombre: "probar", argumentos: "{}")]),
            RespuestaModelo(texto: "lo siento")
        ])
        let herramienta = HerramientaFalsa(error: ErrorHerramienta.noPermitida("nada"))
        let bucle = ToolLoop(motor: motor, herramientas: [herramienta])

        let resultado = try await bucle.ejecutar(
            historial: [ChatMessage(rol: .usuario, texto: "x")]
        )

        let mensaje = resultado.mensajesNuevos[1]
        XCTAssertEqual(mensaje.rol, .herramienta)
        XCTAssertTrue(mensaje.texto.hasPrefix("Error:"))
        XCTAssertEqual(resultado.texto, "lo siento")
    }

    func testHerramientaDesconocidaNoRompeElTurno() async throws {
        let motor = MotorFalso([
            RespuestaModelo(texto: "", toolCalls: [ToolCall(id: "c1", nombre: "noexiste", argumentos: "{}")]),
            RespuestaModelo(texto: "ok")
        ])
        let bucle = ToolLoop(motor: motor, herramientas: [])

        let resultado = try await bucle.ejecutar(
            historial: [ChatMessage(rol: .usuario, texto: "x")]
        )

        XCTAssertTrue(resultado.mensajesNuevos[1].texto.contains("no existe"))
        XCTAssertEqual(resultado.texto, "ok")
    }

    func testOfreceLasDefinicionesAlMotor() async throws {
        let motor = MotorFalso([RespuestaModelo(texto: "ok")])
        let bucle = ToolLoop(motor: motor, herramientas: [HerramientaFalsa(nombre: "miherramienta")])

        _ = try await bucle.ejecutar(historial: [])

        XCTAssertEqual(motor.herramientasOfrecidas.first?.first?.nombre, "miherramienta")
    }

    func testElTextoParcialLlegaAlLlamador() async throws {
        let motor = MotorFalso([RespuestaModelo(texto: "en vivo")])
        let bucle = ToolLoop(motor: motor, herramientas: [])
        var visto: [String] = []

        _ = try await bucle.ejecutar(
            historial: [ChatMessage(rol: .usuario, texto: "x")],
            alRecibirTexto: { visto.append($0) }
        )

        XCTAssertEqual(visto, ["en vivo"])
    }

    func testSumaElUsoDeTodasLasLlamadasInternasDelTurno() async throws {
        let motor = MotorFalso([
            RespuestaModelo(
                texto: "",
                toolCalls: [ToolCall(id: "c1", nombre: "probar", argumentos: "{}")],
                uso: UsoTokens(entrada: 10, salida: 4)
            ),
            RespuestaModelo(
                texto: "listo",
                uso: UsoTokens(entrada: 20, salida: 8)
            )
        ])
        let bucle = ToolLoop(motor: motor, herramientas: [HerramientaFalsa()])

        let resultado = try await bucle.ejecutar(
            historial: [ChatMessage(rol: .usuario, texto: "x")]
        )

        XCTAssertEqual(resultado.usoTotal, UsoTokens(entrada: 30, salida: 12))

        let ultimo = try XCTUnwrap(resultado.mensajesNuevos.last)
        XCTAssertEqual(ultimo.rol, .asistente)
        XCTAssertEqual(ultimo.tokensEntrada, 30)
        XCTAssertEqual(ultimo.tokensSalida, 12)

        // Solo el ultimo asistente lleva el total: si se repitiera en cada
        // llamada, el acumulado del chat contaria dos veces.
        XCTAssertNil(resultado.mensajesNuevos.first?.tokensEntrada)
    }

    func testVariasHerramientasEnUnTurnoSeEjecutanTodas() async throws {
        let motor = MotorFalso([
            RespuestaModelo(texto: "", toolCalls: [
                ToolCall(id: "c1", nombre: "una", argumentos: "{}"),
                ToolCall(id: "c2", nombre: "otra", argumentos: "{}")
            ]),
            RespuestaModelo(texto: "fin")
        ])
        let una = HerramientaFalsa(nombre: "una", resultado: "r1")
        let otra = HerramientaFalsa(nombre: "otra", resultado: "r2")
        let bucle = ToolLoop(motor: motor, herramientas: [una, otra])

        let resultado = try await bucle.ejecutar(
            historial: [ChatMessage(rol: .usuario, texto: "x")]
        )

        let resultados = resultado.mensajesNuevos.filter { $0.rol == .herramienta }
        XCTAssertEqual(resultados.map(\.texto), ["r1", "r2"])
        XCTAssertEqual(resultados.map(\.toolCallId), ["c1", "c2"])
    }

    func testErrorDeRedDelMotorSePropaga() async {
        let motor = MotorQueFalla(error: ErrorAPI.red("sin conexion"))
        let bucle = ToolLoop(motor: motor, herramientas: [])

        do {
            _ = try await bucle.ejecutar(historial: [])
            XCTFail("deberia lanzar")
        } catch let error as ErrorAPI {
            XCTAssertEqual(error, .red("sin conexion"))
        } catch {
            XCTFail("error inesperado: \(error)")
        }
    }
}

/// Motor que siempre lanza el mismo error.
final class MotorQueFalla: ChatEngine {
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func responder(
        mensajes: [ChatMessage],
        herramientas: [ToolDefinition],
        alRecibirTexto: ((String) -> Void)?
    ) async throws -> RespuestaModelo {
        throw error
    }
}
