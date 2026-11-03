---
layout: default
locale: de
lang: de
page_key: email
permalink: /de/email-setup.html
title: E-Mail verbinden
description: So erstellen Sie ein Gmail-App-Passwort und verbinden Ihr E-Mail-Konto mit SIFT.
---

# E-Mail verbinden

SIFT verbindet E-Mail-Konten **über IMAP**. Diese Anleitung beschreibt **Gmail**, für das eine tatsächliche Verbindung bestätigt wurde. Erstellen Sie bei Google ein App-Passwort und geben Sie es in SIFT ein. Anschließend können Sie Ihren Posteingang ansehen und Anfragen aus E-Mails als Aufgaben organisieren.

Die E-Mail-Verbindung ist optional. Die grundlegende Aufgabenverwaltung können Sie auch ohne sie nutzen.

## 1. Bestätigung in zwei Schritten für Ihr Google-Konto aktivieren

1. Melden Sie sich mit der zu verbindenden Gmail-Adresse bei Ihrem [Google-Konto](https://myaccount.google.com/) an.
2. Öffnen Sie **Sicherheit und Anmeldung → So melden Sie sich in Google an → Bestätigung in zwei Schritten**.
3. Aktivieren Sie die Bestätigung in zwei Schritten gemäß den Anweisungen. Falls sie bereits aktiv ist, fahren Sie mit dem nächsten Schritt fort.

Für ein App-Passwort ist die Bestätigung in zwei Schritten erforderlich. Einzelheiten finden Sie in [Googles Anleitung zur Bestätigung in zwei Schritten](https://support.google.com/accounts/answer/185839?hl=ko).

## 2. Ein App-Passwort für SIFT erstellen

1. Öffnen Sie mit demselben Konto die [Verwaltung der Google-App-Passwörter](https://myaccount.google.com/apppasswords). Bestätigen Sie bei Aufforderung Ihre Identität.
2. Geben Sie einen Namen ein, der App und Gerät erkennbar macht, etwa `SIFT iPhone`, und wählen Sie **Erstellen**.
3. Kopieren Sie das angezeigte **16-stellige App-Passwort**.

**Dies ist nicht Ihr normales Google-Anmeldepasswort.** Geben Sie in SIFT weder Ihr normales Passwort noch einen Code für die Bestätigung in zwei Schritten oder einen Wiederherstellungscode ein. Hier wird ausschließlich das von Google gesondert erstellte App-Passwort verwendet.

Wenn der Menüpunkt für App-Passwörter fehlt, lesen Sie unten die [Hinweise zur Fehlerbehebung](#troubleshooting). Deaktivieren Sie für die Verbindung weder die Bestätigung in zwei Schritten noch das erweiterte Sicherheitsprogramm.

## 3. Gmail in SIFT verbinden

1. Öffnen Sie in SIFT **Einstellungen → E-Mail-Anbindung**.
2. Klappen Sie **Gmail-IMAP-Verbindung** auf.
3. Geben Sie unter **Gmail-E-Mail-Adresse** die vollständige Adresse des Kontos ein, für das Sie das App-Passwort erstellt haben.
4. Fügen Sie das App-Passwort unter **Google-App-Passwort** ein.
5. Aktivieren Sie **E-Mails automatisch im Hintergrund abrufen** nur bei Bedarf. Sie können die Verbindung auch bei deaktivierter Option herstellen.
6. Tippen Sie auf **Gmail-IMAP-Verbindung**. Bestätigen Sie bei Aufforderung auf dem Gerät Ihre Identität.
7. Nach der Prüfung erscheint in der Zeile **Gmail-Konto** der Status **Verbunden**.

Die Servereinstellungen werden automatisch übernommen. Der Gmail-Server ist `imap.gmail.com`, der Port `993`; die Verbindung erfolgt über SSL/TLS. Server und Port müssen Sie in der App nicht gesondert eingeben. Bei privaten Gmail-Konten ist [IMAP immer aktiviert](https://support.google.com/mail/answer/7126229?hl=ko); eine zusätzliche Aktivierung in den Webeinstellungen ist nicht nötig.

## Verbundene E-Mails ansehen

Öffnen Sie Ihren Posteingang im Tab **E-Mail**. Um sofort neue E-Mails abzurufen, halten Sie unter **Einstellungen → E-Mail-Anbindung** die verbundene Zeile **Gmail-Konto** gedrückt und wählen Sie **E-Mails jetzt abrufen**.

- **E-Mails automatisch im Hintergrund abrufen** ist standardmäßig deaktiviert. Wenn Sie die Option aktivieren, kann das gespeicherte App-Passwort nach dem ersten Entsperren des Geräts auch bei gesperrtem Gerät verwendet werden. Prüfen Sie vor Ihrer Entscheidung die erläuterten Sicherheitsrisiken.
- **Automatische E-Mail-Analyse** ist eine eigene Einstellung, die Aufgaben nur aus den Einträgen unter **Prüfung oder Bearbeitung erforderlich** des vollständigen Nachrichtentextes vorschlägt. Ohne solche Einträge werden keine Aufgaben automatisch vorgeschlagen; Sie können selbst eine Aufgabe eingeben und speichern.
- Liste und vollständige Nachrichtentexte werden unabhängig von der Einstellung für automatische Analysen beim Aktivieren der App und regelmäßig auf dem Gerät gespeichert. Die Hintergrundabfrage gilt nur für freigegebene Konten. Da iOS die Ausführungsmöglichkeiten bestimmt, ist kein festes Intervall garantiert.
- Sie können die **Uhrzeit der täglichen Analyse** für Gmail einstellen. Die Hintergrund-KI-Analyse eines freigegebenen Gmail-Kontos wird danach einmal täglich versucht; dieselbe tägliche Analyse ist für Outlook nicht garantiert. Der Analysezeitraum begrenzt den aktuellen IMAP-Abruf von Listen und Texten nicht.

**Das Markieren als gelesen und das Verschieben in den Papierkorb wirken sich auch auf die Original-E-Mails in Gmail aus.** Das Laden der Liste allein markiert nichts als gelesen. Erst nach dem Anzeigen des Inhalts einer ungelesenen E-Mail wird das Markieren als gelesen angefordert. Schlägt dies fehl, bleibt der bereits empfangene Nachrichtentext lesbar. Auch das Verschieben in den Papierkorb betrifft die Originalnachricht.

## Verbindung trennen oder Gerät wechseln

Das App-Passwort wird **in der Keychain dieses Geräts** gespeichert. Verbindungsinformationen können nach ausdrücklicher Zustimmung zur vollständigen iCloud-Speicherung mit demselben Apple-Konto und dem iCloud-Schlüsselbund wiederhergestellt werden. Gerätespezifische Zugriffsfreigaben und Hintergrundberechtigungen werden jedoch nicht übertragen. Prüfen Sie auf einem neuen Gerät die Verbindungsinformationen und genehmigen Sie die benötigten Zugriffe selbst, oder erstellen Sie ein eigenes App-Passwort für dieses Gerät und verbinden Sie es damit.

1. Halten Sie unter **Einstellungen → E-Mail-Anbindung** die Zeile des verbundenen Kontos gedrückt oder wischen Sie sie nach links und wählen Sie **Verbindung trennen**.
2. SIFT löscht das App-Passwort und die Informationen zum verbundenen Konto auf diesem Gerät.
3. **Löschen** Sie nicht mehr benötigte SIFT-App-Passwörter auch in der [Verwaltung der Google-App-Passwörter](https://myaccount.google.com/apppasswords).

**Das Trennen in SIFT und das Widerrufen eines App-Passworts bei Google sind getrennte Vorgänge.** Wenn Sie Ihr Gerät verloren haben, löschen Sie das Passwort zuerst bei Google. Das Trennen der Verbindung löscht nicht pauschal die Original-E-Mails oder bereits gespeicherte E-Mails und Aufgaben.

<h2 id="troubleshooting">Wenn die Verbindung nicht funktioniert</h2>

- **Der Menüpunkt für App-Passwörter fehlt.** Prüfen Sie das Konto und ob die Bestätigung in zwei Schritten aktiv ist. Bei Arbeits- oder Schulkonten, einer ausschließlich auf Sicherheitsschlüsseln beruhenden Bestätigung in zwei Schritten oder dem erweiterten Sicherheitsprogramm kann der Menüpunkt fehlen. Fragen Sie bei Organisationskonten die Administration, ob App-Passwörter und IMAP verfügbar sind. [Offizielle Google-Hilfe](https://support.google.com/accounts/answer/185833?hl=ko)
- **Das Passwort wird abgelehnt.** Prüfen Sie, ob es ein App-Passwort statt des normalen Passworts ist und ob Ausgabekonto und eingegebene Adresse übereinstimmen. Wenn Sie Ihr normales Google-Passwort ändern, werden bestehende App-Passwörter ebenfalls widerrufen; erstellen Sie dann ein neues.
- **Ein gespeichertes Konto erscheint als nicht verbunden.** Beheben Sie Netzwerkprobleme oder Probleme mit der Identitätsbestätigung auf dem Gerät und wählen Sie **Erneut verbinden**. Wurde das Passwort widerrufen, wählen Sie **App-Passwort ersetzen** und geben Sie ein neues App-Passwort ein.
- **Zeitüberschreitung oder Fehler bei der sicheren Verbindung.** Prüfen Sie Ihre Internetverbindung und versuchen Sie ein anderes Netzwerk. Prüfen Sie in Organisationsnetzwerken auch, ob der IMAP-Port `993` blockiert wird.
- **Verbunden, aber keine E-Mails sichtbar.** Prüfen Sie den Posteingang desselben Kontos in Gmail im Web und rufen Sie neue E-Mails in SIFT manuell ab. Eine Verbindung kann auch bei leerem Posteingang erfolgreich sein.

Wenn Sie Hilfe benötigen, teilen Sie nur den Fehlertext und die Umstände mit. **Senden Sie in Anfragen oder Feedback weder normale Passwörter noch App-Passwörter, Bestätigungs- oder Wiederherstellungscodes.** Verdecken Sie beim Teilen von Bildschirmaufnahmen auch E-Mail-Adressen und Nachrichteninhalte.

<h2 id="outlook">Outlook und andere E-Mail-Anbieter</h2>

In den SIFT-Einstellungen gibt es auch **Outlook über IMAP verbinden**. Die aktuelle Methode mit App-Passwort entspricht jedoch nicht dem von Microsoft verlangten Authentifizierungsverfahren; eine erfolgreiche Verbindung wird daher nicht garantiert. Übertragen Sie die Gmail-Anleitung nicht unverändert auf Outlook.

- **Private Outlook.com-Konten** verlangen Modern Authentication. [Microsoft-Hinweise zur Authentifizierung](https://support.microsoft.com/en-us/office/modern-authentication-methods-now-needed-to-continue-syncing-outlook-email-in-non-microsoft-email-apps-c5d65390-9676-4763-b41f-d7986499a90d)
- Exchange Online für **Microsoft 365-Arbeits- und Schulkonten** blockiert die IMAP-Basisauthentifizierung; App-Passwörter können dies nicht umgehen. [Microsoft-Authentifizierungsrichtlinie](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/deprecation-of-basic-authentication-exchange-online)

Diese Einschränkung beruht auf den Authentifizierungsrichtlinien des Anbieters, nicht auf IMAP selbst. Geben Sie stattdessen kein normales Microsoft-Kontopasswort ein und reduzieren Sie Ihre Sicherheit nicht. SIFT bietet derzeit keine allgemeine Verbindungsmaske zur manuellen Eingabe der Server anderer Anbieter.

[Zurück zur Anleitung](workflows.html) · [Datenschutzerklärung](privacy-policy.html)
