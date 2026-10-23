import XCTest

@testable import NodoCore

final class MetricasChatTests: XCTestCase {
    func testOcupacionEsElUsoDelUltimoMensajeQueLoTrae() {
        let mensajes = [
            ChatMessage(rol: .asistente, texto: "vieja", tokensEntrada: 100, tokensSalida: 50),
            ChatMessage(rol: .usuario, texto: "sigue"),
            ChatMessage(rol: .asistente, texto: "nueva", tokensEntrada: 200, tokensSalida: 80)
        ]

        XCTAssertEqual(
            MetricasChat.ocupacionVentana(de: mensajes),
            UsoTokens(entrada: 200, salida: 80)
        )
    }

    func testLosMensajesPosterioresSinUsoNoBorranLaOcupacion() {
        let mensajes = [
            ChatMessage(rol: .asistente, texto: "respuesta", tokensEntrada: 10, tokensSalida: 5),
            ChatMessage(rol: .usuario, texto: "otra pregunta")
        ]

        XCTAssertEqual(
            MetricasChat.ocupacionVentana(de: mensajes),
            UsoTokens(entrada: 10, salida: 5)
        )
    }

    func testSinNingunUsoLaOcupacionEsNil() {
        let mensajes = [
            ChatMessage(rol: .usuario, texto: "hola"),
            ChatMessage(rol: .asistente, texto: "que tal")
        ]

        XCTAssertNil(MetricasChat.ocupacionVentana(de: mensajes))
        XCTAssertNil(MetricasChat.ocupacionVentana(de: []))
    }

    func testSinVentanaDefinidaNoHayPorcentaje() {
        XCTAssertNil(MetricasChat.porcentaje(ocupacion: 500, ventana: nil))
        XCTAssertNil(MetricasChat.porcentaje(ocupacion: 500, ventana: 0))
        XCTAssertNil(MetricasChat.porcentaje(ocupacion: 500, ventana: -10))
    }

    func testElPorcentajeEsElCocienteExactoYNoSeRecorta() throws {
        let medio = try XCTUnwrap(MetricasChat.porcentaje(ocupacion: 500, ventana: 1000))
        XCTAssertEqual(medio, 0.5, accuracy: 0.0000001)

        let pasado = try XCTUnwrap(MetricasChat.porcentaje(ocupacion: 1500, ventana: 1000))
        XCTAssertEqual(pasado, 1.5, accuracy: 0.0000001)
    }

    func testElAcumuladoExistenteNoCambiaDeComportamiento() {
        let mensajes = [
            ChatMessage(rol: .asistente, texto: "una", tokensEntrada: 100, tokensSalida: 50),
            ChatMessage(rol: .usuario, texto: "sin cifras"),
            ChatMessage(rol: .asistente, texto: "dos", tokensEntrada: 200, tokensSalida: 80)
        ]

        XCTAssertEqual(
            CostoEstimado.usoAcumulado(de: mensajes),
            UsoTokens(entrada: 300, salida: 130)
        )
        // La ocupacion, en cambio, solo mira la ultima respuesta.
        XCTAssertEqual(
            MetricasChat.ocupacionVentana(de: mensajes),
            UsoTokens(entrada: 200, salida: 80)
        )
    }

    func testLaOcupacionDeUnaConversacionUsaElUltimoMensajeConUso() {
        let conversacion = Conversation(mensajes: [
            ChatMessage(rol: .asistente, texto: "vieja", tokensEntrada: 100, tokensSalida: 50),
            ChatMessage(rol: .usuario, texto: "sigue"),
            ChatMessage(rol: .asistente, texto: "nueva", tokensEntrada: 200, tokensSalida: 80)
        ])

        let medida = MetricasChat.ocupacionVentana(de: conversacion)

        XCTAssertEqual(medida.tokens, 280)
        XCTAssertNil(medida.mensaje)
    }

    func testSinUsoEnLosMensajesSeUsaElUsoTrasCompactar() {
        let conversacion = Conversation(
            mensajes: [ChatMessage(rol: .usuario, texto: "hola")],
            usoTrasCompactar: UsoTokens(entrada: 30, salida: 12)
        )

        let medida = MetricasChat.ocupacionVentana(de: conversacion)

        XCTAssertEqual(medida.tokens, 42)
        XCTAssertEqual(medida.mensaje, "Ocupación medida tras compactar")
    }

    func testElUsoDeUnMensajeMandaSobreElUsoTrasCompactar() {
        let conversacion = Conversation(
            mensajes: [
                ChatMessage(
                    rol: .asistente,
                    texto: "respuesta",
                    tokensEntrada: 20,
                    tokensSalida: 5
                )
            ],
            usoTrasCompactar: UsoTokens(entrada: 300, salida: 100)
        )

        XCTAssertEqual(
            MetricasChat.ocupacionVentana(de: conversacion).tokens,
            25
        )
    }

    func testSinUsoNiCompactacionLaOcupacionEsCero() {
        let conversacion = Conversation(
            mensajes: [ChatMessage(rol: .usuario, texto: "hola")]
        )

        let medida = MetricasChat.ocupacionVentana(de: conversacion)

        XCTAssertEqual(medida.tokens, 0)
        XCTAssertNil(medida.mensaje)
    }
}
