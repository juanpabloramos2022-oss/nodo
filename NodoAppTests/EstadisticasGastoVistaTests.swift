import Foundation
import XCTest

@testable import Nodo
import NodoCore

/// Nivel 1 de IDEA5: la agregacion pura de uso y gasto local.
///
/// POR QUE sin SwiftUI: la vista Gasto solo pinta `EstadisticasGasto`, que se
/// calcula sobre los sellos y los metadatos (fecha, modelo) de las
/// conversaciones persistidas. Estos tests construyen conversaciones con sellos
/// simulados de varios modelos y periodos y afirman los tres tramos y el
/// reparto por modelo contra la suma manual. Un Chat Temporal sembrado no puede
/// aparecer en ningun agregado (invariante de cero rastro de B2.2).
@MainActor
final class EstadisticasGastoVistaTests: XCTestCase {

    /// Fecha fija a mitad de mes: los tres tramos son estables en cualquier
    /// zona horaria (dia 15/16 en UTC, Bogota y Tokio).
    private let ahora = Date(timeIntervalSince1970: 1_750_000_000)

    private func fecha(_ valor: Date, dias: Int = 0, meses: Int = 0) throws -> Date {
        let calendario = Calendar(identifier: .gregorian)
        if dias != 0 {
            return try XCTUnwrap(
                calendario.date(byAdding: .day, value: dias, to: valor)
            )
        }
        return try XCTUnwrap(
            calendario.date(byAdding: .month, value: meses, to: valor)
        )
    }

    /// Un mensaje sellado del asistente: consumo, fecha, modelo y sello.
    private func sellado(
        fecha: Date,
        proveedorID: UUID?,
        usd: Double,
        tokens: Int = 1_000
    ) -> ChatMessage {
        ChatMessage(
            rol: .asistente,
            texto: "Respuesta sellada.",
            fecha: fecha,
            tokensEntrada: tokens,
            tokensSalida: 500,
            proveedorID: proveedorID,
            costoSelladoUSD: usd
        )
    }

    /// Configura dos proveedores con modelos distintos y devuelve sus ids.
    private func dosProveedores(
        en arnes: ArnesApp
    ) -> (a: ProviderConfig, b: ProviderConfig) {
        var config = arnes.estado.config
        config.proveedores[0].modelo = "inferhub/modelo-alfa"
        let a = config.proveedores[0]
        let b = ProviderConfig(
            nombre: "Proveedor B",
            baseURL: "https://api.b.test/v1",
            modelo: "inferhub/modelo-beta"
        )
        config.proveedores.append(b)
        arnes.estado.config = config
        return (a, b)
    }

    /// Las conversaciones del guion: dos normales y una temporal.
    private func conversacionesSembradas(
        a: ProviderConfig,
        b: ProviderConfig
    ) throws -> [Conversation] {
        let otroDiaMes = try fecha(ahora, dias: -1)
        let mesAnterior = try fecha(ahora, meses: -1)

        let normal1 = Conversation(
            titulo: "Normal 1",
            mensajes: [
                sellado(fecha: ahora, proveedorID: a.id, usd: 1.50),
                sellado(fecha: ahora, proveedorID: b.id, usd: 0.50),
                sellado(fecha: otroDiaMes, proveedorID: a.id, usd: 2.00),
                sellado(fecha: mesAnterior, proveedorID: a.id, usd: 3.00)
            ],
            proveedorID: a.id
        )
        // El ultimo mensaje no trae proveedor propio: hereda el del chat.
        let normal2 = Conversation(
            titulo: "Normal 2",
            mensajes: [
                sellado(fecha: ahora, proveedorID: nil, usd: 0.25),
                sellado(fecha: otroDiaMes, proveedorID: b.id, usd: 0.75)
            ],
            proveedorID: b.id
        )
        // Chat Temporal: su sello NO puede entrar en ningun tramo.
        let temporal = Conversation(
            titulo: "Temporal",
            mensajes: [
                sellado(fecha: ahora, proveedorID: a.id, usd: 99.00)
            ],
            proveedorID: a.id,
            esTemporal: true
        )
        return [normal1, normal2, temporal]
    }

    private func fila(
        _ nombre: String,
        _ clave: String,
        _ mensajes: Int,
        _ usd: Double
    ) -> FilaModeloEstadistica {
        FilaModeloEstadistica(
            clave: clave,
            nombre: nombre,
            mensajes: mensajes,
            usd: usd
        )
    }

    // MARK: - Nivel 1: los tres tramos y el reparto por modelo

    /// (1) Hoy, Este mes y Total historico son la suma exacta de los sellos de
    /// cada periodo, con el reparto por modelo ordenado de mayor a menor gasto.
    func testLosAgregadosCuadranConLaSumaManual() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        let (a, b) = dosProveedores(en: arnes)
        let conversaciones = try conversacionesSembradas(a: a, b: b)

        let estadisticas = arnes.estado.estadisticasDeGasto(
            en: conversaciones,
            ahora: ahora
        )

        // Hoy: 1,50 + 0,50 + 0,25 = 2,25 en 3 mensajes.
        XCTAssertEqual(estadisticas.hoy.mensajes, 3)
        XCTAssertEqual(estadisticas.hoy.usd, 2.25, accuracy: 1e-9)
        XCTAssertEqual(
            estadisticas.hoy.modelos,
            [
                fila("modelo-alfa", "inferhub/modelo-alfa", 1, 1.50),
                fila("modelo-beta", "inferhub/modelo-beta", 2, 0.75)
            ]
        )

        // Este mes: hoy + el otro dia del mes = 5 mensajes y 5,00.
        XCTAssertEqual(estadisticas.mes.mensajes, 5)
        XCTAssertEqual(estadisticas.mes.usd, 5.00, accuracy: 1e-9)
        XCTAssertEqual(
            estadisticas.mes.modelos,
            [
                fila("modelo-alfa", "inferhub/modelo-alfa", 2, 3.50),
                fila("modelo-beta", "inferhub/modelo-beta", 3, 1.50)
            ]
        )

        // Total historico: + el mes anterior = 6 mensajes y 8,00.
        XCTAssertEqual(estadisticas.total.mensajes, 6)
        XCTAssertEqual(estadisticas.total.usd, 8.00, accuracy: 1e-9)
        XCTAssertEqual(
            estadisticas.total.modelos,
            [
                fila("modelo-alfa", "inferhub/modelo-alfa", 3, 6.50),
                fila("modelo-beta", "inferhub/modelo-beta", 3, 1.50)
            ]
        )
    }

    /// (2) Los conteos de cada tramo son la suma de sus filas por modelo.
    func testLosConteosCuadranConSusFilasPorModelo() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        let (a, b) = dosProveedores(en: arnes)
        let estadisticas = arnes.estado.estadisticasDeGasto(
            en: try conversacionesSembradas(a: a, b: b),
            ahora: ahora
        )

        for tramo in [estadisticas.hoy, estadisticas.mes, estadisticas.total] {
            XCTAssertEqual(
                tramo.modelos.reduce(0) { $0 + $1.mensajes },
                tramo.mensajes
            )
            XCTAssertEqual(
                tramo.modelos.reduce(0.0) { $0 + $1.usd },
                tramo.usd,
                accuracy: 1e-9
            )
        }
    }

    // MARK: - Invariante: un temporal no deja rastro

    /// (3) El Chat Temporal sembrado (sello de $99,00) no aparece en ningun
    /// agregado: sin el, las cifras son las mismas.
    func testElHiloTemporalNoApareceEnNingunAgregado() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        let (a, b) = dosProveedores(en: arnes)
        let todas = try conversacionesSembradas(a: a, b: b)
        let sinTemporal = todas.filter { !$0.esTemporal }

        let conTemporal = arnes.estado.estadisticasDeGasto(
            en: todas,
            ahora: ahora
        )
        let soloNormales = arnes.estado.estadisticasDeGasto(
            en: sinTemporal,
            ahora: ahora
        )

        XCTAssertEqual(conTemporal, soloNormales)
        XCTAssertEqual(conTemporal.hoy.usd, 2.25, accuracy: 1e-9)
        XCTAssertEqual(conTemporal.total.usd, 8.00, accuracy: 1e-9)
        XCTAssertFalse(
            conTemporal.total.usd > 90,
            "El sello del temporal no puede sumar al total"
        )
    }

    // MARK: - Mensaje sin costo resoluble

    /// (4) Una llamada real sin sello y sin proveedor resoluble se cuenta (es
    /// un mensaje) pero aporta USD cero: no se inventa un costo.
    func testUnMensajeSinCostoSeCuentaConDolarCero() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        let (a, _) = dosProveedores(en: arnes)

        let conversacion = Conversation(
            titulo: "Sin sello",
            mensajes: [
                ChatMessage(
                    rol: .asistente,
                    texto: "Sin proveedor.",
                    fecha: ahora,
                    tokensEntrada: 10,
                    tokensSalida: 5
                ),
                sellado(fecha: ahora, proveedorID: a.id, usd: 1.00)
            ]
        )

        let estadisticas = arnes.estado.estadisticasDeGasto(
            en: [conversacion],
            ahora: ahora
        )

        XCTAssertEqual(estadisticas.hoy.mensajes, 2)
        XCTAssertEqual(estadisticas.hoy.usd, 1.00, accuracy: 1e-9)
        XCTAssertEqual(
            estadisticas.hoy.modelos,
            [
                fila("modelo-alfa", "inferhub/modelo-alfa", 1, 1.00),
                fila("Sin modelo", "", 1, 0.00)
            ]
        )
    }

    // MARK: - Contrato: el rotulo no es una factura

    /// El rotulo visible es, con todas las letras, «Gasto sellado local».
    func testElRotuloDeclaraElAlcanceLocal() {
        XCTAssertEqual(EstadisticasGasto.rotulo, "Gasto sellado local")
    }
}