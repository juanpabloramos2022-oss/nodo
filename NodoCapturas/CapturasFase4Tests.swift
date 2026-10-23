import Foundation
import XCTest

/// Capturas de verificacion visual de la Fase 4 (SPEC §5).
///
/// Un test por captura. La raiz ya es la definitiva de tres pestanas; Mi
/// Contexto se abre con un estado de PRUEBA que siembra Memoria, tope, skills y
/// contadores. Ninguna captura usa datos reales.
final class CapturasFase4Tests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    // MARK: - Raiz de tres pestanas

    /// SPEC §3/§5: la raiz muestra Chats, Mi Contexto y Conexiones, y la vieja
    /// pestana Ajustes ya no existe.
    func testF4TresPestanas() throws {
        lanzar(estado: "chat")

        XCTAssertTrue(
            app.tabBars.buttons["Chats"].waitForExistence(timeout: 60),
            "Falta la pestana Chats"
        )
        XCTAssertTrue(
            app.tabBars.buttons["Mi Contexto"].waitForExistence(timeout: 30),
            "Falta la pestana Mi Contexto"
        )
        XCTAssertTrue(
            app.tabBars.buttons["Conexiones"].waitForExistence(timeout: 30),
            "Falta la pestana Conexiones"
        )
        XCTAssertFalse(
            app.tabBars.buttons["Ajustes"].exists,
            "La pestana Ajustes no puede sobrevivir como cuarta pestana"
        )
        Thread.sleep(forTimeInterval: 0.4)

        disparar("f4-tres-pestanas")
    }

    // MARK: - Conexiones

    /// SPEC §3.6/§4.8: UNA tarjeta InferHub con sus cuatro combos, la tarjeta
    /// MCP y la seccion Respaldo al final de la pestana.
    func testF4ConexionesLimpias() throws {
        lanzar(estado: "chat")
        abrirConexiones()

        let encabezado = elemento(identifier: "proveedor-grupo")
        XCTAssertTrue(
            encabezado.waitForExistence(timeout: 30),
            "No aparecio la tarjeta agrupada de proveedores"
        )
        XCTAssertTrue(
            encabezado.label.contains("InferHub"),
            "La tarjeta no se encabeza con el nombre limpio InferHub: \(encabezado.label)"
        )

        for modelo in [
            "deepseek-v4-1-flash",
            "glm-5-3-flash",
            "gpt-6-1-sol",
            "gpt-6-astra"
        ] {
            XCTAssertTrue(
                app.buttons["Editar \(modelo)"].waitForExistence(timeout: 30),
                "Falta la fila del combo \(modelo) dentro de la tarjeta"
            )
        }

        XCTAssertTrue(
            elemento(identifier: "anadir-modelo-combo").waitForExistence(timeout: 30),
            "Falta + Anadir modelo/combo al final de la tarjeta"
        )
        XCTAssertTrue(
            elemento(identifier: "tarjeta-mcp").waitForExistence(timeout: 30),
            "Falta la tarjeta MCP"
        )
        Thread.sleep(forTimeInterval: 0.4)

        disparar("f4-conexiones")

        let exportar = elemento(identifier: "exportar-respaldo")
        XCTAssertTrue(
            exportar.waitForExistence(timeout: 30),
            "Falta Exportar mi configuracion en la seccion Respaldo"
        )
        XCTAssertTrue(
            elemento(identifier: "importar-respaldo").waitForExistence(timeout: 30),
            "Falta Importar configuracion en la seccion Respaldo"
        )
        asegurarVisible(exportar)
        Thread.sleep(forTimeInterval: 0.4)

        disparar("f4-conexiones-respaldo")
    }

    // MARK: - Mi Contexto

    /// SPEC §3.5: los tres bloques, el peso con ~, el acumulador encima de los
    /// botones y el tope vigente marcado.
    func testF4MiContextoCompleta() throws {
        lanzar(estado: "mi-contexto")
        abrirMiContexto()

        let peso = elemento(identifier: "memoria-peso")
        XCTAssertTrue(
            peso.waitForExistence(timeout: 30),
            "No aparecio el peso estimado de la Memoria"
        )
        XCTAssertTrue(
            peso.label.contains("~") && peso.label.contains("tokens est."),
            "El peso no usa el formato ~N tokens est.: \(peso.label)"
        )

        let acumulado = elemento(identifier: "gasto-acumulado")
        XCTAssertTrue(
            acumulado.waitForExistence(timeout: 30),
            "No aparecio la linea del acumulador global"
        )
        XCTAssertTrue(
            acumulado.label.contains("Gasto acumulado: Hoy"),
            "La linea del acumulador no empieza por 'Gasto acumulado: Hoy'"
        )
        XCTAssertTrue(
            acumulado.label.contains("Desde el último reinicio"),
            "La linea del acumulador no muestra el total desde el reinicio"
        )
        XCTAssertTrue(
            elemento(identifier: "reiniciar-contador").waitForExistence(timeout: 30),
            "Falta el boton [Reiniciar contador]"
        )

        let vigente = app.buttons["tope-25"]
        XCTAssertTrue(
            vigente.waitForExistence(timeout: 30),
            "No aparecio el boton rapido del tope vigente"
        )
        XCTAssertTrue(
            vigente.isSelected || (vigente.value as? String) == "Seleccionado",
            "El tope vigente 0.25 no aparece marcado como seleccionado"
        )

        XCTAssertTrue(
            elemento(identifier: "memoria-editar").waitForExistence(timeout: 30),
            "Falta la salida para editar la Memoria"
        )
        XCTAssertTrue(
            elemento(identifier: "skill-nueva").waitForExistence(timeout: 30),
            "Falta el boton para crear una skill"
        )
        Thread.sleep(forTimeInterval: 0.4)

        disparar("f4-mi-contexto")

        // Segunda foto con scroll minimo: la lista de skills con su slug.
        app.swipeUp()
        Thread.sleep(forTimeInterval: 0.4)
        disparar("f4-mi-contexto-skills")
    }

    /// SPEC §3.5: el editor de Memoria conserva Cancelar y Guardar.
    func testF4MemoriaEditor() throws {
        lanzar(estado: "mi-contexto")
        abrirMiContexto()

        let editar = elemento(identifier: "memoria-editar")
        XCTAssertTrue(
            editar.waitForExistence(timeout: 30),
            "No aparecio [Editar memoria]"
        )
        editar.tap()

        XCTAssertTrue(
            app.buttons["Cancelar"].waitForExistence(timeout: 30),
            "El editor de Memoria no muestra Cancelar"
        )
        XCTAssertTrue(
            app.buttons["Guardar"].waitForExistence(timeout: 30),
            "El editor de Memoria no muestra Guardar"
        )
        Thread.sleep(forTimeInterval: 0.4)

        disparar("f4-mi-contexto-memoria-editor")
    }

    /// SPEC §4.4: una skill recien creada aparece en la lista con su slug.
    func testF4SkillNueva() throws {
        lanzar(estado: "mi-contexto")
        abrirMiContexto()

        let nueva = elemento(identifier: "skill-nueva")
        XCTAssertTrue(
            nueva.waitForExistence(timeout: 30),
            "No aparecio [Nueva skill]"
        )
        asegurarVisible(nueva)
        nueva.tap()

        let nombre = app.textFields["skill-nombre"]
        XCTAssertTrue(
            nombre.waitForExistence(timeout: 30),
            "No aparecio el campo de nombre de la skill"
        )
        nombre.tap()
        nombre.typeText("Soporte")

        let instrucciones = app.textViews["skill-instrucciones"]
        XCTAssertTrue(
            instrucciones.waitForExistence(timeout: 30),
            "No aparecio el editor de instrucciones de la skill"
        )
        instrucciones.tap()
        instrucciones.typeText("Responde en tres puntos claros.")

        // Se baja el teclado con Listo para dejar libre la barra de la hoja.
        let listo = botonListo()
        if listo.waitForExistence(timeout: 5) {
            listo.tap()
        }

        let guardar = app.buttons["skill-guardar"]
        XCTAssertTrue(
            guardar.waitForExistence(timeout: 15),
            "No aparecio Guardar en la hoja de skill"
        )
        XCTAssertTrue(guardar.isEnabled, "Guardar esta deshabilitado tras escribir el nombre")
        guardar.tap()

        let slug = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "/soporte")
        ).firstMatch
        XCTAssertTrue(
            slug.waitForExistence(timeout: 30),
            "La skill creada no muestra su slug /soporte en la lista"
        )
        asegurarVisible(slug)
        Thread.sleep(forTimeInterval: 0.4)

        disparar("f4-mi-contexto-skill-nueva")
    }

    /// SPEC §4.4: un nombre reservado muestra el aviso y no crea la skill.
    func testF4SkillNombreReservado() throws {
        lanzar(estado: "mi-contexto")
        abrirMiContexto()

        let nueva = elemento(identifier: "skill-nueva")
        XCTAssertTrue(
            nueva.waitForExistence(timeout: 30),
            "No aparecio [Nueva skill]"
        )
        asegurarVisible(nueva)
        nueva.tap()

        let nombre = app.textFields["skill-nombre"]
        XCTAssertTrue(
            nombre.waitForExistence(timeout: 30),
            "No aparecio el campo de nombre de la skill"
        )
        nombre.tap()
        nombre.typeText("Compact")

        let instrucciones = app.textViews["skill-instrucciones"]
        XCTAssertTrue(
            instrucciones.waitForExistence(timeout: 30),
            "No aparecio el editor de instrucciones de la skill"
        )
        instrucciones.tap()
        instrucciones.typeText("Esto no debe guardarse.")

        let listo = botonListo()
        if listo.waitForExistence(timeout: 5) {
            listo.tap()
        }

        app.buttons["skill-guardar"].tap()

        let aviso = elemento(identifier: "skill-aviso")
        XCTAssertTrue(
            aviso.waitForExistence(timeout: 30),
            "El nombre reservado no mostro el aviso visible"
        )
        XCTAssertTrue(
            aviso.label.lowercased().contains("reservado"),
            "El aviso no explica que el nombre esta reservado: \(aviso.label)"
        )
        Thread.sleep(forTimeInterval: 0.4)

        disparar("f4-mi-contexto-skill-reservada")
    }

    // MARK: - Skill invocada en un chat

    /// SPEC §4.4: la skill resuelta se inyecta en el payload y la burbuja del
    /// mensaje muestra la etiqueta visual ⚡ nombre. La captura ensena la
    /// etiqueta; el payload se verifica en el test unitario del nucleo.
    func testF4SkillEnviada() throws {
        lanzar(estado: "mi-contexto")
        abrirConversacion("Chat de ejemplo")
        escribirYEnviar("/resumidor hola")

        let etiqueta = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "⚡ Resumidor")
        ).firstMatch
        XCTAssertTrue(
            etiqueta.waitForExistence(timeout: 60),
            "La burbuja del mensaje no muestra la etiqueta ⚡ de la skill"
        )
        Thread.sleep(forTimeInterval: 0.4)

        disparar("f4-skill-enviada")
    }

    // MARK: - Tarjeta de Bienvenida
    /// SPEC §3.2: la Tarjeta muestra el tope vigente real bajo el titulo.
    func testF4BienvenidaTope() throws {
        lanzar(estado: "bienvenida")
        abrirConversacion("Chat de ejemplo")

        let tope = elemento(identifier: "tope-bienvenida")
        XCTAssertTrue(
            tope.waitForExistence(timeout: 60),
            "La Tarjeta de Bienvenida no muestra el tope vigente"
        )
        XCTAssertTrue(
            tope.label.contains("Tope de aviso por chat: $1.00"),
            "El tope de la Tarjeta no tiene el formato esperado: \(tope.label)"
        )
        Thread.sleep(forTimeInterval: 0.4)

        disparar("f4-bienvenida-tope")
    }

    // MARK: - Navegacion y utilidades

    private func abrirConexiones() {
        let conexiones = app.tabBars.buttons["Conexiones"]
        XCTAssertTrue(
            conexiones.waitForExistence(timeout: 60),
            "No aparecio la pestana Conexiones"
        )
        conexiones.tap()
    }

    private func abrirMiContexto() {
        let contexto = app.tabBars.buttons["Mi Contexto"]
        XCTAssertTrue(
            contexto.waitForExistence(timeout: 60),
            "No aparecio la pestana Mi Contexto"
        )
        contexto.tap()
    }

    /// Escribe en la caja, baja el teclado con Listo y pulsa Enviar.
    private func escribirYEnviar(_ texto: String) {
        let caja = app.descendants(matching: .any)
            .matching(identifier: "caja-mensaje")
            .firstMatch
        XCTAssertTrue(
            caja.waitForExistence(timeout: 60),
            "No aparecio la caja de mensaje"
        )
        caja.tap()

        let listo = botonListo()
        XCTAssertTrue(
            listo.waitForExistence(timeout: 60),
            "No aparecio la barra Listo sobre el teclado"
        )
        caja.typeText(texto)
        listo.tap()

        let teclado = app.keyboards.element
        let oculto = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: teclado
        )
        _ = XCTWaiter().wait(for: [oculto], timeout: 15)

        let enviar = app.buttons["enviar-mensaje"]
        XCTAssertTrue(
            enviar.waitForExistence(timeout: 30),
            "No aparecio el boton Enviar"
        )
        XCTAssertTrue(enviar.isEnabled, "El boton Enviar esta deshabilitado")
        enviar.tap()
    }

    private func abrirConversacion(_ titulo: String) {
        let fila = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", titulo)
        ).firstMatch
        XCTAssertTrue(
            fila.waitForExistence(timeout: 60),
            "No aparecio la fila \(titulo) en la lista de Chats"
        )
        fila.tap()

        let pildora = app.descendants(matching: .any)
            .matching(identifier: "pildora-modelo")
            .firstMatch
        XCTAssertTrue(
            pildora.waitForExistence(timeout: 30),
            "No se abrio la conversacion \(titulo)"
        )
    }

    private func elemento(identifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    /// Si el elemento quedo por debajo del pliegue, desplaza el formulario.
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

    private func botonListo() -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier == %@ OR label == %@", "teclado-listo", "Listo")
        ).firstMatch
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
