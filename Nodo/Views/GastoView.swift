import Foundation
import SwiftUI

import NodoCore

/// Vista Gasto (SPEND.2): el libro de sellos contado sin recalentar cifras.
///
/// POR QUE esta pantalla no mira proveedores: el contrato dice que la unica
/// fuente es el libro construido desde los costos SELLADOS por mensaje. Todo lo
/// que se pinta aqui sale de `EstadoApp.resumenDeGasto`, que a su vez solo lee
/// `config.usoApp`. Cambiar el modelo activo o editar sus precios no puede
/// mover ni un centavo de estas barras.
struct GastoView: View {
    @EnvironmentObject private var estado: EstadoApp
    /// Borrador del campo del tope mensual (IDEA4). El valor guardado vive en
    /// `AppConfig`; este texto solo evita reescribir el campo en cada tecla.
    @State private var topeTexto = ""

    var body: some View {
        // El resumen y las estadisticas se arman una sola vez por pasada, al
        // presentar la vista. La agregacion IDEA5 NO vive en el streaming ni se
        // guarda: se calcula aqui y solo aqui.
        pantalla(estado.resumenDeGasto(), estado.estadisticasDeGasto())
            .onAppear { sincronizarCampoTope() }
    }

    private func pantalla(
        _ resumen: ResumenGasto,
        _ estadisticas: EstadisticasGasto
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // IDEA4 va primero: es la configuracion del tope mensual y la
                // lectura del acumulado contra el. IDEA5 es una seccion mas de
                // esta misma vista, consecutiva a la Idea 4.
                tarjetaTopeMensual(resumen)
                tarjetaEstadisticas(estadisticas)
                tarjetaHoy(resumen)
                tarjetaMes(resumen)
                tarjetaModelos(resumen)
                rotuloSinLimite
                fronteraHonesta
            }
            .padding(Tema.margen)
        }
        .background(Tema.fondo.ignoresSafeArea())
        .navigationTitle("Gasto")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Tope mensual personal (IDEA4)

    /// Configuracion y lectura del tope mensual.
    ///
    /// El acumulado sale del MISMO resumen sellado que el resto de la vista
    /// (`resumen.mes.usd`), asi que cambiar de modelo activo no lo mueve. La
    /// banda de aviso no bloquea nada: aqui solo se informa.
    private func tarjetaTopeMensual(_ resumen: ResumenGasto) -> some View {
        let tope = estado.estadoTopeMensual(acumuladoDelMes: resumen.mes.usd)

        return VStack(alignment: .leading, spacing: 12) {
            Text("TOPE MENSUAL")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Tema.textoSuave)
                .tracking(1.2)

            Text(descripcionDelTope(tope))
                .font(.subheadline)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("tope-mensual")

            barraDelTope(tope)

            HStack(spacing: 8) {
                TextField("0.00", text: $topeTexto)
                    .keyboardType(.decimalPad)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Tema.superficieAlta)
                    .clipShape(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .accessibilityIdentifier("tope-mensual-campo")

                Button("Guardar") {
                    guardarTopeMensual()
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
                .foregroundStyle(Tema.acento)
                .frame(minHeight: 44)
                .accessibilityIdentifier("tope-mensual-guardar")

                Button("Quitar") {
                    estado.fijarTopeMensual(nil)
                    topeTexto = ""
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
                .foregroundStyle(Tema.textoSuave)
                .frame(minHeight: 44)
                .accessibilityIdentifier("tope-mensual-quitar")
            }

            Text(TopeMensualGasto.nota)
                .font(.caption2)
                .foregroundStyle(Tema.textoSuave)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("tope-mensual-nota")

            BandaTopeMensual(estado: tope, conMargen: false)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tema.superficie)
        .clipShape(RoundedRectangle(cornerRadius: Tema.radio, style: .continuous))
    }

    private func descripcionDelTope(_ tope: TopeMensualGasto) -> String {
        guard let valor = tope.tope else {
            return "Sin tope: fija un monto mensual para recibir un aviso "
                + "al 80 % y al 100 %."
        }
        return "Tope: \(importeDelTope(valor)) · Acumulado: "
            + "\(importe(tope.acumulado)) (\(tope.porcentajeEntero) %)"
    }

    private func barraDelTope(_ tope: TopeMensualGasto) -> some View {
        GeometryReader { geometria in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Tema.superficieAlta)

                Capsule()
                    .fill(Tema.acento)
                    .frame(
                        width: geometria.size.width * CGFloat(tope.fraccion)
                    )
            }
        }
        .frame(height: 10)
        .accessibilityElement()
        .accessibilityIdentifier("tope-mensual-barra")
        .accessibilityLabel("Consumo del tope mensual")
        .accessibilityValue("\(tope.porcentajeEntero) por ciento")
    }

    private func sincronizarCampoTope() {
        if let tope = estado.config.topeMensualGasto {
            topeTexto = String(format: "%.2f", tope)
        } else {
            topeTexto = ""
        }
    }

    /// Guarda el monto escrito. Un texto vacio o no numerico NO borra el tope:
    /// para eso esta [Quitar], que es una accion explicita.
    private func guardarTopeMensual() {
        let limpio = topeTexto
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let valor = Double(limpio), valor > 0, valor.isFinite else {
            return
        }
        estado.fijarTopeMensual(valor)
        topeTexto = String(format: "%.2f", valor)
    }

    private func importeDelTope(_ valor: Double) -> String {
        "$" + String(format: "%.2f", valor)
    }

    // MARK: - Estadisticas locales (IDEA5)

    /// Agregados locales de uso y gasto: Hoy, Este mes y Total historico.
    ///
    /// POR QUE vive en esta misma vista y no en otra pantalla: IDEA5 es
    /// consecutiva a la Idea 4 y comparte la fuente sellada. El calculo ya
    /// viene resuelto en `EstadisticasGasto` (NodoCore); aqui solo se pinta.
    /// Las cifras jamas se presentan como factura del proveedor: el rotulo
    /// visible es «Gasto sellado local».
    private func tarjetaEstadisticas(_ estadisticas: EstadisticasGasto) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(EstadisticasGasto.rotulo)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Tema.textoSuave)
                    .tracking(1.2)
                    .accessibilityIdentifier("gasto-estadisticas-rotulo")

                Text(
                    "Agregado en este dispositivo sobre tus sellos. No es una "
                        + "factura de tu proveedor."
                )
                .font(.caption2)
                .foregroundStyle(Tema.textoSuave)
                .fixedSize(horizontal: false, vertical: true)
            }

            tramoEstadistica("Hoy", estadisticas.hoy, clave: "hoy")
            tramoEstadistica("Este mes", estadisticas.mes, clave: "mes")
            tramoEstadistica(
                "Total histórico",
                estadisticas.total,
                clave: "total"
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tema.superficie)
        .clipShape(RoundedRectangle(cornerRadius: Tema.radio, style: .continuous))
    }

    /// Un tramo de las estadisticas: conteo total y reparto por modelo.
    private func tramoEstadistica(
        _ titulo: String,
        _ tramo: TramoEstadistica,
        clave: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(titulo.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Tema.textoSuave)
                    .tracking(0.8)

                Spacer(minLength: 8)

                Text("\(tramo.mensajes) mensajes · \(importe(tramo.usd))")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("gasto-estadisticas-\(clave)")
            }

            if tramo.modelos.isEmpty {
                Text("Todavía no hay sellos en este periodo.")
                    .font(.caption2)
                    .foregroundStyle(Tema.textoSuave)
                    .accessibilityIdentifier("gasto-estadisticas-\(clave)-vacio")
            } else {
                ForEach(tramo.modelos) { fila in
                    filaDeEstadistica(fila, clave: clave)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tema.superficieAlta)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Una fila del reparto por modelo de un tramo.
    private func filaDeEstadistica(
        _ fila: FilaModeloEstadistica,
        clave: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(fila.nombre)
                .font(.caption)
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text("\(fila.mensajes) mensajes")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Tema.textoSuave)

            Text(importe(fila.usd))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("gasto-estadisticas-\(clave)-modelo-\(fila.clave)")
    }

    // MARK: - HOY

    /// Cifra grande del dia y UNA barra con su escala declarada en la vista.
    private func tarjetaHoy(_ resumen: ResumenGasto) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HOY")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Tema.textoSuave)
                .tracking(1.2)

            Text(importe(resumen.hoy.usd))
                .font(.system(size: 46, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityIdentifier("gasto-hoy")

            barraDeHoy(resumen)

            // La escala no se esconde: la barra se lee contra el dia mas alto
            // de la ventana, no contra una cuota que Nodo no tiene.
            Text(
                "barra llena = tu día más alto de los últimos 30 días: "
                    + importe(resumen.maximoDiario30)
            )
            .font(.caption2)
            .foregroundStyle(Tema.textoSuave)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("gasto-escala-hoy")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tema.superficie)
        .clipShape(RoundedRectangle(cornerRadius: Tema.radio, style: .continuous))
    }

    private func barraDeHoy(_ resumen: ResumenGasto) -> some View {
        let maximo = resumen.maximoDiario30
        let fraccion = maximo > 0 && maximo.isFinite && resumen.hoy.usd.isFinite
            ? min(max(resumen.hoy.usd / maximo, 0), 1)
            : 0

        return GeometryReader { geometria in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Tema.superficieAlta)

                Capsule()
                    .fill(Tema.acento)
                    .frame(width: geometria.size.width * CGFloat(fraccion))
            }
        }
        .frame(height: 12)
        .accessibilityElement()
        .accessibilityIdentifier("gasto-barra-hoy")
        .accessibilityLabel("Gasto de hoy")
        .accessibilityValue(
            "\(Int((fraccion * 100).rounded())) por ciento de tu día más alto"
        )
    }

    // MARK: - ESTE MES

    private func tarjetaMes(_ resumen: ResumenGasto) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("ESTE MES")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Tema.textoSuave)
                    .tracking(1.2)

                Spacer(minLength: 8)

                Text(importe(resumen.mes.usd))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityIdentifier("gasto-mes")
            }

            barrasDelMes(resumen)

            Text("Cada barra es un día del mes en curso.")
                .font(.caption2)
                .foregroundStyle(Tema.textoSuave)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tema.superficie)
        .clipShape(RoundedRectangle(cornerRadius: Tema.radio, style: .continuous))
    }

    /// Una barra por dia del mes. La altura se escala contra el dia mas caro
    /// del propio mes para que las diferencias se lean sin exagerarlas.
    private func barrasDelMes(_ resumen: ResumenGasto) -> some View {
        let maximo = resumen.diasDelMes.map(\.usd).max() ?? 0
        let diaDeHoy = Calendar(identifier: .gregorian).component(.day, from: Date())

        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(resumen.diasDelMes) { dia in
                barraDeDia(dia, maximo: maximo, diaDeHoy: diaDeHoy)
            }
        }
        .frame(height: 56, alignment: .bottom)
        .accessibilityIdentifier("gasto-barras-mes")
    }

    /// Barra de un dia del mes, escalada contra el dia mas caro del mes.
    private func barraDeDia(
        _ dia: DiaDeGasto,
        maximo: Double,
        diaDeHoy: Int
    ) -> some View {
        let fraccion = maximo > 0 && maximo.isFinite && dia.usd.isFinite
            ? min(max(dia.usd / maximo, 0), 1)
            : 0
        let altura = max(CGFloat(2), 56 * CGFloat(fraccion))
        let esHoy = dia.dia == diaDeHoy

        return Capsule()
            .fill(esHoy ? Tema.acento : Tema.acento.opacity(0.55))
            .frame(maxWidth: .infinity)
            .frame(height: altura)
            .accessibilityElement()
            .accessibilityIdentifier("gasto-dia-\(dia.dia)")
            .accessibilityLabel("Día \(dia.dia)")
            .accessibilityValue(importe(dia.usd))
    }

    // MARK: - Desglose por modelo

    private func tarjetaModelos(_ resumen: ResumenGasto) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("POR MODELO")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Tema.textoSuave)
                .tracking(1.2)

            if resumen.modelos.isEmpty {
                // Si solo hay tokens sin precio, el mensaje de vacio mentiria:
                // la linea de abajo ya declara ese consumo.
                if !resumen.tieneSinPrecio {
                    Text("Todavía no hay gasto registrado este mes.")
                        .font(.footnote)
                        .foregroundStyle(Tema.textoSuave)
                        .accessibilityIdentifier("gasto-modelos-vacio")
                }
            } else {
                ForEach(resumen.modelos) { fila in
                    filaDeModelo(fila)
                }
            }

            // La linea de tokens sin precio se agrega aparte y solo existe si
            // hubo llamadas que no se pudieron valorar: su dolar es
            // desconocido y no se inventa un cero.
            if resumen.tieneSinPrecio {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(Tema.textoSuave)
                        .accessibilityHidden(true)

                    Text(
                        "\(resumen.sinPrecio.total) tokens sin precio configurado"
                    )
                    .font(.footnote)
                    .foregroundStyle(Tema.textoSuave)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("gasto-sin-precio")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tema.superficie)
        .clipShape(RoundedRectangle(cornerRadius: Tema.radio, style: .continuous))
    }

    private func filaDeModelo(_ fila: FilaModeloGasto) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(fila.nombre)
                .font(.subheadline)
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(importe(fila.usd))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white)

                Text("\(Int(fila.porcentaje.rounded()))% del mes")
                    .font(.caption2)
                    .foregroundStyle(Tema.textoSuave)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("gasto-modelo-\(fila.clave)")
    }

    // MARK: - Rotulos permanentes

    /// Nodo no vende cuota ni impone un limite: el gasto ensenado es el real
    /// registrado, no un saldo que se agota.
    private var rotuloSinLimite: some View {
        Text("Sin límite: Nodo no tiene cuota; esto es tu gasto real registrado.")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tema.acento.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityIdentifier("gasto-sin-limite")
    }

    /// Frontera honesta: los precios son los del dueno en cada proveedor, no
    /// la factura que emita el proveedor.
    private var fronteraHonesta: some View {
        Text(
            "Las cifras usan los precios configurados por el dueño en cada "
                + "proveedor, no la factura del proveedor."
        )
        .font(.caption2)
        .foregroundStyle(Tema.textoSuave)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("gasto-frontera")
    }

    private func importe(_ valor: Double) -> String {
        "$" + String(format: "%.4f", valor)
    }
}
