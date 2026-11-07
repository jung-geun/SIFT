---
layout: default
locale: it
lang: it
page_key: email
permalink: /it/email-setup.html
title: Collega la tua email
description: Guida alla creazione di una password per le app di Gmail e al collegamento della tua email a SIFT.
---

# Collega la tua email

Il collegamento email di SIFT utilizza **IMAP**. Questa guida si basa su **Gmail**, per cui è stato verificato un collegamento effettivo. Dopo aver creato una password per le app su Google e averla inserita in SIFT, puoi consultare la posta in arrivo e organizzare le richieste delle email come attività.

Il collegamento email è facoltativo. Puoi gestire le attività di base anche senza collegarlo.

## 1. Attiva la verifica in due passaggi del tuo account Google

1. Accedi al tuo [Account Google](https://myaccount.google.com/) con l’indirizzo Gmail da collegare.
2. Vai a **Sicurezza e accesso → Come accedi a Google → Verifica in due passaggi**.
3. Segui le istruzioni sullo schermo per attivare la verifica in due passaggi. Se la utilizzi già, passa al punto successivo.

La verifica in due passaggi è necessaria per creare una password per le app. Per i passaggi dettagliati, consulta la [guida di Google alla verifica in due passaggi](https://support.google.com/accounts/answer/185839?hl=ko).

## 2. Crea una password per le app destinata a SIFT

1. Con lo stesso account, apri la [gestione delle password per le app di Google](https://myaccount.google.com/apppasswords). Se viene chiesto di verificare la tua identità, completa la verifica.
2. Inserisci un nome che identifichi app e dispositivo, ad esempio `SIFT iPhone`, e scegli **Crea**.
3. Copia la **password per le app di 16 caratteri** visualizzata.

**Non è la normale password di accesso a Google.** Non inserire in SIFT la password abituale, codici della verifica in due passaggi o codici di recupero. Qui si utilizza esclusivamente la password per le app generata separatamente da Google.

Se non compare il menu delle password per le app, consulta la sezione [Risoluzione dei problemi di collegamento](#troubleshooting). Non disattivare la verifica in due passaggi o la protezione avanzata per effettuare il collegamento.

## 3. Collega Gmail in SIFT

1. In SIFT, apri **Impostazioni → Collegamento email**.
2. Espandi **Collega Gmail tramite IMAP**.
3. In **Indirizzo email Gmail**, inserisci l’indirizzo completo dell’account per cui hai creato la password per le app.
4. Incolla la password per le app in **Google App Password**.
5. Attiva **Recupero automatico delle email in background** solo se necessario. Puoi effettuare il collegamento anche lasciandolo disattivato.
6. Tocca il pulsante **Collega Gmail tramite IMAP**. Se il dispositivo chiede di verificare la tua identità, completa la verifica.
7. Al termine, nella riga **Account Gmail** compare **Collegato**.

Le impostazioni del server vengono applicate automaticamente. Il server Gmail è `imap.gmail.com`, la porta è `993` e il collegamento utilizza SSL/TLS. Non è necessario inserire separatamente server o porta nell’app. Per gli account Gmail personali, [IMAP è sempre attivo](https://support.google.com/mail/answer/7126229?hl=ko), quindi non occorre abilitarlo separatamente nelle impostazioni web.

## Controlla la posta collegata

Consulta la posta in arrivo nella scheda **Email**. Per recuperare subito nuovi messaggi, tieni premuta la riga dell’**Account Gmail** collegato in **Impostazioni → Collegamento email** e scegli **Controlla la posta adesso**.

- Il **Recupero automatico delle email in background** è disattivato per impostazione predefinita. Se lo attivi, dopo il primo sblocco del dispositivo la password per le app salvata può essere utilizzata anche quando il dispositivo è bloccato. Scegli dopo aver esaminato i rischi di sicurezza indicati.
- L’**Analisi automatica delle email** è un’impostazione separata che propone attività solo dagli elementi **Richiede verifica o intervento** del corpo completo. Se non ci sono elementi, non vengono proposte attività automaticamente; puoi inserirne una e salvarla manualmente.
- L’elenco e i corpi completi vengono salvati sul dispositivo all’attivazione dell’app e periodicamente, indipendentemente dall’impostazione dell’analisi automatica. La raccolta in background riguarda solo gli account autorizzati; iOS decide le opportunità di esecuzione, quindi non è garantito un intervallo fisso.
- Quando l’analisi automatica è attiva, i testi completi salvati vengono elaborati separatamente sul dispositivo. L’analisi in background riguarda solo gli account autorizzati e iOS ne decide l’esecuzione. Il periodo di analisi non limita la raccolta IMAP.

**Contrassegnare come letto o spostare nel cestino si riflette anche su Gmail.** Il semplice caricamento dell’elenco non contrassegna i messaggi come letti; il contrassegno viene richiesto dopo la consultazione del corpo di un’email non letta. Anche se il contrassegno come letto fallisce, il corpo già ricevuto rimane consultabile. Anche lo spostamento nel cestino modifica il messaggio originale.

## Quando scolleghi l’account o cambi dispositivo

La password per le app viene conservata **nel Keychain di questo dispositivo**. Le informazioni di collegamento possono essere ripristinate se hai dato un consenso esplicito al salvataggio completo su iCloud e utilizzi lo stesso account Apple e il Portachiavi iCloud, ma le approvazioni di accesso e le autorizzazioni in background specifiche del dispositivo non vengono trasferite. Su un nuovo dispositivo, verifica le informazioni di collegamento e approva direttamente gli accessi necessari oppure crea una password per le app dedicata a quel dispositivo ed effettua il collegamento.

1. In **Impostazioni → Collegamento email**, tieni premuta la riga dell’account collegato o falla scorrere verso sinistra e scegli **Scollega**.
2. SIFT elimina da questo dispositivo la password per le app e le informazioni dell’account collegato.
3. **Elimina** anche le password per SIFT non più utilizzate nella [gestione delle password per le app di Google](https://myaccount.google.com/apppasswords).

**Scollegare l’account da SIFT e revocare la password per le app su Google sono operazioni distinte.** Se perdi il dispositivo, eliminala prima su Google. Lo scollegamento non elimina in blocco i messaggi originali né le email e le attività già salvate.

<h2 id="troubleshooting">Se il collegamento non funziona</h2>

- **Non trovo il menu delle password per le app.** Verifica di usare l’account corretto e di avere attivato la verifica in due passaggi. Il menu potrebbe non essere disponibile per account aziendali o scolastici, per la verifica in due passaggi basata esclusivamente su chiavi di sicurezza o per il programma di protezione avanzata. Per un account dell’organizzazione, chiedi all’amministratore se sono consentiti password per le app e IMAP. [Guida ufficiale di Google](https://support.google.com/accounts/answer/185833?hl=ko)
- **La password viene rifiutata.** Verifica che sia una password per le app e non la password abituale, e che l’account che l’ha generata corrisponda all’indirizzo inserito. Se cambi la normale password Google, vengono revocate anche le password per le app esistenti: occorre crearne una nuova.
- **L’account salvato risulta scollegato.** Risolvi eventuali problemi di rete o di verifica dell’identità sul dispositivo, quindi tocca **Ricollega**. Se la password è stata revocata, scegli **Sostituisci App Password** e inserisci una nuova password per le app.
- **Compare un errore di timeout o di collegamento sicuro.** Controlla la connessione Internet e prova una rete diversa. Se utilizzi una rete aziendale, verifica anche che la porta IMAP `993` non sia bloccata.
- **L’account è collegato, ma non vedo email.** Controlla la posta in arrivo dello stesso account sul sito Gmail, quindi recupera manualmente i nuovi messaggi in SIFT. Il collegamento può riuscire normalmente anche con la posta in arrivo vuota.

Se hai bisogno di aiuto, comunica solo il testo dell’errore e le circostanze in cui si è verificato. **Non inviare password abituali, password per le app, codici di autenticazione o codici di recupero nelle richieste di assistenza o nei feedback.** Se condividi lo schermo, nascondi anche indirizzi email e contenuti dei messaggi.

<h2 id="outlook">Outlook e altri fornitori email</h2>

Le impostazioni di SIFT includono anche **Collega Outlook tramite IMAP**, ma il metodo attuale con password per le app non corrisponde ai requisiti di autenticazione di Microsoft e non garantisce il successo del collegamento. Non applicare a Outlook gli stessi passaggi previsti per Gmail.

- Gli **account personali Outlook.com** richiedono Modern Authentication. [Guida di Microsoft all’autenticazione](https://support.microsoft.com/en-us/office/modern-authentication-methods-now-needed-to-continue-syncing-outlook-email-in-non-microsoft-email-apps-c5d65390-9676-4763-b41f-d7986499a90d)
- Per gli **account aziendali o scolastici Microsoft 365**, Exchange Online blocca l’autenticazione di base IMAP e le password per le app non consentono di aggirare il blocco. [Criteri di autenticazione di Microsoft](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/deprecation-of-basic-authentication-exchange-online)

Questa limitazione dipende dalle politiche di autenticazione del fornitore, non da IMAP in sé. Non inserire al suo posto la normale password dell’account Microsoft e non ridurre le misure di sicurezza. Attualmente SIFT non dispone di una schermata di collegamento generica per inserire manualmente i server di altri fornitori.

[Torna alla guida all’uso](workflows.html) · [Informativa sulla privacy](privacy-policy.html)
