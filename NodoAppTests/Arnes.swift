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
    /// Almacen propio de tareas, junto al de conversaciones pero sin mezclarse.
    let directorioTareas: URL
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

    init(
        config: AppConfig = .inicial(),
        dictado: SpeechRecognizing? = nil
    ) throws {
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
        self.directorioTareas = TareaStore.directorioEn(directorio)

        let transporte = TransporteGuionizado()
        self.transporte = transporte
        let llavero = LlaveroFalso()
        self.llavero = llavero

        self.estado = EstadoApp(
            llavero: llavero,
            transporte: transporte,
            defaults: defaults,
            directorioStore: directorio,
            directorioTareas: directorioTareas,
            // El dictado inyectado entra de verdad al estado: sin este paso el
            // parametro se ignoraba y los tests de dictado no podian sustituir
            // el reconocedor real (hardware) por el doble.
            dictado: dictado
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

    /// Espera a que se cumpla una condicion del estado sin bloquear el actor.
    func esperar(
        _ condicion: @escaping () -> Bool,
        timeout: TimeInterval = 5,
        mensaje: String = "La condición no se cumplió dentro del tiempo del test"
    ) async throws {
        let limite = Date().addingTimeInterval(timeout)
        while !condicion(), Date() < limite {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condicion(), mensaje)
    }

    /// Espera a que una tarea llegue al estado pedido.
    func esperarTarea(
        id: UUID,
        estado: EstadoTarea,
        timeout: TimeInterval = 5
    ) async throws {
        try await esperar(
            { self.estado.tareas.first(where: { $0.id == id })?.estado == estado },
            timeout: timeout,
            mensaje: "La tarea no llegó a \(estado.titulo)"
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
    /// El archivo de humo no trae la forma `{http, peticion, respuesta}`.
    case archivoDeHumoInvalido
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
    private var streamsContados = 0
    private var unariasContadas = 0
    /// Numero de peticion (1-based) que se queda esperando hasta que el test
    /// la libere. Sirve para mirar el disco a mitad de una tarea.
    private var retenerStreamEn: Int?
    private var retenerUnariaEn: Int?
    /// Retraso real (segundos) que se espera antes de servir el stream N.
    ///
    /// Lo usa el replay temporizado de B3-B: la espera de red archivada se
    /// reproduce con una espera REAL, no con un volcado instantaneo (P0.3).
    private var retrasosDeStream: [Int: TimeInterval] = [:]
    private var continuacionStream: CheckedContinuation<Void, Never>?
    private var continuacionUnaria: CheckedContinuation<Void, Never>?
    private var streamYaLiberado = false
    private var unariaYaLiberada = false

    /// Encola una respuesta de chat completions con su consumo.
    ///
    /// `toolCalls` permite guionizar un turno que pide herramientas, que es lo
    /// que necesitan las pruebas de Memoria para ejecutar sin red.
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

    /// Encola la respuesta viva archivada de una Puerta B.
    ///
    /// El archivo es el registro crudo `{http, peticion, respuesta}` que deja
    /// el humo. No inventa nada: traduce el mensaje archivado (prosa,
    /// `tool_calls` y `usage`) al mismo guion SSE que usa el transporte falso.
    /// Es el doble permitido: reproduce la corrida real, no la sustituye.
    func guionarDesdeArchivo(_ ruta: URL) throws {
        let guion = try Self.leerGuionDesdeArchivo(ruta)
        guionar(texto: guion.texto, uso: guion.uso, toolCalls: guion.toolCalls)
    }

    /// Lee el guion exacto de un archivo de humo, sin encolarlo.
    ///
    /// Lo usan el arnes y los tests que necesitan afirmar sobre el contenido
    /// archivado (por ejemplo, que la traza reproduce esa misma prosa).
    static func leerGuionDesdeArchivo(_ ruta: URL) throws -> GuionRespuesta {
        let datos = try Data(contentsOf: ruta)
        guard
            let raiz = try JSONSerialization.jsonObject(with: datos) as? [String: Any],
            let respuesta = raiz["respuesta"] as? [String: Any],
            let choices = respuesta["choices"] as? [[String: Any]],
            let mensaje = choices.first?["message"] as? [String: Any]
        else {
            throw ErrorArnes.archivoDeHumoInvalido
        }

        let texto = mensaje["content"] as? String ?? ""
        let uso: UsoTokens? = {
            guard let crudo = respuesta["usage"] as? [String: Any],
                  let entrada = crudo["prompt_tokens"] as? Int,
                  let salida = crudo["completion_tokens"] as? Int
            else { return nil }
            return UsoTokens(entrada: entrada, salida: salida)
        }()

        var llamadas: [ToolCall] = []
        if let crudas = mensaje["tool_calls"] as? [[String: Any]] {
            for cruda in crudas {
                guard let id = cruda["id"] as? String,
                      let funcion = cruda["function"] as? [String: Any],
                      let nombre = funcion["name"] as? String
                else { continue }
                llamadas.append(
                    ToolCall(
                        id: id,
                        nombre: nombre,
                        argumentos: funcion["arguments"] as? String ?? "{}"
                    )
                )
            }
        }

        return GuionRespuesta(texto: texto, uso: uso, toolCalls: llamadas)
    }

    /// Guiones que aun no consumio el turno. Si el arnes solo reproduce la
    /// corrida archivada, al cerrar el turno debe ser 0.
    var guionesPendientes: Int {
        candado.lock()
        defer { candado.unlock() }
        return guiones.count
    }

    /// Retiene la respuesta de streaming numero `numero` (1-based).
    /// Fija una espera real antes de servir el stream numero `numero`.
    func retrasarStream(en numero: Int, segundos: TimeInterval) {
        candado.lock()
        defer { candado.unlock() }
        retrasosDeStream[numero] = segundos
    }

    func retenerStream(en numero: Int) {
        candado.lock()
        defer { candado.unlock() }
        retenerStreamEn = numero
        streamYaLiberado = false
    }

    func liberarStreamRetenido() {
        candado.lock()
        let continuacion = continuacionStream
        continuacionStream = nil
        if continuacion == nil { streamYaLiberado = true }
        candado.unlock()
        continuacion?.resume()
    }

    /// Retiene la respuesta unaria numero `numero` (1-based).
    func retenerUnaria(en numero: Int) {
        candado.lock()
        defer { candado.unlock() }
        retenerUnariaEn = numero
        unariaYaLiberada = false
    }

    func liberarUnariaRetenida() {
        candado.lock()
        let continuacion = continuacionUnaria
        continuacionUnaria = nil
        if continuacion == nil { unariaYaLiberada = true }
        candado.unlock()
        continuacion?.resume()
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
        let numero = siguienteNumeroDeStream()
        guard let guion = registrarStream(peticion) else {
            throw ErrorAPI.respuestaInvalida(
                "El transporte de prueba recibio una peticion sin guion."
            )
        }

        if debeRetenerStream(numero) {
            await esperarLiberacionDeStream()
        }

        // Replay temporizado (B3-B): la espera de red archivada se reproduce
        // como espera real antes de entregar el cuerpo.
        if let retraso = retrasoDeStream(numero), retraso > 0 {
            try await Task.sleep(
                nanoseconds: UInt64(retraso * 1_000_000_000)
            )
        }

        let datos = Self.cuerpoSSE(guion)
        return AsyncThrowingStream { continuacion in
            continuacion.yield(datos)
            continuacion.finish()
        }
    }

    func enviar(_ peticion: HTTPRequest) async throws -> HTTPRespuesta {
        let numero = siguienteNumeroUnaria()
        let respuesta = registrarUnaria(peticion)

        if debeRetenerUnaria(numero) {
            await esperarLiberacionDeUnaria()
        }

        return respuesta
    }

    private func siguienteNumeroDeStream() -> Int {
        candado.lock()
        defer { candado.unlock() }
        streamsContados += 1
        return streamsContados
    }

    private func siguienteNumeroUnaria() -> Int {
        candado.lock()
        defer { candado.unlock() }
        unariasContadas += 1
        return unariasContadas
    }

    private func retrasoDeStream(_ numero: Int) -> TimeInterval? {
        candado.lock()
        defer { candado.unlock() }
        return retrasosDeStream[numero]
    }

    private func debeRetenerStream(_ numero: Int) -> Bool {
        candado.lock()
        defer { candado.unlock() }
        guard retenerStreamEn == numero else { return false }
        retenerStreamEn = nil
        return true
    }

    private func debeRetenerUnaria(_ numero: Int) -> Bool {
        candado.lock()
        defer { candado.unlock() }
        guard retenerUnariaEn == numero else { return false }
        retenerUnariaEn = nil
        return true
    }

    private func esperarLiberacionDeStream() async {
        if tomarLiberacionDeStream() { return }

        await withCheckedContinuation { (continuacion: CheckedContinuation<Void, Never>) in
            if instalarContinuacionDeStream(continuacion) {
                continuacion.resume()
            }
        }
    }

    private func esperarLiberacionDeUnaria() async {
        if tomarLiberacionDeUnaria() { return }

        await withCheckedContinuation { (continuacion: CheckedContinuation<Void, Never>) in
            if instalarContinuacionDeUnaria(continuacion) {
                continuacion.resume()
            }
        }
    }

    /// Helpers sincronos: `NSLock.lock()` no se llama desde un contexto async.
    private func tomarLiberacionDeStream() -> Bool {
        candado.lock()
        defer { candado.unlock() }
        guard streamYaLiberado else { return false }
        streamYaLiberado = false
        return true
    }

    private func instalarContinuacionDeStream(
        _ continuacion: CheckedContinuation<Void, Never>
    ) -> Bool {
        candado.lock()
        defer { candado.unlock() }
        guard !streamYaLiberado else {
            streamYaLiberado = false
            return true
        }
        continuacionStream = continuacion
        return false
    }

    private func tomarLiberacionDeUnaria() -> Bool {
        candado.lock()
        defer { candado.unlock() }
        guard unariaYaLiberada else { return false }
        unariaYaLiberada = false
        return true
    }

    private func instalarContinuacionDeUnaria(
        _ continuacion: CheckedContinuation<Void, Never>
    ) -> Bool {
        candado.lock()
        defer { candado.unlock() }
        guard !unariaYaLiberada else {
            unariaYaLiberada = false
            return true
        }
        continuacionUnaria = continuacion
        return false
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

/// Doble de dictado para probar la logica de estado sin microfono (INT.4).
///
/// POR QUE: `EstadoApp.alternarDictado()` no debe tocar hardware en CI. Este
/// doble guarda los callbacks de parcial y fallo para que el test pueda
/// dispararlos a voluntad y comprobar que el estado reacciona: boton que se
/// apaga, texto parcial que se conserva y nada que se envie solo.
final class DictadoGuionizado: SpeechRecognizing {
    /// Si el permiso se concede (true) o se deniega (false).
    var permiso = true
    /// Error que lanza `empezar` para simular un arranque fallido.
    var errorDeArranque: Error?

    private(set) var vecesArrancado = 0
    private(set) var vecesDetenido = 0
    private var onParcial: ((String) -> Void)?
    private var onFallo: ((Error?) -> Void)?

    var disponible: Bool { true }

    func solicitarPermisos() async -> Bool { permiso }

    func empezar(
        onParcial: @escaping (String) -> Void,
        onFallo: @escaping (Error?) -> Void
    ) throws {
        if let errorDeArranque { throw errorDeArranque }
        vecesArrancado += 1
        self.onParcial = onParcial
        self.onFallo = onFallo
    }

    func detener() {
        vecesDetenido += 1
    }

    /// Simula una transcripcion parcial del reconocedor.
    func emitir(_ texto: String) {
        onParcial?(texto)
    }

    /// Simula un fallo del reconocimiento; `nil` representa una cancelacion.
    func fallar(_ error: Error?) {
        onFallo?(error)
    }
}
