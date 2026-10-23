import Foundation
import XCTest

@testable import Nodo
import NodoCore

/// Arnes de las pruebas unitarias de la capa app.
///
/// POR QUE: `EstadoApp` toca cuatro dependencias del sistema (llavero,
/// UserDefaults, carpeta de conversaciones y red). Para probar la logica real
/// sin tocar el telefono ni salir a internet se inyectan dobles en esas cuatro
/// costuras. El estado NO es un `EstadoPrueba`: es el mismo `EstadoApp` de
/// produccion, con su init normal y su persistencia real, solo que apuntando a
/// recursos temporales.
@MainActor
final class ArnesApp {
    let estado: EstadoApp
    let transporte: TransporteGuionizado
    let llavero: LlaveroFalso
    let defaults: UserDefaults
    let directorioStore: URL
    private let nombreSuite: String

    /// Proveedor activo de la configuracion sembrada.
    var proveedor: ProviderConfig {
        // `AppConfig.inicial()` siempre trae un proveedor activo. Si un test
        // cambia la configuracion a algo sin proveedor, conviene fallar aqui
        // con un mensaje claro en vez de seguir con un valor inventado.
        guard let proveedor = estado.config.proveedorSeleccionado else {
            fatalError("El arnes necesita un proveedor seleccionado")
        }
        return proveedor
    }

    init(config: AppConfig = .inicial()) throws {
        let sufijo = UUID().uuidString
        let nombreSuite = "com.nodo.ios.apptests.\(sufijo)"
        guard let defaults = UserDefaults(suiteName: nombreSuite) else {
            throw ErrorArnes.sinSuiteDePreferencias
        }
        // Una suite nueva puede heredar valores de una corrida anterior si el
        // simulador reutiliza el contenedor: se limpia antes de construir.
        defaults.removePersistentDomain(forName: nombreSuite)
        self.nombreSuite = nombreSuite
        self.defaults = defaults

        let directorio = FileManager.default.temporaryDirectory
            .appendingPathComponent("NodoAppTests-\(sufijo)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directorio,
            withIntermediateDirectories: true
        )
        self.directorioStore = directorio

        let transporte = TransporteGuionizado()
        self.transporte = transporte
        let llavero = LlaveroFalso()
        self.llavero = llavero

        self.estado = EstadoApp(
            llavero: llavero,
            transporte: transporte,
            defaults: defaults,
            directorioStore: directorio
        )
        // El init normal arranca con `.inicial()` cuando la suite esta vacia;
        // se aplica la configuracion pedida por el test por la ruta publica,
        // que tambien la deja persistida en la suite temporal.
        self.estado.config = config
    }

    /// Espera a que el turno lanzado por `enviar` termine.
    ///
    /// No se usa una expectation bloqueante: el turno corre en el MainActor y
    /// bloquearlo con `wait(for:)` impediria que avanzara. Ceder el actor con
    /// `Task.sleep` deja que la tarea del turno progrese.
    func esperarTurno(timeout: TimeInterval = 5) async throws {
        let limite = Date().addingTimeInterval(timeout)
        while estado.enviando, Date() < limite {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(
            estado.enviando,
            "El turno no termino dentro del tiempo del test"
        )
    }

    /// Espera a que la compactacion lanzada por `compactar` termine.
    ///
    /// `compactar` no toca `enviando`, asi que `esperarTurno` no sirve: la
    /// bandera que se apaga al cerrar la tarea de resumen es `compactando`.
    func esperarCompactacion(timeout: TimeInterval = 5) async throws {
        let limite = Date().addingTimeInterval(timeout)
        while estado.compactando, Date() < limite {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(
            estado.compactando,
            "La compactacion no termino dentro del tiempo del test"
        )
    }

    /// Borra la suite y la carpeta temporales al terminar el test.
    func limpiar() {
        defaults.removePersistentDomain(forName: nombreSuite)
        try? FileManager.default.removeItem(at: directorioStore)
    }
}

enum ErrorArnes: Error {
    case sinSuiteDePreferencias
}

/// Respuesta que el transporte falso devolvera al siguiente turno.
struct GuionRespuesta {
    var texto: String
    var uso: UsoTokens?
    /// Llamadas a herramienta que pedira el modelo en este turno (MEM.3).
    var toolCalls: [ToolCall]
}

/// Transporte falso que graba peticiones y sirve respuestas SSE guionizadas.
///
/// Implementa los dos protocolos de red porque `EstadoApp` usa el mismo objeto
/// para chat (streaming), herramientas y MCP (peticion completa). Los tests
/// pueden comprobar asi, por ejemplo, que compactar una conversacion corta no
/// llega a pedir nada al modelo.
final class TransporteGuionizado: HTTPStreaming, HTTPUnary {
    private let candado = NSLock()
    private var guiones: [GuionRespuesta] = []
    private var peticiones: [HTTPRequest] = []
    private var respuestasUnarias: [HTTPRespuesta] = []

    /// Encola una respuesta de chat completions con su consumo.
    ///
    /// `toolCalls` permite guionizar un turno que pide herramientas, que es lo
    /// que necesita MEM.3 para probar `memoria_chat` sin red.
    func guionar(
        texto: String,
        uso: UsoTokens? = nil,
        toolCalls: [ToolCall] = []
    ) {
        candado.lock()
        defer { candado.unlock() }
        guiones.append(
            GuionRespuesta(texto: texto, uso: uso, toolCalls: toolCalls)
        )
    }

    /// Encola una respuesta completa para las rutas que no usan streaming.
    func guionarUnaria(_ respuesta: HTTPRespuesta) {
        candado.lock()
        defer { candado.unlock() }
        respuestasUnarias.append(respuesta)
    }

    var peticionesRegistradas: [HTTPRequest] {
        candado.lock()
        defer { candado.unlock() }
        return peticiones
    }

    var cantidadDePeticiones: Int {
        candado.lock()
        defer { candado.unlock() }
        return peticiones.count
    }

    func abrirStream(_ peticion: HTTPRequest) async throws -> AsyncThrowingStream<Data, Error> {
        guard let guion = registrarStream(peticion) else {
            throw ErrorAPI.respuestaInvalida(
                "El transporte de prueba recibio una peticion sin guion."
            )
        }

        let datos = Self.cuerpoSSE(guion)
        return AsyncThrowingStream { continuacion in
            continuacion.yield(datos)
            continuacion.finish()
        }
    }

    func enviar(_ peticion: HTTPRequest) async throws -> HTTPRespuesta {
        registrarUnaria(peticion)
    }

    /// Saca el guion de la siguiente peticion de streaming.
    ///
    /// El candado se toma en un metodo sincrono a proposito: `NSLock.lock()`
    /// no esta permitido dentro de un contexto async, y la red del cliente si
    /// llega desde una tarea.
    private func registrarStream(_ peticion: HTTPRequest) -> GuionRespuesta? {
        candado.lock()
        defer { candado.unlock() }
        peticiones.append(peticion)
        return guiones.isEmpty ? nil : guiones.removeFirst()
    }

    /// Graba una peticion completa y devuelve la respuesta encolada.
    private func registrarUnaria(_ peticion: HTTPRequest) -> HTTPRespuesta {
        candado.lock()
        defer { candado.unlock() }
        peticiones.append(peticion)
        return respuestasUnarias.isEmpty
            ? HTTPRespuesta(estado: 200, cuerpo: Data("{}".utf8))
            : respuestasUnarias.removeFirst()
    }

    /// Construye el SSE con el mismo dialecto que lee `ChatCompletionsClient`:
    /// trozos de `delta.content`, llamadas de `delta.tool_calls`, un bloque
    /// final de `usage` y `[DONE]`.
    private static func cuerpoSSE(_ guion: GuionRespuesta) -> Data {
        var lineas: [String] = []

        let mitad = guion.texto.count / 2
        let partes = [
            String(guion.texto.prefix(mitad)),
            String(guion.texto.dropFirst(mitad))
        ]
        for parte in partes where !parte.isEmpty {
            let objeto: [String: Any] = [
                "choices": [
                    ["delta": ["content": parte]]
                ]
            ]
            lineas.append(evento(objeto))
        }

        // Una sola pieza por llamada: el cliente acumula nombre y argumentos
        // por indice, asi que este formato minimo ya ejercita el camino real.
        for (indice, llamada) in guion.toolCalls.enumerated() {
            let funcion: [String: Any] = [
                "name": llamada.nombre,
                "arguments": llamada.argumentos
            ]
            let llamadaJSON: [String: Any] = [
                "index": indice,
                "id": llamada.id,
                "type": "function",
                "function": funcion
            ]
            let delta: [String: Any] = ["tool_calls": [llamadaJSON]]
            let objeto: [String: Any] = [
                "choices": [["delta": delta]]
            ]
            lineas.append(evento(objeto))
        }

        if let uso = guion.uso {
            let objeto: [String: Any] = [
                "choices": [[String: Any]](),
                "usage": [
                    "prompt_tokens": uso.entrada,
                    "completion_tokens": uso.salida
                ]
            ]
            lineas.append(evento(objeto))
        }

        lineas.append("data: [DONE]\n\n")
        return Data(lineas.joined().utf8)
    }

    private static func evento(_ objeto: [String: Any]) -> String {
        let datos = (try? JSONSerialization.data(withJSONObject: objeto))
            ?? Data("{}".utf8)
        return "data: " + String(decoding: datos, as: UTF8.self) + "\n\n"
    }
}

/// Llavero falso en memoria.
///
/// No toca Security: en el simulador de CI no hay credenciales reales y una
/// prueba nunca debe escribir en el llavero del dispositivo.
final class LlaveroFalso: AlmacenClaves {
    private var valores: [String: String] = [:]

    func guardar(_ valor: String, para clave: String) throws {
        valores[clave] = valor
    }

    func leer(_ clave: String) -> String? {
        valores[clave]
    }

    func borrar(_ clave: String) throws {
        valores.removeValue(forKey: clave)
    }

    var cantidad: Int { valores.count }
}
