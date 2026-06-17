#include "extension.h"
#include "foundtarget_call.h"

#include <cstring>

TF2SentryNewTargetExt g_TF2SentryNewTargetExt;
IGameConfig *g_pGameConf = nullptr;

SMEXT_LINK(&g_TF2SentryNewTargetExt);

extern sp_nativeinfo_t g_TF2SentryNewTargetNatives[];

bool TF2SentryNewTargetExt::SDK_OnLoad(char *error, size_t maxlength, bool late)
{
    if (std::strcmp(g_pSM->GetGameFolderName(), "tf") != 0)
    {
        ke::SafeSprintf(error, maxlength, "This extension only supports Team Fortress 2.");
        return false;
    }

    char confError[255] = "";
    if (!gameconfs->LoadGameConfigFile("tf2_sentry_newtarget_dist.games", &g_pGameConf, confError, sizeof(confError)))
    {
        if (confError[0])
            ke::SafeSprintf(error, maxlength, "Could not load tf2_sentry_newtarget_dist.games.txt: %s", confError);
        else
            ke::SafeSprintf(error, maxlength, "Could not load tf2_sentry_newtarget_dist.games.txt");
        return false;
    }

    if (!SentryFoundTarget::Init(g_pGameConf, error, maxlength))
        return false;

    sharesys->AddNatives(myself, g_TF2SentryNewTargetNatives);
    sharesys->RegisterLibrary(myself, "tf2_sentry_newtarget_dist");

    return true;
}

void TF2SentryNewTargetExt::SDK_OnUnload()
{
    SentryFoundTarget::Shutdown();

    if (g_pGameConf)
    {
        gameconfs->CloseGameConfigFile(g_pGameConf);
        g_pGameConf = nullptr;
    }
}
