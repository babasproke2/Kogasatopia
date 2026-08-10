#if defined _kogasa_tf2_classes_helper_included
    #endinput
#endif
#define _kogasa_tf2_classes_helper_included

#include <tf2>

stock bool TF2Classes_GetKey(TFClassType playerClass, char[] buffer, int maxlen, const char[] fallback = "")
{
    switch (playerClass)
    {
        case TFClass_Scout:     strcopy(buffer, maxlen, "scout");
        case TFClass_Soldier:   strcopy(buffer, maxlen, "soldier");
        case TFClass_Pyro:      strcopy(buffer, maxlen, "pyro");
        case TFClass_DemoMan:   strcopy(buffer, maxlen, "demoman");
        case TFClass_Heavy:     strcopy(buffer, maxlen, "heavy");
        case TFClass_Engineer:  strcopy(buffer, maxlen, "engineer");
        case TFClass_Medic:     strcopy(buffer, maxlen, "medic");
        case TFClass_Sniper:    strcopy(buffer, maxlen, "sniper");
        case TFClass_Spy:       strcopy(buffer, maxlen, "spy");
        default:
        {
            strcopy(buffer, maxlen, fallback);
            return false;
        }
    }

    return true;
}
