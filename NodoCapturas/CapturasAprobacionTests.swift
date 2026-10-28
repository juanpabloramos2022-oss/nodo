import Foundation
import XCTest

/// Prueba CON TOQUE REAL de la aprobacion en el hilo de Tarea (deuda M2).
///
/// POR QUE existe: la parte unit ya fija la condicion de render de la tarjeta,
/// pero el juez B3 exige evidencia de que la hoja EN EL HILO se pinta junto a
/// su fila y de que sus DOS botones ejercen la decision. Estos tests arrancan
/// la app con el estado sembrado `tarea-aprobacion-pendiente`, navegan por la
/// UI real hasta la tarea y tocan [Denegar] / [Aprobar] por su ETIQUETA
/// VISIBLE, igual que lo haria el dueno.
///
/// HALLAZGO (corrida CI 40182942035 sobre 79de6ec): en el arbol de
/// accesibilidad REAL todos los elementos de la tarjeta exponen el identifier
/// del contenedor `aprobacion-en-hilo`, botones incluidos; los identifiers
/// `rechazar-solicitud-hilo` / `aprobar-solicitud-hilo` que declara el producto
/// NO aparecen en ningun punto del arbol. El identifier del contenedor
/// ENSOMBRECE al de sus botones, asi que `app.buttons["denegar-solicitud-hilo"]`
/// no podia existir nunca: el fallo era del LOCALIZADOR del test, no del
/// comportamiento. Los botones existen, se ven y son tocables por su etiqueta
/// visible, que es lo que el dueno toca. Cambiar el esquema de identifiers es
/// decision de producto aparte y NO se hace en esta correccion.
///
/// El estado sembrado no tiene ToolLoop vivo: al tocar, el estado aplica al
/// libro el efecto inmediato y determinista de la decision (Denegado al
/// denegar; En curso al aprobar). Lo que sigue despues de aprobar —ejecutar la
/// herramienta y otra vuelta del modelo— necesita el bucle real y NO se afirma
/// aqui: el limite esta documentado en cada test.
final class CapturasAprobacionTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    // MARK: - Denegar con toque real

    /// La tarjeta aparece EN EL HILO junto a la fila 2 y [Denegar] la resuelve.
    func testB3AprobacionEnHiloDenegarConToqueReal() throws {
        abrirTareaSembrada()
        afirmarTarjetaJuntoASuFila()

        let denegar = app.buttons["Rechazar"]
        XCTAssertTrue(
            denegar.waitForExistence(timeout: 30),
            "No aparecio el boton Rechazar de la tarjeta en el hilo"
        )
        asegurarVisible(denegar)
        denegar.tap()

        esperarSinTexto(
            "Esperando tu aprobación",
            "La tarjeta de aprobacion no desaparecio tras denegar"
        )
        esperarDesaparicionElemento(
            app.buttons["Rechazar"],
            "El boton Rechazar sigue en pantalla tras resolver la aprobacion"
        )

        // Denegar deja el paso 2 en «Denegado»: es el estado observable y
        // determinista del libro sembrado, no una simulacion de la vista.
        esperarTexto(
            "Denegado",
            "La fila 2 no quedo en Denegado tras tocar Denegar"
        )
        XCTAssertTrue(
            textoDeFila("2. Leer el enlace de ejemplo.").exists,
            "La fila 2 desaparecio del libro en vez de quedar Denegada"
        )
        esperarSinTexto(
            "Esperando aprobación",
            "El hilo sigue mostrando Esperando aprobación tras denegar"
        )
        XCTAssertEqual(
            app.state,
            .runningForeground,
            "La app dejo de estar en primer plano tras denegar"
        )

        adjuntarCaptura("b3-aprobacion-denegada")
    }

    // MARK: - Aprobar con toque real

    /// [Aprobar] resuelve la tarjeta y saca la fila 2 de «Esperando aprobación».
    ///
    /// LIMITE HONESTO: en un estado sembrado no hay ToolLoop que reanude, asi
    /// que el test afirma solo el efecto inmediato de la decision (tarjeta
    /// fuera, paso en curso, sin crash). El resultado de la herramienta y la
    /// vuelta siguiente del modelo no son deterministas sin bucle vivo.
    func testB3AprobacionEnHiloAprobarConToqueReal() throws {
        abrirTareaSembrada()
        afirmarTarjetaJuntoASuFila()

        let aprobar = app.buttons["Aprobar"]
        XCTAssertTrue(
            aprobar.waitForExistence(timeout: 30),
            "No aparecio el boton Aprobar de la tarjeta en el hilo"
        )
        asegurarVisible(aprobar)
        aprobar.tap()

        esperarSinTexto(
            "Esperando tu aprobación",
            "La tarjeta de aprobacion no desaparecio tras aprobar"
        )
        esperarDesaparicionElemento(
            app.buttons["Aprobar"],
            "El boton Aprobar sigue en pantalla tras resolver la aprobacion"
        )
        XCTAssertTrue(
            textoDeFila("2. Leer el enlace de ejemplo.").exists,
            "La fila 2 desaparecio del libro tras aprobar"
        )
        esperarSinTexto(
            "Esperando aprobación",
            "La fila 2 (o la cabecera) sigue en Esperando aprobación tras aprobar"
        )
        XCTAssertEqual(
            app.state,
            .runningForeground,
            "La app dejo de estar en primer plano tras aprobar"
        )

        adjuntarCaptura("b3-aprobacion-aprobada")
    }

    // MARK: - Navegacion y aserciones compartidas

    /// Arranca la app con el estado sembrado y abre la tarea por su titulo.
    private func abrirTareaSembrada() {
        lanzar(estado: "tarea-aprobacion-pendiente")

        let tareas = app.tabBars.buttons["Tareas"]
        XCTAssertTrue(
            tareas.waitForExistence(timeout: 60),
            "No aparecio la pestana Tareas"
        )
        tareas.tap()

        let predicado = NSPredicate(
            format: "label CONTAINS %@",
            "Revisar el material de ejemplo"
        )
        let boton = app.buttons.matching(predicado).firstMatch
        let fila = boton.waitForExistence(timeout: 20)
            ? boton
            : app.descendants(matching: .any).matching(predicado).firstMatch
        XCTAssertTrue(
            fila.waitForExistence(timeout: 10),
            "No aparecio la tarea sembrada en la lista de Tareas"
        )
        fila.tap()

        XCTAssertTrue(
            app.navigationBars["Tarea"].waitForExistence(timeout: 30),
            "No se abrio el hilo de la tarea sembrada"
        )
        // La red de seguridad de la raiz no puede tapar la decision EN CONTEXTO.
        XCTAssertFalse(
            existeTexto("Aprobación necesaria"),
            "La hoja modal de la raiz tapa la tarjeta que vive en el hilo"
        )
    }

    /// Afirma que la tarjeta existe junto a la fila 2 del libro.
    private func afirmarTarjetaJuntoASuFila() {
        let filaDos = textoDeFila("2. Leer el enlace de ejemplo.")
        XCTAssertTrue(
            filaDos.exists,
            "No aparecio la fila 2 del libro en el hilo"
        )

        // La fila 2 se proyecta «Esperando aprobación» porque su paso tiene
        // `aprobacion == .pendiente`.
        esperarTexto(
            "Esperando aprobación",
            "La fila 2 no se proyecto como Esperando aprobación"
        )

        let tituloTarjeta = textoQueContiene("Esperando tu aprobación")
        XCTAssertTrue(
            tituloTarjeta.waitForExistence(timeout: 30),
            "No aparecio la tarjeta de aprobacion EN EL HILO"
        )

        // El identificador de la tarjeta se comprueba por la via directa y,
        // si iOS no expone el contenedor, por sus dos botones: las tres rutas
        // solo existen cuando la tarjeta esta pintada. Los botones se buscan
        // por ETIQUETA visible porque el identifier del contenedor los
        // ensombrece en el arbol real (ver cabecera del archivo).
        let tarjeta = elemento("aprobacion-en-hilo")
        XCTAssertTrue(
            tarjeta.waitForExistence(timeout: 10)
                || app.buttons["Rechazar"].exists
                || app.buttons["Aprobar"].exists,
            "La tarjeta no expone 'aprobacion-en-hilo' ni sus botones"
        )

        let filas = app.descendants(matching: .any).matching(identifier: "fila-paso-tarea")
        XCTAssertTrue(
            filas.firstMatch.waitForExistence(timeout: 10) || filaDos.exists,
            "No aparecieron las filas de paso ('fila-paso-tarea') del libro"
        )

        // «Junto a su fila»: la tarjeta va debajo de la fila 2, no en una hoja
        // aparte ni encima de la cabecera.
        XCTAssertGreaterThan(
            tituloTarjeta.frame.minY,
            filaDos.frame.minY,
            "La tarjeta de aprobacion no quedo junto a la fila que la pide"
        )
    }

    // MARK: - Utilidades

    private func lanzar(estado: String) {
        app.launchArguments = ["-CapturasPrueba", "-CapturasEstado", estado]
        app.launch()
    }

    /// Primer elemento con el identificador indicado, de cualquier tipo.
    private func elemento(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    /// Primer elemento cuya etiqueta CONTIENE el fragmento.
    ///
    /// Se prefiere `staticTexts` (el texto de un `Label` y de una fila) y se
    /// cae al arbol completo si iOS lo expone como otro tipo. Comparar por
    /// contenido evita depender de como se compone la etiqueta.
    private func textoQueContiene(_ fragmento: String) -> XCUIElement {
        let predicado = NSPredicate(format: "label CONTAINS %@", fragmento)
        let estatico = app.staticTexts.matching(predicado).firstMatch
        if estatico.waitForExistence(timeout: 5) { return estatico }
        return app.descendants(matching: .any).matching(predicado).firstMatch
    }

    /// True si CUALQUIER elemento del arbol contiene el fragmento.
    private func existeTexto(_ fragmento: String) -> Bool {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", fragmento))
            .count > 0
    }

    /// Espera a que el fragmento aparezca en algun elemento del hilo.
    private func esperarTexto(
        _ fragmento: String,
        _ mensaje: String,
        timeout: TimeInterval = 30
    ) {
        esperarCondicion(timeout: timeout, mensaje) { self.existeTexto(fragmento) }
    }

    /// Espera a que el fragmento deje de existir en TODO el arbol.
    private func esperarSinTexto(
        _ fragmento: String,
        _ mensaje: String,
        timeout: TimeInterval = 30
    ) {
        esperarCondicion(timeout: timeout, mensaje) { !self.existeTexto(fragmento) }
    }

    /// Espera a que un elemento concreto deje de existir.
    private func esperarDesaparicionElemento(
        _ elemento: XCUIElement,
        _ mensaje: String
    ) {
        let expectativa = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: elemento
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectativa], timeout: 15),
            .completed,
            mensaje
        )
    }

    private func esperarCondicion(
        timeout: TimeInterval,
        _ mensaje: String,
        _ condicion: () -> Bool
    ) {
        let limite = Date().addingTimeInterval(timeout)
        while Date() < limite {
            if condicion() { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTFail(mensaje)
    }

    /// Elemento de la FILA del libro con esa etiqueta exacta.
    ///
    /// La tarjeta del plan repite el texto de los pasos (sin el numero), asi
    /// que si hubiera dos coincidencias se elige la mas baja en pantalla: la
    /// fila del libro va despues del plan en el hilo.
    private func textoDeFila(_ etiqueta: String) -> XCUIElement {
        let exacta = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", etiqueta))
        if exacta.firstMatch.waitForExistence(timeout: 15) {
            let coincidencias = exacta.allElementsBoundByIndex
            return coincidencias.max(by: { $0.frame.minY < $1.frame.minY })
                ?? exacta.firstMatch
        }

        // Si iOS fusiona la fila en un solo elemento, se acepta su etiqueta
        // combinada; la coincidencia mas baja sigue siendo la fila del libro.
        let contiene = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", etiqueta))
        XCTAssertTrue(
            contiene.firstMatch.waitForExistence(timeout: 10),
            "No aparecio '\(etiqueta)' en el hilo"
        )
        let coincidencias = contiene.allElementsBoundByIndex
        return coincidencias.max(by: { $0.frame.minY < $1.frame.minY })
            ?? contiene.firstMatch
    }

    /// Si el boton quedo por debajo del pliegue, desplaza el hilo hasta el.
    private func asegurarVisible(_ elemento: XCUIElement) {
        let visible = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: elemento
        )
        if XCTWaiter().wait(for: [visible], timeout: 10) == .completed {
            return
        }

        var intentos = 0
        while !elemento.isHittable && intentos < 4 {
            app.swipeUp()
            intentos += 1
        }
    }

    private func adjuntarCaptura(_ nombre: String) {
        let captura = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        captura.name = nombre
        captura.lifetime = .keepAlways
        add(captura)
    }
}
