import Foundation
import XCTest

@testable import NodoCore

/// Pruebas de la Memoria viva (MEM.1/D5) y del esquema tipado de B2.1.
///
/// La migracion y el respaldo son las dos puertas por las que puede perderse lo
/// que el dueno ya tenia escrito. Por eso se prueba el texto completo, no solo
/// que la lista tenga una entrada.
final class MemoriaTests: XCTestCase {
    private let idUno = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let idDos = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    // MARK: - Migracion de la configuracion

    func testMigracionDelTextoLegadoAUnaSolaEntradaConservaElTextoCompleto() throws {
        let texto = "Primera linea\n\nSegunda linea con datos: 42\n- y un guion"
        let json: [String: Any] = [
            "version": 1,
            "proveedores": [],
            "systemPrompt": texto,
            "servidor": ["nombre": "Servidor", "url": "", "activo": false] as [String: Any]
        ]
        let datos = try JSONSerialization.data(withJSONObject: json)

        let config = try AppConfig.desde(json: datos)

        XCTAssertEqual(
            config.memoria.count,
            1,
            "El texto legado no puede trocearse en varias entradas"
        )
        XCTAssertEqual(
            config.memoria.first?.texto,
            texto,
            "La migracion tiene que conservar el texto completo, no una version recortada"
        )
        XCTAssertEqual(
            config.memoria.first?.categoria,
            .durableFact,
            "Una entrada migrada sin categoria se lee como dato durable"
        )
    }

    func testUnTextoLegadoVacioNoCreaEntrada() throws {
        let json: [String: Any] = [
            "version": 1,
            "proveedores": [],
            "systemPrompt": "   \n  ",
            "servidor": ["nombre": "Servidor", "url": "", "activo": false] as [String: Any]
        ]
        let datos = try JSONSerialization.data(withJSONObject: json)

        let config = try AppConfig.desde(json: datos)

        XCTAssertTrue(config.memoria.isEmpty)
    }

    func testLaMemoriaNuevaSobreviveAlJSONDeLaConfiguracion() throws {
        let entradas = [
            EntradaMemoria(
                id: idUno,
                texto: "Vive en Madrid",
                fecha: Date(timeIntervalSince1970: 100),
                categoria: .durableFact
            ),
            EntradaMemoria(
                id: idDos,
                texto: "Prefiere respuestas breves",
                fecha: Date(timeIntervalSince1970: 200),
                categoria: .preference
            )
        ]
        let config = AppConfig(memoria: entradas)

        let vuelta = try AppConfig.desde(json: try config.json())

        XCTAssertEqual(vuelta.memoria, entradas)
    }

    /// B2.1: una entrada guardada antes del esquema tipado no trae categoria.
    /// Debe seguir decodificando, con valor por defecto, sin perder el texto.
    func testUnaEntradaViejaSinCategoriaSeLeeComoDatoDurable() throws {
        let json = """
        {
          "id": "11111111-1111-4111-8111-111111111111",
          "texto": "Vive en Madrid desde 2019",
          "fecha": 0
        }
        """

        let entrada = try JSONDecoder().decode(
            EntradaMemoria.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(entrada.texto, "Vive en Madrid desde 2019")
        XCTAssertEqual(entrada.categoria, .durableFact)
    }

    // MARK: - Respaldo

    func testRespaldoIdaYVueltaConservaLasEntradas() throws {
        let entradas = [
            EntradaMemoria(
                id: idUno,
                texto: "Vive en Madrid",
                fecha: Date(timeIntervalSince1970: 100),
                categoria: .durableFact
            ),
            EntradaMemoria(
                id: idDos,
                texto: "Prefiere respuestas breves",
                fecha: Date(timeIntervalSince1970: 200),
                categoria: .preference
            )
        ]
        let config = AppConfig(memoria: entradas, topeAvisoCosto: 0.25)

        let respaldo = RespaldoConfiguracion.hacerRespaldo(
            config: config,
            ventanas: [:]
        )
        let leido = try RespaldoConfiguracion.desde(json: try respaldo.json())

        XCTAssertEqual(leido.memoria, entradas)

        let restaurada = RespaldoConfiguracion.aplicar(leido, sobre: AppConfig())
        XCTAssertEqual(restaurada.memoria, entradas)
    }

    func testUnRespaldoViejoConTextoPlanoImportaComoUnaEntrada() throws {
        let texto = "Memoria vieja completa\ncon dos lineas y datos: 42"
        let json = """
        {
          "memoria": "Memoria vieja completa\\ncon dos lineas y datos: 42",
          "skills": [],
          "ventanas": {},
          "proveedores": [],
          "topeGlobalUSD": 1.0
        }
        """

        let respaldo = try RespaldoConfiguracion.desde(json: Data(json.utf8))

        XCTAssertEqual(respaldo.memoria.count, 1)
        XCTAssertEqual(respaldo.memoria.first?.texto, texto)
        XCTAssertEqual(respaldo.memoria.first?.categoria, .durableFact)
        XCTAssertEqual(respaldo.versionFormato, 1)
    }

    // MARK: - Bloque de sistema

    func testElBloqueInyectaIdCategoriaYTextoDeCadaEntrada() {
        let entradas = [
            EntradaMemoria(
                id: idUno,
                texto: "Vive en Madrid",
                categoria: .durableFact
            ),
            EntradaMemoria(
                id: idDos,
                texto: "Prefiere respuestas breves",
                categoria: .preference
            )
        ]

        let bloque = Memoria.bloqueSistema(entradas: entradas)

        XCTAssertTrue(bloque.contains(Memoria.cabeceraBloque))
        XCTAssertTrue(bloque.contains(Memoria.nombreGuardar))
        XCTAssertTrue(bloque.contains(Memoria.nombreActualizar))
        XCTAssertTrue(bloque.contains(Memoria.nombreBorrar))
        XCTAssertFalse(bloque.contains("memoria_chat"))
        for entrada in entradas {
            XCTAssertTrue(
                bloque.contains(
                    "- id: \(entrada.id.uuidString) · categoria: "
                        + "\(entrada.categoria.rawValue) · texto: \(entrada.texto)"
                ),
                "Cada entrada viaja con su id, su categoria y su texto"
            )
        }
    }

    /// B1.3: el bloque conserva el disparo y el parrafo de comunicacion.
    ///
    /// B2.1 solo cambia la linea de herramienta (de `memoria_chat` al conjunto
    /// tipado) y anade el candado de borrado de PDE-A1. Las cuatro reglas de
    /// comunicacion se copian literales: si una sesion futura las toca, esta
    /// prueba falla.
    func testElBloqueConservaElParrafoDeComunicacionYAnadeElCandadoDeBorrado() {
        let entradas = [
            EntradaMemoria(id: idUno, texto: "Vive en Madrid")
        ]

        let bloque = Memoria.bloqueSistema(entradas: entradas)

        let disparo = "Puedes guardar, actualizar o borrar entradas de esta memoria SOLO cuando el dueno te lo ordene de forma explicita. No lo hagas por iniciativa propia ni en silencio."
        let herramienta = "Usa las herramientas tipadas de memoria: save_memory (content + category), update_memory (entry_id + content + category) y delete_memory (entry_id). Ninguna de ellas admite una categoria sensible. Un dato sensible (salud, finanzas, documentos de identidad o datos intimos) nunca va por save_memory ni por update_memory: su unica via es propose_sensitive_memory (content + sensitive_category), y la app pedira aprobacion al dueno antes de escribir nada."
        let candado = "Candado de borrado: delete_memory solo ante orden explicita del dueno en ese turno; nunca por iniciativa propia del modelo, ni siquiera con la memoria inteligente activada."

        XCTAssertTrue(bloque.contains(disparo), "El disparo general no cambia en B2.1")
        XCTAssertTrue(bloque.contains(herramienta), "La linea de herramienta es la tipada")
        XCTAssertTrue(
            bloque.contains(disparo + "\n" + herramienta + "\n\n"),
            "La comunicacion va en un parrafo separado, despues del disparo"
        )
        XCTAssertTrue(bloque.contains(candado))
        XCTAssertEqual(
            bloque.components(separatedBy: disparo).count - 1,
            1,
            "El disparo aparece exactamente una vez y sin reescrituras"
        )
        XCTAssertEqual(
            bloque.components(separatedBy: candado).count - 1,
            1,
            "El candado de borrado aparece exactamente una vez"
        )

        // Las 4 reglas normativas de B1.3, afirmadas sobre el texto real.
        XCTAssertTrue(bloque.contains("no menciones la memoria"))
        XCTAssertTrue(bloque.contains("Nunca afirmes haber guardado"))
        XCTAssertTrue(bloque.contains("«anotado mentalmente»"))
        XCTAssertTrue(bloque.contains("acuse en palabras es opcional"))
        XCTAssertTrue(bloque.contains("maximo 1 frase simple de 20 palabras"))
        XCTAssertTrue(
            bloque.contains("pregunta literalmente como funciona la memoria")
        )

        // Las entradas y sus ids siguen viajando.
        XCTAssertTrue(bloque.contains(entradas[0].id.uuidString))
        XCTAssertTrue(bloque.contains(entradas[0].texto))
    }

    // MARK: - Interruptor «Memoria inteligente» (B2.3)

    /// La rama ON presenta las cuatro categorias y el criterio de §5.5.2, y
    /// ordena expresar el juicio SOLO con las herramientas.
    func testLaRamaDeJuicioPresentaLasCuatroCategoriasYElCriterio() {
        let bloque = Memoria.bloqueSistema(
            entradas: [EntradaMemoria(id: idUno, texto: "Vive en Madrid")],
            disparo: .juicio
        )

        for categoria in [
            "durable_fact", "preference", "correction", "commitment"
        ] {
            XCTAssertTrue(
                bloque.contains(categoria),
                "La rama ON tiene que presentar \(categoria)"
            )
        }
        XCTAssertTrue(
            bloque.contains("Ante la duda entre guardar y no guardar, no guardes")
        )
        XCTAssertTrue(bloque.contains("No guardes detalles efimeros"))
        XCTAssertTrue(bloque.contains("SOLO invocando las herramientas"))
        XCTAssertTrue(bloque.contains("update_memory con el entry_id"))

        XCTAssertFalse(
            bloque.contains(Memoria.instruccionDeOrdenExplicita),
            "La rama ON no puede arrastrar el disparo de OFF"
        )

        // El parrafo de B1.3 y el candado son los mismos en las dos ramas y no
        // se duplican al cambiar el disparo.
        XCTAssertTrue(bloque.contains(Memoria.comunicacionDeMemoria))
        XCTAssertTrue(bloque.contains(Memoria.candadoDeBorrado))
        XCTAssertEqual(
            bloque.components(
                separatedBy: Memoria.comunicacionDeMemoria
            ).count - 1,
            1
        )
    }

    /// La rama OFF conserva el disparo literal de la v0.3.1 y no trae juicio.
    func testLaRamaOFFConservaElDisparoDeSiempreYNoTraeElJuicio() {
        let entradas = [EntradaMemoria(id: idUno, texto: "Vive en Madrid")]

        let porDefecto = Memoria.bloqueSistema(entradas: entradas)
        let explicita = Memoria.bloqueSistema(
            entradas: entradas,
            disparo: .ordenExplicita
        )

        XCTAssertEqual(porDefecto, explicita, "El defecto es OFF")
        XCTAssertTrue(
            porDefecto.contains(Memoria.instruccionDeOrdenExplicita)
        )
        XCTAssertFalse(porDefecto.contains("Memoria inteligente activada"))
        XCTAssertFalse(porDefecto.contains("cuatro categorias tipadas"))
        XCTAssertEqual(
            porDefecto.components(
                separatedBy: Memoria.instruccionDeOrdenExplicita
            ).count - 1,
            1
        )
    }

    /// Las dos ramas solo cambian el disparo: herramientas, comunicacion,
    /// candado y entradas con id quedan identicos.
    func testLasDosRamasSoloCambianElDisparo() {
        let entradas = [
            EntradaMemoria(
                id: idUno,
                texto: "Vive en Madrid",
                categoria: .durableFact
            ),
            EntradaMemoria(
                id: idDos,
                texto: "Prefiere respuestas breves",
                categoria: .preference
            )
        ]

        let off = Memoria.bloqueSistema(
            entradas: entradas,
            disparo: .ordenExplicita
        )
        let on = Memoria.bloqueSistema(
            entradas: entradas,
            disparo: .juicio
        )

        let restoOFF = off.replacingOccurrences(
            of: Memoria.instruccionDeOrdenExplicita,
            with: "<DISPARO>"
        )
        let restoON = on.replacingOccurrences(
            of: Memoria.instruccionDeJuicio,
            with: "<DISPARO>"
        )
        XCTAssertEqual(restoOFF, restoON)
    }

    // MARK: - Esquemas tipados (B2.1)

    func testLasCuatroHerramientasTipadasDeclaranSusCamposYObligatorios() {
        XCTAssertEqual(Memoria.herramientaGuardar.nombre, "save_memory")
        XCTAssertEqual(
            Set(Memoria.herramientaGuardar.parametros.propiedades.keys),
            ["content", "category", "confidence_score"]
        )
        XCTAssertEqual(
            Set(Memoria.herramientaGuardar.parametros.requeridos),
            ["content", "category"]
        )
        XCTAssertEqual(
            Memoria.herramientaGuardar.parametros
                .propiedades["category"]?.valoresPermitidos,
            ["durable_fact", "preference", "commitment"]
        )
        XCTAssertNil(
            Memoria.herramientaGuardar.parametros
                .propiedades["sensitive_category"],
            "save_memory no puede tener campo para una categoria sensible"
        )

        XCTAssertEqual(Memoria.herramientaActualizar.nombre, "update_memory")
        XCTAssertEqual(
            Set(Memoria.herramientaActualizar.parametros.requeridos),
            ["entry_id", "content", "category"]
        )
        XCTAssertEqual(
            Memoria.herramientaActualizar.parametros
                .propiedades["category"]?.valoresPermitidos,
            ["correction", "durable_fact", "preference", "commitment"]
        )

        XCTAssertEqual(
            Memoria.herramientaProponerSensible.nombre,
            "propose_sensitive_memory"
        )
        XCTAssertEqual(
            Set(Memoria.herramientaProponerSensible.parametros.requeridos),
            ["content", "sensitive_category"]
        )
        XCTAssertEqual(
            Memoria.herramientaProponerSensible.parametros
                .propiedades["sensitive_category"]?.valoresPermitidos,
            ["health", "finances", "documents_identifiers", "intimate"]
        )

        XCTAssertEqual(Memoria.herramientaBorrar.nombre, "delete_memory")
        XCTAssertEqual(
            Set(Memoria.herramientaBorrar.parametros.propiedades.keys),
            ["entry_id"]
        )
        XCTAssertEqual(
            Memoria.herramientaBorrar.parametros.requeridos,
            ["entry_id"]
        )
        XCTAssertNil(
            Memoria.herramientaBorrar.parametros.propiedades["category"],
            "delete_memory no lleva categoria"
        )
    }

    func testElEsquemaDeTareaSigueConAccionTextoEId() {
        let definicion = Memoria.herramientaTarea

        XCTAssertEqual(definicion.nombre, "proponer_memoria")
        XCTAssertNotNil(definicion.parametros.propiedades["accion"])
        XCTAssertNotNil(definicion.parametros.propiedades["texto"])
        XCTAssertNotNil(definicion.parametros.propiedades["id"])
        XCTAssertTrue(definicion.parametros.requeridos.contains("accion"))
    }

    // MARK: - Parseo tipado

    func testSaveMemoryLeeContentCategoriaYConfianza() throws {
        let operacion = try Memoria.operacion(
            herramienta: "save_memory",
            argumentos: #"{"content":"Vive en Madrid","category":"durable_fact","confidence_score":0.9}"#
        )

        XCTAssertEqual(
            operacion,
            .guardar(
                contenido: "Vive en Madrid",
                categoria: .durableFact,
                confianza: 0.9
            )
        )
    }

    func testSaveMemoryRechazaCategoriaSensibleYFueraDeRango() {
        XCTAssertThrowsError(
            try Memoria.operacion(
                herramienta: "save_memory",
                argumentos: #"{"content":"Toma insulina","category":"health"}"#
            ),
            "save_memory no admite una categoria sensible"
        )
        XCTAssertThrowsError(
            try Memoria.operacion(
                herramienta: "save_memory",
                argumentos: #"{"content":"Vive en Madrid","category":"durable_fact","confidence_score":1.5}"#
            )
        )
        XCTAssertThrowsError(
            try Memoria.operacion(
                herramienta: "save_memory",
                argumentos: #"{"content":"Vive en Madrid","category":"durable_fact","confidence_score":-0.1}"#
            )
        )
    }

    func testUpdateMemoryExigeEntryIdValidoYCorrigeLaCategoria() throws {
        let operacion = try Memoria.operacion(
            herramienta: "update_memory",
            argumentos: #"{"entry_id":"11111111-1111-4111-8111-111111111111","content":"Vive en Barcelona","category":"correction"}"#
        )

        XCTAssertEqual(
            operacion,
            .actualizar(
                id: idUno,
                contenido: "Vive en Barcelona",
                categoria: .correction,
                confianza: nil
            )
        )

        XCTAssertThrowsError(
            try Memoria.operacion(
                herramienta: "update_memory",
                argumentos: #"{"entry_id":"no-es-uuid","content":"Vive en Barcelona","category":"correction"}"#
            )
        )
    }

    func testDeleteMemoryExigeEntryIdYNoAceptaCategoria() throws {
        let operacion = try Memoria.operacion(
            herramienta: "delete_memory",
            argumentos: #"{"entry_id":"11111111-1111-4111-8111-111111111111"}"#
        )

        XCTAssertEqual(operacion, .borrar(id: idUno))

        XCTAssertThrowsError(
            try Memoria.operacion(
                herramienta: "delete_memory",
                argumentos: #"{"content":"sin id"}"#
            )
        )
    }

    func testProposeSensitiveMemoryLeeSuCategoriaSensible() throws {
        let operacion = try Memoria.operacion(
            herramienta: "propose_sensitive_memory",
            argumentos: #"{"content":"Toma insulina","sensitive_category":"health"}"#
        )

        XCTAssertEqual(
            operacion,
            .proponerSensible(
                contenido: "Toma insulina",
                categoria: .health,
                confianza: nil
            )
        )

        XCTAssertThrowsError(
            try Memoria.operacion(
                herramienta: "propose_sensitive_memory",
                argumentos: #"{"content":"Toma insulina","sensitive_category":"otra"}"#
            )
        )
    }

    func testUnaHerramientaDesconocidaSeRechaza() {
        XCTAssertThrowsError(
            try Memoria.operacion(
                herramienta: "memoria_chat",
                argumentos: #"{"accion":"guardar","texto":"Hola"}"#
            )
        )
    }

    // MARK: - Aplicacion tipada

    func testAplicarTipadaGuardarUsaLaCategoriaYDeshacerLaQuita() {
        var entradas: [EntradaMemoria] = []

        let resultado = Memoria.aplicarTipada(
            .guardar(
                contenido: "Prefiere cafe sin azucar",
                categoria: .preference,
                confianza: nil
            ),
            en: &entradas
        )

        guard case .aplicada(let cambio) = resultado else {
            return XCTFail("Se esperaba una operacion aplicada")
        }
        XCTAssertEqual(entradas.count, 1)
        XCTAssertEqual(entradas[0].categoria, .preference)

        Memoria.deshacer(cambio, en: &entradas)
        XCTAssertTrue(entradas.isEmpty)
    }

    func testAplicarTipadaActualizarCambiaLaCategoriaYDeshacerLaRestaura() {
        let original = EntradaMemoria(
            id: idUno,
            texto: "Vive en Madrid",
            categoria: .durableFact
        )
        var entradas = [original]

        let resultado = Memoria.aplicarTipada(
            .actualizar(
                id: idUno,
                contenido: "Vive en Barcelona",
                categoria: .correction,
                confianza: nil
            ),
            en: &entradas
        )

        guard case .aplicada(let cambio) = resultado else {
            return XCTFail("Se esperaba una operacion aplicada")
        }
        XCTAssertEqual(entradas.count, 1)
        XCTAssertEqual(entradas[0].texto, "Vive en Barcelona")
        XCTAssertEqual(entradas[0].categoria, .correction)

        Memoria.deshacer(cambio, en: &entradas)
        XCTAssertEqual(entradas, [original])
    }

    func testAplicarTipadaProponerSensibleNoTocaLaLista() {
        let original = EntradaMemoria(id: idUno, texto: "Vive en Madrid")
        var entradas = [original]

        let resultado = Memoria.aplicarTipada(
            .proponerSensible(
                contenido: "Toma insulina",
                categoria: .health,
                confianza: nil
            ),
            en: &entradas
        )

        guard case .rechazada = resultado else {
            return XCTFail("Una propuesta sensible nunca se aplica sola")
        }
        XCTAssertEqual(entradas, [original])
    }
}

// MARK: - Operaciones de lista (MEM.3)

/// Pruebas puras de aplicar y deshacer acciones sobre la lista.
///
/// Viven aparte de la migracion porque aqui no importa el formato guardado:
/// importa que el inverso devuelva EXACTAMENTE el estado anterior.
final class MemoriaOperacionesTests: XCTestCase {
    private let idUno = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let idDos = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    func testGuardarAnadeUnaEntradaYDeshacerLaQuita() {
        var entradas: [EntradaMemoria] = []

        let resultado = Memoria.aplicar(
            .guardar(texto: "Vive en Madrid"),
            en: &entradas
        )

        guard case .aplicada(let cambio) = resultado else {
            return XCTFail("Se esperaba una accion aplicada")
        }
        XCTAssertEqual(entradas.map(\.texto), ["Vive en Madrid"])

        Memoria.deshacer(cambio, en: &entradas)
        XCTAssertTrue(entradas.isEmpty)
    }

    func testActualizarCambiaSoloLaEntradaIndicadaYDeshacerRestauraElTexto() {
        let original = EntradaMemoria(
            id: idUno,
            texto: "Vive en Madrid",
            fecha: Date(timeIntervalSince1970: 100)
        )
        let otra = EntradaMemoria(
            id: idDos,
            texto: "Prefiere respuestas breves",
            fecha: Date(timeIntervalSince1970: 200)
        )
        var entradas = [original, otra]

        let resultado = Memoria.aplicar(
            .actualizar(id: idUno, texto: "Vive en Barcelona"),
            en: &entradas
        )

        guard case .aplicada(let cambio) = resultado else {
            return XCTFail("Se esperaba una accion aplicada")
        }
        XCTAssertEqual(entradas[0].texto, "Vive en Barcelona")
        XCTAssertEqual(entradas[1], otra)

        Memoria.deshacer(cambio, en: &entradas)
        XCTAssertEqual(entradas, [original, otra])
    }

    func testBorrarQuitaLaEntradaYDeshacerLaReinsertaEnSuPosicionConSuId() {
        let original = EntradaMemoria(
            id: idUno,
            texto: "Vive en Madrid",
            fecha: Date(timeIntervalSince1970: 100)
        )
        let otra = EntradaMemoria(
            id: idDos,
            texto: "Prefiere respuestas breves",
            fecha: Date(timeIntervalSince1970: 200)
        )
        var entradas = [original, otra]

        let resultado = Memoria.aplicar(.borrar(id: idUno), en: &entradas)

        guard case .aplicada(let cambio) = resultado else {
            return XCTFail("Se esperaba una accion aplicada")
        }
        XCTAssertEqual(entradas, [otra])

        Memoria.deshacer(cambio, en: &entradas)
        XCTAssertEqual(entradas, [original, otra])
    }

    func testUnIdDesconocidoSeRechazaSinTocarLaLista() {
        let original = EntradaMemoria(id: idUno, texto: "Vive en Madrid")
        var entradas = [original]

        let resultado = Memoria.aplicar(
            .actualizar(id: idDos, texto: "No debe entrar"),
            en: &entradas
        )

        guard case .rechazada(let motivo) = resultado else {
            return XCTFail("Se esperaba un rechazo")
        }
        XCTAssertTrue(motivo.contains(idDos.uuidString))
        XCTAssertEqual(entradas, [original])
    }

    func testLaAccionSeLeeDeLosArgumentosYSeRechazaLoQueFalta() throws {
        let accion = try Memoria.accion(
            desdeArgumentos: #"{"accion":"guardar","texto":"Hola"}"#
        )
        XCTAssertEqual(accion, .guardar(texto: "Hola"))

        XCTAssertThrowsError(
            try Memoria.accion(desdeArgumentos: #"{"accion":"renombrar"}"#)
        )
        XCTAssertThrowsError(
            try Memoria.accion(
                desdeArgumentos: #"{"accion":"actualizar","texto":"sin id"}"#
            )
        )
    }

    // MARK: - Freno sensible con aprobacion (B2.4)

    /// La unica via que crea una entrada con marca sensible es la aprobada.
    func testAplicarSensibleAprobadaEscribeExactamenteUnaEntradaConSuCategoria() {
        var entradas = [EntradaMemoria(id: idUno, texto: "Vive en Madrid")]

        let resultado = Memoria.aplicarSensibleAprobada(
            contenido: "mi presion arterial de prueba es 120 sobre 80",
            categoria: .health,
            en: &entradas,
            fecha: Date(timeIntervalSince1970: 300),
            id: idDos
        )

        guard case .aplicada(let cambio) = resultado else {
            return XCTFail("Se esperaba una entrada escrita")
        }
        XCTAssertEqual(entradas.count, 2)
        XCTAssertEqual(entradas[1].id, idDos)
        XCTAssertEqual(
            entradas[1].texto,
            "mi presion arterial de prueba es 120 sobre 80"
        )
        XCTAssertEqual(entradas[1].categoriaSensible, .health)
        XCTAssertEqual(entradas[1].categoria, .durableFact)
        XCTAssertEqual(cambio.textoDeLinea, "Guardado en memoria: mi presion arterial de prueba es 120 sobre 80")
    }

    /// `aplicarTipada` sigue siendo la segunda barrera: la propuesta nunca
    /// escribe por ahi.
    func testAplicarTipadaSigueRechazandoLaPropuestaSensible() {
        var entradas = [EntradaMemoria(id: idUno, texto: "Vive en Madrid")]

        let resultado = Memoria.aplicarTipada(
            .proponerSensible(
                contenido: "mi presion arterial de prueba es 120 sobre 80",
                categoria: .health,
                confianza: nil
            ),
            en: &entradas
        )

        guard case .rechazada = resultado else {
            return XCTFail("La propuesta sensible no puede aplicarse sin hoja")
        }
        XCTAssertEqual(entradas.count, 1)
    }

    /// Una entrada aprobada como sensible no se reescribe por `update_memory`.
    func testAplicarTipadaRechazaActualizarUnaEntradaSensible() {
        let sensible = EntradaMemoria(
            id: idUno,
            texto: "mi presion arterial de prueba es 120 sobre 80",
            categoria: .durableFact,
            categoriaSensible: .health
        )
        var entradas = [sensible]

        let resultado = Memoria.aplicarTipada(
            .actualizar(
                id: idUno,
                contenido: "mi presion ahora es 130 sobre 90",
                categoria: .correction,
                confianza: nil
            ),
            en: &entradas
        )

        guard case .rechazada(let motivo) = resultado else {
            return XCTFail("Una entrada sensible no se actualiza sin aprobacion")
        }
        XCTAssertTrue(motivo.contains("sensible"), motivo)
        XCTAssertEqual(entradas, [sensible])
    }

    /// El esquema tipado de Tarea conserva su regimen y su semantica.
    func testOperacionTipadaMapeaLaAccionDeTareaSinAblandarNada() {
        let preferencia = EntradaMemoria(
            id: idUno,
            texto: "Prefiere respuestas breves",
            categoria: .preference
        )
        let entradas = [preferencia]

        XCTAssertEqual(
            Memoria.operacionTipada(.guardar(texto: "Hola"), en: entradas),
            .guardar(
                contenido: "Hola",
                categoria: .durableFact,
                confianza: nil
            )
        )
        XCTAssertEqual(
            Memoria.operacionTipada(
                .actualizar(id: idUno, texto: "Prefiere informes breves"),
                en: entradas
            ),
            .actualizar(
                id: idUno,
                contenido: "Prefiere informes breves",
                categoria: .preference,
                confianza: nil
            ),
            "Actualizar conserva la categoria base de la entrada"
        )
        XCTAssertEqual(
            Memoria.operacionTipada(.borrar(id: idUno), en: entradas),
            .borrar(id: idUno)
        )
    }

    /// La marca sensible sobrevive al JSON y una entrada vieja se lee sin ella.
    func testLaMarcaSensibleSobreviveAlJSONYEsToleranteConLoViejo() throws {
        let sensible = EntradaMemoria(
            id: idUno,
            texto: "mi presupuesto de prueba es 500",
            fecha: Date(timeIntervalSince1970: 100),
            categoria: .durableFact,
            categoriaSensible: .finances
        )

        let datos = try JSONEncoder().encode(sensible)
        let vuelta = try JSONDecoder().decode(EntradaMemoria.self, from: datos)
        XCTAssertEqual(vuelta, sensible)

        let legado: [String: Any] = [
            "id": idDos.uuidString,
            "texto": "Vive en Madrid",
            "fecha": 100
        ]
        let datosLegado = try JSONSerialization.data(withJSONObject: legado)
        let sinMarca = try JSONDecoder().decode(
            EntradaMemoria.self,
            from: datosLegado
        )
        XCTAssertNil(sinMarca.categoriaSensible)
        XCTAssertEqual(sinMarca.categoria, .durableFact)
    }

    /// La hoja y Mi Contexto pintan lenguaje llano, nunca el `rawValue`.
    func testLasCategoriasSensiblesTienenRotuloLlano() {
        XCTAssertEqual(
            CategoriaSensibleMemoria.allCases.map(\.etiquetaVisible),
            ["Salud", "Finanzas", "Documentos e identificadores", "Íntimo"]
        )
    }

    /// El bloque inyectado declara la marca sensible de una entrada aprobada.
    func testElBloqueDeclaraLaMarcaSensibleDeUnaEntradaAprobada() {
        let sensible = EntradaMemoria(
            id: idUno,
            texto: "mi presion arterial de prueba es 120 sobre 80",
            categoria: .durableFact,
            categoriaSensible: .health
        )

        let bloque = Memoria.bloqueSistema(entradas: [sensible])

        XCTAssertTrue(
            bloque.contains(
                "· categoria: durable_fact · sensible: health · texto: "
            ),
            bloque
        )
    }
}
