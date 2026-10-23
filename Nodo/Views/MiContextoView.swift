import Foundation
import SwiftUI

import NodoCore

/// Pestana Mi Contexto: Memoria, Tope de gasto y Skills (§3.5).
///
/// Los tres bloques viven en un Form para que el teclado siempre pueda bajarse
/// (§2.4). El editor de Memoria y el de Skills son hojas con borrador: Cancelar
/// descarta y solo Guardar escribe en la configuracion.
struct MiContextoView: View {
    @EnvironmentObject private var estado: EstadoApp

    @State private var hoja: HojaMiContexto?
    /// Entrada que espera confirmacion antes de borrarse (MEM.4).
    ///
    /// La Memoria es texto curado a mano: un borrado por deslizamiento no debe
    /// ejecutarse sin preguntar, igual que el borrado de un chat.
    @State private var entradaAConfirmar: EntradaMemoria?
    @State private var mostrandoOtroTope = false
    @State private var otroTope = ""
    @FocusState private var otroTopeEnfocado: Bool

    /// Escalones rapidos del tope (§3.5). El vigente se marca como seleccionado.
    private static let escalones: [Double] = [0.10, 0.25, 0.50, 1.00]

    private var memoriaVacia: Bool {
        estado.config.memoria.allSatisfy {
            $0.texto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Tope que se aplica de verdad: nil equivale al dolar por defecto.
    private var topeActual: Double {
        estado.config.topeAvisoCostoEfectivo
    }

    /// "Otro…" se marca cuando el valor vigente no es ninguno de los rapidos.
    private var esOtroSeleccionado: Bool {
        topeActual > 0
            && !Self.escalones.contains { abs(topeActual - $0) < 0.0001 }
    }

    var body: some View {
        NavigationStack {
            Form {
                seccionMemoria
                seccionTope
                seccionSkills
            }
            .scrollContentBackground(.hidden)
            .background(Tema.fondo.ignoresSafeArea())
            .navigationTitle("Mi Contexto")
            // Esta pestana es su propia jerarquia: declara una sola vez la
            // barra Listo para el campo de "Otro…" y los editores.
            .conBarraTecladoListo()
            .scrollDismissesKeyboard(.interactively)
            .sheet(item: $hoja) { hoja in
                switch hoja {
                case .entrada(let entrada):
                    HojaEntradaMemoriaView(entrada: entrada)
                case .skill(let skill):
                    HojaSkillView(skill: skill)
                }
            }
            .confirmationDialog(
                "¿Borrar esta entrada de Memoria?",
                isPresented: Binding(
                    get: { entradaAConfirmar != nil },
                    set: { presentado in
                        if !presentado { entradaAConfirmar = nil }
                    }
                ),
                titleVisibility: .visible,
                presenting: entradaAConfirmar
            ) { entrada in
                Button("Borrar", role: .destructive) {
                    estado.borrarEntradaMemoria(id: entrada.id)
                    entradaAConfirmar = nil
                }
                Button("Cancelar", role: .cancel) {
                    entradaAConfirmar = nil
                }
            } message: { entrada in
                Text("Se quitará de la Memoria: \(entrada.texto)")
            }
        }
    }

    // MARK: - Bloque 1: Memoria

    private var seccionMemoria: some View {
        Section {
            Text("Lo que escribas aquí se envía automáticamente a todos los modelos para que te conozcan sin que tengas que presentarte en cada chat.")
                .font(.footnote)
                .foregroundStyle(Tema.textoSuave)
                .fixedSize(horizontal: false, vertical: true)

            if memoriaVacia {
                Text("Tu memoria está vacía.")
                    .font(.footnote)
                    .foregroundStyle(Tema.textoSuave)
                    .accessibilityIdentifier("memoria-vacia")
            } else {
                // MEM.4: una fila por entrada. Tocar la fila abre su editor;
                // deslizar hacia la izquierda pide confirmacion antes de
                // borrarla. Ya no hay un unico bloque de texto editable.
                ForEach(estado.config.memoria) { entrada in
                    Button {
                        hoja = .entrada(entrada)
                    } label: {
                        filaEntrada(entrada)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("memoria-entrada")
                    .accessibilityLabel("Editar entrada de Memoria: \(entrada.texto)")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            entradaAConfirmar = entrada
                        } label: {
                            Label("Borrar", systemImage: "trash")
                        }
                    }
                }

                HStack {
                    Text("Peso estimado")
                        .foregroundStyle(.white)
                    Spacer()
                    Text("~\(estado.pesoEstimadoMemoria) tokens est.")
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(Tema.textoSuave)
                        .accessibilityIdentifier("memoria-peso")
                }

                if let estimacion = estado.costoEstimadoDeMemoria {
                    // Rotulo informativo: es una estimacion con el precio de
                    // entrada del proveedor ACTIVO, y se dice con cual se
                    // calculo. No es un costo historico.
                    Text("≈$\(String(format: "%.6f", estimacion.costo)) por envío · estimado con \(estimacion.proveedor)")
                        .font(.caption2)
                        .foregroundStyle(Tema.textoSuave)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("memoria-costo")
                }
            }

            Button {
                hoja = .entrada(nil)
            } label: {
                Label("Añadir entrada", systemImage: "plus.circle")
            }
            // Se conserva el identificador de las capturas de la Fase 4: ahora
            // abre el editor de una entrada nueva, no el bloque unico.
            .accessibilityIdentifier("memoria-editar")
        } header: {
            Text("Memoria")
        } footer: {
            Text("Se aplica desde el siguiente mensaje que envíes.")
        }
    }

    /// Fila de una entrada: texto completo (hasta 3 lineas) y acceso al editor.
    private func filaEntrada(_ entrada: EntradaMemoria) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entrada.texto)
                .foregroundStyle(.white)
                .lineLimit(3)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Tema.textoSuave)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Bloque 2: Tope de gasto

    private var seccionTope: some View {
        Section {
            Text("Te avisaremos dentro de la conversación si un solo chat supera este monto.")
                .font(.footnote)
                .foregroundStyle(Tema.textoSuave)
                .fixedSize(horizontal: false, vertical: true)

            acumulador

            HStack(spacing: 8) {
                ForEach(Self.escalones, id: \.self) { valor in
                    botonTope(valor)
                }
                botonOtro
            }

            if mostrandoOtroTope {
                campoOtroTope
            }
        } header: {
            Text("Tope de gasto por chat")
        } footer: {
            Text("0 = sin aviso. Los importes son una estimación con los precios configurados.")
        }
    }

    /// Linea del acumulador global, encima de los botones (§3.5).
    private var acumulador: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(
                "Gasto acumulado: Hoy \(importe(estado.gastoDelDiaVisible)) · "
                    + "Desde el último reinicio: \(importe(estado.config.gasto.desdeReinicio))"
            )
            .font(.footnote)
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("gasto-acumulado")

            Spacer(minLength: 4)

            Button("Reiniciar contador") {
                estado.reiniciarContadorGasto()
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.borderless)
            .frame(minHeight: 44)
            .accessibilityIdentifier("reiniciar-contador")
        }
    }

    private func botonTope(_ valor: Double) -> some View {
        let seleccionado = abs(topeActual - valor) < 0.0001
        return Button {
            fijarTope(valor)
        } label: {
            Text("$\(String(format: "%.2f", valor))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(seleccionado ? Color.white : Tema.textoSuave)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(seleccionado ? Tema.acento : Tema.superficieAlta)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tope-\(Int((valor * 100).rounded()))")
        .accessibilityValue(seleccionado ? "Seleccionado" : "")
    }

    private var botonOtro: some View {
        let seleccionado = esOtroSeleccionado
        return Button {
            abrirOtro()
        } label: {
            Text("Otro…")
                .font(.caption.weight(.semibold))
                .foregroundStyle(seleccionado || mostrandoOtroTope ? Color.white : Tema.textoSuave)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(seleccionado || mostrandoOtroTope ? Tema.acento : Tema.superficieAlta)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tope-otro")
        .accessibilityValue(seleccionado ? "Seleccionado" : "")
    }

    private var campoOtroTope: some View {
        HStack {
            Text("Tope en dólares")
                .foregroundStyle(.white)
            Spacer()
            TextField("0.00", text: $otroTope)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.white)
                .focused($otroTopeEnfocado)
                .frame(maxWidth: 120)
                .accessibilityIdentifier("tope-otro-campo")
                .accessibilityLabel("Tope de aviso por chat")
                .onChange(of: otroTope) { _, nuevo in
                    actualizarOtroTope(nuevo)
                }
            Button {
                cerrarOtro()
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Tema.acento)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cerrar campo de tope")
        }
    }

    /// Guarda el valor de un boton rapido y baja el teclado.
    private func fijarTope(_ valor: Double) {
        bajarTeclado()
        otroTopeEnfocado = false
        mostrandoOtroTope = false
        estado.config.topeAvisoCosto = valor
    }

    /// "Otro…" abre el campo numerico con el valor vigente ya escrito.
    private func abrirOtro() {
        otroTope = Self.textoDe(topeActual)
        mostrandoOtroTope = true
        DispatchQueue.main.async {
            otroTopeEnfocado = true
        }
    }

    private func cerrarOtro() {
        bajarTeclado()
        otroTopeEnfocado = false
        mostrandoOtroTope = false
    }

    /// Un texto vacio o invalido no pisa el tope anterior; 0 si es un valor.
    private func actualizarOtroTope(_ texto: String) {
        let limpio = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpio.isEmpty else { return }

        let normalizado = limpio.replacingOccurrences(of: ",", with: ".")
        guard let valor = Double(normalizado), valor.isFinite, valor >= 0 else {
            return
        }
        estado.config.topeAvisoCosto = valor
    }

    private static func textoDe(_ valor: Double) -> String {
        if valor == valor.rounded() {
            return String(format: "%.0f", valor)
        }
        return String(valor)
    }

    private func importe(_ valor: Double) -> String {
        "$" + String(format: "%.4f", valor)
    }

    // MARK: - Bloque 3: Skills

    private var seccionSkills: some View {
        Section {
            if estado.config.skills.isEmpty {
                Text("Todavía no tienes skills. Crea una con un nombre y sus instrucciones.")
                    .font(.footnote)
                    .foregroundStyle(Tema.textoSuave)
                    .accessibilityIdentifier("skills-vacias")
            } else {
                ForEach(estado.config.skills) { skill in
                    Button {
                        hoja = .skill(skill)
                    } label: {
                        HStack {
                            HStack(spacing: 8) {
                                Text(skill.nombre)
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text("/\(skill.slug)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(Tema.textoSuave)
                                    .lineLimit(1)
                                if skill.origen == .fabrica {
                                    etiquetaDeFabrica
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(Tema.textoSuave)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("skill-fila")
                    .accessibilityLabel(
                        "Editar skill \(skill.nombre), se invoca como /\(skill.slug)"
                    )
                }
                .onDelete { indices in
                    // Se copian los ids antes de borrar: los indices apuntan a
                    // la lista original y cada borrado desplaza los siguientes.
                    let ids = indices.map { estado.config.skills[$0].id }
                    for id in ids {
                        estado.borrarSkill(id: id)
                    }
                }
            }

            Button {
                hoja = .skill(nil)
            } label: {
                Label("Nueva skill", systemImage: "plus.circle")
            }
            .accessibilityIdentifier("skill-nueva")

            // PACK.1: la unica via para que vuelva una skill de fabrica
            // borrada, ademas de reinstalar la app. Respeta la regla de
            // idempotencia por slug: solo repone las que faltan.
            Button {
                estado.restaurarSkillsDeFabrica()
            } label: {
                Label(
                    "Restaurar skills de fábrica",
                    systemImage: "arrow.counterclockwise"
                )
            }
            .accessibilityIdentifier("skill-restaurar")
        } header: {
            Text("Skills")
        } footer: {
            Text(
                "Invócalas en cualquier chat escribiendo /slug o tocándolas en el selector de /. "
                    + "Las de fábrica se editan y se borran como las tuyas; restaurar repone solo las que falten."
            )
        }
    }

    /// Etiqueta de origen de una skill del pack (PACK.1).
    ///
    /// No cambia nada de como se edita o invoca: solo dice de donde salio para
    /// que el dueno sepa que esa se puede restaurar si la borra.
    private var etiquetaDeFabrica: some View {
        Text("De fábrica")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Tema.acento)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Tema.acento.opacity(0.16))
            .clipShape(Capsule())
            .fixedSize()
            .accessibilityIdentifier("skill-origen-fabrica")
    }
}

/// Hoja que puede abrir Mi Contexto: el editor de una entrada de Memoria o el
/// de una skill.
private enum HojaMiContexto: Identifiable {
    /// nil = entrada nueva.
    case entrada(EntradaMemoria?)
    case skill(SkillLocal?)

    var id: String {
        switch self {
        case .entrada(let entrada):
            return "memoria-\(entrada?.id.uuidString ?? "nueva")"
        case .skill(let skill):
            return "skill-\(skill?.id.uuidString ?? "nueva")"
        }
    }
}
