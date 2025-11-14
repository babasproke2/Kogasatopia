#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define CONFIG_FILE "configs/precachefiles.cfg"

ArrayList g_ModelList;
ArrayList g_ModelVariantList;
ArrayList g_MaterialList;
ArrayList g_SoundList;
ArrayList g_GenericList;

public Plugin myinfo =
{
    name = "Precache Manager",
    author = "Codex",
    description = "Adds configured assets to the download table and precaches them.",
    version = "1.0.0",
    url = "https://kogasa.tf"
};

public void OnPluginStart()
{
    g_ModelList = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
    g_ModelVariantList = new ArrayList(ByteCountToCells(64));
    g_MaterialList = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
    g_SoundList = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
    g_GenericList = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));

    LoadPrecacheConfig();
}

public void OnConfigsExecuted()
{
    LoadPrecacheConfig();
}

public void OnMapStart()
{
    AddConfiguredDownloads();
}

static void LoadPrecacheConfig()
{
    g_ModelList.Clear();
    g_ModelVariantList.Clear();
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

    if (kv.JumpToKey("model_variants"))
    {
        if (kv.GotoFirstSubKey(false))
        {
            do
            {
                char value[64];
                kv.GetString(NULL_STRING, value, sizeof(value));
                TrimString(value);
                if (value[0])
                {
                    g_ModelVariantList.PushString(value);
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

        AddFileToDownloadsTable(path);
        PrecacheModel(path, true);

        if (g_ModelVariantList.Length > 0)
        {
            char basePath[PLATFORM_MAX_PATH];
            strcopy(basePath, sizeof(basePath), path);
            int len = strlen(basePath);
            if (len > 4)
            {
                basePath[len - 4] = '\0';

                char variantName[64];
                for (int j = 0; j < g_ModelVariantList.Length; j++)
                {
                    g_ModelVariantList.GetString(j, variantName, sizeof(variantName));
                    if (!variantName[0])
                        continue;

                    Format(path, sizeof(path), "%s%s", basePath, variantName);
                    AddFileToDownloadsTable(path);
                }
            }
        }
    }

    for (int i = 0; i < g_MaterialList.Length; i++)
    {
        g_MaterialList.GetString(i, path, sizeof(path));
        if (!path[0])
            continue;

        AddFileToDownloadsTable(path);
    }

    for (int i = 0; i < g_SoundList.Length; i++)
    {
        g_SoundList.GetString(i, path, sizeof(path));
        if (!path[0])
            continue;

        AddFileToDownloadsTable(path);
        PrecacheSound(path, true);
    }

    for (int i = 0; i < g_GenericList.Length; i++)
    {
        g_GenericList.GetString(i, path, sizeof(path));
        if (!path[0])
            continue;

        AddFileToDownloadsTable(path);
    }
}
