---
layout: default
locale: es
lang: es
page_key: changes
permalink: /es/changes.html
title: Novedades
description: Nuevas funciones, mejoras y correcciones de errores de cada versión de SIFT.
---

# Novedades

<a id="version-1-0-16"></a>
## 1.0.16

### Eliminación de publicidad

- Se han eliminado los anuncios y los controles de consentimiento publicitario. Todas las funciones son gratuitas y no requieren compras dentro de la app.

### Sincronización, correo y prioridad

- La sincronización, la revisión del correo, el procesamiento de calendario y reuniones y la ordenación por prioridad ahora funcionan de forma independiente.
- Solo se sincronizan con iCloud los elementos modificados, y la prioridad se ordena solo al añadir una tarea nueva. Completar o editar una tarea existente ya no reordena todo.
- Con la app abierta, se revisan el correo nuevo y sus contenidos cada 45 segundos aproximadamente, y cada dispositivo analiza las acciones del correo nuevo. Los análisis fallidos se reintentan con intervalos crecientes.
- Se corrigió la repetición del aviso «Datos locales restaurados» y el banner «Ordenando prioridades con IA…» durante el análisis del correo.

<a id="version-1-0-15"></a>
## 1.0.15

### Listas de tareas y correo

- Las filas de tareas y correo en Mac ya no muestran flechas permanentes. Al pasar el ratón aparece Más a la derecha: la fila abre los detalles; Más o el clic derecho solo abre las acciones.
- En iPhone y iPad, los detalles de tareas usan filas de formulario estándar para Completar y Eliminar en lugar de grandes botones rellenos. Eliminar usa el color destructivo estándar y Añadir etiqueta tiene un aspecto más ligero.

### Calendario

- En el calendario de iPhone y iPad, la esquina superior izquierda muestra el año y el mes y se actualiza al desplazarte a otro mes. También puedes identificar el año y el mes al pasar de un año a otro.
- Los títulos mensuales dentro del calendario también muestran el año, para distinguir un mismo mes de años diferentes.

- La vista semanal muestra dos o tres días a la vez en iPhone y en diseños estrechos de iPad; los diseños amplios de iPad pueden mostrar los siete días.
- Las fechas se desplazan horizontalmente con la inercia nativa. Deslizar las fechas hacia la derecha ya no vuelve a la pantalla anterior; el botón Atrás sigue disponible.
- Los eventos de todo el día o que duran al menos un día aparecen como una barra continua. Las cabeceras, columnas horarias y barras se desplazan juntas, con las horas fijas. Los eventos con hora de menos de un día permanecen en el horario de cada fecha aunque crucen medianoche.

### Correo

- Solo se sugieren tareas a partir de los elementos de **Requiere revisión o acción** del análisis del cuerpo completo. Si no hay elementos, el asunto o el resumen del correo no se convierten en una tarea; puedes guardar por separado una tarea que introduzcas manualmente.
- Puedes guardar por separado varios elementos de acción de un mismo correo y evitar duplicar un elemento incluso después de editar su título. Los eventos de calendario que añades manualmente también se distinguen por tarea y conservan la referencia al correo original.
- Las conexiones IMAP interrumpidas se restablecen en la siguiente consulta, y un fallo al marcar un mensaje como leído ya no impide recibir su cuerpo. No se ejecutan acciones de marcar como leído o mover a la papelera mediante la conexión de otra cuenta.
- La lista y los cuerpos completos se guardan en el dispositivo al activar la app y de forma periódica. La caché se mantiene aunque el análisis de IA esté desactivado; la recuperación en segundo plano solo se aplica a las cuentas autorizadas y iOS decide cuándo se ejecuta.
- Se han equilibrado los espacios superior e inferior de las tarjetas de resumen del correo y se ha mejorado la pantalla de selección de elementos de acción para poder leer los nombres largos.
- Se obtiene el texto completo y el HTML de presentación sin grandes adjuntos, conservando las acciones al final del correo. Un fallo de conexión del dispositivo no borra resúmenes sincronizados válidos; deshacer una eliminación conserva el origen de la acción y evita duplicados.

### Ajustes y sincronización

- La pantalla **Conflictos de sincronización** permite comparar las versiones y las diferencias de cada elemento, elegir directamente qué versión usar y aplicarla. Si un elemento cambia durante la comparación, se solicita revisarlo de nuevo; los demás elementos sin conflictos siguen sincronizándose.
- Se conserva en el dispositivo una copia de las versiones originales antes de resolver un conflicto, y pueden volver a compararse y restaurarse desde **Versiones conservadas**. Los duplicados de un mismo elemento se unifican con la versión elegida directamente.
- Los errores de configuración de la app en formularios de privacidad publicitaria, los errores de red o tiempos de espera y los fallos al ofrecer formularios se distinguen para indicar cómo resolverlos. Los problemas de configuración de Google no se presentan como errores solucionables simplemente reintentando.
- Mejoramos la restauración iCloud de tareas anteriores. La versión 1.0.14 no puede leer las nuevas tareas de acciones de correo y su sincronización puede detenerse; actualiza todos los iPhone, iPad y Mac de la misma cuenta iCloud.

<a id="version-1-0-14-13"></a>
## 1.0.14 (13)

### Reuniones

- Se ofrece el botón **Añadir tarea** junto a las frases del resumen clasificadas como tareas. La frase revisada se añade tal cual a la cola de pendientes de registro, sin una lista independiente de candidatos ni un nuevo resumen del nombre de la tarea; se mantienen la verificación de evidencias del original y la prevención de duplicados.
- En **Volver a resumir** puedes elegir directamente Apple Intelligence, GPT-6.1 Sol o GPT-6 Luna. GPT solo se utiliza con una cuenta conectada y consentimiento de envío de reuniones por dispositivo; en caso de error o cancelación se conservan los resultados anteriores.
- Se ha corregido la selección de formato y la edición de instrucciones para que estén disponibles incluso si las instrucciones personalizadas del resumen están vacías.
- El procesamiento de reuniones largas con Apple Intelligence se divide en etapas, con mejoras en la elección del idioma de salida y la validación de evidencias del texto original.
- Se agrupan en párrafos las transcripciones consecutivas del mismo hablante y los intervalos sin detección rodeados por el mismo hablante. Se mantienen las divisiones manuales, los cambios de fuente y las intervenciones realmente superpuestas, sin cambiar las asignaciones originales de hablantes.
- Se han organizado los múltiples botones de evidencias del resumen en enlaces de ubicación y un menú de evidencias.
- Tras confirmar, puedes eliminar **la reunión completa y todas sus fuentes de audio, transcripciones, resúmenes y audio original**. Se conservan las tareas ya registradas y los archivos guardados externamente.
- Puedes guardar el ZIP/WAV original de una fuente individual o el ZIP original de todas las fuentes desde Files en iPhone y iPad o la ventana de guardado en Mac. Se conservan por separado los archivos y los desfases de inicio de cada fuente.
- La importación de audio en Mac incorpora arrastrar y soltar archivos desde Finder y un botón de pegar y ⌘V. No se modifican los archivos originales.
- Al recuperar reuniones, ahora se guardan los cambios en hijos y pertenencia antes de limpiar los registros de recuperación. Si falla el guardado, se conservan las transcripciones, el audio original y los registros de recuperación existentes.
- Cambiar solo los ajustes de salida del resumen conserva el resumen existente. También se mantiene el registro de tareas si puede comprobarse que las evidencias originales siguen siendo las mismas; si cambian realmente o no pueden validarse, se bloquea el registro.
- Se han mejorado la detección de actividad de reuniones y la captura de salida por app en Mac. Se comprueban los ejecutables de las apps elegidas y la relación de propiedad de los procesos; si cambia el destino de captura, se detiene para solicitar una nueva selección. No se admite la captura por app de Safari que utiliza helpers compartidos de WebKit.

### Ajustes, cuentas y sincronización

- Se han eliminado de la pantalla de cuentas de IA los niveles de plan que no podían verificarse y las listas de modelos innecesarias, para centrarse en el estado y la prueba de conexión, los consentimientos de envío y el uso.
- Se han corregido el formato JSON de las solicitudes a ChatGPT y el procesamiento de respuestas completadas. Se muestran por cuenta los tokens de entrada, salida y entrada en caché y el número de respuestas comprobados en este dispositivo; no deben interpretarse como el uso total de la cuenta ni como su límite restante.
- Se ha corregido un problema que volvía a programar sincronizaciones completas por registros de conexión de cuentas que no habían cambiado.
- Se han mejorado la compatibilidad y la recuperación de los registros de eliminación de iCloud. Los identificadores duplicados con contenido diferente no se sobrescriben arbitrariamente: solo se pone en espera el elemento afectado y continúa la sincronización de los demás cambios.
- Se han reducido las explicaciones duplicadas y las entradas vacías de los ajustes de reuniones, IA y funciones beta, y se evita que las filas de modelos y los valores seleccionados se corten en pantallas pequeñas o con texto grande.
- Se ha ampliado el área táctil de los botones de restablecer y crear perfiles de personalidad en iPad.
- Se ha añadido **Consentimiento publicitario y privacidad** a los ajustes de iPhone y iPad. Se vuelve a comprobar el estado del consentimiento de Google y los errores de formulario no se tratan como consentimiento completado. Mac sigue excluido de la publicidad.

<a id="version-1-0-13-12"></a>
## 1.0.13 (12)

- Las comprobaciones de información de conexión protegida durante la sincronización automática se realizan sin ventanas de autenticación; en las operaciones separadas de autorización se indican el propósito, el grupo actual y los estados de cancelación y espera.
- Los pequeños cambios de sincronización se guardan en lotes limitados para reducir las escrituras en disco y las solicitudes de exportación de CloudKit. Se conservan los originales, los identificadores de revisión, la reanudación tras fallos intermedios y la gestión de cancelaciones.
- Se conservan la fase del fallo y los códigos del SDK de errores de audio del sistema en reuniones, y se orienta sobre los permisos de captura de Mac. Los errores no se pierden aunque la recopilación de diagnósticos se autorice más tarde.
- Al cancelar la redacción de un informe de error o fallar el envío, se mantienen la revisión de diagnósticos, el borrador y el identificador de envío; solo se marca como entregado cuando se recibe realmente el diagnóstico.

<a id="version-1-0-12-11"></a>
## 1.0.12 (11)

- Se han mejorado la densidad de la vista mensual del calendario móvil, las vistas de año, día y varios días, el desplazamiento continuo, los gestos de pellizco, el acceso a hoy y la visualización en pantallas estrechas de iPad.
- En el calendario de Mac puedes crear eventos haciendo clic o arrastrando en horas vacías, ajustar las horas arrastrando los bordes de los eventos y editarlos o eliminarlos con clic secundario.
- Al editar o eliminar eventos directamente, se conservan las conexiones con tareas, el historial de finalización, las recurrencias y los límites de zona horaria; se ha reforzado la prevención de que el registro automático vuelva a crear eventos eliminados.
- Se han añadido formas de onda de la entrada real, Live Activity en iPhone y iPad e indicadores de grabación en la barra de menús de Mac. La transcripción en tiempo real utiliza el modelo predeterminado de Apple; Whisper es opcional y solo procesa después de terminar.
- Se distinguen los fallos de transcripción durante la grabación de los fallos al guardar el audio original, y se comprueba si la transcripción de Apple admite el formato real de entrada.
- La importación de audio de Mac utiliza permisos de lectura de archivos seleccionados por el usuario y el panel nativo de apertura. Guarda y reproduce localmente sin modificar el original.
- Los ajustes se han organizado según la función de IA, reuniones, tareas y rutinas. Se distingue el estado real de preparación de Apple Intelligence del consentimiento para un modelo local alternativo; el análisis externo solo se ejecuta con conexión, región compatible y los consentimientos individuales para compartir datos.
- Se han eliminado las ventanas de éxito de sincronización de correo y se muestra un punto azul en los correos nuevos aún no abiertos.
- Se han fijado la búsqueda y los filtros de tareas, y puedes crear tareas con un doble clic o doble toque en el espacio vacío.
- Al cambiar de pantalla en Duo, se conserva el borrador de la nueva tarea y, en pantallas pequeñas, el botón de guardar ya no tapa el área de introducción.
- Se han mejorado los botones, la edición y el contraste de las tareas de Mac, así como la consulta de eventos y el desplazamiento del calendario.

<a id="version-1-0-11-10"></a>
## 1.0.11 (10)

- El banner de tareas de iPhone y iPad se ha trasladado desde la parte inferior de la pantalla a un área fija bajo las categorías.
- La búsqueda de idiomas de Mac se ha colocado en la parte superior de la pantalla de selección y se ha corregido que el campo de búsqueda permaneciera al volver a la pantalla anterior.
- El botón de la barra lateral del calendario de Mac se ha trasladado a la barra de herramientas superior y se ha corregido la continuidad de las semanas del mes anterior y siguiente para evitar duplicados.
- Se han corregido la desaparición de eventos debido a tareas vinculadas y el espacio excesivo en la parte superior de la agenda diaria.
- Las vistas previas al arrastrar tareas incluyen metadatos y se han unificado los controles de instalación, cancelación y eliminación de modelos.
- La línea de tiempo de conversaciones de reuniones se ha organizado alrededor del hablante, la hora y el contenido, reduciendo los títulos repetidos del mismo hablante y los espacios.
- Se han corregido la escala horaria y los errores de colocación de la agenda diaria, y se han mejorado el editor de tareas en pantallas grandes y las áreas de clic de las filas de conexión de Gmail y Outlook.
- Se ha mejorado la respuesta del calendario continuo de Mac al desplazamiento y a los cambios de tamaño de ventana y se ha eliminado el borde innecesario de selección de semana.

<a id="version-1-0-11-9"></a>
## 1.0.11 (9)

- Se han organizado los ajustes de tareas para gestionar las notificaciones de plazos y la IA y las reglas de ordenación por prioridad, y se permite editar títulos y notas desde el tablero de Mac.
- Puedes elegir directamente qué calendarios usar para analizar tareas. Al deseleccionar uno, solo se detienen las nuevas importaciones y las actualizaciones de propuestas no aprobadas; se conservan las tareas aprobadas.
- Se han separado la conexión de cuentas de IA y el consentimiento de envío de la instalación, cancelación y eliminación de modelos locales. Los modelos no se descargan solo por abrir la pantalla.
- El alcance opcional de almacenamiento en iCloud se amplía a correos, reuniones, rutinas, vocabulario y ajustes. La información de conexión utiliza el Llavero de iCloud; se excluyen los datos de salud, los permisos del sistema operativo y los modelos descargados.
- El audio completo de la reunión y la línea de tiempo de conversación se reproducen alineados con el tiempo común de las fuentes, y se recuerdan los últimos idiomas elegidos para el audio y el resumen.
- Se permite revisar y aprobar las evidencias y los horarios de las sugerencias de rutinas; los registros de salud y ejercicio de dispositivos iOS compatibles se conectan con permisos y consentimientos separados.
- Puedes revisar y enviar comentarios y los diagnósticos elegidos sin iniciar sesión. Solo se indica éxito cuando se recibe un número de recepción real.
- Se han mejorado los ajustes de reproducción, las formas de onda, el tablero de tareas, el tutorial y la visualización del calendario mensual de Mac.
- Se han corregido un fallo de la barra de herramientas inactiva de Mac, la inicialización innecesaria de Metal cuando no se utiliza ningún modelo y problemas al guardar y reproducir FLAC de reuniones cortas.
- Los elementos pendientes de registro se excluyen de la ordenación masiva con IA, las notificaciones y el registro automático en el calendario.

{% include release-history.html %}
