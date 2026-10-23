import AVFoundation
import Foundation
import Speech

/// Puerto del dictado (§4.5).
///
/// La app habla siempre con este protocolo: en el iPhone real lo implementa
/// `SFSpeechRecognizer` + `AVAudioEngine`; en las capturas de CI lo implementa
/// un doble que no toca hardware. La Fase 4 no necesita cambiar la vista para
/// sustituir el reconocedor.
protocol SpeechRecognizing {
    /// True si el reconocedor esta disponible en este dispositivo.
    var disponible: Bool { get }

    /// Pide permiso de reconocimiento de voz y de microfono.
    func solicitarPermisos() async -> Bool

    /// Empieza a escuchar y entrega cada transcripcion parcial por el callback.
    func empezar(onParcial: @escaping (String) -> Void) throws

    /// Corta la escucha y libera el microfono.
    func detener()
}

/// Errores legibles del dictado real.
enum ErrorDictado: Error, LocalizedError {
    case noDisponible
    case sinEntradaDeAudio

    var errorDescription: String? {
        switch self {
        case .noDisponible:
            return "El dictado no está disponible en este dispositivo."
        case .sinEntradaDeAudio:
            return "No se pudo abrir el micrófono para dictar."
        }
    }
}

/// Dictado real con el reconocimiento del propio iPhone (locale es-ES).
///
/// No hay servidor ni costo: `SFSpeechRecognizer` transcribe en el telefono y
/// `AVAudioEngine` le pasa el audio del microfono. La transcripcion parcial se
/// entrega continua para que la caja se vaya rellenando mientras se habla.
final class DictadoReconocimiento: SpeechRecognizing {
    private let reconocedor = SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))
    private let motor = AVAudioEngine()
    private var solicitud: SFSpeechAudioBufferRecognitionRequest?
    private var tarea: SFSpeechRecognitionTask?
    private var tapInstalado = false

    var disponible: Bool {
        reconocedor?.isAvailable == true
    }

    func solicitarPermisos() async -> Bool {
        let reconocimiento = await conContinuacion { continuacion in
            SFSpeechRecognizer.requestAuthorization { estado in
                continuacion.resume(returning: estado == .authorized)
            }
        }
        guard reconocimiento else { return false }

        return await conContinuacion { continuacion in
            AVAudioSession.sharedInstance().requestRecordPermission { concedido in
                continuacion.resume(returning: concedido)
            }
        }
    }

    func empezar(onParcial: @escaping (String) -> Void) throws {
        guard disponible else { throw ErrorDictado.noDisponible }

        // Empezar dos veces no puede dejar dos motores escuchando.
        detener()

        let sesion = AVAudioSession.sharedInstance()
        try sesion.setCategory(.record, mode: .measurement, options: [])
        try sesion.setActive(true, options: [])

        let solicitud = SFSpeechAudioBufferRecognitionRequest()
        solicitud.shouldReportPartialResults = true
        solicitud.taskHint = .dictation
        // Cuando el telefono trae el modelo de es-ES, se dicta en el propio
        // dispositivo (sin servidor). Si no, el sistema decide.
        solicitud.requiresOnDeviceRecognition =
            reconocedor?.supportsOnDeviceRecognition == true
        self.solicitud = solicitud

        let entrada = motor.inputNode
        let formato = entrada.outputFormat(forBus: 0)
        guard formato.sampleRate > 0, formato.channelCount > 0 else {
            detener()
            throw ErrorDictado.sinEntradaDeAudio
        }

        entrada.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: formato
        ) { buffer, _ in
            solicitud.append(buffer)
        }
        tapInstalado = true

        motor.prepare()
        do {
            try motor.start()
        } catch {
            detener()
            throw error
        }

        tarea = reconocedor?.recognitionTask(with: solicitud) { [weak self] resultado, error in
            if let resultado {
                onParcial(resultado.bestTranscription.formattedString)
            }
            if error != nil {
                DispatchQueue.main.async {
                    self?.detener()
                }
            }
        }
    }

    func detener() {
        tarea?.cancel()
        tarea = nil
        solicitud?.endAudio()
        solicitud = nil

        if motor.isRunning {
            motor.stop()
        }
        if tapInstalado {
            motor.inputNode.removeTap(onBus: 0)
            tapInstalado = false
        }

        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    /// Envuelve un callback de permisos en `async` sin bloquear la interfaz.
    private func conContinuacion(
        _ cuerpo: (@escaping (Bool) -> Void) -> Void
    ) async -> Bool {
        await withCheckedContinuation { continuacion in
            cuerpo { valor in
                continuacion.resume(returning: valor)
            }
        }
    }
}

/// Doble de dictado para CI y capturas (`-CapturasPrueba`).
///
/// No pide permisos ni toca el microfono: al empezar entrega una vez la
/// transcripcion fija y se queda escuchando hasta que la vista llama a
/// `detener()`. Asi la captura ensena el texto en la caja sin enviarlo.
final class DictadoDePrueba: SpeechRecognizing {
    static let transcripcionDeEjemplo = "Mensaje dictado de ejemplo"

    var disponible: Bool { true }

    func solicitarPermisos() async -> Bool { true }

    func empezar(onParcial: @escaping (String) -> Void) throws {
        onParcial(Self.transcripcionDeEjemplo)
    }

    func detener() {}
}
