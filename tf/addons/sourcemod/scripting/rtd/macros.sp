#if defined _RTD2_MACROS
  #endinput
#endif
#define _RTD2_MACROS

#define KILL_ENT_IN(%1,%2) \
	SetVariantString("OnUser1 !self:Kill::" ... #%2 ... ":1"); \
	AcceptEntityInput(%1, "AddOutput"); \
	AcceptEntityInput(%1, "FireUser1") // no semicolor, require it's added on caller

