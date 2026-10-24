import Foundation
import XCTest

@testable import Nodo
import NodoCore

/// Pruebas de la ida y vuelta del respaldo TOTAL (BACK.1/BACK.2/BACK.3).
///
/// POR QUE en NodoAppTests: la exportacion y la importacion reales viven en
/// `EstadoApp` y tocan sus dos almacenes (conversaciones y tareas), la
/// configuracion persistida y la tabla de ventanas. Aqui se usa el `EstadoApp`
/// de produccion con el arnes de recursos temporales, sin simulador grafico.
@MainActor
final class RespaldoTotalTests: XCTestCase {

    /// Vacía los archivos JSON de un directorio sin borrar el directorio ni sus
    /// subcarpetas: los almacenes ya construidos siguen apuntando a la misma
    /// ruta y el directorio de tareas (subcarpeta del de conversaciones) no se
    /// lleva por delante.
    private func vaciar(_ url: URL) throws {
        let items = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        )
        for item in items where item.pathExtension == "json" {
            try FileManager.default.removeItem(at: item)
        }
    }

    /// Una skill de fabrica real, como la sembraria el PACK.
    private static func skillDeFabrica() throws -> SkillLocal {
        let definicion = try XCTUnwrap(PackSkillsFabrica.skills.first)
        return SkillLocal(
            nombre: definicion.nombre,
            slug: definicion.slug,
            descripcion: definicion.descripcion,
            instrucciones: definicion.instrucciones,
            origen: .fabrica
        )
    }

    // MARK: - BACK.3: ida y vuelta completa

    func testIdaYVueltaTotalEsIdenticaEnConteosYMuestra() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let proveedor = arnes.proveedor
        let conversacion = Conversation(
            id: UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!,
            titulo: "Chat de juguete",
            mensajes: [
                ChatMessage(rol: .usuario, texto: "Pregunta de juguete"),
                ChatMessage(
                    rol: .asistente,
                    texto: "Respuesta de juguete",
                    fecha: Date(timeIntervalSince1970: 50),
                    tokensEntrada: 10,
                    tokensSalida: 20,
                    proveedorID: proveedor.id,
                    costoSelladoUSD: 0.02,
                    costoEsEstimacion: false
                )
            ],
            creada: Date(timeIntervalSince1970: 10),
            actualizada: Date(timeIntervalSince1970: 50),
            resumenCompactado: "Resumen compactado de juguete",
            usoTrasCompactar: UsoTokens(entrada: 3, salida: 4),
            proveedorID: proveedor.id
        )
        let tarea = Tarea(
            id: UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!,
            instruccion: "Tarea de juguete",
            estado: .completada,
            pasos: [
                Paso(descripcion: "Paso uno", estado: .terminado, herramienta: "traer_url"),
                Paso(descripcion: "Paso dos", estado: .terminado)
            ],
            fechaCreacion: Date(timeIntervalSince1970: 20),
            fechaActualizacion: Date(timeIntervalSince1970: 60)
        )

        var usoApp = UsoApp()
        usoApp.registrar(
            uso: UsoTokens(entrada: 10, salida: 20),
            usd: 0.02,
            fecha: Date(timeIntervalSince1970: 50),
            modelo: proveedor.modelo
        )
        let config = AppConfig(
            proveedores: [proveedor],
            proveedorActivo: proveedor.id,
            memoria: [
                EntradaMemoria(
                    id: UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")!,
                    texto: "Memoria de juguete",
                    fecha: Date(timeIntervalSince1970: 30)
                )
            ],
            topeAvisoCosto: 0.5,
            skills: [
                SkillLocal(
                    nombre: "Propia",
                    slug: "propia",
                    instrucciones: "Instrucciones propias"
                ),
                try Self.skillDeFabrica()
            ],
            packSkillsVersion: PACK_VERSION,
            usoApp: usoApp
        )
        arnes.estado.config = config
        arnes.estado.ventanasPorModelo = ["modelo/de-prueba": 128_000]

        // Se siembra el almacen real, como lo haria la app al guardar.
        let store = try ConversationStore(directorio: arnes.directorioStore)
        try store.guardar(conversacion)
        let storeTareas = try TareaStore(directorio: arnes.directorioTareas)
        try storeTareas.guardar(tarea)
        arnes.estado.recargarConversaciones()
        arnes.estado.recargarTareas()

        // Exportar.
        let datos = try XCTUnwrap(arnes.estado.exportarRespaldo())
        let respaldo = try RespaldoConfiguracion.desde(json: datos)
        let manifiesto = try XCTUnwrap(respaldo.manifiesto)
        XCTAssertTrue(manifiesto.cuadraCon(respaldo))

        // Borrar el almacenamiento.
        try vaciar(arnes.directorioStore)
        try vaciar(arnes.directorioTareas)
        arnes.estado.recargarConversaciones()
        arnes.estado.recargarTareas()
        XCTAssertTrue(arnes.estado.conversaciones.isEmpty)
        XCTAssertTrue(arnes.estado.tareas.isEmpty)

        // Importar.
        let restaurado = try arnes.estado.importarRespaldoTotal(respaldo)

        // Conteos identicos.
        XCTAssertEqual(restaurado, manifiesto)
        XCTAssertEqual(arnes.estado.conversaciones.count, 1)
        XCTAssertEqual(arnes.estado.tareas.count, 1)
        XCTAssertEqual(arnes.estado.config.memoria.count, 1)
        XCTAssertEqual(arnes.estado.config.skills.count, 2)
        XCTAssertEqual(arnes.estado.config.proveedores.count, 1)
        XCTAssertEqual(arnes.estado.ventanasPorModelo, ["modelo/de-prueba": 128_000])
        XCTAssertEqual(arnes.estado.config.topeAvisoCosto, 0.5)
        XCTAssertEqual(arnes.estado.config.usoApp, config.usoApp)

        // Muestra de contenido identica: resumen, sello de costo y pasos.
        let chat = try XCTUnwrap(arnes.estado.conversaciones.first)
        XCTAssertEqual(chat.id, conversacion.id)
        XCTAssertEqual(chat.resumenCompactado, "Resumen compactado de juguete")
        XCTAssertEqual(chat.usoTrasCompactar, UsoTokens(entrada: 3, salida: 4))
        XCTAssertEqual(chat.mensajes.last?.costoSelladoUSD, 0.02)
        XCTAssertEqual(chat.mensajes.last?.tokensSalida, 20)
        let tareaRestaurada = try XCTUnwrap(arnes.estado.tareas.first)
        XCTAssertEqual(tareaRestaurada.pasos.count, 2)
        XCTAssertEqual(tareaRestaurada.pasos.first?.descripcion, "Paso uno")
        XCTAssertEqual(tareaRestaurada.estado, .completada)
    }

    // MARK: - BACK.2: reemplazo total sin mezcla

    func testElReemplazoTotalNoMezclaLaConversacionVieja() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let vieja = Conversation(titulo: "Solo en el telefono")
        let store = try ConversationStore(directorio: arnes.directorioStore)
        try store.guardar(vieja)
        arnes.estado.recargarConversaciones()
        XCTAssertEqual(arnes.estado.conversaciones.count, 1)

        let nueva = Conversation(
            id: UUID(uuidString: "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD")!,
            titulo: "Viene en el respaldo",
            mensajes: [ChatMessage(rol: .usuario, texto: "Del respaldo")]
        )
        let respaldo = RespaldoConfiguracion.hacerRespaldo(
            config: arnes.estado.config,
            ventanas: [:],
            conversaciones: [nueva],
            tareas: []
        )

        try arnes.estado.importarRespaldoTotal(respaldo)

        XCTAssertEqual(arnes.estado.conversaciones.count, 1)
        XCTAssertEqual(arnes.estado.conversaciones.first?.id, nueva.id)
        XCTAssertFalse(arnes.estado.conversaciones.contains { $0.id == vieja.id })
        // En disco tambien desaparecio: no se mezclo ningun estado.
        XCTAssertNil(store.cargar(id: vieja.id))
        XCTAssertNotNil(store.cargar(id: nueva.id))
    }

    // MARK: - BACK.2: rechazo sin tocar el estado

    func testUnRespaldoCorruptoSeRechazaSinTocarElEstado() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let conversacion = Conversation(titulo: "No se puede tocar")
        let store = try ConversationStore(directorio: arnes.directorioStore)
        try store.guardar(conversacion)
        arnes.estado.recargarConversaciones()
        let memoriaAntes = arnes.estado.config.memoria
        let totalAntes = arnes.estado.conversaciones.count

        // Texto que ni siquiera es JSON.
        XCTAssertThrowsError(try RespaldoConfiguracion.desde(json: Data("no es json".utf8)))

        // JSON con forma de respaldo pero con el manifiesto manipulado.
        var roto = RespaldoConfiguracion.hacerRespaldo(
            config: arnes.estado.config,
            ventanas: [:]
        )
        roto.manifiesto = ManifiestoRespaldo(
            versionFormato: roto.versionFormato,
            conversaciones: 42
        )
        XCTAssertThrowsError(try arnes.estado.importarRespaldoTotal(roto))

        XCTAssertEqual(arnes.estado.conversaciones.count, totalAntes)
        XCTAssertEqual(arnes.estado.config.memoria, memoriaAntes)
        XCTAssertNotNil(store.cargar(id: conversacion.id))
    }

    // MARK: - BACK.2: la siembra del PACK no duplica slugs

    func testTrasRestaurarSkillsDeFabricaLaSiembraNoDuplicaSlugs() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        var config = AppConfig(
            proveedores: [arnes.proveedor],
            proveedorActivo: arnes.proveedor.id
        )
        // El pack completo, como en un arranque limpio.
        let sembradas = SiembraSkills.sembrarSiFaltaVersion(en: &config)
        XCTAssertEqual(sembradas, 12)
        config.skills.append(
            SkillLocal(nombre: "Propia", slug: "propia", instrucciones: "x")
        )

        let respaldo = RespaldoConfiguracion.hacerRespaldo(
            config: config,
            ventanas: [:],
            conversaciones: [],
            tareas: []
        )
        try arnes.estado.importarRespaldoTotal(respaldo)

        let slugsAntes = arnes.estado.config.skills.map(\.slug)
        XCTAssertEqual(slugsAntes.count, 13)
        XCTAssertEqual(Set(slugsAntes).count, 13)

        // La siembra explicita (idempotente por slug) no crea duplicados ni
        // resucita lo que ya existe con ese slug.
        XCTAssertEqual(arnes.estado.restaurarSkillsDeFabrica(), 0)
        let slugsDespues = arnes.estado.config.skills.map(\.slug)
        XCTAssertEqual(slugsDespues, slugsAntes)
        XCTAssertEqual(Set(slugsDespues).count, 13)
    }

    // MARK: - BACK.1: la exportacion real no lleva claves

    func testElExportadoDeLaAppNoContieneElValorDeLaClave() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let centinela = "sk-app-test-no-debe-salir"
        try arnes.llavero.guardar(centinela, para: arnes.proveedor.claveKeychain)
        try arnes.llavero.guardar(centinela, para: ServerConfig.tokenKeychain)

        let datos = try XCTUnwrap(arnes.estado.exportarRespaldo())
        let texto = String(decoding: datos, as: UTF8.self)

        XCTAssertFalse(texto.contains(centinela))
        XCTAssertFalse(texto.contains(ServerConfig.tokenKeychain))
    }
}