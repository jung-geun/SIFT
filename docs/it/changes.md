---
layout: default
locale: it
lang: it
page_key: changes
permalink: /it/changes.html
title: Novità
description: Nuove funzioni, miglioramenti e correzioni di ogni versione di SIFT.
---

# Novità

<a id="version-1-0-17"></a>
## 1.0.17

### Attività, note, connessione e sincronizzazione

- Filtra le attività per tag nell'elenco e nella bacheca.
- Le note possono suggerire attività con l'IA sul dispositivo. Vengono aggiunti solo i suggerimenti scelti e quelli uguali a un'attività esistente sono segnalati come duplicati.
- Su Mac, attiva la connessione MCP nelle impostazioni per consentire agli strumenti IA locali di leggere, aggiungere, modificare e completare le attività su questo dispositivo. È disattivata per impostazione predefinita e richiede un token.
- Verso iCloud vengono inviati meno dati: i corpi HTML delle email restano su ciascun dispositivo e la cronologia di azioni e controlli più vecchia di 120 giorni viene ripulita automaticamente.
- Un ordinamento IA manuale che non risponde termina con un errore dopo 10 minuti, e l'analisi delle email non mostra più il banner di ordinamento.

<a id="version-1-0-16"></a>
## 1.0.16

### Rimozione della pubblicità

- Rimossi annunci e controlli del consenso pubblicitario. Tutte le funzioni sono gratuite, senza acquisti in-app.

### Sincronizzazione, posta e priorità

- Sincronizzazione, controllo della posta, elaborazione di calendario e riunioni e ordinamento per priorità ora procedono in modo indipendente.
- Con iCloud vengono sincronizzati solo gli elementi modificati e la priorità viene ordinata solo quando si aggiunge una nuova attività. Completare o modificare un’attività esistente non riordina più tutto.
- Con l’app aperta, nuova posta e relativi contenuti vengono controllati circa ogni 45 secondi e ogni dispositivo analizza le azioni delle nuove e-mail. Le analisi non riuscite vengono ritentate a intervalli crescenti.
- Corretta la ripetizione dell’avviso «Dati locali ripristinati» e del banner «Ordinamento priorità con IA…» durante l’analisi della posta.

<a id="version-1-0-15"></a>
## 1.0.15

### Elenchi di attività ed email

- Le righe di attività ed email su Mac non mostrano più frecce permanenti. Al passaggio del mouse appare Altro a destra: il clic sulla riga apre i dettagli; Altro o il clic destro apre solo le azioni.
- Su iPhone e iPad, i dettagli delle attività usano righe standard per Completa ed Elimina al posto di grandi pulsanti pieni. Elimina usa il colore distruttivo standard e Aggiungi tag ha un aspetto più leggero.

### Calendario

- Nell’angolo superiore sinistro del calendario su iPhone e iPad vengono mostrati insieme anno e mese, aggiornati in base al mese raggiunto con lo scorrimento. Anche a cavallo dell’anno puoi identificare correttamente anno e mese.
- Anche i titoli dei mesi all’interno del calendario mostrano l’anno, per distinguere lo stesso mese in anni diversi.

- La vista settimanale mostra due o tre giorni alla volta su iPhone e nei layout stretti di iPad; i layout ampi di iPad possono mostrare tutti e sette i giorni.
- Le date scorrono orizzontalmente con l’inerzia nativa. Scorrere le date verso destra non torna più alla schermata precedente; il pulsante Indietro resta disponibile.
- Gli eventi di un’intera giornata o di almeno un giorno appaiono come un’unica barra continua. Intestazioni, colonne orarie e barre scorrono insieme, con le ore fisse. Gli eventi con orario di meno di un giorno rimangono nel programma di ogni data anche se attraversano mezzanotte.

### Email

- Le attività vengono proposte solo dagli elementi **Richiede verifica o intervento** dell’analisi del corpo completo. Se non ci sono elementi, l’oggetto o il riepilogo dell’email non vengono trasformati in attività; puoi salvare separatamente un’attività inserita a mano.
- Puoi salvare separatamente più interventi della stessa email, evitando di registrare due volte lo stesso elemento anche dopo averne modificato il titolo. Anche gli eventi del calendario aggiunti manualmente sono distinti per attività, mantenendo il riferimento all’email originale.
- Una connessione IMAP interrotta viene ristabilita alla consultazione successiva e un errore nel contrassegno come letto non impedisce più la ricezione del corpo del messaggio. Le operazioni di contrassegno come letto e spostamento nel cestino non vengono eseguite tramite la connessione di un altro account.
- L’elenco e i corpi completi vengono salvati sul dispositivo all’attivazione dell’app e periodicamente. La cache viene mantenuta anche con l’analisi AI disattivata; la raccolta in background riguarda solo gli account autorizzati e l’orario di esecuzione è deciso da iOS.
- Uniformati i margini superiore e inferiore delle schede di riepilogo delle email e migliorata la leggibilità dei nomi lunghi nella schermata di selezione degli interventi.
- Vengono recuperati testo completo e HTML di visualizzazione senza grandi allegati, conservando le azioni a fine messaggio. Un errore di connessione locale non cancella riepiloghi sincronizzati validi; annullare un’eliminazione conserva l’origine dell’azione e previene duplicati.

### Impostazioni e sincronizzazione

- Nella schermata **Conflitti di sincronizzazione** puoi confrontare le versioni e le differenze di ogni elemento e scegliere direttamente quale applicare. Se un elemento cambia durante il confronto viene richiesta una nuova verifica; la sincronizzazione degli altri elementi senza conflitti continua.
- Prima di risolvere un conflitto, la versione originale viene conservata sul dispositivo e può essere confrontata e ripristinata da **Versioni conservate**. La versione scelta direttamente viene usata per unire in uno solo i duplicati dello stesso elemento.
- Le indicazioni per risolvere gli errori dei moduli di privacy pubblicitaria distinguono errori di configurazione dell’app, errori di rete e timeout e mancata disponibilità del modulo. I problemi di configurazione Google non vengono presentati come errori risolvibili con un semplice nuovo tentativo.
- Migliorata la compatibilità del ripristino iCloud delle attività precedenti. La versione 1.0.14 non legge le nuove attività da azioni email e può interrompere la sincronizzazione: aggiorna tutti gli iPhone, iPad e Mac dello stesso account iCloud.

<a id="version-1-0-14-13"></a>
## 1.0.14 (13)

### Riunioni

- Accanto alle frasi del riepilogo classificate come attività compare il pulsante **Aggiungi attività**. La frase verificata viene aggiunta invariata alla coda di revisione senza elenchi separati di candidati né un nuovo riepilogo del titolo dell’attività, mantenendo la verifica dei riscontri originali e la prevenzione dei duplicati.
- In **Riepiloga di nuovo** puoi scegliere direttamente Apple Intelligence, GPT-6.1 Sol o GPT-6 Luna. GPT viene usato solo con un account collegato e il consenso all’invio delle riunioni specifico del dispositivo; errori e annullamenti preservano il risultato precedente.
- Corretto un problema che impediva di scegliere il formato e modificare le istruzioni quando le istruzioni personalizzate del riepilogo erano vuote.
- L’elaborazione delle riunioni lunghe con Apple Intelligence è suddivisa in fasi; migliorate l’impostazione della lingua di uscita e la verifica dei riscontri nel contenuto originale.
- Le trascrizioni consecutive dello stesso parlante e gli intervalli non rilevati preceduti e seguiti dallo stesso parlante vengono raggruppati in paragrafi. Vengono mantenuti separazioni manuali, cambi di sorgente e interventi realmente sovrapposti, senza modificare le assegnazioni originali dei parlanti.
- I numerosi pulsanti dei riscontri del riepilogo sono stati organizzati in collegamenti alle posizioni e un menu dei riscontri.
- Dopo una conferma, puoi eliminare **l’intera riunione e tutte le sue sorgenti audio, trascrizioni, riepiloghi e registrazioni originali**. Le attività già registrate e i file salvati esternamente rimangono.
- Puoi salvare lo ZIP originale o il WAV di una singola sorgente oppure lo ZIP originale di tutte le sorgenti tramite File su iPhone e iPad e la finestra di salvataggio su Mac. I file e gli offset iniziali delle diverse sorgenti vengono mantenuti distinti.
- L’importazione audio su Mac ora supporta il trascinamento dei file dal Finder, un pulsante Incolla e ⌘V. I file originali non vengono modificati.
- Durante il recupero di una riunione, i dati di recupero vengono rimossi dopo il salvataggio delle modifiche ai figli e alle appartenenze. Se il salvataggio fallisce, trascrizioni, audio originali e dati di recupero esistenti rimangono.
- Cambiare solo le impostazioni di uscita del riepilogo mantiene il riepilogo esistente. Se è possibile verificare che i riscontri originali siano invariati, rimane disponibile anche la registrazione delle attività; se i riscontri cambiano effettivamente o non sono verificabili, la registrazione viene bloccata.
- Migliorati il rilevamento delle riunioni su Mac e l’acquisizione dell’uscita per app. Vengono verificati l’eseguibile dell’app selezionata e i rapporti di appartenenza dei processi; se la destinazione cambia, l’acquisizione si interrompe e richiede una nuova selezione. L’acquisizione per app di Safari, che utilizza helper WebKit condivisi, non è supportata.

### Impostazioni, account e sincronizzazione

- Rimossi dalla schermata degli account AI i livelli di abbonamento non verificabili e gli elenchi di modelli superflui; la schermata è ora incentrata su stato del collegamento, test, consensi alla trasmissione e utilizzo.
- Corretti il formato delle richieste JSON ChatGPT e la gestione delle risposte completate. Vengono mostrati token di input, output e input nella cache e numero di risposte verificati su questo dispositivo per account, senza considerarli utilizzo dell’intero account o limiti residui.
- Corretto un problema per cui record invariati di collegamento degli account pianificavano ripetutamente sincronizzazioni complete.
- Migliorati compatibilità e recupero dei record di eliminazione iCloud. Identificatori duplicati con contenuti diversi non vengono sovrascritti arbitrariamente: viene sospeso solo l’elemento interessato e la sincronizzazione delle altre modifiche continua.
- Ridotte le spiegazioni duplicate e le voci vuote nelle impostazioni di riunioni, AI e funzioni beta; righe dei modelli e valori selezionati non vengono più tagliati su schermi piccoli o con caratteri grandi.
- Ampliate le aree toccabili dei pulsanti per reimpostare e generare il profilo persona su iPad.
- Aggiunto **Consenso pubblicitario e privacy** alle impostazioni di iPhone e iPad. Lo stato del consenso Google viene ricontrollato e gli errori dei moduli non sono trattati come consenso completato. Su Mac continua a non essere prevista pubblicità.

<a id="version-1-0-13-12"></a>
## 1.0.13 (12)

- Le verifiche delle informazioni protette di collegamento per la sincronizzazione automatica avvengono senza finestre di autenticazione; l’operazione di approvazione separata spiega scopo dell’autenticazione, gruppo corrente e stati di annullamento e attesa.
- Le piccole modifiche di sincronizzazione vengono salvate in gruppi limitati per ridurre le scritture su disco e le richieste di esportazione CloudKit. Rimangono preservati originali, ID di revisione, riavvio dopo errori intermedi e gestione degli annullamenti.
- Gli errori dell’audio di sistema delle riunioni mantengono fase di errore e codice SDK, con indicazioni sui permessi di acquisizione Mac. Gli errori non vengono persi se la raccolta diagnostica viene autorizzata successivamente.
- Annullare la compilazione di una segnalazione o fallire l’invio mantiene verifica diagnostica, bozza e ID di invio; la consegna è segnata come completata solo dopo l’effettiva ricezione della diagnostica.

<a id="version-1-0-12-11"></a>
## 1.0.12 (11)

- Migliorati densità della vista mensile, viste anno, giorno e più giorni, scorrimento continuo, pinch, ritorno a oggi e layout su iPad stretto nel calendario mobile.
- Nel calendario Mac puoi creare eventi con clic o trascinamento negli spazi liberi, regolare gli orari trascinando i bordi e modificare o eliminare con il clic destro.
- La modifica e l’eliminazione diretta degli eventi mantengono collegamenti alle attività esistenti, registrazioni di completamento, ricorrenze e confini dei fusi orari; rafforzata la prevenzione della ricreazione automatica degli eventi eliminati.
- Aggiunti la forma d’onda dell’ingresso effettivo, la Live Activity su iPhone e iPad e l’indicatore di registrazione nella barra dei menu Mac. La trascrizione in tempo reale usa il modello predefinito Apple; Whisper facoltativo viene usato solo dopo la registrazione.
- Distinti errori di trascrizione e di salvataggio dell’audio originale durante la registrazione; migliorata la verifica del supporto effettivo del formato di ingresso della trascrizione Apple.
- L’importazione audio su Mac utilizza l’accesso in lettura ai file scelti dall’utente e un pannello nativo di apertura. Salvataggio e riproduzione avvengono localmente senza modificare gli originali.
- Riorganizzate le impostazioni secondo i ruoli di AI, riunioni, attività e routine. Lo stato effettivo di preparazione di Apple Intelligence è distinto dal consenso all’uso di un modello locale alternativo; le analisi esterne vengono eseguite solo con collegamento, regione supportata e singoli consensi alla condivisione.
- Rimosso il popup di sincronizzazione email riuscita; i nuovi messaggi non ancora aperti sono indicati con un punto blu.
- Ricerca e filtri delle attività rimangono fissi; un doppio clic o doppio tocco negli spazi vuoti permette di creare attività.
- Le bozze di nuove attività vengono mantenute passando tra le schermate Duo; sui piccoli schermi il pulsante Salva non copre l’area di inserimento.
- Migliorati pulsanti, modifica e contrasto delle attività su Mac, nonché consultazione e scorrimento degli eventi del calendario.

<a id="version-1-0-11-10"></a>
## 1.0.11 (10)

- Il banner delle attività su iPhone e iPad è stato spostato dal fondo dello schermo a un’area fissa sotto le categorie.
- La ricerca della lingua su Mac è stata spostata in cima alla schermata di selezione; il campo di ricerca non rimane più tornando alla schermata precedente.
- Il pulsante della barra laterale del calendario Mac è stato spostato nella barra degli strumenti superiore; le settimane dei mesi precedente e successivo proseguono senza duplicati.
- Corretti la scomparsa degli eventi a causa di attività collegate e lo spazio eccessivo sopra la vista giornaliera degli impegni.
- Aggiunti metadati all’anteprima di trascinamento delle attività; uniformati i controlli per installare, annullare ed eliminare i modelli.
- La timeline delle conversazioni delle riunioni è stata riorganizzata intorno a parlante, orario e testo, riducendo titoli ripetuti dello stesso parlante e spazi vuoti.
- Corretti gli errori di scala oraria e posizionamento nella vista giornaliera; migliorati l’editor delle attività sui grandi schermi e le aree cliccabili delle righe di collegamento Gmail e Outlook.
- Migliorata la risposta del calendario continuo Mac allo scorrimento e al ridimensionamento delle finestre; rimossi bordi di selezione delle settimane superflui.

<a id="version-1-0-11-9"></a>
## 1.0.11 (9)

- Le impostazioni delle attività ora permettono di gestire avvisi di scadenza, AI per l’ordinamento delle priorità e regole; sul pannello Mac è possibile modificare titoli e note.
- Puoi scegliere direttamente i calendari da usare nell’analisi delle attività. Deselezionarli interrompe solo le nuove importazioni e l’aggiornamento delle proposte non approvate; le attività approvate rimangono.
- Separati collegamento degli account AI e consensi alla trasmissione dalle operazioni di installazione, annullamento ed eliminazione dei modelli locali. Aprire una schermata non scarica modelli.
- L’ambito facoltativo di salvataggio iCloud è stato esteso a email, riunioni, routine, dizionari e impostazioni. Le informazioni di collegamento usano il Portachiavi iCloud; dati sanitari, permessi del sistema operativo e modelli scaricati sono esclusi.
- L’audio complessivo e la timeline delle conversazioni delle riunioni vengono riprodotti allineandoli al tempo comune delle sorgenti; vengono ricordate le ultime lingue scelte per audio e riepilogo.
- Puoi rivedere e approvare riscontri e orari delle routine proposte; sui dispositivi iOS supportati, dati sanitari e di esercizio fisico si collegano con autorizzazioni e consensi separati.
- Puoi rivedere e inviare feedback e diagnostica selezionata senza effettuare l’accesso. L’invio è indicato come riuscito solo dopo la ricezione di un numero di conferma effettivo.
- Migliorati impostazioni di riproduzione, forme d’onda, pannello delle attività, tutorial e visualizzazione del calendario mensile Mac.
- Corretti un arresto anomalo della barra degli strumenti inattiva su Mac, l’inizializzazione Metal superflua quando non si usano modelli e problemi di salvataggio/riproduzione FLAC per riunioni brevi.
- Gli elementi in attesa di registrazione sono esclusi dall’ordinamento AI collettivo, dalle notifiche e dalla registrazione automatica nel calendario.

{% include release-history.html %}
