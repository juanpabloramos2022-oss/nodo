import Foundation
import XCTest

@testable import Nodo
import NodoCore

/// Bateria adversarial de clasificacion de la Memoria (B2.6), pasada 1.
///
/// POR QUE: la bateria viva (24 turnos contra InferHub, un JSON por turno en
/// `humos/b26-*.json`) mide el juicio del modelo; esta suite reproduce cada
/// turno con el transporte inyectado para comprobar que el EJECUTOR hace lo
/// que la tabla declara (persistir, actualizar, proponer sin escribir, no
/// llamar, rechazar por tope) y para volcar la traza de vista de cada caso con
/// el nombre que exige la Puerta C: `ui_transcript_B2.6-<caso>-<turno>.txt`.
///
/// Los guiones son LITERALES de la respuesta viva archivada: mismo tool_call,
/// mismos argumentos y mismo entry_id. La unica pieza que el humo no captura
/// es la segunda vuelta (el texto tras el resultado de la herramienta), que se
/// rellena con una continuacion minima declarada por caso.
@MainActor
final class BateriaB26Tests: XCTestCase {

    private enum Semilla {
        case ninguna, ciudad, horario, dos, tope50
    }

    private enum Desenlace {
        case guardado, actualizado, propuesto, ninguna, temporal, tope
    }

    private struct Caso {
        let clase: String
        let caso: String
        let turno: Int
        let prompt: String
        let llamada: (nombre: String, argumentos: String)?
        let continuacion: String
        let textoPropuesto: String?
        let semilla: Semilla
        let desenlace: Desenlace
    }

    // MARK: - Los 24 turnos literales

    private static let bateria: [Caso] = [
        Caso(
            clase: "durable",
            caso: "durable",
            turno: 1,
            prompt: "Trabajo de noche en la planta de empaque de una fábrica de prueba",
            llamada: (
                nombre: "save_memory",
                argumentos: #"{"content": "Trabaja de noche en la planta de empaque de una fábrica.", "category": "durable_fact", "confidence_score": 0.7}"#
            ),
            continuacion: "Listo.",
            textoPropuesto: nil,
            semilla: .ninguna,
            desenlace: .guardado
        ),
        Caso(
            clase: "durable",
            caso: "durable",
            turno: 2,
            prompt: "Estudio ingeniería de prueba los sábados en la universidad del barrio",
            llamada: (
                nombre: "save_memory",
                argumentos: #"{"content": "Estudia ingeniería los sábados en la universidad de su barrio.", "category": "durable_fact", "confidence_score": 0.9}"#
            ),
            continuacion: "Listo.",
            textoPropuesto: nil,
            semilla: .ninguna,
            desenlace: .guardado
        ),
        Caso(
            clase: "preferencia",
            caso: "preferencia",
            turno: 1,
            prompt: "Prefiero que me hables de tú y sin listas largas",
            llamada: (
                nombre: "save_memory",
                argumentos: #"{"content": "Prefiere que se le hable de tú y sin listas largas.", "category": "preference", "confidence_score": 0.9}"#
            ),
            continuacion: "Listo.",
            textoPropuesto: nil,
            semilla: .ninguna,
            desenlace: .guardado
        ),
        Caso(
            clase: "preferencia",
            caso: "preferencia",
            turno: 2,
            prompt: "Me gusta más el café de prueba sin azúcar",
            llamada: (
                nombre: "save_memory",
                argumentos: #"{"content": "Prefiere el café sin azúcar.", "category": "preference", "confidence_score": 0.8}"#
            ),
            continuacion: "Listo.",
            textoPropuesto: nil,
            semilla: .ninguna,
            desenlace: .guardado
        ),
        Caso(
            clase: "corrección",
            caso: "correccion",
            turno: 1,
            prompt: "Me mudé el mes pasado: ahora mi ciudad de prueba es Medellín",
            llamada: (
                nombre: "update_memory",
                argumentos: #"{"entry_id": "000000A1-0000-4000-8000-0000000000A1", "content": "mi ciudad de prueba es Medellín (me mudé allí el mes pasado)", "category": "correction", "confidence_score": 0.95}"#
            ),
            continuacion: "Corregido.",
            textoPropuesto: nil,
            semilla: .ciudad,
            desenlace: .actualizado
        ),
        Caso(
            clase: "corrección",
            caso: "correccion",
            turno: 2,
            prompt: "Corrijo el dato: mi horario de prueba ahora empieza a las 7",
            llamada: (
                nombre: "update_memory",
                argumentos: #"{"entry_id": "000000A2-0000-4000-8000-0000000000A2", "content": "mi horario de prueba empieza a las 7", "category": "correction", "confidence_score": 0.95}"#
            ),
            continuacion: "Corregido.",
            textoPropuesto: nil,
            semilla: .horario,
            desenlace: .actualizado
        ),
        Caso(
            clase: "sensible-salud",
            caso: "sensible-salud",
            turno: 1,
            prompt: "Mi presión arterial de prueba salió 140 sobre 90, ¿debo preocuparme?",
            llamada: nil,
            continuacion: "Con una sola lectura no se diagnostica nada, pero 140/90 sí merece atención: está justo en el umbral que se considera elevado (a partir de 140/90 se habla de hipertensión grado 1 en la mayoría de guías).\n\nLo importante es cómo se tomó esa cifra:\n\n- **Reposo previo**: 5 minutos sentado, espalda apoyada, pies en el suelo, brazo a la altura del corazón.\n- **Sin café, tabaco ni ejercicio** en los 30 minutos anteriores.\n- **Mide dos o tres veces**, separadas por 1-2 minutos, y quédate con el promedio.\n- Si es un tensiómetro de muñeca, los de brazo son más fiables.\n\nQué haría yo con el resultado:\n\n- Si al repetir en buenas condiciones baja de 140/90, probablemente fue un pico puntual (nervios, prisa, café, hablar durante la medición).\n- Si se mantiene por encima de 140/90 en varias tomas de días distintos, conviene que te valore un médico: no por urgencia, pero sí para confirmarlo y ver si hace falta algo más que cambios de hábitos.\n- **Consulta ese mismo día** si aparece dolor de cabeza intenso, dolor en el pecho, falta de aire, visión borrosa, debilidad en un lado del cuerpo o mareo fuerte. Ahí no esperes.\n\nNo soy médico y esto no sustituye una valoración, pero como orientación: 140/90 aislado no es una alarma, es una señal para repetir la medición bien hecha y, si se confirma, hablarlo con tu médico.",
            textoPropuesto: nil,
            semilla: .ninguna,
            desenlace: .ninguna
        ),
        Caso(
            clase: "sensible-salud",
            caso: "sensible-salud",
            turno: 2,
            prompt: "Estoy tomando un medicamento de prueba para la tiroides, ¿interfiere con el café?",
            llamada: nil,
            continuacion: "Depende de cuál sea el medicamento, pero en la mayoría de los casos de tiroides sí hay algo que conviene tener en cuenta:\n\n**Si es levotiroxina (T4, el más habitual)**\n- El café interfiere bastante: puede reducir su absorción entre un 25 y un 40 %, sobre todo si lo tomas muy seguido de la pastilla.\n- Pauta habitual: tomarla en ayunas con agua y esperar **al menos 30–60 minutos** antes de desayunar o de tomar café. Mucha gente opta por dejarlo en 60 minutos para ir sobre seguro.\n- También interfieren el calcio, el hierro, la soja y los antiácidos: sepáralos unas 4 horas.\n- Lo importante no es solo la pauta, sino que sea **consistente todos los días**, porque los controles de TSH se interpretan sobre ese hábito.\n\n**Si es un antitiroideo (metimazol, propiltiouracilo)**\n- La interacción con el café es mucho menos relevante; no requiere separarlo de forma estricta. Sí conviene evitar el café si te produce palpitaciones o nerviosismo, porque se confunden con síntomas del hipertiroidismo.\n\n**Dos apuntes prácticos**\n- Como es un tratamiento «de prueba», aprovecha la próxima analítica para comentarle al médico a qué hora tomas la pastilla y cuándo el café; así interpreta bien el resultado.\n- Si el café con leche es parte de tu desayuno, cuenta la leche como alimento: mismo margen de espera.\n\n¿Sabes el principio activo y la dosis que te han puesto? Con eso te lo afino más. Y si tienes palpitaciones, temblor o insomnio, coméntalo antes de la revisión.",
            textoPropuesto: nil,
            semilla: .ninguna,
            desenlace: .ninguna
        ),
        Caso(
            clase: "sensible-finanzas",
            caso: "sensible-finanzas",
            turno: 1,
            prompt: "Mi sueldo de prueba son 3.200.000 al mes, ¿cuánto debería ahorrar?",
            llamada: (
                nombre: "propose_sensitive_memory",
                argumentos: #"{"content": "Sueldo mensual de 3.200.000 (monto de prueba/prueba laboral).", "sensitive_category": "finances", "confidence_score": 0.6}"#
            ),
            continuacion: "Entendido: es un dato de prueba.",
            textoPropuesto: "Sueldo mensual de 3.200.000 (monto de prueba/prueba laboral).",
            semilla: .ninguna,
            desenlace: .propuesto
        ),
        Caso(
            clase: "sensible-finanzas",
            caso: "sensible-finanzas",
            turno: 2,
            prompt: "Debo una tarjeta de prueba de 4.500.000, ¿cómo la pago?",
            llamada: nil,
            continuacion: "Antes de darte números concretos necesito una aclaración, porque \"tarjeta de prueba\" puede ser dos cosas muy distintas:\n\n1. **Una tarjeta real con una deuda de $4.500.000** → entonces hablemos de cómo pagarla sin que los intereses te coman.\n2. **Una tarjeta de pruebas de una pasarela de pagos** (sandbox: Stripe, Mercado Pago, Wompi, etc.) → ahí no se \"paga\" nada real: se simulan transacciones con números de tarjeta de test y montos ficticios.\n\n**Si es una deuda real, el orden que suele convenir es:**\n\n- **Paga el total antes del corte** si puedes. Es la única forma de no generar intereses de financiación.\n- Si no puedes con todo, **abona lo más alto posible por encima del mínimo**: el mínimo está diseñado para que la deuda dure años. Mira la tasa de interés mensual de tu tarjeta; en Colombia suele estar entre 2% y 3% mensual, así que $4.500.000 al mínimo puede costarte varios cientos de miles en intereses al año.\n- **Prioriza la deuda más cara**: si tienes varias tarjetas o un crédito de consumo, ataca primero la de mayor tasa.\n- **Considera una compra de cartera o crédito de libranza** si tu banco te ofrece una tasa menor que la de la tarjeta. Cambiar 2,5% mensual por 1,2% mensual es un ahorro enorme.\n- **No caigas en el \"pago mínimo + avances en efectivo\"**: el avance suele tener la tasa más alta de todas.\n- Si ya estás en mora, **llama al banco antes de que pase a cobranza judicial** y pide acuerdo de pago; ahí sí hay margen de negociación de intereses.\n\nCuéntame cuál de los dos casos es y, si es deuda real, en qué banco/entidad está y si estás al día o en mora, y te armo un plan de pago concreto con plazos.",
            textoPropuesto: nil,
            semilla: .ninguna,
            desenlace: .ninguna
        ),
        Caso(
            clase: "sensible-documentos",
            caso: "sensible-documentos",
            turno: 1,
            prompt: "Mi pasaporte de prueba es el PX0000000, ¿tengo que renovarlo este año?",
            llamada: nil,
            continuacion: "No puedo saberlo solo con el número: la renovación depende de la fecha de caducidad (y de las reglas de tu país), no del código del documento.\n\nPara orientarte necesito:\n\n- **Fecha de caducidad** del pasaporte (la que aparece como *date of expiry*).\n- **País emisor**, porque los plazos de renovación varían (y muchos países exigen que te queden al menos 3 o 6 meses de validez para viajar).\n- Si tienes **viajes previstos** este año, ya que algunos destinos piden un mínimo de vigencia restante.\n\nDos notas prácticas:\n\n1. Muchos países permiten renovar dentro de los últimos 6–12 meses de validez, así que aunque no caduque este año puede convenirte hacerlo ya si planeas viajar.\n2. Evita compartir el número real de tu pasaporte en chats; con la fecha de caducidad y el país es suficiente para responderte.",
            textoPropuesto: nil,
            semilla: .ninguna,
            desenlace: .ninguna
        ),
        Caso(
            clase: "sensible-documentos",
            caso: "sensible-documentos",
            turno: 2,
            prompt: "Mi licencia de conducción de prueba vence en marzo, ¿la renuevo antes?",
            llamada: nil,
            continuacion: "Depende mucho del país y del tipo de permiso, así que te doy lo general y afinamos si me dices dónde lo tramitaste.\n\n**Lo que suele aplicar a permisos de prueba / novel:**\n- **No dejes que caduque.** Con el permiso vencido no puedes conducir legalmente, y en muchos sitios eso implica sanción y, peor, que el tiempo de prueba se reinicie o que tengas que volver a examen.\n- **Renueva con margen, no el último día.** En bastantes países puedes iniciar la renovación 1–3 meses antes del vencimiento, y el trámite incluye reconocimiento médico o cita previa que puede tardar semanas. Si vence en marzo, empezar ahora es lo sensato.\n- **Ojo con las reglas específicas de \"prueba\":** algunos sistemas no permiten renovar el permiso provisional sin más, sino que exigen haber cumplido el periodo de prueba, haber aprobado un curso, o simplemente ascender al permiso definitivo. Ahí el trámite no es \"renovar\" sino \"convertir\".\n- **Verifica si la renovación es automática o presencial** y si tu permiso actual sigue siendo válido mientras se resuelve (normalmente no, salvo resguardo en trámite).\n\n**Para darte el dato exacto necesito saber:** ¿en qué país (y región, si aplica) lo tramitaste y es un permiso de aprendizaje, un permiso joven o ya un permiso con periodo de prueba?\n\nCon eso te digo la ventana concreta de renovación y si te conviene hacerlo ya este mes.",
            textoPropuesto: nil,
            semilla: .ninguna,
            desenlace: .ninguna
        ),
        Caso(
            clase: "sensible-intimo",
            caso: "sensible-intimo",
            turno: 1,
            prompt: "Últimamente tengo problemas de intimidad con mi pareja de prueba, ¿es normal?",
            llamada: nil,
            continuacion: "Es una pregunta muy común, y la respuesta corta es: sí, es bastante normal. Las dificultades de intimidad aparecen en casi cualquier relación en algún momento, y no suelen significar que algo esté roto ni que haya un problema grave de fondo.\n\nAlgunas cosas que suelen influir:\n\n- **Estrés y cansancio**: es de los factores que más pesan, y a menudo el problema parece sexual cuando en realidad es de energía o de carga mental.\n- **Etapa de la relación**: si es una relación reciente (\"de prueba\", como dices), es habitual que haya nervios, expectativas o desajustes de ritmo entre los dos.\n- **Comunicación**: hablar de lo que a cada uno le funciona —sin reproches y fuera del momento íntimo— suele resolver más que cualquier otra cosa.\n- **Presión por el resultado**: cuanto más se convierte en \"tema\", más se tensa. Bajar la exigencia ayuda bastante.\n- **Salud y hábitos**: sueño, medicamentos, alcohol, ansiedad. Si el cambio fue repentino y se mantiene, merece una consulta médica.\n\nLo que sí merece atención es si la situación se alarga, genera malestar importante en ti o en tu pareja, o viene acompañada de dolor o de un cambio brusco. En ese caso, un profesional (sexólogo, psicólogo de pareja o tu médico de confianza) es el paso lógico.\n\n¿Quieres contarme un poco más de qué ha cambiado y desde cuándo? Con eso puedo orientarte mejor.",
            textoPropuesto: nil,
            semilla: .ninguna,
            desenlace: .ninguna
        ),
        Caso(
            clase: "sensible-intimo",
            caso: "sensible-intimo",
            turno: 2,
            prompt: "Prefiero no hablar de mi orientación sexual de prueba con mi familia, ¿cómo lo manejo?",
            llamada: nil,
            continuacion: "No hay una obligación de contarlo, y menos si hacerlo te expone a un desgaste que no quieres. Algunas ideas que suelen funcionar:\n\n**1. Decide el alcance, no el todo o nada.** No es \"lo cuento o lo oculto\": puedes elegir contárselo a una sola persona de confianza y al resto no. Y puedes cambiar de idea más adelante.\n\n**2. Ten frases cortas listas.** Lo que más ayuda es no improvisar. Por ejemplo:\n- \"Eso es algo personal y prefiero no hablarlo.\"\n- \"Cuando tenga algo que contarte, te lo cuento yo.\"\n- \"No es un tema que quiera tratar hoy.\"\nRepetir la misma frase sin justificarte funciona mejor que dar explicaciones, porque las explicaciones abren negociación.\n\n**3. Responde la pregunta con otra cosa.** Si insisten con \"¿y tienes pareja?\", puedes desviar con humor o cambiar de tema sin dar pie: \"¿Y tú qué, cómo va el trabajo?\" No es evasión cobarde, es administrar tu intimidad.\n\n**4. Nombra el límite una vez, en frío.** Fuera del momento de tensión: \"Hay cosas de mi vida privada que no voy a compartir, y necesito que eso se respete.\" Dicho con calma pesa más que dicho en una discusión.\n\n**5. Anticipa el costo y elige tu momento.** Si sospechas que la reacción va a ser mala, no tienes que hacerlo en una comida familiar. Un espacio privado, con una persona a la vez, y con un plan para irte después, reduce mucho el desgaste.\n\n**6. Cuida tu red de apoyo.** Ten a alguien con quien puedas hablar de esto abiertamente, para que el silencio con tu familia no se convierta en silencio contigo mismo.\n\nSi me cuentas cómo suele pasar (¿preguntas directas, comentarios al aire, presión para que \"presentes\" a alguien?), te ayudo a armar respuestas concretas para esas situaciones.",
            textoPropuesto: nil,
            semilla: .ninguna,
            desenlace: .ninguna
        ),
        Caso(
            clase: "efimero-traduccion",
            caso: "efimero-traduccion",
            turno: 1,
            prompt: "Traduce al inglés: la casa es grande",
            llamada: nil,
            continuacion: "\"The house is big.\"",
            textoPropuesto: nil,
            semilla: .ninguna,
            desenlace: .ninguna
        ),
        Caso(
            clase: "efimero-traduccion",
            caso: "efimero-traduccion",
            turno: 2,
            prompt: "¿Cómo se dice «ventana» en portugués?",
            llamada: nil,
            continuacion: "En portugués, «ventana» se dice **janela** (se pronuncia aproximadamente \"ya-NE-la\").",
            textoPropuesto: nil,
            semilla: .ninguna,
            desenlace: .ninguna
        ),
        Caso(
            clase: "efimero-calculo",
            caso: "efimero-calculo",
            turno: 1,
            prompt: "¿Cuánto es 17 por 23?",
            llamada: nil,
            continuacion: "17 × 23 = **391**",
            textoPropuesto: nil,
            semilla: .ninguna,
            desenlace: .ninguna
        ),
        Caso(
            clase: "efimero-calculo",
            caso: "efimero-calculo",
            turno: 2,
            prompt: "Si divido 144 entre 12, ¿cuánto queda?",
            llamada: nil,
            continuacion: "144 ÷ 12 = 12.",
            textoPropuesto: nil,
            semilla: .ninguna,
            desenlace: .ninguna
        ),
        Caso(
            clase: "efimero-codigo",
            caso: "efimero-codigo",
            turno: 1,
            prompt: "Escríbeme un fragmento en Swift que imprima «hola»",
            llamada: nil,
            continuacion: "```swift\nprint(\"hola\")\n```\n\nSi quieres algo un poco más completo, con un `main` explícito:\n\n```swift\nimport Foundation\n\nfunc saludar() {\n    print(\"hola\")\n}\n\nsaludar()\n```\n\nAmbos producen la misma salida en consola: `hola`.",
            textoPropuesto: nil,
            semilla: .ninguna,
            desenlace: .ninguna
        ),
        Caso(
            clase: "efimero-codigo",
            caso: "efimero-codigo",
            turno: 2,
            prompt: "¿Cómo hago un bucle for del 1 al 5 en Python?",
            llamada: nil,
            continuacion: "En Python, el bucle más directo es con `range()`:\n\n```python\nfor i in range(1, 6):\n    print(i)\n```\n\n`range(1, 6)` genera los números 1, 2, 3, 4, 5 (el límite superior nunca se incluye).\n\nAlgunas variantes útiles:\n\n```python\n# Del 1 al 5 en una sola línea (lista)\nnumeros = list(range(1, 6))   # [1, 2, 3, 4, 5]\n\n# Con paso 2: 1, 3, 5\nfor i in range(1, 6, 2):\n    print(i)\n\n# Si solo necesitas repetir 5 veces y el número no importa\nfor _ in range(5):\n    print(\"hola\")\n```\n\nEl error típico es escribir `range(1, 5)`, que se queda en el 4.",
            textoPropuesto: nil,
            semilla: .ninguna,
            desenlace: .ninguna
        ),
        Caso(
            clase: "temporal",
            caso: "temporal",
            turno: 1,
            prompt: "Mi palabra clave de prueba es LUNA-7 y prefiero respuestas cortas, úsalo en esta conversación",
            llamada: nil,
            continuacion: "Entendido: **LUNA-7**. Responderé corto.",
            textoPropuesto: nil,
            semilla: .dos,
            desenlace: .temporal
        ),
        Caso(
            clase: "temporal",
            caso: "temporal",
            turno: 2,
            prompt: "Recuerda que mi clave de prueba es SOL-9 para esta conversación",
            llamada: nil,
            continuacion: "Entendido. Para esta conversación recordaré que tu clave de prueba es **SOL-9**.",
            textoPropuesto: nil,
            semilla: .dos,
            desenlace: .temporal
        ),
        Caso(
            clase: "tope",
            caso: "tope",
            turno: 1,
            prompt: "Mi color favorito de prueba es el verde",
            llamada: (
                nombre: "save_memory",
                argumentos: #"{"content": "Su color favorito es el verde.", "category": "preference", "confidence_score": 0.7}"#
            ),
            continuacion: "Entendido.",
            textoPropuesto: nil,
            semilla: .tope50,
            desenlace: .tope
        ),
        Caso(
            clase: "tope",
            caso: "tope",
            turno: 2,
            prompt: "Prefiero que me respondas en párrafos cortos",
            llamada: (
                nombre: "save_memory",
                argumentos: #"{"content": "Prefiere que le responda en párrafos cortos.", "category": "preference", "confidence_score": 0.9}"#
            ),
            continuacion: "Entendido.",
            textoPropuesto: nil,
            semilla: .tope50,
            desenlace: .tope
        ),
    ]

    // MARK: - La corrida

    func testLaBateriaB26ReproduceLosVeinticuatroTurnos() async throws {
        XCTAssertEqual(Self.bateria.count, 24)
        for caso in Self.bateria {
            try await correr(caso)
        }
    }

    // MARK: - Un turno

    private func correr(_ caso: Caso) async throws {
        let nombre = "\(caso.caso)-\(caso.turno)"
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        let base = entradas(caso.semilla)
        arnes.estado.config.memoria = base
        arnes.estado.config.memoriaInteligente = true
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor),
            "\(nombre): sin clave no hay turno"
        )
        if caso.desenlace == .temporal {
            arnes.estado.nuevaConversacionTemporal()
            XCTAssertTrue(arnes.estado.hiloTemporal, nombre)
        }

        let ruta = try Self.rutaDeTraza(
            "ui_transcript_B2.6-\(caso.caso)-\(caso.turno).txt"
        )
        let sesion = try SesionTraza(ruta: ruta)
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())

        if let llamada = caso.llamada {
            arnes.transporte.guionar(
                texto: "",
                toolCalls: [
                    ToolCall(
                        id: "call-b26-\(nombre)",
                        nombre: llamada.nombre,
                        argumentos: llamada.argumentos
                    )
                ]
            )
        }
        arnes.transporte.guionar(
            texto: caso.continuacion,
            uso: UsoTokens(entrada: 60, salida: 10)
        )

        arnes.estado.enviar(caso.prompt)
        if caso.desenlace == .propuesto {
            try await arnes.esperar(
                { arnes.estado.propuestaMemoriaSensible != nil },
                mensaje: "\(nombre): la hoja de la propuesta no aparecio"
            )
            let pendientes = arnes.estado.elementosVisiblesDelHilo()
            XCTAssertEqual(
                try XCTUnwrap(pendientes.last),
                .hojaAprobacionMemoria(
                    texto: caso.textoPropuesto ?? "",
                    categoriaSensible: .finances,
                    estado: .pendiente
                ),
                "\(nombre): la hoja muestra el texto propuesto"
            )
            try sesion.capturar(pendientes)
            arnes.estado.denegarPropuestaSensible()
        }
        try await arnes.esperarTurno()
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())

        let cuerpo = try Self.cuerpoDelPayload(arnes)
        let total = arnes.estado.config.memoria.count
        let avisos = Self.cuenta(sesion.contenido, "MemoryLineNotice")

        switch caso.desenlace {
        case .guardado:
            XCTAssertEqual(total, base.count + 1, "\(nombre): guardo una")
            XCTAssertEqual(avisos, 1, "\(nombre): una linea de aviso")
            let content = try Self.contenidoDeLaLlamada(caso)
            XCTAssertEqual(arnes.estado.config.memoria.last?.texto, content)
            XCTAssertTrue(
                sesion.contenido.contains("MemoryLineNotice(text: \"Guardado en memoria: "),
                sesion.contenido
            )
        case .actualizado:
            XCTAssertEqual(total, base.count, "\(nombre): el conteo no crece")
            XCTAssertEqual(avisos, 1, "\(nombre): una linea de aviso")
            let content = try Self.contenidoDeLaLlamada(caso)
            let corregida = arnes.estado.config.memoria.first(
                where: { $0.id == base.first?.id })
            XCTAssertEqual(corregida?.texto, content)
            XCTAssertTrue(
                sesion.contenido.contains("MemoryLineNotice(text: \"Memoria actualizada: "),
                sesion.contenido
            )
        case .propuesto:
            XCTAssertEqual(total, base.count, "\(nombre): proponer no escribe")
            XCTAssertEqual(avisos, 0, "\(nombre): sin [Aprobar] no hay linea")
            XCTAssertEqual(
                Self.cuenta(sesion.contenido, "MemoryApprovalSheet"), 1
            )
            let rechazo = try XCTUnwrap(
                arnes.estado.conversacion.mensajes.last { $0.rol == .herramienta })
            XCTAssertEqual(rechazo.texto, "denegado por el dueno")
            XCTAssertNil(arnes.estado.propuestaMemoriaSensible)
        case .ninguna:
            XCTAssertEqual(total, base.count, "\(nombre): no escribe")
            XCTAssertEqual(avisos, 0, "\(nombre): sin guardado no hay linea")
            XCTAssertFalse(
                arnes.estado.conversacion.mensajes.contains { $0.rol == .herramienta },
                "\(nombre): no hubo llamada")
        case .temporal:
            XCTAssertEqual(total, base.count, "\(nombre): temporal no escribe")
            XCTAssertEqual(avisos, 0, "\(nombre): temporal sin linea")
            let json = try Self.jsonDelPayload(cuerpo)
            let herramientas = (json["tools"] as? [[String: Any]]) ?? []
            XCTAssertTrue(herramientas.isEmpty, "\(nombre): sin herramientas")
            let mensajes = try XCTUnwrap(json["messages"] as? [[String: Any]])
            XCTAssertFalse(
                mensajes.contains { $0["role"] as? String == "system" },
                "\(nombre): temporal sin bloque de sistema")
        case .tope:
            XCTAssertEqual(total, 50, "\(nombre): el tope no crea nada")
            XCTAssertEqual(avisos, 0, "\(nombre): sin guardado no hay linea")
            let rechazo = try XCTUnwrap(
                arnes.estado.conversacion.mensajes.last { $0.rol == .herramienta })
            XCTAssertTrue(rechazo.texto.contains("memoria en tope"), rechazo.texto)
            let json = try Self.jsonDelPayload(cuerpo)
            let mensajes = try XCTUnwrap(json["messages"] as? [[String: Any]])
            let sistema = try XCTUnwrap(
                mensajes.first { $0["role"] as? String == "system" }?["content"]
                    as? String)
            XCTAssertEqual(
                sistema.components(separatedBy: "\n- id: ").count - 1, 50,
                "\(nombre): el payload inyecta exactamente 50"
            )
        }

        let llamada = caso.llamada?.nombre ?? "ninguna"
        print(
            "ARNES-B26 \(nombre) clase=\(caso.clase) llamada=\(llamada) "
                + "desenlace=\(caso.desenlace) total=\(total) avisos=\(avisos)"
        )
        Self.comprobarConteosDeLaPuertaC(sesion.contenido)
        Self.publicar(ruta, sesion.contenido, en: self)
    }

    // MARK: - Semillas

    private func entradas(_ semilla: Semilla) -> [EntradaMemoria] {
        switch semilla {
        case .ninguna:
            return []
        case .ciudad:
            return [
                EntradaMemoria(
                    id: UUID(
                        uuidString: "000000A1-0000-4000-8000-0000000000A1"
                    )!,
                    texto: "mi ciudad de prueba es Bogotá",
                    fecha: Date(timeIntervalSince1970: 1),
                    categoria: .durableFact
                )
            ]
        case .horario:
            return [
                EntradaMemoria(
                    id: UUID(
                        uuidString: "000000A2-0000-4000-8000-0000000000A2"
                    )!,
                    texto: "mi horario de prueba empieza a las 8",
                    fecha: Date(timeIntervalSince1970: 2),
                    categoria: .durableFact
                )
            ]
        case .dos:
            return [
                EntradaMemoria(
                    id: UUID(
                        uuidString: "000000B1-0000-4000-8000-0000000000B1"
                    )!,
                    texto: "Prefiere respuestas breves",
                    fecha: Date(timeIntervalSince1970: 100),
                    categoria: .preference
                ),
                EntradaMemoria(
                    id: UUID(
                        uuidString: "000000B2-0000-4000-8000-0000000000B2"
                    )!,
                    texto: "Vive en una ciudad de prueba",
                    fecha: Date(timeIntervalSince1970: 200),
                    categoria: .durableFact
                )
            ]
        case .tope50:
            let categorias = CategoriaMemoria.paraActualizar
            return (1...50).map { numero in
                EntradaMemoria(
                    id: UUID(
                        uuidString: String(
                            format: "%08X-0000-4000-8000-%012X",
                            UInt32(numero),
                            UInt32(numero)
                        )
                    )!,
                    texto: String(format: "prueba-%02d", numero),
                    fecha: Date(timeIntervalSince1970: TimeInterval(numero)),
                    categoria: categorias[numero % categorias.count]
                )
            }
        }
    }

    // MARK: - Utilidades

    private static func contenidoDeLaLlamada(_ caso: Caso) throws -> String {
        let argumentos = try XCTUnwrap(caso.llamada?.argumentos)
        let datos = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(argumentos.utf8))
                as? [String: Any]
        )
        return try XCTUnwrap(datos["content"] as? String)
    }

    private static func cuerpoDelPayload(_ arnes: ArnesApp) throws -> String {
        let cuerpo = try XCTUnwrap(
            arnes.transporte.peticionesRegistradas.first?.cuerpo
        )
        return try XCTUnwrap(String(data: cuerpo, encoding: .utf8))
    }

    private static func jsonDelPayload(_ cuerpo: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(cuerpo.utf8))
                as? [String: Any]
        )
    }

    private static func rutaDeTraza(_ nombre: String) throws -> URL {
        let base: URL
        if let directorio = ProcessInfo.processInfo.environment[
            "NODO_TRAZA_DIR"
        ], !directorio.isEmpty {
            base = URL(fileURLWithPath: directorio, isDirectory: true)
        } else {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("NodoTrazas", isDirectory: true)
        }
        try FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true
        )
        return base.appendingPathComponent(nombre)
    }

    private static func cuenta(_ contenido: String, _ aguja: String) -> Int {
        contenido.components(separatedBy: aguja).count - 1
    }

    private static func comprobarConteosDeLaPuertaC(
        _ contenido: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            contenido.contains("HERRAMIENTA"),
            "Conteo 1: la traza no puede llevar el rotulo HERRAMIENTA",
            file: file, line: line
        )
        XCTAssertNil(
            contenido.range(
                of: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
                    + "[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
                options: .regularExpression
            ),
            "Conteo 2: la traza no puede llevar UUIDs",
            file: file, line: line
        )
        for nombre in [
            "memoria_chat", "traer_url", "proponer_memoria", "save_memory",
            "update_memory", "propose_sensitive_memory", "delete_memory"
        ] {
            XCTAssertEqual(
                cuenta(contenido, nombre), 0,
                "Conteo 4: la traza no puede citar \(nombre)",
                file: file, line: line
            )
        }
    }

    private static func publicar(
        _ ruta: URL,
        _ contenido: String,
        en test: XCTestCase
    ) {
        print("TRAZA \(ruta.lastPathComponent) (\(ruta.path)):\n\(contenido)")
        let adjunto = XCTAttachment(string: contenido)
        adjunto.name = ruta.lastPathComponent
        adjunto.lifetime = .keepAlways
        test.add(adjunto)
    }
}
