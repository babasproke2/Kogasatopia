#if defined _saysounds_included
    #endinput
#endif
#define _saysounds_included

#include <sourcemod>

/**
 * Returns whether a client currently has say sounds enabled.
 *
 * @param client        Client index.
 * @return              True if the client can hear say sounds.
 */
native bool SaySounds_ShouldPlay(int client);

/**
 * Plays a raw sound path to clients who can currently hear say sounds.
 *
 * @param soundPath     Raw sound path relative to `sound/`.
 * @param groupName     Optional say sound group. Use `all` for all groups.
 */
native void SaySounds_PlaySoundToOptedIn(const char[] soundPath, const char[] groupName);

/**
 * Plays a configured say sound command to a target client.
 *
 * `client == 0` broadcasts with normal say sound delivery rules.
 *
 * @param client        Client index, or `0` for broadcast.
 * @param commandName   Configured say sound command, such as `xp_gain`.
 * @param force         If true, bypasses say sound opt-in checks.
 * @param bypassAdminOnly
 *                      If true, ignores AdminOnlyGroups for this API-triggered sound.
 * @return              True if the sound resolved and was emitted to at least one client.
 */
native bool SaySounds_PlayCommand(int client, const char[] commandName, bool force = false, bool bypassAdminOnly = true);

/**
 * Plays a configured say sound command using sourceClient for admin/paid access
 * checks and targetClient for delivery.
 *
 * `targetClient == 0` broadcasts with normal say sound delivery rules.
 *
 * @param sourceClient  Client whose permissions/purchases authorize the sound.
 * @param targetClient  Client index, or `0` for broadcast.
 * @param commandName   Configured say sound command or group.
 * @param force         If true, bypasses listener opt-in checks.
 * @param bypassAdminOnly
 *                      If true, ignores AdminOnlyGroups for this API-triggered sound.
 * @return              True if the sound resolved and was emitted to at least one client.
 */
native bool SaySounds_PlayCommandAs(int sourceClient, int targetClient, const char[] commandName, bool force = false, bool bypassAdminOnly = true);

/**
 * Returns whether a source client can use a configured say sound command or group.
 *
 * @param client        Source client index.
 * @param commandName   Configured say sound command or group.
 * @param bypassAdminOnly
 *                      If true, ignores AdminOnlyGroups while checking API-triggered eligibility.
 * @return              True if configured and usable by this client.
 */
native bool SaySounds_CanClientUseCommand(int client, const char[] commandName, bool bypassAdminOnly = true);

/**
 * Returns whether a configured say sound command or group belongs to a paid group.
 *
 * @param commandName   Configured say sound command or group.
 * @return              True if the command/group is paid.
 */
native bool SaySounds_IsCommandPaid(const char[] commandName);

/**
 * Returns the group for a configured say sound command or known group input.
 *
 * @param commandName   Configured say sound command or group.
 * @param groupName     Output group name.
 * @param groupLen      Output buffer size.
 * @return              True if the command/group resolved.
 */
native bool SaySounds_GetCommandGroup(const char[] commandName, char[] groupName, int groupLen);

public SharedPlugin __pl_saysounds =
{
    name = "saysounds",
    file = "saysounds.smx",
    required = 0,
};

public void __pl_saysounds_SetNTVOptional()
{
    MarkNativeAsOptional("SaySounds_ShouldPlay");
    MarkNativeAsOptional("SaySounds_PlaySoundToOptedIn");
    MarkNativeAsOptional("SaySounds_PlayCommand");
    MarkNativeAsOptional("SaySounds_PlayCommandAs");
    MarkNativeAsOptional("SaySounds_CanClientUseCommand");
    MarkNativeAsOptional("SaySounds_IsCommandPaid");
    MarkNativeAsOptional("SaySounds_GetCommandGroup");
}
