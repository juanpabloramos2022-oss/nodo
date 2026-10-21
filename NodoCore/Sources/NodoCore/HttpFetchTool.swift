import Foundation

/// Herramienta que trae el contenido de una direccion.
///
/// Es la unica herramienta que la app trae de fabrica, y esta deliberadamente
/// limitada: solo https, tamano maximo acotado y sin seguir redirecciones a
/// otros esquemas. Una herramienta que puede pedir cualquier cosa en nombre del
/// modelo es una puerta abierta si el modelo se equivoca o alguien lo manipula
/// con una pagina.
public final class HttpFetchTool: Herramienta {
    private let transporte: HTTPUnary
    private let maxBytes: Int

    public init(transporte: HTTPUnary, maxBytes: Int = 200_000) {
        self.transporte = transporte
        self.maxBytes = maxBytes
    }

    public var definicion: ToolDefinition {
        ToolDefinition(
            nombre: "traer_url",
            descripcion: """
            Descarga el contenido de una direccion web y lo devuelve como texto. \
            Solo admite https. Util para leer documentacion, articulos o datos \
            publicos que necesites citar.
            """,
            parametros: JSONSchema(
                propiedades: [
                    "url": .init(tipo: "string", descripcion: "Direccion completa, empezando por https://")
                ],
                requeridos: ["url"]
            )
        )
    }

    public func ejecutar(argumentos: String) async throws -> String {
        let valores = try Argumentos.diccionario(argumentos)

        guard let texto = Argumentos.texto(valores, clave: "url"), !texto.isEmpty else {
            throw ErrorHerramienta.argumentosInvalidos("falta la url")
        }

        let limpio = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: limpio), let esquema = url.scheme?.lowercased() else {
            throw ErrorHerramienta.argumentosInvalidos("la url no es valida")
        }

        // Solo https: con http el contenido puede alterarse por el camino y el
        // modelo lo tomaria como cierto.
        guard esquema == "https" else {
            throw ErrorHerramienta.noPermitida("solo se admite https, no \(esquema)")
        }

        let respuesta = try await transporte.enviar(
            HTTPRequest(url: url, metodo: "GET", cabeceras: ["Accept": "text/plain, text/html;q=0.9, */*;q=0.5"])
        )

        guard (200..<300).contains(respuesta.estado) else {
            return "Error HTTP \(respuesta.estado) al pedir \(url.host ?? "la direccion")."
        }

        if respuesta.cuerpo.count > maxBytes {
            let recorte = respuesta.cuerpo.prefix(maxBytes)
            let parcial = String(data: recorte, encoding: .utf8) ?? ""
            return parcial + "\n\n[Contenido recortado: la pagina supera \(maxBytes) bytes.]"
        }

        let contenido = respuesta.texto
        return contenido.isEmpty ? "[La pagina no devolvio texto.]" : contenido
    }
}
