# Contrato de diseño de Nodo — las leyes del producto

Este archivo manda sobre cualquier pantalla nueva o reconstruida. Toda sesión
de construcción lo cumple y la revisión se hace contra él. La spec completa es
`SPEC.md` (Documento Maestro Definitivo); este contrato es su capa de diseño,
condensada sin perder reglas. Si una pantalla no puede cumplir una ley, la
pantalla está mal diseñada y se corrige antes de seguir.

## 1. Frase guía

> "Todo lo que el motor calcula por dentro debe verse vivo en la conversación
> sin ir a buscarlo a Ajustes, y ninguna pantalla ni teclado puede abrirse
> jamás sin mostrar arriba su puerta de salida." — **y ninguna cifra se
> muestra si no sale de la configuración real del dueño.**

## 2. Regla anti-callejones: toda superficie tiene entrada y salida escritas

Ninguna pantalla, hoja o teclado existe sin su salida definida. Sin
excepciones, y también con el teclado abierto:

| Superficie / estado | Cómo se entra | Cómo se SALE |
|---|---|---|
| Conversación | Tocando un chat en la pestaña Chats o con Nuevo Chat | **← Chats** fijo arriba a la izquierda (la barra superior nunca se oculta ni se desplaza con el teclado) + gesto nativo desde el borde izquierdo. Volver cierra el teclado en la transición. |
| Hoja Estado del chat | Menú ••• de la cabecera | **Cerrar** arriba a la izquierda (hoja de solo consulta) o arrastrar hacia abajo. |
| Hoja Memoria rápida | Icono 🧠 en la tira fina sobre la caja de texto | **Cancelar** arriba a la izquierda, **Guardar** arriba a la derecha. Arrastrar solo cierra sin cambios pendientes. |
| Editor de proveedor | Fila de proveedor o "+ Añadir…" en Conexiones | **Cancelar** arriba a la izquierda (descarta y baja el teclado en el acto), **Guardar** arriba a la derecha. Arrastrar solo cierra sin cambios pendientes. |
| Configuración MCP | Tarjeta MCP en Conexiones | Cancelar izquierda, Guardar derecha. Arrastrar solo cierra sin cambios pendientes. |
| Aprobación de herramienta (modo Tarea) | Aparece sola antes de una herramienta con consecuencias | Dos salidas y solo dos: **Aprobar** o **Rechazar**. Nunca queda colgada ni se cierra por accidente. |
| Cualquier campo de texto o número | Tocando dentro del campo | Triple seguro: 1) botón **Listo** en la barra sobre el teclado; 2) arrastre interactivo hacia abajo; 3) toque fuera del campo en zona sin controles (sin gestos globales, ver §4). |

**Protección de hojas:** toda hoja con botón Guardar lleva
`.interactiveDismissDisabled(hayCambiosSinGuardar)`. Con cambios sin guardar,
arrastrar hacia abajo baja el teclado y nada más; para salir descartando está
el botón explícito Cancelar.

**Descartado expresamente:** cualquier "globo numérico" o contador sobre el
botón ← Chats. Ruido sin función en una app de un solo usuario.

## 3. Las 4 leyes de botones

| # | Acción | Dónde va SIEMPRE | Cómo se ve | Comportamiento exacto |
|---|---|---|---|---|
| 1 | Volver atrás | Esquina superior izquierda | Flecha + nombre de la pantalla anterior: **← Chats** | Regresa a la pantalla previa; si el teclado estaba abierto, lo cierra en la transición. También funciona el gesto desde el borde izquierdo. |
| 2 | Cancelar / Cerrar (hojas) | Esquina superior izquierda de la hoja | Texto simple en el color de acento: **Cancelar** si la hoja edita datos y tiene Guardar a la derecha; **Cerrar** si es de solo consulta y no tiene Guardar. Sin mezclas. | Cancelar: descarta lo escrito, baja el teclado y cierra la hoja de inmediato. Cerrar: cierra la hoja de consulta. |
| 3 | Confirmar / Guardar | Esquina superior derecha | **Guardar** en negrita o píldora rellena. **Deshabilitado (gris) si no se ha modificado nada**; activo en cuanto cambia una letra o un número. | Guarda en local, cierra el teclado, toque háptico suave y cierra la hoja (o ✓ Guardado si es una pestaña). |
| 4 | Cerrar el teclado | Barra horizontal pegada justo encima del teclado, botón a la derecha | **Listo** en negrita (o icono de teclado con flecha hacia abajo) | Esconde el teclado en el acto y deja la pantalla completa visible, sin borrar ni perder lo escrito. |

## 4. Regla técnica de teclado en SwiftUI (obligatoria, sin excepciones)

Los teclados `.decimalPad` y `.numberPad` no traen tecla de retorno ni de
cierre: ningún campo con esos teclados puede existir suelto.

- **Toda vista con campos de entrada vive dentro de un `ScrollView` o un
  `Form`.** Sin desplazamiento vertical, `.scrollDismissesKeyboard` no tiene
  efecto real: la vista entera debe poder rebotar aunque quepa en pantalla.
- **Los dos modificadores base:** `.scrollDismissesKeyboard(.interactively)`
  y la barra sobre el teclado con el botón **Listo**.
- **La barra de teclado se declara UNA sola vez por jerarquía de navegación**
  (`ToolbarItemGroup(placement: .keyboard)` en la vista raíz de la
  jerarquía). Prohibido duplicarla en la vista padre y en la subvista activa:
  UIKit genera barras accesorias duplicadas.
- **PROHIBIDO el `.onTapGesture` global** sobre contenedores que tengan una
  `List` o botones hijos: intercepta o retrasa los toques sobre filas y
  botones. El seguro "tocar fuera" se logra con el fondo del propio
  ScrollView/Form, nunca con un gesto que envuelva controles.
- **Toda hoja con Guardar lleva `.interactiveDismissDisabled(hayCambios)`**:
  el arrastre para bajar el teclado jamás cierra la hoja ni pierde cambios.

## 5. Regla de nombres limpios

- **El modelo manda limpio:** la píldora muestra el nombre limpio del modelo
  del proveedor activo. Si el identificador trae prefijo con barra
  (`vendedor/modelo`), se recorta todo lo anterior a la barra. Si el dueño le
  puso un apodo al modelo, **el apodo manda**.
- **Un modelo por proveedor en los datos** (`ProviderConfig` no cambia): un
  registro = un modelo. La píldora y su menú muestran el nombre limpio del
  modelo de cada proveedor, con el proveedor como subtítulo. La agrupación
  visual por dominio en Conexiones no altera el modelo de datos.
- **El proveedor nunca se llama "Compatible":** si el nombre guardado es
  "Compatible" o está vacío, la app deriva el nombre del dominio de su URL
  (de `https://api.inferhub.dev/v1` deriva **InferHub**) y lo muestra así en
  todas partes. El dueño puede renombrarlo cuando quiera.
- **La palabra "Compatible" no aparece en ninguna pantalla** del producto
  terminado (incluye la etiqueta del protocolo en el editor: se renombra).

## 6. Eventos locales del hilo: metadatos puramente visuales

La conversación muestra cosas que NO son mensajes: el divisor
── Ahora responde X ──, el divisor ── Memoria desactivada desde este
mensaje ──, la salida de /costo, los avisos del parser y la burbuja de error.

- Se pintan en la lista, pero **se filtran SIEMPRE antes de construir el
  arreglo `messages` que se envía al cliente HTTP**. Jamás viajan a la API
  como rol `system` ni `assistant`: gastarían tokens y romperían la
  alternancia de roles en modelos estrictos.
- Si un evento local puede acabar dentro del payload, la tarea está mal
  hecha.

## 7. Dos métricas, nunca mezcladas

- **Ocupación de la ventana (el MEDIDOR):** numerador = `total_tokens`
  (`prompt_tokens` + `completion_tokens`) únicamente de la **ÚLTIMA**
  respuesta recibida en el hilo activo. Tras /compact, el numerador pasa a
  ser el `total_tokens` de la llamada de resumen. Denominador = ventana del
  modelo según la tabla de ventanas editable de la hoja Estado del chat.
  Porcentaje solo cuando hay ventana definida.
- **Consumo acumulado del chat (la FACTURA):** suma histórica de
  `prompt_tokens` y `completion_tokens` de **todas** las llamadas del chat.
  Nunca se borra ni baja al compactar. Alimenta el costo en dólares, la
  pastilla de la lista, la franja de tope y el acumulador global.
- En la hoja Estado del chat viven **rotuladas por separado**: "Ocupación de
  la ventana" y "Consumo acumulado del chat". Ninguna se presenta como la
  otra.

## 8. Gramática del parser de "/" (única, para comandos y skills)

Al enviar, se examinan los tokens iniciales del texto que empiezan con "/":

1. Si el **primer token** es uno de los 5 comandos del sistema (compact,
   costo, modelos, nuevo, exportar): acción local, no se envía nada al
   modelo.
2. Si los tokens iniciales coinciden con **skills existentes**: se adjuntan
   a ese envío y el resto del texto es el mensaje del usuario.
3. Si algún token inicial con "/" **no coincide** con comando ni skill:
   aviso claro, **el texto se conserva intacto en la caja** y no se envía
   nada.
4. Si tras quitar los `/nombre` el mensaje queda **vacío**: la app pide
   escribir el mensaje. **Jamás se envía un turno vacío** (la API lo rechaza
   con error 400).

Slugs de skill: minúsculas, sin espacios (guiones `-`), sin caracteres
especiales. Los 5 nombres del sistema quedan **RESERVADOS**: no se puede
crear una skill con esos slugs.

## 9. Herramientas con consecuencias (definición cerrada)

**Toda llamada a una herramienta MCP y toda petición HTTP que no sea GET**
abre la hoja de aprobación antes de ejecutarse. Los GET corren sin
aprobación. La lista blanca de exentas existe en la configuración y **por
defecto está VACÍA**.

## 10. Reglas de verificación que el diseño impone

- Todo criterio de aceptación se verifica en CI de forma **determinista**:
  datos de prueba, mocks (herramientas, `SpeechRecognizing`, cliente HTTP) y
  verificación por payload o etiqueta visible — nunca por el texto que
  responda un LLM, nunca con datos ni claves reales del dueño.
- Sin captura del simulador revisada contra este contrato, ninguna pantalla
  está terminada.
- **El motor no se toca** (streaming, clientes HTTP, puerta MCP, persistencia
  y conteo de tokens quedan como están), salvo leer los datos que ya existen.
- **Cero datos personales y cero credenciales en el repo** (es público): el
  preset de fábrica lleva la clave VACÍA; el respaldo exportable nunca
  incluye la clave.
