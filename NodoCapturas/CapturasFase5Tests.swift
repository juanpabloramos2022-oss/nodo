import Foundation
import XCTest

/// Capturas de verificacion visual de la Fase 5 (SPEC §5).
///
/// Un test por captura. La lista usa el estado `historial-ejemplo`, que ya
/// siembra un chat fijado con consumo, uno activo y uno archivado. La
/// ramificacion usa el estado `chat` y recorre la ruta real de la app:
/// pulsacion larga sobre una burbuja intermedia y "🔀 Ramificar chat desde
/// aquí". Ninguna captura usa datos reales.
final class CapturasFase5Tests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    // MARK: - Historial enriquecido

    /// SPEC §3.1/§5.1: los fijados van arriba y las filas muestran la pastilla
    /// de costo y la etiqueta del ultimo modelo de cada conversacion.
    func testF5Historial() throws {
        lanzar(estado: "historial-ejemplo")

        let fijada = fila("Conversacion fijada de ejemplo")
        XCTAssertTrue(
            fijada.waitForExistence(timeout: 60),
            "No aparecio la conversacion fijada en la lista de Chats"
        )

        let activa = fila("Conversacion de ejemplo")
        XCTAssertTrue(
            activa.waitForExistence(timeout: 30),
            "No aparecio la conversacion activa en la lista de Chats"
        )
        // Margen para que la lista termine de asentar las filas antes de
        // comparar sus posiciones.
        Thread.sleep(forTimeInterval: 0.5)

        // En una fila de List, SwiftUI puede fusionar los hijos en la etiqueta
        // del boton o dejarlos como textos sueltos. Se aceptan las tres rutas
        // (etiqueta de la fila, identificador propio y texto visible) para no
        // depender de un detalle de accesibilidad de una version de iOS.
        let marca = elemento(identifier: "fijado-fila")
        let marcaTexto = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Fijado")
        ).firstMatch
        XCTAssertTrue(
            fijada.label.contains("Fijado")
                || marca.waitForExistence(timeout: 10)
                || marcaTexto.waitForExistence(timeout: 5),
            "La fila fijada no muestra su marca de fijado"
        )
        XCTAssertLessThan(
            fijada.frame.minY,
            activa.frame.minY,
            "La conversacion fijada no aparece por encima de la activa"
        )

        let costo = elemento(identifier: "costo-fila")
        let costoTexto = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "$")
        ).firstMatch
        let costoVisible = fijada.label.contains("$")
            || activa.label.contains("$")
            || costo.waitForExistence(timeout: 10)
            || costoTexto.waitForExistence(timeout: 5)
        XCTAssertTrue(
            costoVisible,
            "Ninguna fila enriquecida muestra la pastilla de costo"
        )
        if costo.exists {
            XCTAssertTrue(
                costo.label.contains("$"),
                "La pastilla de costo no tiene el formato esperado: \(costo.label)"
            )
        }

        let modelo = elemento(identifier: "modelo-fila")
        let modeloTexto = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "modelo-de-ejemplo")
        ).firstMatch
        let modeloVisible = fijada.label.contains("modelo-de-ejemplo")
            || activa.label.contains("modelo-de-ejemplo")
            || modelo.waitForExistence(timeout: 10)
            || modeloTexto.waitForExistence(timeout: 5)
        XCTAssertTrue(
            modeloVisible,
            "Ninguna fila enriquecida muestra la etiqueta del ultimo modelo"
        )
        if modelo.exists {
            XCTAssertTrue(
                modelo.label.contains("modelo-de-ejemplo"),
                "La etiqueta no muestra el modelo de la conversacion: \(modelo.label)"
            )
        }
        Thread.sleep(forTimeInterval: 0.4)

        disparar("f5-historial")
    }

    // MARK: - Segmento Archivados

    /// SPEC §3.1/§5.2: el segmento Archivados ensena solo los chats
    /// archivados; ningun chat activo se cuela en la lista.
    func testF5Archivados() throws {
        lanzar(estado: "historial-ejemplo")

        let fijada = fila("Conversacion fijada de ejemplo")
        XCTAssertTrue(
            fijada.waitForExistence(timeout: 60),
            "No aparecio la lista de Chats con la conversacion fijada"
        )
        let activa = fila("Conversacion de ejemplo")
        XCTAssertTrue(
            activa.waitForExistence(timeout: 30),
            "No aparecio la conversacion activa antes de cambiar de segmento"
        )
        XCTAssertFalse(
            fila("Conversacion archivada de ejemplo").exists,
            "El segmento Activos no puede mostrar un chat archivado"
        )

        let archivados = botonSegmento("Archivados")
        XCTAssertTrue(
            archivados.waitForExistence(timeout: 30),
            "No aparecio el segmento Archivados"
        )
        archivados.tap()

        let archivada = fila("Conversacion archivada de ejemplo")
        XCTAssertTrue(
            archivada.waitForExistence(timeout: 30),
            "El segmento Archivados no muestra la conversacion archivada"
        )

        let activaFuera = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: activa
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [activaFuera], timeout: 15),
            .completed,
            "El segmento Archivados sigue mostrando un chat activo"
        )

        let fijadaFuera = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: fijada
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [fijadaFuera], timeout: 15),
            .completed,
            "El segmento Archivados sigue mostrando el chat fijado (activo)"
        )
        Thread.sleep(forTimeInterval: 0.4)

        disparar("f5-archivados")
    }

    // MARK: - Menu de pulsacion larga

    /// SPEC §3.1/§5.3: la pulsacion larga sobre una fila activa abre el menu
    /// completo con Fijar, Renombrar, Archivar y Borrar.
    func testF5MenuFila() throws {
        lanzar(estado: "historial-ejemplo")

        let filaActiva = fila("Conversacion de ejemplo")
        XCTAssertTrue(
            filaActiva.waitForExistence(timeout: 60),
            "No aparecio la fila activa para abrir su menu"
        )

        // Renombrar solo existe en el menu contextual (no en los deslizamientos),
        // asi que sirve para saber que el menu esta realmente abierto. La
        // consulta se crea sin esperar: el menu aun no esta abierto.
        let renombrar = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Renombrar")
        ).firstMatch
        filaActiva.press(forDuration: 1.5)
        if !renombrar.waitForExistence(timeout: 10) {
            filaActiva.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
            ).press(forDuration: 1.5)
        }
        XCTAssertTrue(
            renombrar.waitForExistence(timeout: 15),
            "La pulsacion larga no abrio el menu de la fila"
        )
        XCTAssertTrue(
            elementoDeMenu("Fijar").waitForExistence(timeout: 10),
            "El menu de la fila no muestra Fijar"
        )
        XCTAssertTrue(
            elementoDeMenu("Archivar").waitForExistence(timeout: 10),
            "El menu de la fila no muestra Archivar"
        )
        XCTAssertTrue(
            elementoDeMenu("Borrar").waitForExistence(timeout: 10),
            "El menu de la fila no muestra Borrar"
        )
        Thread.sleep(forTimeInterval: 0.4)

        disparar("f5-menu-fila")
    }

    // MARK: - Ramificar desde un punto intermedio

    /// SPEC §5.4: mantener pulsada una burbuja intermedia y elegir
    /// "🔀 Ramificar chat desde aquí" crea una conversacion con los mensajes
    /// hasta el corte y entra directamente en ella.
    func testF5Ramificada() throws {
        lanzar(estado: "chat")
        abrirConversacion("Chat de ejemplo")

        // Corte intermedio: la primera respuesta del asistente. La copia debe
        // quedarse con el primer turno (usuario + asistente) y no heredar los
        // dos mensajes posteriores del chat original.
        let corte = textoDeMensaje("Respuesta de ejemplo: aquí estoy para ayudarte.")
        XCTAssertTrue(
            corte.waitForExistence(timeout: 60),
            "No aparecio la burbuja intermedia para ramificar"
        )
        XCTAssertTrue(
            abrirMenuDeRamificar(corte),
            "La pulsacion larga sobre la burbuja no abrio Ramificar chat desde aquí"
        )

        let ramificar = elementoDeMenu("Ramificar chat desde")
        XCTAssertTrue(
            ramificar.waitForExistence(timeout: 10),
            "No aparecio la accion Ramificar chat desde aquí en el menu"
        )
        ramificar.tap()

        // La copia se abre en la misma pila. Si el chat original siguiera en
        // pantalla, el ultimo mensaje y la segunda respuesta seguirian visibles.
        let segundaRespuesta = textoDeMensaje("Segunda respuesta de ejemplo")
        let desaparece = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: segundaRespuesta
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [desaparece], timeout: 30),
            .completed,
            "La conversacion ramificada sigue mostrando mensajes posteriores al corte"
        )

        XCTAssertTrue(
            textoDeMensaje("Hola, primer mensaje de ejemplo.").waitForExistence(timeout: 30),
            "La copia ramificada no conserva el primer mensaje"
        )
        XCTAssertTrue(
            textoDeMensaje("Respuesta de ejemplo: aquí estoy para ayudarte.")
                .waitForExistence(timeout: 30),
            "La copia ramificada no conserva la respuesta del punto de corte"
        )
        XCTAssertFalse(
            textoDeMensaje("Segundo mensaje de ejemplo.").exists,
            "La copia ramificada heredo un mensaje posterior al corte"
        )
        XCTAssertTrue(
            elemento(identifier: "pildora-modelo").waitForExistence(timeout: 30),
            "La copia ramificada no se abrio como conversacion"
        )
        Thread.sleep(forTimeInterval: 0.6)

        disparar("f5-ramificada")
    }

    // MARK: - Navegacion y utilidades

    private func fila(_ titulo: String) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", titulo)
        ).firstMatch
    }

    /// Primer elemento con la etiqueta indicada DENTRO del hilo del chat.
    ///
    /// Se limita al `ScrollView` de los mensajes cuando existe: la lista de
    /// Chats queda detras de la pila y su vista previa puede contener el mismo
    /// texto, lo que daria un falso positivo al comprobar que un mensaje ya no
    /// esta en la copia ramificada. Tambien se acepta cualquier tipo de
    /// elemento: las burbujas con seleccion de texto no siempre se exponen
    /// igual entre versiones de iOS.
    private func textoDeMensaje(_ fragmento: String) -> XCUIElement {
        let predicado = NSPredicate(format: "label CONTAINS %@", fragmento)
        return app.scrollViews.firstMatch
            .descendants(matching: .any)
            .matching(predicado)
            .firstMatch
    }

    /// Abre la conversacion tocando su fila en la lista de Chats.
    private func abrirConversacion(_ titulo: String) {
        let entrada = fila(titulo)
        XCTAssertTrue(
            entrada.waitForExistence(timeout: 60),
            "No aparecio la fila \(titulo) en la lista de Chats"
        )
        entrada.tap()

        XCTAssertTrue(
            elemento(identifier: "pildora-modelo").waitForExistence(timeout: 30),
            "No se abrio la conversacion \(titulo)"
        )
        Thread.sleep(forTimeInterval: 0.4)
    }

    /// Pulsa la burbuja en su relleno, no sobre el texto: las respuestas tienen
    /// seleccion activada y el texto podria quedarse con la pulsacion larga.
    /// Se prueban los rellenos inferior, superior e izquierdo antes de caer al
    /// centro del texto.
    private func abrirMenuDeRamificar(_ burbuja: XCUIElement) -> Bool {
        let accion = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Ramificar chat desde")
        ).firstMatch

        let rellenoInferior = burbuja.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 1)
        ).withOffset(CGVector(dx: 0, dy: 6))
        rellenoInferior.press(forDuration: 1.6)
        if accion.waitForExistence(timeout: 8) { return true }

        let rellenoSuperior = burbuja.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0)
        ).withOffset(CGVector(dx: 0, dy: -6))
        rellenoSuperior.press(forDuration: 1.6)
        if accion.waitForExistence(timeout: 5) { return true }

        let rellenoIzquierdo = burbuja.coordinate(
            withNormalizedOffset: CGVector(dx: 0, dy: 0.5)
        ).withOffset(CGVector(dx: -6, dy: 0))
        rellenoIzquierdo.press(forDuration: 1.6)
        if accion.waitForExistence(timeout: 5) { return true }

        burbuja.press(forDuration: 1.6)
        return accion.waitForExistence(timeout: 8)
    }

    private func botonSegmento(_ titulo: String) -> XCUIElement {
        let segmentado = app.segmentedControls.buttons[titulo]
        if segmentado.waitForExistence(timeout: 15) {
            return segmentado
        }
        return app.buttons[titulo]
    }

    private func elemento(identifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    /// Primer elemento del menu abierto que coincide con la etiqueta indicada.
    ///
    /// Se prefieren `button` y `menuItem` (que son tocables) y se deja el
    /// arbol completo como ultimo recurso: segun la version de iOS los
    /// elementos del menu contextual pueden exponerse de cualquiera de las
    /// tres formas.
    private func elementoDeMenu(_ etiqueta: String) -> XCUIElement {
        let exacto = NSPredicate(format: "label == %@", etiqueta)
        let exactoBoton = app.buttons.matching(exacto).firstMatch
        if exactoBoton.waitForExistence(timeout: 3) { return exactoBoton }
        let exactoItem = app.menuItems.matching(exacto).firstMatch
        if exactoItem.waitForExistence(timeout: 2) { return exactoItem }

        let contiene = NSPredicate(format: "label CONTAINS %@", etiqueta)
        let boton = app.buttons.matching(contiene).firstMatch
        if boton.waitForExistence(timeout: 3) { return boton }
        let item = app.menuItems.matching(contiene).firstMatch
        if item.waitForExistence(timeout: 2) { return item }
        return app.descendants(matching: .any).matching(contiene).firstMatch
    }

    private func lanzar(estado: String) {
        app.launchArguments = ["-CapturasPrueba", "-CapturasEstado", estado]
        app.launch()
    }

    private func disparar(_ nombre: String) {
        let captura = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        captura.name = nombre
        captura.lifetime = .keepAlways
        add(captura)
    }
}
