# Documento Maestro DEFINITIVO — El Gran Avance de Nodo

**Qué es este documento:** la spec completa y cerrada del próximo salto de Nodo, estilo generart: todo definido antes de construir, con pasos que se cumplen y se marcan uno por uno. Pablo lo aprueba ENTERO; sin su aprobación no se escribe una línea de código. Esta es la versión definitiva: incorpora la conciliación de la Ronda 2 (ver §0) ya aplicada en el texto — no hay notas al margen ni correcciones pendientes.
**Fuentes:** auditoría UX de Gemini Argon, Ronda 1 (auditoria-argon-respuesta.md) · grill de pacho (grill-auditoria-argon.md) · **grill adversarial de Argon, Ronda 2 (grill-ronda2-respuesta.md): 12 hallazgos + Parte B, aceptados por pacho en la conciliación** · defectos del dueño (pruebas-v0.2.md) · reglas de construcción (CONSTRUCCION.md) · plan de funciones aprobado (sintesis-nodo.md).
**Regla de cifras:** ningún número de este documento es un dato. Los precios, topes y costos que la app muestre salen SOLO de la configuración real de pablo (hoy: tope de aviso $1.00 por chat; precios de referencia del combo DeepSeek en InferHub $0.03 entrada / $0.12 salida por millón, cuando él los cargue). Los ejemplos de Argon eran ilustrativos y quedan fuera.

---

## 0. Conciliación de la Ronda 2 — qué cambió y por qué

Argon, actuando como revisor hostil del Documento Maestro v1, le dio un **0.65 global** y presentó 12 hallazgos (7 graves, 5 menores) más una Parte B de huecos e innovación aplicable. **Veredicto de pacho: se aceptan los 12 hallazgos tal como Argon los corrigió, y se integra la Parte B en lo indicado.** Este documento ES la v1 con todo eso aplicado. Resumen de los cambios:

**Por los hallazgos (Parte A):**
- **H1 — El medidor mentía:** §4.1 mezclaba dos métricas incompatibles. Ahora quedan separadas por escrito: el **acumulado facturable del chat** (suma histórica de usos; para el costo en dólares; nunca baja) y la **ocupación de la ventana** (numerador = `total_tokens` SOLO de la última respuesta; es lo único que mide el medidor y lo único que baja tras /compact).
- **H2 — Cabecera físicamente imposible:** cinco controles no caben en 393 pt. La cabecera queda con **solo tres elementos** (← Chats | píldora del modelo | •••); el conmutador Chat|Tarea y el acceso a Memoria bajan a una **tira fina de cápsulas sobre la caja de texto**.
- **H3 — Contradicción modelos/proveedor:** §3.6/§3.7 hablaban de "sus modelos" con un modelo de datos de 1 modelo por registro. Ahora Conexiones **agrupa por URL base** con una fila por registro, y existe el botón **+ Añadir modelo/combo** que duplica nombre, URL y clave.
- **H4 — El parser de "/" chocaba con las skills:** §4.2 + §4.4 comparten ahora **una sola gramática** (comando del sistema / skills adjuntas / token desconocido con aviso), con slugs normalizados, 5 nombres reservados y la regla de que **jamás se envía un turno vacío**.
- **H5 — La regla de teclado rompía SwiftUI:** §2.2/§2.4 prohíben el `.onTapGesture` global sobre contenedores con listas o botones, exigen ScrollView/Form en toda vista con campos, blindan las hojas con `.interactiveDismissDisabled(hayCambios)` y declaran la barra de teclado **una sola vez por jerarquía**.
- **H6 — Fases con retrabajo y dependencias rotas:** el parser nace en la Fase 3.5 **ya con el gancho de skills**; Chat sin memoria tiene **tarea numerada propia en la Fase 2**; Compactar entra al menú ••• recién en la Fase 3; la Fase 1 solo blinda el teclado de la pantalla vieja de Ajustes **sin invertir en su diseño** (su reconstrucción es la Fase 4); la cabecera usa **`.toolbar` nativo** para no romper el gesto de borde.
- **H7 — Criterios imposibles en CI:** los 5 criterios no verificables se reemplazan por **verificaciones deterministas** (migración con estado v0.2.0 de PRUEBA inyectado; modo Tarea en dos capturas secuenciales; skill verificada por su etiqueta ⚡ + test de inyección en el payload, nunca por el texto del LLM; dictado tras el protocolo `SpeechRecognizing` con mock). Y se **define "herramienta con consecuencias"**: toda llamada MCP y todo HTTP que no sea GET abre hoja de aprobación; la lista blanca está vacía por defecto.
- **H8 — [Subir tope] sin acción definida:** ahora abre un menú con los escalones por encima del tope actual y actualiza el **tope global**; [Seguir igual] marca solo ese chat (`topeIgnorado`) sin tocar el global.
- **H9 — Chat sin memoria con promesas falsas:** se borra "nada de lo hablado se guarda en la memoria" (la Memoria es un texto manual); la activación al crear vive en un **conmutador de la Tarjeta de Bienvenida** y en mantener pulsado **+ Nuevo**; apagarla a mitad de chat inserta el divisor visual de aviso.
- **H10 — Conteo de tokens de la Memoria imposible offline:** el peso pasa a ser **estimación con ~** (`max(1, caracteres/4)`), y el costo por envío se calcula con el `inputPrice` del **proveedor activo**, rotulado con su modelo.
- **H11 — Eventos locales que contaminarían la API:** regla nueva (§2.6): divisores, salidas de /costo y avisos son **metadatos puramente visuales** y se filtran SIEMPRE antes de construir el arreglo `messages` que sale a la API.
- **H12 — Cancelar vs Cerrar contradictorio:** nomenclatura única — hoja que edita con Guardar = **Cancelar**; hoja de solo consulta sin Guardar = **Cerrar**.

**Por la Parte B (huecos e innovación aplicable):**
- **Preset InferHub** (la decisión del Anexo A1 pasa al cuerpo como decisión cerrada): nace con **clave compartida por host** (pegarla una vez la propaga a los 4 combos), la Tarjeta de Bienvenida muestra **⚠️ Falta tu clave** — nunca un falso "conectado" — con el botón **[📋 Pegar clave desde el portapapeles]**, y el preset se siembra en la **Fase 2**, no en la 4.
- **Respaldo en 1 toque:** Exportar/Importar la configuración completa (JSON vía ShareLink) al final de Conexiones — la supervivencia ante revocaciones de certificado de ESign.
- **Acumulador de gasto global** en Mi Contexto: "Hoy $X · Desde el último reinicio $Y [Reiniciar]", inmune al borrado de chats.
- **Errores en línea:** burbuja de error con [Reintentar] y [Cambiar modelo y reintentar]; el texto del usuario **nunca se pierde**; selección de texto en las respuestas y botón Copiar en los bloques de código.
- **Selector flotante de "/"**: skills arriba, comandos abajo, píldoras ⚡ activas sobre la caja — es el diseño visible del parser.
- **Regenerar con otro combo** (mantener pulsado ↻) y **Ramificar chat desde aquí**.
- **Descartadas con motivo** (quedan en §7): tokenizador BPE local, ejecución en segundo plano/programada, auto-extracción de memoria en silencio.

**Lo que NO cambió:** el motor no se toca (§7); sigue siendo **un modelo por proveedor** en los datos (la agrupación es solo visual); **Proyectos sigue FUERA** del gran avance; una sola IPA al final; ninguna cifra sale de otro sitio que la configuración real del dueño.

---

## 1. Qué es el gran avance

El gran avance es UNA sola entrega que reúne dos cosas que la v0.2.0 dejó separadas: **la cara nueva** — el contrato de diseño de la §2 aplicado a todas las pantallas, que corrige los dos defectos bloqueantes que pablo encontró al probar la v0.2.0 (el teclado numérico que atrapa y la conversación sin salida visible) y saca a la luz, en la propia conversación, todo lo que el motor ya calcula en silencio (modelo activo, memoria activa, tokens y costo) — y **las funciones del plan aprobado montadas sobre esa cara nueva** (medidor de contexto, compactación y comandos, modo Tarea, skills locales, dictado y chat sin memoria), cada una instalada en la pantalla que se reconstruye para ella, una sola vez. A eso la Ronda 2 sumó tres piezas de supervivencia y control que nacen con la cara nueva: el **preset de InferHub** con clave compartida (§3.6), el **respaldo exportable de toda la configuración** (§4.8) y el **acumulador de gasto global** (§3.5). No hay versiones intermedias instalables ni vueltas de instalar-probar: se construye por fases internas con tests y capturas verificadas en cada una, y al final llega **una única IPA** lista para instalar encima de la actual.

---

## 2. Contrato de diseño — las leyes del producto

Estas leyes mandan sobre cualquier pantalla nueva o reconstruida. Toda sesión de construcción las cumple y pacho revisa contra ellas. Si una pantalla no puede cumplir una ley, la pantalla está mal diseñada y se corrige antes de seguir.

### 2.1 Frase guía (adoptada de la auditoría, con el añadido de la casa)

> "Todo lo que el motor calcula por dentro debe verse vivo en la conversación sin ir a buscarlo a Ajustes, y ninguna pantalla ni teclado puede abrirse jamás sin mostrar arriba su puerta de salida." — **y ninguna cifra se muestra si no sale de la configuración real del dueño.**

### 2.2 Regla anti-callejones: toda superficie tiene entrada y salida escritas

Ninguna pantalla, hoja o teclado existe sin su salida definida. Sin excepciones, y también con el teclado abierto:

| Superficie / estado | Cómo se entra | Cómo se SALE (sin excepciones) |
|---|---|---|
| Conversación | Tocando un chat en la pestaña Chats o con el botón Nuevo Chat. | Botón **← Chats** fijo arriba a la izquierda (la barra superior nunca se oculta ni se desplaza cuando sube el teclado) + gesto nativo desde el borde izquierdo. Volver cierra el teclado durante la transición. |
| Hoja Estado del chat | Desde el menú ••• de la cabecera de la conversación. | Botón **Cerrar** arriba a la izquierda (es hoja de solo consulta, §2.3) o arrastrar la hoja hacia abajo. |
| Hoja Memoria rápida | Tocando el icono 🧠 en la tira fina sobre la caja de texto (§3.2). | **Cancelar** arriba a la izquierda (es hoja de edición con Guardar, §2.3), **Guardar** arriba a la derecha. Arrastrar hacia abajo solo la cierra si NO hay cambios sin guardar (§2.4). |
| Editor de proveedor (hoja modal) | Desde Conexiones: tocar una fila de proveedor o "+ Añadir modelo/combo" / "+ Añadir proveedor". | **Cancelar** arriba a la izquierda (descarta cambios y baja el teclado en el acto), **Guardar** arriba a la derecha. Arrastrar hacia abajo solo cierra si NO hay cambios sin guardar (§2.4). |
| Configuración MCP (hoja modal) | Tocando la tarjeta MCP en Conexiones. | Cancelar arriba a la izquierda, Guardar arriba a la derecha. Arrastrar hacia abajo solo cierra si NO hay cambios sin guardar (§2.4). |
| Aprobación de herramienta (modo Tarea) | Aparece sola cuando una herramienta con consecuencias (§4.3) va a ejecutarse. | Dos salidas claras y solo dos: **Aprobar** o **Rechazar**. Nunca queda colgada ni se cierra por accidente sin decidir. |
| Cualquier campo de texto o número (tope, precios, buscador, memoria, caja del chat) | Tocando dentro del campo. | **Triple seguro obligatorio:** 1) botón **Listo** en la barra pegada sobre el teclado; 2) arrastre interactivo hacia abajo que esconde el teclado; 3) toque en una zona fuera del campo que no tenga controles. El seguro 3 se implementa SIN gestos globales que intercepten listas o botones (§2.4). |

**Protección de hojas (regla de la Ronda 2):** toda hoja con botón Guardar lleva `.interactiveDismissDisabled(hayCambiosSinGuardar)`. Mientras haya cambios sin guardar, arrastrar hacia abajo **baja el teclado y nada más** — la hoja nunca se cierra por accidente perdiendo lo escrito; para salir descartando está el botón explícito Cancelar.

**Descartado expresamente:** el "globo numérico" sobre el botón ← Chats que proponía Argon. Ruido sin función en una app de un solo usuario.

### 2.3 Las 4 leyes de botones

| # | Acción | Dónde va SIEMPRE | Cómo se ve | Comportamiento exacto |
|---|---|---|---|---|
| 1 | Volver atrás | Esquina superior izquierda. | Flecha + nombre de la pantalla anterior: **← Chats**. | Regresa a la pantalla previa; si el teclado estaba abierto, lo cierra en la transición. También funciona el gesto desde el borde izquierdo. |
| 2 | Cancelar / Cerrar (hojas modales) | Esquina superior izquierda de la hoja. | Texto simple en el color de acento: **Cancelar** si la hoja edita datos y tiene Guardar a la derecha; **Cerrar** si la hoja es de solo consulta y no tiene Guardar. Sin excepciones ni mezclas (§0, H12). | Cancelar: descarta cualquier cambio a medio escribir, baja el teclado si estaba abierto y cierra la hoja de inmediato. Cerrar: cierra la hoja de consulta. |
| 3 | Confirmar / Guardar | Esquina superior derecha. | **Guardar** en negrita o píldora rellena. **Deshabilitado (gris) si no se ha modificado nada**; activo en cuanto cambia una letra o un número. | Guarda en el almacenamiento local, cierra el teclado, da un toque háptico suave y cierra la hoja (o muestra ✓ Guardado si es una pestaña). |
| 4 | Cerrar el teclado | Barra horizontal pegada justo encima del teclado, botón a la derecha. | **Listo** en negrita (o icono de teclado con flecha hacia abajo). | Esconde el teclado en el acto y deja la pantalla completa visible, sin borrar ni perder lo escrito. |

### 2.4 Regla técnica de teclado en SwiftUI (obligatoria, sin excepciones)

En iOS, los teclados `.decimalPad` y `.numberPad` **no traen tecla de retorno ni de cierre**: ningún campo con esos teclados puede existir suelto. Las reglas, ya corregidas por la Ronda 2 (H5) para que funcionen en SwiftUI real:

- **Toda vista con campos de entrada vive dentro de un `ScrollView` o un `Form`.** Sin desplazamiento vertical no hay dónde arrastrar y `.scrollDismissesKeyboard(.interactively)` no tiene efecto real: la vista entera debe poder rebotar aunque quepa en pantalla.
- **Los dos modificadores base:** `.scrollDismissesKeyboard(.interactively)` — el usuario baja el teclado empujándolo hacia abajo con el dedo, como en iMessage o WhatsApp — y la barra sobre el teclado con el botón **Listo**.
- **La barra de teclado se declara UNA sola vez por jerarquía de navegación** (`ToolbarItemGroup(placement: .keyboard)` en la vista raíz de la jerarquía). Prohibido duplicarla en la vista padre y en la subvista activa a la vez: UIKit genera barras accesorias duplicadas y alertas.
- **PROHIBIDO el `.onTapGesture` global** sobre contenedores que tengan una `List` o botones hijos: el gesto del padre intercepta o retrasa los toques sobre las filas, los botones y el botón Enviar. El seguro "tocar fuera del campo" se logra con el fondo del propio ScrollView/Form, nunca con un gesto que envuelva controles.
- **Toda hoja con botón Guardar lleva `.interactiveDismissDisabled(hayCambiosSinGuardar)`** (ver §2.2): el arrastre para bajar el teclado jamás puede cerrar la hoja ni perder cambios.

Esta regla nace del defecto n.º 1 de la v0.2.0 (tres campos `.decimalPad` sin una sola barra de teclado en toda la app) y es el primer arreglo del plan de construcción.

### 2.5 Regla de nombres limpios

La cabecera del chat muestra **con quién se está hablando**, nunca la plantilla técnica:

- **El modelo manda limpio:** la píldora muestra el nombre limpio del modelo del proveedor activo. Si el identificador trae prefijo con barra (p. ej. `vendedor/modelo`), se recorta todo lo anterior a la barra. Si pablo le puso un apodo al modelo, **el apodo manda** sobre el identificador.
- **Sin reestructurar la configuración:** el modelo de datos NO cambia — sigue siendo **un modelo por proveedor** (así es `ProviderConfig` hoy: un registro = un modelo). La píldora y su menú muestran el nombre limpio del modelo **de cada proveedor**, con el proveedor como subtítulo. La agrupación visual por dominio en Conexiones (§3.6) no altera este modelo: por fuera se ve ordenado; por dentro nadie toca la configuración.
- **El proveedor nunca se llama "Compatible":** si el nombre guardado de un proveedor es "Compatible" o está vacío, la app deriva el nombre del dominio de su URL configurada (de `https://api.inferhub.dev/v1` deriva **InferHub**) y lo muestra así en todas partes. Pablo puede renombrarlo cuando quiera; el nombre derivado solo aparece mientras no le ponga uno propio.
- **La palabra "Compatible" no aparece en ninguna pantalla** del producto terminado.

### 2.6 Eventos locales del hilo: metadatos puramente visuales (regla nueva, H11)

La conversación muestra cosas que NO son mensajes: el divisor ── Ahora responde X ──, el divisor ── Memoria desactivada desde este mensaje ──, la salida de /costo y los avisos del parser. **Todos esos eventos son metadatos de interfaz, puramente visuales:**

- Se pintan en la lista de la conversación, pero **se filtran SIEMPRE antes de construir el arreglo `messages` que se envía al cliente HTTP**. Jamás viajan a la API como rol `system` ni `assistant`: gastarían tokens y romperían la alternancia de roles en modelos estrictos.
- La regla aplica a toda tarea que toque el hilo (en especial las tareas 2.4 y 3.5 del plan): si un evento local puede acabar dentro del payload, la tarea está mal hecha.

---

## 3. Mapa de pantallas

La raíz de la app pasa a ser una barra de **3 pestañas inferiores** (TabView nativo), cada una con su propia pila de navegación (NavigationStack). La causa raíz del encierro en la v0.2.0 era estructural: la conversación y la lista vivían en pestañas hermanas, así que no existía un "atrás". En el nuevo mapa, la lista es la raíz de la pestaña Chats y la conversación se empuja **dentro de la misma pila**.

- **Pestaña 1 — Chats** (icono de burbujas): la lista de conversaciones y, empujada encima, la conversación.
- **Pestaña 2 — Mi Contexto** (icono de cerebro o controles): Memoria, Tope de gasto y Skills.
- **Pestaña 3 — Conexiones** (icono de red o engranaje): solo fontanería — Proveedores, MCP y, al final, el Respaldo. La vieja pantalla de Ajustes desaparece como mezcla.

Para cada pantalla: qué se ve primero, sus acciones con su salida, y los **criterios de aceptación** — lo que debe verse en la captura del simulador para darla por buena. Sin captura que cumpla, la pantalla no está terminada. Todos los criterios son **deterministas en CI**: donde una verificación necesitaría datos reales, claves reales, un micrófono o el texto de un LLM, el criterio lo dice y usa datos de prueba, mocks o tests unitarios (§0, H7).

### 3.1 Pestaña Chats — la lista

- **Qué se ve primero:** título grande **Chats** y botón **+ Nuevo** bien visible arriba a la derecha; buscador siempre visible bajo el título ("Buscar en tus conversaciones…"); segmento **Activos | Archivados** bajo el buscador; la lista con los **fijados arriba** y los recientes debajo.
- **Cada fila:** línea 1 con el título del chat en negrita y, a la derecha, la pastilla con el **costo acumulado de ese chat** (la métrica facturable de §4.1: suma histórica de usos; solo cuando el proveedor tenga precios configurados — sin precios no se muestra cifra alguna). Línea 2: vista previa del último mensaje + etiqueta del **último modelo usado** en esa conversación (nombre limpio, §2.5).
- **Acciones y salida:** deslizar a la derecha = 📌 Fijar/Desfijar; deslizar a la izquierda = Archivar (gris) y Borrar (rojo); pulsación larga = menú con Fijar, Renombrar, Archivar y Borrar; **mantener pulsado + Nuevo = crear directamente un chat sin memoria** (§4.6); tocar una fila entra a la conversación (§3.2), de donde se sale con ← Chats.
- **Criterios de aceptación (captura del simulador):**
  - [ ] Se ven título, botón + Nuevo, buscador y segmento Activos | Archivados sin hacer scroll.
  - [ ] Al menos un chat fijado aparece arriba, marcado como fijado.
  - [ ] Una fila muestra título, pastilla de costo y segunda línea con vista previa + etiqueta de modelo limpio.
  - [ ] En el segmento Archivados se ven los chats archivados y en Activos no aparece ninguno archivado.
  - [ ] La captura del menú de pulsación larga muestra exactamente: Fijar, Renombrar, Archivar, Borrar.

### 3.2 La conversación

La cabecera queda **descongestionada** (§0, H2): cinco controles no caben en los 393 pt de un iPhone sin truncarse ni violar el área mínima de toque de 44×44 pt. La barra superior lleva **solo tres elementos amplios**, y el resto baja a una tira fina sobre la caja de texto, al estilo de Claude/Gemini.

- **Qué se ve primero — cabecera fija en 3 elementos** (clavada: nunca se oculta ni se desplaza con el teclado abierto; se construye con el `.toolbar` nativo de NavigationStack, §5 paso 2.1):
  - **Izquierda:** ← Chats (ley de botones n.º 1, con el gesto de borde izquierdo funcionando).
  - **Centro:** píldora selectora con el **nombre limpio del modelo** activo y la flecha ▾, en negrita; justo debajo, en letra pequeña gris: **proveedor · costo acumulado del chat** (la métrica facturable de §4.1; el costo solo si hay precios configurados) **· 🧠 con punto verde integrado cuando la Memoria está activa en este chat** (sin punto si la memoria está vacía o el chat es sin memoria).
  - **Derecha:** únicamente el menú **•••** (Estado del chat, Fijar, Archivar, Chat sin memoria, Borrar; **Compactar se suma a este menú en la Fase 3**, junto con /compact — §5).
- **Tira fina de cápsulas — justo encima de la caja de texto:** a la izquierda, el conmutador compacto **Chat | Tarea** (§4.3); a la derecha, el botón **🧠** (con el mismo punto verde del subtítulo) que abre la **Hoja Memoria rápida** (§3.4) sin salir de la conversación. Sobre esta tira aparecen además, solo cuando aplican, la franja ámbar de tope, el selector flotante de "/" y las píldoras ⚡ de skills activas (§4.2/§4.4).
- **Cambio de modelo en 2 toques:** toque 1 en la píldora despliega un menú nativo sin cambiar de pantalla y sin perder lo escrito en la caja: lista de proveedores con el nombre limpio de su modelo, una referencia de costo cuando haya precios, ✓ en el activo, y al final, separada, la opción **Gestionar modelos…** (lleva a Conexiones). Toque 2 elige otro: la cabecera cambia al instante y en la conversación se inserta el divisor **── Ahora responde X ──** (evento visual, §2.6); el cambio aplica desde el siguiente mensaje conservando todo el historial.
- **Estado vacío:** si el chat no tiene mensajes, en el centro va la **Tarjeta de Bienvenida del Motor** en vez de una pantalla muda; desaparece al enviar el primer mensaje. La tarjeta se alimenta **solo de la configuración real** y tiene dos estados honestos:
  - **Con clave guardada:** muestra modelo activo real, proveedor real, memoria activa solo si tiene texto, tope vigente real, con [Cambiar modelo] y [Ver o editar mi memoria].
  - **Sin clave (clave vacía en el proveedor activo — el estado exacto tras instalar con el preset, §3.6):** la tarjeta muestra **⚠️ Falta tu clave de InferHub** — jamás dice "conectado" — con el botón destacado **[📋 Pegar clave desde el portapapeles]**: al tocarlo lee el portapapeles, valida que no esté vacío, guarda la clave con la regla de clave compartida por host (§3.7), confirma con un toque háptico y deja la tarjeta en estado conectado, lista para chatear. Sin entrar a Conexiones ni abrir formularios.
  - La tarjeta incluye además el conmutador **Memoria en este chat: [Activa | Apagada]** (§4.6), visible mientras el chat tiene 0 mensajes.
- **Cuerpo:** burbujas de mensaje con **selección de texto activada** (se puede seleccionar y copiar un párrafo suelto de cualquier respuesta) y, en los bloques de código, un botón **Copiar código** en la esquina del bloque. Debajo de **cada respuesta del asistente**, el pie con tokens y costo (§4, visibilidad), incluido **↻ Regenerar**: **mantener pulsado ↻** despliega **Regenerar con…** con los demás modelos configurados, para regenerar esa respuesta con otro combo en un solo gesto. **Mantener pulsada cualquier burbuja** ofrece **🔀 Ramificar chat desde aquí** (§5, Fase 5): clona los mensajes hasta ese punto en una conversación nueva y entra en ella. Durante el streaming, la respuesta se ve llegar palabra por palabra.
- **Errores en línea (Parte B):** si una petición falla (corte de red, timeout, 429/502, clave inválida), la respuesta fallida se muestra como **burbuja de error** en el hilo con **[Reintentar]** y **[Cambiar modelo y reintentar]** ahí mismo. **El texto del usuario nunca se pierde**: el mensaje que falló queda intacto y disponible para reintentar o copiar, sin volver a escribirlo ni dictarlo. La burbuja de error es un evento visual (§2.6): no viaja a la API.
- **Aviso de tope:** si el costo acumulado del chat supera el tope vigente, aparece una **franja ámbar** justo encima de la caja de texto avisándolo, con [Subir tope] y [Seguir igual] ahí mismo — nadie tiene que ir a otra pestaña para resolverlo. Comportamiento exacto (§0, H8): **[Subir tope]** despliega un menú con los escalones por encima del tope actual; elegir uno **actualiza el tope GLOBAL** de la app y reevalúa la franja al instante. **[Seguir igual]** marca **solo ese chat** como `topeIgnorado` (ese chat no vuelve a avisar) y **no toca el tope global** ni el comportamiento de los demás chats.
- **Caja de texto inferior:** campo autoexpansible de 1 a 5 líneas, botón de **micrófono** (dictado, §4.5) y botón **Enviar (↑)** que durante el streaming se convierte en **Detener (■)**.
- **Salida:** ← Chats o gesto de borde izquierdo, también con el teclado abierto (leyes §2.2 y §2.3).
- **Criterios de aceptación (capturas del simulador):**
  - [ ] Con el teclado abierto, la captura muestra la cabecera COMPLETA y despejada: solo ← Chats a la izquierda, la píldora con nombre limpio de modelo (sin prefijos, jamás "Compatible") en el centro y ••• a la derecha — sin conmutador ni iconos extra en la barra superior.
  - [ ] El subtítulo de la píldora muestra el nombre limpio del proveedor, el costo acumulado del chat (con precios configurados) y el indicador 🧠 con punto verde cuando la memoria está activa.
  - [ ] La captura de la tira fina muestra el conmutador Chat | Tarea y el botón 🧠 sobre la caja de texto.
  - [ ] La captura del menú de la píldora muestra la lista con ✓ en el activo y Gestionar modelos… al final.
  - [ ] Tras cambiar de modelo, la captura muestra el divisor ── Ahora responde X ── dentro de la conversación.
  - [ ] En un chat vacío con clave guardada se ve la Tarjeta de Bienvenida con los datos reales; tras el primer mensaje, ya no está.
  - [ ] En un chat vacío con la clave vacía (estado simulado del preset recién instalado) la tarjeta muestra ⚠️ Falta tu clave y el botón [📋 Pegar clave desde el portapapeles] — y en ninguna parte dice "conectado".
  - [ ] La captura de la franja de tope muestra [Subir tope] y [Seguir igual]; el menú de [Subir tope] muestra solo escalones por encima del tope actual.
  - [ ] La captura de una respuesta con bloque de código muestra su botón Copiar código, y el menú de mantener pulsado ↻ muestra la opción Regenerar con… con los demás modelos.
  - [ ] Ninguna captura de esta pantalla muestra la palabra "Compatible".

### 3.3 Hoja Estado del chat (desde •••)

- **Qué se ve primero:** las **dos métricas de §4.1, separadas y rotuladas** — arriba, **Ocupación de la ventana**: el medidor de contexto (tokens de la última respuesta contra la ventana del modelo, en barra y en cifra); debajo, **Consumo acumulado del chat**: la suma histórica de usos (tokens y costo cuando haya precios), que es la cifra facturable y **nunca baja**. Ninguna de las dos se presenta como si fuera la otra.
- **Acciones y salida:** editar la ventana del modelo en la **tabla de ventanas** (§4.1); salir con **Cerrar** (hoja de solo consulta, §2.3) o arrastrando hacia abajo (§2.2).
- **Criterios de aceptación:**
  - [ ] La captura muestra AMBAS secciones rotuladas por separado: "Ocupación de la ventana" y "Consumo acumulado del chat", con cifras coherentes entre sí (la ocupación nunca supera al acumulado en un chat de varios turnos).
  - [ ] Sin ventana definida para el modelo: se muestran los tokens y la invitación a definirla; **no** se muestra porcentaje fabricado.
  - [ ] La tabla de ventanas es editable desde esta hoja y el cambio se refleja en el medidor.

### 3.4 Hoja Memoria rápida (desde 🧠 en la tira fina)

- **Qué se ve primero:** el texto actual de la Memoria, listo para editar, sin salir de la conversación.
- **Acciones y salida:** **Cancelar** arriba a la izquierda (descarta — es hoja de edición con Guardar, §2.3/H12), **Guardar** arriba a la derecha (ley n.º 3). Arrastrar hacia abajo solo cierra si no hay cambios sin guardar (§2.4). El teclado cumple la regla §2.4.
- **Criterios de aceptación:**
  - [ ] La captura muestra la hoja sobre la conversación, con **Cancelar** y Guardar en sus esquinas (nunca "Cerrar" en una hoja de edición).
  - [ ] Con el teclado abierto se ve la barra con el botón Listo.
  - [ ] Con cambios sin guardar, la captura de un intento de arrastre muestra la hoja todavía abierta con el texto intacto.

---

### 3.5 Pestaña Mi Contexto

La pestaña que desentierra las dos funciones estrella de la v0.2.0 y les suma las skills. Tres bloques, en este orden. Toda la pestaña vive dentro de un ScrollView/Form (§2.4) para que el teclado siempre pueda bajarse.

- **Bloque 1 — Memoria:** explicación en lenguaje llano ("Lo que escribas aquí se envía automáticamente a todos los modelos para que te conozcan sin que tengas que presentarte en cada chat"), cuadro de edición amplio con Cancelar/Guardar, e **indicador de peso estimado**: como no existe conteo exacto de tokens sin conexión (un tokenizador real engordaría la app, §7), el peso se calcula con una heurística ligera — **`~N tokens est.` con N = max(1, caracteres / 4)** cuando la memoria no está vacía — siempre precedido del símbolo **~**. El costo por envío estimado, cuando se muestra, se calcula con el **precio de entrada (`inputPrice`) del proveedor actualmente activo** y se **rotula con el nombre limpio de ese modelo** (p. ej. "≈ calculado con DeepSeek V4.1 Flash"); sin precios en el proveedor activo, no se muestra costo.
- **Bloque 2 — Tope de gasto por chat:** explicación llana ("Te avisaremos dentro de la conversación si un solo chat supera este monto") y **selector sin teclado**: botones rápidos **[$0.10] [$0.25] [$0.50] [$1.00] [Otro…]** con el valor vigente de pablo marcado como seleccionado. "Otro…" abre el campo numérico — con la barra Listo garantizada (§2.4). Poner 0 sigue significando "sin aviso". Justo encima de los botones va la línea del **acumulador de gasto global** (Parte B): **"Gasto acumulado: Hoy $X · Desde el último reinicio: $Y [Reiniciar contador]"** — dos contadores locales que suman cada `usage` recibido en cualquier chat y **sobreviven al borrado de conversaciones** (borrar un chat no resta su gasto). El botón [Reiniciar contador] pone a cero solo el acumulado "desde el último reinicio" (el de "Hoy" se reinicia solo al cambiar el día).
- **Bloque 3 — Skills:** la biblioteca de instrucciones con nombre (§4.4): lista, crear, editar y borrar.
- **Salida:** es una pestaña raíz; se sale tocando otra pestaña. Todo campo cumple §2.4.
- **Criterios de aceptación:**
  - [ ] Una sola captura (o dos con scroll mínimo) muestra los tres bloques: Memoria, Tope y Skills.
  - [ ] El indicador de peso de la Memoria se muestra con el símbolo ~ y, si hay costo estimado, rotulado con el nombre del modelo del proveedor activo usado para calcularlo.
  - [ ] La línea del acumulador global se ve encima de los botones del tope, con las cifras de Hoy y Desde el último reinicio y el botón [Reiniciar contador].
  - [ ] El botón del tope vigente aparece marcado como seleccionado, y corresponde al valor real configurado.
  - [ ] La captura del editor de memoria muestra Cancelar y Guardar; con el teclado abierto, la barra Listo.
  - [ ] **Migración verificada con datos de PRUEBA (H7):** un test de migración inyecta el esquema de almacenamiento de la v0.2.0 con una memoria y un tope de prueba, y la captura muestra esos valores cargados sin pérdida en la cara nueva. (Los datos reales de pablo jamás entran a CI: §6 lo prohíbe.)

### 3.6 Pestaña Conexiones

- **Qué se ve primero:** la sección **Mis Proveedores de IA** con **tarjetas agrupadas por URL base** (§0, H3): cada dominio configurado tiene UNA tarjeta con su encabezado (nombre limpio del proveedor, §2.5 — derivado del dominio si quedó genérico) y, dentro, **una fila por cada registro de configuración**: la etiqueta con el nombre limpio de su modelo/combo y sus precios si los tiene. Tocar una fila abre el Editor de ese registro (§3.7). Al final de cada tarjeta, el botón **+ Añadir modelo/combo a este proveedor**, que crea un registro nuevo **duplicando automáticamente el nombre, la URL y la clave** del proveedor: pablo solo escribe el nuevo ID de modelo y sus dos precios. Debajo de los proveedores, la **tarjeta MCP** compacta con su estado (**Listo** / **Sin configurar**). Y al final de la pestaña, la sección **Respaldo** (§4.8).
- **Preset de fábrica: InferHub (decisión cerrada — era el Anexo A1 de la v1):** en cada instalación limpia, la app **nace con el proveedor InferHub ya creado y activo**, para que pablo solo pegue su clave y ya — estará instalando y desinstalando la app muchas veces durante las pruebas y re-escribir proveedor/modelo/nombre cada vez es inaceptable. Contenido del preset:
  - Nombre: **InferHub** · Protocolo: Chat Completions · URL base: **https://api.inferhub.dev/v1**
  - Modelos precargados (cuatro registros, uno por combo): `combo/deepseek-v4-1-flash` como activo por defecto, `combo/glm-5-3-flash`, `combo/gpt-6-1-sol`, `combo/gpt-6-astra`
  - Precios precargados por combo (sus topes vigentes): deepseek $0.03/$0.12 · glm $0.03/$0.10 · sol $0.6/$3 · astra $3/$15 (por millón de tokens, entrada/salida) — así el costo por chat funciona desde el primer mensaje.
  - La clave queda VACÍA siempre: jamás se hornea ninguna credencial en la app ni en el repo. Con la clave vacía, la Tarjeta de Bienvenida muestra el estado ⚠️ con el botón de pegado en 1 toque (§3.2).
  - El preset es solo el estado inicial: NO limita añadir, editar ni borrar proveedores, y si ya existe configuración guardada, el preset no la pisa.
  - El preset se **siembra en la Fase 2** (junto con la píldora, §5 paso 2.3), para que desde las primeras capturas ya se vean los 4 combos reales de InferHub.
- **Acciones y salida:** tocar una fila o "+ Añadir modelo/combo" abre el Editor (§3.7); el botón "+ Añadir proveedor" crea un dominio nuevo desde cero; tocar la tarjeta MCP abre su configuración (§3.8). Nada de controles vivos vive aquí: Memoria y Tope están en Mi Contexto.
- **Criterios de aceptación:**
  - [ ] La captura muestra solo fontanería: proveedores, MCP y Respaldo. No aparece Memoria ni Tope en esta pestaña.
  - [ ] En una instalación limpia (estado de prueba), la captura muestra UNA sola tarjeta encabezada **InferHub** con sus **4 filas de combos** y los precios precargados — no cuatro tarjetas sueltas ni ningún "Compatible".
  - [ ] La captura del flujo "+ Añadir modelo/combo" muestra el editor con nombre, URL y clave ya rellenados desde el proveedor, pidiendo solo el ID del modelo y los precios.
  - [ ] Al final de la pestaña se ven los botones **Exportar mi configuración** e **Importar configuración** de la sección Respaldo.

### 3.7 Hoja Editor de proveedor

- **Qué se ve primero:** el formulario de UN registro (nombre, URL, clave, protocolo, **un modelo**, precios por millón de entrada/salida de ese modelo) con **Cancelar** arriba a la izquierda y **Guardar** arriba a la derecha desde el primer momento. El editor edita un modelo y sus precios; los demás modelos del mismo dominio son otros registros (§3.6).
- **Clave compartida por host (regla del preset, Parte B):** al guardar o pegar una clave en un registro, si existen otros registros con **exactamente el mismo host** (p. ej. `api.inferhub.dev`) cuya clave esté vacía, la clave **se propaga a todos ellos en el mismo guardado**. Pegar la clave una sola vez deja funcionando los 4 combos. La propagación solo rellena claves vacías: nunca sobrescribe una clave distinta ya guardada en otro registro.
- **Acciones y salida:** las de la tabla §2.2 — Cancelar descarta y baja el teclado en el acto, Guardar (deshabilitado si no hay cambios, ley n.º 3) guarda y cierra; arrastrar hacia abajo solo cierra si no hay cambios sin guardar (§2.4). Los campos de precio son numéricos: regla §2.4 completa.
- **Criterios de aceptación:**
  - [ ] Con el teclado numérico abierto en un campo de precio, la captura muestra la barra con **Listo** encima del teclado y los botones Cancelar/Guardar visibles en la hoja.
  - [ ] Recién abierta la hoja sin tocar nada, Guardar se ve deshabilitado; tras cambiar un carácter, se ve activo.
  - [ ] **Clave propagada (test):** con los 4 registros del preset con clave vacía (estado de prueba), guardar la clave en uno deja los 4 con la misma clave, sin tocar ningún registro de otro host.

### 3.8 Configuración MCP (desde la tarjeta en Conexiones)

- **Qué se ve primero:** el estado del servidor MCP y su formulario de configuración.
- **Acciones y salida:** Cancelar / Guardar en las esquinas (§2.2 y §2.3); campos con §2.4; arrastrar solo cierra sin cambios pendientes.
- **Criterios de aceptación:**
  - [ ] La captura muestra estado y formulario con Cancelar y Guardar en su sitio.

---

## 4. Funciones montadas por pantalla

Cada función del plan aprobado se monta **cuando se reconstruye su pantalla**, una sola vez, sobre la cara nueva — no se le cuelgan funciones al esqueleto viejo. Comportamiento esperado y criterios de aceptación de cada una:

### 4.1 Dos métricas, nunca mezcladas — medidor de contexto y consumo del chat

La Ronda 2 cazó el error central de la v1 (§0, H1): en las APIs que usa Nodo, el bloque `usage` de cada respuesta ya incluye en `prompt_tokens` **todo el historial reenviado**, así que sumar los usos de un chat NO mide la ventana ocupada: mide el consumo facturable, que crece mucho más rápido. Son dos métricas distintas y este documento las separa en todas partes:

- **Ocupación de la ventana (el MEDIDOR):** cuánto aire le queda a la conversación AHORA. **Numerador = `total_tokens` (`prompt_tokens` + `completion_tokens`) únicamente de la ÚLTIMA respuesta recibida en el hilo activo.** Tras un /compact, el numerador pasa a ser el `total_tokens` devuelto por la llamada de resumen. **Denominador** = la ventana del modelo según la **tabla de ventanas editable** que vive en la hoja Estado del chat (ninguna API publica la ventana real detrás de un combo, así que la tabla la mantiene la app y pablo puede corregirla). Barra + cifra + porcentaje solo cuando hay ventana definida. Vive en la Hoja Estado del chat (§3.3), sección "Ocupación de la ventana".
- **Consumo acumulado del chat (la FACTURA):** la **suma histórica de `prompt_tokens` y `completion_tokens` de todas las llamadas del chat** — la cifra que alimenta el costo en dólares. **Nunca se borra ni baja al compactar.** Vive en el subtítulo de la píldora (§3.2), en la pastilla de la lista (§3.1), en la franja de tope, en el acumulador global (§3.5, sumando entre chats) y en la sección "Consumo acumulado del chat" del Estado del chat (§3.3).
- **Para qué el medidor:** decidir a tiempo si compactar o abrir un chat nuevo, antes de que el modelo empiece a "olvidar". Ninguna de las tres apps grandes muestra esto.
- **Criterios de aceptación:**
  - [ ] El numerador del medidor coincide con el `total_tokens` de la ÚLTIMA respuesta del hilo (verificable contra su pie), **no** con la suma de los pies del chat.
  - [ ] Tras /compact en un chat largo, el numerador del medidor **baja** (pasa a ser el de la llamada de resumen) mientras el consumo acumulado del chat **no baja**.
  - [ ] Sin ventana definida para el modelo: se muestran los tokens y cómo definirla; **no** se muestra porcentaje.
  - [ ] Al editar la ventana en la tabla, el porcentaje se recalcula en la misma hoja.

### 4.2 Compactación, comandos con "/" y el selector flotante — la caja de texto de la conversación

- **Comportamiento:** escribir un comando en la caja y enviarlo lo **intercepta antes de que llegue al modelo** y ejecuta la acción localmente; no se envía como mensaje ni gasta tokens de chat (salvo /compact, que hace una llamada de resumen). Comandos de este avance: **/compact** (también disponible en el menú •••), **/costo**, **/modelos**, **/nuevo**, **/exportar**.
- **Gramática ÚNICA del parser (§0, H4 — la misma para §4.2 y §4.4):** al enviar, la app examina los **tokens iniciales** del texto que empiezan con "/":
  1. Si el **primer token** es uno de los **5 comandos del sistema** (compact, costo, modelos, nuevo, exportar), se ejecuta la acción local y no se envía nada al modelo.
  2. Si los tokens iniciales coinciden con **skills existentes**, se adjuntan a ese envío (sus instrucciones se suman al contexto) y el resto del texto es el mensaje del usuario.
  3. Si algún token inicial con "/" **no coincide** ni con un comando ni con una skill activa: **aviso claro, el texto se conserva intacto en la caja y NO se envía nada al modelo** — ni por accidente ni en silencio.
  4. Si tras quitar los `/nombre` de skills el mensaje queda **vacío**, la app **pide escribir el mensaje** (aviso visible) y **NUNCA envía un turno vacío** a la API (las APIs lo rechazan con error 400).
  El parser **nace en la Fase 3.5 ya con el gancho de skills** (la resolución de `/nombre` contra un registro de skills): la Fase 4 solo conecta el almacén real de skills, sin reescribir el parser ni sus tests (§0, H6).
- **Selector flotante de "/" (Parte B — el diseño visible del parser):** en cuanto el usuario escribe "/" como primer carácter en la caja, se despliega justo encima de la caja una lista compacta: **sus skills locales arriba y los 5 comandos del sistema abajo**, filtrándose a medida que escribe. Tocar una skill de la lista la convierte en **píldora activa [⚡ nombre ✕]** sobre la caja (pueden acumularse varias) y **deja la caja limpia** para escribir o dictar el mensaje — nadie tiene que recordar de memoria el nombre exacto de cada skill, y el dictado (§4.5) nunca tiene que pronunciar "barra inclinada nombre". Tocar ✕ quita la skill de ese envío.
- **/compact:** le pide al modelo un resumen del historial, guarda ese resumen como inicio de la conversación y conserva íntegros los últimos mensajes; la sesión **no se borra** y el chat sigue donde iba. El medidor (§4.1) refleja el aire recuperado (su numerador pasa a ser el de la llamada de resumen) y el acumulado facturable **no se toca**.
- **Criterios de aceptación:**
  - [ ] Captura: tras /costo, la conversación muestra el consumo del chat sin que el comando aparezca como mensaje enviado al modelo.
  - [ ] Tras /compact en un chat largo, el numerador del medidor baja, el acumulado no baja, los últimos mensajes siguen visibles y el chat continúa respondiendo con el contexto resumido.
  - [ ] /modelos abre el mismo menú de la píldora; /nuevo crea conversación; /exportar ofrece el texto del chat para compartir/guardar.
  - [ ] La captura del selector flotante muestra las skills arriba y los comandos abajo al escribir "/"; al tocar una skill, aparece su píldora ⚡ sobre la caja y la caja queda limpia.
  - [ ] Un envío que empieza con un `/token` desconocido muestra el aviso y el texto sigue en la caja, sin enviarse (verificable en captura + test del parser).

---

### 4.3 Modo Tarea — conmutador Chat | Tarea en la tira fina (§3.2)

- **Comportamiento:** en modo **Chat** la app responde como siempre. En modo **Tarea**, el envío activa el **ToolLoop que la app ya trae** (herramientas HTTP propias y MCP si hay servidor configurado): el trabajo avanza por **pasos visibles en vivo** dentro de la conversación (paso N · herramienta · resultado, plegables), y **antes de cualquier herramienta con consecuencias la app se detiene y pide aprobación** con la hoja de la tabla §2.2 (Aprobar / Rechazar). El botón Detener corta la tarea en cualquier punto.
- **Qué es una "herramienta con consecuencias" (definición cerrada, §0/H7):** **toda llamada a una herramienta MCP y toda petición HTTP que no sea GET** abre la hoja de aprobación antes de ejecutarse. Las peticiones HTTP GET se consideran de solo lectura y corren sin aprobación. Existe una **lista blanca explícita** de herramientas exentas en la configuración, y **por defecto está VACÍA**: ninguna herramienta está exenta hasta que pablo la añada a mano. Sin regla ambigua: si no es un GET, pide aprobación.
- **Límite honesto, dicho en el producto:** el modo Tarea trabaja **mientras la app está abierta** y pablo está mirando. No es un agente 24/7: si cierra la app, la tarea se detiene. Nada en la interfaz sugiere lo contrario.
- **Criterios de aceptación (deterministas en CI, H7):**
  - [ ] **Dos capturas secuenciales** del mismo paso: Captura A con el paso 1 en estado "Ejecutando…" (spinner visible) **antes** de que el bucle termine, y Captura B con el paso 1 completado y plegable. Una sola foto fija no demuestra "en vivo": el par secuencial sí.
  - [ ] Con una **herramienta de prueba (mock)** clasificada como con consecuencias, la captura muestra la hoja de aprobación **antes** de ejecutarla; con Rechazar, la herramienta no corre (verificable en el registro del mock).
  - [ ] El conmutador Chat | Tarea se ve en la **tira fina sobre la caja de texto** (§3.2) — ya no en la cabecera.

### 4.4 Skills locales — Bloque 3 de Mi Contexto (§3.5)

- **Comportamiento:** una **biblioteca de instrucciones con nombre** guardadas en el teléfono: pablo crea una skill (nombre + texto de instrucciones), la edita y la borra. En cualquier chat, escribir **/nombre** — o tocarla en el selector flotante (§4.2) — invoca esa skill para ese envío: sus instrucciones se suman al contexto de ese mensaje. Varias skills pueden combinarse en un mismo envío (varias píldoras ⚡).
- **Identificadores (slugs) — reglas cerradas (§0, H4):** al guardar una skill, su identificador invocable se **normaliza automáticamente**: minúsculas, sin espacios (reemplazados por guiones `-`), sin caracteres especiales. El nombre visible puede ser el que pablo quiera ("Mi Skill de Ventas"); el slug invocable es siempre limpio (`/mi-skill-de-ventas`) y la interfaz lo muestra junto al nombre para que no haya adivinanzas. Los **5 nombres del sistema quedan RESERVADOS** — **compact, costo, modelos, nuevo, exportar** — y la validación **impide crear una skill con cualquiera de esos slugs**, con el aviso correspondiente.
- **Límite:** las skills son **instrucciones**, no programas: ninguna ejecuta código dentro del iPhone (iOS no lo permite) y la interfaz no promete otra cosa.
- **Criterios de aceptación (deterministas en CI, H7):**
  - [ ] La captura de Mi Contexto muestra la lista de skills bajo la Memoria, con crear/editar/borrar accesibles, y cada skill muestra su slug invocable junto al nombre.
  - [ ] Al invocar una skill en un chat, la burbuja del mensaje enviado muestra la **etiqueta visual ⚡ nombre** de la skill aplicada, y un **test unitario verifica que el texto de la skill se inyectó en el payload** enviado al cliente HTTP. La verificación NUNCA depende del texto que responda el LLM (en CI no hay claves reales ni llamadas a InferHub).
  - [ ] Una skill borrada ya no se invoca: escribir su `/nombre` cae en la regla 3 de la gramática (aviso claro y texto conservado en la caja).
  - [ ] Intentar guardar una skill con un nombre reservado (p. ej. "Compact") muestra el aviso de nombre reservado y no la crea.

### 4.5 Dictado — botón de micrófono en la caja de texto (§3.2)

- **Comportamiento:** tocar el micrófono activa el **reconocimiento de voz del propio iPhone** (sin servidor, sin costo); lo dictado cae **como texto en la caja**, para revisarlo y enviarlo con el botón normal. El dictado nunca envía solo.
- **Implementación verificable (H7):** el reconocimiento vive detrás del **protocolo `SpeechRecognizing`**. En el simulador de GitHub Actions (headless, sin hardware de micrófono) un **mock** inyecta una transcripción simulada en la caja, de modo que el flujo completo — micrófono activo, texto en la caja, sin enviar — sí es capturable y testeable en CI. En el iPhone real se usa el reconocimiento del sistema.
- **Criterios de aceptación:**
  - [ ] La captura muestra el botón de micrófono en la caja de texto.
  - [ ] Con el mock de `SpeechRecognizing`, la captura muestra la transcripción inyectada **en la caja, sin haberse enviado**, lista para corregir.

### 4.6 Chat sin memoria — menú •••, Tarjeta de Bienvenida y + Nuevo

- **Comportamiento:** un chat marcado "sin memoria" **no recibe el texto de la Memoria como contexto**: en ese chat, la Memoria simplemente no se inyecta. Nada más — y nada menos: **la Memoria de Nodo es un bloque de texto que pablo escribe a mano (§3.5), no una memoria automática que la IA extraiga de las charlas**, así que ningún chat "alimenta" la Memoria, con o sin marca. (Aclaración preventiva: si en modo Tarea existiera alguna vez una herramienta capaz de editar la Memoria, en un chat sin memoria quedaría **bloqueada**.) Se activa de tres maneras: desde el menú **•••** de la conversación, con el **conmutador "Memoria en este chat: Activa/Apagada" de la Tarjeta de Bienvenida** (mientras el chat está vacío, §3.2), o **manteniendo pulsado + Nuevo** en la lista (§3.1) para nacer ya sin memoria.
- **Cambio a mitad de conversación:** si se apaga la memoria desde ••• en un chat que ya tenía mensajes, se inserta en el hilo el divisor visual **── Memoria desactivada desde este mensaje ──** (evento local, §2.6): la desactivación aplica **de ese mensaje en adelante**; los turnos anteriores ya viajaron con la Memoria y la interfaz lo dice con transparencia en vez de fingir lo contrario.
- **Señal visual:** la conversación lo indica siempre: el 🧠 del subtítulo y de la tira fina **no muestra el punto verde** en ese chat, y la Tarjeta de Bienvenida de un chat sin memoria dice que la memoria está **apagada** en ese chat (dato real, no de plantilla).
- **Criterios de aceptación:**
  - [ ] En un chat sin memoria, la captura muestra la señal correspondiente y el 🧠 sin punto verde en subtítulo y tira fina.
  - [ ] La Tarjeta de Bienvenida de un chat vacío muestra el conmutador Memoria en este chat, y en un chat sin memoria dice que la memoria está **apagada** en ese chat.
  - [ ] La captura de apagar la memoria a mitad de chat muestra el divisor ── Memoria desactivada desde este mensaje ── en el punto exacto del cambio.
  - [ ] Test unitario: el payload construido para un chat sin memoria no contiene el texto de la Memoria; para un chat normal, sí.

### 4.7 Errores en línea y recuperación — la conversación (§3.2)

- **Comportamiento (Parte B):** ningún fallo de red o de proveedor deja al usuario sin salida ni le hace perder trabajo:
  - La respuesta fallida aparece como **burbuja de error en el hilo** con **[Reintentar]** (mismo modelo) y **[Cambiar modelo y reintentar]** (abre el mismo menú de la píldora y reintenta con el elegido) ahí mismo.
  - **El texto del usuario nunca se pierde:** el mensaje que falló permanece intacto en el hilo y su contenido sigue disponible (copiar, reintentar) sin reescribirlo ni redictarlo.
  - Las respuestas del asistente permiten **selección de texto** y los bloques de código llevan su botón **Copiar código** (§3.2).
- **Criterios de aceptación:**
  - [ ] Con un cliente HTTP de prueba que falla a propósito, la captura muestra la burbuja de error con [Reintentar] y [Cambiar modelo y reintentar], y el mensaje del usuario intacto encima de ella.
  - [ ] Tras pulsar [Reintentar] con el cliente ya sano (mock), la respuesta llega y la burbuja de error desaparece del hilo.

### 4.8 Respaldo e importación de la configuración — final de Conexiones (§3.6)

- **Por qué existe (Parte B, hueco de supervivencia):** pablo instala la IPA mediante ESign; cuando un certificado caduca o se revoca, reinstalar exige **borrar la app**, y eso destruye su almacenamiento local. El preset (§3.6) salva los combos y los precios, pero sin respaldo cada revocación borraría su Memoria redactada, sus skills y sus ventanas corregidas. Esta función es la red de seguridad de todo lo demás.
- **Comportamiento:** dos botones al final de la pestaña Conexiones: **Exportar mi configuración** — genera **un solo archivo JSON** con Memoria, Skills, tabla de ventanas, proveedores con sus precios y el tope, y lo ofrece con el **ShareLink nativo** (guardarlo en Archivos/iCloud Drive o copiarlo) — e **Importar configuración**, que lee un archivo de ese mismo formato y restaura todo eso. **El respaldo NO incluye la clave de API** (decisión de seguridad: ese archivo puede acabar en iCloud o en un chat; las claves no viajan en archivos exportables). Tras importar, la clave se pega una sola vez con el botón de la Tarjeta de Bienvenida (§3.2), que la propaga a los 4 combos (§3.7).
- **Criterios de aceptación:**
  - [ ] **Ida y vuelta verificada en CI con datos de prueba:** exportar una configuración de prueba → borrar el almacenamiento → importar el archivo → la captura muestra Memoria, Skills, ventanas, proveedores/precios y tope **restaurados por completo**.
  - [ ] El archivo exportado de prueba, inspeccionado en el test, no contiene ninguna clave de API.

---

## 5. Plan de construcción por fases

**Método (leyes de CONSTRUCCION.md, sin excepción):** todo el código lo escribe **DeepSeek V4.1 Flash vía DSH**, en **sesiones cortas y frescas, una por tarea**, recibiendo solo la sección de este documento que le toca y los archivos que va a tocar. Una función por tarea y commits chicos. El estado vive en este documento y en el repo: las casillas se marcan al cumplirse, con evidencia. **Las fases son internas: no producen versiones instalables.** Cada fase cierra solo cuando sus tests pasan en Actions **y** pacho revisó sus capturas contra el contrato (§2) y los criterios de la pantalla tocada (§3 y §4).

**Orden corregido por la Ronda 2 (H6):** el plan ya no construye nada que una fase posterior vaya a demoler. La Fase 1 solo blinda el teclado (no invierte en el diseño de pantallas condenadas); el menú ••• de la Fase 2 solo promete funciones que existen en la Fase 2 (Compactar llega en la 3, con su tarea); el parser de la Fase 3 nace con el gancho de skills para que la Fase 4 conecte sin reescribir.

### Fase 1 — Salidas y botones (las leyes + el teclado)

Objetivo: que nadie vuelva a quedar atrapado. Cura el defecto n.º 1 de la v0.2.0. **Alcance honesto:** esta fase blinda, no rediseña — la pantalla vieja de Ajustes recibe SOLO el blindaje de teclado; su reconstrucción entera es la Fase 4 y aquí no se gasta un minuto en su diseño.

- [ ] 1.1 Crear el componente compartido de barra de teclado (ToolbarItemGroup .keyboard con "Listo") **declarado una sola vez por jerarquía de navegación** (§2.4) y la forma estándar de bajar el teclado.
- [ ] 1.2 Aplicar el blindaje §2.4 completo (barra Listo + `.scrollDismissesKeyboard(.interactively)` + vistas con campos dentro de ScrollView/Form) en las vistas con campos existentes: Ajustes de hoy, Editor de proveedor y caja del chat. **Solo blindaje**: nada de rediseñar Ajustes (eso es el paso 4.5).
- [ ] 1.3 Verificar campo por campo los tres `.decimalPad` existentes (tope y los dos precios): ninguno queda suelto.
- [ ] 1.4 Dejar el Editor de proveedor como hoja modal con Cancelar/Guardar según las leyes n.º 2 y n.º 3 (Guardar deshabilitado sin cambios), con `.interactiveDismissDisabled(hayCambios)` (§2.2/§2.4): con cambios, arrastrar baja el teclado y NUNCA cierra la hoja.
- [ ] 1.5 Revisión de pacho: grep de `.decimalPad`/`.numberPad` y de `.onTapGesture` en el repo — cada campo queda cubierto por el componente del paso 1.1 y NO existe ningún `.onTapGesture` global sobre contenedores con List o botones (§2.4).
- **Tests exigidos:** la suite completa de NodoCore sigue en verde en Actions; test nuevo del "sin cambios → Guardar deshabilitado" si esa lógica vive en el núcleo.
- **Capturas exigidas:** Editor de proveedor con el teclado numérico abierto y la barra **Listo** visible; campo de tope con teclado y barra. (No se captura "Ajustes reconstruida": no se reconstruye en esta fase.)

### Fase 2 — Cabecera del chat (+ tira fina, Estado del chat, chat sin memoria y preset)

Objetivo: curar el defecto n.º 2 (el encierro) y montar las funciones de la cabecera y su entorno inmediato.

- [ ] 2.1 Reestructurar la navegación: la lista pasa a ser raíz de la pestaña Chats y la conversación se empuja en la misma NavigationStack; al entrar a una conversación se ocultan las pestañas y la barra superior queda clavada. **La cabecera se construye con el `.toolbar` nativo de NavigationStack — PROHIBIDO reemplazar la barra por una vista propia** (UIKit desactivaría el gesto de borde izquierdo de la Ley n.º 1); solo si un paso futuro lo exigiera de verdad, se re-habilita `interactivePopGestureRecognizer` explícitamente y se verifica en captura.
- [ ] 2.2 Botón ← Chats permanente arriba a la izquierda, funcional también con el teclado abierto y con el gesto de borde.
- [ ] 2.3 Función de nombres limpios en el núcleo: recorte de prefijo tras la barra, apodo manda, nombre de proveedor derivado del dominio si es "Compatible" o vacío (§2.5). **Y la siembra del preset InferHub (§3.6):** si no existe configuración guardada, se crean los 4 registros del preset con sus precios y la clave vacía (si ya hay configuración, no se pisa nada). **Y la regla de clave compartida por host en el núcleo** (§3.7): guardar una clave la propaga a los registros del mismo host con clave vacía — la Tarjeta de Bienvenida de la Fase 3 y el Editor de la Fase 4 consumen esta misma regla, no la reimplementan.
- [ ] 2.4 Píldora central: nombre limpio del modelo + subtítulo proveedor · costo acumulado del chat (§4.1) · indicador 🧠; menú de 2 toques con ✓ en el activo y Gestionar modelos…; divisor ── Ahora responde X ── al cambiar, como **metadato puramente visual filtrado del payload** (§2.6).
- [ ] 2.5 **Tira fina de cápsulas sobre la caja de texto** (§3.2): conmutador Chat | Tarea a la izquierda (su lógica completa es el paso 2.9) y botón 🧠 con punto verde según la memoria tenga texto y el chat no sea sin memoria, abriendo la hoja Memoria rápida (§3.4) con Cancelar/Guardar e `.interactiveDismissDisabled(hayCambios)`.
- [ ] 2.6 Menú ••• **con solo lo que ya existe en esta fase**: Estado del chat, Fijar, Archivar, Chat sin memoria, Borrar. (Compactar se añade al menú en el paso 3.5, junto con /compact: el menú nunca promete una función que aún no existe.)
- [ ] 2.7 Hoja Estado del chat con **las dos métricas rotuladas por separado** (§4.1/§3.3): medidor de ocupación (numerador = `total_tokens` de la última respuesta) y consumo acumulado del chat; tabla de ventanas editable.
- [ ] 2.8 **Chat sin memoria — lógica completa (§4.6), con tarea propia:** el flag por chat y su efecto en la construcción del payload (sin texto de Memoria); activación desde •••; divisor visual ── Memoria desactivada desde este mensaje ── al apagarla a mitad de chat (filtrado del payload, §2.6); creación directa manteniendo pulsado + Nuevo en la lista; señal visual (🧠 sin punto verde). (El conmutador dentro de la Tarjeta de Bienvenida llega con la tarjeta, en el paso 3.2, consumiendo este mismo flag.)
- [ ] 2.9 Modo Tarea en la tira fina: conmutador funcional, ToolLoop con pasos visibles en vivo y hoja de aprobación antes de toda herramienta con consecuencias según la definición cerrada de §4.3 (toda MCP y todo HTTP no-GET; lista blanca vacía por defecto).
- **Tests exigidos:** nombres limpios (con barra, sin barra, con apodo, identificador vacío); nombre desde dominio (URL de InferHub → "InferHub"; nombre propio no se toca); preset (sin configuración previa se siembran los 4 registros con precios y clave vacía; con configuración previa no se toca nada); clave compartida (guardar en un registro propaga solo a claves vacías del mismo host); medidor (**numerador = `total_tokens` de la última respuesta, NO la suma**; el acumulado es la suma y no baja tras /compact; sin ventana definida no hay porcentaje); eventos locales (divisores y avisos NUNCA aparecen en el arreglo `messages` construido); chat sin memoria (su payload no contiene la Memoria; el divisor queda fuera del payload); cambio de proveedor activo inserta el divisor y conserva el historial; modo Tarea no ejecuta una herramienta con consecuencias sin aprobación (mock).
- **Capturas exigidas:** cabecera despejada completa (solo ← Chats, píldora y •••) con el teclado abierto; tira fina con Chat | Tarea y 🧠; menú de la píldora abierto; divisor tras un cambio de modelo; hoja Estado del chat con las dos métricas rotuladas; hoja Memoria rápida con Cancelar/Guardar; paso de herramienta en vivo y hoja de aprobación en modo Tarea.

### Fase 3 — Visibilidad (+ dictado, comandos y errores en línea)

Objetivo: que el motor se vea trabajar en la conversación.

- [ ] 3.1 Pie de cada respuesta: tokens reales · costo (solo con precios configurados; sin precios, solo tokens) · ↻ Regenerar · Copiar. **Mantener pulsado ↻ despliega "Regenerar con…"** con los demás modelos configurados (Parte B), regenerando esa respuesta con el combo elegido. Selección de texto activada en las respuestas y botón Copiar código en los bloques de código (§4.7).
- [ ] 3.2 Tarjeta de Bienvenida del Motor en chats vacíos, alimentada **solo de la configuración real** (modelo activo real, proveedor real, memoria activa solo si tiene texto, tope vigente real) con [Cambiar modelo] y [Ver o editar mi memoria]; **con la clave vacía muestra el estado ⚠️ Falta tu clave con el botón [📋 Pegar clave desde el portapapeles]** que guarda y propaga con la regla del paso 2.3 (§3.2/§3.6); incluye el **conmutador Memoria en este chat** consumiendo el flag del paso 2.8. Desaparece al primer mensaje.
- [ ] 3.3 Franja ámbar de tope sobre la caja de texto al superarse el acumulado, con el comportamiento cerrado de §3.2/H8: [Subir tope] abre el menú de escalones por encima del actual y **actualiza el tope global** reevaluando la franja; [Seguir igual] marca **solo ese chat** con `topeIgnorado` y no toca el global.
- [ ] 3.4 Caja de texto autoexpansible (1–5 líneas) y Enviar ↑ que se vuelve Detener ■ durante el streaming.
- [ ] 3.5 Comandos "/" y selector flotante (§4.2): el **parser con la gramática única completa, nacido YA con el gancho de skills** (resolución de `/nombre` contra un registro de skills inyectable; en esta fase el registro puede venir de una fuente mínima de prueba — la Fase 4 conecta el almacén real sin tocar el parser); los 5 comandos (/compact, /costo, /modelos, /nuevo, /exportar); /compact con resumen que conserva los últimos mensajes, no borra la sesión y actualiza el numerador del medidor sin tocar el acumulado; el menú ••• gana su entrada **Compactar** en este paso; el selector flotante muestra los comandos (y las skills cuando el registro las tenga) y convierte las elegidas en píldoras ⚡ sobre la caja. Todo evento que el parser pinte en el hilo es metadato visual filtrado del payload (§2.6).
- [ ] 3.6 Botón de micrófono con dictado del iPhone hacia la caja, sin envío automático (§4.5), **detrás del protocolo `SpeechRecognizing`** con su mock para CI.
- [ ] 3.7 **Errores en línea (§4.7):** burbuja de error con [Reintentar] y [Cambiar modelo y reintentar]; el mensaje del usuario queda intacto y recuperable tras cualquier fallo.
- **Tests exigidos:** parser con la gramática completa (los cinco comandos se reconocen y ejecutan localmente; un token inicial desconocido avisa y conserva el texto sin enviar nada; `/skill` de prueba vía el gancho se adjunta; `/skill` sin texto detrás pide el mensaje y **nunca envía un turno vacío**; los 5 nombres reservados no pueden resolverse como skills); compactación (el resumen reemplaza el historial antiguo, los últimos mensajes quedan íntegros, la sesión persiste, el numerador pasa a ser el de la llamada de resumen y el acumulado no cambia); pie sin precios configurados no muestra símbolo de dólar; franja de tope ([Subir tope] cambia el global y la franja se reevalúa; [Seguir igual] marca solo ese chat y los demás chats siguen avisando); dictado con mock (la transcripción cae en la caja y no se envía); error en línea (con un cliente que falla, el mensaje del usuario permanece y el reintento funciona al sanar el cliente).
- **Capturas exigidas:** chat vacío con la Tarjeta de Bienvenida (datos reales de prueba) y su variante ⚠️ sin clave con el botón de pegado; una respuesta con el pie completo y el menú "Regenerar con…" abierto; la franja de tope visible y su menú de escalones; la caja con micrófono y la transcripción del mock en la caja sin enviar; el resultado de /costo dentro de la conversación; el selector flotante abierto; la burbuja de error con sus dos botones.

---

### Fase 4 — Las 3 pestañas (Mi Contexto con skills; Conexiones limpia con respaldo)

Objetivo: la estructura definitiva de la raíz y el desentierro de Memoria, Tope y Skills.

- [ ] 4.1 Reestructurar la raíz al TabView definitivo: **Chats / Mi Contexto / Conexiones** (la pila de Chats ya migrada en la Fase 2 no se rehace).
- [ ] 4.2 Mi Contexto — Bloque Memoria: explicación llana, editor amplio con Cancelar/Guardar e **indicador de peso estimado con ~** (`max(1, caracteres/4)`) y costo por envío calculado con el `inputPrice` del proveedor activo, rotulado con su modelo (§3.5/H10).
- [ ] 4.3 Mi Contexto — Bloque Tope: botones rápidos [$0.10] [$0.25] [$0.50] [$1.00] [Otro…] con el valor vigente marcado; "Otro…" con campo numérico bajo §2.4; **y la línea del acumulador de gasto global** (Hoy · Desde el último reinicio · [Reiniciar contador]) cuyos contadores suman cada `usage` y sobreviven al borrado de chats (§3.5).
- [ ] 4.4 Mi Contexto — Bloque Skills: lista de skills locales con crear/editar/borrar, **slugs normalizados** (minúsculas, guiones, sin espacios) y **validación de los 5 nombres reservados** (§4.4); **conexión del almacén real al gancho del parser del paso 3.5 — sin reescribir el parser** — y su reflejo en el selector flotante (skills arriba, comandos abajo, píldoras ⚡).
- [ ] 4.5 Conexiones limpia: **tarjetas agrupadas por URL base** con una fila por registro (modelo y precios), botón **+ Añadir modelo/combo** que duplica nombre/URL/clave (§3.6), Editor de un registro (§3.7) consumiendo la regla de clave compartida del paso 2.3; tarjeta MCP compacta con estado; la vieja mezcla de Ajustes desaparece (aquí sí: esta es su reconstrucción).
- [ ] 4.6 Migración sin pérdidas: la Memoria y el Tope que pablo ya tiene configurados en la v0.2.0 se conservan tal cual en las nuevas pantallas.
- [ ] 4.7 **Respaldo (§4.8)** al final de Conexiones: Exportar configuración (JSON vía ShareLink, **sin la clave**) e Importar configuración con restauración completa.
- **Tests exigidos:** skills (crear/editar/borrar persisten; el slug se normaliza al guardar; los nombres reservados se rechazan con aviso; /nombre inyecta la instrucción en ese envío — verificado en el payload, no en la respuesta del modelo —; /nombre de una skill borrada avisa y conserva el texto); botones rápidos fijan el tope exacto elegido; acumulador (suma usages de varios chats y **no** se altera al borrar un chat; [Reiniciar] solo afecta al acumulado desde el reinicio); agrupación (4 registros del mismo host se muestran bajo una sola tarjeta; + Añadir modelo/combo duplica nombre/URL/clave); migración (**un estado con el esquema de la v0.2.0 y valores de PRUEBA** se abre en la cara nueva con los mismos valores); respaldo (exportar → borrar almacenamiento → importar restaura Memoria, Skills, ventanas, proveedores/precios y tope; el JSON exportado no contiene claves).
- **Capturas exigidas:** una por pestaña (Chats, Mi Contexto completa con sus tres bloques y la línea del acumulador, Conexiones limpia con la tarjeta InferHub agrupada y la sección Respaldo); el tope con su valor vigente marcado; una skill recién creada en la lista con su slug visible.

### Fase 5 — Historial enriquecido

Objetivo: la lista a la altura de la cara nueva (es la raíz ya migrada en la Fase 2; aquí se enriquece su contenido).

- [ ] 5.1 Fila en dos líneas: título + pastilla de **costo acumulado** del chat (la métrica facturable de §4.1; solo con precios) y vista previa + etiqueta del último modelo usado (nombre limpio).
- [ ] 5.2 Segmento Activos | Archivados siempre visible bajo el buscador.
- [ ] 5.3 Gestos completos: deslizar derecha fijar/desfijar, izquierda archivar/borrar; pulsación larga con Fijar, Renombrar, Archivar y Borrar; fijados siempre arriba.
- [ ] 5.4 **Ramificar chat desde aquí (Parte B):** mantener pulsada cualquier burbuja ofrece 🔀 Ramificar chat desde aquí: clona localmente los mensajes desde el n.º 1 hasta ese punto en una conversación nueva y entra directamente en ella. La copia hereda el historial clonado, y **su acumulado facturable arranca como la suma de los usos de los mensajes clonados** (su costo sigue siendo honesto desde el primer mensaje).
- **Tests exigidos:** orden (fijados primero, resto por actividad); el segmento filtra sin mezclar; el costo de la pastilla coincide con el consumo acumulado del chat; la etiqueta muestra el último modelo usado en esa conversación, no el activo global; ramificar (la copia contiene exactamente los mensajes hasta el punto elegido, es independiente del original — escribir en una no toca la otra — y su acumulado corresponde a los mensajes clonados).
- **Capturas exigidas:** historial con fijados arriba y filas enriquecidas; el segmento en Archivados; el menú de pulsación larga abierto; una conversación ramificada recién creada desde un punto intermedio.

---

## 6. Verificación y entrega

La v0.2.0 enseñó que las puertas de código no ven el producto. En este avance, **ninguna fase se da por terminada con tests solamente**, y la entrega final cumple todo esto, en orden:

1. **Puerta por fase (ya incluida en la §5):** tests en verde en GitHub Actions **+** las capturas del simulador de esa fase, revisadas por pacho **contra el contrato (§2) y los criterios de aceptación (§3 y §4)**. Si una captura contradice una ley, la fase no cierra: se corrige en la misma fase, no se anota para después. Todos los criterios son **deterministas en CI** (H7): datos de prueba para la migración, mocks para herramientas y dictado, y verificación por payload/etiqueta — nunca por el texto de un LLM ni con datos reales de pablo.
2. **Revisión tipo PR:** pacho lee el diff completo de cada fase como PR de un junior (bugs, bordes, seguridad, legibilidad) antes de aceptarla. Cero datos personales en el repo, como siempre.
3. **Pase final completo:** con las 5 fases cerradas, Actions genera el juego completo de capturas de **todas** las pantallas y hojas de la §3; pacho las mira **todas** contra el contrato antes de autorizar la IPA. Sin capturas revisadas no hay IPA (regla 8 de CONSTRUCCION.md).
4. **Versión alineada en todas partes:** el número de versión visible en la app y el del sistema (project.yml) coinciden, y se comprueba **leyendo el Info.plist de la IPA ya construida, en disco**, antes de entregarla — la v0.2.0 casi sale etiquetada 0.1.0 por saltarse este paso.
5. **UNA sola IPA final:** se construye una vez, con Actions en verde, y llega a pablo por el chat **con la etiqueta del adjunto igual al nombre completo del archivo, con su extensión .ipa y sin espacios** (lección de la v0.2.0: iOS guarda el archivo con el nombre de la etiqueta, y sin extensión ESign no lo reconoce como instalable).
6. **La prueba final es de pablo en su iPhone**, sobre la app real — pero llega con todo lo verificable ya verificado: él juzga la experiencia, no caza errores de navegación que las capturas debieron cazar.

---

## 7. Fuera de alcance (explícito)

Esto **no** entra en el gran avance, aunque aparezca en auditorías o planes anteriores:

- **Proyectos** (espacios con instrucciones propias y chats agrupados): **FUERA del gran avance — decisión cerrada en la conciliación de la Ronda 2.** Quedan como fase siguiente, con la cara ya estable. La pestaña Chats con fijados + segmento Activos | Archivados cubre el uso real de hoy.
- **Programado real, ejecución en segundo plano y cualquier servidor propio** (idea descartada por Argon en la Parte B, con su motivo: **falla el filtro de aplicabilidad**): iOS corta las conexiones y los bucles de red en cuanto la app pasa a segundo plano; las tareas que corren a su hora con la app cerrada exigen un computador siempre encendido que no existe en este plan. Sin servidor no se promete ejecución en segundo plano; como mucho, avisos locales, que tampoco forman parte de este avance.
- **Auto-extracción de memoria en silencio** (idea descartada por Argon en la Parte B, con su motivo: **falla los filtros de control del saldo y del contexto**): que la IA decida qué guardar en la Memoria tras cada chat haría llamadas ocultas que gastan saldo a espaldas del dueño y ensuciaría con ruido un texto curado a mano. La Memoria se escribe a mano, siempre (§3.5/§4.6).
- **Tokenizador BPE exacto en tiempo real** (idea descartada por Argon en la Parte B, con su motivo: **falla el filtro de no engordar la app**): empaquetar las tablas de vocabulario añadiría varios megabytes a una app de ~430 KB. El `usage` real de la API da la precisión donde importa (§4.1) y la estimación `caracteres/4` basta para el peso de la Memoria (§3.5).
- **Voz en vivo:** conversación hablada en tiempo real con el modelo, no. El **dictado** (§4.5) sí entra porque usa el reconocimiento del propio iPhone.
- **El motor no se toca:** streaming, clientes HTTP, la puerta MCP, la persistencia local y el conteo de tokens funcionan y quedan como están, **salvo lo que el montaje de las funciones exija** (leer los datos que ya existen: usos por mensaje, historial, configuración). Nada de reescribir la capa de red o de datos "de pasada".
- **El modelo de configuración no se reestructura:** un modelo por proveedor, como hoy (§2.5). La agrupación por URL base de Conexiones (§3.6) es **solo visual**: nada de listas de modelos por proveedor en los datos en este avance.
- **Skills que ejecuten código:** imposibles en iOS y fuera de cualquier promesa; las skills de este avance son instrucciones con nombre (§4.4).
- **Peso y librerías:** no se engorda la app con librerías visuales pesadas ni frameworks de terceros. La ligereza (~430 KB) es una virtud: la sensación de "cáscara" se cura mostrando el trabajo del motor, no añadiendo relleno.
- **Relleno de producto:** sin onboarding, sin perfiles de usuario, sin confirmaciones dobles para acciones simples, sin sincronización entre dispositivos. Es la herramienta de un solo dueño y debe abrir lista para trabajar en medio segundo.

---

## Decisiones cerradas (conciliación de la Ronda 2 — no se reabren en la construcción)

1. **Dos métricas separadas para siempre:** ocupación de la ventana = `total_tokens` de la última respuesta (tras /compact, el de la llamada de resumen); acumulado facturable = suma histórica de usos, que nunca baja. Viven rotuladas por separado en el Estado del chat (H1).
2. **Cabecera de 3 elementos** (← Chats | píldora | •••) construida con `.toolbar` nativo; conmutador Chat|Tarea y botón 🧠 viven en la **tira fina sobre la caja de texto** (H2).
3. **Conexiones agrupa por URL base** con una fila por registro (1 modelo por registro, sin tocar `ProviderConfig`), botón **+ Añadir modelo/combo** que duplica nombre/URL/clave, y editor de un solo modelo y sus precios (H3).
4. **Gramática única del parser de "/"**: comando del sistema → acción local; skills existentes → se adjuntan; token desconocido → aviso y texto conservado; mensaje vacío tras quitar los `/nombre` → la app pide el mensaje. **Jamás se envía un turno vacío.** Slugs normalizados y **5 nombres reservados** (compact, costo, modelos, nuevo, exportar) (H4).
5. **Blindaje de teclado sin trampas:** prohibido el `.onTapGesture` global sobre contenedores con List o botones; toda vista con campos en ScrollView/Form; `.interactiveDismissDisabled(hayCambios)` en toda hoja con Guardar; la barra de teclado se declara **una sola vez por jerarquía** (H5).
6. **El plan no se muerde la cola:** parser con gancho de skills desde la Fase 3.5; Chat sin memoria con tarea propia en la Fase 2; la Fase 1 solo blinda (la reconstrucción de Ajustes es la Fase 4); el menú ••• solo promete lo que ya existe en su fase (H6).
7. **Criterios deterministas en CI:** migración con estado v0.2.0 de prueba; modo Tarea en dos capturas secuenciales; skills verificadas por etiqueta ⚡ + test de payload; dictado tras `SpeechRecognizing` con mock. Ningún criterio depende de datos reales, claves reales ni del texto de un LLM (H7).
8. **"Herramienta con consecuencias" = toda llamada MCP y todo HTTP que no sea GET.** Lista blanca explícita, **vacía por defecto** (H7).
9. **[Subir tope] actualiza el tope GLOBAL** (menú de escalones superiores al actual, franja reevaluada); **[Seguir igual] marca solo ese chat** (`topeIgnorado`) y no toca el global (H8).
10. **Chat sin memoria = la Memoria no se inyecta en ese chat** (la Memoria es manual; ninguna charla la alimentaba). Activación: •••, conmutador en la Tarjeta de Bienvenida y mantener pulsado + Nuevo; apagarla a mitad de chat inserta el divisor visual de aviso (H9).
11. **Peso de la Memoria = estimación con ~** (`max(1, caracteres/4)`); su costo estimado usa el `inputPrice` del proveedor activo y se rotula con ese modelo (H10).
12. **Eventos locales del hilo = metadatos puramente visuales**, filtrados SIEMPRE antes de construir el arreglo `messages` que sale a la API (§2.6) (H11).
13. **Cancelar / Cerrar sin mezclas:** hoja que edita con Guardar = **Cancelar**; hoja de solo consulta sin Guardar = **Cerrar** (H12).
14. **Preset InferHub sembrado en la Fase 2:** 4 registros (deepseek activo), precios precargados, **clave vacía siempre**; **clave compartida por host** (un pegado la propaga a los registros del mismo host con clave vacía); la Tarjeta de Bienvenida sin clave muestra **⚠️ Falta tu clave** + botón de pegado en 1 toque — nunca un falso "conectado" (Parte B).
15. **Respaldo en 1 toque:** Exportar/Importar la configuración completa en JSON vía ShareLink, **sin la clave de API**; el criterio de cierre es la ida y vuelta completa con datos de prueba (Parte B).
16. **Acumulador de gasto global** en Mi Contexto (Hoy · Desde el último reinicio · Reiniciar), inmune al borrado de chats (Parte B).
17. **Errores en línea sin pérdida:** burbuja de error con [Reintentar] y [Cambiar modelo y reintentar]; el texto del usuario nunca se pierde; selección de texto y Copiar código en las respuestas (Parte B).
18. **Selector flotante de "/"** con skills arriba y comandos abajo y píldoras ⚡ sobre la caja; **Regenerar con otro combo** manteniendo pulsado ↻; **Ramificar chat desde aquí** en la Fase 5 (Parte B).
19. **Descartadas con motivo, registradas en §7:** tokenizador BPE local, ejecución en segundo plano/programada sin servidor, auto-extracción de memoria en silencio (Parte B).
20. **Proyectos: FUERA del gran avance.** Fase siguiente, si acaso. No se reabre.
21. **El motor no se toca** (§7) y **ninguna cifra se muestra si no sale de la configuración real del dueño** (§2.1). **Una sola IPA al final**, construida y verificada contra este documento (§6).
