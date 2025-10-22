#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

public Plugin myinfo =
{
    name = "Precache Manager",
    author = "Codex",
    description = "Adds configured assets to the download table and precaches them.",
    version = "1.0.0",
    url = "https://kogasa.tf"
};

enum PrecacheType
{
    PrecacheType_Model,
    PrecacheType_Material,
    PrecacheType_Sound,
    PrecacheType_Generic
};

static const char g_sModels[][] =
{
    "models/workshop/weapons/c_models/c_adjudicator/c_adjudicator.mdl"
};

static const char g_sModelVariants[][] =
{
    ".dx80.vtx",
    ".dx90.vtx",
    ".sw.vtx",
    ".vvd",
    ".phy"
};

static const char g_sMaterials[][] =
{
    "materials/models/workshop/weapons/c_items/c_front_lader_exponent.vtf",
    "materials/models/workshop/weapons/c_items/c_front_lader_normal.vtf",
    "materials/models/workshop/weapons/c_items/c_front_lader.vmt",
    "materials/models/workshop/weapons/c_items/c_front_lader.vtf"
};

static const char g_sSounds[][] =
{
    "sound/bluearchive/koyuki_uwah.wav"
};

static const char g_sGenericFiles[][] =
{
    ""
};

public void OnMapStart()
{
    AddConfiguredDownloads();
}

static void AddConfiguredDownloads()
{
    char path[PLATFORM_MAX_PATH];

    for (int i = 0; i < sizeof(g_sModels); i++)
    {
        strcopy(path, sizeof(path), g_sModels[i]);
        AddFileToDownloadsTable(path);
        PrecacheModel(path, true);

        char basePath[PLATFORM_MAX_PATH];
        strcopy(basePath, sizeof(basePath), g_sModels[i]);
        int len = strlen(basePath);
        if (len > 4)
        {
            char prefix[PLATFORM_MAX_PATH];
            strcopy(prefix, sizeof(prefix), basePath);
            prefix[len - 4] = '\0'; // remove .mdl

            for (int j = 0; j < sizeof(g_sModelVariants); j++)
            {
                Format(path, sizeof(path), "%s%s", prefix, g_sModelVariants[j]);
                AddFileToDownloadsTable(path);
            }
        }
    }

    for (int i = 0; i < sizeof(g_sMaterials); i++)
    {
        strcopy(path, sizeof(path), g_sMaterials[i]);
        AddFileToDownloadsTable(path);
    }

    for (int i = 0; i < sizeof(g_sSounds); i++)
    {
        strcopy(path, sizeof(path), g_sSounds[i]);
        AddFileToDownloadsTable(path);
        PrecacheSound(path, true);
    }

    for (int i = 0; i < sizeof(g_sGenericFiles); i++)
    {
        strcopy(path, sizeof(path), g_sGenericFiles[i]);
        if (path[0] == '\0')
        {
            continue;
        }
        AddFileToDownloadsTable(path);
    }
}
