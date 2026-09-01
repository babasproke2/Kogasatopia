#define MUTECHECK_VERSION "1.9.3"

char g_MuteCheckTag[20];
ConVar g_MuteCheckTagCvar = null;

void MuteCheck_Initialize()
{
    g_MuteCheckTagCvar = CreateConVar(
        "sm_mutecheck_tag",
        "[SM]",
        "Tag to be prepended to MuteCheck replies"
    );
    CreateConVar(
        "sm_mutecheck_version",
        MUTECHECK_VERSION,
        "MuteCheck Version",
        FCVAR_DONTRECORD | FCVAR_NOTIFY
    );
    RegAdminCmd(
        "sm_mutecheck",
        MuteCheck_Command,
        0,
        "Determine if anyone has muted a specific player and who"
    );

    g_MuteCheckTagCvar.GetString(g_MuteCheckTag, sizeof(g_MuteCheckTag));
    g_MuteCheckTagCvar.AddChangeHook(MuteCheck_OnTagChanged);
}

public void MuteCheck_OnTagChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    convar.GetString(g_MuteCheckTag, sizeof(g_MuteCheckTag));
}

static bool MuteCheck_IsHumanInGame(int client)
{
    return client > 0
        && client <= MaxClients
        && IsClientInGame(client)
        && !IsFakeClient(client);
}

int MuteCheck_CountMutedClients(int listener)
{
    if (!MuteCheck_IsHumanInGame(listener))
    {
        return 0;
    }

    int count = 0;
    for (int target = 1; target <= MaxClients; target++)
    {
        if (target != listener
            && MuteCheck_IsHumanInGame(target)
            && IsClientMuted(listener, target))
        {
            count++;
        }
    }
    return count;
}

public any Native_MuteCheck_GetMutedClientCount(Handle plugin, int numParams)
{
    return MuteCheck_CountMutedClients(GetNativeCell(1));
}

static void MuteCheck_AppendClientName(char[] buffer, int maxLength, int client)
{
    char name[MAX_NAME_LENGTH];
    GetClientName(client, name, sizeof(name));

    if (buffer[0] != 0)
    {
        StrCat(buffer, maxLength, ", ");
    }
    StrCat(buffer, maxLength, name);
}

static void MuteCheck_ReplyForTarget(int client, int target)
{
    char muteMessage[512];
    char unmuteMessage[512];

    for (int listener = 1; listener <= MaxClients; listener++)
    {
        if (!MuteCheck_IsHumanInGame(listener))
        {
            continue;
        }

        if (IsClientMuted(listener, target))
        {
            MuteCheck_AppendClientName(muteMessage, sizeof(muteMessage), listener);
        }
        else
        {
            MuteCheck_AppendClientName(unmuteMessage, sizeof(unmuteMessage), listener);
        }
    }

    if (muteMessage[0] == 0)
    {
        ReplyToCommand(client, "%s %N is muted by nobody.", g_MuteCheckTag, target);
    }
    else
    {
        ReplyToCommand(client, "%s %N is muted by %s.", g_MuteCheckTag, target, muteMessage);
    }

    if (unmuteMessage[0] == 0)
    {
        ReplyToCommand(client, "%s %N is not muted by nobody.", g_MuteCheckTag, target);
    }
    else
    {
        ReplyToCommand(client, "%s %N is not muted by %s.", g_MuteCheckTag, target, unmuteMessage);
    }
}

public Action MuteCheck_Command(int client, int args)
{
    if (args != 0 && args != 1)
    {
        ReplyToCommand(
            client,
            "%s Usage: sm_mutecheck to check yourself or sm_mutecheck [target] to check a target",
            g_MuteCheckTag
        );
        return Plugin_Handled;
    }

    if (args == 0)
    {
        if (client == 0)
        {
            ReplyToCommand(client, "%s Use sm_mutecheck [target] from the console.", g_MuteCheckTag);
            return Plugin_Handled;
        }

        MuteCheck_ReplyForTarget(client, client);
        return Plugin_Handled;
    }

    if (!CheckCommandAccess(client, "sm_mutecheck_override", ADMFLAG_GENERIC))
    {
        ReplyToCommand(client, "%s Usage: sm_mutecheck", g_MuteCheckTag);
        return Plugin_Handled;
    }

    char targetArgument[MAX_NAME_LENGTH];
    GetCmdArg(1, targetArgument, sizeof(targetArgument));

    int targets[MAXPLAYERS];
    char targetName[MAX_NAME_LENGTH];
    bool targetNameIsMl;
    int total = ProcessTargetString(
        targetArgument,
        client,
        targets,
        sizeof(targets),
        COMMAND_FILTER_NO_IMMUNITY | COMMAND_FILTER_NO_BOTS,
        targetName,
        sizeof(targetName),
        targetNameIsMl
    );
    if (total < 1)
    {
        ReplyToTargetError(client, total);
        return Plugin_Handled;
    }

    for (int i = 0; i < total; i++)
    {
        MuteCheck_ReplyForTarget(client, targets[i]);
    }
    return Plugin_Handled;
}
