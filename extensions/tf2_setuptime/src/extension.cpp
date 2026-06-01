/**
 * vim: set ts=4 :
 * =============================================================================
 * TF2 SetupTime SourceMod Extension
 *
 * Exposes this SourcePawn native:
 *     native bool TF2_IsSetupTimeActive();
 *
 * It reads CTFGameRules::m_bInSetup through the TF2 game-rules proxy sendprop.
 * =============================================================================
 */

#include "extension.h"

#include <cstdint>
#include <cstdio>
#include <cstring>

TF2SetupTimeExtension g_TF2SetupTimeExtension;
SMEXT_LINK(&g_TF2SetupTimeExtension);

namespace
{
constexpr const char *kGameFolder = "tf";
constexpr const char *kGameRulesProxyClass = "CTFGameRulesProxy";
constexpr const char *kGameRulesDataTable = "tf_gamerules_data";
constexpr const char *kSetupProp = "m_bInSetup";

int g_SetupOffset = -1;
SendTableProxyFn g_GameRulesProxyFn = nullptr;

ServerClass *FindServerClassByName(const char *name)
{
    for (ServerClass *serverClass = gamedll->GetAllServerClasses(); serverClass != nullptr; serverClass = serverClass->m_pNext)
    {
        if (std::strcmp(serverClass->GetName(), name) == 0)
        {
            return serverClass;
        }
    }

    return nullptr;
}

bool FindNestedDataTable(SendTable *table, const char *name, sm_sendprop_info_t *info, unsigned int baseOffset = 0)
{
    if (table == nullptr)
    {
        return false;
    }

    const int propCount = table->GetNumProps();
    for (int i = 0; i < propCount; i++)
    {
        SendProp *prop = table->GetProp(i);
        if (prop == nullptr)
        {
            continue;
        }

        SendTable *child = prop->GetDataTable();
        if (child == nullptr)
        {
            continue;
        }

        const char *propName = prop->GetName();
        const unsigned int actualOffset = baseOffset + prop->GetOffset();

        if (propName != nullptr && std::strcmp(propName, name) == 0)
        {
            info->prop = prop;
            info->actual_offset = actualOffset;
            return true;
        }

        if (FindNestedDataTable(child, name, info, actualOffset))
        {
            return true;
        }
    }

    return false;
}

bool ResolveGameRulesProxyFn(char *error = nullptr, size_t maxlength = 0)
{
    if (g_GameRulesProxyFn != nullptr)
    {
        return true;
    }

    ServerClass *serverClass = FindServerClassByName(kGameRulesProxyClass);
    if (serverClass == nullptr)
    {
        if (error != nullptr && maxlength > 0)
        {
            std::snprintf(error, maxlength, "Could not find server class %s", kGameRulesProxyClass);
        }
        return false;
    }

    sm_sendprop_info_t tableInfo;
    if (!FindNestedDataTable(serverClass->m_pTable, kGameRulesDataTable, &tableInfo))
    {
        if (error != nullptr && maxlength > 0)
        {
            std::snprintf(error, maxlength, "Could not find game-rules data table %s", kGameRulesDataTable);
        }
        return false;
    }

    g_GameRulesProxyFn = tableInfo.prop->GetDataTableProxyFn();
    if (g_GameRulesProxyFn == nullptr)
    {
        if (error != nullptr && maxlength > 0)
        {
            std::snprintf(error, maxlength, "Game-rules data table %s has no proxy function", kGameRulesDataTable);
        }
        return false;
    }

    return true;
}

void *GetTFGameRules()
{
    if (!ResolveGameRulesProxyFn())
    {
        return nullptr;
    }

    // This is the same safe lookup strategy used by SDKTools' GameRules helpers:
    // call the game-rules data-table proxy to retrieve the active CTFGameRules pointer.
    CSendProxyRecipients recipients;
    return g_GameRulesProxyFn(nullptr, nullptr, nullptr, &recipients, 0);
}

bool ResolveSetupOffset(char *error = nullptr, size_t maxlength = 0)
{
    if (g_SetupOffset >= 0)
    {
        return true;
    }

    sm_sendprop_info_t setupInfo;
    if (!gamehelpers->FindSendPropInfo(kGameRulesProxyClass, kSetupProp, &setupInfo))
    {
        if (error != nullptr && maxlength > 0)
        {
            std::snprintf(error, maxlength, "Could not find %s.%s", kGameRulesProxyClass, kSetupProp);
        }
        return false;
    }

    if (setupInfo.prop == nullptr || setupInfo.prop->GetType() != DPT_Int)
    {
        if (error != nullptr && maxlength > 0)
        {
            std::snprintf(error, maxlength, "%s.%s is not an integer/bool sendprop", kGameRulesProxyClass, kSetupProp);
        }
        return false;
    }

    g_SetupOffset = static_cast<int>(setupInfo.actual_offset);
    return true;
}

cell_t Native_TF2_IsSetupTimeActive(IPluginContext *context, const cell_t *params)
{
    if (!ResolveSetupOffset())
    {
        return context->ThrowNativeError("Could not resolve %s.%s", kGameRulesProxyClass, kSetupProp);
    }

    void *gameRules = GetTFGameRules();
    if (gameRules == nullptr)
    {
        return context->ThrowNativeError("Could not resolve the active TF2 game-rules pointer");
    }

    const bool inSetup = *reinterpret_cast<bool *>(reinterpret_cast<uintptr_t>(gameRules) + g_SetupOffset);
    return inSetup ? 1 : 0;
}

sp_nativeinfo_t g_Natives[] =
{
    {"TF2_IsSetupTimeActive", Native_TF2_IsSetupTimeActive},
    {nullptr, nullptr}
};
} // namespace

bool TF2SetupTimeExtension::SDK_OnLoad(char *error, size_t maxlength, bool late)
{
    const char *gameFolder = g_pSM->GetGameFolderName();
    if (gameFolder == nullptr || std::strcmp(gameFolder, kGameFolder) != 0)
    {
        std::snprintf(error, maxlength, "TF2 SetupTime only supports Team Fortress 2; current game folder is '%s'", gameFolder ? gameFolder : "unknown");
        return false;
    }

    if (!ResolveSetupOffset(error, maxlength))
    {
        return false;
    }

    // This can fail before a map is fully active, so do not make it fatal.
    // The native retries and throws a SourcePawn-native error if still unavailable.
    ResolveGameRulesProxyFn();

    sharesys->AddNatives(myself, g_Natives);
    sharesys->RegisterLibrary(myself, "tf2_setuptime");

    return true;
}
