import XCTest

@testable import NodoCore

final class UsoTokensTests: XCTestCase {
    func testSumaDosUsos() {
        let total = UsoTokens(entrada: 10, salida: 4)
            .sumando(UsoTokens(entrada: 20, salida: 8))

        XCTAssertEqual(total, UsoTokens(entrada: 30, salida: 12))
        XCTAssertEqual(total.total, 42)
    }

    func testCostoConPreciosConocidos() {
        // Cifras de ejemplo, no precios de ningun proveedor real.
        let uso = UsoTokens(entrada: 1_000_000, salida: 500_000)

        let costo = CostoEstimado.costo(
            uso: uso,
            precioEntrada: 2.0,
            precioSalida: 4.0
        )

        XCTAssertEqual(costo ?? -1, 4.0, accuracy: 0.0000001)
    }

    func testSinPreciosNoHayCosto() {
        let uso = UsoTokens(entrada: 100, salida: 50)

        XCTAssertNil(CostoEstimado.costo(uso: uso, precioEntrada: nil, precioSalida: 4.0))
        XCTAssertNil(CostoEstimado.costo(uso: uso, precioEntrada: 2.0, precioSalida: nil))
        XCTAssertNil(CostoEstimado.costo(uso: uso, precioEntrada: nil, precioSalida: nil))
    }

    func testAcumuladoSumaSoloLosMensajesConCifras() {
        let mensajes = [
            ChatMessage(rol: .usuario, texto: "hola"),
            ChatMessage(rol: .asistente, texto: "uno", tokensEntrada: 100, tokensSalida: 50),
            ChatMessage(rol: .asistente, texto: "dos", tokensEntrada: 200, tokensSalida: 100)
        ]

        let uso = CostoEstimado.usoAcumulado(de: mensajes)
        XCTAssertEqual(uso, UsoTokens(entrada: 300, salida: 150))

        let costo = CostoEstimado.acumulado(
            mensajes: mensajes,
            precioEntrada: 2.0,
            precioSalida: 4.0
        )
        XCTAssertEqual(costo ?? -1, 0.0012, accuracy: 0.0000001)
    }

    func testAcumuladoSinCifrasOSinPreciosEsNil() {
        let sinCifras = [ChatMessage(rol: .usuario, texto: "hola")]
        XCTAssertNil(CostoEstimado.usoAcumulado(de: sinCifras))
        XCTAssertNil(CostoEstimado.acumulado(
            mensajes: sinCifras,
            precioEntrada: 2.0,
            precioSalida: 4.0
        ))

        let conCifras = [
            ChatMessage(rol: .asistente, texto: "x", tokensEntrada: 10, tokensSalida: 5)
        ]
        XCTAssertNil(CostoEstimado.acumulado(
            mensajes: conCifras,
            precioEntrada: nil,
            precioSalida: 4.0
        ))
    }
}

final class CompatibilidadConsumoTests: XCTestCase {
    func testJSONViejoDeChatMessageSinTokensDecodifica() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "rol": "asistente",
          "texto": "hola",
          "fecha": 0.0,
          "toolCalls": []
        }
        """

        let mensaje = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))

        XCTAssertEqual(mensaje.id, id)
        XCTAssertEqual(mensaje.texto, "hola")
        XCTAssertNil(mensaje.tokensEntrada)
        XCTAssertNil(mensaje.tokensSalida)
        XCTAssertNil(mensaje.uso)
    }

    func testJSONViejoDeProviderConfigSinPreciosDecodifica() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "nombre": "Ejemplo",
          "protocolo": "chatCompletions",
          "baseURL": "https://api.ejemplo.test/v1",
          "modelo": "modelo-x"
        }
        """

        let proveedor = try JSONDecoder().decode(ProviderConfig.self, from: Data(json.utf8))

        XCTAssertEqual(proveedor.id, id)
        XCTAssertEqual(proveedor.modelo, "modelo-x")
        XCTAssertNil(proveedor.precioEntradaPorMillon)
        XCTAssertNil(proveedor.precioSalidaPorMillon)
    }
}
