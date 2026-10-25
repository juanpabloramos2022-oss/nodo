import Foundation
import XCTest

@testable import Nodo
import NodoCore

/// Pruebas de estado del tope mensual personal de gasto (IDEA4).
///
/// POR QUE sin SwiftUI: la banda se decide en `EstadoApp.estadoTopeMensual`,
/// que solo lee el libro SELLADO del mes. Estos tests siembran el libro por la
/// misma API publica que usa `registrarGasto` y afirman los estados en los
/// umbrales, la invariante de que cambiar de modelo no mueve el acumulado y la
/// de que la banda nunca bloquea un envio.
@MainActor
final class TopeMensualGastoTests: XCTestCase {

    /// Siembra una llamada sellada en el libro del estado.
    private func sembrar(
        usd: Double,
        en arnes: ArnesApp,
        fecha: Date = Date()
    ) {
        arnes.estado.config.usoApp.registrar(
            uso: UsoTokens(entrada: 1_000, salida: 500),
            usd: usd,
            fecha: fecha,
            modelo: arnes.proveedor.modelo,
            conPrecio: true
        )
    }

    // MARK: - Nivel 1: los dos umbrales

    /// El acumulado cruza el 80 % y el 100 % y la banda cambia de estado en
    /// ambos puntos. Los umbrales son inclusivos.
    func testLaBandaCambiaAlCruzar80Y100() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        arnes.estado.fijarTopeMensual(10.00)

        XCTAssertEqual(
            arnes.estado.estadoTopeMensual().estado,
            .bajoUmbral,
            "Sin gasto, el tope fijado deja la banda por debajo del umbral"
        )
        XCTAssertNil(arnes.estado.estadoTopeMensual().texto)

        sembrar(usd: 7.90, en: arnes)
        XCTAssertEqual(arnes.estado.estadoTopeMensual().estado, .bajoUmbral)

        // 8,00 = exactamente el 80 %: ya es aviso.
        sembrar(usd: 0.10, en: arnes)
        let aviso = arnes.estado.estadoTopeMensual()
        XCTAssertEqual(aviso.estado, .aviso)
        XCTAssertEqual(aviso.porcentajeEntero, 80)
        XCTAssertTrue(aviso.visible)
        XCTAssertFalse(aviso.bloqueaEnvio)
        XCTAssertEqual(
            aviso.texto,
            "Llevas el 80 % de tu tope mensual de gasto. "
                + "Puedes seguir enviando."
        )

        // 9,99 sigue en aviso; 10,02 = tope alcanzado (con holgura para no
        // depender del redondeo binario de 9,99 + 0,01).
        sembrar(usd: 1.99, en: arnes)
        XCTAssertEqual(arnes.estado.estadoTopeMensual().estado, .aviso)

        sembrar(usd: 0.02, en: arnes)
        let alcanzado = arnes.estado.estadoTopeMensual()
        XCTAssertEqual(alcanzado.estado, .alcanzado)
        XCTAssertEqual(alcanzado.porcentajeEntero, 100)
        XCTAssertEqual(
            alcanzado.texto,
            "Tope mensual alcanzado. Enviar sigue siendo tu decisión."
        )
        XCTAssertFalse(alcanzado.bloqueaEnvio)
    }

    /// Sin tope no hay banda, por mucho gasto que haya.
    func testSinTopeNoHayBanda() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        sembrar(usd: 50, en: arnes)

        let estado = arnes.estado.estadoTopeMensual()
        XCTAssertEqual(estado.estado, .sinTope)
        XCTAssertFalse(estado.visible)
        XCTAssertNil(estado.texto)
        XCTAssertNil(estado.tope)
    }

    /// El gasto de un mes anterior no entra en el acumulado del mes en curso.
    func testElMesAnteriorNoCuenta() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        arnes.estado.fijarTopeMensual(10.00)

        let calendario = Calendar(identifier: .gregorian)
        let ahora = Date()
        let mesAnterior = try XCTUnwrap(
            calendario.date(byAdding: .month, value: -1, to: ahora)
        )
        sembrar(usd: 100, en: arnes, fecha: mesAnterior)
        sembrar(usd: 1, en: arnes, fecha: ahora)

        let estado = arnes.estado.estadoTopeMensual(ahora: ahora)
        XCTAssertEqual(estado.acumulado, 1, accuracy: 0.000001)
        XCTAssertEqual(estado.estado, .bajoUmbral)
    }

    // MARK: - Nivel 1: cambiar de modelo no altera el pasado

    /// Cambiar el modelo activo (o sus precios) no mueve el acumulado: la
    /// suma lee los sellos cerrados del libro, no valora de nuevo.
    func testCambiarDeModeloNoAlteraLoAcumulado() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        arnes.estado.fijarTopeMensual(10.00)
        sembrar(usd: 8.40, en: arnes)

        let antes = arnes.estado.estadoTopeMensual()
        XCTAssertEqual(antes.estado, .aviso)
        XCTAssertEqual(antes.acumulado, 8.40, accuracy: 0.000001)

        // Se cambia el modelo del proveedor activo y sus precios: el libro no
        // se toca, asi que la cifra tiene que quedar identica.
        var config = arnes.estado.config
        config.proveedores[0].modelo = "modelo-distinto"
        config.proveedores[0].precioEntradaPorMillon = 999
        config.proveedores[0].precioSalidaPorMillon = 999
        arnes.estado.config = config

        let despues = arnes.estado.estadoTopeMensual()
        XCTAssertEqual(despues, antes, "El acumulado pasado no cambia jamas")
        XCTAssertEqual(despues.acumulado, 8.40, accuracy: 0.000001)
        XCTAssertEqual(despues.estado, .aviso)
    }

    // MARK: - Nivel 1: la banda nunca bloquea el envio

    /// Con la banda en «tope alcanzado», enviar sigue funcionando: el turno
    /// arranca, la respuesta se cierra y no se cancela nada solo.
    func testEnviarSigueFuncionandoConLaBandaAlcanzada() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        arnes.estado.config.memoria = []
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )
        arnes.estado.fijarTopeMensual(1.00)
        sembrar(usd: 2.00, en: arnes)
        XCTAssertEqual(arnes.estado.estadoTopeMensual().estado, .alcanzado)

        arnes.transporte.guionar(
            texto: "Sigo aqui.",
            uso: UsoTokens(entrada: 10, salida: 5)
        )
        arnes.estado.enviar("Hola con el tope alcanzado")
        try await arnes.esperarTurno()

        XCTAssertEqual(arnes.transporte.guionesPendientes, 0)
        XCTAssertEqual(arnes.transporte.cantidadDePeticiones, 1)
        XCTAssertEqual(
            arnes.estado.conversacion.mensajes.first?.texto,
            "Hola con el tope alcanzado"
        )
        XCTAssertTrue(
            arnes.estado.conversacion.mensajes.contains { mensaje in
                mensaje.rol == .asistente && mensaje.texto == "Sigo aqui."
            },
            "La respuesta se cerro: la banda no cancelo el envio"
        )
        XCTAssertEqual(arnes.estado.estadoTopeMensual().estado, .alcanzado)
    }

    // MARK: - Persistencia y nota visible

    /// El tope se guarda en la configuracion (el mismo almacen de los ajustes
    /// locales) y sobrevive a un viaje por JSON. Sin la clave se lee sin tope.
    func testElTopeSePersisteConLaConfiguracion() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        arnes.estado.fijarTopeMensual(12.50)

        let datos = try arnes.estado.config.json()
        let leida = try AppConfig.desde(json: datos)
        XCTAssertEqual(leida.topeMensualGasto, 12.50)

        arnes.estado.fijarTopeMensual(nil)
        XCTAssertNil(arnes.estado.config.topeMensualGasto)
        let sinTope = try AppConfig.desde(json: arnes.estado.config.json())
        XCTAssertNil(sinTope.topeMensualGasto)
    }

    /// La nota de la configuracion dice, con todas las letras, que el tope se
    /// calcula solo con el gasto sellado en este dispositivo.
    func testLaNotaDeclaraElAlcanceLocal() {
        XCTAssertEqual(
            TopeMensualGasto.nota,
            "Calculado sobre el gasto sellado en este dispositivo."
        )
    }
}
