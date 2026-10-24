import Foundation
import SwiftUI

import NodoCore

/// Hoja de solo consulta con las dos metricas del chat y la tabla de ventanas.
///
/// POR QUE dos secciones separadas: la ocupacion mide el aire que queda AHORA
/// (solo la ultima respuesta) y el consumo acumulado es la factura historica
/// del chat. Mezclarlas fue el error de la v1 (SPEC §4.1).
struct HojaEstadoChatView: View {
    @EnvironmentObject private var estado: EstadoApp
    @Environment(\.dismiss) private var dismiss

    /// Modelo cuya ventana se esta corrigiendo en la tabla.
    @State private var modeloEnEdicion: String?
    @State private var textoVentanaTabla = ""
    /// Ventana que se escribe cuando el modelo activo todavia no tiene una.
    @State private var textoVentanaNueva = ""

    private var proveedor: ProviderConfig? {
        estado.config.proveedorSeleccionado
    }

    /// Identificador crudo: es la clave de la tabla de ventanas.
    private var modeloCrudo: String {
        proveedor?.modelo.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var modeloLimpio: String {
        modeloCrudo.isEmpty ? "Sin modelo" : NombresLimpios.modelo(modeloCrudo)
    }

    private var ocupacion: UsoTokens? {
        estado.ocupacionDelChat
    }

    private var ventanaActiva: Int? {
        guard !modeloCrudo.isEmpty else { return nil }
        return estado.ventana(paraModelo: modeloCrudo)
    }

    private var consumo: UsoTokens? {
        estado.usoAcumuladoDelChat
    }

    private var modelosConVentana: [String] {
        estado.ventanasPorModelo
            .filter { $0.value > 0 }
            .keys
            .sorted()
    }

    var body: some View {
        NavigationStack {
            Form {
                seccionOcupacion
                seccionConsumo
                seccionVentanas
            }
            .scrollContentBackground(.hidden)
            .background(Tema.fondo.ignoresSafeArea())
            .navigationTitle("Estado del chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cerrar") {
                        cerrar()
                    }
                    .accessibilityIdentifier("estado-cerrar")
                }
            }
            // Esta hoja es su propia jerarquia: la barra Listo se declara una
            // sola vez aqui, no se hereda de la conversacion (contrato §4).
            .conBarraTecladoListo()
            .scrollDismissesKeyboard(.interactively)
        }
    }

    // MARK: - Ocupacion de la ventana

    @ViewBuilder
    private var seccionOcupacion: some View {
        Section {
            if let uso = ocupacion {
                if let ventana = ventanaActiva {
                    barraDeOcupacion(uso: uso, ventana: ventana)
                } else {
                    HStack {
                        Text("Tokens de la última respuesta")
                        Spacer()
                        Text("\(uso.total)")
                            .monospacedDigit()
                            .foregroundStyle(Tema.textoSuave)
                    }

                    if modeloCrudo.isEmpty {
                        Text("No hay un modelo activo: elige uno para asociarle una ventana.")
                            .font(.footnote)
                            .foregroundStyle(Tema.textoSuave)
                    } else {
                        Text("Ventana de \(modeloLimpio)")
                            .font(.footnote)
                            .foregroundStyle(Tema.textoSuave)

                        HStack {
                            TextField("Tokens", text: $textoVentanaNueva)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(.white)
                                .accessibilityIdentifier("ventana-nueva")
                                .accessibilityLabel("Ventana de \(modeloLimpio) en tokens")

                            Button("Definir") {
                                definirVentanaNueva()
                            }
                            .fontWeight(.semibold)
                            .disabled(ventanaEscrita == nil)
                        }

                        Text("Sin ventana definida no hay porcentaje. Define la ventana de este modelo.")
                            .font(.footnote)
                            .foregroundStyle(Tema.textoSuave)
                    }
                }
            } else {
                Text("Todavía no hay respuestas medidas en este chat.")
                    .foregroundStyle(Tema.textoSuave)
            }
        } header: {
            Text("Ocupación de la ventana")
        } footer: {
            Text("Mide el aire que le queda a este chat ahora: tokens de la última respuesta contra la ventana del modelo.")
        }
    }

    private func barraDeOcupacion(uso: UsoTokens, ventana: Int) -> some View {
        let fraccion = MetricasChat.porcentaje(ocupacion: uso.total, ventana: ventana) ?? 0
        let porcentaje = Int((fraccion * 100).rounded())

        return VStack(alignment: .leading, spacing: 8) {
            // La barra se recorta al 100% para no romper el control, pero la
            // cifra conserva el exceso: pasarse de la ventana es informacion.
            ProgressView(value: min(max(fraccion, 0), 1))
                .tint(Tema.acento)
                .accessibilityValue("\(porcentaje) por ciento")

            HStack {
                Text("\(uso.total) de \(ventana) tokens (\(porcentaje)%)")
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Spacer()
                Text(modeloLimpio)
                    .font(.caption)
                    .foregroundStyle(Tema.textoSuave)
                    .lineLimit(1)
            }
        }
    }

    private var ventanaEscrita: Int? {
        let limpio = textoVentanaNueva.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let valor = Int(limpio), valor > 0 else { return nil }
        return valor
    }

    private func definirVentanaNueva() {
        guard let ventana = ventanaEscrita, !modeloCrudo.isEmpty else { return }
        estado.fijarVentana(ventana, paraModelo: modeloCrudo)
        textoVentanaNueva = ""
        bajarTeclado()
    }

    // MARK: - Consumo acumulado del chat

    @ViewBuilder
    private var seccionConsumo: some View {
        Section {
            if let uso = consumo {
                HStack {
                    Text("Tokens acumulados")
                    Spacer()
                    Text("\(uso.total)")
                        .monospacedDigit()
                        .foregroundStyle(Tema.textoSuave)
                }

                if let costo = estado.costoAcumuladoDelChat {
                    HStack {
                        Text("Costo acumulado estimado")
                        Spacer()
                        Text(textoCosto(costo))
                            .monospacedDigit()
                            .foregroundStyle(Tema.textoSuave)
                    }

                    // COST.3: los mensajes legados se sellaron al cargar con
                    // los precios actuales de su proveedor. La cifra sigue
                    // siendo historica, pero conviene decirlo.
                    if estado.hayCostosEstimados {
                        Text("Incluye estimaciones de legado: los mensajes viejos se sellaron con los precios actuales de su proveedor.")
                            .font(.footnote)
                            .foregroundStyle(Tema.textoSuave)
                            .accessibilityIdentifier("estado-costos-estimados")
                    }
                }
            } else {
                Text("Todavía no hay consumo medido en este chat.")
                    .foregroundStyle(Tema.textoSuave)
            }
        } header: {
            Text("Consumo acumulado del chat")
        } footer: {
            Text("Suma histórica de todas las llamadas del chat. No baja al compactar.")
        }
    }

    private func textoCosto(_ costo: Double) -> String {
        "≈$\(String(format: "%.4f", costo)) estimado"
    }

    // MARK: - Tabla de ventanas

    @ViewBuilder
    private var seccionVentanas: some View {
        Section {
            if modelosConVentana.isEmpty {
                Text("Todavía no hay ventanas definidas.")
                    .foregroundStyle(Tema.textoSuave)
            } else {
                ForEach(modelosConVentana, id: \.self) { modelo in
                    filaVentana(modelo)
                }
            }
        } header: {
            Text("Ventanas definidas")
        } footer: {
            Text("Toca una fila para corregir la ventana de ese modelo. El porcentaje se recalcula en cuanto guardas.")
        }
    }

    @ViewBuilder
    private func filaVentana(_ modelo: String) -> some View {
        if modeloEnEdicion == modelo {
            VStack(alignment: .leading, spacing: 8) {
                Text(NombresLimpios.modelo(modelo))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    TextField("Tokens", text: $textoVentanaTabla)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.white)
                        .frame(maxWidth: 120)
                        .accessibilityIdentifier("ventana-editor")
                        .accessibilityLabel("Ventana de \(NombresLimpios.modelo(modelo)) en tokens")

                    Spacer(minLength: 8)

                    Button {
                        guardarVentanaTabla(modelo)
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .buttonStyle(.borderless)
                    .disabled(ventanaTablaEscrita == nil)
                    .accessibilityLabel("Guardar ventana")

                    Button {
                        cancelarEdicionDeVentana()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Cancelar edición")

                    Button(role: .destructive) {
                        quitarVentana(modelo)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Quitar ventana")
                }
            }
        } else {
            Button {
                modeloEnEdicion = modelo
                textoVentanaTabla = String(estado.ventana(paraModelo: modelo) ?? 0)
            } label: {
                HStack {
                    Text(NombresLimpios.modelo(modelo))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer()
                    Text("\(estado.ventana(paraModelo: modelo) ?? 0) tokens")
                        .monospacedDigit()
                        .foregroundStyle(Tema.textoSuave)
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(Tema.textoSuave)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ventana-fila")
            .accessibilityLabel("Editar ventana de \(NombresLimpios.modelo(modelo))")
        }
    }

    private var ventanaTablaEscrita: Int? {
        let limpio = textoVentanaTabla.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let valor = Int(limpio), valor > 0 else { return nil }
        return valor
    }

    private func guardarVentanaTabla(_ modelo: String) {
        guard let ventana = ventanaTablaEscrita else { return }
        estado.fijarVentana(ventana, paraModelo: modelo)
        cancelarEdicionDeVentana()
    }

    private func cancelarEdicionDeVentana() {
        modeloEnEdicion = nil
        textoVentanaTabla = ""
        bajarTeclado()
    }

    private func quitarVentana(_ modelo: String) {
        estado.fijarVentana(nil, paraModelo: modelo)
        cancelarEdicionDeVentana()
    }

    /// Hoja de consulta: Cerrar y arrastrar hacia abajo hacen lo mismo.
    private func cerrar() {
        modeloEnEdicion = nil
        textoVentanaTabla = ""
        textoVentanaNueva = ""
        bajarTeclado()
        dismiss()
    }
}
