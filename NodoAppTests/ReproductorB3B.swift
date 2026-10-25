import Foundation

@testable import Nodo
import NodoCore

/// Reproductor temporizado de una corrida viva del humo B3-B (P0.3).
///
/// POR QUE: la Puerta B de la Partida B no se prueba sobre una reproduccion
/// instantanea del JSON archivado. Este tipo lee los `t` de reloj de pared que
/// el controlador vivo (`humos/humo_b3b.py`) sello en cada evento del stream y
/// los convierte en ESPERAS REALES entre las respuestas del transporte. El
/// motor (ToolLoop), el ViewModel del hilo y la traza son los de produccion:
/// aqui no se fabrica ninguna linea de traza.
struct RegistroB3B {
    /// Una pierna del turno: la respuesta del modelo a una peticion.
    struct Pierna {
        var http: Int
        /// Instante (s) del primer evento del stream, desde el toque.
        var primerEvento: TimeInterval
        /// Instante (s) del ultimo evento del stream.
        var ultimoEvento: TimeInterval
        var texto: String
        var llamadas: [ToolCall]
        var uso: UsoTokens?
        /// Resultado de herramienta que el controlador aporto en la pierna
        /// siguiente (el contenido real que devolvio traer_url).
        var resultadosDeHerramienta: [String: String]
    }

    var modo: String
    var piernas: [Pierna]
    /// Plan aprobado que viaja en el mensaje de ejecucion archivado.
    var plan: [String]

    static func cargar(_ ruta: URL) throws -> RegistroB3B {
        let datos = try Data(contentsOf: ruta)
        let raiz = try JSONSerialization.jsonObject(with: datos)
        guard let diccionario = raiz as? [String: Any] else {
            throw ErrorRegistroB3B.formato
        }
        return try desde(diccionario)
    }

    static func desde(_ diccionario: [String: Any]) throws -> RegistroB3B {
        guard let crudas = diccionario["piernas"] as? [[String: Any]],
              !crudas.isEmpty
        else { throw ErrorRegistroB3B.formato }

        var piernas: [Pierna] = []
        for cruda in crudas {
            let eventos = cruda["eventos"] as? [[String: Any]] ?? []
            let tiempos = eventos.compactMap { $0["t"] as? Double }
            let mensaje = cruda["mensaje"] as? [String: Any] ?? [:]
            var llamadas: [ToolCall] = []
            for llamada in mensaje["tool_calls"] as? [[String: Any]] ?? [] {
                let id = llamada["id"] as? String ?? ""
                let funcion = llamada["function"] as? [String: Any] ?? [:]
                let nombre = funcion["name"] as? String ?? ""
                guard !nombre.isEmpty else { continue }
                llamadas.append(
                    ToolCall(
                        id: id,
                        nombre: nombre,
                        argumentos: funcion["arguments"] as? String ?? "{}"
                    )
                )
            }

            var uso: UsoTokens?
            if let crudo = cruda["usage"] as? [String: Any],
               let entrada = crudo["prompt_tokens"] as? Int,
               let salida = crudo["completion_tokens"] as? Int {
                uso = UsoTokens(entrada: entrada, salida: salida)
            }

            piernas.append(
                Pierna(
                    http: cruda["http"] as? Int ?? 0,
                    primerEvento: tiempos.first ?? 0,
                    ultimoEvento: tiempos.last ?? 0,
                    texto: mensaje["content"] as? String ?? "",
                    llamadas: llamadas,
                    uso: uso,
                    resultadosDeHerramienta:
                        ResultadosArchivados.de(pierna: cruda)
                )
            )
        }

        return RegistroB3B(
            modo: diccionario["modo"] as? String ?? "vivo",
            piernas: piernas,
            plan: ResultadosArchivados.plan(de: diccionario)
        )
    }

    /// Espera REAL que precede al stream numero `orden` (1-based).
    ///
    /// El stream 1 del arnes es el plan, y no lleva espera: el humo de A ya lo
    /// midio. Cada pierna de ejecucion espera la distancia de reloj de pared
    /// que el archivador midio desde el fin de la pierna anterior.
    func retraso(dePierna indice: Int) -> TimeInterval {
        guard indice >= 1, indice < piernas.count else {
            guard indice == 0, let primera = piernas.first else { return 0 }
            return max(0, primera.primerEvento)
        }
        let anterior = piernas[indice - 1]
        let distancia = piernas[indice].primerEvento - anterior.ultimoEvento
        return max(0, distancia)
    }

    /// Espera desde el toque hasta la primera pierna (incluye la primera
    /// respuesta del modelo, que es la espera de red mas larga del turno).
    var esperaInicial: TimeInterval {
        max(0, piernas.first?.primerEvento ?? 0)
    }
}

enum ErrorRegistroB3B: Error {
    case formato
}

/// Extraccion de los datos que el archivador deja en el cuerpo de las
/// peticiones (plan aprobado y resultados de herramienta reales).
private enum ResultadosArchivados {
    static func plan(de diccionario: [String: Any]) -> [String] {
        guard let piernas = diccionario["piernas"] as? [[String: Any]],
              let primera = piernas.first,
              let peticion = primera["peticion"] as? [String: Any],
              let mensajes = peticion["messages"] as? [[String: Any]]
        else { return [] }
        let usuario = mensajes.first { ($0["role"] as? String) == "user" }
        let texto = usuario?["content"] as? String ?? ""
        var pasos: [String] = []
        var dentroDelPlan = false
        for linea in texto.components(separatedBy: .newlines) {
            let recortada = linea.trimmingCharacters(in: .whitespaces)
            if recortada.lowercased().hasPrefix("plan aprobado") {
                dentroDelPlan = true
                continue
            }
            guard dentroDelPlan, !recortada.isEmpty else { continue }
            guard let punto = recortada.firstIndex(of: ".") else { continue }
            let numero = recortada[..<punto]
            guard Int(numero) != nil else { continue }
            let contenido = recortada[
                recortada.index(after: punto)...
            ].trimmingCharacters(in: .whitespaces)
            if !contenido.isEmpty { pasos.append(contenido) }
        }
        return pasos
    }

    static func de(pierna cruda: [String: Any]) -> [String: String] {
        guard let peticion = cruda["peticion"] as? [String: Any],
              let mensajes = peticion["messages"] as? [[String: Any]]
        else { return [:] }
        var salida: [String: String] = [:]
        for mensaje in mensajes where (mensaje["role"] as? String) == "tool" {
            guard let id = mensaje["tool_call_id"] as? String,
                  let contenido = mensaje["content"] as? String
            else { continue }
            salida[id] = contenido
        }
        return salida
    }
}
