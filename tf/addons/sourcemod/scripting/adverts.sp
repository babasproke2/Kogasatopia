#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#include <morecolors>

#undef REQUIRE_PLUGIN
#include <mapchooser>
#define REQUIRE_PLUGIN

#define PL_VERSION "3.0.0"

public Plugin myinfo =
{
	name = "Adverts",
	author = "Hombre, Tsunami",
	description = "Print advertisement messages in an interval",
	version = PL_VERSION,
	url = "https://kogasa.tf"
};

enum struct Advertisement
{
	char chat[2048];
	bool usePrefix;
}

enum AdvertsSection
{
	AdvertsSection_None = 0,
	AdvertsSection_Plain,
	AdvertsSection_Prefix
};

ArrayList g_Ads;
ConVar g_CvarEnabled, g_CvarFile, g_CvarInterval, g_CvarRandom, g_CvarPrefix;
Handle g_Timer;
int g_AdIndex;

public void OnPluginStart()
{
	CreateConVar("sm_adverts_version", PL_VERSION, "Display advertisements", FCVAR_NOTIFY);
	g_CvarEnabled = CreateConVar("sm_adverts_enabled", "1", "Enable/disable displaying advertisements.");
	g_CvarFile = CreateConVar("sm_adverts_file", "adverts.cfg", "File to read the advertisements from.");
	g_CvarInterval = CreateConVar("sm_adverts_interval", "600", "Number of seconds between advertisements.");
	g_CvarRandom = CreateConVar("sm_adverts_random", "1", "Enable/disable random advertisements.");
	g_CvarPrefix = CreateConVar("sm_adverts_prefix", "{gold}[Server]", "Prefix added before each prefixed chat advertisement ({default} and a space are appended automatically).");

	g_CvarFile.AddChangeHook(CvarChanged_File);
	g_CvarRandom.AddChangeHook(CvarChanged_Reload);
	g_CvarInterval.AddChangeHook(CvarChanged_Timer);

	g_Ads = new ArrayList(sizeof(Advertisement));
	RegServerCmd("sm_adverts_reload", Command_ReloadAds, "Reload the advertisements");

	LoadAdvertisements();
	RestartTimer();
}

public void OnConfigsExecuted()
{
	LoadAdvertisements();
	RestartTimer();
}

public void OnPluginEnd()
{
	delete g_Timer;
	delete g_Ads;
}

public void CvarChanged_Reload(ConVar convar, const char[] oldValue, const char[] newValue)
{
	LoadAdvertisements();
	RestartTimer();
}

public void CvarChanged_File(ConVar convar, const char[] oldValue, const char[] newValue)
{
	LoadAdvertisements();
	RestartTimer();
}

public void CvarChanged_Timer(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (!g_Ads.Length) {
		LoadAdvertisements();
	}
	RestartTimer();
}

public Action Command_ReloadAds(int args)
{
	LoadAdvertisements();
	RestartTimer();
	return Plugin_Handled;
}

public int MenuHandler_Noop(Menu menu, MenuAction action, int param1, int param2)
{
	return 0;
}

public Action Timer_DisplayAd(Handle timer)
{
	if (!g_CvarEnabled.BoolValue || !g_Ads.Length) {
		return Plugin_Continue;
	}

	Advertisement ad;
	int adIndex = g_CvarRandom.BoolValue ? GetRandomInt(0, g_Ads.Length - 1) : g_AdIndex;
	g_Ads.GetArray(adIndex, ad);

	if (ad.chat[0]) {
		char prefix[128];
		if (ad.usePrefix) {
			g_CvarPrefix.GetString(prefix, sizeof(prefix));
		} else {
			prefix[0] = '\0';
		}

		char lines[10][1024], tmp[1024];
		int count = ExplodeString(ad.chat, "\n", lines, sizeof(lines), sizeof(lines[]));
		for (int n = 0; n < count; n++) {
			ProcessVariables(lines[n], tmp, sizeof(tmp));
			FormatChatMessage(prefix, tmp, lines[n], sizeof(lines[]));
		PrintToServer("[Advertisements] %s", lines[n]);
		}
		for (int i = 1; i <= MaxClients; i++) {
			if (!CanSeeAd(i)) {
				continue;
			}
			for (int n = 0; n < count; n++) {
				if (StrContains(lines[n], "{teamcolor}", false) != -1) {
					CPrintToChatEx(i, i, "%s", lines[n]);
				} else {
					CPrintToChat(i, "%s", lines[n]);
				}
			}
		}
	}

	if (!g_CvarRandom.BoolValue) {
		if (++g_AdIndex >= g_Ads.Length) {
			g_AdIndex = 0;
		}
	}
	return Plugin_Continue;
}

bool CanSeeAd(int client)
{
	return IsClientInGame(client) && !IsFakeClient(client);
}

void LoadAdvertisements()
{
	g_AdIndex = 0;
	g_Ads.Clear();

	char file[PLATFORM_MAX_PATH], path[PLATFORM_MAX_PATH];
	g_CvarFile.GetString(file, sizeof(file));
	BuildPath(Path_SM, path, sizeof(path), "configs/%s", file);
	if (!FileExists(path)) {
		SetFailState("File Not Found: %s", path);
		return;
	}

	File adverts = OpenFile(path, "r");
	if (adverts == null) {
		LogError("[Adverts] Could not open %s", path);
		return;
	}

	char line[2048], token[2048];
	AdvertsSection currentSection = AdvertsSection_None;
	AdvertsSection pendingSection = AdvertsSection_None;

	while (!adverts.EndOfFile() && adverts.ReadLine(line, sizeof(line))) {
		TrimString(line);
		if (!line[0] || StrContains(line, "//") == 0) {
			continue;
		}
		if (StrEqual(line, "{")) {
			if (pendingSection != AdvertsSection_None) {
				currentSection = pendingSection;
				pendingSection = AdvertsSection_None;
			}
			continue;
		}
		if (StrEqual(line, "}")) {
			currentSection = AdvertsSection_None;
			continue;
		}

		if (!ExtractQuotedString(line, token, sizeof(token))) {
			continue;
		}

		if (StrEqual(token, "advertsPlain", false)) {
			pendingSection = AdvertsSection_Plain;
			if (StrContains(line, "{") != -1) {
				currentSection = pendingSection;
				pendingSection = AdvertsSection_None;
			}
			continue;
		}
		if (StrEqual(token, "advertsPrefix", false)) {
			pendingSection = AdvertsSection_Prefix;
			if (StrContains(line, "{") != -1) {
				currentSection = pendingSection;
				pendingSection = AdvertsSection_None;
			}
			continue;
		}

		if (currentSection == AdvertsSection_Plain || currentSection == AdvertsSection_Prefix) {
			AddAdvertisement(token, currentSection == AdvertsSection_Prefix);
		}
	}

	delete adverts;
	PrintToServer("[Advertisements] Loaded %d advertisement%s from %s.", g_Ads.Length, g_Ads.Length == 1 ? "" : "s", path);
}

void AddAdvertisement(const char[] message, bool usePrefix)
{
	if (!message[0]) {
		return;
	}

	Advertisement ad;
	strcopy(ad.chat, sizeof(ad.chat), message);
	ad.usePrefix = usePrefix;
	g_Ads.PushArray(ad);
}

bool ExtractQuotedString(const char[] line, char[] buffer, int maxlen)
{
	int start = FindCharInString(line, '"');
	if (start == -1) {
		return false;
	}

	int out = 0;
	for (int i = start + 1; line[i] && out < maxlen - 1; i++) {
		if (line[i] == '\\' && line[i + 1]) {
			buffer[out++] = line[++i];
			continue;
		}
		if (line[i] == '"') {
			buffer[out] = '\0';
			return true;
		}
		buffer[out++] = line[i];
	}

	buffer[out] = '\0';
	return out > 0;
}

void RestartTimer()
{
	delete g_Timer;
	int interval = g_CvarInterval.IntValue;
	if (interval > 0) {
		g_Timer = CreateTimer(float(interval), Timer_DisplayAd, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	}
}

void FormatChatMessage(const char[] prefix, const char[] msg, char[] out, int maxlen)
{
	if (prefix[0]) {
		FormatEx(out, maxlen, "%s{default} %s", prefix, msg);
	} else {
		strcopy(out, maxlen, msg);
	}
}

void ProcessVariables(const char[] src, char[] out, int maxlen)
{
	char name[64], value[256];
	int i, j, len;

	while (src[i] && j < maxlen - 1) {
		if (src[i] != '{' || (len = FindCharInString(src[i + 1], '}')) == -1) {
			out[j++] = src[i++];
			continue;
		}

		strcopy(name, len + 1, src[i + 1]);

		if (StrEqual(name, "currentmap", false)) {
			GetCurrentMap(value, sizeof(value));
			GetMapDisplayName(value, value, sizeof(value));
			j += strcopy(out[j], maxlen - j, value);
		} else if (StrEqual(name, "nextmap", false)) {
			if (LibraryExists("mapchooser") && EndOfMapVoteEnabled() && !HasEndOfMapVoteFinished()) {
				j += strcopy(out[j], maxlen - j, "Pending Vote");
			} else {
				GetNextMap(value, sizeof(value));
				GetMapDisplayName(value, value, sizeof(value));
				j += strcopy(out[j], maxlen - j, value);
			}
		} else if (StrEqual(name, "date", false)) {
			FormatTime(value, sizeof(value), "%m/%d/%Y");
			j += strcopy(out[j], maxlen - j, value);
		} else if (StrEqual(name, "time", false)) {
			FormatTime(value, sizeof(value), "%I:%M:%S%p");
			j += strcopy(out[j], maxlen - j, value);
		} else if (StrEqual(name, "time24", false)) {
			FormatTime(value, sizeof(value), "%H:%M:%S");
			j += strcopy(out[j], maxlen - j, value);
		} else if (StrEqual(name, "timeleft", false)) {
			int mins, secs, left;
			if (GetMapTimeLeft(left) && left > 0) {
				mins = left / 60;
				secs = left % 60;
			}
			j += FormatEx(out[j], maxlen - j, "%d:%02d", mins, secs);
		} else {
			ConVar cv = FindConVar(name);
			if (cv != null) {
				cv.GetString(value, sizeof(value));
				j += strcopy(out[j], maxlen - j, value);
			} else {
				j += FormatEx(out[j], maxlen - j, "{%s}", name);
			}
		}

		i += len + 2;
	}
	out[j] = '\0';
}
