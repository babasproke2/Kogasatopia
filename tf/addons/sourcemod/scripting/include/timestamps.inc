#if defined _kogasa_timestamps_helper_included
    #endinput
#endif
#define _kogasa_timestamps_helper_included

// Statistics tables store Unix epoch seconds from GetTime().
stock void Timestamps_GetWeekdayHour(int timestamp, int &weekday, int &hourOfDay)
{
    char buffer[8];
    FormatTime(buffer, sizeof(buffer), "%w", timestamp);
    weekday = StringToInt(buffer);
    FormatTime(buffer, sizeof(buffer), "%H", timestamp);
    hourOfDay = StringToInt(buffer);
}
