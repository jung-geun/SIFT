---
layout: default
locale: es
lang: es
page_key: email
permalink: /es/email-setup.html
title: Conectar el correo
description: Sigue los pasos para preparar una contraseña de aplicación de Gmail y conectar el correo a SIFT.
---

# Conectar el correo

SIFT conecta el correo mediante **IMAP**. Esta guía se basa en **Gmail**, cuya conexión se ha verificado. Crea una contraseña de aplicación en Google e introdúcela en SIFT para consultar tu bandeja de entrada y convertir las peticiones del correo en tareas.

Conectar el correo es opcional. Puedes usar la gestión básica de tareas sin hacerlo.

## 1. Activa la verificación en dos pasos de tu cuenta de Google

1. Inicia sesión en tu [cuenta de Google](https://myaccount.google.com/) con la dirección de Gmail que quieras conectar.
2. Ve a **Seguridad e inicio de sesión → Cómo inicias sesión en Google → Verificación en dos pasos**.
3. Sigue las instrucciones para activar la verificación en dos pasos. Si ya la utilizas, pasa al siguiente apartado.

La verificación en dos pasos es necesaria para crear contraseñas de aplicación. Consulta las [instrucciones de Google sobre la verificación en dos pasos](https://support.google.com/accounts/answer/185839?hl=ko) para obtener más información.

## 2. Crea una contraseña de aplicación para SIFT

1. Abre la [gestión de contraseñas de aplicación de Google](https://myaccount.google.com/apppasswords) con la misma cuenta. Si se solicita verificar tu identidad, completa la verificación.
2. Introduce un nombre que permita identificar la app y el dispositivo, como `SIFT iPhone`, y selecciona **Crear**.
3. Copia la **contraseña de aplicación de 16 caracteres** que aparece.

**No es la contraseña habitual de inicio de sesión de Google.** No introduzcas en SIFT tu contraseña habitual, códigos de verificación en dos pasos ni códigos de recuperación. Aquí solo se utiliza la contraseña de aplicación creada por separado por Google.

Si no aparece el menú de contraseñas de aplicación, consulta [Solución de problemas de conexión](#troubleshooting). No desactives la verificación en dos pasos ni la Protección Avanzada para conectarte.

## 3. Conecta Gmail en SIFT

1. Abre **Ajustes → Integración de correo** en SIFT.
2. Despliega **Conexión IMAP de Gmail**.
3. En **Dirección de correo de Gmail**, introduce la dirección completa de la cuenta en la que creaste la contraseña de aplicación.
4. Pega la contraseña de aplicación en **Google App Password**.
5. Activa **Recuperación automática de correo en segundo plano** solo si la necesitas. Puedes conectar la cuenta con esta opción desactivada.
6. Pulsa **Conectar Gmail por IMAP**. Si el dispositivo solicita verificar tu identidad, completa la verificación.
7. Al terminar la comprobación, la fila **Cuenta de Gmail** mostrará **Conectada**.

Los ajustes del servidor se aplican automáticamente. El servidor de Gmail es `imap.gmail.com`, el puerto es `993` y la conexión utiliza SSL/TLS. No necesitas introducir el servidor ni el puerto en la app. En las cuentas personales de Gmail, [IMAP está siempre activado](https://support.google.com/mail/answer/7126229?hl=ko), por lo que no es necesario habilitarlo en los ajustes de la web.

## Consulta el correo conectado

Consulta la bandeja de entrada en la pestaña **Correo**. Para obtener correo nuevo de inmediato, mantén pulsada la fila de la **Cuenta de Gmail** conectada en **Ajustes → Integración de correo** y selecciona **Comprobar correo ahora**.

- **Recuperación automática de correo en segundo plano** está desactivada por defecto. Si la activas, la contraseña de aplicación guardada podrá utilizarse incluso con el dispositivo bloqueado, una vez que lo hayas desbloqueado al menos una vez. Lee los riesgos de seguridad indicados antes de elegir.
- **Análisis automático del correo** es un ajuste independiente que sugiere tareas solo a partir de los elementos de Requiere revisión o acción del cuerpo completo. Si no hay elementos, no se sugieren tareas automáticamente; puedes introducirlas y guardarlas manualmente.
- La lista y los cuerpos completos se guardan en el dispositivo al activar la app y de forma periódica, con independencia del ajuste de análisis automático. La recuperación en segundo plano solo se aplica a las cuentas autorizadas; iOS decide cuándo puede ejecutarse, por lo que no se garantiza un intervalo fijo.
- Puedes ajustar la **Hora del análisis diario** de Gmail. El análisis IA en segundo plano de una cuenta Gmail autorizada se intenta una vez al día tras esa hora; no se garantiza el mismo análisis diario para Outlook. El periodo de análisis no limita el alcance actual de la recopilación IMAP de listas o cuerpos.

**Marcar un mensaje como leído o moverlo a la papelera también afecta al Gmail original.** Cargar la lista no marca los mensajes como leídos; se solicita marcar un mensaje no leído como leído después de obtener su cuerpo. Aunque falle el marcado como leído, puedes ver el cuerpo ya recibido. Moverlo a la papelera también afecta al mensaje original.

## Al desconectar la cuenta o cambiar de dispositivo

La contraseña de aplicación se guarda en el **Keychain de este dispositivo**. La información de conexión puede restaurarse si consientes explícitamente el almacenamiento completo en iCloud y utilizas la misma cuenta de Apple y el Llavero de iCloud, pero no se transfieren la aprobación de acceso por dispositivo ni la autorización de uso en segundo plano. En un dispositivo nuevo, comprueba la información de conexión y aprueba personalmente el acceso necesario, o crea una contraseña de aplicación para ese dispositivo y conéctalo.

1. En **Ajustes → Integración de correo**, mantén pulsada la fila de la cuenta conectada o deslízala hacia la izquierda y selecciona **Desconectar**.
2. SIFT elimina de este dispositivo la contraseña de aplicación y la información de la cuenta conectada.
3. En la [gestión de contraseñas de aplicación de Google](https://myaccount.google.com/apppasswords), **elimina** también las contraseñas de SIFT que ya no utilices.

**Desconectar en SIFT y revocar la contraseña de aplicación en Google son acciones distintas.** Si has perdido el dispositivo, elimínala primero en Google. Desconectar no elimina de forma masiva los correos originales ni los correos y tareas ya guardados.

<h2 id="troubleshooting">Solución de problemas de conexión</h2>

- **No aparece el menú de contraseñas de aplicación.** Comprueba que estás en la cuenta correcta y que la verificación en dos pasos está activada. El menú puede no estar disponible en cuentas de trabajo o educativas, en la verificación en dos pasos que solo utiliza llaves de seguridad o en el Programa de Protección Avanzada. Para cuentas de organizaciones, consulta al administrador si se permiten las contraseñas de aplicación e IMAP. [Ayuda oficial de Google](https://support.google.com/accounts/answer/185833?hl=ko)
- **Se rechaza la contraseña.** Comprueba que sea una contraseña de aplicación y no la habitual, y que la cuenta que la generó coincida con la dirección introducida. Si cambias tu contraseña habitual de Google, se revocan las contraseñas de aplicación existentes y debes crear una nueva.
- **La cuenta guardada aparece desconectada.** Resuelve los problemas de red o de verificación de identidad del dispositivo y pulsa **Volver a conectar**. Si la contraseña se ha revocado, selecciona **Sustituir App Password** e introduce una nueva contraseña de aplicación.
- **Aparece un error de tiempo de espera o de conexión segura.** Comprueba la conexión a Internet y prueba con otra red. Si utilizas una red de una organización, comprueba también si está bloqueado el puerto IMAP `993`.
- **La cuenta está conectada, pero no aparece correo.** Comprueba la bandeja de entrada de esa misma cuenta en la web de Gmail y recupera manualmente el correo nuevo en SIFT. La conexión puede ser correcta aunque la bandeja de entrada esté vacía.

Si necesitas ayuda, comunica únicamente el mensaje de error y las circunstancias en que se produjo. **No envíes contraseñas habituales, contraseñas de aplicación, códigos de verificación ni códigos de recuperación en consultas o comentarios.** Si compartes una pantalla, oculta también las direcciones de correo y el contenido de los mensajes.

<h2 id="outlook">Outlook y otros proveedores de correo</h2>

Los ajustes de SIFT también incluyen **Conexión IMAP de Outlook**, pero el método actual de contraseña de aplicación no coincide con el método de autenticación que exige Microsoft, por lo que no se garantiza que la conexión se complete. No apliques directamente a Outlook los pasos de Gmail.

- Las **cuentas personales de Outlook.com** requieren Modern Authentication. [Información de Microsoft sobre autenticación](https://support.microsoft.com/en-us/office/modern-authentication-methods-now-needed-to-continue-syncing-outlook-email-in-non-microsoft-email-apps-c5d65390-9676-4763-b41f-d7986499a90d)
- Exchange Online de las **cuentas de trabajo o educativas de Microsoft 365** bloquea la autenticación básica de IMAP, y las contraseñas de aplicación no permiten eludir este bloqueo. [Política de autenticación de Microsoft](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/deprecation-of-basic-authentication-exchange-online)

Esta limitación se debe a la política de autenticación del proveedor, no al propio IMAP. No introduzcas en su lugar la contraseña habitual de tu cuenta de Microsoft ni reduzcas la seguridad. Actualmente, SIFT no dispone de una pantalla de conexión genérica para introducir manualmente los servidores de otros proveedores.

[Volver a la guía de uso](workflows.html) · [Política de privacidad](privacy-policy.html)
