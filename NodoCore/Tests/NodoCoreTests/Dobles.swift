import Foundation

@testable import NodoCore

/// Transporte falso que devuelve trozos ya preparados.
final class TransporteFalso: HTTPStreaming, HTTPUnary {
    var peticiones: [HTTPRequest] = []
    var trozos: [String] = []
    var respuesta: HTTPRespuesta = HTTPRespuesta(estado: 200)
    var errorAlAbrir: Error?

    init(trozos: [String] = [], respuesta: HTTPRespuesta = HTTPRespuesta(estado: 200)) {
        self.trozos = trozos
        self.respuesta = respuesta
    }

    func abrirStream(_ peticion: HTTPRequest) async throws -> AsyncThrowingStream<Data, Error> {
        peticiones.append(peticion)
        if let errorAlAbrir { throw errorAlAbrir }
        let trozos = self.trozos
        return AsyncThrowingStream { continuacion in
            for trozo in trozos {
                continuacion.yield(Data(trozo.utf8))
            }
            continuacion.finish()
        }
    }

    func enviar(_ peticion: HTTPRequest) async throws -> HTTPRespuesta {
        peticiones.append(peticion)
        return respuesta
    }
}

/// Motor de chat falso: devuelve respuestas en orden y recuerda lo que recibio.
final class MotorFalso: ChatEngine {
    var respuestas: [RespuestaModelo]
    private(set) var llamadas = 0
    private(set) var historiales: [[ChatMessage]] = []
    private(set) var herramientasOfrecidas: [[ToolDefinition]] = []

    init(_ respuestas: [RespuestaModelo]) {
        self.respuestas = respuestas
    }

    func responder(
        mensajes: [ChatMessage],
        herramientas: [ToolDefinition],
        alRecibirTexto: ((String) -> Void)?
    ) async throws -> RespuestaModelo {
        historiales.append(mensajes)
        herramientasOfrecidas.append(herramientas)

        let indice = min(llamadas, respuestas.count - 1)
        llamadas += 1
        let respuesta = respuestas[indice]

        if let alRecibirTexto, !respuesta.texto.isEmpty {
            alRecibirTexto(respuesta.texto)
        }
        return respuesta
    }
}

/// Herramienta falsa configurable.
final class HerramientaFalsa: Herramienta {
    let definicion: ToolDefinition
    var resultado: String
    var error: Error?
    private(set) var argumentosRecibidos: [String] = []

    init(
        nombre: String = "probar",
        resultado: String = "ok",
        error: Error? = nil
    ) {
        self.definicion = ToolDefinition(
            nombre: nombre,
            descripcion: "herramienta de prueba",
            parametros: JSONSchema(
                propiedades: ["x": .init(tipo: "string", descripcion: "un valor")],
                requeridos: ["x"]
            )
        )
        self.resultado = resultado
        self.error = error
    }

    func ejecutar(argumentos: String) async throws -> String {
        argumentosRecibidos.append(argumentos)
        if let error { throw error }
        return resultado
    }
}

enum Ayudas {
    static func proveedor(
        nombre: String = "Prueba",
        base: String = "https://api.ejemplo.test/v1",
        modelo: String = "modelo-x",
        protocolo: ProtocoloProveedor = .chatCompletions
    ) -> ProviderConfig {
        ProviderConfig(nombre: nombre, protocolo: protocolo, baseURL: base, modelo: modelo)
    }

    static func json(_ objeto: [String: Any]) -> String {
        guard let datos = try? JSONSerialization.data(withJSONObject: objeto) else { return "{}" }
        return String(decoding: datos, as: UTF8.self)
    }

    /// Trozo SSE con el delta que se le pase, construido sin escapar JSON a mano.
    static func trozoDelta(_ delta: [String: Any]) -> String {
        "data: " + json(["choices": [["delta": delta]]]) + "\n\n"
    }

    /// Trozo SSE con un delta de contenido.
    static func trozoTexto(_ texto: String) -> String {
        trozoDelta(["content": texto])
    }

    /// Trozo SSE con llamadas a herramienta.
    static func trozoToolCalls(_ llamadas: [[String: Any]]) -> String {
        trozoDelta(["tool_calls": llamadas])
    }

    static func directorioTemporal() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("nodo-pruebas-\(UUID().uuidString)", isDirectory: true)
    }
}
