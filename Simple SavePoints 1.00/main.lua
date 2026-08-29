-- name: \\#00FF7F\\Simple SavePoints v1.00b\\#00FF7F\\
-- description: Host-managed multiplayer savepoints. Each connected player has an independent savepoint.\n\nDpad Down while stationary: create your savepoint.\nL Trigger + Dpad Down: load your savepoint.\n\nThe host persists each player's savepoint separately in mod_storage.\n\nMade by \\#674ea7\\Toxikskull\\#674ea7\\ \\#ffffff\\&\\#ffffff\\ \\#f8c62d\\GazzyGaz\\#f8c62d\\.
-- Written and bug tested by Toxikskull & GazzyGaz.
 
local keepCoins, fullHP, keepObjects = false, false, true
local DEFAULT_HP, WARP_FALLBACK, LOAD_TIMEOUT, LOAD_RETRIES = 2176, 180, 20, 2 ---Original LOAD_TIMEOUT = 900. Faster LOAD_TIMEOUT = 20. (Faster may cause issues with other players in the lobby?)
local IW_OFFSET, IW_RECENT = 160, 2
 
local pending, mode, timer, retries = false, nil, 0, 0
local lastLevel, lastArea, maxHP = nil, nil, DEFAULT_HP
local hostInit = {}
local recentIWAge, recentDX, recentDY, recentDZ = 99, 0, 0, 0
local guardFrames, guardX, guardY, guardZ = 0, 0, 0, 0

local bowserTime = 0 ---BOWSER FIX CODE (ACTIVATE FIX AFTER 5 FRAMES)
local bowser = nil ---BOWSER FIX CODE (USED TO FIND BOWSER ON MAP)
local isFlying = 0 ---USED TO SET MARIO BACK INTO FLYING STATE IF NEEDED WITHOUT GETTING CAMERA STUCK UNDERGROUND
local hasHeld = 0 ---USED TO SPAWN MARIOS HELD OBJECT AFTER 15 FRAMES
local spawnShell = 0 ---USED TO SPAWN MARIOS RIDEABLE SHELL OBJECT
local newObj = nil ---USED TO DELETE MARIOS HELD OBJECT IF TRYING TO SPAWN TOO MANY
local shell = nil --SHELL OBJECT WE SPAWN
local notInvulnerable = true --USED FOR SPAWNING SHELL WHILE ON GROUND HAZARDS
 
local F = {
    {"level","spLevel",0},{"area","spArea",1},{"act","spAct",0},{"hp","spHP",DEFAULT_HP},
    {"x","spX",0},{"y","spY",0},{"z","spZ",0},{"ax","spAngleX",0},{"ay","spAngleY",0},{"az","spAngleZ",0},
    {"red","spRedCoins",0},{"coins","spCoins",0},{"secrets","spSecrets",0},{"onInstantWarp","spIW",0},
    {"warpDX","spDX",0},{"warpDY","spDY",0},{"warpDZ","spDZ",0}, {"currFlags", "spFlags", 0},
	{"currCapTime", "spCapTime", 0}, {"currBhv", "spBhv", 0}, {"currobjModel", "spObjModel", 0},
	{"currHeld", "spHeld", 0}, {"currGrabPos", "spGrabPos", 0}, {"currRidingShell", "spRidingShell", 0}
}
 
local function blockedSave(m) --Block Saving
    return m == nil or m.health <= 0
		or m.action == ACT_READING_SIGN 
		or m.action == ACT_READING_NPC_DIALOG 
		or m.action == ACT_READING_AUTOMATIC_DIALOG 
		or m.action == ACT_WAITING_FOR_DIALOG 
		or m.action == ACT_INTRO_CUTSCENE
		or m.action == ACT_EXIT_LAND_SAVE_DIALOG
        or m.action == ACT_BUBBLED
        or (m.flags & MARIO_TELEPORTING) ~= 0
end
 
local function hash(s)
    local h = 5381
    s = tostring(s or "player")
    for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end
    return tostring(h)
end
 
local function prefix(i)
    local n = gNetworkPlayers[i]
    return "sp_" .. hash(n and n.name or ("player" .. tostring(i))) .. "_"
end
 
local function persist(i)
    if not network_is_server() then return end
    local n, s = gNetworkPlayers[i], gPlayerSyncTable[i]
    if n == nil or not n.connected or not s.spEnabled then return end
    local p = prefix(i)
    mod_storage_save(p .. "enabled", "1")
    for _, f in ipairs(F) do mod_storage_save(p .. f[1], tostring(s[f[2]] or f[3])) end
end
 
local function restore(i)
    if not network_is_server() then return end
    local n = gNetworkPlayers[i]
    if n == nil or not n.connected then return end
    local p = prefix(i)
    if mod_storage_load(p .. "enabled") == nil then hostInit[i] = true return end
    local s = gPlayerSyncTable[i]
    for _, f in ipairs(F) do
        local v = mod_storage_load(p .. f[1])
        s[f[2]] = tonumber(v) or f[3]
    end
    s.spEnabled = true
    s.spRevision = (s.spRevision or 0) + 1
    hostInit[i] = true
end
 
local function revision(i, old, new)
    if old ~= new then persist(i) end
end
 
local function iwSurface(s)
    if s == nil then return false end
    local t = s.type
    return t == SURFACE_INSTANT_WARP_1B or t == SURFACE_INSTANT_WARP_1C
        or t == SURFACE_INSTANT_WARP_1D or t == SURFACE_INSTANT_WARP_1E
end
 
local function onIWSurface(m)
    return iwSurface(m.floor) or iwSurface(m.wall) or iwSurface(m.ceil)
end
 
local function sign(v)
    if v > 0 then return 1 elseif v < 0 then return -1 end
    return 0
end
 
local function resetLoad()
    pending, mode, timer, retries, lastLevel, lastArea = false, nil, 0, 0, nil, nil
end
 
local function checkpointPos(s)
    local x, y, z = s.spX or 0, s.spY or 0, s.spZ or 0
    if (s.spIW or 0) == 0 then return x, y, z end
    local sx, sy, sz = sign(s.spDX or 0), sign(s.spDY or 0), sign(s.spDZ or 0)
    if sx ~= 0 or sy ~= 0 or sz ~= 0 then
        x, y, z = x - sx * IW_OFFSET, y - sy * math.min(IW_OFFSET, 80), z - sz * IW_OFFSET
    else
        local a = s.spAngleY or 0
        x, z = x - sins(a) * IW_OFFSET, z - coss(a) * IW_OFFSET
    end
    return x, y, z
end
 
local function apply(m)
    local s = gPlayerSyncTable[0]
    if not s.spEnabled then resetLoad() return end
 
    local x, y, z = checkpointPos(s)
    m.pos.x, m.pos.y, m.pos.z = x, y, z
    m.faceAngle.x, m.faceAngle.y, m.faceAngle.z = s.spAngleX or 0, s.spAngleY or 0, s.spAngleZ or 0
    m.vel.x, m.vel.y, m.vel.z, m.forwardVel, m.slideVelX, m.slideVelZ = 0, 0, 0, 0, 0, 0
 
    if m.area ~= nil then
        m.area.numRedCoins, m.area.numSecrets = s.spRedCoins or 0, s.spSecrets or 0
    end
    if keepCoins then m.numCoins = s.spCoins or 0 end
	m.flags = s.spFlags --LOAD MARIOS FLAGS
	m.capTimer = s.spCapTime --LOAD MARIOS CAP TIME

    m.health = fullHP and maxHP or (s.spHP or DEFAULT_HP)
    if m.marioObj ~= nil then m.marioObj.oIntangibleTimer = 0 end
    m.hurtCounter, m.invincTimer = 0, 30

	set_mario_action(m, ACT_WATER_IDLE, 0) ---Using ACT_WATER_IDLE instead of ACT_IDLE or ACT_FREEFALL to stop camera getting stuck underground when teleporting out of water.
	
	isFlying = 1 --FLYING FIX CODE
	
	if s.spRidingShell == 1 then
	spawnShell = 1
	notInvulnerable = false
	end
	
	if s.spBhv ~= 0 and keepObjects and s.spGrabPos ~= 3 then --s.spGrabPos 3 is bowsers tail so we ignore.
	hasHeld = 1
	end
	
    m.statusForCamera.action = ACT_IDLE
    if m.area ~= nil and m.area.camera ~= nil then soft_reset_camera(m.area.camera) end
 
    if (s.spIW or 0) ~= 0 then
        guardFrames, guardX, guardY, guardZ = 1, x, y, z
    end
 
    m.particleFlags = PARTICLE_SPARKLES
    if m.marioObj ~= nil then play_sound(SOUND_MENU_CLICK_FILE_SELECT, m.marioObj.header.gfx.cameraToObject) end
    resetLoad()

    djui_popup_create("\\#6fd83f\\Loaded your savepoint\\#6fd83f\\", 1)
end
 
local function save(m)
    local s, n = gPlayerSyncTable[0], gNetworkPlayers[0]
    s.spLevel = n.currLevelNum
    s.spArea = (m.area ~= nil and m.area.index) or n.currAreaIndex
    s.spAct, s.spHP = n.currActNum, m.health
    s.spX, s.spY, s.spZ = m.pos.x, m.pos.y, m.pos.z
	s.spFlags = m.flags --SAVE MARIOS FLAGS
	s.spCapTime = m.capTimer --SAVE MARIOS CAP TIME
	
	local held = m.heldObj
	if held ~= nil then
	s.spGrabPos = m.marioBodyState.grabPos
	s.spObjModel = obj_get_model_id_extended(held)
    s.spBhv = get_id_from_behavior(held.behavior)   -- convert pointer -> integer ID
	end
	if held == nil then
	s.spHeld = 0
	s.spObjModel = 0
	s.spBhv = 0
	end
	
	if m.action == ACT_RIDING_SHELL_GROUND or m.action == ACT_RIDING_SHELL_FALL or m.action == ACT_RIDING_SHELL_JUMP then
	s.spRidingShell = 1
	else
	s.spRidingShell = 0
	end
	
    s.spAngleX, s.spAngleY, s.spAngleZ = m.faceAngle.x, m.faceAngle.y, m.faceAngle.z
    s.spRedCoins = m.area and m.area.numRedCoins or 0
    s.spCoins = m.numCoins
    s.spSecrets = m.area and m.area.numSecrets or 0
    s.spIW = onIWSurface(m) and 1 or 0
    if s.spIW ~= 0 and recentIWAge <= IW_RECENT then
        s.spDX, s.spDY, s.spDZ = recentDX, recentDY, recentDZ
    else
        s.spDX, s.spDY, s.spDZ = 0, 0, 0
    end
    s.spEnabled = true
    s.spRevision = (s.spRevision or 0) + 1
    m.particleFlags = PARTICLE_SPARKLES
    if m.marioObj ~= nil then play_sound(SOUND_MENU_CLICK_CHANGE_VIEW, m.marioObj.header.gfx.cameraToObject) end
    djui_popup_create("\\#e7b625\\Created your savepoint\\#e7b625\\", 1)
end
 
local function requestWarp(s, useNode)
    timer, lastLevel, lastArea = 0, nil, nil
    if useNode and warp_to_warpnode ~= nil and WARP_NODE_DEATH ~= nil then
        mode = "node"
        warp_to_warpnode(s.spLevel, s.spArea, s.spAct, WARP_NODE_DEATH)	
    else
        mode = "level"
        warp_to_level(s.spLevel, s.spArea, s.spAct)
    end
	
	bowserTime = 1 ---After warping, set the variable for bowserTime to 1. (continues in local function update())
end
 
local function load(m)
    local s, n = gPlayerSyncTable[0], gNetworkPlayers[0]
    if not s.spEnabled then djui_popup_create("\\#dd3232\\No savepoint saved.\\#dd3232\\", 1) return end
    local a = (m.area ~= nil and m.area.index) or n.currAreaIndex
    if n.currLevelNum == s.spLevel and a == s.spArea then apply(m) return end
    pending, retries = true, 0
    requestWarp(s, true)
end
 
local function beforeMario(m)
    if m.playerIndex ~= 0 or not pending then return end
    local s, n = gPlayerSyncTable[0], gNetworkPlayers[0]
    if s.spEnabled and m.area ~= nil and n.currLevelNum == s.spLevel and m.area.index == s.spArea then
        apply(m)
    end
end
 
local function marioUpdate(m)
    if m.playerIndex ~= 0 then return end
	
	if spawnShell > 0 then --GHETTO GROUND SHELL CODE
	set_mario_action(m, ACT_IDLE, 0)
	spawnShell = spawnShell + 1
	obj_mark_for_deletion(shell)
	obj_mark_for_deletion(m.riddenObj)

		if spawnShell >= 15 then --WAIT AROUND 15 FRAMES AS SPAWNING OBJECT TO FAST WILL NOT WORK AND CAUSE SCRIPT ERRORS
		shell = spawn_sync_object(id_bhvKoopaShell, E_MODEL_KOOPA_SHELL, m.pos.x, m.pos.y, m.pos.z, nil)

		shell.oAction = 1                              -- skip straight to "being ridden" state
		shell.oInteractStatus = INT_STATUS_INTERACTED  -- mimic the touch event
		m.interactObj = shell
		m.riddenObj = shell
		set_mario_action(m, ACT_RIDING_SHELL_GROUND, 0)
		notInvulnerable = true
		spawnShell = 0
		end

	end
	
	if hasHeld > 0 then --GHETTO KEEP HELD ITEM CODE
	
	local s = gPlayerSyncTable[0]

	obj_mark_for_deletion(m.heldObj)
	set_mario_action(m, ACT_IDLE, 0)
	obj_mark_for_deletion(newObj)

	
	hasHeld = hasHeld + 1
	
		if hasHeld >= 15 then --WAIT AROUND 15 FRAMES AS SPAWNING OBJECT TO FAST WILL NOT WORK AND CAUSE SCRIPT ERRORS

			if m.heldObj == nil then
			newObj = spawn_sync_object(s.spBhv, s.spObjModel, m.pos.x, m.pos.y, m.pos.z, nil)
			newObj.oHeldState = 1 --STOPS ITEM FROM DUPLICATING
			--newObj.oAction = 1 
			m.heldObj = newObj
			
			if s.spGrabPos == 1 then
			m.marioBodyState.grabPos = GRAB_POS_LIGHT_OBJ
			set_mario_action(m, ACT_HOLD_IDLE, 0)
			--set_mario_action(m, ACT_HOLD_WATER_IDLE, 0)
			elseif s.spGrabPos == 2 then
			m.marioBodyState.grabPos = GRAB_POS_HEAVY_OBJ
			set_mario_action(m, ACT_HOLD_HEAVY_IDLE, 0)
			else
			m.marioBodyState.grabPos = GRAB_POS_LIGHT_OBJ
			set_mario_action(m, ACT_HOLD_IDLE, 0)
			end
			if s.spBhv == id_bhvKoopaShellUnderwater then
			newObj.oAction = 1 
			m.riddenObj = newObj
			set_mario_action(m, ACT_WATER_SHELL_SWIMMING, 0)
			end

			end
		hasHeld = 0
		end
		
	end

	if isFlying > 0 then --FLYING FIX CODE
	isFlying = isFlying + 1
		if isFlying >= 2 then
			if m.action == ACT_FREEFALL then
			set_mario_action(m, ACT_FLYING, 0)
			end
		isFlying = 0
		end
	end --END OF FLYING FIX CODE

    if m.health > maxHP then maxHP = m.health end
	
	if (m.controller.buttonPressed & D_JPAD) == 0 or blockedSave(m) then return end

    if pending then resetLoad() end

	if (m.controller.buttonDown & L_TRIG) ~= 0 then load(m) else save(m) end

end

local function update()
	
	if bowserTime > 0 then ---BOWSER FIX CODE (THIS CODE MAY NOT WORK FOR ROMHACK FINAL/MAJOR BOSSES!)
	bowserTime = bowserTime + 1
		if bowserTime >= 5 then
		    
			bowser = obj_get_first_with_behavior_id(id_bhvBowser)
			if bowser ~= nil then
			bowser.oAction = 0 ---Reset Bowsers action back to 0 so he doesn't get stuck in place.
			end
		
		bowserTime = 0
		bowser = nil
		end
	end ---END OF BOWSER FIX CODE

    if recentIWAge <= IW_RECENT then recentIWAge = recentIWAge + 1 end
 
    if network_is_server() then
        for i = 0, MAX_PLAYERS - 1 do
            local n = gNetworkPlayers[i]
            if n ~= nil and n.connected then
                if not hostInit[i] then restore(i) end
            else
                hostInit[i] = nil
            end
        end
    end
 
    if not pending then return end
    local m, n, s = gMarioStates[0], gNetworkPlayers[0], gPlayerSyncTable[0]
    if m == nil or n == nil or not s.spEnabled then return end
    local a = m.area and m.area.index or n.currAreaIndex
    if n.currLevelNum ~= lastLevel or a ~= lastArea then
        lastLevel, lastArea, timer = n.currLevelNum, a, 0
    else
        timer = timer + 1
    end
 
    if mode == "node" and timer >= WARP_FALLBACK then
        requestWarp(s, false)
        return
    end
 
    if timer >= LOAD_TIMEOUT then
        if retries < LOAD_RETRIES then
            retries = retries + 1
            requestWarp(s, mode ~= "level")
        else
            resetLoad()
            djui_popup_create("\\#dd3232\\SavePoint load stopped; press load again.\\#dd3232\\", 2)
			djui_popup_create("\\#dd3232\\PLEASE REPORT ISSUE TO MOD AUTHOR!\\#dd3232\\", 1)
        end
    end
end
 
local function instantWarp(area, id, d)
    recentIWAge = 0
    recentDX, recentDY, recentDZ = 0, 0, 0
    if d ~= nil then recentDX, recentDY, recentDZ = d.x or 0, d.y or 0, d.z or 0 end
end

local function beforePhys(m, step)
    if m.playerIndex ~= 0 or guardFrames <= 0 then return end
    m.pos.x, m.pos.y, m.pos.z = guardX, guardY, guardZ
    m.vel.x, m.vel.y, m.vel.z, m.forwardVel = 0, 0, 0, 0
    guardFrames = guardFrames - 1
    if step == STEP_TYPE_GROUND then return GROUND_STEP_NONE end
    if step == STEP_TYPE_AIR then return AIR_STEP_NONE end
    if step == STEP_TYPE_WATER then return WATER_STEP_NONE end
    return 0
end

local function prevent_slope_slide(m, incomingAction, actionArg)
    if notInvulnerable == false and incomingAction == ACT_BEGIN_SLIDING then return ACT_IDLE end
end
 
local function disconnected(m)
    if network_is_server() and m ~= nil then hostInit[m.playerIndex] = nil end
end
 
local function fullhp()
    fullHP = not fullHP
    djui_chat_message_create("Full HP on load: " .. (fullHP and "\\#6fd83f\\enabled\\#6fd83f\\" or "\\#dd3232\\disabled\\#dd3232\\"))
    return true
end
 
local function keepcoin()
    keepCoins = not keepCoins
    djui_chat_message_create("Keep coins on load: " .. (keepCoins and "\\#6fd83f\\enabled\\#6fd83f\\" or "\\#dd3232\\disabled\\#dd3232\\"))
    return true
end

local function keepobject()
    keepObjects = not keepObjects
    djui_chat_message_create("Keep holdable object on load: " .. (keepObjects and "\\#6fd83f\\enabled\\#6fd83f\\" or "\\#dd3232\\disabled\\#dd3232\\"))
    return true
end
 
local function debugSP()
    local m, n, s = gMarioStates[0], gNetworkPlayers[0], gPlayerSyncTable[0]
    local a = m and m.area and m.area.index or -1

    djui_chat_message_create("SP current=" .. tostring(n and n.currLevelNum or -1) .. "/" .. tostring(a)
        .. " saved=" .. tostring(s.spLevel or -1) .. "/" .. tostring(s.spArea or -1))
    djui_chat_message_create("SP pending=" .. tostring(pending) .. " mode=" .. tostring(mode) .. " timer=" .. tostring(timer))
    return true
end
 
for i = 0, MAX_PLAYERS - 1 do
    if gPlayerSyncTable[i].spRevision == nil then gPlayerSyncTable[i].spRevision = 0 end
    hook_on_sync_table_change(gPlayerSyncTable[i], "spRevision", i, revision)
end
 
 
hook_event(HOOK_BEFORE_SET_MARIO_ACTION, prevent_slope_slide)
hook_event(HOOK_BEFORE_MARIO_UPDATE, beforeMario)
hook_event(HOOK_MARIO_UPDATE, marioUpdate)
hook_event(HOOK_UPDATE, update)
hook_event(HOOK_ON_INSTANT_WARP, instantWarp)
hook_event(HOOK_BEFORE_PHYS_STEP, beforePhys)
hook_event(HOOK_ON_PLAYER_DISCONNECTED, disconnected)
hook_event(HOOK_ALLOW_HAZARD_SURFACE, function(m) return notInvulnerable end)  --(USED FOR RESPAWNING WITH SHELL OVER GROUND HAZARDS)
 
hook_chat_command("fullhp", "Toggle full HP on load.", fullhp)
hook_chat_command("keepcoin", "Toggle saved coin restoration.", keepcoin)
hook_chat_command("keepobject", "Toggle held item restoration.", keepobject)
hook_chat_command("ko", "Toggle held item restoration.", keepobject)
hook_chat_command("fh", "Toggle full HP on load.", fullhp)
hook_chat_command("kc", "Toggle saved coin restoration.", keepcoin)
hook_chat_command("spdebug", "Show SavePoint debug info.", debugSP)