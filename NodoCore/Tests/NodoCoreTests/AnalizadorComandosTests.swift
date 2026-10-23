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

    func testComandoConTextoDetrasNoEsComando() {
        XCTAssertEqual(
            AnalizadorComandos.analizar("/compact ahora", resolvedor: resolvedor),
            .tokensDesconocidos(["compact"])
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

        XCTAssertEqual(
            AnalizadorComandos.analizar(
                "/compact ahora",
                resolvedor: ResolvedorDoble([reservada])
            ),
            .tokensDesconocidos(["compact"])
        )
    }

    func testSlugsReservadosSonLosCincoComandosDelSistema() {
        XCTAssertEqual(
            AnalizadorComandos.slugsReservados,
            Set(["compact", "costo", "modelos", "nuevo", "exportar"])
        )
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
