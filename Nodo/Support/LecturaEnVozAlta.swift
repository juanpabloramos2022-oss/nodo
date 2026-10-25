import Foundation

import NodoCore

/// Una locucion de la lectura en voz alta (IDEA1).
///
/// El anuncio de un bloque de codigo es una locucion PROPIA: nunca se mezcla
/// con el texto de la respuesta. Asi el texto hablado es exactamente la
/// concatenacion de los segmentos `.texto` y el anuncio queda aparte.
enum LocucionLectura: Equatable {
    case texto(String)
    case anuncioCodigoOmitido
}

/// Constructor puro de la lectura en voz alta (IDEA1).
///
/// No conoce `AVSpeechSynthesizer` ni SwiftUI: recibe los segmentos ya
/// proyectados de una respuesta terminada y devuelve, en orden, lo que se va a
/// decir. Cada bloque `.codigo` produce SOLO el anuncio «bloque de código
/// omitido»; su contenido y las cercas Markdown no llegan nunca al
/// sintetizador.
///
/// POR QUE vive aparte del lector real: esta es la parte que se puede probar
/// sin simulador ni hardware, y la que garantiza la invariante negativa de la
/// spec (0 caracteres de codigo y 0 cercas en el texto hablado).
enum LecturaEnVozAlta {
    /// Texto exacto que se dice en lugar de leer un bloque de codigo.
    static let anuncioCodigoOmitido = "bloque de código omitido"

    /// Locuciones en orden: cada segmento `.texto` y un anuncio por cada
    /// bloque `.codigo`. Los textos vacios no producen locucion.
    static func textoParaLeer(
        segmentos: [SegmentoRespuesta]
    ) -> [LocucionLectura] {
        segmentos.compactMap { segmento in
            switch segmento {
            case .texto(let texto):
                return texto.isEmpty ? nil : .texto(texto)
            case .codigo:
                return .anuncioCodigoOmitido
            }
        }
    }

    /// Texto hablado: EXACTAMENTE la concatenacion de los segmentos `.texto`.
    ///
    /// El anuncio de codigo no forma parte de esta cadena; va aparte, como
    /// locucion propia. Es la invariante que comprueban los tests de estado.
    static func textoHablado(segmentos: [SegmentoRespuesta]) -> String {
        var salida = ""
        for segmento in segmentos {
            if case .texto(let texto) = segmento {
                salida += texto
            }
        }
        return salida
    }
}

/// Estado visible del control de lectura (IDEA1).
///
/// El boton recorre Escuchar → Pausar → Reanudar → Detener y vuelve a
/// Escuchar al terminar o al detenerse.
enum EstadoLectura: Equatable {
    case inactivo
    case leyendo
    case pausado

    /// Rotulo del boton principal en cada estado.
    var rotulo: String {
        switch self {
        case .inactivo: return "Escuchar"
        case .leyendo: return "Pausar"
        case .pausado: return "Reanudar"
        }
    }

    /// True mientras hay una lectura en curso o en pausa: muestra [Detener].
    var estaActivo: Bool {
        self != .inactivo
    }
}

/// Puerto del lector en voz alta (IDEA1).
///
/// En el iPhone real lo implementa `LectorAVSpeech`; en los tests, un doble
/// que registra llamadas y locuciones sin tocar audio. `EstadoApp` habla
/// siempre con este protocolo, de modo que la logica de estados se prueba sin
/// simulador.
@MainActor
protocol LectorEnVozAlta: AnyObject {
    /// Estado actual del lector.
    var estado: EstadoLectura { get }

    /// Detiene cualquier lectura anterior y empieza esta, en orden.
    ///
    /// `alTerminar` se invoca UNA sola vez, y solo al acabar de forma natural
    /// la ultima locucion. `detener()` NO lo invoca: corta el audio, limpia el
    /// estado y descarta el aviso, porque quien detiene ya sabe que la lectura
    /// acabo y no necesita que se le avise.
    func leer(
        _ locuciones: [LocucionLectura],
        alTerminar: @escaping () -> Void
    )

    /// Pausa en la palabra actual (`pauseSpeaking(at: .word)`).
    func pausar()

    /// Reanuda desde la posicion pausada (`continueSpeaking()`).
    func reanudar()

    /// Corta de inmediato (`stopSpeaking(at: .immediate)`).
    func detener()
}
