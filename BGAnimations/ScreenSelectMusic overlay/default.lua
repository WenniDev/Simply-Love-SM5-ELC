-- Returns the list of group names allowed in Casual mode, read from CasualMode-Groups.txt.
-- Falls back to all groups if the file is missing or empty.
local GetCasualGroups = function()
	local path = THEME:GetCurrentThemeDirectory() .. "Other/CasualMode-Groups.txt"
	local groups = {}

	if FILEMAN:DoesFileExist(path) then
		local file = RageFileUtil.CreateRageFile()
		if file:Open(path, 1) then
			local contents = file:Read()
			file:Close()
			for line in contents:gmatch("[^\r\n]+") do
				if SONGMAN:DoesSongGroupExist(line) then
					groups[#groups+1] = line
				end
			end
		end
		file:destroy()
	end

	if #groups == 0 then
		return SONGMAN:GetSongGroupNames()
	end
	return groups
end

-- Extracts "GroupName/SongDir" path from a song object, matching the format
-- expected by SONGMAN:SetPreferredSongs().
local GetSongPath = function(song)
	local dir = song:GetSongDir():gsub("/$", "")
	return song:GetGroupName() .. "/" .. (dir:match("[^/]+$") or "")
end

-- Builds a preferred-songs file containing only Casual-valid songs (groups from
-- CasualMode-Groups.txt, with at least one chart ≤ CasualMaxMeter), then
-- switches the music wheel to SortOrder_Preferred so only those songs appear.
-- Songs are grouped by pack using "---GroupName" section headers so the wheel
-- preserves the folder structure.
local ApplyCasualGroupFilter = function(screen)
	local stepsType   = GAMESTATE:GetCurrentStyle():GetStepsType()
	local maxMeter    = ThemePrefs.Get("CasualMaxMeter")
	local longVerSecs = PREFSMAN:GetPreference("LongVerSongSeconds")
	local content     = ""
	local totalSongs  = 0

	for group in ivalues(GetCasualGroups()) do
		local groupContent = ""
		for song in ivalues(SONGMAN:GetSongsInGroup(group)) do
			if song:HasStepsType(stepsType)
			and song:GetLastSecond() < longVerSecs
			and UNLOCKMAN:IsSongLocked(song) == 0
			then
				for steps in ivalues(song:GetStepsByStepsType(stepsType)) do
					if steps:GetMeter() <= maxMeter then
						groupContent = groupContent .. GetSongPath(song) .. "\n"
						totalSongs   = totalSongs + 1
						break
					end
				end
			end
		end
		if #groupContent > 0 then
			content = content .. "---" .. group .. "\n" .. groupContent
		end
	end

	if totalSongs == 0 then return end

	local path = THEME:GetCurrentThemeDirectory() .. "Other/_CasualFilter.txt"
	local file = RageFileUtil.CreateRageFile()
	if file:Open(path, 2) then
		file:Write(content)
		file:Close()
	end
	file:destroy()

	SONGMAN:SetPreferredSongs(path, true)
	if SONGMAN:GetPreferredSortSongs() then
		screen:GetMusicWheel():ChangeSort("SortOrder_Preferred")
	end
end

local ResetModsInput = function(event)
	if event.type == "InputEventType_Release" then return false end
	if event.GameButton ~= "EffectUp" then return false end
	local player = event.PlayerNumber
	if player and GAMESTATE:IsSideJoined(player) then
		ResetPlayerMods(player)
		local pn = player == PLAYER_1 and "1" or "2"
        SCREENMAN:SystemMessage("P"..pn.." mods reset")
end
	return false
end

local ClampCasualDifficulty = function(player)
	if SL.Global.GameMode ~= "Casual" then return end
	local song = GAMESTATE:GetCurrentSong()
	if not song then return end
	local current = GAMESTATE:GetCurrentSteps(player)
	if not current then return end
	local maxMeter = ThemePrefs.Get("CasualMaxMeter")
	if current:GetMeter() <= maxMeter then return end
	local bestSteps = nil
	for _, s in ipairs(SongUtil.GetPlayableSteps(song)) do
		if s:GetMeter() <= maxMeter then
			if bestSteps == nil or s:GetMeter() > bestSteps:GetMeter() then
				bestSteps = s
			end
		end
	end
	if bestSteps then
		GAMESTATE:SetCurrentSteps(player, bestSteps)
	end
end

local af = Def.ActorFrame{
	-- GameplayReloadCheck is a kludgy global variable used in ScreenGameplay in.lua to check
	-- if ScreenGameplay is being entered "properly" or being reloaded by a scripted mod-chart.
	-- If we're here in SelectMusic, set GameplayReloadCheck to false, signifying that the next
	-- time ScreenGameplay loads, it should have a properly animated entrance.
	OnCommand=function(self)
		SCREENMAN:GetTopScreen():AddInputCallback(ResetModsInput)
		-- Apply Casual group/difficulty filter immediately if entering in Casual mode.
		if SL.Global.GameMode == "Casual" then
			ApplyCasualGroupFilter(SCREENMAN:GetTopScreen())
		end
	end,
	-- Re-apply or remove the filter whenever the player switches game mode.
	SLGameModeChangedMessageCommand=function(self)
		local screen = SCREENMAN:GetTopScreen()
		if SL.Global.GameMode == "Casual" then
			ApplyCasualGroupFilter(screen)
		else
			screen:GetMusicWheel():ChangeSort("SortOrder_Group")
		end
	end,
	InitCommand=function(self)
		SL.Global.GameplayReloadCheck = false
		generateFavoritesForMusicWheel()
		
		-- reset song start time here in case player force-escaped
		start_time = -1

		-- While other SM versions don't need this, Outfox resets the
		-- the music rate to 1 between songs, but we want to be using
		-- the preselected music rate.
		local songOptions = GAMESTATE:GetSongOptionsObject("ModsLevel_Preferred")
		songOptions:MusicRate(SL.Global.ActiveModifiers.MusicRate)
	end,

	PlayerProfileSetMessageCommand=function(self, params)
		if not PROFILEMAN:IsPersistentProfile(params.Player) then
			LoadGuest(params.Player)
		end
		generateFavoritesForMusicWheel()
		ApplyMods(params.Player)
	end,

	PlayerJoinedMessageCommand=function(self, params)
		if not PROFILEMAN:IsPersistentProfile(params.Player) then
			LoadGuest(params.Player)
		end
		ApplyMods(params.Player)
	end,
	CodeMessageCommand=function(self, params)
		if params.Name == "Favorite1" or params.Name == "Favorite2" then
			addOrRemoveFavorite(params.PlayerNumber)
		elseif params.Name == "EscapeFromEventMode" then
			SCREENMAN:GetTopScreen():Cancel()
		end
	end,
	CurrentStepsP1ChangedMessageCommand=function(self) ClampCasualDifficulty(PLAYER_1) end,
	CurrentStepsP2ChangedMessageCommand=function(self) ClampCasualDifficulty(PLAYER_2) end,

	ReloadScreenForMemoryCardsMessageCommand=function(self, params)
		-- Wait some time for the profile screen to finish transitioning
		-- before reloading the screen.
		self:sleep(0.10):queuecommand("Reload")
	end,
	ReloadCommand=function(self)
		SCREENMAN:GetTopScreen():SetNextScreenName("ScreenReloadSSM")
		SCREENMAN:GetTopScreen():StartTransitioningScreen("SM_GoToNextScreen")
	end,
	-- ---------------------------------------------------
	--  first, load files that contain no visual elements, just code that needs to run

	-- MenuTimer code for preserving SSM's timer value when going
	-- from SSM to a different screen and back to SSM (i.e. returning from PlayerOptions).
	LoadActor("./PreserveMenuTimer.lua"),
	-- Apply player modifiers from profile
	LoadActor("./PlayerModifiers.lua"),

	-- ---------------------------------------------------
	-- next, load visual elements; the order of these matters
	-- i.e. content in PerPlayer/Over needs to draw on top of content from PerPlayer/Under

	-- make the MusicWheel appear to cascade down; this should draw underneath P2's PaneDisplay
	LoadActor("./MusicWheelAnimation.lua"),

	-- number of steps, jumps, holds, etc., and high scores associated with the current stepchart
	LoadActor("./PaneDisplay.lua"),

	-- elements we need two of (one for each player) that draw underneath the StepsDisplayList
	-- this includes the stepartist boxes, the density graph, and the cursors.
	LoadActor("./PerPlayer/default.lua"),
	-- The grid for the difficulty picker (normal) or CourseContentsList (CourseMode)
	LoadActor("./StepsDisplayList/default.lua"),

	-- Song's Musical Artist, BPM, Duration
	LoadActor("./SongDescription/SongDescription.lua"),

	-- Banner Art
	LoadActor("./Banner.lua"),

	-- ---------------------------------------------------
	-- finally, load the overlay used for sorting the MusicWheel (and more), hidden by default
	LoadActor("./SortMenu/default.lua"),
	-- a Test Input overlay can (maybe) be accessed from the SortMenu
	LoadActor("./TestInput.lua"),

	-- The GrooveStats leaderboard that can (maybe) be accessed from the SortMenu
	-- This is only added in "dance" mode and if the service is available.
	LoadActor("./Leaderboard.lua"),

	LoadActor("./SongSearch/default.lua"),

}

return af
