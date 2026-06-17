#if defined _tf2_sentry_newtarget_dist_included
    #endinput
#endif
#define _tf2_sentry_newtarget_dist_included

/**
 * This is a native SourceMod extension, not a SourcePawn plugin library.
 */
public Extension __ext_tf2_sentry_newtarget_dist =
{
    name = "tf2_sentry_newtarget_dist",
    file = "tf2_sentry_newtarget_dist.ext",
    autoload = 1,
    required = 1,
};

/**
 * Enables/disables the native helper extension. The SourcePawn plugin owns the
 * gameplay loop; this is stored by the extension for diagnostics/future use.
 */
native void TF2SentryNewTarget_SetEnabled(bool enabled);

/**
 * Sets the configured distance threshold in Hammer Units. The SourcePawn plugin
 * owns the gameplay loop; this is stored by the extension for diagnostics/future use.
 */
native void TF2SentryNewTarget_SetDistance(float distance);

/**
 * Calls CObjectSentrygun::FoundTarget on a sentry.
 *
 * sentry:
 *   Entity index/ref of obj_sentrygun.
 *
 * target:
 *   Entity index/ref of the target entity.
 *
 * soundCenter:
 *   Usually the sentry eye position. Stock FindTarget() passes vecSentryOrigin.
 *
 * noSound:
 *   true to suppress the acquisition sound.
 */
native void TF2SentryNewTarget_FoundTarget(int sentry, int target, const float soundCenter[3], bool noSound = false);
