import XCTest

@testable import NodoCore

private final class ResolvedorDoble: ResolvedorSkills {
    let skills: [SkillResuelta]

    init(_ skills: [SkillResuelta]) {
        self.skills = skills
    }

    func skill(porSlug slug: String) -> SkillResuelta? {
        skills.first { $0.slug == slug }
    }

    func todas() -> [SkillResuelta] {
        skills
    }
}

final class AnalizadorComandosTests: XCTestCase {
    private let resumen = SkillResuelta(
        nombre: "Resumen",
        slug: "resumen",
        instrucciones: "Resume el texto."
    )
    private let otra = SkillResuelta(
        nombre: "Otra",
        slug: "otra",
        instrucciones: "Otra instruccion."
    )

    private var resolvedor: ResolvedorDoble {
        ResolvedorDoble([resumen, otra])
    }

    func testSinBarraInicialEsMensajeNormal() {
        XCTAssertEqual(
            AnalizadorComandos.analizar("hola /resumen", resolvedor: resolvedor),
            .mensajeNormal(texto: "hola /resumen")
        )
    }

    func testCadaComandoIntegradoSoloSeReconoceComoComando() {
        for comando in ComandoIntegrado.allCases {
            XCTAssertEqual(
                AnalizadorComandos.analizar("/\(comando.rawValue)", resolvedor: resolvedor),
                .comando(comando)
            )
        }
    }

    /// D1=A: el primer token manda. Un comando con texto detras se ejecuta y el
    /// resto se marca como descartado para que la app avise en el hilo.
    func testComandoConTextoDetrasSeEjecutaYReportaElResto() {
        XCTAssertEqual(
            AnalizadorComandos.analizar("/compact ahora", resolvedor: resolvedor),
            .comandoConTexto(comando: .compact, descartado: "ahora")
        )
        XCTAssertEqual(
            AnalizadorComandos.analizar(
                "/exportar todo el hilo",
                resolvedor: resolvedor
            ),
            .comandoConTexto(comando: .exportar, descartado: "todo el hilo")
        )
    }

    /// El comando se normaliza igual que su slug: mayusculas y tildes no lo
    /// convierten en un token desconocido.
    func testComandoConMayusculasSeReconoce() {
        XCTAssertEqual(
            AnalizadorComandos.analizar("/COMPACT", resolvedor: resolvedor),
            .comando(.compact)
        )
        XCTAssertEqual(
            AnalizadorComandos.analizar("/Compact ahora", resolvedor: resolvedor),
            .comandoConTexto(comando: .compact, descartado: "ahora")
        )
    }

    /// Un "/" cuyo primer token no es comando ni skill conocida va entero como
    /// mensaje normal: no se traga el texto por el hecho de empezar con "/".
    func testPrimerTokenDesconocidoConBarraVaComoMensajeNormal() {
        XCTAssertEqual(
            AnalizadorComandos.analizar("/inventado hola", resolvedor: resolvedor),
            .mensajeNormal(texto: "/inventado hola")
        )
        XCTAssertEqual(
            AnalizadorComandos.analizar("/", resolvedor: resolvedor),
            .mensajeNormal(texto: "/")
        )
    }

    /// Una barra a mitad del texto nunca dispara un comando.
    func testBarraAMitadDeTextoNoDisparaComando() {
        XCTAssertEqual(
            AnalizadorComandos.analizar("hola /compact", resolvedor: resolvedor),
            .mensajeNormal(texto: "hola /compact")
        )
        XCTAssertEqual(
            AnalizadorComandos.analizar("mira /resumen esto", resolvedor: resolvedor),
            .mensajeNormal(texto: "mira /resumen esto")
        )
    }

    func testUnaSkillConMensajeDevuelveElTextoLimpiado() {
        XCTAssertEqual(
            AnalizadorComandos.analizar("/resumen esto es todo", resolvedor: resolvedor),
            .conSkills(skills: [resumen], mensaje: "esto es todo")
        )
    }

    func testVariasSkillsSeDevuelvenEnOrdenSinDuplicados() {
        XCTAssertEqual(
            AnalizadorComandos.analizar(
                "/resumen /otra /resumen esto es todo",
                resolvedor: resolvedor
            ),
            .conSkills(skills: [resumen, otra], mensaje: "esto es todo")
        )
    }

    func testUnaSkillSinMensajePideEscribirlo() {
        XCTAssertEqual(
            AnalizadorComandos.analizar("/resumen /otra", resolvedor: resolvedor),
            .skillSinMensaje(skill: resumen)
        )
    }

    func testUnTokenDesconocidoMezcladoDevuelveSoloElMalo() {
        XCTAssertEqual(
            AnalizadorComandos.analizar("/resumen /inventada hola", resolvedor: resolvedor),
            .tokensDesconocidos(["inventada"])
        )
    }

    func testLosSlugsReservadosNoSeResuelvenComoSkills() {
        let reservada = SkillResuelta(
            nombre: "Compact",
            slug: "compact",
            instrucciones: "No deberia existir."
        )

        // El token reservado no puede resolverse como skill ni siquiera cuando
        // el registro lo ofrece; aqui va despues de una skill real.
        XCTAssertEqual(
            AnalizadorComandos.analizar(
                "/resumen /compact ahora",
                resolvedor: ResolvedorDoble([resumen, reservada])
            ),
            .tokensDesconocidos(["compact"])
        )
    }

    func testSlugsReservadosIncluyenLosComandosDelSistemaPlanYBoost() {
        XCTAssertEqual(
            AnalizadorComandos.slugsReservados,
            Set(["compact", "costo", "modelos", "nuevo", "exportar", "plan", "boost"])
        )
    }

    /// /plan es una adicion firmada del dueno para TASK.2. Se reconoce por la
    /// misma gramatica que los demas comandos, no por un parser paralelo.
    func testPlanSeReconoceComoComandoIntegrado() {
        XCTAssertEqual(
            AnalizadorComandos.analizar("/plan", resolvedor: resolvedor),
            .comando(.plan)
        )
        // Bajo D1=A /plan con texto tambien dispara su flujo; el resto solo se
        // descarta con aviso, no cambia de comando.
        XCTAssertEqual(
            AnalizadorComandos.analizar("/plan con texto", resolvedor: resolvedor),
            .comandoConTexto(comando: .plan, descartado: "con texto")
        )
    }

    /// /boost (BOOST.1) se registra en la misma gramatica, pero su instruccion
    /// efectiva es el resto del texto: el prefijo es el disparo de la tuberia.
    func testBoostConTextoDevuelveLaInstruccionEfectiva() {
        XCTAssertEqual(
            AnalizadorComandos.instruccionDeBoost("/boost analiza el informe"),
            "analiza el informe"
        )
        XCTAssertEqual(
            AnalizadorComandos.instruccionDeBoost("  /BOOST  con mayúsculas  "),
            "con mayúsculas"
        )
        // Solo el comando: cadena vacia, que el llamador trata como error de
        // instruccion y no como tarea normal.
        XCTAssertEqual(AnalizadorComandos.instruccionDeBoost("/boost"), "")
    }

    func testBoostSoloSeDisparaSiEsElPrimerTokenExacto() {
        XCTAssertNil(AnalizadorComandos.instruccionDeBoost("analiza /boost esto"))
        XCTAssertNil(AnalizadorComandos.instruccionDeBoost("/boosters no es boost"))
        XCTAssertNil(AnalizadorComandos.instruccionDeBoost(""))
    }

    func testNormalizarSlugQuitaTildesEspaciosYCaracteresRaros() {
        XCTAssertEqual(
            AnalizadorComandos.normalizarSlug("Mi Skill de Ventas"),
            "mi-skill-de-ventas"
        )
        XCTAssertEqual(
            AnalizadorComandos.normalizarSlug("  Canción__Ñandú  "),
            "cancion-nandu"
        )
        XCTAssertEqual(
            AnalizadorComandos.normalizarSlug("--Hola!!--"),
            "hola"
        )
        XCTAssertEqual(
            AnalizadorComandos.normalizarSlug("a---b___c"),
            "a-b-c"
        )
        XCTAssertEqual(AnalizadorComandos.normalizarSlug("..."), "")
    }
}
