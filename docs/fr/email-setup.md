---
layout: default
locale: fr
lang: fr
page_key: email
permalink: /fr/email-setup.html
title: Connecter votre messagerie
description: Découvrez comment créer un mot de passe d’application Gmail et connecter votre messagerie à SIFT.
---

# Connecter votre messagerie

SIFT se connecte à la messagerie par **IMAP**. Ce guide porte sur **Gmail**, dont la connexion a effectivement été vérifiée. Après avoir créé un mot de passe d’application chez Google et l’avoir saisi dans SIFT, vous pouvez consulter votre boîte de réception et organiser les demandes des e-mails en tâches.

La connexion à la messagerie est facultative. Vous pouvez utiliser la gestion de base des tâches sans connecter de compte.

## 1. Activez la validation en deux étapes du compte Google

1. Connectez-vous à votre [compte Google](https://myaccount.google.com/) avec l’adresse Gmail à utiliser.
2. Accédez à **Sécurité et connexion → Comment vous vous connectez à Google → Validation en deux étapes**.
3. Suivez les instructions à l’écran pour activer la validation en deux étapes. Si vous l’utilisez déjà, passez à l’étape suivante.

La validation en deux étapes est nécessaire pour créer un mot de passe d’application. Pour plus de détails, consultez le [guide Google de la validation en deux étapes](https://support.google.com/accounts/answer/185839?hl=ko).

## 2. Créez un mot de passe d’application pour SIFT

1. Avec le même compte, ouvrez la [gestion des mots de passe d’application Google](https://myaccount.google.com/apppasswords). Effectuez la vérification d’identité si elle vous est demandée.
2. Saisissez un nom permettant de reconnaître l’app et l’appareil, comme `SIFT iPhone`, puis choisissez **Créer**.
3. Copiez le **mot de passe d’application de 16 caractères** affiché.

**Il est différent de votre mot de passe de connexion Google habituel.** Ne saisissez pas dans SIFT votre mot de passe habituel, un code de validation en deux étapes ou un code de secours. Seul le mot de passe d’application créé séparément par Google est utilisé ici.

Si le menu des mots de passe d’application n’apparaît pas, consultez la section [Résoudre les problèmes de connexion](#troubleshooting). Ne désactivez ni la validation en deux étapes ni la Protection Avancée pour établir la connexion.

## 3. Connectez Gmail dans SIFT

1. Ouvrez **Réglages → Connexion à la messagerie** dans SIFT.
2. Développez la section **Connexion Gmail IMAP**.
3. Dans **Adresse e-mail Gmail**, saisissez l’adresse complète du compte pour lequel vous avez créé le mot de passe d’application.
4. Collez le mot de passe d’application dans **Google App Password**.
5. Activez **Récupération automatique des e-mails en arrière-plan** uniquement si nécessaire. Vous pouvez vous connecter en laissant cette option désactivée.
6. Touchez le bouton **Connexion Gmail IMAP**. Effectuez la vérification d’identité de l’appareil si elle vous est demandée.
7. Une fois la vérification terminée, la ligne **Compte Gmail** affiche **Connecté**.

Les paramètres du serveur sont appliqués automatiquement. Le serveur Gmail est `imap.gmail.com`, le port est `993` et la connexion utilise SSL/TLS. Vous n’avez pas à saisir séparément de serveur ni de port dans l’app. Pour un compte Gmail personnel, [IMAP est toujours activé](https://support.google.com/mail/answer/7126229?hl=ko) : aucune activation supplémentaire dans les réglages web n’est nécessaire.

## Consultez les e-mails du compte connecté

Consultez votre boîte de réception dans l’onglet **E-mails**. Pour récupérer immédiatement de nouveaux messages, appuyez longuement sur la ligne du **Compte Gmail** connecté dans **Réglages → Connexion à la messagerie**, puis choisissez **Vérifier les e-mails maintenant**.

- **La récupération automatique des e-mails en arrière-plan** est désactivée par défaut. Si vous l’activez, le mot de passe d’application enregistré peut être utilisé même lorsque l’appareil est verrouillé, après un premier déverrouillage. Examinez les risques de sécurité indiqués avant de choisir cette option.
- **L’analyse automatique des e-mails** est un réglage distinct qui propose des tâches uniquement à partir des éléments **Examen ou action nécessaire** du corps complet. En l’absence d’éléments, aucune tâche n’est proposée automatiquement ; vous pouvez en saisir une et l’enregistrer manuellement.
- La liste et les corps complets sont enregistrés sur l’appareil à l’activation de l’app et périodiquement, indépendamment du réglage d’analyse automatique. La collecte en arrière-plan concerne uniquement les comptes autorisés ; iOS détermine les occasions d’exécution, sans garantie d’intervalle fixe.
- Vous pouvez ajuster l’**Heure de l’analyse quotidienne** de Gmail. L’analyse IA en arrière-plan d’un compte Gmail autorisé est tentée une fois par jour après cette heure ; la même analyse quotidienne n’est pas garantie pour Outlook. La période d’analyse ne limite pas la collecte IMAP actuelle des listes et corps.

**Le marquage comme lu et le déplacement vers la corbeille se répercutent sur Gmail.** Le simple chargement de la liste ne marque pas les messages comme lus ; le marquage d’un e-mail non lu est demandé après consultation de son corps. Même si le marquage comme lu échoue, le corps déjà reçu reste consultable. Le déplacement vers la corbeille affecte également le message d’origine.

## Déconnecter un compte ou changer d’appareil

Le mot de passe d’application est enregistré dans **le Keychain de cet appareil**. Les informations de connexion peuvent être restaurées si vous avez explicitement consenti au stockage intégral iCloud et utilisez le même compte Apple et le trousseau iCloud, mais les autorisations d’accès et d’exécution en arrière-plan propres à chaque appareil ne sont pas transférées. Sur un nouvel appareil, vérifiez les informations de connexion et autorisez vous-même les accès nécessaires, ou créez un mot de passe d’application dédié à cet appareil pour vous connecter.

1. Dans **Réglages → Connexion à la messagerie**, appuyez longuement sur la ligne du compte connecté ou balayez-la vers la gauche, puis choisissez **Déconnecter**.
2. SIFT supprime le mot de passe d’application et les informations du compte connecté sur cet appareil.
3. Dans la [gestion des mots de passe d’application Google](https://myaccount.google.com/apppasswords), **supprimez** également le mot de passe SIFT que vous n’utilisez plus.

**Déconnecter le compte dans SIFT et révoquer le mot de passe d’application chez Google sont deux opérations distinctes.** Si vous avez perdu votre appareil, supprimez d’abord le mot de passe chez Google. La déconnexion ne supprime pas en bloc les messages d’origine ni les e-mails et tâches déjà enregistrés.

<h2 id="troubleshooting">Résoudre les problèmes de connexion</h2>

- **Le menu des mots de passe d’application est absent.** Vérifiez que vous utilisez le bon compte et que la validation en deux étapes est activée. Le menu peut être absent pour les comptes professionnels ou scolaires, la validation en deux étapes utilisant uniquement des clés de sécurité ou le programme Protection Avancée. Pour un compte d’organisation, demandez à l’administrateur si les mots de passe d’application et IMAP sont autorisés. [Guide officiel Google](https://support.google.com/accounts/answer/185833?hl=ko)
- **Le mot de passe est refusé.** Vérifiez qu’il s’agit d’un mot de passe d’application et non du mot de passe habituel, et que le compte qui l’a émis correspond à l’adresse saisie. Si vous modifiez votre mot de passe Google habituel, les mots de passe d’application existants sont aussi révoqués : vous devez en créer un nouveau.
- **Le compte enregistré apparaît comme déconnecté.** Résolvez le problème de réseau ou de vérification d’identité de l’appareil, puis touchez **Reconnecter**. Si le mot de passe a été révoqué, choisissez **Remplacer l’App Password** et saisissez un nouveau mot de passe d’application.
- **Une erreur de délai d’attente ou de connexion sécurisée apparaît.** Vérifiez votre connexion Internet et essayez sur un autre réseau. Sur un réseau d’organisation, vérifiez également que le port IMAP `993` n’est pas bloqué.
- **Le compte est connecté mais aucun e-mail n’apparaît.** Vérifiez la boîte de réception du même compte sur le site Gmail, puis récupérez manuellement les nouveaux messages dans SIFT. Une boîte de réception vide n’empêche pas une connexion correcte.

Si vous avez besoin d’aide, communiquez uniquement le message d’erreur et les circonstances. **N’envoyez jamais de mot de passe habituel, de mot de passe d’application, de code de vérification ou de code de secours dans une demande d’assistance ou un retour.** Masquez aussi les adresses e-mail et le contenu des messages lorsque vous partagez un écran.

<h2 id="outlook">Outlook et autres fournisseurs de messagerie</h2>

Les réglages de SIFT proposent aussi **Connexion Outlook IMAP**, mais le mode actuel par mot de passe d’application ne correspond pas à l’authentification exigée par Microsoft et ne garantit pas une connexion réussie. N’appliquez pas à Outlook la procédure Gmail telle quelle.

- Les **comptes personnels Outlook.com** exigent Modern Authentication. [Guide d’authentification Microsoft](https://support.microsoft.com/en-us/office/modern-authentication-methods-now-needed-to-continue-syncing-outlook-email-in-non-microsoft-email-apps-c5d65390-9676-4763-b41f-d7986499a90d)
- Pour les **comptes professionnels ou scolaires Microsoft 365**, Exchange Online bloque l’authentification de base IMAP ; les mots de passe d’application ne permettent pas de contourner cette restriction. [Politique d’authentification Microsoft](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/deprecation-of-basic-authentication-exchange-online)

Cette restriction provient de la politique d’authentification du fournisseur, et non d’IMAP lui-même. Ne saisissez pas votre mot de passe Microsoft habituel à la place et ne réduisez pas votre niveau de sécurité. SIFT ne propose actuellement pas d’écran de connexion universel permettant de saisir le serveur d’un autre fournisseur.

[Retour au guide d’utilisation](workflows.html) · [Politique de confidentialité](privacy-policy.html)
