#if defined _plugin_statistics_included
    #endinput
#endif
#define _plugin_statistics_included

/**
 * Queues a statistics event for the Rust backend.
 *
 * Runtime, server, map-session, and tickrate fields are added by
 * plugin_statistics.smx. The event name should be a stable snake_case key.
 *
 * @param eventName Stable event identifier.
 * @param message   Optional application-specific payload.
 * @return          True when the event was accepted into the SourceMod queue.
 * @error           Invalid event name or an unavailable provider plugin.
 */
native bool PluginStats_Record(const char[] eventName, const char[] message = "");

/** Returns the provider's latest one-second observed server tickrate. */
native float PluginStats_GetObservedTickrate();

/** Returns the server's expected tickrate derived from GetTickInterval(). */
native float PluginStats_GetExpectedTickrate();

public SharedPlugin __pl_plugin_statistics =
{
    name = "plugin_statistics",
    file = "plugin_statistics.smx",
#if defined REQUIRE_PLUGIN
    required = 1,
#else
    required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_plugin_statistics_SetNTVOptional()
{
    MarkNativeAsOptional("PluginStats_Record");
    MarkNativeAsOptional("PluginStats_GetObservedTickrate");
    MarkNativeAsOptional("PluginStats_GetExpectedTickrate");
}
#endif
