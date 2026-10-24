import Foundation
import XCTest

@testable import Nodo
import NodoCore

/// Pruebas de la vista Gasto sobre el libro de sellos (SPEND.1-SPEND.3).
///
/// POR QUE sobre `ArnesApp`: la vista no calcula nada, lee
/// `EstadoApp.resumenDeGasto`, que a su vez lee `config.usoApp`. Sembrar el
/// libro en el arnes ejercita la misma ruta que usa la app real y deja fuera al
/// proveedor activo, que es justo lo que exige el contrato.
@MainActor
final class GastoVistaTests: XCTestCase {

    /// Una llamada sembrada en el libro: fecha, tokens, USD sellado, modelo y
    /// si su proveedor tenia precios.
    private struct Sembrado {
        let fecha: Date
        let uso: UsoTokens
        let usd: Double
        let modelo: String
        let conPrecio: Bool
    }

    /// Mete los registros en el libro del estado, por la misma API publica que
    /// usa `registrarGasto`.
    private func sembrar(_ registros: [Sembrado], en arnes: ArnesApp) {
        for registro in registros {
            arnes.estado.config.usoApp.registrar(
                uso: registro.uso,
                usd: registro.usd,
                fecha: registro.fecha,
                modelo: registro.modelo,
                conPrecio: registro.conPrecio
            )
        }
    }

    /// Suma esperada del periodo, calculada con las claves del propio libro.
    private func suma(
        _ registros: [Sembrado],
        donde incluir: (String) -> Bool,
        clave: (Date) -> String
    ) -> (usd: Double, tokens: Int, tokensSinPrecio: Int) {
        var usd = 0.0
        var tokens = 0
        var tokensSinPrecio = 0

        for registro in registros where incluir(clave(registro.fecha)) {
            usd += registro.usd
            tokens += registro.uso.total
            if !registro.conPrecio {
                tokensSinPrecio += registro.uso.total
            }
        }
        return (usd, tokens, tokensSinPrecio)
    }

    // MARK: - SPEND.1: agregacion

    /// (1) Los totales de HOY y del MES son la suma exacta de los sellos
    /// sembrados en el periodo. No hay valoracion con el proveedor activo.
    func testTotalesDeLaVistaSonLaSumaExactaDeLosSellos() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let ahora = Date()
        let calendario = Calendar(identifier: .gregorian)
        let inicioMes = try XCTUnwrap(
            calendario.date(from: calendario.dateComponents([.year, .month], from: ahora))
        )
        let otroDiaDelMes = try XCTUnwrap(
            calendario.date(byAdding: .day, value: 1, to: inicioMes)
        )
        let mesAnterior = try XCTUnwrap(
            calendario.date(byAdding: .month, value: -1, to: inicioMes)
        )

        let registros = [
            Sembrado(
                fecha: ahora,
                uso: UsoTokens(entrada: 1_000_000, salida: 500_000),
                usd: 2.00,
                modelo: "modelo-a",
                conPrecio: true
            ),
            Sembrado(
                fecha: ahora,
                uso: UsoTokens(entrada: 100_000, salida: 0),
                usd: 0.10,
                modelo: "modelo-b",
                conPrecio: true
            ),
            Sembrado(
                fecha: otroDiaDelMes,
                uso: UsoTokens(entrada: 200_000, salida: 100_000),
                usd: 0.40,
                modelo: "modelo-a",
                conPrecio: true
            ),
            // Mes anterior: no puede colarse en los totales del mes en curso.
            Sembrado(
                fecha: mesAnterior,
                uso: UsoTokens(entrada: 1_000_000, salida: 0),
                usd: 1.00,
                modelo: "modelo-a",
                conPrecio: true
            ),
            // Uso sin precio: tokens reales, USD desconocido (no inventado).
            Sembrado(
                fecha: ahora,
                uso: UsoTokens(entrada: 300, salida: 0),
                usd: 0,
                modelo: "modelo-sin-precio",
                conPrecio: false
            )
        ]
        sembrar(registros, en: arnes)

        let claveHoy = UsoApp.claveDia(ahora)
        let claveMes = UsoApp.claveMes(ahora)
        let esperadoHoy = suma(
            registros,
            donde: { $0 == claveHoy },
            clave: UsoApp.claveDia
        )
        let esperadoMes = suma(
            registros,
            donde: { $0 == claveMes },
            clave: UsoApp.claveMes
        )

        let resumen = arnes.estado.resumenDeGasto(ahora: ahora)

        XCTAssertEqual(resumen.hoy.usd, esperadoHoy.usd, accuracy: 1e-12)
        XCTAssertEqual(resumen.mes.usd, esperadoMes.usd, accuracy: 1e-12)
        XCTAssertEqual(resumen.hoy.uso.total, esperadoHoy.tokens)
        XCTAssertEqual(resumen.mes.uso.total, esperadoMes.tokens)
        XCTAssertEqual(resumen.sinPrecio.total, esperadoMes.tokensSinPrecio)

        // El mes anterior queda fuera: el libro no mezcla periodos.
        XCTAssertLessThan(resumen.mes.usd, 2.00 + 0.10 + 0.40 + 0.0001)
    }

    /// (2) El desglose por modelo cuadra con el total del mes; la linea sin
    /// precio solo aporta tokens y no un USD inventado.
    func testElDesglosePorModeloCuadraConElTotalDelMes() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let ahora = Date()
        let inicioMes = try XCTUnwrap(
            Calendar(identifier: .gregorian).date(
                from: Calendar(identifier: .gregorian)
                    .dateComponents([.year, .month], from: ahora)
            )
        )

        let registros = [
            Sembrado(
                fecha: ahora,
                uso: UsoTokens(entrada: 1_000_000, salida: 0),
                usd: 1.00,
                modelo: "modelo-a",
                conPrecio: true
            ),
            Sembrado(
                fecha: ahora,
                uso: UsoTokens(entrada: 0, salida: 500_000),
                usd: 0.50,
                modelo: "modelo-b",
                conPrecio: true
            ),
            Sembrado(
                fecha: inicioMes,
                uso: UsoTokens(entrada: 250_000, salida: 0),
                usd: 0.25,
                modelo: "modelo-a",
                conPrecio: true
            ),
            Sembrado(
                fecha: ahora,
                uso: UsoTokens(entrada: 7_000, salida: 3_000),
                usd: 0,
                modelo: "modelo-sin-precio",
                conPrecio: false
            )
        ]
        sembrar(registros, en: arnes)

        let resumen = arnes.estado.resumenDeGasto(ahora: ahora)
        let sumaDeModelos = resumen.modelos.reduce(0.0) { $0 + $1.usd }

        XCTAssertEqual(sumaDeModelos, resumen.mes.usd, accuracy: 1e-12)
        XCTAssertEqual(resumen.mes.usd, 1.75, accuracy: 1e-12)

        // Los tokens tambien cuadran: modelos + linea sin precio = mes.
        let tokensDeModelos = resumen.modelos.reduce(0) { $0 + $1.uso.total }
        XCTAssertEqual(
            tokensDeModelos + resumen.sinPrecio.total,
            resumen.mes.uso.total
        )

        // El uso sin precio se declara aparte: 10.000 tokens y cero USD.
        XCTAssertEqual(resumen.sinPrecio.total, 10_000)
        XCTAssertFalse(
            resumen.modelos.contains { $0.clave == "modelo-sin-precio" },
            "Un uso sin precio no puede aparecer como un modelo de cero dolares"
        )

        // El porcentaje de cada fila es su parte del mes.
        for fila in resumen.modelos {
            let esperado = resumen.mes.usd > 0
                ? fila.usd / resumen.mes.usd * 100
                : 0
            XCTAssertEqual(fila.porcentaje, esperado, accuracy: 1e-9)
        }

        // Las barras del mes tambien suman el total: una por dia en curso.
        let diasEnElMes = try XCTUnwrap(
            Calendar(identifier: .gregorian)
                .range(of: .day, in: .month, for: ahora)?.count
        )
        XCTAssertEqual(resumen.diasDelMes.count, diasEnElMes)
        XCTAssertEqual(
            resumen.diasDelMes.reduce(0.0) { $0 + $1.usd },
            resumen.mes.usd,
            accuracy: 1e-12
        )
    }

    /// Un libro escrito antes de SPEND.1 no trae reparto por modelo: la vista
    /// declara esa diferencia como "Sin modelo" en vez de esconderla, y el
    /// desglose sigue cuadrando con el total.
    func testUnLibroViejoSinDesgloseSeDeclaraComoSinModelo() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let ahora = Date()
        arnes.estado.config.usoApp.meses[UsoApp.claveMes(ahora)] = TramoDeGasto(
            uso: UsoTokens(entrada: 1_000, salida: 500),
            usd: 0.05
        )

        let resumen = arnes.estado.resumenDeGasto(ahora: ahora)
        XCTAssertEqual(resumen.modelos.count, 1)
        XCTAssertEqual(resumen.modelos.first?.nombre, "Sin modelo")
        XCTAssertEqual(
            resumen.modelos.reduce(0.0) { $0 + $1.usd },
            resumen.mes.usd,
            accuracy: 1e-12
        )
    }

    /// (3) La linea "sin precio" existe solo si hubo usos sin precio.
    func testLaLineaSinPrecioSoloApareceSiHayUsosSinPrecio() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let ahora = Date()
        arnes.estado.config.usoApp.registrar(
            uso: UsoTokens(entrada: 1_000, salida: 500),
            usd: 0.01,
            fecha: ahora,
            modelo: "modelo-con-precio"
        )

        let soloConPrecio = arnes.estado.resumenDeGasto(ahora: ahora)
        XCTAssertFalse(soloConPrecio.tieneSinPrecio)
        XCTAssertEqual(soloConPrecio.sinPrecio.total, 0)

        arnes.estado.config.usoApp.registrar(
            uso: UsoTokens(entrada: 40, salida: 2),
            usd: 0,
            fecha: ahora,
            modelo: "modelo-sin-precio",
            conPrecio: false
        )

        let conSinPrecio = arnes.estado.resumenDeGasto(ahora: ahora)
        XCTAssertTrue(conSinPrecio.tieneSinPrecio)
        XCTAssertEqual(conSinPrecio.sinPrecio.total, 42)
    }

    // MARK: - Contrato: cambiar de modelo no mueve las cifras

    /// (4) Regresion clave: cambiar el proveedor activo (y sus precios) no
    /// cambia ni un centavo de los totales del libro.
    func testCambiarElProveedorActivoNoCambiaLosTotales() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let ahora = Date()
        sembrar(
            [
                Sembrado(
                    fecha: ahora,
                    uso: UsoTokens(entrada: 800_000, salida: 200_000),
                    usd: 0.60,
                    modelo: "modelo-sellado",
                    conPrecio: true
                ),
                Sembrado(
                    fecha: ahora,
                    uso: UsoTokens(entrada: 50_000, salida: 0),
                    usd: 0,
                    modelo: "modelo-sin-precio",
                    conPrecio: false
                )
            ],
            en: arnes
        )

        let antes = arnes.estado.resumenDeGasto(ahora: ahora)

        // Otro proveedor pasa a ser el activo y sus precios son absurdos: si
        // la vista recalculara contra el, las cifras se dispararian.
        let caro = ProviderConfig(
            nombre: "Caro",
            baseURL: "https://api.caro.test/v1",
            modelo: "modelo-carísimo",
            precioEntradaPorMillon: 1_000,
            precioSalidaPorMillon: 2_000
        )
        arnes.estado.config.proveedores.append(caro)
        arnes.estado.config.proveedorActivo = caro.id

        let despues = arnes.estado.resumenDeGasto(ahora: ahora)

        XCTAssertEqual(despues, antes)
        XCTAssertEqual(despues.hoy.usd, 0.60, accuracy: 1e-12)
        XCTAssertEqual(despues.mes.usd, 0.60, accuracy: 1e-12)
        XCTAssertEqual(despues.sinPrecio.total, 50_000)
    }

    // MARK: - SPEND.3: superficies consistentes

    /// Las superficies que hoy ensenan un costo (cabecera, lista, pie, Estado y
    /// franja de tope) leen el sello del mensaje. Cambiar el proveedor activo o
    /// sus precios no puede mover ninguna de ellas.
    func testLasSuperficiesDeCostoSiguenElSelloAlCambiarDeProveedor() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let proveedor = arnes.proveedor
        var respuesta = ChatMessage(
            rol: .asistente,
            texto: "Respuesta sellada.",
            tokensEntrada: 1_000_000,
            tokensSalida: 500_000,
            proveedorID: proveedor.id
        )
        SellosDeCosto.sellar(&respuesta, proveedor: proveedor)
        let sello = try XCTUnwrap(respuesta.costoSelladoUSD)

        let conversacion = Conversation(
            mensajes: [
                ChatMessage(rol: .usuario, texto: "Hola"),
                respuesta
            ],
            proveedorID: proveedor.id
        )
        arnes.estado.conversacion = conversacion

        // Las tres caras que se pueden leer sin SwiftUI: cabecera/Estado,
        // pie de respuesta y pastilla de la lista.
        let acumuladoAntes = try XCTUnwrap(arnes.estado.costoAcumuladoDelChat)
        let pieAntes = try XCTUnwrap(arnes.estado.costo(de: respuesta))
        let listaAntes = HistorialConversaciones.datosFila(
            de: conversacion,
            proveedores: arnes.estado.config.proveedores
        )
        let listaCostoAntes = try XCTUnwrap(listaAntes.costo)
        XCTAssertEqual(acumuladoAntes, sello, accuracy: 1e-12)
        XCTAssertEqual(pieAntes, sello, accuracy: 1e-12)
        XCTAssertEqual(listaCostoAntes, sello, accuracy: 1e-12)

        // Otro proveedor pasa a ser el activo y el original se vuelve carisimo:
        // ninguna superficie puede revaluar la historia ya sellada.
        let caro = ProviderConfig(
            nombre: "Caro",
            baseURL: "https://api.caro.test/v1",
            modelo: "modelo-carísimo",
            precioEntradaPorMillon: 1_000,
            precioSalidaPorMillon: 2_000
        )
        arnes.estado.config.proveedores.append(caro)
        arnes.estado.config.proveedorActivo = caro.id
        let indiceOriginal = try XCTUnwrap(
            arnes.estado.config.proveedores.firstIndex { $0.id == proveedor.id }
        )
        var original = arnes.estado.config.proveedores[indiceOriginal]
        original.precioEntradaPorMillon = 9_999
        original.precioSalidaPorMillon = 9_999
        arnes.estado.config.proveedores[indiceOriginal] = original

        let acumuladoDespues = try XCTUnwrap(arnes.estado.costoAcumuladoDelChat)
        let pieDespues = try XCTUnwrap(arnes.estado.costo(de: respuesta))
        XCTAssertEqual(acumuladoDespues, acumuladoAntes, accuracy: 1e-12)
        XCTAssertEqual(pieDespues, pieAntes, accuracy: 1e-12)
        let listaDespues = HistorialConversaciones.datosFila(
            de: conversacion,
            proveedores: arnes.estado.config.proveedores
        )
        let listaCostoDespues = try XCTUnwrap(listaDespues.costo)
        XCTAssertEqual(listaCostoDespues, listaCostoAntes, accuracy: 1e-12)
    }
}
