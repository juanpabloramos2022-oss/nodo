# UI_INVARIANTS.md — invariantes de presentación del hilo (inmutables)

Archivo corto e inmutable (tope 120 líneas). No importa código y no duplica
`CONTRATO-DISENO.md`: aquel manda en el diseño general, este manda en lo que
puede y no puede aparecer en el hilo. Toda sesión que toque vistas lo lee antes
de escribir una línea y lo cita en su primer commit. Cambiarlo exige firma del
dueño y nota en el log, como una enmienda de spec: nunca ocurre dentro de una
sesión de construcción ordinaria.

## 1. Prohibido mostrar UUIDs

Ninguna cadena con formato de UUID llega a la vista, venga de un resultado de
herramienta, de un id de entrada o de un mensaje interno.

## 2. Prohibido volcar resultados de herramientas

Ningún mensaje con rol herramienta, ningún JSON crudo y ningún texto de
retorno de herramienta (p. ej. el `resultadoHerramienta` de `CambioMemoria`,
que hoy dice «Guarde en Memoria la entrada <UUID>.») es un elemento visible del
hilo. Esos textos son metadatos internos del turno: viajan en el payload al
modelo y nada más.

## 3. Prohibido el rótulo «HERRAMIENTA»

Ni «HERRAMIENTA» ni cualquier etiqueta con el nombre técnico de una función
(p. ej. `memoria_chat`) bajo, sobre o dentro de una burbuja visible.

## 4. Artefacto único por guardado de memoria

Tras un guardado, actualización o borrado de memoria, los artefactos visuales
adicionales a la burbuja del asistente son exactamente 1: la línea única de
B1.2. Ni tarjeta, ni divisor extra, ni etiqueta.

## 5. Comunicación de memoria

Sin guardado, 0 palabras sobre memoria o su política; con guardado, acuse
verbal ≤1 frase de ≤20 palabras; prohibida la frase «anotado mentalmente» y
equivalentes que afirmen un guardado no ejecutado.

## 6. Tokens de diseño obligados

Los ya existentes en `Nodo/Support/Tema.swift`, que se conservan:
`Tema.fondo`, `Tema.superficie`, `Tema.superficieAlta`, `Tema.acento`,
`Tema.textoSuave`, `Tema.borde`; `Tema.radio = 16`, `Tema.margen = 16`; burbuja
de conversación en `.body`; línea discreta de aviso en `.caption` con
`Tema.textoSuave`, sin fondo de tarjeta, sin borde y sin icono protagonista.
Ninguna vista nueva introduce colores, radios ni tamaños fuera de `Tema`.

## 7. Regla de oro de la proyección y catálogo cerrado

La vista pinta solo lo que la proyección visible (P0.2) le entrega; si un
elemento no tiene caso en el catálogo de la sección «Catálogo completo de
elementos proyectables» de este mismo archivo, no existe en pantalla. El
catálogo se declara COMPLETO en este archivo desde P0.1 y cubre los cuatro
bloques de la fase (Chat, hoja de aprobación sensible, segmentación de código,
Tarea y búsqueda): ninguna sesión posterior de ningún bloque añade, renombra ni
retira un caso. Un elemento fuera del catálogo en una proyección, en una traza
o en una vista es fallo de Puerta C, no motivo de enmienda.

## Catálogo completo de elementos proyectables

Declarado en P0.1, vigente para toda la fase. Cerrado: ningún bloque añade,
renombra ni retira casos.

### Chat — `ElementoHiloVisible` (7 casos)

- `.burbujaUsuario(texto:)` → `UserBubble`
- `.burbujaAsistente(segmentos:)` → `AssistantBubble`
- `.lineaMemoria(texto:, puedeDeshacer:, deshecho:)` → `MemoryLineNotice`
- `.divisor(texto:)` → `Divider`
- `.burbujaEnCurso(texto:)` → `StreamingBubble`
- `.errorTurno(texto:)` → `ErrorBubble`
- `.hojaAprobacionMemoria(texto:, categoriaSensible:, estado:)` →
  `MemoryApprovalSheet`

### Segmentos de la respuesta del asistente — `SegmentoRespuesta` (2 casos)

Contenido ordenado de `.burbujaAsistente`. El pie de respuesta
(tokens/costo/copiar/regenerar) sigue siendo parte de la burbuja, no un
artefacto separado.

- `.texto(String)` → `TextSegment`
- `.codigo(lenguaje: String?, textoCrudo: String)` → `CodeBlock`

### Tarea — `ElementoTareaVisible` (3 casos)

- `.cabeceraTarea(estado:, pasoActual:, pasosTotales:, costoSellado:)` →
  `TaskHeader`
- `.tarjetaPlan(pasos:, version:)` → `PlanCard`
- `.filaPaso(paso:, estado:, etiquetaDinamica:, duracion:, costo:)` → `StepRow`

`EstadoPaso` (7 estados): `.pendiente`, `.enCurso`, `.esperandoAprobacion`,
`.completado`, `.denegado`, `.detenido`, `.error`.

### Búsqueda — `ElementoBusquedaVisible` (2 casos)

Las filas de resultado se identifican por título y vista previa de texto, nunca
por identificador interno: en la traza no hay UUIDs ni identificadores de
registro.

- `.resultadoBusqueda(titulo:, vistaPrevia:)` → `SearchResultRow`
- `.sinResultados(termino:)` → `SearchEmptyState`

### Etiquetas válidas de traza (Puerta C, mismo orden — 14)

`UserBubble`, `AssistantBubble`, `TextSegment`, `CodeBlock`,
`MemoryLineNotice`, `Divider`, `StreamingBubble`, `ErrorBubble`,
`MemoryApprovalSheet`, `TaskHeader`, `PlanCard`, `StepRow`, `SearchResultRow`,
`SearchEmptyState`. Ningún otro nombre de elemento es válido en una traza.

## Invariantes negativas

- Este archivo no contiene criterios de producto (cuándo guardar, qué es
  sensible): eso vive en la spec de cada bloque. Mezclarlos lo convertiría en
  una segunda spec que se desincroniza.
- Este archivo no se modifica dentro de una sesión de construcción ordinaria:
  cambiarlo exige firma del dueño y nota en el log, como una enmienda de spec.
