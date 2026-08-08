# Kogasatopia
The repository for everyone's favorite TF2 server. Visit Kogasatopia's website here: [kogasa.tf](https://kogasa.tf)

These plugins are very specific and are shared for the sake of letting anyone look at them. The major plugins are as follows:
- weaponreverts.sp for weapon attribute changes, custom attributes and nerf reverts
- cwx by nosoop with some local changes such as a descriptions feature
- mapsdb, a plugin that handles per-gamemode setting configurations, map popularity statistics and once-only server configs for better load times between maps
- dgm.sp for instant respawn configuration and gamemode tweaks
- gameplay_rewards.sp for Points Store rewards emitted by gameplay APIs; airshot announcements are integrated into WhaleTracker
- saysounds.sp as an implementation of the saysounds concept with many features
- announcers.sp for gameplay announcers such as Unreal Tournament killstreak trackers
- clans.sp for a Minecraft factions style plugin in tf2 along with tags.sp for a chat tags system
- custom_hats.sp for custom hats
- autobalance_4teams and whalescramble for autobalancing and scrambling inspired by gScramble
- hugs.sp
- filters.sp, a large plugin that handles chat such as the tags feature, a web frontend connection and word filters
- points_store.sp, a currency system and lottery with an API

Not everything in this repo was created by Kogasatopia, credits are given when possible. This repository also contains config files, tooling and Sourcemod extensions. Many plugins found in the repository not by us have small tweaks or attempts at bug fixes, such as adding command aliases for quality of life.

This server implements the Amplifier concept from community Saxton Hale servers, see the repository at https://github.com/eltanschauung/Amplifier-Fork<br>
This server has a heavily tweaked version of Nativevotes along with a system called mapeval that assigns vote weights to certain clients and maps, see https://github.com/eltanschauung/Nativevotes-Colorful<br>
We have an ambitious stats tracker plugin and frontend, see https://github.com/eltanschauung/Whaletracker<br>

The counterpart frontend repository can be found here, containing the site's blog and WhaleTracker's frontend: https://github.com/eltanschauung/Kogasatopia-Frontend<br>
