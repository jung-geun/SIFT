---
layout: default
locale: de
lang: de
page_key: changes
permalink: /de/changes.html
title: Änderungen
description: Neue Funktionen, Verbesserungen und Fehlerbehebungen in den einzelnen SIFT-Versionen.
---

# Änderungen

<a id="version-1-0-16"></a>
## 1.0.16

### Werbung entfernt

- Werbung und Steuerelemente zur Werbeeinwilligung wurden entfernt. Alle App-Funktionen sind ohne In-App-Käufe kostenlos nutzbar.

### Synchronisierung, E-Mail und Priorität

- Synchronisierung, E-Mail-Abruf, Kalender- und Besprechungsverarbeitung sowie Prioritätssortierung laufen jetzt unabhängig voneinander.
- Nur geänderte Einträge werden mit iCloud synchronisiert, und die Priorität wird nur beim Hinzufügen einer neuen Aufgabe sortiert. Das Erledigen oder Bearbeiten bestehender Aufgaben löst keine vollständige Neuberechnung mehr aus.
- Solange die App geöffnet ist, werden neue E-Mails und Inhalte etwa alle 45 Sekunden abgerufen, und jedes Gerät analysiert Handlungspunkte neuer E-Mails. Fehlgeschlagene Analysen werden mit wachsenden Abständen wiederholt.
- Behoben: Der Hinweis „Lokale Daten wiederhergestellt“ wiederholte sich, und das Banner „KI sortiert Prioritäten…“ erschien während der E-Mail-Analyse.

<a id="version-1-0-15"></a>
## 1.0.15

### Aufgaben- und E-Mail-Listen

- Aufgaben- und E-Mail-Zeilen auf dem Mac zeigen keine dauerhaften Pfeile mehr. Beim Darüberfahren erscheint rechts das Menü Mehr. Ein Klick auf die Zeile öffnet Details; Mehr oder ein Rechtsklick öffnet nur Aktionen.
- Auf iPhone und iPad verwenden Aufgabendetails für Abschließen und Löschen Standardformularzeilen statt großer ausgefüllter Schaltflächen. Löschen nutzt die übliche Warnfarbe; auch Tag hinzufügen ist dezenter gestaltet.

### Kalender

- Im iPhone-/iPad-Kalender werden oben links Jahr und Monat gemeinsam angezeigt und beim Scrollen an den sichtbaren Monat angepasst. So sind auch beim Jahreswechsel Jahr und Monat erkennbar.
- Auch die Monatsüberschriften im Kalender zeigen jetzt das Jahr, damit sich gleiche Monate verschiedener Jahre unterscheiden lassen.

- Die Wochenansicht zeigt auf dem iPhone und in schmalen iPad-Layouts zwei oder drei Tage gleichzeitig; breite iPad-Layouts können alle sieben Tage anzeigen.
- Datumsbereiche lassen sich mit nativer Trägheit horizontal scrollen. Wischen nach rechts führt nicht mehr zur vorherigen Ansicht zurück; die Zurück-Taste bleibt verfügbar.
- Ganztägige und mindestens einen Tag dauernde Termine erscheinen als durchgehender Balken. Datumsköpfe, Stundenspalten und Balken scrollen gemeinsam, die Stunden bleiben fixiert. Zeitgebundene Termine unter einem Tag bleiben auch über Mitternacht im Stundenplan jedes Datums.

### E-Mail

- Aufgaben werden nur aus den Einträgen unter **Prüfung oder Bearbeitung erforderlich** der Analyse des vollständigen Nachrichtentextes vorgeschlagen. Ohne solche Einträge werden weder Betreff noch Zusammenfassung in Aufgaben umgewandelt; manuell eingegebene Aufgaben lassen sich separat speichern.
- Mehrere zu bearbeitende Punkte einer E-Mail lassen sich einzeln speichern. Auch nach Änderung des Titels wird derselbe Punkt nicht doppelt übernommen. Manuell hinzugefügte Kalendertermine werden ebenfalls je Aufgabe getrennt zugeordnet; der Verweis auf die Original-E-Mail bleibt erhalten.
- Eine unterbrochene IMAP-Verbindung wird beim nächsten Abruf wiederhergestellt. Schlägt das Markieren als gelesen fehl, wird der Empfang des Nachrichtentextes nicht mehr blockiert. Gelesen- und Papierkorb-Aktionen werden nicht über die Verbindung eines anderen Kontos ausgeführt.
- Liste und vollständige Nachrichtentexte werden beim Aktivieren der App und regelmäßig auf dem Gerät gespeichert. Der Cache bleibt auch bei deaktivierter KI-Analyse erhalten. Die Hintergrundabfrage gilt nur für freigegebene Konten; den Ausführungszeitpunkt bestimmt iOS.
- Die oberen und unteren Abstände der E-Mail-Zusammenfassungskarten wurden angeglichen. Lange Bezeichnungen lassen sich in der Auswahlansicht für zu bearbeitende Punkte besser lesen.
- Vollständiger Text und Anzeige-HTML werden ohne große Anhänge geladen; Aktionen am Nachrichtenende bleiben erhalten. Lokale Verbindungsfehler löschen keine gültigen synchronisierten Zusammenfassungen mehr. Rückgängig gemachte Löschungen bewahren Aktionsherkunft und Dublettenvermeidung.

### Einstellungen und Synchronisierung

- Unter **Synchronisierungskonflikte** können Sie Versionen und abweichende Inhalte je Eintrag vergleichen und die gewünschte Version selbst auswählen und übernehmen. Ändert sich ein Eintrag während des Vergleichs, muss er erneut geprüft werden. Andere konfliktfreie Einträge werden weiter synchronisiert.
- Vor der Konfliktlösung wird die ursprüngliche Version auf dem Gerät aufbewahrt. Unter **Aufbewahrte Versionen** lässt sie sich erneut vergleichen und wiederherstellen. Mit der direkt gewählten Version werden Dubletten desselben Eintrags zu einem Eintrag zusammengeführt.
- Bei Werbedatenschutzformularen werden App-Konfigurationsfehler, Netzwerkfehler und Zeitüberschreitungen sowie Fehler bei der Formularbereitstellung unterschieden und passende Lösungshinweise gegeben. Konfigurationsprobleme bei Google werden nicht als Fehler dargestellt, die sich durch einfaches Wiederholen beheben lassen.
- Verbesserte iCloud-Wiederherstellung älterer Aufgaben. Version 1.0.14 kann neue Aufgaben aus E-Mail-Aktionen nicht lesen und ihre Synchronisierung kann anhalten. Aktualisieren Sie alle iPhone-, iPad- und Mac-Geräte desselben iCloud-Kontos.

<a id="version-1-0-14-13"></a>
## 1.0.14 (13)

### Besprechungen

- Neben Sätzen einer Zusammenfassung, die als Aufgabe eingestuft wurden, steht **Aufgabe hinzufügen** zur Verfügung. Der geprüfte Satz wird unverändert in die Warteschlange zur Übernahme aufgenommen, ohne gesonderte Kandidatenliste und ohne erneute Zusammenfassung eines Aufgabentitels. Prüfung der Originalbelege und Dublettenvermeidung bleiben erhalten.
- Unter **Erneut zusammenfassen** können Apple Intelligence, GPT-6.1 Sol und GPT-6 Luna direkt gewählt werden. GPT wird nur mit verbundenem Konto und gerätespezifischer Zustimmung zur Besprechungsübertragung verwendet. Bei Fehler oder Abbruch bleiben die bisherigen Ergebnisse erhalten.
- Formatwahl und Bearbeitung der Anweisungen sind jetzt auch bei leeren benutzerdefinierten Zusammenfassungsanweisungen möglich.
- Die Verarbeitung langer Besprechungen mit Apple Intelligence wurde in Schritte aufgeteilt. Festlegung der Ausgabesprache und Prüfung der Originalbelege wurden verbessert.
- Aufeinanderfolgende Transkripte derselben sprechenden Person sowie nicht erkannte Abschnitte mit derselben Person davor und danach werden als Absätze gruppiert. Manuelle Trennungen, Quellenwechsel und tatsächliche überlappende Äußerungen bleiben erhalten; ursprüngliche Sprecherzuordnungen werden nicht verändert.
- Mehrere Belegschaltflächen in Zusammenfassungen wurden als Positionslink und Belegmenü geordnet.
- Nach Bestätigung lassen sich **die gesamte Besprechung und ihre Audioquellen, Transkripte, Zusammenfassungen und Originalaufnahmen** löschen. Bereits erstellte Aufgaben und extern gespeicherte Dateien bleiben erhalten.
- Das Original-ZIP/WAV einzelner Quellen oder das Original-ZIP aller Quellen lässt sich unter iPhone/iPad in Dateien und auf dem Mac über den Speicherdialog sichern. Dateien und Startoffsets mehrerer Quellen bleiben getrennt erhalten.
- Beim Audioimport auf dem Mac werden jetzt Drag-and-drop aus dem Finder sowie eine Einfügeschaltfläche und ⌘V unterstützt. Originaldateien werden nicht verändert.
- Bei der Besprechungswiederherstellung werden untergeordnete Datensätze und Änderungen der Zugehörigkeit gespeichert, bevor Wiederherstellungsaufzeichnungen bereinigt werden. Schlägt das Speichern fehl, bleiben bestehende Transkripte, Originalaudio und Wiederherstellungsaufzeichnungen erhalten.
- Wenn nur die Ausgabeeinstellungen einer Zusammenfassung geändert werden, bleibt die bestehende Zusammenfassung erhalten. Kann bestätigt werden, dass die Originalbelege unverändert sind, bleibt auch die Aufgabenübernahme verfügbar. Haben sich die tatsächlichen Belege geändert oder lassen sie sich nicht prüfen, wird die Übernahme blockiert.
- Die Erkennung von Besprechungsaktivitäten und die Erfassung von App-Ausgaben auf dem Mac wurden verbessert. Ausführbare Dateien und Prozesszugehörigkeit der ausgewählten App werden geprüft. Ändert sich das Erfassungsziel, wird gestoppt und eine neue Auswahl verlangt. Die appbezogene Safari-Erfassung über gemeinsam genutzte WebKit-helper wird nicht unterstützt.

### Einstellungen, Konten und Synchronisierung

- Nicht überprüfbare Tarifstufen und unnötige Modelllisten wurden aus der KI-Kontoansicht entfernt. Verbindungsstatus, Verbindungstest, Übertragungszustimmung und Nutzung stehen nun im Mittelpunkt.
- Das ChatGPT-JSON-Anfrageformat und die Verarbeitung abgeschlossener Antworten wurden korrigiert. Angezeigt werden auf diesem Gerät bestätigte Eingabe-, Ausgabe- und zwischengespeicherte Eingabetoken sowie Antwortzahlen je Konto. Sie sind nicht als gesamte Kontonutzung oder verbleibendes Limit zu verstehen.
- Ein Problem wurde behoben, bei dem unveränderte Kontoverbindungsdaten wiederholt eine vollständige Synchronisierung einplanten.
- Kompatibilität und Wiederherstellung von iCloud-Löschdatensätzen wurden verbessert. Doppelte Kennungen mit abweichendem Inhalt werden nicht willkürlich überschrieben; nur der betreffende Eintrag wird zurückgestellt, während andere Änderungen weiter synchronisiert werden.
- Doppelte Erläuterungen und leere Einträge in den Einstellungen für Besprechungen, KI und Betafunktionen wurden reduziert. Modellzeilen und Auswahlwerte werden auf kleinen Bildschirmen und bei großer Schrift seltener abgeschnitten.
- Die Berührungsflächen zum Zurücksetzen und Erstellen einer Persona auf dem iPad wurden vergrößert.
- In den iPhone-/iPad-Einstellungen wurde **Werbeeinwilligung und Datenschutz** hinzugefügt. Der Google-Einwilligungsstatus wird erneut geprüft; Formularfehler gelten nicht als abgeschlossene Einwilligung. Der Ausschluss von Werbung auf dem Mac bleibt bestehen.

<a id="version-1-0-13-12"></a>
## 1.0.13 (12)

- Geschützte Verbindungsinformationen werden bei der automatischen Synchronisierung ohne Authentifizierungsdialog geprüft. Gesonderte Freigabevorgänge erläutern Authentifizierungszweck, aktuelle Gruppe, Abbruch- und Wartezustand.
- Kleine Synchronisierungsänderungen werden in begrenzten Gruppen gespeichert, um Datenträgerschreibzugriffe und CloudKit-Exportanfragen zu reduzieren. Originale, Revisions-IDs sowie Wiederanlauf nach Teilfehlern und Abbruchverarbeitung bleiben erhalten.
- Bei Fehlern mit Besprechungs-Systemaudio bleiben Fehlerphase und SDK-Code erhalten; auf Mac-Aufnahmeberechtigungen wird hingewiesen. Fehler gehen auch dann nicht verloren, wenn die Diagnoseerfassung erst später erlaubt wird.
- Nach Abbruch der Berichtserstellung oder fehlgeschlagenem Versand bleiben Diagnoseprüfung, Entwurf und Einreichungs-ID erhalten. Erst ein tatsächlich erfolgreicher Diagnoseeingang gilt als abgeschlossene Übermittlung.

<a id="version-1-0-12-11"></a>
## 1.0.12 (11)

- Dichte der Monatsdarstellung, Jahres-, Tages- und Mehrtagesansicht, fortlaufendes Scrollen, Pinch-Gesten, Sprung zu heute und die Darstellung auf schmalen iPad-Bildschirmen im mobilen Kalender wurden verbessert.
- Im Mac-Kalender können Termine durch Klicken oder Ziehen in freien Zeitbereichen erstellt, Zeiten durch Ziehen an Terminrändern angepasst und Termine per Rechtsklick bearbeitet oder gelöscht werden.
- Beim direkten Bearbeiten und Löschen von Terminen bleiben bestehende Aufgabenverknüpfungen, Erledigungsaufzeichnungen, Wiederholungstermine und Zeitzonengrenzen erhalten. Gelöschte Termine sollen nicht durch automatische Eintragung erneut entstehen.
- Hinzugefügt wurden die tatsächliche Eingangswellenform, Live Activity auf iPhone/iPad und eine Aufnahmeanzeige in der Mac-Menüleiste. Live-Transkription verwendet Apples Standardmodell; optionales Whisper kommt nur nach dem Aufnahmeende zum Einsatz.
- Transkriptionsfehler während der Aufnahme werden von Fehlern beim Speichern des Originalaudios unterschieden. Die tatsächliche Unterstützung des Eingabeformats durch die Apple-Transkription wird geprüft.
- Für den Audioimport auf dem Mac werden die Leseberechtigung für die vom Nutzer gewählte Datei und der native Öffnendialog verwendet. Lokale Speicherung und Wiedergabe erfolgen ohne Änderung des Originals.
- Einstellungen wurden nach den Rollen von KI, Besprechungen, Aufgaben und Routinen geordnet. Der tatsächliche Bereitschaftsstatus von Apple Intelligence wird von der Zustimmung zu lokalen Ersatzmodellen unterschieden. Externe Analysen erfolgen nur mit Verbindung, unterstützter Region und gesonderter Weitergabezustimmung.
- Das Erfolgspopup nach E-Mail-Synchronisierung wurde entfernt. Noch nicht geöffnete neue E-Mails werden mit einem blauen Punkt markiert.
- Aufgabensuche und Filter wurden fixiert. Durch Doppelklick oder zweimaliges Tippen auf freie Flächen lassen sich Aufgaben erstellen.
- Beim Wechsel der Duo-Ansicht bleibt der Entwurf einer neuen Aufgabe erhalten. Auf kleinen Bildschirmen verdeckt die Speicherschaltfläche den Eingabebereich nicht mehr so leicht.
- Aufgabenschaltflächen, Bearbeitung und Kontrast sowie Abfrage und Scrollen von Kalenderterminen auf dem Mac wurden verbessert.

<a id="version-1-0-11-10"></a>
## 1.0.11 (10)

- Das Aufgabenbanner auf iPhone/iPad wurde vom unteren Bildschirmrand in einen festen Bereich unterhalb der Kategorien verschoben.
- Die Sprachsuche auf dem Mac steht oben in der Auswahlansicht und bleibt beim Zurückkehren zur vorherigen Ansicht nicht mehr sichtbar.
- Die Schaltfläche für die Mac-Kalenderseitenleiste wurde in die obere Werkzeugleiste verschoben. Wochen vorheriger und nachfolgender Monate schließen jetzt ohne Dopplungen aneinander an.
- Probleme mit durch verknüpfte Aufgaben verschwindenden Terminen sowie übermäßigem Leerraum oberhalb der Tagesansicht wurden behoben.
- Metadaten wurden zur Ziehvorschau von Aufgaben hinzugefügt und die Bedienelemente zur Modellinstallation, zum Abbrechen und Löschen vereinheitlicht.
- Die Gesprächszeitleiste für Besprechungen wurde auf Sprecher, Zeit und Inhalt ausgerichtet. Wiederholte Überschriften derselben Person und Leerraum wurden reduziert.
- Zeitraster und Platzierungsfehler der Tagesansicht wurden korrigiert. Aufgabenbearbeitung auf großen Bildschirmen und die Klickflächen der Gmail-/Outlook-Verbindungszeilen wurden verbessert.
- Scrollen und Anpassung an Fenstergrößen im fortlaufenden Mac-Kalender wurden verbessert. Unnötige Rahmen für die Wochenauswahl wurden entfernt.

<a id="version-1-0-11-9"></a>
## 1.0.11 (9)

- In den Aufgabeneinstellungen werden Fristerinnerungen sowie KI und Regeln zur Prioritätssortierung verwaltet. Auf dem Mac-Board lassen sich Titel und Notizen bearbeiten.
- Kalender für die Aufgabenanalyse können direkt ausgewählt werden. Eine Abwahl beendet nur neue Importe und Aktualisierungen unbestätigter Vorschläge; genehmigte Aufgaben bleiben erhalten.
- KI-Kontoverbindung und Übertragungszustimmung wurden von Installation, Abbruch und Löschen lokaler Modelle getrennt. Das bloße Öffnen einer Ansicht lädt keine Modelle herunter.
- Die optionale iCloud-Speicherung wurde auf E-Mails, Besprechungen, Routinen, Wörterbuch und Einstellungen erweitert. Verbindungsinformationen nutzen den iCloud-Schlüsselbund. Gesundheitsinformationen, OS-Berechtigungen und heruntergeladene Modelle sind ausgeschlossen.
- Gesamtaudio und Gesprächszeitleiste einer Besprechung werden an der gemeinsamen Zeitbasis der Quellen ausgerichtet wiedergegeben. Die zuletzt gewählten Audio- und Zusammenfassungssprachen werden gemerkt.
- Belege und Zeitplanung für Routinevorschläge können geprüft und genehmigt werden. Auf unterstützten iOS-Geräten werden Gesundheits- und Trainingsaufzeichnungen mit gesonderten Berechtigungen und Zustimmungen verbunden.
- Feedback und ausgewählte Diagnosen lassen sich ohne Anmeldung prüfen und senden. Erfolg wird nur nach Erhalt einer tatsächlichen Eingangsnummer angezeigt.
- Wiedergabeeinstellungen, Wellenformen, Aufgabenboard, Tutorial und die Darstellung des Mac-Monatskalenders wurden verbessert.
- Behoben wurden Abstürze mit inaktiven Mac-Werkzeugleisten, unnötige Metal-Initialisierung bei Nichtverwendung von Modellen sowie Probleme beim FLAC-Speichern und Abspielen kurzer Besprechungen.
- Zur Übernahme ausstehende Einträge sind von gebündelter KI-Sortierung, Erinnerungen und automatischer Kalendereintragung ausgeschlossen.

{% include release-history.html %}
