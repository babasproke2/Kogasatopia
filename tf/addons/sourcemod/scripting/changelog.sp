#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <morecolors>

#define CHANGELOG_CONFIG "configs/changelog.cfg"
#define CHANGELOG_DATE_KEY_LENGTH 16
#define CHANGELOG_DATE_LONG_LENGTH 64
#define CHANGELOG_TEXT_LENGTH 256

public Plugin myinfo =
{
    name = "Changelog",
    author = "Hombre",
    description = "Displays server changelog entries.",
    version = "1.0.0",
    url = "https://kogasa.tf"
};

public void OnPluginStart()
{
    RegConsoleCmd("sm_changelog", Command_Changelog, "Open the server changelog.");
    RegConsoleCmd("sm_log", Command_Changelog, "Open the server changelog.");
}

public Action Command_Changelog(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return Plugin_Handled;
    }

    ShowChangelogMenu(client);
    return Plugin_Handled;
}

void ShowChangelogMenu(int client)
{
    KeyValues changelog = LoadChangelog();
    if (changelog == null)
    {
        CPrintToChat(client, "{green}[Changelog]{default} Changelog data is unavailable.");
        return;
    }

    ArrayList dates = new ArrayList();
    if (changelog.GotoFirstSubKey())
    {
        do
        {
            char dateKey[CHANGELOG_DATE_KEY_LENGTH];
            changelog.GetSectionName(dateKey, sizeof(dateKey));

            int sortableDate;
            if (ParseSortableDate(dateKey, sortableDate))
            {
                dates.Push(sortableDate);
            }
        }
        while (changelog.GotoNextKey());
    }

    if (dates.Length == 0)
    {
        delete dates;
        delete changelog;
        CPrintToChat(client, "{green}[Changelog]{default} No changelog entries were found.");
        return;
    }

    dates.Sort(Sort_Descending, Sort_Integer);

    Menu menu = new Menu(MenuHandler_Changelog);
    menu.SetTitle("Changelog");

    for (int i = 0; i < dates.Length; i++)
    {
        char dateKey[CHANGELOG_DATE_KEY_LENGTH];
        FormatDateKey(dates.Get(i), dateKey, sizeof(dateKey));

        if (!MoveToDateSection(changelog, dateKey))
        {
            continue;
        }

        char dateLong[CHANGELOG_DATE_LONG_LENGTH];
        changelog.GetString("date_long", dateLong, sizeof(dateLong), dateKey);
        menu.AddItem(dateKey, dateLong);
    }

    delete dates;
    delete changelog;

    if (menu.ItemCount == 0)
    {
        delete menu;
        CPrintToChat(client, "{green}[Changelog]{default} No changelog entries could be displayed.");
        return;
    }

    menu.ExitButton = true;
    if (!menu.Display(client, MENU_TIME_FOREVER))
    {
        delete menu;
        CPrintToChat(client, "{green}[Changelog]{default} The changelog menu could not be opened.");
    }
}

public int MenuHandler_Changelog(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }

    if (action != MenuAction_Select || client <= 0 || !IsClientInGame(client))
    {
        return 0;
    }

    char dateKey[CHANGELOG_DATE_KEY_LENGTH];
    menu.GetItem(item, dateKey, sizeof(dateKey));
    PrintChangelogEntry(client, dateKey);
    return 0;
}

void PrintChangelogEntry(int client, const char[] dateKey)
{
    KeyValues changelog = LoadChangelog();
    if (changelog == null || !MoveToDateSection(changelog, dateKey))
    {
        delete changelog;
        CPrintToChat(client, "{green}[Changelog]{default} That changelog entry is unavailable.");
        return;
    }

    int printed = 0;
    for (int i = 1; ; i++)
    {
        char changeKey[24];
        char changeText[CHANGELOG_TEXT_LENGTH];
        FormatEx(changeKey, sizeof(changeKey), "change%d", i);
        changelog.GetString(changeKey, changeText, sizeof(changeText));
        if (changeText[0] == '\0')
        {
            break;
        }

        CPrintToChat(client, "{green}%d. {gold}%s", i, changeText);
        printed++;
    }

    delete changelog;

    if (printed == 0)
    {
        CPrintToChat(client, "{green}[Changelog]{default} No changes were recorded for that date.");
    }
}

bool MoveToDateSection(KeyValues changelog, const char[] dateKey)
{
    changelog.Rewind();
    if (!changelog.GotoFirstSubKey())
    {
        return false;
    }

    do
    {
        char currentDate[CHANGELOG_DATE_KEY_LENGTH];
        changelog.GetSectionName(currentDate, sizeof(currentDate));
        if (StrEqual(currentDate, dateKey))
        {
            return true;
        }
    }
    while (changelog.GotoNextKey());

    changelog.Rewind();
    return false;
}

KeyValues LoadChangelog()
{
    char configPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, configPath, sizeof(configPath), CHANGELOG_CONFIG);

    KeyValues changelog = new KeyValues("changelog");
    if (!changelog.ImportFromFile(configPath))
    {
        delete changelog;
        return null;
    }

    return changelog;
}

bool ParseSortableDate(const char[] dateKey, int &sortableDate)
{
    char parts[3][8];
    if (ExplodeString(dateKey, "/", parts, sizeof(parts), sizeof(parts[])) != 3)
    {
        return false;
    }

    int day = StringToInt(parts[0]);
    int month = StringToInt(parts[1]);
    int year = StringToInt(parts[2]);
    if (day < 1 || day > 31 || month < 1 || month > 12 || year < 1)
    {
        return false;
    }

    sortableDate = year * 10000 + month * 100 + day;
    return true;
}

void FormatDateKey(int sortableDate, char[] dateKey, int maxlen)
{
    int year = sortableDate / 10000;
    int month = (sortableDate / 100) % 100;
    int day = sortableDate % 100;
    FormatEx(dateKey, maxlen, "%02d/%02d/%04d", day, month, year);
}
