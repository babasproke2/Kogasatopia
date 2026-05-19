#if defined _conch_no_speed_included
	#endinput
#endif
#define _conch_no_speed_included

native void TF2ConchNoSpeed_AddRegenBuff(int client, float duration, int provider = 0);
native void TF2ConchNoSpeed_RemoveRegenBuff(int client);
native bool TF2ConchNoSpeed_IsRegenBuffActive(int client);

public Extension __ext_conch_no_speed =
{
	name = "Conch No Speed",
	file = "conch_no_speed.ext.2.tf2",
	autoload = 1,
#if defined REQUIRE_EXTENSIONS
	required = 1,
#else
	required = 0,
#endif
};

#if !defined REQUIRE_EXTENSIONS
public void __ext_conch_no_speed_SetNTVOptional()
{
	MarkNativeAsOptional("TF2ConchNoSpeed_AddRegenBuff");
	MarkNativeAsOptional("TF2ConchNoSpeed_RemoveRegenBuff");
	MarkNativeAsOptional("TF2ConchNoSpeed_IsRegenBuffActive");
}
#endif
