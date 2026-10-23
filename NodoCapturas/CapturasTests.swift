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

    // MARK: - Fase 2: cabecera, tira fina, hojas y modo Tarea

    /// SPEC §5, Fase 2: "cabecera despejada completa (solo ← Chats, píldora y
    /// •••) con el teclado abierto".
    func testF2CabeceraTecladoAbierto() throws {
        lanzar(estado: "chat")
        abrirConversacion("Chat de ejemplo")
        abrirTecladoEnLaCaja()

        XCTAssertTrue(app.buttons["pildora-modelo"].exists, "Falta la pildora")
        XCTAssertTrue(app.buttons["menu-chat"].exists, "Falta el menu de acciones")

        adjuntarCaptura("f2-cabecera-teclado-abierto")
    }

    /// SPEC §5, Fase 2: "tira fina con Chat | Tarea y 🧠" sobre la caja.
    func testF2TiraFina() throws {
        lanzar(estado: "chat")
        abrirConversacion("Chat de ejemplo")

        // Se abre y se baja el teclado con Listo para que el encuadre sea el
        // mismo de la conversacion, pero sin teclado tapando la tira.
        abrirTecladoEnLaCaja()
        tocarListo()
        esperarTecladoOculto()
        // Margen para que termine la animacion de bajada del teclado.
        Thread.sleep(forTimeInterval: 0.3)

        let modo = app.descendants(matching: .any)
            .matching(identifier: "modo-chat")
            .firstMatch
        XCTAssertTrue(
            modo.waitForExistence(timeout: 30),
            "No aparecio el conmutador Chat | Tarea"
        )
        XCTAssertTrue(
            app.buttons["memoria-rapida"].exists,
            "No aparecio el boton de Memoria rapida"
        )

        adjuntarCaptura("f2-tira-fina")
    }

    /// SPEC §5, Fase 2: "menú de la píldora abierto" con los modelos y el ✓.
    func testF2MenuPildora() throws {
        lanzar(estado: "chat")
        abrirConversacion("Chat de ejemplo")

        let pildora = app.buttons["pildora-modelo"]
        XCTAssertTrue(pildora.waitForExistence(timeout: 30), "No aparecio la pildora")
        pildora.tap()

        let activo = elementoDeMenu("deepseek-v4-1-flash")
        let otro = elementoDeMenu("glm-5-3-flash")
        XCTAssertTrue(
            activo.waitForExistence(timeout: 30),
            "El menu no muestra el modelo activo"
        )
        XCTAssertTrue(
            otro.waitForExistence(timeout: 30),
            "El menu no muestra los otros modelos"
        )
        // Margen para que el menu termine de desplegarse antes de la foto.
        Thread.sleep(forTimeInterval: 0.3)

        adjuntarCaptura("f2-menu-pildora")
    }

    /// SPEC §5, Fase 2: "divisor tras un cambio de modelo".
    func testF2DivisorCambioModelo() throws {
        lanzar(estado: "chat")
        abrirConversacion("Chat de ejemplo")

        app.buttons["pildora-modelo"].tap()

        let otro = elementoDeMenu("glm-5-3-flash")
        XCTAssertTrue(
            otro.waitForExistence(timeout: 30),
            "No aparecio el modelo glm en el menu"
        )
        otro.tap()

        let divisor = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Ahora responde")
        ).firstMatch
        XCTAssertTrue(
            divisor.waitForExistence(timeout: 30),
            "No aparecio el divisor del cambio de modelo"
        )
        // Margen para que el menu se cierre y el hilo termine de desplazarse.
        Thread.sleep(forTimeInterval: 0.5)

        adjuntarCaptura("f2-divisor-cambio-modelo")
    }

    /// SPEC §5, Fase 2: "hoja Estado del chat con las dos métricas rotuladas".
    func testF2EstadoDelChat() throws {
        lanzar(estado: "chat")
        abrirConversacion("Chat de ejemplo")

        let botonMenu = app.buttons["menu-chat"]
        XCTAssertTrue(
            botonMenu.waitForExistence(timeout: 30),
            "Falta el menu de acciones"
        )
        // Toque por coordenadas: el scroll-to-visible por AX de XCUITest falla
        // con este boton de toolbar cuando hay un ScrollView debajo.
        let marcoMenu = botonMenu.frame
        if !marcoMenu.isEmpty {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                .withOffset(CGVector(dx: marcoMenu.midX, dy: marcoMenu.midY))
                .tap()
        } else {
            botonMenu.tap()
        }
        let opcion = elementoDeMenu("Estado del chat")
        XCTAssertTrue(
            opcion.waitForExistence(timeout: 30),
            "No aparecio la opcion Estado del chat"
        )
        opcion.tap()

        XCTAssertTrue(
            app.navigationBars["Estado del chat"].waitForExistence(timeout: 60),
            "No se abrio la hoja Estado del chat"
        )

        let ocupacion = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Ocupaci")
        ).firstMatch
        let consumo = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Consumo acumulado")
        ).firstMatch
        XCTAssertTrue(
            ocupacion.waitForExistence(timeout: 30),
            "Falta la seccion Ocupacion de la ventana"
        )
        XCTAssertTrue(
            consumo.waitForExistence(timeout: 30),
            "Falta la seccion Consumo acumulado del chat"
        )
        // Margen para que la hoja termine de presentarse.
        Thread.sleep(forTimeInterval: 0.4)

        adjuntarCaptura("f2-estado-del-chat")
    }

    /// SPEC §5, Fase 2: "hoja Memoria rápida con Cancelar/Guardar".
    func testF2MemoriaRapida() throws {
        lanzar(estado: "chat")
        abrirConversacion("Chat de ejemplo")

        let memoria = app.buttons["memoria-rapida"]
        XCTAssertTrue(
            memoria.waitForExistence(timeout: 30),
            "No aparecio el boton de Memoria rapida"
        )
        memoria.tap()

        XCTAssertTrue(
            app.navigationBars["Memoria rápida"].waitForExistence(timeout: 60),
            "No se abrio la hoja Memoria rapida"
        )
        XCTAssertTrue(app.buttons["Cancelar"].exists, "Falta Cancelar")
        XCTAssertTrue(app.buttons["Guardar"].exists, "Falta Guardar")
        // Margen para que la hoja termine de presentarse.
        Thread.sleep(forTimeInterval: 0.4)

        adjuntarCaptura("f2-memoria-rapida")
    }

    /// SPEC §5/§4.3: la hoja de aprobacion aparece ANTES de ejecutar una
    /// herramienta con consecuencias y solo ofrece Aprobar o Rechazar.
    func testF2TareaAprobacion() throws {
        lanzar(estado: "tarea")
        abrirConversacion("Tarea de ejemplo")
        escribirYEnviar("Mensaje de ejemplo para la tarea.")

        _ = esperarHojaDeAprobacion()

        let ejecutando = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Ejecutando")
        ).firstMatch
        XCTAssertFalse(
            ejecutando.exists,
            "La herramienta se ejecuto antes de que el usuario aprobara"
        )
        // Margen para que la hoja de aprobacion termine de presentarse.
        Thread.sleep(forTimeInterval: 0.5)

        adjuntarCaptura("f2-tarea-aprobacion")
    }

    /// SPEC §5/§4.3: tras aprobar, el turno termina con la respuesta final de
    /// ejemplo y el paso plegable de la herramienta.
    func testF2TareaPasoCompletado() throws {
        lanzar(estado: "tarea")
        abrirConversacion("Tarea de ejemplo")
        escribirYEnviar("Mensaje de ejemplo para la tarea.")

        let aprobar = esperarHojaDeAprobacion()
        // Margen para que la hoja termine de presentarse antes de tocarla.
        Thread.sleep(forTimeInterval: 0.5)
        aprobar.tap()

        // La costura de prueba puede cambiar el texto final entre corridas;
        // se aceptan las dos respuestas de ejemplo conocidas.
        let final = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS %@ OR label CONTAINS %@",
                "Respuesta de ejemplo para las capturas",
                "He completado la tarea de ejemplo"
            )
        ).firstMatch
        XCTAssertTrue(
            final.waitForExistence(timeout: 90),
            "No aparecio la respuesta final del turno de tarea"
        )

        let paso = app.descendants(matching: .any)
            .matching(identifier: "paso-herramienta")
            .firstMatch
        XCTAssertTrue(
            paso.waitForExistence(timeout: 30),
            "No quedo el paso plegable de la herramienta"
        )
        // Margen para que el hilo termine de desplazarse hasta el final.
        Thread.sleep(forTimeInterval: 0.4)

        adjuntarCaptura("f2-tarea-paso-completado")
    }

    /// SPEC §4.3: intento del estado intermedio "Ejecutando..." justo tras
    /// aprobar. Si el turno termina antes de la foto, el test no falla: las
    /// capturas obligatorias son la de aprobacion y la del paso completado.
    func testF2TareaEjecutando() throws {
        lanzar(estado: "tarea")
        abrirConversacion("Tarea de ejemplo")
        escribirYEnviar("Mensaje de ejemplo para la tarea.")

        let aprobar = esperarHojaDeAprobacion()
        // Margen para que la hoja termine de presentarse antes de tocarla.
        Thread.sleep(forTimeInterval: 0.5)
        aprobar.tap()
        esperarQueDesaparezca(aprobar)
        // Margen para que la hoja termine de retirarse y se vea la fila viva.
        Thread.sleep(forTimeInterval: 0.3)

        let ejecutando = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Ejecutando")
        ).firstMatch
        guard ejecutando.waitForExistence(timeout: 3) else {
            // El turno fue mas rapido que la foto; no se fuerza un fallo por
            // una captura que la propia SPEC marca como intento.
            return
        }
        // Margen minimo para que la fila y el spinner se pinten.
        Thread.sleep(forTimeInterval: 0.1)

        adjuntarCaptura("f2-tarea-ejecutando")
    }

    // MARK: - Ayudas

    /// Entra a la conversacion tocando su fila en la lista de Chats.
    private func abrirConversacion(_ titulo: String) {
        // La fila es un boton; se busca por su etiqueta porque SwiftUI puede
        // combinar el titulo y el contador de mensajes en un solo elemento.
        let fila = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", titulo)
        ).firstMatch

        if fila.waitForExistence(timeout: 60) {
            fila.tap()
        } else {
            // Respaldo por si una version de iOS expone el titulo como texto
            // suelto en lugar de dentro del boton de la fila.
            let texto = app.staticTexts[titulo]
            XCTAssertTrue(
                texto.waitForExistence(timeout: 15),
                "No aparecio la fila \(titulo) en la lista de Chats"
            )
            texto.tap()
        }

        // La pildora se espera como CUALQUIER tipo de elemento, no solo como
        // boton: asi el fallo distingue "no se navego" de "la pildora existe
        // pero no se expone como boton". El timeout es corto a proposito:
        // cuando la navegacion no ocurre, fallar a los 20 s abarata el
        // diagnostico (y deja la evidencia menos contaminada por la espera).
        let pildora = app.descendants(matching: .any)
            .matching(identifier: "pildora-modelo")
            .firstMatch
        let aparecio = pildora.waitForExistence(timeout: 20)
        // El resto de los tests toca la pildora como boton, asi que se sigue
        // exigiendo ese tipo, con un margen corto para que el toolbar termine
        // de exponerla. Si la busqueda amplia ya fallo no se espera de mas.
        let esBoton = aparecio
            && app.buttons["pildora-modelo"].waitForExistence(timeout: 5)

        if !aparecio {
            // Evidencia de lo que hay en pantalla justo despues del toque: la
            // foto dice si se navego o no y la jerarquia dice que se pinta y
            // con que tipos de elemento.
            adjuntarCaptura("diagnostico-tras-toque")
            adjuntarJerarquia()
        } else if !esBoton {
            // La pildora esta, pero no como boton: la jerarquia es la prueba.
            adjuntarJerarquia()
        }

        XCTAssertTrue(
            aparecio && esBoton,
            "No se abrio la conversacion \(titulo)"
        )
        // Margen para que termine la animacion de empuje de la pila antes de
        // tocar la cabecera o la tira fina.
        Thread.sleep(forTimeInterval: 0.4)
    }

    /// Toca la caja de texto y espera a que el teclado y su barra Listo esten
    /// arriba. Se usa en las capturas de cabecera y de la tira fina.
    private func abrirTecladoEnLaCaja() {
        let caja = app.descendants(matching: .any)
            .matching(identifier: "caja-mensaje")
            .firstMatch
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
    /// teclado para que las capturas de la hoja no lo incluyan.
    private func escribirYEnviar(_ texto: String) {
        abrirTecladoEnLaCaja()

        let caja = app.descendants(matching: .any)
            .matching(identifier: "caja-mensaje")
            .firstMatch
        caja.typeText(texto)

        tocarListo()
        esperarTecladoOculto()
        // Margen para que la caja y el boton Enviar vuelvan a su sitio.
        Thread.sleep(forTimeInterval: 0.3)

        let enviar = app.buttons["enviar-mensaje"]
        XCTAssertTrue(
            enviar.waitForExistence(timeout: 30),
            "No aparecio el boton Enviar"
        )
        XCTAssertTrue(enviar.isEnabled, "El boton Enviar esta deshabilitado")
        enviar.tap()
    }

    /// Espera la hoja de aprobacion y comprueba sus dos unicas salidas.
    private func esperarHojaDeAprobacion() -> XCUIElement {
        let aprobar = app.buttons["Aprobar"]
        XCTAssertTrue(
            aprobar.waitForExistence(timeout: 90),
            "No aparecio la hoja de aprobacion antes de ejecutar la herramienta"
        )
        XCTAssertTrue(app.buttons["Rechazar"].exists, "Falta la salida Rechazar")
        return aprobar
    }

    /// Espera a que un elemento desaparezca (por ejemplo, la hoja al cerrarse).
    private func esperarQueDesaparezca(_ elemento: XCUIElement, timeout: TimeInterval = 15) {
        let expectativa = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: elemento
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectativa], timeout: timeout),
            .completed,
            "El elemento no desaparecio a tiempo"
        )
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

    /// Primer elemento del menu abierto que contiene la etiqueta indicada.
    /// Se prefiere el boton (lo normal en un menu nativo) y se cae al arbol
    /// completo porque algunas versiones de iOS exponen el item como texto.
    private func elementoDeMenu(_ etiqueta: String) -> XCUIElement {
        let predicado = NSPredicate(format: "label CONTAINS %@", etiqueta)
        let boton = app.buttons.matching(predicado).firstMatch
        if boton.waitForExistence(timeout: 5) {
            return boton
        }
        return app.descendants(matching: .any).matching(predicado).firstMatch
    }

    /// Boton Listo de la barra del teclado.
    private func botonListo() -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier == %@ OR label == %@", "teclado-listo", "Listo")
        ).firstMatch
    }

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

    /// Adjunta la jerarquia de accesibilidad de la app como texto plano.
    ///
    /// Es la evidencia que dice si la navegacion no ocurrio, si el destino
    /// pinta otra cosa o si la pildora existe con otro tipo de elemento.
    /// `herramientas/extraer-capturas.py` la copia como .txt junto a los PNG.
    /// El nombre permite distinguir cada momento del diagnostico.
    private func adjuntarJerarquia(nombre: String = "diagnostico-jerarquia") {
        let jerarquia = XCTAttachment(string: app.debugDescription)
        jerarquia.name = nombre
        jerarquia.lifetime = .keepAlways
        add(jerarquia)
    }
}
