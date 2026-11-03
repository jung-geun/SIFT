---
layout: default
locale: zh-Hans
lang: zh-Hans
page_key: email
permalink: /zh-Hans/email-setup.html
title: 连接邮箱
description: 了解如何准备 Gmail 应用专用密码并将邮箱连接到 SIFT。
---

# 连接邮箱

SIFT 通过 **IMAP 方式**连接邮箱。本指南以已确认实际连接成功的 **Gmail** 为准。在 Google 创建应用专用密码后，将其输入 SIFT，即可查看收件箱，并将邮件中的请求整理为待办。

邮箱连接是可选的。不连接也能使用基本待办管理功能。

## 1. 开启 Google 账户的两步验证

1. 使用要连接的 Gmail 地址登录 [Google 账户](https://myaccount.google.com/)。
2. 前往**安全性与登录 → 登录 Google 的方式 → 两步验证**。
3. 按照屏幕提示开启两步验证。如果已开启，请继续下一步。

创建应用专用密码需要开启两步验证。具体步骤请参阅 [Google 两步验证说明](https://support.google.com/accounts/answer/185839?hl=ko)。

## 2. 为 SIFT 创建应用专用密码

1. 使用同一账户打开 [Google 应用专用密码管理](https://myaccount.google.com/apppasswords)。如果要求验证身份，请完成验证。
2. 输入可识别应用和设备的名称，例如 `SIFT iPhone`，然后选择**创建**。
3. 复制显示的 **16 位应用专用密码**。

**它与 Google 的普通登录密码不同。** 请勿在 SIFT 中输入普通密码、两步验证代码或恢复代码。这里只使用 Google 单独生成的应用专用密码。

如果看不到应用专用密码菜单，请查看下方的[连接问题排查](#troubleshooting)。请勿为了连接而关闭两步验证或高级保护。

## 3. 在 SIFT 中连接 Gmail

1. 打开 SIFT 的**设置 → 邮件集成**。
2. 展开 **Gmail IMAP 连接**项目。
3. 在 **Gmail 邮件地址**中输入创建应用专用密码的账户的完整地址。
4. 在 **Google 应用专用密码** 中粘贴应用专用密码。
5. **自动在后台加载邮件**只在需要时开启。关闭此设置也可以连接。
6. 点击 **Gmail IMAP 连接**按钮。如果设备要求验证身份，请完成验证。
7. 验证结束后，**Gmail 账户**行会显示**已连接**。

服务器设置会自动应用。Gmail 服务器为 `imap.gmail.com`，端口为 `993`，通过 SSL/TLS 连接。无需在应用中单独输入服务器或端口。个人 Gmail 的 [IMAP 始终开启](https://support.google.com/mail/answer/7126229?hl=ko)，因此无需在网页设置中另行启用。

## 查看已连接的邮件

在**邮件**标签页查看收件箱。如需立即获取新邮件，请长按**设置 → 邮件集成**中已连接的 **Gmail 账户**行，选择**立即检查邮件**。

- **自动在后台加载邮件**默认关闭。开启后，设备解锁过一次，即使再次锁定，也可使用已保存的应用专用密码。请了解所提示的安全风险后再选择。
- **自动分析邮件**是仅根据完整正文中的待审核/处理项目建议待办的独立设置。没有此类项目时不会自动建议，也可以手动输入后保存。
- 列表和完整正文会独立于自动分析设置，在应用激活时及定期保存在设备上。后台获取仅适用于已获许可的账户；iOS 决定执行机会，因此不保证固定间隔。
- 可调整 Gmail 的**每日自动分析时间**。获准 Gmail 账户的后台 AI 分析会在该时间之后每天尝试一次，不保证 Outlook 具有相同日常分析。分析时段设置不限制当前 IMAP 列表或正文的收集范围。

**标记已读和移至垃圾箱也会反映到原始 Gmail。** 仅加载列表不会标记已读，而是在确认未读邮件的正文后请求标记已读。即使标记已读失败，仍可查看已收到的正文。移至垃圾箱也会影响原始邮件。

## 断开连接或更换设备时

应用专用密码保存在**此设备的 Keychain** 中。明确同意完整 iCloud 存储，并使用同一 Apple 账户及 iCloud 钥匙串时，可以恢复连接信息，但不会迁移设备级访问批准和后台许可。在新设备上，请确认连接信息并亲自批准所需访问，或为该设备创建应用专用密码后连接。

1. 在**设置 → 邮件集成**中长按或向左滑动已连接的账户行，选择**断开连接**。
2. SIFT 会删除此设备上的应用专用密码和已连接账户信息。
3. 也请在 [Google 应用专用密码管理](https://myaccount.google.com/apppasswords)中**删除**不再使用的 SIFT 密码。

**在 SIFT 中断开连接，与在 Google 中撤销应用专用密码是两回事。** 如果设备丢失，请先在 Google 中删除。断开连接不会批量删除原始邮件或已保存的邮件、待办。

<h2 id="troubleshooting">连接问题排查</h2>

- **没有应用专用密码菜单。** 请确认账户是否正确、两步验证是否开启。工作或学校账户、仅使用安全密钥的两步验证，以及高级保护计划可能不提供此菜单。组织账户请咨询管理员是否允许使用应用专用密码和 IMAP。[Google 官方说明](https://support.google.com/accounts/answer/185833?hl=ko)
- **密码被拒绝。** 请确认使用的是应用专用密码而非普通密码，且签发密码的账户与输入的地址一致。更改 Google 普通密码会撤销现有应用专用密码，因此需要重新创建。
- **已保存的账户显示未连接。** 解决网络或设备身份验证问题后，点击**重新连接**。如果密码已撤销，请选择**更换应用专用密码**，输入新的应用专用密码。
- **发生超时或安全连接错误。** 请检查互联网连接，并尝试其他网络。如果是组织网络，也请确认 IMAP 端口 `993` 是否被阻止。
- **已连接但没有邮件。** 请在 Gmail 网页中查看同一账户的收件箱，再在 SIFT 中手动获取新邮件。即使收件箱为空，也可以正常连接。

如需帮助，请只提供错误提示与发生情况。**请勿在咨询或反馈中发送普通密码、应用专用密码、验证码或恢复代码。** 分享屏幕时，也请遮盖邮箱地址和邮件内容。

<h2 id="outlook">Outlook 及其他邮件服务商</h2>

SIFT 设置中也有 **连接 Outlook IMAP**项目，但当前的应用专用密码方式与 Microsoft 要求的身份验证方式不符，因此不保证连接成功。请勿将 Gmail 的步骤直接套用于 Outlook。

- **Outlook.com 个人账户**要求使用 Modern Authentication。[Microsoft 身份验证说明](https://support.microsoft.com/en-us/office/modern-authentication-methods-now-needed-to-continue-syncing-outlook-email-in-non-microsoft-email-apps-c5d65390-9676-4763-b41f-d7986499a90d)
- **Microsoft 365 工作或学校账户**的 Exchange Online 会阻止 IMAP 基本身份验证，应用专用密码也无法绕过此限制。[Microsoft 身份验证政策](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/deprecation-of-basic-authentication-exchange-online)

此限制源于服务商的身份验证政策，而非 IMAP 本身。请勿改为输入普通 Microsoft 账户密码或降低安全设置。当前 SIFT 没有可手动输入其他服务商服务器的通用连接界面。

[返回使用指南](workflows.html) · [隐私政策](privacy-policy.html)
