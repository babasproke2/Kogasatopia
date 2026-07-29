#if defined _server_mail_included
    #endinput
#endif
#define _server_mail_included

#include <sourcemod>

/**
 * All send natives queue an asynchronous database insert and return false when
 * mail is not ready, an identity/string is invalid, or a currency dependency is
 * unavailable. A true return means queued, not yet committed; callers that need
 * confirmation must provide requestKey and handle ServerMail_OnMailSendResult.
 *
 * Connected-client natives accept sender 0 for mail authored by kogasa.tf.
 * SteamID64 natives accept an empty senderSteamId64 for server/plugin mail.
 */

/**
 * Sends ordinary mail between connected clients.
 *
 * @param sender        Sender client, or 0 for the server.
 * @param receiver      Connected receiver client.
 * @param contents      Mail body.
 * @param requestKey    Optional idempotency/callback key.
 * @return              True if the asynchronous insert was queued.
 */
native bool ServerMail_Send(int sender, int receiver, const char[] contents, const char[] requestKey = "");

/**
 * Sends custom-titled mail between connected clients.
 *
 * @param sender        Sender client, or 0 for the server.
 * @param receiver      Connected receiver client.
 * @param title         Stored title without the generated date suffix.
 * @param contents      Mail body.
 * @param requestKey    Optional idempotency/callback key.
 * @return              True if the asynchronous insert was queued.
 */
native bool ServerMail_SendCustom(int sender, int receiver, const char[] title, const char[] contents, const char[] requestKey = "");

/**
 * Sends currency mail between connected clients.
 *
 * Fails when the idempotent points-store award API is unavailable.
 *
 * @param sender        Sender client, or 0 for the server.
 * @param receiver      Connected receiver client.
 * @param title         Stored title without the generated date/gem suffix.
 * @param contents      Mail body.
 * @param gems          Positive attached currency amount.
 * @param requestKey    Optional idempotency/callback key.
 * @return              True if the asynchronous insert was queued.
 */
native bool ServerMail_SendCurrency(int sender, int receiver, const char[] title, const char[] contents, int gems, const char[] requestKey = "");

/**
 * Sends ordinary mail to an offline-capable SteamID64.
 *
 * senderSteamId64 may be empty for server/plugin mail. senderName is always
 * required so stored mail remains readable while the sender is offline.
 *
 * @return              True if the asynchronous insert was queued.
 */
native bool ServerMail_SendSteamId(
    const char[] senderSteamId64,
    const char[] senderName,
    const char[] receiverSteamId64,
    const char[] contents,
    const char[] requestKey = "");

/**
 * Sends custom-titled mail to an offline-capable SteamID64.
 *
 * @return              True if the asynchronous insert was queued.
 */
native bool ServerMail_SendCustomSteamId(
    const char[] senderSteamId64,
    const char[] senderName,
    const char[] receiverSteamId64,
    const char[] title,
    const char[] contents,
    const char[] requestKey = "");

/**
 * Sends currency mail to an offline-capable SteamID64.
 *
 * Mail insertion is idempotent when requestKey is non-empty. Currency is not
 * awarded until the recipient explicitly redeems the attachment.
 *
 * @return              True if the asynchronous insert was queued.
 */
native bool ServerMail_SendCurrencySteamId(
    const char[] senderSteamId64,
    const char[] senderName,
    const char[] receiverSteamId64,
    const char[] title,
    const char[] contents,
    int gems,
    const char[] requestKey = "");

/**
 * Fired after an API-created mail insert resolves.
 *
 * @param requestKey    Caller-provided request key.
 * @param success       True if the mail now exists.
 * @param mailId        Stored mail ID, or 0 on failure.
 * @param newlyCreated  True only when this request inserted a new row.
 */
forward void ServerMail_OnMailSendResult(const char[] requestKey, bool success, int mailId, bool newlyCreated);

public SharedPlugin __pl_server_mail =
{
    name = "server_mail",
    file = "server_mail.smx",
    required = 0,
};

public void __pl_server_mail_SetNTVOptional()
{
    MarkNativeAsOptional("ServerMail_Send");
    MarkNativeAsOptional("ServerMail_SendCustom");
    MarkNativeAsOptional("ServerMail_SendCurrency");
    MarkNativeAsOptional("ServerMail_SendSteamId");
    MarkNativeAsOptional("ServerMail_SendCustomSteamId");
    MarkNativeAsOptional("ServerMail_SendCurrencySteamId");
}
