---
layout: default
locale: fr
lang: fr
page_key: changes
permalink: /fr/changes.html
title: Nouveautés
description: Nouvelles fonctions, améliorations et corrections de SIFT, version par version.
---

# Nouveautés

<a id="version-1-0-16"></a>
## 1.0.16

### Suppression de la publicité

- Suppression de la publicité et des options de consentement publicitaire. Toutes les fonctions sont gratuites, sans achats intégrés.

<a id="version-1-0-15"></a>
## 1.0.15

### Listes de tâches et de messages

- Les lignes de tâches et de messages sur Mac n’affichent plus de flèche permanente. Le survol révèle le menu Plus à droite : un clic sur la ligne ouvre les détails ; Plus ou un clic droit ouvre uniquement les actions.
- Sur iPhone et iPad, les détails des tâches utilisent des lignes de formulaire standard pour Terminer et Supprimer, au lieu de grands boutons pleins. Supprimer utilise la couleur destructive standard et Ajouter une étiquette est plus discret.

### Calendrier

- Sur iPhone et iPad, l’année et le mois sont affichés ensemble en haut à gauche du calendrier et actualisés selon le mois parcouru. Vous pouvez ainsi identifier l’année et le mois, même au passage d’une année à l’autre.
- Les titres des mois dans le calendrier affichent également l’année pour distinguer un même mois d’années différentes.

- La vue hebdomadaire affiche deux ou trois jours à la fois sur iPhone et dans les dispositions étroites sur iPad ; les dispositions larges sur iPad peuvent afficher les sept jours.
- Les dates défilent horizontalement avec une inertie native. Un balayage des dates vers la droite ne revient plus à l’écran précédent ; le bouton Retour reste disponible.
- Les événements sur toute la journée ou durant au moins un jour apparaissent en une barre continue. Les en-têtes, colonnes horaires et barres défilent ensemble, tandis que les heures restent fixes. Les événements horaires de moins d’un jour restent dans le planning de chaque date, même s’ils traversent minuit.

### E-mails

- Les tâches sont proposées uniquement à partir des éléments **Examen ou action nécessaire** de l’analyse du corps complet. En l’absence d’éléments, l’objet ou le résumé de l’e-mail ne sont pas transformés en tâches ; vous pouvez enregistrer séparément une tâche saisie manuellement.
- Vous pouvez enregistrer séparément plusieurs actions d’un même e-mail, sans créer de doublon pour une même action même après modification du titre. Les événements de calendrier ajoutés manuellement sont également distingués par tâche, tout en conservant la référence à l’e-mail d’origine.
- Une connexion IMAP interrompue est rétablie lors de la consultation suivante, et un échec du marquage comme lu ne bloque plus la réception du corps du message. Les actions de marquage comme lu et de mise à la corbeille ne sont pas exécutées via la connexion d’un autre compte.
- La liste et les corps complets sont enregistrés sur l’appareil à l’activation de l’app et périodiquement. Le cache est conservé même lorsque l’analyse IA est désactivée ; la collecte en arrière-plan concerne uniquement les comptes autorisés et son horaire est déterminé par iOS.
- Les marges supérieure et inférieure des cartes de résumé d’e-mail ont été harmonisées, et les noms longs sont plus lisibles dans l’écran de sélection des actions.
- Le texte complet et le HTML d’affichage sont récupérés sans les pièces jointes volumineuses, en conservant les actions en fin de message. Un échec de connexion local n’efface plus les résumés synchronisés valides ; l’annulation d’une suppression conserve l’origine des actions et empêche les doublons.

### Réglages et synchronisation

- L’écran **Conflits de synchronisation** permet de comparer les versions et les contenus différents de chaque élément, puis de choisir directement la version à appliquer. Les éléments modifiés pendant la comparaison doivent être vérifiés à nouveau ; la synchronisation des autres éléments sans conflit se poursuit.
- Avant de résoudre un conflit, les versions d’origine sont conservées sur l’appareil et peuvent être comparées et restaurées dans **Versions conservées**. Les doublons d’un même élément sont réunis en un seul selon la version choisie directement.
- Les erreurs de configuration de l’app pour les formulaires de confidentialité publicitaire, les erreurs réseau et délais d’attente, ainsi que les échecs de présentation des formulaires, sont distingués avec des indications adaptées. Un problème de configuration chez Google n’est pas présenté comme une erreur pouvant être résolue par une simple nouvelle tentative.
- Amélioration de la restauration iCloud des anciennes tâches. La version 1.0.14 ne peut pas lire les nouvelles tâches d’actions d’e-mail et sa synchronisation peut s’arrêter : mettez à jour tous les iPhone, iPad et Mac du même compte iCloud.

<a id="version-1-0-14-13"></a>
## 1.0.14 (13)

### Réunions

- Un bouton **Ajouter une tâche** figure à côté des phrases du résumé classées comme tâches. La phrase vérifiée est ajoutée telle quelle à la file d’attente, sans liste de propositions distincte ni nouvelle reformulation du titre de tâche ; la vérification des éléments justificatifs d’origine et la prévention des doublons sont conservées.
- Dans **Résumer à nouveau**, vous pouvez choisir directement Apple Intelligence, GPT-6.1 Sol ou GPT-6 Luna. GPT n’est utilisé qu’avec un compte connecté et le consentement à l’envoi des réunions propre à l’appareil ; les résultats précédents sont conservés en cas d’erreur ou d’annulation.
- Le choix du format et l’édition des consignes restent possibles même lorsque les consignes personnalisées de résumé sont vides.
- Le traitement des longues réunions par Apple Intelligence a été divisé en étapes ; la définition de la langue de sortie et la vérification de l’ancrage dans le texte d’origine ont été améliorées.
- Les transcriptions consécutives d’un même locuteur et les portions sans locuteur détecté entourées par ce même locuteur sont regroupées en paragraphes. Les séparations manuelles, changements de source et chevauchements réels de parole sont préservés ; les attributions d’origine des locuteurs ne sont pas modifiées.
- Les multiples boutons de justification des résumés ont été réorganisés en liens de position et menu d’éléments justificatifs.
- Après confirmation, vous pouvez supprimer **la réunion entière ainsi que ses sources audio, transcriptions, résumés et fichiers audio originaux**. Les tâches déjà créées et les fichiers sauvegardés à l’extérieur sont conservés.
- Vous pouvez enregistrer le ZIP/WAV original d’une source ou le ZIP des originaux de toutes les sources dans Files sur iPhone et iPad, ou dans la fenêtre d’enregistrement sur Mac. Les fichiers des différentes sources et leurs décalages de début restent distincts et sont préservés.
- L’importation audio sur Mac accepte désormais le glisser-déposer de fichiers depuis Finder ainsi qu’un bouton Coller et ⌘V. Les fichiers d’origine ne sont pas modifiés.
- Lors de la récupération d’une réunion, les modifications des enfants et de l’appartenance sont désormais enregistrées avant le nettoyage des traces de récupération. Si l’enregistrement échoue, les transcriptions, l’audio original et les traces de récupération existants sont conservés.
- Modifier seulement les paramètres de sortie du résumé conserve le résumé existant. L’ajout de tâches reste aussi possible pour les résumés dont les éléments justificatifs d’origine peuvent être confirmés inchangés ; il est bloqué si ces éléments ont réellement changé ou ne peuvent pas être vérifiés.
- La détection de l’activité de réunion sur Mac et la collecte de sortie par app ont été améliorées. L’exécutable de l’app sélectionnée et les relations d’appartenance des processus sont vérifiés ; si la cible de collecte change, celle-ci s’arrête et une nouvelle sélection est demandée. La collecte par app de Safari utilisant un helper WebKit partagé n’est pas prise en charge.

### Réglages, comptes et synchronisation

- Les niveaux de forfait non vérifiables et la liste superflue des modèles ont été retirés de l’écran des comptes IA, désormais centré sur l’état de connexion, le test de connexion, les consentements d’envoi et l’utilisation.
- Le format des requêtes JSON ChatGPT et le traitement des réponses achevées ont été corrigés. Les jetons d’entrée, de sortie et d’entrée mis en cache, ainsi que le nombre de réponses constatés par compte sur cet appareil, sont affichés ; ils ne représentent pas l’ensemble de l’utilisation du compte ni ses limites restantes.
- Un problème qui replanifiait une synchronisation complète pour des enregistrements de connexion inchangés a été corrigé.
- La compatibilité et la récupération des enregistrements de suppression iCloud ont été améliorées. Des identifiants dupliqués avec des contenus différents ne sont pas écrasés arbitrairement : seul l’élément concerné est mis en attente, tandis que les autres modifications continuent à être synchronisées.
- Les explications redondantes et éléments vides des réglages de réunions, d’IA et des fonctions bêta ont été réduits ; les lignes des modèles et les valeurs choisies sont moins susceptibles d’être tronquées sur petit écran ou avec de grands caractères.
- Les zones tactiles des boutons de réinitialisation et de génération de persona ont été agrandies sur iPad.
- Un accès **Consentement publicitaire et confidentialité** a été ajouté aux réglages iPhone et iPad. Le statut du consentement Google est vérifié à nouveau ; une erreur de formulaire n’est pas considérée comme un consentement obtenu. L’absence de publicité sur Mac est maintenue.

<a id="version-1-0-13-12"></a>
## 1.0.13 (12)

- La vérification des informations de connexion protégées lors de la synchronisation automatique se fait sans fenêtre d’authentification. Une opération d’autorisation distincte indique le motif de l’authentification, le groupe actuel et les états d’annulation et d’attente.
- Les petites modifications de synchronisation sont enregistrées en lots limités afin de réduire les écritures disque et les demandes d’exportation CloudKit. Le contenu d’origine, les identifiants de révision, la reprise après échec intermédiaire et la gestion de l’annulation sont préservés.
- L’étape d’échec et le code SDK des erreurs audio système de réunion sont conservés, et les autorisations de capture Mac sont expliquées. L’erreur n’est pas perdue si la collecte des diagnostics est autorisée plus tard.
- La vérification des diagnostics, le brouillon et l’identifiant de soumission sont conservés après annulation de la rédaction d’un signalement ou échec d’envoi. La transmission n’est marquée comme achevée que si la réception réelle des diagnostics réussit.

<a id="version-1-0-12-11"></a>
## 1.0.12 (11)

- Amélioration de la densité d’affichage des mois, des vues année, jour et plusieurs jours du calendrier mobile, du défilement continu, du pincement, du retour à aujourd’hui et de l’affichage sur iPad étroit.
- Sur Mac, vous pouvez créer un événement en cliquant ou en faisant glisser dans un créneau vide, ajuster son heure en faisant glisser son bord, et le modifier ou le supprimer par clic droit.
- La modification ou suppression directe d’un événement préserve les liens avec les tâches, les historiques d’achèvement, les événements récurrents et les limites des fuseaux horaires ; des protections empêchent aussi la recréation automatique d’un événement supprimé.
- Ajout d’une forme d’onde de l’entrée réelle, d’une Live Activity sur iPhone et iPad et d’un indicateur d’enregistrement dans la barre des menus Mac. La transcription en direct utilise le modèle Apple par défaut ; Whisper, facultatif, est réservé au traitement après la fin de l’enregistrement.
- Les échecs de transcription pendant l’enregistrement sont distingués des échecs de sauvegarde audio ; la compatibilité du format d’entrée réel avec la transcription Apple est vérifiée.
- L’importation audio sur Mac utilise l’autorisation de lecture des fichiers choisis par l’utilisateur et un panneau d’ouverture natif. L’audio est enregistré et lu localement sans modifier l’original.
- Les réglages ont été organisés selon les rôles de l’IA, des réunions, des tâches et des routines. L’état réel de préparation d’Apple Intelligence est distingué du consentement à utiliser un modèle local de remplacement ; l’analyse externe ne s’exécute qu’avec une connexion, une région prise en charge et les consentements de partage individuels.
- La fenêtre de réussite de synchronisation des e-mails a été supprimée ; un point bleu identifie les nouveaux messages pas encore ouverts.
- La recherche et les filtres des tâches restent fixes ; un double-clic ou un double toucher sur un espace vide permet de créer une tâche.
- Les brouillons de nouvelles tâches sont conservés lors des changements d’écran Duo ; sur petit écran, le bouton d’enregistrement ne masque plus la zone de saisie.
- Amélioration des boutons, de l’édition et du contraste des tâches sur Mac, ainsi que de la consultation et du défilement des événements du calendrier.

<a id="version-1-0-11-10"></a>
## 1.0.11 (10)

- Sur iPhone et iPad, la bannière des tâches a été déplacée du bas de l’écran vers une zone fixe sous les catégories.
- Sur Mac, la recherche de langue est placée en haut de l’écran de sélection et le champ de recherche ne reste plus affiché après un retour à l’écran précédent.
- Le bouton de barre latérale du calendrier Mac est placé dans la barre d’outils supérieure ; les semaines des mois précédent et suivant se suivent sans doublons.
- Correction de la disparition d’événements causée par des tâches liées et de l’espace excessif en haut du planning journalier.
- Les aperçus de glisser-déposer des tâches comprennent les métadonnées ; les commandes d’installation, d’annulation et de suppression des modèles ont été harmonisées.
- La chronologie des conversations de réunion est centrée sur le locuteur, l’heure et le texte ; les titres répétés du même locuteur et les espaces ont été réduits.
- Correction des graduations horaires et des erreurs de placement du planning journalier ; amélioration de l’éditeur de tâches sur grand écran et des zones cliquables des lignes de connexion Gmail et Outlook.
- Le calendrier continu Mac réagit mieux au défilement et au redimensionnement de la fenêtre ; les contours superflus de sélection de semaine ont été supprimés.

<a id="version-1-0-11-9"></a>
## 1.0.11 (9)

- Les réglages des tâches regroupent les rappels d’échéance, l’IA et les règles de classement des priorités ; les titres et notes peuvent être modifiés dans le tableau Mac.
- Vous pouvez choisir directement les calendriers à utiliser pour l’analyse des tâches. Désélectionner un calendrier arrête seulement les nouvelles importations et l’actualisation des suggestions non approuvées ; les tâches approuvées sont conservées.
- La connexion aux comptes IA et le consentement aux transmissions ont été séparés de l’installation, de l’annulation et de la suppression des modèles locaux. La simple ouverture d’un écran ne télécharge pas de modèle.
- La portée facultative du stockage iCloud a été élargie aux e-mails, réunions, routines, dictionnaires et réglages. Les identifiants utilisent le trousseau iCloud ; les données de santé, autorisations système et modèles téléchargés sont exclus.
- La lecture de l’audio complet d’une réunion et de la chronologie des conversations est alignée sur le temps commun des sources ; les dernières langues choisies pour l’audio et le résumé sont mémorisées.
- Vous pouvez examiner et approuver les éléments justificatifs et créneaux des suggestions de routines ; sur les appareils iOS compatibles, les données de santé et d’exercice sont connectées avec des autorisations et consentements distincts.
- Vous pouvez examiner et envoyer des retours et les diagnostics choisis sans connexion à un compte. La réussite n’est annoncée qu’après réception d’un véritable numéro de réception.
- Amélioration des réglages de lecture, des formes d’onde, du tableau des tâches, du tutoriel et de l’affichage du calendrier mensuel Mac.
- Correction d’un plantage de barre d’outils inactive sur Mac, d’une initialisation Metal inutile lorsqu’aucun modèle n’était utilisé, ainsi que de problèmes de sauvegarde et de lecture FLAC des réunions courtes.
- Les éléments en attente d’enregistrement sont exclus du classement IA en lot, des notifications et de l’inscription automatique au calendrier.

{% include release-history.html %}
