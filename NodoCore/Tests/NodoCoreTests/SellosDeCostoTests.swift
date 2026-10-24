import XCTest

@testable import NodoCore

/// Sellado y lectura del costo por mensaje (COST.1 y COST.3).
///
/// El "activo caro" se simula poniendo el proveedor caro PRIMERO en la lista,
/// que es el orden en el que la app resuelve el activo; el sello del legado
/// tiene que salir igualmente del proveedor barato anotado en el mensaje.
final class SellosDeCostoTests: XCTestCase {
    private let idBarato = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
    private let idCaro = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!

    private var barato: ProviderConfig {
        ProviderConfig(
            id: idBarato,
            nombre: "Barato",
            baseURL: "https://api.ejemplo.test/v1",
            modelo: "modelo-barato",
            precioEntradaPorMillon: 0.10,
            precioSalidaPorMillon: 0.20
        )
    }

    private var caro: ProviderConfig {
        ProviderConfig(
            id: idCaro,
            nombre: "Caro",
            baseURL: "https://api.ejemplo.test/v1",
            modelo: "modelo-caro",
            precioEntradaPorMillon: 10,
            precioSalidaPorMillon: 20
        )
    }

    // MARK: - Sello de un mensaje nuevo

    func testSellarEscribeElCostoConLosPreciosDelProveedorYNoEsEstimacion() throws {
        var mensaje = ChatMessage(
            rol: .asistente,
            texto: "respuesta nueva",
            tokensEntrada: 1_000_000,
            tokensSalida: 500_000,
            proveedorID: idBarato
        )

        SellosDeCosto.sellar(&mensaje, proveedor: barato)

        // 1M x 0.10 + 0.5M x 0.20 = 0.20
        let sello = try XCTUnwrap(mensaje.costoSelladoUSD)
        XCTAssertEqual(sello, 0.20, accuracy: 0.0000001)
        XCTAssertFalse(mensaje.costoEsEstimacion)
    }

    func testSellarNoReescribeUnSelloExistente() throws {
        var mensaje = ChatMessage(
            rol: .asistente,
            texto: "ya pagada",
            tokensEntrada: 1_000_000,
            tokensSalida: 0,
            proveedorID: idBarato,
            costoSelladoUSD: 0.5
        )

        SellosDeCosto.sellar(&mensaje, proveedor: caro)

        let sello = try XCTUnwrap(mensaje.costoSelladoUSD)
        XCTAssertEqual(sello, 0.5, accuracy: 0.0000001)
        XCTAssertFalse(mensaje.costoEsEstimacion)
    }

    func testSellarSinUsoNoEscribeNada() {
        var mensaje = ChatMessage(rol: .asistente, texto: "sin cifras")
        SellosDeCosto.sellar(&mensaje, proveedor: barato)
        XCTAssertNil(mensaje.costoSelladoUSD)
    }

    // MARK: - Migracion de legados (COST.3)

    func testSellarLegadoUsaSuProveedorPropioAunqueElActivoSeaCaro() throws {
        let proveedores = [caro, barato]
        var mensajes = [
            ChatMessage(
                rol: .asistente,
                texto: "respuesta vieja",
                tokensEntrada: 1_000_000,
                tokensSalida: 500_000,
                proveedorID: idBarato
            )
        ]

        // El proveedor del chat tambien es el caro: aun asi manda el del
        // mensaje, que es el que lo genero.
        let cambios = SellosDeCosto.sellarLegados(
            en: &mensajes,
            proveedores: proveedores,
            proveedorDelChat: idCaro
        )

        XCTAssertEqual(cambios, 1)
        let sello = try XCTUnwrap(mensajes[0].costoSelladoUSD)
        // 1M x 0.10 + 0.5M x 0.20 = 0.20, no los 20 del proveedor caro.
        XCTAssertEqual(sello, 0.20, accuracy: 0.0000001)
        XCTAssertTrue(mensajes[0].costoEsEstimacion)
    }

    func testSellarLegadoSinProveedorResolubleQuedaSinSello() {
        var mensajes = [
            ChatMessage(
                rol: .asistente,
                texto: "huerfana",
                tokensEntrada: 1_000,
                tokensSalida: 500,
                proveedorID: UUID()
            )
        ]

        let cambios = SellosDeCosto.sellarLegados(
            en: &mensajes,
            proveedores: [caro, barato],
            proveedorDelChat: nil
        )

        XCTAssertEqual(cambios, 0)
        XCTAssertNil(mensajes[0].costoSelladoUSD)
        XCTAssertFalse(mensajes[0].costoEsEstimacion)
    }

    func testSellarLegadoSinPreciosQuedaSinSello() {
        let sinPrecios = ProviderConfig(
            id: idBarato,
            nombre: "Sin precios",
            baseURL: "https://api.ejemplo.test/v1",
            modelo: "modelo-barato"
        )
        var mensajes = [
            ChatMessage(
                rol: .asistente,
                texto: "sin precios",
                tokensEntrada: 1_000,
                tokensSalida: 500,
                proveedorID: idBarato
            )
        ]

        let cambios = SellosDeCosto.sellarLegados(
            en: &mensajes,
            proveedores: [sinPrecios],
            proveedorDelChat: nil
        )

        XCTAssertEqual(cambios, 0)
        XCTAssertNil(mensajes[0].costoSelladoUSD)
    }

    func testSellarLegadosNoTocaLosMensajesQueYaTienenSello() {
        var mensajes = [
            ChatMessage(
                rol: .asistente,
                texto: "ya sellada",
                tokensEntrada: 1_000,
                tokensSalida: 500,
                proveedorID: idBarato,
                costoSelladoUSD: 0.123
            )
        ]

        let cambios = SellosDeCosto.sellarLegados(
            en: &mensajes,
            proveedores: [barato, caro],
            proveedorDelChat: nil
        )

        XCTAssertEqual(cambios, 0)
        XCTAssertEqual(mensajes[0].costoSelladoUSD, 0.123)
        XCTAssertFalse(mensajes[0].costoEsEstimacion)
    }

    // MARK: - Lector unico

    func testAcumuladoSelladoLeeElSelloYNoRevalua() throws {
        let mensajes = [
            ChatMessage(
                rol: .asistente,
                texto: "pagada",
                tokensEntrada: 1_000_000,
                tokensSalida: 0,
                proveedorID: idBarato,
                costoSelladoUSD: 0.5
            )
        ]

        // Con los precios de hoy costaria 10, pero el sello manda.
        let total = try XCTUnwrap(CostoEstimado.acumuladoSellado(
            mensajes: mensajes,
            proveedores: [caro],
            proveedorDelChat: idCaro
        ))
        XCTAssertEqual(total, 0.5, accuracy: 0.0000001)
    }

    func testAcumuladoSelladoValoraElLegadoSinSelloConSuProveedor() throws {
        let mensajes = [
            ChatMessage(
                rol: .asistente,
                texto: "legado",
                tokensEntrada: 1_000_000,
                tokensSalida: 0,
                proveedorID: idBarato
            )
        ]

        let total = try XCTUnwrap(CostoEstimado.acumuladoSellado(
            mensajes: mensajes,
            proveedores: [caro, barato],
            proveedorDelChat: idCaro
        ))
        XCTAssertEqual(total, 0.10, accuracy: 0.0000001)
    }

    func testAcumuladoSelladoSinProveedorResolubleEsNil() {
        let mensajes = [
            ChatMessage(
                rol: .asistente,
                texto: "huerfana",
                tokensEntrada: 1_000,
                tokensSalida: 500
            )
        ]

        XCTAssertNil(CostoEstimado.acumuladoSellado(
            mensajes: mensajes,
            proveedores: [barato, caro],
            proveedorDelChat: nil
        ))
    }

    // MARK: - Codable tolerante

    func testJSONViejoDeMensajeSinSelloDecodifica() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "rol": "asistente",
          "texto": "hola",
          "fecha": 0.0,
          "toolCalls": [],
          "tokensEntrada": 10,
          "tokensSalida": 5
        }
        """

        let mensaje = try JSONDecoder().decode(
            ChatMessage.self,
            from: Data(json.utf8)
        )

        XCTAssertNil(mensaje.costoSelladoUSD)
        XCTAssertFalse(mensaje.costoEsEstimacion)
    }
}
