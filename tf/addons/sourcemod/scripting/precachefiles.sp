#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define CONFIG_FILE "configs/precachefiles.cfg"

ArrayList g_ModelList;
ArrayList g_MaterialList;
ArrayList g_SoundList;
ArrayList g_GenericList;
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
    g_ModelList = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
    g_MaterialList = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
    g_SoundList = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
    g_GenericList = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));

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

static void LoadPrecacheConfig()
{
    g_ModelList.Clear();
    g_MaterialList.Clear();
    g_SoundList.Clear();
    g_GenericList.Clear();

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

    if (kv.JumpToKey("models"))
    {
        if (kv.GotoFirstSubKey(false))
        {
            do
            {
                char value[PLATFORM_MAX_PATH];
                kv.GetString(NULL_STRING, value, sizeof(value));
                TrimString(value);
                if (value[0])
                {
                    g_ModelList.PushString(value);
                }
            }
            while (kv.GotoNextKey(false));
            kv.GoBack();
        }
        kv.GoBack();
    }

    if (kv.JumpToKey("materials"))
    {
        if (kv.GotoFirstSubKey(false))
        {
            do
            {
                char value[PLATFORM_MAX_PATH];
                kv.GetString(NULL_STRING, value, sizeof(value));
                TrimString(value);
                if (value[0])
                {
                    g_MaterialList.PushString(value);
                }
            }
            while (kv.GotoNextKey(false));
            kv.GoBack();
        }
        kv.GoBack();
    }

    if (kv.JumpToKey("sounds"))
    {
        if (kv.GotoFirstSubKey(false))
        {
            do
            {
                char value[PLATFORM_MAX_PATH];
                kv.GetString(NULL_STRING, value, sizeof(value));
                TrimString(value);
                if (value[0])
                {
                    g_SoundList.PushString(value);
                }
            }
            while (kv.GotoNextKey(false));
            kv.GoBack();
        }
        kv.GoBack();
    }

    if (kv.JumpToKey("generic"))
    {
        if (kv.GotoFirstSubKey(false))
        {
            do
            {
                char value[PLATFORM_MAX_PATH];
                kv.GetString(NULL_STRING, value, sizeof(value));
                TrimString(value);
                if (value[0])
                {
                    g_GenericList.PushString(value);
                }
            }
            while (kv.GotoNextKey(false));
            kv.GoBack();
        }
        kv.GoBack();
    }

    delete kv;
}

static void AddConfiguredDownloads()
{
    char path[PLATFORM_MAX_PATH];

    for (int i = 0; i < g_ModelList.Length; i++)
    {
        g_ModelList.GetString(i, path, sizeof(path));
        if (!path[0])
            continue;

        if (g_AddDownloads)
        {
            AddFileToDownloadsTable(path);
        }
        PrecacheModel(path, true);
    }

    for (int i = 0; i < g_MaterialList.Length; i++)
    {
        g_MaterialList.GetString(i, path, sizeof(path));
        if (!path[0])
            continue;

        if (g_AddDownloads)
        {
            AddFileToDownloadsTable(path);
        }
    }

    for (int i = 0; i < g_SoundList.Length; i++)
    {
        g_SoundList.GetString(i, path, sizeof(path));
        if (!path[0])
            continue;

        if (g_AddDownloads)
        {
            AddFileToDownloadsTable(path);
        }
        PrecacheSound(path, true);
    }

    for (int i = 0; i < g_GenericList.Length; i++)
    {
        g_GenericList.GetString(i, path, sizeof(path));
        if (!path[0])
            continue;

        if (g_AddDownloads)
        {
            AddFileToDownloadsTable(path);
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
