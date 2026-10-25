import Foundation
import XCTest

@testable import NodoCore

/// Pruebas del ejecutor local validador de B2.1.
///
/// Cada caso comprueba las dos caras del contrato: el resultado interno que
/// vuelve al modelo y el registro resultante. Una validacion fallida no puede
/// mutar nada ni devolver un exito.
@MainActor
final class EjecutorMemoriaTests: XCTestCase {
    private let idUno = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let idDos = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    private func semilla() -> [EntradaMemoria] {
        [
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
    }

    /// Registro mutable de una prueba, con su ejecutor ya enganchado.
    ///
    /// Se encapsula en una clase porque el aplicador es un closure escapable y
    /// no puede capturar un `inout`.
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

    // MARK: - Camino valido

    func testGuardarValidoCreaLaTerceraEntrada() async throws {
        let caja = RegistroDePrueba(semilla())
        let ejecutor = caja.ejecutor()

        let resultado = try await ejecutor.ejecutar(
            herramienta: Memoria.nombreGuardar,
            argumentos: #"{"content":"Prefiere cafe sin azucar","category":"preference"}"#
        )

        XCTAssertFalse(resultado.contains("Error"))
        XCTAssertTrue(resultado.contains("Guarde en Memoria"))
        XCTAssertEqual(caja.entradas.count, 3)
        XCTAssertEqual(caja.entradas.last?.texto, "Prefiere cafe sin azucar")
        XCTAssertEqual(caja.entradas.last?.categoria, .preference)
    }

    func testActualizarConElIdDeLaSemillaNoCreceN() async throws {
        let caja = RegistroDePrueba(semilla())
        let ejecutor = caja.ejecutor()

        let resultado = try await ejecutor.ejecutar(
            herramienta: Memoria.nombreActualizar,
            argumentos: #"{"entry_id":"11111111-1111-4111-8111-111111111111","content":"Vive en Barcelona","category":"correction"}"#
        )

        XCTAssertFalse(resultado.contains("Error"))
        XCTAssertEqual(caja.entradas.count, 2)
        XCTAssertEqual(caja.entradas[0].texto, "Vive en Barcelona")
        XCTAssertEqual(caja.entradas[0].categoria, .correction)
        XCTAssertEqual(caja.entradas[1].texto, "Prefiere respuestas breves")
    }

    func testBorrarConElIdDeLaSemillaQuitaExactamenteEsaEntrada() async throws {
        let caja = RegistroDePrueba(semilla())
        let ejecutor = caja.ejecutor()

        let resultado = try await ejecutor.ejecutar(
            herramienta: Memoria.nombreBorrar,
            argumentos: #"{"entry_id":"11111111-1111-4111-8111-111111111111"}"#
        )

        XCTAssertFalse(resultado.contains("Error"))
        XCTAssertEqual(caja.entradas.map(\.id), [idDos])
    }

    // MARK: - Tope 1/turno

    func testLaSegundaLlamadaDelTurnoSeRechazaSinMutar() async throws {
        let caja = RegistroDePrueba(semilla())
        let ejecutor = caja.ejecutor()

        let primera = try await ejecutor.ejecutar(
            herramienta: Memoria.nombreGuardar,
            argumentos: #"{"content":"Primera","category":"durable_fact"}"#
        )
        let segunda = try await ejecutor.ejecutar(
            herramienta: Memoria.nombreGuardar,
            argumentos: #"{"content":"Segunda","category":"durable_fact"}"#
        )

        XCTAssertFalse(primera.contains("Error"))
        XCTAssertTrue(segunda.contains("Error"))
        XCTAssertEqual(caja.entradas.count, 3)
        XCTAssertEqual(caja.entradas.last?.texto, "Primera")
        XCTAssertFalse(caja.entradas.contains { $0.texto == "Segunda" })
    }

    func testLaSegundaLlamadaSeRechazaAunqueLaPrimeraFalle() async throws {
        let caja = RegistroDePrueba(semilla())
        var aplicadas = 0
        let ejecutor = EjecutorMemoriaDelTurno(entradas: caja.entradas) { [caja] operacion in
            aplicadas += 1
            return Memoria.aplicarTipada(operacion, en: &caja.entradas)
        }

        let primera = try await ejecutor.ejecutar(
            herramienta: Memoria.nombreGuardar,
            argumentos: #"{"content":"sin categoria"}"#
        )
        let segunda = try await ejecutor.ejecutar(
            herramienta: Memoria.nombreGuardar,
            argumentos: #"{"content":"Valida","category":"durable_fact"}"#
        )

        XCTAssertTrue(primera.contains("Error"))
        XCTAssertTrue(segunda.contains("Error"))
        XCTAssertEqual(aplicadas, 0)
        XCTAssertEqual(caja.entradas, semilla())
    }

    // MARK: - entry_id contra el snapshot del turno

    func testActualizarConIdInventadoSeRechazaYNoCreaEntrada() async throws {
        let caja = RegistroDePrueba(semilla())
        let ejecutor = caja.ejecutor()

        let resultado = try await ejecutor.ejecutar(
            herramienta: Memoria.nombreActualizar,
            argumentos: #"{"entry_id":"FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF","content":"No debe entrar","category":"correction"}"#
        )

        XCTAssertTrue(resultado.contains("Error"))
        XCTAssertEqual(caja.entradas, semilla())
    }

    func testBorrarConIdInventadoSeRechazaSinBorrarNiCrearNada() async throws {
        let caja = RegistroDePrueba(semilla())
        let ejecutor = caja.ejecutor()

        let resultado = try await ejecutor.ejecutar(
            herramienta: Memoria.nombreBorrar,
            argumentos: #"{"entry_id":"FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF"}"#
        )

        XCTAssertTrue(resultado.contains("Error"))
        XCTAssertEqual(caja.entradas, semilla())
    }

    /// El snapshot manda: un id que existe en el registro pero no en la foto
    /// del turno se rechaza (la lista pudo cambiar a mitad del turno).
    func testUnIdQueNoEstabaEnElSnapshotSeRechazaAunqueExistaEnElRegistro() async throws {
        let caja = RegistroDePrueba(semilla())
        let ejecutor = EjecutorMemoriaDelTurno(entradas: [semilla()[0]]) { [caja] operacion in
            Memoria.aplicarTipada(operacion, en: &caja.entradas)
        }

        let resultado = try await ejecutor.ejecutar(
            herramienta: Memoria.nombreBorrar,
            argumentos: #"{"entry_id":"22222222-2222-4222-8222-222222222222"}"#
        )

        XCTAssertTrue(resultado.contains("Error"))
        XCTAssertEqual(caja.entradas, semilla())
    }

    // MARK: - Categorias

    func testUnaCategoriaSensiblePorLaViaNoSensibleSeRechaza() async throws {
        let caja = RegistroDePrueba(semilla())
        let ejecutor = caja.ejecutor()

        let resultado = try await ejecutor.ejecutar(
            herramienta: Memoria.nombreGuardar,
            argumentos: #"{"content":"Toma insulina","category":"health"}"#
        )

        XCTAssertTrue(resultado.contains("Error"))
        XCTAssertEqual(caja.entradas, semilla())
    }

    func testUnaConfianzaFueraDeRangoSeRechaza() async throws {
        let caja = RegistroDePrueba(semilla())
        let ejecutor = caja.ejecutor()

        let resultado = try await ejecutor.ejecutar(
            herramienta: Memoria.nombreGuardar,
            argumentos: #"{"content":"Dato","category":"durable_fact","confidence_score":1.2}"#
        )

        XCTAssertTrue(resultado.contains("Error"))
        XCTAssertEqual(caja.entradas, semilla())
    }

    // MARK: - Memoria sensible (B2.4)

    /// B2.4: la propuesta deja de cortarse en el ejecutor y llega al aplicador,
    /// que es quien presenta la hoja. Si el dueno no aprueba (aplicador que
    /// rechaza), no se escribe nada.
    func testLaPropuestaSensibleLlegaAlAplicadorYNoPersisteSinAprobacion() async throws {
        let caja = RegistroDePrueba(semilla())
        var aplicadas: [OperacionMemoriaTipada] = []
        let ejecutor = EjecutorMemoriaDelTurno(entradas: caja.entradas) { [caja] operacion in
            aplicadas.append(operacion)
            return .rechazada("denegado por el dueno")
        }

        let resultado = try await ejecutor.ejecutar(
            herramienta: Memoria.nombreProponerSensible,
            argumentos: #"{"content":"Toma insulina","sensitive_category":"health"}"#
        )

        XCTAssertEqual(
            aplicadas,
            [
                .proponerSensible(
                    contenido: "Toma insulina",
                    categoria: .health,
                    confianza: nil
                )
            ],
            "La propuesta llega UNA vez al aplicador, con su categoria tipada"
        )
        XCTAssertEqual(
            resultado,
            Memoria.rechazoDenegado,
            "El rechazo del dueno viaja como decision, no como error tecnico"
        )
        XCTAssertEqual(caja.entradas, semilla())
    }

    /// Con [Aprobar], el aplicador escribe exactamente 1 entrada con la marca
    /// sensible declarada; la propuesta en si no muta el registro.
    func testLaPropuestaAprobadaEscribeUnaEntradaConSuCategoriaSensible() async throws {
        let caja = RegistroDePrueba(semilla())
        var invocaciones = 0
        let ejecutor = EjecutorMemoriaDelTurno(entradas: caja.entradas) { [caja] operacion in
            invocaciones += 1
            switch operacion {
            case .proponerSensible(let contenido, let categoria, _):
                // El registro NO cambia al invocar: solo el [Aprobar] escribe.
                XCTAssertEqual(caja.entradas, self.semilla())
                return Memoria.aplicarSensibleAprobada(
                    contenido: contenido,
                    categoria: categoria,
                    en: &caja.entradas
                )
            default:
                return Memoria.aplicarTipada(operacion, en: &caja.entradas)
            }
        }

        let resultado = try await ejecutor.ejecutar(
            herramienta: Memoria.nombreProponerSensible,
            argumentos: #"{"content":"mi presion de prueba es 120 sobre 80","sensitive_category":"health"}"#
        )

        XCTAssertEqual(invocaciones, 1)
        XCTAssertFalse(resultado.contains("Error"))
        XCTAssertEqual(caja.entradas.count, 3)
        XCTAssertEqual(
            caja.entradas.last?.categoriaSensible,
            .health,
            "La entrada aprobada conserva la categoria sensible declarada"
        )
    }

    /// Una propuesta cuenta como la operacion de memoria del turno.
    func testUnaPropuestaConsumeElTopeDeUnaOperacionPorTurno() async throws {
        let caja = RegistroDePrueba(semilla())
        let ejecutor = EjecutorMemoriaDelTurno(entradas: caja.entradas) { [caja] operacion in
            Memoria.aplicarTipada(operacion, en: &caja.entradas)
        }

        _ = try await ejecutor.ejecutar(
            herramienta: Memoria.nombreProponerSensible,
            argumentos: #"{"content":"Toma insulina","sensitive_category":"health"}"#
        )
        let segunda = try await ejecutor.ejecutar(
            herramienta: Memoria.nombreGuardar,
            argumentos: #"{"content":"Otra cosa","category":"durable_fact"}"#
        )

        XCTAssertTrue(segunda.contains("Error"))
        XCTAssertTrue(segunda.contains("maximo 1 por turno"))
        XCTAssertEqual(caja.entradas, semilla())
    }

    /// Una entrada sensible no se reescribe por `update_memory`.
    func testActualizarUnaEntradaSensibleSeRechazaSinMutarla() async throws {
        let sensible = EntradaMemoria(
            id: idUno,
            texto: "mi presion de prueba es 120 sobre 80",
            categoria: .durableFact,
            categoriaSensible: .health
        )
        let caja = RegistroDePrueba([sensible])
        let ejecutor = caja.ejecutor()

        let resultado = try await ejecutor.ejecutar(
            herramienta: Memoria.nombreActualizar,
            argumentos: #"{"entry_id":"11111111-1111-4111-8111-111111111111","content":"mi presion ahora es 130","category":"correction"}"#
        )

        XCTAssertTrue(resultado.contains("Error"))
        XCTAssertTrue(resultado.contains("sensible"))
        XCTAssertEqual(caja.entradas, [sensible])
    }

    func testUnaHerramientaDesconocidaSeRechaza() async throws {
        let caja = RegistroDePrueba(semilla())
        let ejecutor = caja.ejecutor()

        let resultado = try await ejecutor.ejecutar(
            herramienta: "memoria_chat",
            argumentos: #"{"accion":"guardar","texto":"Hola"}"#
        )

        XCTAssertTrue(resultado.contains("Error"))
        XCTAssertEqual(caja.entradas, semilla())
    }
}
