import AVFoundation
import Foundation

/// Lector real de IDEA1: envuelve `AVSpeechSynthesizer` (voz local del iPhone).
///
/// Solo primer plano: no declara `UIBackgroundModes = audio` ni deja procesos
/// en segundo plano, asi que bloquear el telefono detiene la lectura. No
/// guarda audio ni envia nada a ningun servicio: la sintesis ocurre en el
/// dispositivo.
///
/// POR QUE un envoltorio y no usar el sintetizador desde la vista: `EstadoApp`
/// necesita una costura inyectable para probar los estados y los cortes sin
/// hardware, y la vista no debe conocer `AVSpeechSynthesizer`.
@MainActor
final class LectorAVSpeech: NSObject, LectorEnVozAlta, AVSpeechSynthesizerDelegate {
    private let sintetizador = AVSpeechSynthesizer()
    private var locuciones: [LocucionLectura] = []
    private var indice = 0
    private var enunciadoActual: AVSpeechUtterance?
    private var alTerminar: (() -> Void)?

    private(set) var estado: EstadoLectura = .inactivo

    override init() {
        super.init()
        sintetizador.delegate = self
    }

    func leer(
        _ locuciones: [LocucionLectura],
        alTerminar: @escaping () -> Void
    ) {
        // Empezar otra lectura nunca deja sonando la anterior.
        detener()

        guard !locuciones.isEmpty else {
            alTerminar()
            return
        }

        self.locuciones = locuciones
        self.alTerminar = alTerminar
        indice = 0
        estado = .leyendo
        prepararSesionDeAudio()
        hablarSiguiente()
    }

    func pausar() {
        guard estado == .leyendo else { return }
        // Pausa en la palabra: al reanudar no se pierde la posicion.
        if sintetizador.pauseSpeaking(at: .word) {
            estado = .pausado
        }
    }

    func reanudar() {
        guard estado == .pausado else { return }
        if sintetizador.continueSpeaking() {
            estado = .leyendo
        }
    }

    func detener() {
        // OBLIGATORIO: el corte es inmediato y no deja audio en curso.
        enunciadoActual = nil
        sintetizador.stopSpeaking(at: .immediate)
        locuciones = []
        indice = 0
        alTerminar = nil
        if estado != .inactivo {
            estado = .inactivo
            desactivarSesionDeAudio()
        }
    }

    // MARK: - Sintesis

    private func hablarSiguiente() {
        guard indice < locuciones.count else {
            terminar()
            return
        }

        let locucion = locuciones[indice]
        indice += 1

        let enunciado = AVSpeechUtterance(string: textoDe(locucion))
        enunciado.voice = AVSpeechSynthesisVoice(language: "es-CO")
        enunciado.rate = AVSpeechUtteranceDefaultSpeechRate
        enunciadoActual = enunciado
        sintetizador.speak(enunciado)
    }

    private func textoDe(_ locucion: LocucionLectura) -> String {
        switch locucion {
        case .texto(let texto):
            return texto
        case .anuncioCodigoOmitido:
            return LecturaEnVozAlta.anuncioCodigoOmitido
        }
    }

    private func terminar() {
        let aviso = alTerminar
        enunciadoActual = nil
        locuciones = []
        indice = 0
        alTerminar = nil
        estado = .inactivo
        desactivarSesionDeAudio()
        aviso?()
    }

    // MARK: - Sesion de audio

    /// La sintesis usa la salida del telefono, nunca el microfono.
    ///
    /// POR QUE se configura aqui: el dictado deja la sesion en `.record`; sin
    /// volver a una categoria de reproduccion, la voz podria no sonar despues
    /// de dictar. El dictado y la sintesis nunca estan activos a la vez: abrir
    /// uno detiene al otro.
    private func prepararSesionDeAudio() {
        let sesion = AVAudioSession.sharedInstance()
        try? sesion.setCategory(
            .playback,
            mode: .spokenAudio,
            options: [.duckOthers]
        )
        try? sesion.setActive(true, options: [])
    }

    private func desactivarSesionDeAudio() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        // Un aviso tardio de una lectura ya cortada no puede avanzar la nueva.
        guard utterance === enunciadoActual else { return }
        enunciadoActual = nil
        hablarSiguiente()
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        // `detener()` ya dejo el estado inactivo; no hay nada que avanzar.
    }
}
