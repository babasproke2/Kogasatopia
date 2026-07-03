/**
* Roller class defines clients who interact with the plugin.
* Copyright (C) 2023 Filip Tomaszewski
*
* This program is free software: you can redistribute it and/or modify
* it under the terms of the GNU General Public License as published by
* the Free Software Foundation, either version 3 of the License, or
* (at your option) any later version.
*
* This program is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
* GNU General Public License for more details.
*
* You should have received a copy of the GNU General Public License
* along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

methodmap Rollers < ArrayList
{
	public Rollers()
	{
		ArrayList data = new ArrayList(8, MAXPLAYERS + 1);

		for (int i = 1; i <= MaxClients; ++i)
			for (int block = 0; block <= 6; ++block)
				data.Set(i, 0, block); // init to false/0/null

		return view_as<Rollers>(data);
	}

	public bool GetInRoll(int client)
	{
		return view_as<bool>(this.Get(client, 0));
	}

	public void SetInRoll(int client, bool val)
	{
		this.Set(client, val, 0);
	}

	public int GetLastRollTime(int client)
	{
		return view_as<int>(this.Get(client, 1));
	}

	public void SetLastRollTime(int client, int val)
	{
		this.Set(client, val, 1);
	}

	public int GetEndRollTime(int client)
	{
		return view_as<int>(this.Get(client, 2));
	}

	public void SetEndRollTime(int client, int val)
	{
		this.Set(client, val, 2);
	}

	public PerkList GetPerkHistory(int client)
	{
		return view_as<PerkList>(this.Get(client, 3));
	}

	public void SetPerkHistory(int client, PerkList val)
	{
		this.Set(client, val, 3);
	}

	public Perk GetPerk(int client)
	{
		return view_as<Perk>(this.Get(client, 4));
	}

	public void SetPerk(int client, Perk val)
	{
		this.Set(client, val, 4);
	}

	public Handle GetTimer(int client)
	{
		return view_as<Handle>(this.Get(client, 5));
	}

	public void SetTimer(int client, Handle val)
	{
		this.Set(client, val, 5);
	}

	public Handle GetHud(int client)
	{
		return view_as<Handle>(this.Get(client, 6));
	}

	public void SetHud(int client, Handle val)
	{
		this.Set(client, val, 6);
	}

	public int GetUnconsumedAddedTime(int client)
	{
		return view_as<int>(this.Get(client, 7));
	}

	public void SetUnconsumedAddedTime(int client, int val)
	{
		this.Set(client, val, 7);
	}

	public void AddRollTime(const int client, const int iTime)
	{
		this.SetEndRollTime(client, this.GetEndRollTime(client) + iTime);
		this.SetUnconsumedAddedTime(client, this.GetUnconsumedAddedTime(client) + iTime);
	}

	public int PushToPerkHistory(const int client, Perk perk)
	{
		PerkList list = this.GetPerkHistory(client);
		if (!list)
		{
			list = new PerkList();
			this.SetPerkHistory(client, list);
		}

		return list.Push(perk);
	}

	public bool IsInPerkHistory(const int client, Perk perk, int iLimit)
	{
		PerkList list = this.GetPerkHistory(client);
		if (!list)
			return false;

		int i = list.Length;
		if (i < iLimit)
			return false;

		iLimit = i -iLimit;
		while (--i >= iLimit)
			if (list.Get(i) == perk)
				return true;

		return false;
	}

	public void ResetPerkHistory(const int client)
	{
		PerkList list = this.GetPerkHistory(client);
		if (list)
			list.Clear();
	}

	public void Reset(const int client)
	{
		this.SetInRoll(client, false);
		this.SetLastRollTime(client, 0);
		this.SetPerk(client, null);
		this.ResetPerkHistory(client);
	}

	public void ResetPerkHisories()
	{
		for (int i = 1; i <= MaxClients; ++i)
			this.ResetPerkHistory(i);
	}
}
