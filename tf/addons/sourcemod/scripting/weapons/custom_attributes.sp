/**
 * Embedded SM-TFCustAttr core.
 *
 * Original implementation by nosoop:
 * https://github.com/nosoop/SM-TFCustAttr
 */
#define TF_CUSTOM_ATTRIBUTES_VERSION "0.5.0"
#define ATTRID_CUSTOM_STORAGE 192 // "referenced item id low"

Handle g_WeaponsCustomAttributesForward;

/**
 * Attribute 192 is copied with an item's runtime attribute list, so it remains
 * the transport for custom-attribute identity. Store a small finite token in
 * it rather than reinterpreting a SourceMod Handle as a float. Handle values
 * are NaNs in float form and can be invalidated or reused while an item still
 * carries the old bits.
 */
#define WEAPONS_CUSTOM_ATTRIBUTE_MAX_TOKEN 16000000

StringMap g_WeaponsCustomAttributeKVs;
int g_WeaponsCustomAttributeNextToken = 1;

void WeaponsCustomAttributes_RegisterNatives() {
	RegPluginLibrary("tf2custattr");

	CreateNative("TF2CustAttr_GetAttributeKeyValues", WeaponsCustomAttributes_NativeGetKeyValues);
	CreateNative("TF2CustAttr_UseKeyValues", WeaponsCustomAttributes_NativeUseKeyValues);

	CreateNative("TF2CustAttr_GetInt", WeaponsCustomAttributes_NativeGetInt);
	CreateNative("TF2CustAttr_GetFloat", WeaponsCustomAttributes_NativeGetFloat);
	CreateNative("TF2CustAttr_GetString", WeaponsCustomAttributes_NativeGetString);

	CreateNative("TF2CustAttr_SetInt", WeaponsCustomAttributes_NativeSetInt);
	CreateNative("TF2CustAttr_SetFloat", WeaponsCustomAttributes_NativeSetFloat);
	CreateNative("TF2CustAttr_SetString", WeaponsCustomAttributes_NativeSetString);
}

void WeaponsCustomAttributes_OnPluginStart() {
	g_WeaponsCustomAttributesForward = CreateGlobalForward("TF2CustAttr_OnKeyValuesAdded",
			ET_Event, Param_Cell, Param_Cell);

	g_WeaponsCustomAttributeKVs = new StringMap();

	ConVar version = CreateConVar("tf2custattr_version", TF_CUSTOM_ATTRIBUTES_VERSION, .flags = FCVAR_NOTIFY);
	version.SetString(TF_CUSTOM_ATTRIBUTES_VERSION);
}

/**
 * Remove custom attribute references on existing attributes.
 */
void WeaponsCustomAttributes_OnPluginEnd() {
	int entity = -1;
	while ((entity = FindEntityByClassname(entity, "*")) != -1) {
		if (!HasEntProp(entity, Prop_Send, "m_AttributeList")) {
			continue;
		}

		Address pAttrib = TF2Attrib_GetByDefIndex(entity, ATTRID_CUSTOM_STORAGE);
		if (pAttrib) {
			TF2Attrib_RemoveByDefIndex(entity, ATTRID_CUSTOM_STORAGE);
		}
	}
	WeaponsCustomAttributes_Erase();
	delete g_WeaponsCustomAttributeKVs;
	delete g_WeaponsCustomAttributesForward;
}

/**
 * Schedule a garbage collection routine.
 */
void WeaponsCustomAttributes_OnMapStart() {
	CreateTimer(60.0, WeaponsCustomAttributes_GarbageCollect, .flags = TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

void WeaponsCustomAttributes_OnMapEnd() {
	WeaponsCustomAttributes_Erase();
	g_WeaponsCustomAttributeNextToken = 1;
}

void WeaponsCustomAttributes_OnEntityCreated(int entity) {
	if (HasEntProp(entity, Prop_Send, "m_AttributeList")) {
		SDKHook(entity, SDKHook_SpawnPost, WeaponsCustomAttributes_OnItemSpawnPost);
	}
}

/**
 * An entity has been spawned.  Check if any custom attributes should be added.
 * If no custom attributes are present on an entity after the forward, the KeyValues handle is
 * cleaned up.
 */
public void WeaponsCustomAttributes_OnItemSpawnPost(int entity) {
	if (!WeaponsCustomAttributes_GetStruct(entity, .validate = true)) {
		KeyValues customAttributes = new KeyValues("CustomAttributes");

		Action result;

		Call_StartForward(g_WeaponsCustomAttributesForward);
		Call_PushCell(entity);
		Call_PushCell(customAttributes);
		Call_Finish(result);

		if (result > Plugin_Continue) {
			WeaponsCustomAttributes_SetStruct(entity, customAttributes);
		} else {
			delete customAttributes;
		}
	}
}

/**
 * Garbage collection routine.  Scans all items and checks against its local list to see which
 * handles are unused and can be deleted.
 *
 * We can't just keep a reference to entities because dropped weapons exist, invalidating those
 * references but still keeping the KV handle accessible.
 */
public Action WeaponsCustomAttributes_GarbageCollect(Handle timer) {
	StringMapSnapshot attributeTokens = g_WeaponsCustomAttributeKVs.Snapshot();
	if (!attributeTokens.Length) {
		delete attributeTokens;
		return Plugin_Continue;
	}

	StringMap referencedTokens = new StringMap();
	int entity = -1;
	while ((entity = FindEntityByClassname(entity, "*")) != -1) {
		if (!HasEntProp(entity, Prop_Send, "m_AttributeList")) {
			continue;
		}

		int token = WeaponsCustomAttributes_GetToken(entity);
		if (token > 0) {
			char tokenKey[16];
			IntToString(token, tokenKey, sizeof(tokenKey));
			if (g_WeaponsCustomAttributeKVs.ContainsKey(tokenKey)) {
				referencedTokens.SetValue(tokenKey, true);
			}
		}
	}

	for (int i = 0; i < attributeTokens.Length; i++) {
		char tokenKey[16];
		attributeTokens.GetKey(i, tokenKey, sizeof(tokenKey));
		if (referencedTokens.ContainsKey(tokenKey)) {
			continue;
		}

		KeyValues kv;
		if (g_WeaponsCustomAttributeKVs.GetValue(tokenKey, kv) && IsValidHandle(kv)) {
			delete kv;
		}
		g_WeaponsCustomAttributeKVs.Remove(tokenKey);
	}
	delete referencedTokens;
	delete attributeTokens;

	return Plugin_Continue;
}

int WeaponsCustomAttributes_GetToken(int entity) {
	Address pCustomAttr = TF2Attrib_GetByDefIndex(entity, ATTRID_CUSTOM_STORAGE);
	if (pCustomAttr == Address_Null) {
		return 0;
	}

	float storedValue = TF2Attrib_GetValue(pCustomAttr);
	int storedBits = view_as<int>(storedValue);
	if ((storedBits & 0x7F800000) == 0x7F800000) {
		return 0;
	}

	int token = RoundToNearest(storedValue);
	if (token <= 0 || token > WEAPONS_CUSTOM_ATTRIBUTE_MAX_TOKEN
			|| FloatAbs(storedValue - float(token)) > 0.001) {
		return 0;
	}
	return token;
}

/**
 * Returns the KeyValues handle associated with an entity, if one exists.
 */
KeyValues WeaponsCustomAttributes_GetStruct(int entity, bool validate) {
	int token = WeaponsCustomAttributes_GetToken(entity);
	if (token <= 0) {
		if (validate && TF2Attrib_GetByDefIndex(entity, ATTRID_CUSTOM_STORAGE)) {
			TF2Attrib_RemoveByDefIndex(entity, ATTRID_CUSTOM_STORAGE);
		}
		return null;
	}

	char tokenKey[16];
	IntToString(token, tokenKey, sizeof(tokenKey));

	KeyValues kv;
	if (g_WeaponsCustomAttributeKVs.GetValue(tokenKey, kv) && (!validate || IsValidHandle(kv))) {
		return kv;
	}

	if (validate && TF2Attrib_GetByDefIndex(entity, ATTRID_CUSTOM_STORAGE)) {
		TF2Attrib_RemoveByDefIndex(entity, ATTRID_CUSTOM_STORAGE);
	}
	return null;
}

KeyValues TF2CustAttr_GetAttributeKeyValues(int entity) {
	KeyValues result = WeaponsCustomAttributes_GetStruct(entity, .validate = true);
	return result == null
		? null
		: WeaponsCustomAttributes_CopyKeyValues(result, "CustomAttributes");
}

bool TF2CustAttr_UseKeyValues(int entity, KeyValues kv) {
	if (kv == null || !HasEntProp(entity, Prop_Send, "m_AttributeList")) {
		return false;
	}

	KeyValues customAttributes = WeaponsCustomAttributes_CopyKeyValues(kv, "CustomAttributes");
	WeaponsCustomAttributes_SweepEmptyKeys(customAttributes);
	WeaponsCustomAttributes_SetStruct(entity, customAttributes);
	return true;
}

int TF2CustAttr_GetInt(int entity, const char[] attr, int defaultValue = 0) {
	KeyValues kv = WeaponsCustomAttributes_GetStruct(entity, .validate = true);
	return kv == null ? defaultValue : kv.GetNum(attr, defaultValue);
}

float TF2CustAttr_GetFloat(int entity, const char[] attr, float defaultValue = 0.0) {
	KeyValues kv = WeaponsCustomAttributes_GetStruct(entity, .validate = true);
	return kv == null ? defaultValue : kv.GetFloat(attr, defaultValue);
}

int TF2CustAttr_GetString(int entity, const char[] attr, char[] buffer, int maxlen,
		const char[] defaultValue = "") {
	KeyValues kv = WeaponsCustomAttributes_GetStruct(entity, .validate = true);
	if (kv == null) {
		return strcopy(buffer, maxlen, defaultValue);
	}

	kv.GetString(attr, buffer, maxlen, defaultValue);
	return strlen(buffer);
}

void TF2CustAttr_SetInt(int entity, const char[] attr, int value) {
	KeyValues kv = WeaponsCustomAttributes_InitStruct(entity);
	if (kv != null) {
		kv.SetNum(attr, value);
	}
}

void TF2CustAttr_SetFloat(int entity, const char[] attr, float value) {
	KeyValues kv = WeaponsCustomAttributes_InitStruct(entity);
	if (kv != null) {
		kv.SetFloat(attr, value);
	}
}

void TF2CustAttr_SetString(int entity, const char[] attr, const char[] value) {
	KeyValues kv = WeaponsCustomAttributes_InitStruct(entity);
	if (kv != null) {
		kv.SetString(attr, value);
	}
}

public int WeaponsCustomAttributes_NativeGetKeyValues(Handle caller, int argc) {
	int entity = GetNativeCell(1);
	KeyValues result = TF2CustAttr_GetAttributeKeyValues(entity);
	if (result) {
		return WeaponsCustomAttributes_MoveHandle(result, caller);
	}
	return 0;
}

public int WeaponsCustomAttributes_NativeUseKeyValues(Handle caller, int argc) {
	int entity = GetNativeCell(1);
	KeyValues kv = GetNativeCell(2);
	return TF2CustAttr_UseKeyValues(entity, kv);
}

public int WeaponsCustomAttributes_NativeGetInt(Handle caller, int argc) {
	int entity = GetNativeCell(1);
	char attr[64];
	GetNativeString(2, attr, sizeof(attr));
	return TF2CustAttr_GetInt(entity, attr, GetNativeCell(3));
}

public int WeaponsCustomAttributes_NativeGetFloat(Handle caller, int argc) {
	int entity = GetNativeCell(1);
	char attr[64];
	GetNativeString(2, attr, sizeof(attr));
	return view_as<int>(TF2CustAttr_GetFloat(entity, attr, GetNativeCell(3)));
}

public int WeaponsCustomAttributes_NativeGetString(Handle caller, int argc) {
	int entity = GetNativeCell(1);

	int maxlen = GetNativeCell(4);
	char[] outputBuffer = new char[maxlen];

	int nBytesWritten;
	GetNativeString(5, outputBuffer, maxlen, nBytesWritten);

	char attr[64];
	GetNativeString(2, attr, sizeof(attr));
	TF2CustAttr_GetString(entity, attr, outputBuffer, maxlen, outputBuffer);
	SetNativeString(3, outputBuffer, maxlen, true, nBytesWritten);
	return nBytesWritten;
}

public int WeaponsCustomAttributes_NativeSetInt(Handle caller, int argc) {
	int entity = GetNativeCell(1);
	if (!HasEntProp(entity, Prop_Send, "m_AttributeList")) {
		ThrowNativeError(1, "Entity %d does not support attributes", entity);
	}

	char attr[64];
	GetNativeString(2, attr, sizeof(attr));

	TF2CustAttr_SetInt(entity, attr, GetNativeCell(3));
	return 0;
}

public int WeaponsCustomAttributes_NativeSetFloat(Handle caller, int argc) {
	int entity = GetNativeCell(1);
	if (!HasEntProp(entity, Prop_Send, "m_AttributeList")) {
		ThrowNativeError(1, "Entity %d does not support attributes", entity);
	}

	char attr[64];
	GetNativeString(2, attr, sizeof(attr));

	TF2CustAttr_SetFloat(entity, attr, GetNativeCell(3));
	return 0;
}

public int WeaponsCustomAttributes_NativeSetString(Handle caller, int argc) {
	int entity = GetNativeCell(1);
	if (!HasEntProp(entity, Prop_Send, "m_AttributeList")) {
		ThrowNativeError(1, "Entity %d does not support attributes", entity);
	}

	char attr[64];
	GetNativeString(2, attr, sizeof(attr));

	int len;
	GetNativeStringLength(3, len);
	char[] buf = new char[++len];
	GetNativeString(3, buf, len);

	TF2CustAttr_SetString(entity, attr, buf);
	return 0;
}

/**
 * Returns a clone of a handle with a new owner, deleting the existing one in the process.
 *
 * This function is used for cases where the `hndl` argument is the return value of another
 * function call, in which case attempting to use `MoveHandle` results in an argument type
 * mismatch compile error.
 *
 * The return type is `any` to allow assignment without retagging.
 */
stock any WeaponsCustomAttributes_MoveHandle(Handle hndl, Handle plugin = INVALID_HANDLE) {
	Handle moved = CloneHandle(hndl, plugin);
	CloseHandle(hndl);
	return moved;
}

/**
 * Returns a new KeyValues handle containing the contents of the given KeyValues handle at its
 * current position.
 */
KeyValues WeaponsCustomAttributes_CopyKeyValues(KeyValues kv, const char[] section = "") {
	KeyValues copy = new KeyValues(section);
	copy.Import(kv);
	return copy;
}

/**
 * Returns the KeyValues handle assigned to the given entity, creating one if it doesn't exist.
 * Returns `null` if the entity does not support attributes.
 */
KeyValues WeaponsCustomAttributes_InitStruct(int entity) {
	if (!HasEntProp(entity, Prop_Send, "m_AttributeList")) {
		return null;
	}

	KeyValues kv = WeaponsCustomAttributes_GetStruct(entity, .validate = true);
	if (!kv) {
		kv = new KeyValues("CustomAttributes");
		WeaponsCustomAttributes_SetStruct(entity, kv);
	}
	return kv;
}

/**
 * Stores the given KeyValues handle into the entity.
 */
void WeaponsCustomAttributes_SetStruct(int entity, KeyValues kv) {
	int token = WeaponsCustomAttributes_AllocateToken();
	char tokenKey[16];
	IntToString(token, tokenKey, sizeof(tokenKey));
	g_WeaponsCustomAttributeKVs.SetValue(tokenKey, kv);
	TF2Attrib_SetByDefIndex(entity, ATTRID_CUSTOM_STORAGE, float(token));
}

int WeaponsCustomAttributes_AllocateToken() {
	for (int attempt = 0; attempt < WEAPONS_CUSTOM_ATTRIBUTE_MAX_TOKEN; attempt++) {
		int token = g_WeaponsCustomAttributeNextToken++;
		if (g_WeaponsCustomAttributeNextToken > WEAPONS_CUSTOM_ATTRIBUTE_MAX_TOKEN) {
			g_WeaponsCustomAttributeNextToken = 1;
		}

		char tokenKey[16];
		IntToString(token, tokenKey, sizeof(tokenKey));
		if (!g_WeaponsCustomAttributeKVs.ContainsKey(tokenKey)) {
			return token;
		}
	}

	ThrowError("Custom attribute token space exhausted");
	return 0;
}

stock void WeaponsCustomAttributes_SweepEmptyKeys(KeyValues kv) {
	kv.GotoFirstSubKey(false);
	bool bNext;
	do {
		if (kv.GetDataType(NULL_STRING) == KvData_None) {
			bNext = kv.GotoNextKey(false);
			continue;
		}
		// plain key / value pair
		char value[4];
		kv.GetString(NULL_STRING, value, sizeof(value));
		bNext = !value[0]? kv.DeleteThis() == 1 : kv.GotoNextKey(false);
	} while (bNext);
	kv.GoBack();
}

/**
 * Disposes all KeyValues handles and empties the token registry.
 */
void WeaponsCustomAttributes_Erase() {
	StringMapSnapshot attributeTokens = g_WeaponsCustomAttributeKVs.Snapshot();
	for (int i = 0; i < attributeTokens.Length; i++) {
		char tokenKey[16];
		attributeTokens.GetKey(i, tokenKey, sizeof(tokenKey));

		KeyValues kv;
		if (g_WeaponsCustomAttributeKVs.GetValue(tokenKey, kv) && IsValidHandle(kv)) {
			delete kv;
		}
	}
	delete attributeTokens;
	g_WeaponsCustomAttributeKVs.Clear();
}
