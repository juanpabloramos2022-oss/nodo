import Foundation
import XCTest

@testable import NodoCore

/// Pruebas de la cláusula de crecimiento (B2.5), nivel unitario de estado.
///
/// Cubren las tres caras del tope: la inyección nunca pasa de 50, la creación
/// se rechaza sin mutar con el tope lleno (incluida el alta sensible aprobada y
/// la vía de Tarea) y actualizar/borrar siguen permitidos. También el contador
/// y la banda de Mi Contexto, que se calculan aquí y no en la vista.
@MainActor
final class TopeMemoriaTests: XCTestCase {

    // MARK: - Semillas

    private func id(_ numero: Int) -> UUID {
        UUID(
            uuidString: String(
                format: "%08X-0000-4000-8000-%012X",
                numero,
                numero
            )
        )!
    }

    private func semilla(_ cantidad: Int) -> [EntradaMemoria] {
        let categorias = CategoriaMemoria.paraActualizar
        return (1...cantidad).map { numero in
            EntradaMemoria(
                id: id(numero),
                texto: String(format: "prueba-%02d", numero),
                fecha: Date(timeIntervalSince1970: TimeInterval(numero)),
                categoria: categorias[numero % categorias.count]
            )
        }
    }

    /// Registro mutable de una prueba, con su ejecutor ya enganchado.
    @MainActor
    private final class RegistroDePrueba {
        var entradas: [EntradaMemoria]

        init(_ entradas: [EntradaMemoria]) {
            self.entradas = entradas
        }

        func ejecutor() -> EjecutorMemoriaDelTurno {
            EjecutorMemoriaDelTurno(entradas: entradas) { [self] operacion in
                Memoria.aplicarTipada(operacion, en: &entradas)
            }
        }
    }

    // MARK: - Inyección

    func testConCincuentaEntradasElBloqueInyectaExactamenteCincuenta() {
        let bloque = Memoria.bloqueSistema(entradas: semilla(50))

        XCTAssertEqual(
            bloque.components(separatedBy: "\n- id: ").count - 1,
            50,
            "El bloque tiene que listar exactamente 50 entradas"
        )
        XCTAssertTrue(bloque.contains("prueba-01"))
        XCTAssertTrue(bloque.contains("prueba-50"))
    }

    func testConMasDeCincuentaInyectaLasPrimerasCincuentaSinReordenar() {
        var entradas = semilla(60)
        let copia = entradas

        let bloque = Memoria.bloqueSistema(entradas: entradas)

        XCTAssertEqual(
            bloque.components(separatedBy: "\n- id: ").count - 1,
            50,
            "Nunca se inyectan más de 50, aunque haya 60 almacenadas"
        )
        XCTAssertTrue(bloque.contains("prueba-01"))
        XCTAssertTrue(bloque.contains("prueba-50"))
        XCTAssertFalse(bloque.contains("prueba-51"))
        XCTAssertFalse(bloque.contains("prueba-60"))
        XCTAssertEqual(
            entradas,
            copia,
            "Inyectar no puede reordenar ni tocar el almacenamiento"
        )
    }

    // MARK: - Creación rechazada, corrección permitida

    func testGuardarEnTopeSeRechazaSinMutacion() async throws {
        let caja = RegistroDePrueba(semilla(50))
        let ejecutor = caja.ejecutor()

        let resultado = try await ejecutor.ejecutar(
            herramienta: Memoria.nombreGuardar,
            argumentos: #"{"content":"dato nuevo","category":"durable_fact"}"#
        )

        XCTAssertTrue(resultado.contains("memoria en tope"), resultado)
        XCTAssertEqual(caja.entradas.count, 50)
        XCTAssertFalse(caja.entradas.contains { $0.texto == "dato nuevo" })
    }

    func testActualizarEnTopeSigueEjecutandoseSinCrecer() async throws {
        let caja = RegistroDePrueba(semilla(50))
        let ejecutor = caja.ejecutor()
        let objetivo = id(1)

        let resultado = try await ejecutor.ejecutar(
            herramienta: Memoria.nombreActualizar,
            argumentos: #"{"entry_id":"\#(objetivo.uuidString)","content":"prueba-01 corregida","category":"correction"}"#
        )

        XCTAssertFalse(resultado.contains("Error"), resultado)
        XCTAssertEqual(caja.entradas.count, 50, "Corregir no hace crecer N")
        XCTAssertEqual(
            caja.entradas.first { $0.id == objetivo }?.texto,
            "prueba-01 corregida"
        )
    }

    func testBorrarEnTopeBajaAYRehabilitaLaCreacion() async throws {
        let caja = RegistroDePrueba(semilla(50))
        let ejecutorBorrado = caja.ejecutor()

        let borrado = try await ejecutorBorrado.ejecutar(
            herramienta: Memoria.nombreBorrar,
            argumentos: #"{"entry_id":"\#(id(1).uuidString)"}"#
        )

        XCTAssertFalse(borrado.contains("Error"), borrado)
        XCTAssertEqual(caja.entradas.count, 49)

        // Turno nuevo: el ejecutor se crea con la lista de 49.
        let ejecutorCreacion = caja.ejecutor()
        let creado = try await ejecutorCreacion.ejecutar(
            herramienta: Memoria.nombreGuardar,
            argumentos: #"{"content":"dato nuevo","category":"durable_fact"}"#
        )

        XCTAssertFalse(creado.contains("Error"), creado)
        XCTAssertEqual(caja.entradas.count, 50)
        XCTAssertEqual(caja.entradas.last?.texto, "dato nuevo")
    }

    // MARK: - Vía de Tarea y alta sensible aprobada

    func testLaViaDeTareaTambienChocaConElTope() {
        var entradas = semilla(50)
        let copia = entradas

        let operacion = Memoria.operacionTipada(
            .guardar(texto: "alta aprobada en Tarea"),
            en: entradas
        )
        let resultado = Memoria.aplicarTipada(operacion, en: &entradas)

        XCTAssertEqual(resultado, .rechazada(Memoria.rechazoEnTope))
        XCTAssertEqual(entradas, copia, "La acción aprobada en Tarea no crea nada")
    }

    func testElAltaSensibleAprobadaTambienChocaConElTope() {
        var entradas = semilla(50)
        let copia = entradas

        let resultado = Memoria.aplicarSensibleAprobada(
            contenido: "dato sensible de prueba",
            categoria: .health,
            en: &entradas
        )

        XCTAssertEqual(resultado, .rechazada(Memoria.rechazoEnTope))
        XCTAssertEqual(entradas, copia, "[Aprobar] no puede saltarse el tope")
    }

    // MARK: - Contador y banda de Mi Contexto

    func testConTreintaYNueveElContadorEsVisibleYSinBanda() {
        let estado = EstadoMemoriaMiContexto(entradas: semilla(39))

        XCTAssertEqual(estado.contador, "Memoria en 39 de 50 entradas")
        XCTAssertFalse(estado.muestraBanda, "La banda solo aparece desde 40")
        XCTAssertFalse(estado.enTope)
    }

    func testConCuarentaElContadorSigueVisibleYApareceLaBanda() {
        let estado = EstadoMemoriaMiContexto(entradas: semilla(40))

        XCTAssertEqual(estado.contador, "Memoria en 40 de 50 entradas")
        XCTAssertTrue(estado.muestraBanda)
        XCTAssertFalse(estado.enTope)
    }

    func testConCincuentaElContadorYLaBandaSiguenYElTopeEstaLleno() {
        let estado = EstadoMemoriaMiContexto(entradas: semilla(50))

        XCTAssertEqual(estado.contador, "Memoria en 50 de 50 entradas")
        XCTAssertTrue(estado.muestraBanda)
        XCTAssertTrue(estado.enTope)
    }

    func testUnRespaldoHeredadoConMasDeCincuentaNoAnunciaMasDeCincuenta() {
        let estado = EstadoMemoriaMiContexto(entradas: semilla(60))

        XCTAssertEqual(estado.contador, "Memoria en 50 de 50 entradas")
        XCTAssertEqual(estado.almacenadas, 60)
        XCTAssertTrue(estado.enTope)
        XCTAssertEqual(
            estado.grupos.reduce(0) { $0 + $1.entradas.count },
            60,
            "La lista completa sigue visible y editable"
        )
    }

    func testLaRevisionAgrupaPorCategoriaSinGruposVacios() {
        let entradas = [
            EntradaMemoria(id: id(1), texto: "uno", categoria: .preference),
            EntradaMemoria(id: id(2), texto: "dos", categoria: .durableFact),
            EntradaMemoria(id: id(3), texto: "tres", categoria: .preference),
            EntradaMemoria(id: id(4), texto: "cuatro", categoria: .commitment)
        ]
        let estado = EstadoMemoriaMiContexto(entradas: entradas)

        XCTAssertEqual(
            estado.grupos.map(\.categoria),
            [.durableFact, .preference, .commitment],
            "Orden fijo de categorías y sin el grupo vacío de correction"
        )
        XCTAssertEqual(
            estado.grupos.first { $0.categoria == .preference }?.entradas.map(\.texto),
            ["uno", "tres"],
            "Agrupar no reordena las entradas del grupo"
        )
        XCTAssertEqual(
            estado.grupos.first { $0.categoria == .preference }?.titulo,
            "Preferencias"
        )
    }
}
