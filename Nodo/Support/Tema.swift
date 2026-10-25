import Foundation
import SwiftUI
import UIKit

import NodoCore

/// Colores y medidas compartidas.
///
/// Se definen aqui y no en cada pantalla para que el tono no se vaya
/// desviando a medida que se anaden vistas.
///
/// Estos tokens son obligatorios: `UI_INVARIANTS.md` (raiz del repo, regla 6)
/// prohibe que una vista nueva introduzca colores, radios o tamanos fuera de
/// aqui.
enum Tema {
    static let fondo = Color(red: 0.05, green: 0.055, blue: 0.075)
    static let superficie = Color(red: 0.11, green: 0.12, blue: 0.15)
    static let superficieAlta = Color(red: 0.16, green: 0.17, blue: 0.21)
    static let acento = Color(red: 0.42, green: 0.63, blue: 1.0)
    static let textoSuave = Color.white.opacity(0.62)
    static let borde = Color.white.opacity(0.09)

    static let radio: CGFloat = 16
    static let margen: CGFloat = 16
}

/// Burbuja de un mensaje de usuario o de asistente.
///
/// B1.1 demolió de aquí todo lo que procedía de una herramienta: la rama del
/// rol `.herramienta` (fondo atenuado y texto suave), el rótulo «herramienta»
/// y la fila con el icono y el nombre técnico de cada `toolCall`. Un resultado
/// de herramienta sigue existiendo como metadato del payload, pero no tiene
/// ninguna representación posible en esta vista (`UI_INVARIANTS.md`, reglas 1-3).
struct BurbujaMensaje: View {
    let mensaje: ChatMessage
    /// Pie de la respuesta (tokens, costo, lectura, regenerar y copiar). Lo
    /// llevan TODAS las respuestas terminadas del asistente; sin consumo solo
    /// desaparece el texto de consumo y el boton de regenerar sigue exigiendo
    /// consumo (lo decide ChatView).
    var pie: PieRespuesta?
    /// Accion de "Ramificar chat desde aqui" (§5.4). Se ofrece sobre el
    /// contenedor de la burbuja, no sobre el texto: la seleccion de texto de
    /// las respuestas sigue viviendo dentro de `Text`/`ContenidoAsistente`.
    var alRamificar: (() -> Void)?

    init(
        mensaje: ChatMessage,
        pie: PieRespuesta? = nil,
        alRamificar: (() -> Void)? = nil
    ) {
        self.mensaje = mensaje
        self.pie = pie
        self.alRamificar = alRamificar
    }

    var esDelUsuario: Bool { mensaje.rol == .usuario }

    var body: some View {
        HStack {
            if esDelUsuario { Spacer(minLength: 48) }

            contenido

            if !esDelUsuario { Spacer(minLength: 48) }
        }
    }

    /// Burbuja con su menu contextual opcional.
    @ViewBuilder
    private var contenido: some View {
        if let alRamificar {
            burbuja.contextMenu {
                Button(action: alRamificar) {
                    Label(
                        "🔀 Ramificar chat desde aquí",
                        systemImage: "arrow.triangle.branch"
                    )
                }
            }
        } else {
            burbuja
        }
    }

    private var burbuja: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Skills aplicadas en este envio: la etiqueta visual ⚡ nombre
            // (§4.4). Las instrucciones viajan solo en el payload del turno.
            if !mensaje.skillsAplicadas.isEmpty {
                HStack(spacing: 6) {
                    ForEach(mensaje.skillsAplicadas, id: \.self) { nombre in
                        Text("⚡ \(nombre)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Tema.acento)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Tema.acento.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                .accessibilityIdentifier("skills-aplicadas")
            }

            if !mensaje.texto.isEmpty {
                if esDelUsuario {
                    Text(mensaje.texto)
                        .font(.body)
                        .textSelection(.enabled)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ContenidoAsistente(texto: mensaje.texto)
                }
            }

            if let pie {
                pie
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(fondo)
        .clipShape(RoundedRectangle(cornerRadius: Tema.radio, style: .continuous))
    }

    private var fondo: Color {
        if esDelUsuario { return Tema.acento.opacity(0.22) }
        return Tema.superficie
    }
}

/// Texto de una respuesta del asistente, con sus bloques de codigo separados.
///
/// El parser vive en NodoCore (`BloquesRespuesta`); aqui solo se decide como se
/// pinta cada tramo (§4.7).
private struct ContenidoAsistente: View {
    let texto: String

    private var bloques: [BloqueRespuesta] {
        BloquesRespuesta.parsear(texto)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(bloques.indices), id: \.self) { indice in
                bloque(bloques[indice])
            }
        }
    }

    @ViewBuilder
    private func bloque(_ bloque: BloqueRespuesta) -> some View {
        switch bloque {
        case .texto(let texto):
            Text(texto)
                .font(.body)
                .textSelection(.enabled)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

        case .codigo(let lenguaje, let contenido):
            BloqueCodigo(lenguaje: lenguaje, textoCrudo: contenido)
        }
    }
}

/// Pie de una respuesta: consumo, costo, lectura en voz alta, regenerar y
/// copiar, en una sola fila pegada a su burbuja (SPEC §3.3).
///
/// Se pinta en TODA respuesta terminada del asistente. Sin consumo medido solo
/// se oculta el texto de consumo; copiar y [Escuchar] siguen disponibles, y
/// regenerar sigue exigiendo `puedeRegenerar` (que ya requiere uso).
struct PieRespuesta: View {
    let uso: UsoTokens?
    let costo: Double?
    let textoParaCopiar: String
    let puedeRegenerar: Bool
    let otrosProveedores: [ProviderConfig]
    let nombreDeProveedor: (ProviderConfig) -> String
    let alRegenerar: () -> Void
    let alRegenerarCon: (ProviderConfig) -> Void
    /// Estado del control de lectura de ESTA burbuja (IDEA1).
    let estadoLectura: EstadoLectura
    let alAlternarLectura: () -> Void
    let alDetenerLectura: () -> Void

    init(
        uso: UsoTokens?,
        costo: Double?,
        textoParaCopiar: String,
        puedeRegenerar: Bool,
        otrosProveedores: [ProviderConfig],
        nombreDeProveedor: @escaping (ProviderConfig) -> String,
        alRegenerar: @escaping () -> Void,
        alRegenerarCon: @escaping (ProviderConfig) -> Void,
        estadoLectura: EstadoLectura = .inactivo,
        alAlternarLectura: @escaping () -> Void = {},
        alDetenerLectura: @escaping () -> Void = {}
    ) {
        self.uso = uso
        self.costo = costo
        self.textoParaCopiar = textoParaCopiar
        self.puedeRegenerar = puedeRegenerar
        self.otrosProveedores = otrosProveedores
        self.nombreDeProveedor = nombreDeProveedor
        self.alRegenerar = alRegenerar
        self.alRegenerarCon = alRegenerarCon
        self.estadoLectura = estadoLectura
        self.alAlternarLectura = alAlternarLectura
        self.alDetenerLectura = alDetenerLectura
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle()
                .fill(Tema.borde)
                .frame(height: 1)

            HStack(spacing: 8) {
                if let uso {
                    Text(textoConsumo(uso))
                        .font(.caption2)
                        .foregroundStyle(Tema.textoSuave)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .layoutPriority(1)
                }

                Spacer(minLength: 0)

                if puedeRegenerar {
                    botonRegenerar
                }

                botonLectura

                if estadoLectura.estaActivo {
                    botonDetener
                }

                Button {
                    UIPasteboard.general.string = textoParaCopiar
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(Tema.textoSuave)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copiar respuesta")
                .accessibilityIdentifier("copiar-respuesta")
            }
        }
        .padding(.top, 2)
        .accessibilityIdentifier("pie-respuesta")
    }

    private func textoConsumo(_ uso: UsoTokens) -> String {
        var texto = "\(uso.entrada) de entrada · \(uso.salida) de salida"
        if let costo {
            texto += " · ≈$\(String(format: "%.4f", costo)) estimado"
        }
        return texto
    }

    // MARK: - Lectura en voz alta (IDEA1)

    /// Icono del boton principal segun el estado de la lectura.
    private var iconoLectura: String {
        switch estadoLectura {
        case .inactivo: return "speaker.wave.2"
        case .leyendo: return "pause.fill"
        case .pausado: return "play.fill"
        }
    }

    /// Boton principal: capsula con icono y rotulo (Escuchar/Pausar/Reanudar).
    ///
    /// El rotulo es el mismo `EstadoLectura.rotulo` que prueban los tests de
    /// estado: no hay una segunda lista de textos que se pueda desincronizar.
    private var botonLectura: some View {
        Button {
            alAlternarLectura()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: iconoLectura)
                    .font(.caption)

                Text(estadoLectura.rotulo)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(
                estadoLectura.estaActivo ? Tema.acento : Tema.textoSuave
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Tema.acento.opacity(estadoLectura.estaActivo ? 0.22 : 0.12)
            )
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(estadoLectura.rotulo)
        .accessibilityIdentifier("escuchar-respuesta")
    }

    /// Solo existe mientras hay lectura viva: corta de inmediato y vuelve a
    /// [Escuchar].
    private var botonDetener: some View {
        Button {
            alDetenerLectura()
        } label: {
            Image(systemName: "stop.fill")
                .font(.caption)
                .foregroundStyle(Tema.textoSuave)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Detener lectura")
        .accessibilityIdentifier("detener-lectura")
    }

    /// Toque corto = regenerar; pulsacion larga = elegir otro modelo.
    private var botonRegenerarSimple: some View {
        Button {
            alRegenerar()
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(Tema.textoSuave)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Regenerar la última respuesta")
        .accessibilityIdentifier("regenerar-respuesta")
    }

    @ViewBuilder
    private var botonRegenerar: some View {
        if otrosProveedores.isEmpty {
            botonRegenerarSimple
        } else {
            botonRegenerarSimple.contextMenu {
                ForEach(otrosProveedores) { proveedor in
                    Button {
                        alRegenerarCon(proveedor)
                    } label: {
                        Text("Regenerar con \(nombreDeProveedor(proveedor))")
                    }
                }
            }
        }
    }
}

/// Texto que se esta escribiendo ahora mismo, con el cursor al final.
struct BurbujaEnCurso: View {
    let texto: String

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                if texto.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(texto.isEmpty ? "Pensando..." : texto)
                    .font(.body)
                    .textSelection(.enabled)
                    .foregroundStyle(texto.isEmpty ? Tema.textoSuave : Color.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Tema.superficie)
            .clipShape(RoundedRectangle(cornerRadius: Tema.radio, style: .continuous))

            Spacer(minLength: 48)
        }
    }
}

/// Aviso de error, con boton para cerrarlo.
struct AvisoError: View {
    let texto: String
    let cerrar: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(texto)
                .font(.footnote)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: cerrar) {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(Tema.textoSuave)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, Tema.margen)
    }
}

/// Pantalla vacia con un mensaje.
struct EstadoVacio: View {
    let icono: String
    let titulo: String
    let detalle: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icono)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Tema.acento.opacity(0.7))
            Text(titulo)
                .font(.headline)
            Text(detalle)
                .font(.footnote)
                .foregroundStyle(Tema.textoSuave)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
