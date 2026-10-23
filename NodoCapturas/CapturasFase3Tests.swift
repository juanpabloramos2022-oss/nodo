import Foundation
import XCTest

/// Capturas de verificacion visual de la Fase 3 (SPEC §5).
///
/// Un test por captura. Cada uno arranca la app con `-CapturasPrueba
/// -CapturasEstado ...`, navega por la UI real, comprueba los textos y botones
/// clave de la SPEC y adjunta el PNG con `disparar(nombre)`. La suite de la
/// Fase 2 vive en `CapturasTests.swift` y no se toca.
final class CapturasFase3Tests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    // MARK: - Tarjeta de Bienvenida

    /// SPEC §3.2/§5: chat vacio con la Tarjeta de Bienvenida y clave
    /// configurada. Se ve el estado conectado (boton para empezar) y ninguna
    /// advertencia de clave.
    func testF3BienvenidaConClave() throws {
        lanzar(estado: "bienvenida")
        abrirConversacion("Chat de ejemplo")

        let titulo = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Este chat usa InferHub")
        ).firstMatch
        XCTAssertTrue(
            titulo.waitForExistence(timeout: 60),
            "La Tarjeta de Bienvenida no muestra el proveedor y el modelo reales"
        )
        XCTAssertTrue(
            titulo.label.contains("deepseek-v4-1-flash"),
            "La Tarjeta no muestra el modelo activo del preset"
        )
        XCTAssertTrue(
            elemento("empezar-chatear", etiqueta: "Empezar a chatear").waitForExistence(timeout: 30),
            "Con clave guardada falta el boton para empezar a chatear"
        )
        XCTAssertFalse(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@", "Falta tu clave")
            ).firstMatch.exists,
            "La tarjeta con clave no debe mostrar la advertencia de clave"
        )
        // Margen para que la tarjeta termine de pintarse antes de la foto.
        Thread.sleep(forTimeInterval: 0.4)

        disparar("f3-bienvenida")
    }

    /// SPEC §3.2/§5: la misma tarjeta con la clave vacia. Muestra el aviso
    /// ⚠️ Falta tu clave y el boton de pegado, y en ningun sitio dice
    /// "conectado".
    func testF3BienvenidaSinClave() throws {
        lanzar(estado: "bienvenida-sin-clave")
        abrirConversacion("Chat de ejemplo")

        let aviso = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Falta tu clave")
        ).firstMatch
        XCTAssertTrue(
            aviso.waitForExistence(timeout: 60),
            "La tarjeta sin clave no muestra el aviso ⚠️ Falta tu clave"
        )
        XCTAssertTrue(
            elemento("pegar-clave", etiqueta: "Pegar clave").waitForExistence(timeout: 30),
            "Falta el boton 📋 Pegar clave desde el portapapeles"
        )
        let conectado = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "conectado")
        ).firstMatch
        XCTAssertFalse(
            conectado.exists,
            "La tarjeta sin clave no puede decir conectado en ninguna parte"
        )
        // Margen para que la tarjeta termine de pintarse antes de la foto.
        Thread.sleep(forTimeInterval: 0.4)

        disparar("f3-bienvenida-sin-clave")
    }

    // MARK: - Pie de respuesta y Regenerar con

    /// SPEC §3.3/§5: respuesta con el pie completo y el menu "Regenerar con…"
    /// abierto con una pulsacion larga sobre ↻ de la ultima respuesta.
    func testF3PieRegenerarCon() throws {
        lanzar(estado: "chat")
        abrirConversacion("Chat de ejemplo")

        let consumo = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "de entrada")
        ).firstMatch
        XCTAssertTrue(
            consumo.waitForExistence(timeout: 60),
            "No aparecio el pie de la respuesta con tokens y costo"
        )
        XCTAssertTrue(
            elemento("copiar-respuesta", etiqueta: "Copiar respuesta").waitForExistence(timeout: 30),
            "El pie de la respuesta no muestra el boton Copiar"
        )

        let regenerar = elemento("regenerar-respuesta", etiqueta: "Regenerar la última respuesta")
        XCTAssertTrue(
            regenerar.waitForExistence(timeout: 30),
            "Falta el boton ↻ de la ultima respuesta"
        )
        asegurarVisible(regenerar)
        regenerar.press(forDuration: 1.2)

        let otroModelo = elementoDeMenu("Regenerar con glm-5-3-flash")
        let menuAbierto = otroModelo.waitForExistence(timeout: 15)
        if menuAbierto {
            XCTAssertTrue(
                elementoDeMenu("Regenerar con gpt-6-1-sol").exists,
                "El menu Regenerar con… no muestra el segundo modelo"
            )
            XCTAssertTrue(
                elementoDeMenu("Regenerar con gpt-6-astra").exists,
                "El menu Regenerar con… no muestra el tercer modelo"
            )
        }
        // Margen para que el menu termine de desplegarse antes de la foto.
        Thread.sleep(forTimeInterval: 0.4)

        // La captura se toma tambien si el menu contextual no abrio: deja
        // evidencia del estado alcanzable (el pie completo) y el fallo se
        // reporta justo despues.
        disparar("f3-pie-regenerar-con")
        XCTAssertTrue(
            menuAbierto,
            "La pulsacion larga sobre ↻ no abrio el menu Regenerar con…"
        )
    }

    // MARK: - Franja de tope

    /// SPEC §3.3/§5: franja ambar de tope visible sobre la caja, con
    /// [Subir tope] y [Seguir igual]. En la misma prueba se abre el menu de
    /// escalones y se toma la segunda captura.
    func testF3FranjaTope() throws {
        lanzar(estado: "tope")
        abrirConversacion("Chat de ejemplo")

        let aviso = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Este chat ya supera tu tope")
        ).firstMatch
        XCTAssertTrue(
            aviso.waitForExistence(timeout: 60),
            "No aparecio la franja ambar de tope sobre la caja"
        )
        XCTAssertTrue(
            elemento("subir-tope", etiqueta: "Subir tope").waitForExistence(timeout: 30),
            "La franja no muestra [Subir tope]"
        )
        XCTAssertTrue(
            elemento("seguir-igual", etiqueta: "Seguir igual").waitForExistence(timeout: 30),
            "La franja no muestra [Seguir igual]"
        )
        // Margen para que la franja termine de pintarse antes de la foto.
        Thread.sleep(forTimeInterval: 0.4)

        disparar("f3-franja-tope")

        let subir = elemento("subir-tope", etiqueta: "Subir tope")
        XCTAssertTrue(
            subir.waitForExistence(timeout: 30),
            "No se encontro el menu [Subir tope]"
        )
        subir.tap()

        let escalon = elementoDeMenuConImporte("0.25")
        let menuAbierto = escalon.waitForExistence(timeout: 15)
        if menuAbierto {
            XCTAssertTrue(
                elementoDeMenuConImporte("0.50").exists,
                "El menu de [Subir tope] no muestra el escalon 0.50"
            )
            XCTAssertTrue(
                elementoDeMenuConImporte("1.00").exists,
                "El menu de [Subir tope] no muestra el escalon 1.00"
            )
            XCTAssertTrue(
                elementoDeMenuConImporte("2.00").exists,
                "El menu de [Subir tope] no muestra el escalon 2.00"
            )
        }
        // Margen para que el menu termine de desplegarse antes de la foto.
        Thread.sleep(forTimeInterval: 0.4)

        // Igual que con el menu contextual del pie: si el menu no abrio, la
        // captura deja evidencia del estado alcanzable y el fallo se reporta
        // despues.
        disparar("f3-franja-tope-menu")
        XCTAssertTrue(
            menuAbierto,
            "El menu de [Subir tope] no muestra escalones por encima del tope actual"
        )
    }

    // MARK: - Dictado

    /// SPEC §4.5/§5: la caja con la transcripcion del doble de dictado ya
    /// insertada y el microfono visible, sin enviar el mensaje.
    func testF3Dictado() throws {
        lanzar(estado: "chat")
        abrirConversacion("Chat de ejemplo")

        let caja = elemento("caja-mensaje")
        XCTAssertTrue(
            caja.waitForExistence(timeout: 60),
            "No aparecio la caja de mensaje"
        )
        let micro = elemento("boton-dictado", etiqueta: "Dictar")
        XCTAssertTrue(
            micro.waitForExistence(timeout: 30),
            "No aparecio el boton de microfono"
        )
        micro.tap()

        let transcripcion = "Mensaje dictado de ejemplo"
        let expectativa = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", transcripcion),
            object: caja
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectativa], timeout: 30),
            .completed,
            "La transcripcion del doble de dictado no cayo en la caja"
        )
        XCTAssertTrue(
            elemento("boton-dictado", etiqueta: "Detener dictado").waitForExistence(timeout: 30),
            "El microfono desaparecio despues de dictar"
        )
        // Margen para que el texto y el estado del microfono se pinten.
        Thread.sleep(forTimeInterval: 0.4)

        disparar("f3-dictado")
    }

    // MARK: - Comandos "/"

    /// SPEC §4.2/§5: el resultado de /costo se pinta como evento DENTRO del
    /// hilo, no como una hoja. El comando se ejecuta por la ruta real de la app.
    func testF3ComandoCosto() throws {
        lanzar(estado: "chat")
        abrirConversacion("Chat de ejemplo")
        escribirYEnviar("/costo")

        let evento = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "En este chat van")
        ).firstMatch
        XCTAssertTrue(
            evento.waitForExistence(timeout: 60),
            "El resultado de /costo no aparecio como evento dentro de la conversacion"
        )
        XCTAssertTrue(
            evento.label.contains("tope de aviso"),
            "El resultado de /costo no muestra el tope vigente"
        )
        XCTAssertFalse(
            app.navigationBars["Modelos"].exists,
            "/costo abrio una hoja en vez de insertar un evento en el hilo"
        )
        // Margen para que el hilo termine de desplazarse hasta el evento.
        Thread.sleep(forTimeInterval: 0.4)

        disparar("f3-comando-costo")
    }

    /// SPEC §4.2/§5: el selector flotante de "/" abierto sobre la caja con la
    /// seccion de comandos del sistema.
    func testF3SelectorFlotante() throws {
        lanzar(estado: "chat")
        abrirConversacion("Chat de ejemplo")

        let caja = elemento("caja-mensaje")
        XCTAssertTrue(
            caja.waitForExistence(timeout: 60),
            "No aparecio la caja de mensaje"
        )
        caja.tap()
        esperarBarraListo()
        caja.typeText("/")

        for comando in ["compact", "costo", "modelos", "nuevo", "exportar"] {
            XCTAssertTrue(
                elemento("sugerencia-comando-\(comando)", etiqueta: "/\(comando)").waitForExistence(timeout: 15),
                "El selector flotante no muestra el comando /\(comando)"
            )
        }
        let costo = elemento("sugerencia-comando-costo", etiqueta: "/costo")
        XCTAssertTrue(
            costo.waitForExistence(timeout: 15),
            "El selector flotante no muestra la fila de /costo"
        )
        XCTAssertTrue(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@", "Muestra tokens")
            ).firstMatch.exists,
            "El selector flotante no muestra la descripcion de /costo"
        )
        // Margen para que el selector termine de pintarse antes de la foto.
        Thread.sleep(forTimeInterval: 0.4)

        disparar("f3-selector-flotante")
    }

    // MARK: - Error en linea

    /// SPEC §3.7/§5: burbuja de error en linea con [Reintentar] y
    /// [Cambiar modelo]. El fallo lo produce el motor determinista al enviar, y
    /// el mensaje del usuario sigue en el hilo.
    func testF3ErrorEnLinea() throws {
        lanzar(estado: "error-en-linea")
        abrirConversacion("Chat de ejemplo")

        let mensaje = "Mensaje de ejemplo que falla."
        escribirYEnviar(mensaje)

        let detalle = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "No se pudo conectar")
        ).firstMatch
        XCTAssertTrue(
            detalle.waitForExistence(timeout: 90),
            "No aparecio la burbuja de error en linea"
        )
        XCTAssertTrue(
            elemento("reintentar-turno", etiqueta: "Reintentar").waitForExistence(timeout: 30),
            "La burbuja de error no muestra [Reintentar]"
        )
        XCTAssertTrue(
            elemento("cambiar-modelo-error", etiqueta: "Cambiar modelo").waitForExistence(timeout: 30),
            "La burbuja de error no muestra [Cambiar modelo]"
        )
        XCTAssertTrue(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@", mensaje)
            ).firstMatch.waitForExistence(timeout: 30),
            "El mensaje del usuario se perdio al fallar el turno"
        )
        // Margen para que la burbuja termine de pintarse antes de la foto.
        Thread.sleep(forTimeInterval: 0.4)

        disparar("f3-error-en-linea")
    }

    // MARK: - Ayudas

    /// Entra a la conversacion tocando su fila en la lista de Chats.
    private func abrirConversacion(_ titulo: String) {
        let fila = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", titulo)
        ).firstMatch

        if fila.waitForExistence(timeout: 60) {
            fila.tap()
        } else {
            let texto = app.staticTexts[titulo]
            XCTAssertTrue(
                texto.waitForExistence(timeout: 15),
                "No aparecio la fila \(titulo) en la lista de Chats"
            )
            texto.tap()
        }

        let pildora = elemento("pildora-modelo")
        XCTAssertTrue(
            pildora.waitForExistence(timeout: 20),
            "No se abrio la conversacion \(titulo)"
        )
        // Margen para que termine la animacion de empuje de la pila.
        Thread.sleep(forTimeInterval: 0.4)
    }

    /// Abre el teclado en la caja y espera la barra Listo.
    private func abrirTecladoEnLaCaja() {
        let caja = elemento("caja-mensaje")
        XCTAssertTrue(
            caja.waitForExistence(timeout: 60),
            "No aparecio la caja de mensaje"
        )
        caja.tap()
        esperarBarraListo()
    }

    /// Baja el teclado con el boton Listo de la barra.
    private func tocarListo() {
        let listo = botonListo()
        XCTAssertTrue(
            listo.waitForExistence(timeout: 60),
            "No aparecio el boton Listo"
        )
        listo.tap()
    }

    /// Escribe y envia un mensaje en la conversacion abierta, bajando antes el
    /// teclado para que la captura no lo incluya.
    private func escribirYEnviar(_ texto: String) {
        abrirTecladoEnLaCaja()

        let caja = elemento("caja-mensaje")
        caja.typeText(texto)

        tocarListo()
        esperarTecladoOculto()
        // Margen para que la caja y el boton Enviar vuelvan a su sitio.
        Thread.sleep(forTimeInterval: 0.3)

        let enviar = elemento("enviar-mensaje", etiqueta: "Enviar")
        XCTAssertTrue(
            enviar.waitForExistence(timeout: 30),
            "No aparecio el boton Enviar"
        )
        XCTAssertTrue(enviar.isEnabled, "El boton Enviar esta deshabilitado")
        enviar.tap()
    }

    /// Espera a que el teclado termine de bajar.
    private func esperarTecladoOculto() {
        let teclado = app.keyboards.element
        let expectativa = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: teclado
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectativa], timeout: 15),
            .completed,
            "El teclado no se cerro"
        )
    }

    /// Espera la barra "Listo" con un timeout generoso: el arranque del
    /// simulador y la animacion del teclado pueden tardar en CI.
    private func esperarBarraListo() {
        let listo = botonListo()
        XCTAssertTrue(
            listo.waitForExistence(timeout: 60),
            "No aparecio la barra Listo sobre el teclado"
        )
        XCTAssertTrue(
            listo.label.contains("Listo"),
            "La barra del teclado no muestra Listo: \(listo.label)"
        )

        let teclado = app.keyboards.element
        let expectativa = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"),
            object: teclado
        )
        _ = XCTWaiter().wait(for: [expectativa], timeout: 5)

        // Margen corto para que la animacion del teclado termine y la foto no
        // salga a medio abrir.
        Thread.sleep(forTimeInterval: 1.0)
    }

    /// Primer elemento de cualquier tipo con el identificador indicado.
    ///
    /// Si la version de iOS no expone el identificador, se cae a la etiqueta
    /// visible para que la captura no dependa de un detalle de accesibilidad.
    private func elemento(_ id: String, etiqueta: String? = nil) -> XCUIElement {
        let porIdentificador = app.descendants(matching: .any)
            .matching(identifier: id)
            .firstMatch
        if porIdentificador.exists { return porIdentificador }

        guard let etiqueta else { return porIdentificador }

        let porEtiquetaBoton = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", etiqueta))
            .firstMatch
        if porEtiquetaBoton.exists { return porEtiquetaBoton }

        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", etiqueta))
            .firstMatch
    }

    /// Primer elemento del menu abierto que contiene la etiqueta indicada.
    private func elementoDeMenu(_ etiqueta: String) -> XCUIElement {
        let predicado = NSPredicate(format: "label CONTAINS %@", etiqueta)
        let boton = app.buttons.matching(predicado).firstMatch
        if boton.waitForExistence(timeout: 5) {
            return boton
        }
        return app.descendants(matching: .any).matching(predicado).firstMatch
    }

    /// Elemento del menu para un importe con punto o con coma decimal.
    ///
    /// El texto de la franja usa `String(format:)`, que puede seguir el locale
    /// del simulador; la captura no debe depender de si CI esta en es_ES o
    /// en_US.
    private func elementoDeMenuConImporte(_ valor: String) -> XCUIElement {
        let conPunto = "$\(valor)"
        let conComa = "$\(valor.replacingOccurrences(of: ".", with: ","))"
        let predicado = NSPredicate(
            format: "label CONTAINS %@ OR label CONTAINS %@",
            conPunto,
            conComa
        )
        let boton = app.buttons.matching(predicado).firstMatch
        if boton.waitForExistence(timeout: 5) { return boton }
        return app.descendants(matching: .any).matching(predicado).firstMatch
    }

    /// Boton Listo de la barra del teclado.
    private func botonListo() -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier == %@ OR label == %@", "teclado-listo", "Listo")
        ).firstMatch
    }

    /// Arranca la app con el estado de prueba pedido.
    private func lanzar(estado: String) {
        app.launchArguments = ["-CapturasPrueba", "-CapturasEstado", estado]
        app.launch()
    }

    /// Si el elemento quedo por debajo del pliegue, desplaza el hilo hasta
    /// dejarlo tocable.
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

    /// Adjunta el PNG con el nombre que mapea a la captura exigida por SPEC §5.
    private func disparar(_ nombre: String) {
        // Se captura la PANTALLA completa, no solo la ventana de la app: los
        // menus y el teclado del simulador viven fuera de ella.
        let captura = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        captura.name = nombre
        captura.lifetime = .keepAlways
        add(captura)
    }
}
