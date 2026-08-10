#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#include <sdktools>

#define CONFIG_FILE "configs/precachefiles.cfg"

#define PRECACHE_ASSET_MODEL 0
#define PRECACHE_ASSET_MATERIAL 1
#define PRECACHE_ASSET_SOUND 2
#define PRECACHE_ASSET_GENERIC 3
#define PRECACHE_ASSET_COUNT 4

static const char g_PrecacheSections[][] =
{
    "models",
    "materials",
    "sounds",
    "generic"
};

ArrayList g_PrecacheLists[PRECACHE_ASSET_COUNT];
ConVar g_CvarAddDownloads;
bool g_AddDownloads = true;

public Plugin myinfo =
{
    name = "Precache Manager",
    author = "Hombre",
    description = "Adds configured assets to the download table and precaches them.",
    version = "1.0.0",
    url = "https://kogasa.tf"
};

public void OnPluginStart()
{
    for (int type = 0; type < PRECACHE_ASSET_COUNT; type++)
    {
        g_PrecacheLists[type] = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
    }

    g_CvarAddDownloads = CreateConVar(
        "sm_precachefiles_add_downloads",
        "1",
        "Add configured files to the download table (0 = precache only, 1 = precache + downloads).",
        FCVAR_NONE,
        true,
        0.0,
        true,
        1.0
    );
    g_CvarAddDownloads.AddChangeHook(OnCvarChanged);
    UpdateDownloadSetting();

    LoadPrecacheConfig();
}

public void OnConfigsExecuted()
{
    UpdateDownloadSetting();
    LoadPrecacheConfig();
}

public void OnMapStart()
{
    AddConfiguredDownloads();
}

public void OnPluginEnd()
{
    for (int type = 0; type < PRECACHE_ASSET_COUNT; type++)
    {
        delete g_PrecacheLists[type];
    }
}

static void LoadPrecacheConfig()
{
    for (int type = 0; type < PRECACHE_ASSET_COUNT; type++)
    {
        g_PrecacheLists[type].Clear();
    }

    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), CONFIG_FILE);

    if (!FileExists(path))
    {
        LogError("[PrecacheFiles] Config file not found: %s", path);
        return;
    }

    KeyValues kv = new KeyValues("PrecacheFiles");

    if (!kv.ImportFromFile(path))
    {
        LogError("[PrecacheFiles] Failed to parse config file: %s", path);
        delete kv;
        return;
    }

    for (int type = 0; type < PRECACHE_ASSET_COUNT; type++)
    {
        LoadPrecacheSection(kv, g_PrecacheSections[type], g_PrecacheLists[type]);
    }

    delete kv;
}

static void LoadPrecacheSection(KeyValues kv, const char[] section, ArrayList output)
{
    kv.Rewind();
    if (!kv.JumpToKey(section, false) || !kv.GotoFirstSubKey(false))
    {
        return;
    }

    do
    {
        char value[PLATFORM_MAX_PATH];
        kv.GetString(NULL_STRING, value, sizeof(value));
        TrimString(value);
        if (value[0])
        {
            output.PushString(value);
        }
    }
    while (kv.GotoNextKey(false));
}

static void AddConfiguredDownloads()
{
    char path[PLATFORM_MAX_PATH];

    for (int type = 0; type < PRECACHE_ASSET_COUNT; type++)
    {
        ArrayList assets = g_PrecacheLists[type];
        for (int i = 0; i < assets.Length; i++)
        {
            assets.GetString(i, path, sizeof(path));
            if (g_AddDownloads)
            {
                AddFileToDownloadsTable(path);
            }

            if (type == PRECACHE_ASSET_MODEL)
            {
                PrecacheModel(path, true);
            }
            else if (type == PRECACHE_ASSET_SOUND)
            {
                PrecacheSound(path, true);
            }
        }
    }
}

static void UpdateDownloadSetting()
{
    g_AddDownloads = g_CvarAddDownloads.BoolValue;
}

public void OnCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    UpdateDownloadSetting();
}
