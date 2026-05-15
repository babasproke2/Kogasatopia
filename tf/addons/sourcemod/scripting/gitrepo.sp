#include <sourcemod>
#include <morecolors>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "0.1.0"
#define GIT_REPO_LINE_MAX 1024
#define GIT_REPO_RETRY_SECONDS 10.0

public Plugin myinfo =
{
    name = "Git Repo Display",
    author = "OpenAI",
    description = "Publishes local git repository metadata to display-only ConVars.",
    version = PLUGIN_VERSION,
    url = "https://openai.com"
};

ConVar g_hRepoSourcePath = null;
ConVar g_hRefreshSeconds = null;
ConVar g_hRepoNameOverride = null;

ConVar g_hRepoStatus = null;
ConVar g_hRepoError = null;
ConVar g_hRepoName = null;
ConVar g_hRepoBranch = null;
ConVar g_hRepoCommit = null;
ConVar g_hRepoCommitShort = null;
ConVar g_hRepoCommitMessage = null;
ConVar g_hRepoCommitDate = null;
ConVar g_hRepoCommitUnix = null;
ConVar g_hRepoCommitTimezone = null;

Handle g_hRefreshTimer = null;
Handle g_hRetryTimer = null;
char g_sLastError[256];

public void OnPluginStart()
{
    g_hRepoSourcePath = CreateConVar(
        "sm_gitrepo_source_path",
        "",
        "Path to a git work tree, .git directory, or .git gitdir file.",
        FCVAR_NONE
    );
    g_hRefreshSeconds = CreateConVar(
        "sm_gitrepo_refresh_seconds",
        "300.0",
        "How often to refresh git metadata from disk. Set to 0 to disable polling.",
        FCVAR_NONE
    );
    g_hRepoNameOverride = CreateConVar(
        "sm_gitrepo_name_override",
        "",
        "Optional repo name override for the display ConVars.",
        FCVAR_NONE
    );

    g_hRepoStatus = CreateConVar(
        "sm_gitrepo_status",
        "disabled",
        "Git metadata status: disabled, ok, partial, or error.",
        FCVAR_NOTIFY | FCVAR_DONTRECORD
    );
    g_hRepoError = CreateConVar(
        "sm_gitrepo_error",
        "",
        "Last git metadata refresh error.",
        FCVAR_NOTIFY | FCVAR_DONTRECORD
    );
    g_hRepoName = CreateConVar(
        "sm_gitrepo_name",
        "",
        "Resolved repository display name.",
        FCVAR_NOTIFY | FCVAR_DONTRECORD
    );
    g_hRepoBranch = CreateConVar(
        "sm_gitrepo_branch",
        "",
        "Resolved HEAD branch name or detached.",
        FCVAR_NOTIFY | FCVAR_DONTRECORD
    );
    g_hRepoCommit = CreateConVar(
        "sm_gitrepo_commit",
        "",
        "Resolved full HEAD commit hash.",
        FCVAR_NOTIFY | FCVAR_DONTRECORD
    );
    g_hRepoCommitShort = CreateConVar(
        "sm_gitrepo_commit_short",
        "",
        "Resolved short HEAD commit hash.",
        FCVAR_NOTIFY | FCVAR_DONTRECORD
    );
    g_hRepoCommitMessage = CreateConVar(
        "sm_gitrepo_commit_message",
        "",
        "Last HEAD reflog message, truncated to 256 characters.",
        FCVAR_NOTIFY | FCVAR_DONTRECORD
    );
    g_hRepoCommitDate = CreateConVar(
        "sm_gitrepo_commit_date",
        "",
        "Last HEAD update time formatted in the server timezone.",
        FCVAR_NOTIFY | FCVAR_DONTRECORD
    );
    g_hRepoCommitUnix = CreateConVar(
        "sm_gitrepo_commit_unix",
        "",
        "Last HEAD update unix timestamp from git logs/HEAD.",
        FCVAR_NOTIFY | FCVAR_DONTRECORD
    );
    g_hRepoCommitTimezone = CreateConVar(
        "sm_gitrepo_commit_timezone",
        "",
        "Timezone token parsed from git logs/HEAD.",
        FCVAR_NOTIFY | FCVAR_DONTRECORD
    );

    HookConVarChange(g_hRepoSourcePath, ConVarChanged_Refresh);
    HookConVarChange(g_hRefreshSeconds, ConVarChanged_Refresh);
    HookConVarChange(g_hRepoNameOverride, ConVarChanged_Refresh);

    RegAdminCmd("sm_gitrepo_refresh", Command_RefreshGitRepo, ADMFLAG_GENERIC, "Refresh git repo display ConVars now.");
    RegConsoleCmd("sm_git", Command_ShowGitDisplay, "Show git repository display metadata.");
    RegConsoleCmd("sm_repo", Command_ShowGitDisplay, "Show git repository display metadata.");
    RegConsoleCmd("sm_github", Command_ShowGitDisplay, "Show git repository display metadata.");

    AutoExecConfig(true, "git_repo_display");
    RefreshTimer();
    RefreshGitMetadata(false);
}

public void OnConfigsExecuted()
{
    RefreshTimer();
    RefreshGitMetadata(false);
}

public void OnMapStart()
{
    RefreshGitMetadata(false);
}

public void OnMapEnd()
{
    g_hRefreshTimer = null;
    g_hRetryTimer = null;
}

public void ConVarChanged_Refresh(ConVar convar, const char[] oldValue, const char[] newValue)
{
    RefreshTimer();
    RefreshGitMetadata(false);
}

public Action Command_RefreshGitRepo(int client, int args)
{
    RefreshGitMetadata(true);

    char status[32];
    char repoName[128];
    char branch[128];
    char commitShort[16];
    char commitDate[64];
    char error[256];

    g_hRepoStatus.GetString(status, sizeof(status));
    g_hRepoName.GetString(repoName, sizeof(repoName));
    g_hRepoBranch.GetString(branch, sizeof(branch));
    g_hRepoCommitShort.GetString(commitShort, sizeof(commitShort));
    g_hRepoCommitDate.GetString(commitDate, sizeof(commitDate));
    g_hRepoError.GetString(error, sizeof(error));

    ReplyToCommand(
        client,
        "[GitRepoDisplay] status=%s repo=%s branch=%s commit=%s date=%s%s%s",
        status,
        repoName,
        branch,
        commitShort,
        commitDate,
        error[0] ? " error=" : "",
        error
    );
    return Plugin_Handled;
}

public Action Command_ShowGitDisplay(int client, int args)
{
    char repoName[128];
    char branch[128];
    char commitShort[16];
    char commitMessage[257];
    char commitDate[64];

    g_hRepoName.GetString(repoName, sizeof(repoName));
    g_hRepoBranch.GetString(branch, sizeof(branch));
    g_hRepoCommitShort.GetString(commitShort, sizeof(commitShort));
    g_hRepoCommitMessage.GetString(commitMessage, sizeof(commitMessage));
    g_hRepoCommitDate.GetString(commitDate, sizeof(commitDate));

    CPrintToChat(client, "{green}[Git Display]{default} %s, %s", repoName, branch);
    CPrintToChat(client, "{green}[Git Display]{default} %s", commitShort);
    CPrintToChat(client, "{green}[Git Display]{default} %s", commitMessage);
    CPrintToChat(client, "{green}[Git Display]{default} %s", commitDate);
    return Plugin_Handled;
}

public Action Timer_RefreshGitMetadata(Handle timer, any data)
{
    if (timer != g_hRefreshTimer)
    {
        return Plugin_Stop;
    }

    RefreshGitMetadata(false);
    return Plugin_Continue;
}

public Action Timer_RetryGitMetadata(Handle timer, any data)
{
    if (timer != g_hRetryTimer)
    {
        return Plugin_Stop;
    }

    g_hRetryTimer = null;
    RefreshGitMetadata(false);
    return Plugin_Stop;
}

void ScheduleRetry()
{
    if (g_hRetryTimer != null)
    {
        return;
    }

    g_hRetryTimer = CreateTimer(GIT_REPO_RETRY_SECONDS, Timer_RetryGitMetadata, _, TIMER_FLAG_NO_MAPCHANGE);
}

void CancelRetry()
{
    if (g_hRetryTimer != null)
    {
        delete g_hRetryTimer;
        g_hRetryTimer = null;
    }
}

void RefreshTimer()
{
    if (g_hRefreshTimer != null)
    {
        delete g_hRefreshTimer;
        g_hRefreshTimer = null;
    }

    float interval = g_hRefreshSeconds.FloatValue;
    if (interval > 0.0)
    {
        g_hRefreshTimer = CreateTimer(interval, Timer_RefreshGitMetadata, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    }
}

bool RefreshGitMetadata(bool logFailures)
{
    char sourcePath[PLATFORM_MAX_PATH];
    g_hRepoSourcePath.GetString(sourcePath, sizeof(sourcePath));
    TrimString(sourcePath);

    if (sourcePath[0] == '\0')
    {
        CancelRetry();
        ClearDisplayMetadata("disabled", "", false);
        return false;
    }

    char gitDir[PLATFORM_MAX_PATH];
    char workTree[PLATFORM_MAX_PATH];
    char error[256];
    if (!ResolveGitDirectory(sourcePath, gitDir, sizeof(gitDir), workTree, sizeof(workTree), error, sizeof(error)))
    {
        ScheduleRetry();
        ClearDisplayMetadata("error", error, logFailures);
        return false;
    }

    char repoName[128];
    ResolveRepoName(workTree, gitDir, repoName, sizeof(repoName));
    g_hRepoName.SetString(repoName, true, true);

    bool haveHead = false;
    bool haveDate = false;

    char refPath[PLATFORM_MAX_PATH];
    char branch[128];
    char commitHash[64];
    char shortHash[16];
    char commitMessage[257];
    char commitDate[64];
    char commitUnix[16];
    char commitTimezone[16];

    error[0] = '\0';

    if (ResolveHeadCommit(gitDir, refPath, sizeof(refPath), commitHash, sizeof(commitHash), error, sizeof(error)))
    {
        ExtractBranchName(refPath, branch, sizeof(branch));
        BuildShortCommit(commitHash, shortHash, sizeof(shortHash));

        g_hRepoBranch.SetString(branch, true, true);
        g_hRepoCommit.SetString(commitHash, true, true);
        g_hRepoCommitShort.SetString(shortHash, true, true);
        haveHead = true;
    }
    else
    {
        g_hRepoBranch.SetString("", true, true);
        g_hRepoCommit.SetString("", true, true);
        g_hRepoCommitShort.SetString("", true, true);
    }

    char dateError[256];
    if (ResolveHeadDate(gitDir, commitDate, sizeof(commitDate), commitUnix, sizeof(commitUnix), commitTimezone, sizeof(commitTimezone), commitMessage, sizeof(commitMessage), dateError, sizeof(dateError)))
    {
        g_hRepoCommitDate.SetString(commitDate, true, true);
        g_hRepoCommitUnix.SetString(commitUnix, true, true);
        g_hRepoCommitTimezone.SetString(commitTimezone, true, true);
        g_hRepoCommitMessage.SetString(commitMessage, true, true);
        haveDate = true;
    }
    else
    {
        g_hRepoCommitDate.SetString("", true, true);
        g_hRepoCommitUnix.SetString("", true, true);
        g_hRepoCommitTimezone.SetString("", true, true);
        g_hRepoCommitMessage.SetString("", true, true);
        if (error[0] == '\0')
        {
            strcopy(error, sizeof(error), dateError);
        }
    }

    if (haveHead && haveDate)
    {
        CancelRetry();
        SetStatus("ok", "", false);
        return true;
    }

    if (error[0] == '\0')
    {
        strcopy(error, sizeof(error), "Repository metadata refresh only completed partially.");
    }

    ScheduleRetry();
    SetStatus("partial", error, logFailures);
    return haveHead || haveDate;
}

void ClearDisplayMetadata(const char[] status, const char[] error, bool logFailures)
{
    g_hRepoName.SetString("", true, true);
    g_hRepoBranch.SetString("", true, true);
    g_hRepoCommit.SetString("", true, true);
    g_hRepoCommitShort.SetString("", true, true);
    g_hRepoCommitMessage.SetString("", true, true);
    g_hRepoCommitDate.SetString("", true, true);
    g_hRepoCommitUnix.SetString("", true, true);
    g_hRepoCommitTimezone.SetString("", true, true);
    SetStatus(status, error, logFailures);
}

void SetStatus(const char[] status, const char[] error, bool logFailures)
{
    g_hRepoStatus.SetString(status, true, true);
    g_hRepoError.SetString(error, true, true);

    if (!StrEqual(g_sLastError, error))
    {
        strcopy(g_sLastError, sizeof(g_sLastError), error);
        if (logFailures && error[0] != '\0')
        {
            LogError("[GitRepoDisplay] %s", error);
        }
    }
}

bool ResolveGitDirectory(const char[] sourcePath, char[] gitDir, int gitDirMax, char[] workTree, int workTreeMax, char[] error, int errorMax)
{
    char normalized[PLATFORM_MAX_PATH];
    strcopy(normalized, sizeof(normalized), sourcePath);
    TrimString(normalized);
    TrimTrailingSeparators(normalized);

    if (normalized[0] == '\0')
    {
        FormatEx(error, errorMax, "sm_gitrepo_source_path is empty.");
        return false;
    }

    if (LooksLikeGitDirectory(normalized))
    {
        strcopy(gitDir, gitDirMax, normalized);
        DeriveWorkTreeFromGitPath(normalized, workTree, workTreeMax);
        return true;
    }

    if (FileExists(normalized))
    {
        char baseName[64];
        GetBaseName(normalized, baseName, sizeof(baseName));
        if (StrEqual(baseName, ".git"))
        {
            GetParentPath(normalized, workTree, workTreeMax);
            return ResolveGitdirPointer(normalized, gitDir, gitDirMax, error, errorMax);
        }
    }

    if (!DirExists(normalized))
    {
        FormatEx(error, errorMax, "Path does not exist or is not a directory: %s", normalized);
        return false;
    }

    strcopy(workTree, workTreeMax, normalized);

    char dotGitPath[PLATFORM_MAX_PATH];
    JoinPath(normalized, ".git", dotGitPath, sizeof(dotGitPath));

    if (LooksLikeGitDirectory(dotGitPath))
    {
        strcopy(gitDir, gitDirMax, dotGitPath);
        return true;
    }

    if (FileExists(dotGitPath))
    {
        if (!ResolveGitdirPointer(dotGitPath, gitDir, gitDirMax, error, errorMax))
        {
            return false;
        }
        return true;
    }

    FormatEx(error, errorMax, "Could not find .git metadata under %s", normalized);
    return false;
}

void ResolveRepoName(const char[] workTree, const char[] gitDir, char[] repoName, int repoNameMax)
{
    char overrideValue[128];
    g_hRepoNameOverride.GetString(overrideValue, sizeof(overrideValue));
    TrimString(overrideValue);
    if (overrideValue[0] != '\0')
    {
        strcopy(repoName, repoNameMax, overrideValue);
        return;
    }

    if (workTree[0] != '\0')
    {
        GetBaseName(workTree, repoName, repoNameMax);
        return;
    }

    char gitBase[64];
    GetBaseName(gitDir, gitBase, sizeof(gitBase));
    if (StrEqual(gitBase, ".git"))
    {
        char parentPath[PLATFORM_MAX_PATH];
        GetParentPath(gitDir, parentPath, sizeof(parentPath));
        GetBaseName(parentPath, repoName, repoNameMax);
        return;
    }

    strcopy(repoName, repoNameMax, gitBase);
}

bool ResolveHeadCommit(const char[] gitDir, char[] refPath, int refPathMax, char[] commitHash, int commitHashMax, char[] error, int errorMax)
{
    char headPath[PLATFORM_MAX_PATH];
    JoinPath(gitDir, "HEAD", headPath, sizeof(headPath));

    char headLine[256];
    if (!ReadFirstNonEmptyLine(headPath, headLine, sizeof(headLine)))
    {
        FormatEx(error, errorMax, "Failed to read git HEAD from %s", headPath);
        return false;
    }

    if (StrContains(headLine, "ref:", false) == 0)
    {
        int refPos = 4;
        while (headLine[refPos] == ' ' || headLine[refPos] == '\t')
        {
            refPos++;
        }

        strcopy(refPath, refPathMax, headLine[refPos]);
        if (refPath[0] == '\0')
        {
            FormatEx(error, errorMax, "HEAD ref was empty in %s", headPath);
            return false;
        }

        if (ReadLooseRef(gitDir, refPath, commitHash, commitHashMax))
        {
            return true;
        }

        if (ReadPackedRef(gitDir, refPath, commitHash, commitHashMax))
        {
            return true;
        }

        FormatEx(error, errorMax, "Unable to resolve ref %s in %s", refPath, gitDir);
        return false;
    }

    refPath[0] = '\0';
    TrimString(headLine);
    if (headLine[0] == '\0')
    {
        FormatEx(error, errorMax, "HEAD was empty in %s", headPath);
        return false;
    }

    strcopy(commitHash, commitHashMax, headLine);
    return true;
}

bool ResolveHeadDate(const char[] gitDir, char[] commitDate, int commitDateMax, char[] commitUnix, int commitUnixMax, char[] commitTimezone, int commitTimezoneMax, char[] commitMessage, int commitMessageMax, char[] error, int errorMax)
{
    char reflogPath[PLATFORM_MAX_PATH];
    JoinPath(gitDir, "logs/HEAD", reflogPath, sizeof(reflogPath));

    char lastLine[GIT_REPO_LINE_MAX];
    if (!ReadLastNonEmptyLine(reflogPath, lastLine, sizeof(lastLine)))
    {
        FormatEx(error, errorMax, "Failed to read git reflog from %s", reflogPath);
        return false;
    }

    int timestamp = 0;
    if (!ParseReflogTimestamp(lastLine, timestamp, commitTimezone, commitTimezoneMax))
    {
        FormatEx(error, errorMax, "Failed to parse reflog timestamp from %s", reflogPath);
        return false;
    }

    FormatTime(commitDate, commitDateMax, "%Y-%m-%d %H:%M:%S", timestamp);
    IntToString(timestamp, commitUnix, commitUnixMax);
    ParseReflogMessage(lastLine, commitMessage, commitMessageMax);
    return true;
}

bool ResolveGitdirPointer(const char[] gitPointerPath, char[] gitDir, int gitDirMax, char[] error, int errorMax)
{
    char line[PLATFORM_MAX_PATH];
    if (!ReadFirstNonEmptyLine(gitPointerPath, line, sizeof(line)))
    {
        FormatEx(error, errorMax, "Failed to read gitdir pointer file %s", gitPointerPath);
        return false;
    }

    if (StrContains(line, "gitdir:", false) != 0)
    {
        FormatEx(error, errorMax, "Unexpected gitdir pointer format in %s", gitPointerPath);
        return false;
    }

    int pos = 7;
    while (line[pos] == ' ' || line[pos] == '\t')
    {
        pos++;
    }

    if (line[pos] == '\0')
    {
        FormatEx(error, errorMax, "gitdir pointer was empty in %s", gitPointerPath);
        return false;
    }

    char candidate[PLATFORM_MAX_PATH];
    if (PathIsAbsolute(line[pos]))
    {
        strcopy(candidate, sizeof(candidate), line[pos]);
    }
    else
    {
        char parentPath[PLATFORM_MAX_PATH];
        GetParentPath(gitPointerPath, parentPath, sizeof(parentPath));
        JoinPath(parentPath, line[pos], candidate, sizeof(candidate));
    }

    TrimString(candidate);
    TrimTrailingSeparators(candidate);

    if (!LooksLikeGitDirectory(candidate))
    {
        FormatEx(error, errorMax, "Resolved gitdir does not look valid: %s", candidate);
        return false;
    }

    strcopy(gitDir, gitDirMax, candidate);
    return true;
}

bool ReadLooseRef(const char[] gitDir, const char[] refPath, char[] commitHash, int commitHashMax)
{
    char fullRefPath[PLATFORM_MAX_PATH];
    JoinPath(gitDir, refPath, fullRefPath, sizeof(fullRefPath));
    return ReadFirstNonEmptyLine(fullRefPath, commitHash, commitHashMax);
}

bool ReadPackedRef(const char[] gitDir, const char[] refPath, char[] commitHash, int commitHashMax)
{
    char packedRefsPath[PLATFORM_MAX_PATH];
    JoinPath(gitDir, "packed-refs", packedRefsPath, sizeof(packedRefsPath));

    File file = OpenFile(packedRefsPath, "r");
    if (file == null)
    {
        return false;
    }

    char line[GIT_REPO_LINE_MAX];
    bool found = false;
    while (!file.EndOfFile() && file.ReadLine(line, sizeof(line)))
    {
        TrimString(line);
        if (line[0] == '\0' || line[0] == '#' || line[0] == '^')
        {
            continue;
        }

        int separator = FindCharInString(line, ' ');
        if (separator <= 0)
        {
            continue;
        }

        line[separator] = '\0';
        if (!StrEqual(line[separator + 1], refPath))
        {
            continue;
        }

        strcopy(commitHash, commitHashMax, line);
        found = true;
        break;
    }

    delete file;
    return found;
}

bool ReadFirstNonEmptyLine(const char[] path, char[] buffer, int maxlen)
{
    File file = OpenFile(path, "r");
    if (file == null)
    {
        return false;
    }

    bool found = false;
    while (!file.EndOfFile() && file.ReadLine(buffer, maxlen))
    {
        TrimString(buffer);
        if (buffer[0] == '\0')
        {
            continue;
        }

        found = true;
        break;
    }

    delete file;
    return found;
}

bool ReadLastNonEmptyLine(const char[] path, char[] buffer, int maxlen)
{
    File file = OpenFile(path, "r");
    if (file == null)
    {
        return false;
    }

    buffer[0] = '\0';

    char line[GIT_REPO_LINE_MAX];
    while (!file.EndOfFile() && file.ReadLine(line, sizeof(line)))
    {
        TrimString(line);
        if (line[0] == '\0')
        {
            continue;
        }

        strcopy(buffer, maxlen, line);
    }

    delete file;
    return buffer[0] != '\0';
}

bool ParseReflogTimestamp(const char[] reflogLine, int &timestamp, char[] timezone, int timezoneMax)
{
    char working[GIT_REPO_LINE_MAX];
    strcopy(working, sizeof(working), reflogLine);
    TrimString(working);

    int tabPos = FindCharInString(working, '\t');
    if (tabPos != -1)
    {
        working[tabPos] = '\0';
    }

    int lastSpace = FindLastChar(working, ' ');
    if (lastSpace == -1)
    {
        return false;
    }

    strcopy(timezone, timezoneMax, working[lastSpace + 1]);
    working[lastSpace] = '\0';

    int previousSpace = FindLastChar(working, ' ');
    if (previousSpace == -1)
    {
        return false;
    }

    timestamp = StringToInt(working[previousSpace + 1]);
    return timestamp > 0;
}

void ParseReflogMessage(const char[] reflogLine, char[] commitMessage, int commitMessageMax)
{
    commitMessage[0] = '\0';

    int tabPos = FindCharInString(reflogLine, '\t');
    if (tabPos == -1 || reflogLine[tabPos + 1] == '\0')
    {
        return;
    }

    strcopy(commitMessage, commitMessageMax, reflogLine[tabPos + 1]);
    TrimString(commitMessage);

    int labelPos = StrContains(commitMessage, ": ");
    if (labelPos != -1 && labelPos < 32 && commitMessage[labelPos + 2] != '\0')
    {
        char trimmed[257];
        strcopy(trimmed, sizeof(trimmed), commitMessage[labelPos + 2]);
        strcopy(commitMessage, commitMessageMax, trimmed);
    }
}

void ExtractBranchName(const char[] refPath, char[] branch, int branchMax)
{
    if (refPath[0] == '\0')
    {
        strcopy(branch, branchMax, "detached");
        return;
    }

    int lastSlash = FindLastChar(refPath, '/');
    if (lastSlash == -1 || refPath[lastSlash + 1] == '\0')
    {
        strcopy(branch, branchMax, refPath);
        return;
    }

    strcopy(branch, branchMax, refPath[lastSlash + 1]);
}

void BuildShortCommit(const char[] commitHash, char[] shortHash, int shortHashMax)
{
    int maxCopy = shortHashMax - 1;
    if (maxCopy > 12)
    {
        maxCopy = 12;
    }

    int i = 0;
    while (i < maxCopy && commitHash[i] != '\0')
    {
        shortHash[i] = commitHash[i];
        i++;
    }

    shortHash[i] = '\0';
}

bool LooksLikeGitDirectory(const char[] path)
{
    if (!DirExists(path))
    {
        return false;
    }

    char headPath[PLATFORM_MAX_PATH];
    char refsPath[PLATFORM_MAX_PATH];
    JoinPath(path, "HEAD", headPath, sizeof(headPath));
    JoinPath(path, "refs", refsPath, sizeof(refsPath));
    return FileExists(headPath) && DirExists(refsPath);
}

void DeriveWorkTreeFromGitPath(const char[] gitPath, char[] workTree, int workTreeMax)
{
    char baseName[64];
    GetBaseName(gitPath, baseName, sizeof(baseName));
    if (StrEqual(baseName, ".git"))
    {
        GetParentPath(gitPath, workTree, workTreeMax);
        return;
    }

    workTree[0] = '\0';
}

void JoinPath(const char[] left, const char[] right, char[] output, int outputMax)
{
    if (left[0] == '\0')
    {
        strcopy(output, outputMax, right);
        return;
    }

    if (right[0] == '\0')
    {
        strcopy(output, outputMax, left);
        return;
    }

    int leftLen = strlen(left);
    bool leftHasSeparator = IsPathSeparator(left[leftLen - 1]);
    bool rightHasSeparator = IsPathSeparator(right[0]);

    if (leftHasSeparator && rightHasSeparator)
    {
        FormatEx(output, outputMax, "%s%s", left, right[1]);
    }
    else if (!leftHasSeparator && !rightHasSeparator)
    {
        FormatEx(output, outputMax, "%s/%s", left, right);
    }
    else
    {
        FormatEx(output, outputMax, "%s%s", left, right);
    }
}

void GetParentPath(const char[] path, char[] parent, int parentMax)
{
    char working[PLATFORM_MAX_PATH];
    strcopy(working, sizeof(working), path);
    TrimTrailingSeparators(working);

    int lastSeparator = FindLastPathSeparator(working);
    if (lastSeparator == -1)
    {
        parent[0] = '\0';
        return;
    }

    if (lastSeparator == 0)
    {
        strcopy(parent, parentMax, "/");
        return;
    }

    if (lastSeparator == 2 && working[1] == ':')
    {
        strcopy(parent, parentMax, working);
        parent[3] = '\0';
        return;
    }

    working[lastSeparator] = '\0';
    strcopy(parent, parentMax, working);
}

void GetBaseName(const char[] path, char[] baseName, int baseNameMax)
{
    char working[PLATFORM_MAX_PATH];
    strcopy(working, sizeof(working), path);
    TrimTrailingSeparators(working);

    int lastSeparator = FindLastPathSeparator(working);
    if (lastSeparator == -1)
    {
        strcopy(baseName, baseNameMax, working);
        return;
    }

    strcopy(baseName, baseNameMax, working[lastSeparator + 1]);
}

void TrimTrailingSeparators(char[] path)
{
    int len = strlen(path);
    while (len > 1 && IsPathSeparator(path[len - 1]))
    {
        if (len == 3 && path[1] == ':')
        {
            return;
        }

        path[len - 1] = '\0';
        len--;
    }
}

int FindLastChar(const char[] value, char needle)
{
    for (int i = strlen(value) - 1; i >= 0; i--)
    {
        if (value[i] == needle)
        {
            return i;
        }
    }

    return -1;
}

int FindLastPathSeparator(const char[] value)
{
    for (int i = strlen(value) - 1; i >= 0; i--)
    {
        if (IsPathSeparator(value[i]))
        {
            return i;
        }
    }

    return -1;
}

bool PathIsAbsolute(const char[] path)
{
    if (path[0] == '\0')
    {
        return false;
    }

    if (IsPathSeparator(path[0]))
    {
        return true;
    }

    if (path[1] == '\0' || path[2] == '\0')
    {
        return false;
    }

    return (path[1] == ':' && IsPathSeparator(path[2]));
}

bool IsPathSeparator(char c)
{
    return c == '/' || c == '\\';
}
