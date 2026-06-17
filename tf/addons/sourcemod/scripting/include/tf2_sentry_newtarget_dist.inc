#if defined _tf2_sentry_newtarget_dist_included
    #endinput
#endif
#define _tf2_sentry_newtarget_dist_included

/**
 * Native extension backing [TF2] Sentry NewTarget Distance.
 */
public Extension __ext_tf2_sentry_newtarget_dist =
{
    name = "tf2_sentry_newtarget_dist",
    file = "tf2_sentry_newtarget_dist.ext",
    autoload = 1,
    required = 1,
};

/**
 * Enables or disables the native FindTarget() range override.
 */
native void TF2SentryNewTarget_SetEnabled(bool enabled);

/**
 * Sets the target acquisition range in Hammer Units.
 * Applies to both normal sentries and mini-sentries.
 */
native void TF2SentryNewTarget_SetDistance(float distance);

/**
 * Returns the resolved raw offset of CObjectSentrygun::m_flSentryRange,
 * or -1 if unavailable. Intended for diagnostics only.
 */
native int TF2SentryNewTarget_GetRangeOffset();
