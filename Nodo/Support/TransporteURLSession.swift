import Foundation

import NodoCore

/// Transporte real sobre URLSession.
///
/// Vive en la capa de la app y no en NodoCore para que el nucleo se pueda
/// compilar y probar en cualquier sistema: aqui es donde se usan las APIs de red
/// que solo existen en las plataformas de Apple.
struct TransporteURLSession: HTTPStreaming, HTTPUnary {
    var tiempoLimite: TimeInterval = 120

    private func construir(_ peticion: HTTPRequest) -> URLRequest {
        var solicitud = URLRequest(url: peticion.url)
        solicitud.httpMethod = peticion.metodo
        solicitud.httpBody = peticion.cuerpo
        solicitud.timeoutInterval = tiempoLimite
        for (nombre, valor) in peticion.cabeceras {
            solicitud.setValue(valor, forHTTPHeaderField: nombre)
        }
        return solicitud
    }

    func abrirStream(_ peticion: HTTPRequest) async throws -> AsyncThrowingStream<Data, Error> {
        let solicitud = construir(peticion)

        let (bytes, respuesta): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, respuesta) = try await URLSession.shared.bytes(for: solicitud)
        } catch {
            throw ErrorAPI.red(error.localizedDescription)
        }

        guard let http = respuesta as? HTTPURLResponse else {
            throw ErrorAPI.respuestaInvalida("la respuesta no es HTTP")
        }

        if let error = ErrorAPI.desdeEstado(http.statusCode, cuerpo: "") {
            throw error
        }

        return AsyncThrowingStream { continuacion in
            let tarea = Task {
                do {
                    // Se agrupan los bytes en bloques antes de entregarlos: uno a
                    // uno multiplica el coste de cada salto de concurrencia.
                    var bloque = Data()
                    bloque.reserveCapacity(4096)

                    for try await byte in bytes {
                        bloque.append(byte)
                        if bloque.count >= 4096 {
                            continuacion.yield(bloque)
                            bloque = Data()
                            bloque.reserveCapacity(4096)
                        }
                    }

                    if !bloque.isEmpty { continuacion.yield(bloque) }
                    continuacion.finish()
                } catch is CancellationError {
                    continuacion.finish()
                } catch {
                    continuacion.finish(throwing: ErrorAPI.red(error.localizedDescription))
                }
            }

            continuacion.onTermination = { _ in tarea.cancel() }
        }
    }

    func enviar(_ peticion: HTTPRequest) async throws -> HTTPRespuesta {
        let solicitud = construir(peticion)

        let datos: Data
        let respuesta: URLResponse
        do {
            (datos, respuesta) = try await URLSession.shared.data(for: solicitud)
        } catch {
            throw ErrorAPI.red(error.localizedDescription)
        }

        guard let http = respuesta as? HTTPURLResponse else {
            throw ErrorAPI.respuestaInvalida("la respuesta no es HTTP")
        }

        var cabeceras: [String: String] = [:]
        for (nombre, valor) in http.allHeaderFields {
            cabeceras[String(describing: nombre)] = String(describing: valor)
        }

        return HTTPRespuesta(estado: http.statusCode, cabeceras: cabeceras, cuerpo: datos)
    }
}
