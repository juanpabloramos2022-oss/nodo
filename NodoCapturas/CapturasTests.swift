import Foundation
import XCTest

/// Capturas de verificacion visual de la SPEC (§6/H7).
///
/// Cada test arranca la app con un estado de PRUEBA determinista
/// (`-CapturasPrueba -CapturasEstado ...`), navega por la UI real y adjunta un
/// PNG al .xcresult. El nombre del adjunto empieza por `f<fase>-` para poder
/// mapearlo a las "Capturas exigidas" de SPEC §5.
final class CapturasTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    // MARK: - Fase 1: salidas y teclado

    /// SPEC §5, Fase 1: "Editor de proveedor con el teclado numerico abierto y
    /// la barra Listo visible". Se navega de verdad desde Ajustes hasta la hoja.
    func testF1EditorProveedorTecladoNumerico() throws {
        lanzar(estado: "editor-proveedor")

        let ajustes = app.tabBars.buttons["Ajustes"]
        XCTAssertTrue(
            ajustes.waitForExistence(timeout: 60),
            "No aparecio la pestana Ajustes"
        )
        ajustes.tap()

        let filaProveedor = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier == %@ OR label BEGINSWITH %@",
                "proveedor-fila",
                "Editar"
            )
        ).firstMatch
        XCTAssertTrue(
            filaProveedor.waitForExistence(timeout: 30),
            "No aparecio la fila del proveedor de prueba"
        )
        filaProveedor.tap()

        let campoEntrada = app.textFields.matching(
            NSPredicate(
                format: "identifier == %@ OR label == %@",
                "precio-entrada",
                "Precio de entrada"
            )
        ).firstMatch
        XCTAssertTrue(
            campoEntrada.waitForExistence(timeout: 30),
            "No aparecio el campo de precio de entrada"
        )
        asegurarVisible(campoEntrada)
        campoEntrada.tap()

        esperarBarraListo()
        adjuntarCaptura("f1-editor-teclado-numerico")
    }

    /// SPEC §5, Fase 1: "campo de tope con teclado y barra".
    func testF1AjustesTopeTecladoNumerico() throws {
        lanzar(estado: "ajustes-tope")

        let ajustes = app.tabBars.buttons["Ajustes"]
        XCTAssertTrue(
            ajustes.waitForExistence(timeout: 60),
            "No aparecio la pestana Ajustes"
        )
        ajustes.tap()

        let campoTope = app.textFields.matching(
            NSPredicate(
                format: "identifier == %@ OR label == %@",
                "tope-aviso",
                "Tope de aviso por chat"
            )
        ).firstMatch
        XCTAssertTrue(
            campoTope.waitForExistence(timeout: 30),
            "No aparecio el campo de tope de aviso"
        )
        asegurarVisible(campoTope)
        campoTope.tap()

        esperarBarraListo()
        adjuntarCaptura("f1-ajustes-tope-teclado-numerico")
    }

    // MARK: - Ayudas

    /// Arranca la app con el estado de prueba pedido. Sin estos argumentos la
    /// app no activa el gancho y se comportaria como en produccion.
    private func lanzar(estado: String) {
        app.launchArguments = ["-CapturasPrueba", "-CapturasEstado", estado]
        app.launch()
    }

    /// Si el campo quedo por debajo del pliegue, desplaza el formulario hasta
    /// dejarlo tocable. En el iPhone 16 de CI no hace falta, pero evita que la
    /// captura dependa del tamano exacto de la pantalla.
    private func asegurarVisible(_ elemento: XCUIElement) {
        // Primero se le da tiempo a la animacion de la hoja o del scroll.
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

    /// Espera la barra "Listo" con un timeout generoso: el arranque del
    /// simulador y la animacion del teclado pueden tardar en CI.
    private func esperarBarraListo() {
        // Se busca por etiqueta y por identificador a la vez: la etiqueta es
        // la que exige la SPEC y el identificador cubre versiones de iOS que
        // no exponen igual el boton de la barra de teclado.
        let listo = app.buttons.matching(
            NSPredicate(format: "identifier == %@ OR label == %@", "teclado-listo", "Listo")
        ).firstMatch
        XCTAssertTrue(
            listo.waitForExistence(timeout: 60),
            "No aparecio la barra Listo sobre el teclado"
        )
        XCTAssertTrue(
            listo.label.contains("Listo"),
            "La barra del teclado no muestra Listo: \(listo.label)"
        )

        // Deja terminar la animacion del teclado antes de tomar la foto.
        let teclado = app.keyboards.element
        let expectativa = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"),
            object: teclado
        )
        _ = XCTWaiter().wait(for: [expectativa], timeout: 5)

        // Margen corto para que la animacion del teclado termine y la foto no
        // salga a medio abrir. No se usa para esperar elementos: eso siempre
        // va con waitForExistence.
        Thread.sleep(forTimeInterval: 1.0)
    }

    /// Adjunta el PNG con un nombre descriptivo y lo conserva siempre en el
    /// .xcresult, para que el job de CI lo pueda extraer como artefacto.
    private func adjuntarCaptura(_ nombre: String) {
        // Se captura la PANTALLA completa, no solo la ventana de la app: el
        // teclado del simulador vive en otra ventana y debe salir en la foto.
        let captura = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        captura.name = nombre
        captura.lifetime = .keepAlways
        add(captura)
    }
}
