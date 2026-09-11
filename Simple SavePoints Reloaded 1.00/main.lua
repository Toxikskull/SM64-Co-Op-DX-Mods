-- name: \\#00FF7F\\Simple SavePoints Reloaded v1.00\\#00FF7F\\
-- description: Four persistent, multiplayer-safe savepoints per player.\n\nAny D-pad direction: save to that direction's slot.\nL Trigger + the same D-pad direction: load that slot.\n\nEach slot stays on this computer and sends no SavePoint data to the host or other players.\n\nVibe coded by \\#f8c62d\\GazzyGaz\\#f8c62d\\\n\\#ffffff\\debugged by\\#ffffff\\ \\#674ea7\\Toxikskull\\#674ea7\\.
 
---------------------------------------------------------------------------------------------------
-- Controls, constants, and live session state
---------------------------------------------------------------------------------------------------
 
-- Purpose:
-- This section defines the controls and every value that exists only while the mod is running. Slot contents are
-- introduced in the persistence section; none of the state here is sent as SavePoint network data.
-- Call flow: engine hooks update these values, save() copies the relevant gameplay values into one slot, and
-- apply() plus the per-frame maintenance callbacks consume them while a load settles.
-- Player effect: each computer owns its own controls and temporary work, so one player's save/load cannot pause,
-- overwrite, or time another player's checkpoint.
 
-- Local preferences are toggled by the chat-command callbacks and read only by apply(). keepCoins restores the
-- saved coin count; fullHP chooses a refill to maxHP instead of exact saved health.
local keepCoins, fullHP, trackTimer = false, false, false

local invulnerable = false --USED FOR SPAWNING SHELL WHILE ON GROUND HAZARDS
 
-- Load/camera timing constants are measured in frames. A destination must be stable briefly before apply(); each
-- cross-level load gets one safe level-entry request, and camera vectors stay fixed briefly after Mario arrives.
local DEFAULT_HP, LOAD_TIMEOUT, BOWSER_READY_TIMEOUT = 2176, 180, 300
local LOAD_SETTLE_FRAMES, CAMERA_RESTORE_FRAMES = 3, 4
local IW_OFFSET, IW_RECENT = 160, 2
 
-- loadMode replaces a separate pending flag: LOAD_NONE means idle, while the other values tell beforeMario() and
-- updatePendingLoad() whether they are waiting for a safe level entry or a native Bowser root.
local LOAD_NONE, LOAD_LEVEL, LOAD_BOWSER = 0, 1, 2
 
-- resetLoad(), requestWarp(), load(), beforeMario(), and updatePendingLoad() own these values. timer bounds waiting;
-- loadSettle requires consecutive ready frames, while level/area progress restarts the timeout. marioUpdate() grows maxHP.
local loadMode, timer, retries = LOAD_NONE, 0, 0
local lastLevel, lastArea, maxHP = nil, nil, DEFAULT_HP
 
-- instantWarp() records the latest engine-supplied displacement. save() keeps it only near the triggering frame;
-- apply() arms guardFrames and beforePhys() holds the corrected position for one collision step.
local recentIWAge, recentDX, recentDY, recentDZ = 99, 0, 0, 0
local guardFrames, guardX, guardY, guardZ = 0, 0, 0, 0
 
-- updatePrivateSlideSurface() starts/stops this local clock, save()/apply() capture or restore it, and three engine
-- phases reassert it where slide finish logic and the HUD need it. Koopa's shared race deliberately never owns it.
local raceTimerOverride, raceTimerRunning, raceTimerValue, raceTimerHold = false, false, 0, 0
local raceTimerLevel, raceTimerArea = -1, -1
 
-- apply() sets this after the immediate camera snap. latePlayModeRestore() repeats the saved vectors for a few
-- post-camera frames, then releases control so water/warp setup cannot replace the checkpoint view with a stale one.
local cameraRestoreFrames = 0
 
-- onInteract() fills collectedByArea. apply() selects ownedGone for the loaded slot; refreshOwnedItems() and
-- allowInteract() use it to hide/block native pickups locally without deleting synchronized objects for peers.
local ownedGone, ownedGoneLocation, hiddenObjects = {}, nil, {}
local collectedByArea, worldScanTicker = {}, 0
 
-- The restoredObject group identifies a private held clone or synchronized ridden shell and the native source it
-- replaces. Interaction restoration sets it; visibility/cleanup functions validate and clear it when loading again.
local restoredObject, restoredObjectKey, restoredObjectBehavior = nil, nil, nil
local restoredObjectSourceKey, restoredObjectSourceBehavior, restoredObjectLocation = nil, nil, nil
-- A newly spawned synchronized shell may receive its network slot one or two frames after creation. This bounded
-- counter lets updateRestoredObjectSync() send the completed riding state as soon as that slot exists.
local restoredObjectSyncFrames = 0
-- A same-area shell replacement waits briefly after the old ride ends so CoopDX can retire the old sync slot and
-- deliver its deletion before a new shell is announced. The retry count handles a temporarily unavailable spawn.
local shellRestoreFrames, shellRestoreAttempts = 0, 0
-- CoopDX currently drops a newly reconstructed ridden shell from non-owning peers. One tiny reliable event lets
-- those peers maintain a local, non-interactive shell model under the remote rider instead. Only the owner keeps
-- the real gameplay shell; these tables hold the announced rider states and this process's visual stand-ins.
local shellVisual = {
    packet = 91, serial = 0, lost = 0, active = false, level = -1, area = -1,
    playerCount = 1, resend = 0, pending = 0, states = {}, visuals = {}
}
 
-- apply() arms these bounded counters only when a synchronized Bowser root is late. updateBowserRetries() retries
-- the held and free-boss paths independently, then stops on success, area exit, or exhaustion.
local interactionRetryFrames, bowserWorldRetryFrames = 0, 0
 
-- Stored interaction modes select no object, an ordinary held clone, a ridden shell clone, or the native Bowser.
-- FREE/HELD/DEACTIVATED normalize the engine's object-state constants used throughout reconstruction checks.
local OBJ_NONE, OBJ_HELD, OBJ_SHELL, OBJ_BOWSER = 0, 1, 2, 3
local FREE, HELD, DEACTIVATED = HELD_FREE or 0, HELD_HELD or 1, ACTIVE_FLAG_DEACTIVATED or 0
 
-- Bowser restoration is staged because the arena, network sync, Mario pickup, boss animation, and render graph
-- become ready on different frames. requestWarp() arms bowserTime for ordinary arena setup.
local bowserTime = 0
 
-- restoreBowserInteraction() initializes this staged pickup; advanceBowserRestore() owns the phase/frame values
-- until the saved spin is stable or the attempt is cancelled.
local bowserRestoreObject, bowserRestoreFrames, bowserRestoreLocation = nil, 0, nil
local bowserRestorePhase, bowserRestoreSettle = 0, 0
local BOWSER_RESTORE_GRAB, BOWSER_RESTORE_HELD, BOWSER_RESTORE_SETTLE = 1, 2, 3
 
-- While Mario holds Bowser, maintainHeldBowserWorldGraph() keeps the native world graph hidden so the held render
-- path does not draw a duplicate. The root is revealed as soon as the reciprocal hold ends.
local heldBowserRoot, heldBowserLocation = nil, nil
local BOWSER_RENDER_ACTIVE = GRAPH_RENDER_ACTIVE or 1
 
-- A free Bowser's action can choose its animation after restoration. This one-frame record lets
-- finishBowserWorldAnimationRestore() reapply the saved frame after native action setup.
local bowserWorldAnimObject, bowserWorldAnimLocation, bowserWorldAnimFrame = nil, nil, 0
 
-- packCheckpoint()/unpackCheckpoint() use this byte to reject files with a different binary layout.
local CHECKPOINT_FORMAT = 2
 
-- Down uses the base checkpoint filename; the other directions use explicit directional filenames.
-- marioUpdate() maps button presses to these entries; persistence and popups reuse the same table.
local SAVE_SLOTS = {
    {button = U_JPAD, name = "Up", file = "checkpoint-up.sav"},
    {button = L_JPAD, name = "Left", file = "checkpoint-left.sav"},
    {button = D_JPAD, name = "Down", file = "checkpoint.sav"},
    {button = R_JPAD, name = "Right", file = "checkpoint-right.sav"},
}
-- Down is the initial active pointer, and the combined mask lets marioUpdate() return before scanning the table
-- on ordinary frames with no D-pad press.
local DEFAULT_SLOT = 3
local SAVE_BUTTON_MASK = U_JPAD | L_JPAD | D_JPAD | R_JPAD
 
---------------------------------------------------------------------------------------------------
-- What each slot remembers and how it persists
---------------------------------------------------------------------------------------------------
 
-- Purpose:
-- This section lists every value one slot remembers, converts it to compact binary data, and reads all four local
-- files once when the script starts. The fixed field order is the on-disk contract used by both encoder/decoder.
-- Call flow: module initialization builds the schema and loads files; save() creates, packs, and writes one fresh
-- table; load() selects an already-decoded table and therefore performs no disk work during gameplay.
-- Player effect: four independent checkpoints survive closing the game, belong only to this computer, and
-- never send save data to the host. Invalid or incompatible files are ignored safely.
 
-- addFields() fills this ordered array during script initialization. blankCheckpoint(), packCheckpoint(), and
-- unpackCheckpoint() are its only consumers; reordering entries would change the binary file layout.
local CHECKPOINT_FIELDS = {}
 
-- Field guide (all numeric unless noted):
--   spLevel/spArea/spAct, spX/Y/Z, spAngle*, inventory, caps, swim/air and spIW/spD* describe Mario and location.
--   spObj* describes a held/ridden object's root; spBobomb* preserves its behavior-specific remaining fuse.
--   spBowserHeld* plus spInt* preserve Mario's tail-hold pose/momentum; spBowserWorld* describes a free boss root.
--   spTimer* owns a private timer; spSharedRace marks that the live lobby race must remain authoritative.
--   spCam* stores the rendered view and smoothing state; spGone (stored separately as text) lists local pickups.
-- Every populated slot contains every schema field, so gameplay code can read values directly without nil/default
-- branches. blankCheckpoint() supplies the defaults and unpackCheckpoint() must decode the complete schema.
 
-- Appends a space-separated field group with one default value.
-- Called by the declarations immediately below, before slot files are read or hooks are registered.
-- Why/player effect: compact declarations keep encoder/decoder order identical and every fresh save complete.
local function addFields(default, spec)
    for name in spec:gmatch("%w+") do CHECKPOINT_FIELDS[#CHECKPOINT_FIELDS + 1] = {name, default} end
end
 
addFields(0, [[
spLevel spAct spX spY spZ spAngleX spAngleY spAngleZ
spRedCoins spCoins spSecrets spKeys spCapFlags spCapTimer
spShell spShellWater spShellAction
spObjMode spObjBhv spObjModel spObjKey spObjBehParams spObjBehParams2
spObjX spObjY spObjZ spObjHomeX spObjHomeY spObjHomeZ
spObjVelX spObjVelY spObjVelZ spObjForwardVel
spObjMovePitch spObjMoveYaw spObjMoveRoll spObjFacePitch spObjFaceYaw spObjFaceRoll
spObjAngleVelPitch spObjAngleVelYaw spObjAngleVelRoll
spObjAction spObjPrevAction spObjSubAction spObjTimer spObjBhvTimer
spObjAnimState spObjAnimFrame spObjFlags spObjInteractType
spObjInteractSubtype spObjInteractStatus spObjIntangibleTimer spObjHealth
spObjMoveFlags spObjGravity spObjFriction spObjBuoyancy
spObjBounciness spObjGraphYOffset spObjRoom spObjAreaTimer
spObjAreaTimerDuration spObjAreaTimerType
spBobombBlinkTimer spBobombFuseLit spBobombFuseTimer
spBowserF4 spBowserHeldPitch spBowserHeldVelYaw spBowserHeldStage
spBowserWorld spBowserWorldKey spBowserWorldX spBowserWorldY spBowserWorldZ
spBowserWorldHomeX spBowserWorldHomeY spBowserWorldHomeZ
spBowserWorldVelX spBowserWorldVelY spBowserWorldVelZ spBowserWorldForwardVel
spBowserWorldMovePitch spBowserWorldMoveYaw spBowserWorldMoveRoll
spBowserWorldFacePitch spBowserWorldFaceYaw spBowserWorldFaceRoll
spBowserWorldAngleVelPitch spBowserWorldAngleVelYaw spBowserWorldAngleVelRoll
spBowserWorldAction spBowserWorldPrevAction spBowserWorldSubAction
spBowserWorldTimer spBowserWorldDelayTimer spBowserWorldAnimState
spBowserWorldAnimFrame spBowserWorldHealth spBowserWorldMoveFlags
spBowserWorldIntangible spBowserWorldUnk88 spBowserWorldF4
spBowserWorldF8 spBowserWorldDist spBowserWorldUnk106
spBowserWorldUnk108 spBowserWorldUnk110 spBowserWorldAngleToCentre
spBowserWorldUnk1AC spBowserWorldUnk1AE spBowserWorldEyesShut spBowserWorldUnk1B2
spIntAction spIntPrevAction spIntActionState spIntActionTimer spIntActionArg
spIntVelX spIntVelY spIntVelZ spIntForwardVel spIntSlideX spIntSlideZ
spIntAngleVelX spIntAngleVelY spIntAngleVelZ spIntTwirlYaw spIntGrabPos
spIntAnimFrame spIntMarioObjPitch spTimer spTimerOn spSharedRace
spSwim spAir spIW spDX spDY spDZ spSSX spSSY spSSZ spSLevel spSArea spSAct
]]) --SSXYZ/Level/Area/Act = slide races SURFACE_TIMER_START location. spSLevel = level with a SURFACE_TIMER_START/END

local tempSSX, tempSSY, tempSSZ, tempSLevel, tempArea, tempAct = nil, nil, nil, nil, nil, nil
local refreshSlide = 0
--local inTimer = false

addFields(1, "spArea spObjScaleX spObjScaleY spObjScaleZ")
addFields(4, "spLives")
addFields(255, "spObjOpacity spBowserWorldOpacity")
addFields(-1, "spBowserAnim spBowserWorldAnim")
addFields(DEFAULT_HP, "spHP")
addFields(0, [[
spCamValid spCamPosX spCamPosY spCamPosZ
spCamFocusX spCamFocusY spCamFocusZ spCamYaw spCamNextYaw
spCamOldPitch spCamOldYaw spCamFocusDistance
spCamFocHSpeed spCamFocVSpeed spCamPosHSpeed spCamPosVSpeed
]])
 
-- Creates a fresh slot table populated with every schema default and an empty collectible list.
-- Called by unpackCheckpoint() before filling disk values and by save() before capturing a new moment.
-- Why/player effect: every save is independent and empty/damaged files never leave partial gameplay state.
local function blankCheckpoint()
    local s = {spGone = ""}
    for _, f in ipairs(CHECKPOINT_FIELDS) do s[f[1]] = f[2] end
    return s
end
 
-- localCheckpoints is indexed exactly like SAVE_SLOTS and stores decoded/fresh tables only for populated slots.
-- activeSlot names popup/camera work; localCheckpoint is the table consumed by apply() and delayed callbacks.
-- A nil entry means that direction has never been saved; save() always creates a fresh table.
-- Player effect: each D-pad direction remains independent, and an unused direction reports that it is empty.
local localCheckpoints, activeSlot, localCheckpoint = {}, DEFAULT_SLOT, nil
 
-- Converts one complete slot table into its compact binary file payload.
-- Called only by save(), immediately before writeCheckpoint(); numeric fields follow CHECKPOINT_FIELDS and the
-- sorted collectible identities follow as bounded integers.
-- Why/player effect: one small local payload preserves the full moment without network traffic or host pauses.
local function packCheckpoint(s)
    local out, gone = {string.pack("<B", CHECKPOINT_FORMAT)}, {}
    for _, f in ipairs(CHECKPOINT_FIELDS) do out[#out + 1] = string.pack("<d", tonumber(s[f[1]]) or f[2]) end
    for key in s.spGone:gmatch("[^,]+") do
        local value = tonumber(key)
        if value ~= nil and value >= 0 and value <= 0x7fffffff then gone[#gone + 1] = value end
    end
    out[#out + 1] = string.pack("<I2", #gone)
    for _, value in ipairs(gone) do out[#out + 1] = string.pack("<I4", value) end
    return table.concat(out)
end
 
-- Decodes and validates one binary payload into a fresh slot table.
-- Called by loadPersistentSlots() during startup, inside a protected call. It checks the format byte, reads the
-- exact schema, bounds collectible IDs, and rejects trailing/truncated data.
-- Why/player effect: an unusable file stays empty instead of feeding corrupt values into Mario or the world.
local function unpackCheckpoint(blob)
    local ok, result = pcall(function()
        local offset, version, s = 1, nil, blankCheckpoint()
        version, offset = string.unpack("<B", blob, offset)
        if version ~= CHECKPOINT_FORMAT then error("unsupported checkpoint format") end
        for _, f in ipairs(CHECKPOINT_FIELDS) do s[f[1]], offset = string.unpack("<d", blob, offset) end
        local count
        count, offset = string.unpack("<I2", blob, offset)
        local gone = {}
        for i = 1, count do
            local value
            value, offset = string.unpack("<I4", blob, offset)
            gone[i] = tostring(value)
        end
        if offset ~= #blob + 1 then error("trailing checkpoint data") end
        s.spGone = table.concat(gone, ",")
        return s
    end)
    return ok and result or nil
end
 
-- Replaces only the selected direction's file through CoopDX ModFS.
-- Called by save() after the in-memory slot is complete. Rewind/erase prevents an open ModFS file object from
-- appending a second payload, and pcall turns storage failure into a session-only save.
-- Why/player effect: one direction writes one local file while the other slots and all other players are untouched.
local function writeCheckpoint(slot, blob)
    if mod_fs_get == nil or mod_fs_create == nil then return false end
    local ok, saved = pcall(function()
        local fs = mod_fs_get() or mod_fs_create()
        if fs == nil then return false end
        local fileName = SAVE_SLOTS[slot].file
        local file = fs:get_file(fileName) or fs:create_file(fileName, false)
        if file == nil or not file:rewind() then return false end
        if file.size > 0 and not file:erase(file.size) then return false end
        if not file:rewind() or not file:write_bytes(blob) then return false end
        return fs:save()
    end)
    return ok and saved == true
end
 
-- Opens ModFS once and independently loads every directional file into localCheckpoints.
-- Called once by module initialization below; each file operation is protected separately so one failure cannot
-- suppress the other directions. load() never calls this function.
-- Why/player effect: every valid slot is immediately available while a missing slot simply starts empty.
local function loadPersistentSlots()
    if mod_fs_get == nil then return end
    local ok, fs = pcall(mod_fs_get)
    if not ok or fs == nil then return end
    for i, slot in ipairs(SAVE_SLOTS) do
        local valid, s = pcall(function()
            local file = fs:get_file(slot.file)
            if file == nil or file.size <= 0 or not file:rewind() then return nil end
            return unpackCheckpoint(file:read_bytes(file.size))
        end)
        if valid and s ~= nil then localCheckpoints[i] = s end
    end
end
 
-- Startup call: runs before hook registration, then points delayed work at Down if that slot exists.
loadPersistentSlots()
localCheckpoint = localCheckpoints[activeSlot]
 
---------------------------------------------------------------------------------------------------
-- Finding the correct place and world object
---------------------------------------------------------------------------------------------------
 
-- Purpose:
-- These small read-only helpers turn CoopDX surfaces, areas, object pointers, and animation records into stable
-- answers. They are defined before every subsystem that consumes them.
-- Call flow: save/load uses the location and warp helpers; collectible and interaction code uses objectKey();
-- Bowser restoration additionally uses behavior, sync-readiness, and animation helpers.
-- Player effect: a checkpoint returns to the right area and reconnects to the right objects without being
-- confused by a transition, a reused object slot, or an invisible warp surface.
 
-- Turns stable spawn details into a compact repeatable identity.
-- Called only by objectKey(), during saves, loads, collectible callbacks, and throttled visibility scans. It uses
-- deterministic text hashing and never reads or changes engine state itself.
-- Why/player effect: the same world object can be recognized after pointers and sync slots have changed.
local function stableHash(s)
    local h = 5381
    s = tostring(s or "object")
    for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end
    return tostring(h)
end
 
-- Reports whether a surface is one of SM64's four instant-warp triggers.
-- Called by save() for Mario's floor, wall, and ceiling only when recording a slot.
-- Why/player effect: checkpointPos() can later offset Mario away from an invisible warp instead of retriggering it.
local function iwSurface(s)
    if s == nil then return false end
    local t = s.type
    return t == SURFACE_INSTANT_WARP_1B or t == SURFACE_INSTANT_WARP_1C
        or t == SURFACE_INSTANT_WARP_1D or t == SURFACE_INSTANT_WARP_1E
end
 
-- Reduces a number to -1, 0, or 1 to describe its direction.
-- Called three times by checkpointPos() only for an instant-warp checkpoint; it does not touch engine state.
-- Why/player effect: the safety offset follows direction rather than full warp distance, placing Mario safely.
local function sign(v)
    if v > 0 then return 1 elseif v < 0 then return -1 end
    return 0
end
 
 
-- Rounds a coordinate to the nearest whole number.
-- Called by objectKey() for each home-position axis whenever an object identity is needed.
-- Why/player effect: harmless floating-point drift cannot make a native pickup look like a different object.
local function roundi(v)
    v = v or 0
    return math.floor(v + (v >= 0 and 0.5 or -0.5))
end
 
-- Combines a level number and area number into one text key.
-- Called by currentLocationKey(), save/apply(), and object/Bowser trackers when indexing area-bound state.
-- Why/player effect: hidden, rebuilt, or delayed objects never leak into another level or area.
local function locationKey(level, area)
    return tostring(level or -1) .. "/" .. tostring(area or -1) end
 
-- Returns Mario's current area, including while an area is still loading.
-- Called by every location/timer/pending-load comparison. It prefers MarioState.area, then the network player's
-- transition value while Mario's area object is unavailable.
-- Why/player effect: cross-area restoration does not fail between CoopDX's separate warp setup steps.
local function playerArea(m, n)
    return m and m.area and m.area.index or (n and n.currAreaIndex or -1) end
 
-- Returns the local player's current level-and-area key.
-- Called by collectible visibility, restored-object cleanup, and Bowser guards during update/apply work.
-- It always reads player zero because every checkpoint and private clone belongs to this client.
-- Why/player effect: locally hidden or rebuilt objects remain attached to the area where they belong.
local function currentLocationKey()
    local m, n = gMarioStates[0], gNetworkPlayers[0]
    if n == nil then return nil end
    return locationKey(n.currLevelNum, playerArea(m, n))
end
 
-- Reports whether local Mario is inside a slot's exact level and area.
-- Called by load(), beforeMario(), and updateBowserRetries() so immediate and delayed paths use the same rule.
-- Why/player effect: restoration starts only after the correct destination exists.
local function atCheckpoint(s, m, n)
    return s ~= nil and m ~= nil and n ~= nil
        and n.currLevelNum == s.spLevel and playerArea(m, n) == s.spArea
end
 
-- Reports whether a warped destination has finished creating Mario, the area camera, and normal player control.
-- Called by beforeMario() for consecutive-frame settling; same-area loads already have these objects and apply
-- directly. Transition actions are rejected even after level/area numbers change because their camera is temporary.
-- Why/player effect: cross-level loads wait past death/warp setup instead of freezing on a sky or underwater view.
local function destinationReady(s, m, n)
    if not atCheckpoint(s, m, n) or m.area == nil or m.area.camera == nil or m.marioObj == nil then return false end
    return m.health > 0 and (m.action & ACT_GROUP_MASK) ~= ACT_GROUP_CUTSCENE
        and (m.action & ACT_FLAG_INTANGIBLE) == 0 and m.action ~= ACT_BUBBLED
        and (m.flags & MARIO_TELEPORTING) == 0
end
 
-- Returns the stable Lua behavior ID for an object, or zero when none is available.
-- Called throughout object capture, clone validation, shell checks, collectible scans, and Bowser recognition.
-- Why/player effect: every supported object follows the restore path for its actual behavior, not just its model.
local function objectBehaviorId(o)
    return o ~= nil and (get_id_from_behavior(o.behavior) or 0) or 0
end
 
-- Reports whether a synchronized object has a usable CoopDX sync slot.
-- Called by Bowser capture, candidate ranking, and sendObjectSync(); the engine query is protected with pcall.
-- Why/player effect: restoration waits for a complete boss root instead of producing duplicates or detached parts.
local function objectSyncInitialized(o)
    if o == nil then return false end
    local syncId = o.oSyncID or 0
    if syncId == 0 then return false end
    local ok, initialized = pcall(sync_object_is_initialized, syncId)
    return ok and initialized == true
end
 
-- Builds a repeatable identity from an object's behavior, model, parameters, and rounded home position.
-- Called by save/capture, collectible hooks, local visibility, clone validation, and Bowser candidate ranking.
-- It reads stable spawn details and delegates the final compact identity to stableHash().
-- Why/player effect: changing pointers/sync slots cannot make the mod hide or reconnect the wrong object.
local function objectKey(o)
    if o == nil then return nil end
    local bhv = objectBehaviorId(o)
    local model = obj_get_model_id_extended(o) or 0
    local x = o.oHomeX ~= nil and o.oHomeX or o.oPosX
    local y = o.oHomeY ~= nil and o.oHomeY or o.oPosY
    local z = o.oHomeZ ~= nil and o.oHomeZ or o.oPosZ
    local raw = table.concat({
        tostring(bhv), tostring(model), tostring(o.oBehParams or 0),
        tostring(roundi(x)), tostring(roundi(y)), tostring(roundi(z))
    }, ":")
    return stableHash(raw)
end
 
-- Returns an object's writable animation record when its graphics data contains one.
-- Called by interaction/Bowser capture and their immediate or delayed animation restore paths.
-- Why/player effect: supported animations resume at the saved frame, while objects without animation load safely.
local function animInfo(o)
    return o and o.header and o.header.gfx and o.header.gfx.animInfo or nil end
 
-- Converts a compact saved-field:object-field list into metadata used by copy loops.
-- Called twice during module initialization to build OBJECT_FIELDS and BOWSER_WORLD_FIELDS before hooks run.
-- Each optional third token overrides the group's default and no live object is accessed here.
-- Why/player effect: capture/restore stays symmetrical, so motion, actions, and appearance return together.
local function fieldMap(default, spec)
    local fields = {}
    for token in spec:gmatch("%S+") do
        local saved, live, override = token:match("(%w+):(%w+):?(-?%d*)")
        fields[#fields + 1] = {saved, live, override ~= "" and tonumber(override) or default}
    end
    return fields
end
 
---------------------------------------------------------------------------------------------------
-- Remembering held objects, shells, and Bowser
---------------------------------------------------------------------------------------------------
 
-- Purpose:
-- This section defines the field maps and capture functions used by save(). Generic objects and held Bowser share
-- the interaction snapshot because Mario's pose/motion is part of both; a free Bowser has an additional root map.
-- Call flow: fieldMap() builds the maps at startup; save() calls captureInteraction() and, when Bowser is free,
-- captureBowserWorldSnapshot(); later restoration sections consume the same saved fields.
-- Player effect: carried items, shell rides, Bob-omb fuses, Bowser attacks, and tail spins continue from the
-- saved moment instead of restarting, disappearing, or becoming unresponsive.
 
-- OBJECT_FIELDS maps slot names to CoopDX Object members. captureInteraction() reads it and
-- restoreObjectFields() writes it; explicit code handles animation/scale, Bob-omb fuse, and held Bowser details.
local OBJECT_FIELDS = fieldMap(0, [[
spObjBehParams:oBehParams spObjBehParams2:oBehParams2ndByte spObjX:oPosX spObjY:oPosY spObjZ:oPosZ
spObjHomeX:oHomeX spObjHomeY:oHomeY spObjHomeZ:oHomeZ spObjVelX:oVelX spObjVelY:oVelY spObjVelZ:oVelZ
spObjForwardVel:oForwardVel spObjMovePitch:oMoveAnglePitch spObjMoveYaw:oMoveAngleYaw spObjMoveRoll:oMoveAngleRoll
spObjFacePitch:oFaceAnglePitch spObjFaceYaw:oFaceAngleYaw spObjFaceRoll:oFaceAngleRoll
spObjAngleVelPitch:oAngleVelPitch spObjAngleVelYaw:oAngleVelYaw spObjAngleVelRoll:oAngleVelRoll
spObjAction:oAction spObjPrevAction:oPrevAction spObjSubAction:oSubAction spObjTimer:oTimer spObjAnimState:oAnimState
spObjFlags:oFlags spObjInteractType:oInteractType spObjInteractSubtype:oInteractionSubtype spObjInteractStatus:oInteractStatus
spObjIntangibleTimer:oIntangibleTimer spObjHealth:oHealth spObjOpacity:oOpacity spObjMoveFlags:oMoveFlags
spObjGravity:oGravity spObjFriction:oFriction spObjBuoyancy:oBuoyancy spObjBounciness:oBounciness
spObjGraphYOffset:oGraphYOffset spObjRoom:oRoom spObjAreaTimer:areaTimer
spObjAreaTimerDuration:areaTimerDuration spObjAreaTimerType:areaTimerType
]])
 
-- BOWSER_WORLD_FIELDS maps the native free-boss root. captureBowserWorldSnapshot() reads it and
-- restoreBowserWorldSnapshot() writes it; children such as the jaw/tail are intentionally never copied.
local BOWSER_WORLD_FIELDS = fieldMap(0, [[
spBowserWorldX:oPosX spBowserWorldY:oPosY spBowserWorldZ:oPosZ
spBowserWorldHomeX:oHomeX spBowserWorldHomeY:oHomeY spBowserWorldHomeZ:oHomeZ
spBowserWorldVelX:oVelX spBowserWorldVelY:oVelY spBowserWorldVelZ:oVelZ spBowserWorldForwardVel:oForwardVel
spBowserWorldMovePitch:oMoveAnglePitch spBowserWorldMoveYaw:oMoveAngleYaw spBowserWorldMoveRoll:oMoveAngleRoll
spBowserWorldFacePitch:oFaceAnglePitch spBowserWorldFaceYaw:oFaceAngleYaw spBowserWorldFaceRoll:oFaceAngleRoll
spBowserWorldAngleVelPitch:oAngleVelPitch spBowserWorldAngleVelYaw:oAngleVelYaw spBowserWorldAngleVelRoll:oAngleVelRoll
spBowserWorldAction:oAction spBowserWorldPrevAction:oPrevAction spBowserWorldSubAction:oSubAction spBowserWorldTimer:oTimer
spBowserWorldAnimState:oAnimState spBowserWorldAnim:oSoundStateID:-1 spBowserWorldHealth:oHealth
spBowserWorldOpacity:oOpacity:255 spBowserWorldMoveFlags:oMoveFlags spBowserWorldIntangible:oIntangibleTimer
spBowserWorldUnk88:oBowserUnk88 spBowserWorldF4:oBowserUnkF4 spBowserWorldF8:oBowserUnkF8
spBowserWorldDist:oBowserDistToCentre spBowserWorldUnk106:oBowserUnk106 spBowserWorldUnk108:oBowserUnk108
spBowserWorldUnk110:oBowserUnk110 spBowserWorldAngleToCentre:oBowserAngleToCentre
spBowserWorldUnk1AC:oBowserUnk1AC spBowserWorldUnk1AE:oBowserUnk1AE
spBowserWorldEyesShut:oBowserEyesShut spBowserWorldUnk1B2:oBowserUnk1B2
]])
 
-- Reports whether an object is the native Bowser behavior root.
-- Called by save/capture, clone rejection, candidate scans, and held-Bowser safety checks.
-- Why/player effect: behavior identity selects the real root instead of a jaw/tail child or Bowser-shaped model.
local function isBowserObject(o)
    return o ~= nil and objectBehaviorId(o) == id_bhvBowser
end
 
-- Reports whether the checkpoint explicitly records Mario holding Bowser.
-- Called by spawnCheckpointObject(), interaction dispatch, retry supervision, and arena-reset protection.
-- Why/player effect: a tail spin reuses the native root rather than spawning a frozen Bowser-shaped clone.
local function checkpointIsBowser(s)
    return s.spObjMode == OBJ_BOWSER
end
 
-- Reports whether the checkpoint contains a held or free Bowser snapshot.
-- Called by load() and beforeMario() when deciding whether destination setup is complete.
-- Why/player effect: entering a boss arena waits briefly for its synchronized root instead of breaking the boss.
local function checkpointHasBowserState(s)
    return checkpointIsBowser(s) or s.spBowserWorld ~= 0 end
 
-- Saves the position, movement, action, health, timers, and animation of a living free Bowser root.
-- Called by save() only when Mario is not holding Bowser. It accepts one initialized, living, free native root,
-- copies BOWSER_WORLD_FIELDS, and records the delayed timer/animation frame without touching child objects.
-- Why/player effect: Bowser returns to the saved position and attack, such as breathing fire, with his body intact.
local function captureBowserWorldSnapshot(s, o)
    if not isBowserObject(o) or not objectSyncInitialized(o)
        or o.oHeldState ~= FREE or (o.oHealth or 0) <= 0 then
        return false
    end
 
    s.spBowserWorld, s.spBowserWorldKey = 1, tonumber(objectKey(o)) or 0
    for _, f in ipairs(BOWSER_WORLD_FIELDS) do s[f[1]] = o[f[2]] ~= nil and o[f[2]] or f[3] end
    s.spBowserWorldDelayTimer = o.bhvDelayTimer or 0
    local anim = animInfo(o)
    s.spBowserWorldAnimFrame = anim and anim.animFrame or 0
    return true
end
 
-- Saves a held object, ridden shell, or held Bowser together with Mario's matching action and motion.
-- Called once by save() after it classifies Mario's current interaction. It copies OBJECT_FIELDS plus scale,
-- animation, Bob-omb fuse, Bowser-tail values, and the Mario action/motion that connects both sides.
-- Why/player effect: held items, shell movement, remaining fuse time, and Bowser spin momentum stay together.
local function captureInteraction(s, m, o, objectMode)
    s.spObjMode = objectMode
    if o == nil then return end
    s.spObjBhv = objectBehaviorId(o)
    s.spObjModel = obj_get_model_id_extended(o) or 0
    s.spObjKey = tonumber(objectKey(o)) or 0
 
    for _, f in ipairs(OBJECT_FIELDS) do s[f[1]] = o[f[2]] or 0 end
    s.spObjBhvTimer = o.bhvDelayTimer or 0
    local objAnim = animInfo(o)
    s.spObjAnimFrame = objAnim and objAnim.animFrame or 0
    local scale = o.header and o.header.gfx and o.header.gfx.scale
    s.spObjScaleX, s.spObjScaleY, s.spObjScaleZ = scale and scale.x or 1, scale and scale.y or 1, scale and scale.z or 1
 
    if s.spObjBhv == id_bhvBobomb then
        s.spBobombBlinkTimer, s.spBobombFuseLit, s.spBobombFuseTimer =
            o.oBobombBlinkTimer or 0, o.oBobombFuseLit or 0, o.oBobombFuseTimer or 0
    end
 
    if s.spObjMode == OBJ_BOWSER or isBowserObject(o) then
        s.spBowserF4 = o.oBowserUnkF4 or 0
        s.spBowserHeldPitch, s.spBowserHeldVelYaw, s.spBowserHeldStage =
            o.oBowserHeldAnglePitch or 0, o.oBowserHeldAngleVelYaw or 0, o.oBowserUnk10E or 0
    end
 
    s.spIntAction, s.spIntPrevAction = m.action or 0, m.prevAction or 0
    s.spIntActionState, s.spIntActionTimer, s.spIntActionArg = m.actionState or 0, m.actionTimer or 0, m.actionArg or 0
    s.spIntVelX, s.spIntVelY, s.spIntVelZ = m.vel.x or 0, m.vel.y or 0, m.vel.z or 0
    s.spIntForwardVel, s.spIntSlideX, s.spIntSlideZ = m.forwardVel or 0, m.slideVelX or 0, m.slideVelZ or 0
    s.spIntAngleVelX, s.spIntAngleVelY, s.spIntAngleVelZ = m.angleVel.x or 0, m.angleVel.y or 0, m.angleVel.z or 0
    s.spIntTwirlYaw = m.twirlYaw or 0
    s.spIntGrabPos = m.marioBodyState and m.marioBodyState.grabPos or 0
    local marioAnim = animInfo(m.marioObj)
    s.spIntAnimFrame = marioAnim and marioAnim.animFrame or 0
    s.spIntMarioObjPitch = m.marioObj and m.marioObj.oMoveAnglePitch or 0
end
 
---------------------------------------------------------------------------------------------------
-- Keeping each player's collectibles independent
---------------------------------------------------------------------------------------------------
 
-- Purpose:
-- This section tracks which persistent personal pickups player zero has removed in each area and recreates a
-- selected slot's view using local render/interaction rules rather than shared deletion.
-- Call flow: onInteract() records coins/1-Ups, save() encodes the current set, apply() selects a slot set,
-- refreshOwnedItems() updates visibility every third frame, and allowInteract() prevents local duplication.
-- Player effect: coins and 1-Ups match your checkpoint without hiding shared cap-block items or ridden shells from
-- other players; cap inventory and shell riding are restored by their dedicated systems instead.
 
-- Reports whether an object is a pickup whose collected state belongs to one player.
-- Called by onInteract(), allowInteract(), and refreshOwnedItems(); it accepts only coin/1-Up behavior and flags.
-- Caps and shells are deliberately excluded because they are temporary/shared interaction objects in multiplayer.
-- Why/player effect: opening a cap block or riding a shell stays visible and usable for every player.
local function isOwnedItem(o, interactType)
    if o == nil then return false end
    if interactType == INTERACT_COIN then return true end
    if obj_is_coin(o) or obj_is_mushroom_1up(o) then return true end
    local it = o.oInteractType or 0
    return (it & INTERACT_COIN) ~= 0
end
 
-- Converts a set of collected-object keys into sorted comma-separated text.
-- Called by save() once per requested slot write and never by a frame hook.
-- Why/player effect: sorting gives the same collection history a stable, compact persistent representation.
local function encodeSet(set)
    local t = {}
    for k in pairs(set or {}) do t[#t + 1] = k end
    table.sort(t)
    return table.concat(t, ",")
end
 
-- Rebuilds a fast key lookup table from the checkpoint's collected-object text.
-- Called by apply() after the destination is ready.
-- Why/player effect: constant-time lookups keep collected originals hidden/blocked without searching text.
local function decodeSet(value)
    local set = {}
    for k in tostring(value or ""):gmatch("[^,]+") do set[k] = true end
    return set
end
 
-- Makes an independent copy of a collected-object lookup table.
-- Called by apply() when turning the chosen slot into the area's new live collection history.
-- Why/player effect: future pickups change live history, not the stored slot, so repeated loads stay identical.
local function copySet(set)
    local out = {}
    for k in pairs(set or {}) do out[k] = true end
    return out
end
 
-- Returns the local collected-object set for the current area, creating one when needed.
-- Called by onInteract() and save(); it indexes collectedByArea with currentLocationKey() and creates the table
-- lazily.
-- Why/player effect: one area's pickups cannot remove a matching object somewhere else.
local function currentAreaSet()
    local k = currentLocationKey()
    if k == nil then return {} end
    collectedByArea[k] = collectedByArea[k] or {}
    return collectedByArea[k]
end
 
-- Clears all private-clone identity and source fields together.
-- Called by refreshOwnedItems() when the copy expires/changes area and by clearRestoredObject() after removal.
-- Why/player effect: a recycled engine object slot cannot be mistaken for an older checkpoint-created item.
local function clearRestoredTracking()
    restoredObject, restoredObjectKey, restoredObjectBehavior = nil, nil, nil
    restoredObjectSourceKey, restoredObjectSourceBehavior, restoredObjectLocation = nil, nil, nil
    restoredObjectSyncFrames = 0
end
 
-- Confirms that the tracked restored-object reference is still the same active object.
-- Called by refreshOwnedItems() and clearRestoredObject(); pcall guards a stale engine pointer. Ordinary clones use
-- their stable identity key, while a moving shell uses Mario's reciprocal ridden pointer because native shell logic
-- can rewrite its home position (and therefore its identity key) as the ride continues.
-- Why/player effect: repeated loads clean up only their checkpoint-created copy, never an unrelated new object.
local function restoredObjectIsLive()
    if restoredObject == nil then return false end
    local ok, live = pcall(function()
        local behavior = objectBehaviorId(restoredObject)
        local shell = behavior == id_bhvKoopaShell or behavior == id_bhvKoopaShellUnderwater
        local m = gMarioStates[0]
        return restoredObject.activeFlags ~= DEACTIVATED and behavior == restoredObjectBehavior
            and ((shell and m ~= nil and m.riddenObj == restoredObject)
                or (not shell and objectKey(restoredObject) == restoredObjectKey))
    end)
    return ok and live
end
 
-- Hides locally owned collectible originals and restores the visibility of objects no longer hidden.
-- Called immediately by apply(), after a late held-Bowser retry, and every third HOOK_UPDATE frame. It returns
-- before object-list scanning when neither a removed set nor replacement source is active. Hidden entries retain
-- behavior/key identity so a recycled object slot can never transfer old visibility flags to a new enemy or cap.
-- Why/player effect: the loaded world looks right locally without making new objects flash, vanish, or inherit state.
local function refreshOwnedItems()
    local here = currentLocationKey()
    if restoredObjectLocation ~= nil and here ~= restoredObjectLocation then
        clearRestoredTracking()
    elseif restoredObject ~= nil and not restoredObjectIsLive() then
        clearRestoredTracking()
    end
    local activeGone = here == ownedGoneLocation and ownedGone or nil
    local activeSource = here == restoredObjectLocation and restoredObjectSourceKey or nil
    local activeSourceBehavior = activeSource ~= nil and restoredObjectSourceBehavior or nil
    -- Most frames have nothing to hide; release stale graphs without scanning every object list.
    if activeSource == nil and next(activeGone or {}) == nil then
        for o, record in pairs(hiddenObjects) do
            pcall(function()
                if o.activeFlags ~= DEACTIVATED and objectBehaviorId(o) == record.behavior
                    and objectKey(o) == record.key then o.header.gfx.node.flags = record.flags end
            end)
            hiddenObjects[o] = nil
        end
        return
    end
    local m = gMarioStates[0]
    for list = 0, NUM_OBJ_LISTS - 1 do
        local o = obj_get_first(list)
        while o ~= nil do
            local nextObj = obj_get_next(o)
            local protected = o == restoredObject
                or (m ~= nil and (o == m.heldObj or o == m.riddenObj))
            local key = nil
            local shouldHide = false
            local sourceCandidate = activeSource ~= nil
                and (activeSourceBehavior == nil or activeSourceBehavior == 0 or objectBehaviorId(o) == activeSourceBehavior)
            local ownedCandidate = activeGone ~= nil and isOwnedItem(o, nil)
            if not protected and (sourceCandidate or ownedCandidate) then
                key = objectKey(o)
                shouldHide = key ~= nil and (
                    (sourceCandidate and key == activeSource)
                    or (ownedCandidate and activeGone[key])
                )
            end
            if shouldHide then
                if hiddenObjects[o] == nil then
                    hiddenObjects[o] = {flags = o.header.gfx.node.flags, behavior = objectBehaviorId(o), key = key}
                end
                o.header.gfx.node.flags = o.header.gfx.node.flags | GRAPH_RENDER_INVISIBLE
            elseif hiddenObjects[o] ~= nil then
                local record = hiddenObjects[o]
                if objectBehaviorId(o) == record.behavior and objectKey(o) == record.key then
                    o.header.gfx.node.flags = record.flags
                end
                hiddenObjects[o] = nil
            end
            o = nextObj
        end
    end
end
 
---------------------------------------------------------------------------------------------------
-- Safely replacing Mario's current interaction
---------------------------------------------------------------------------------------------------
 
-- Purpose:
-- This section contains the shared cleanup, copy, spawn, and linking building blocks used before any checkpoint
-- interaction is restored. Ordinary held objects become private clones, ridden shells are synchronized so every
-- player sees them, and Bowser always remains the arena's native synchronized root.
-- Call flow: apply() calls releaseCurrentInteraction(); the later shell/held/Bowser paths call the field, Mario,
-- pointer, tracking, and sync helpers as appropriate.
-- Player effect: an item returns in the correct pose and state without invisible leftovers, duplicate copies,
-- restarted fuses, or a stale object still attached to Mario.
 
-- Detaches and removes the held-object clone or synchronized ridden shell created by the previous load when valid.
-- Called only by releaseCurrentInteraction() at the start of apply(). It validates the reference, clears matching
-- Mario pointers through native drop/ride helpers, then asks the engine to delete that reconstructed object. A
-- same-area shell selected for immediate reuse is detached without sending the native STOP_RIDING/deletion state.
-- Why/player effect: repeated loads replace their own copy without duplicates, while reloading the shell already
-- under Mario cannot briefly tell other players that the shared shell was destroyed.
-- Publishes or clears the local player's restored-shell visual announcement.
-- releaseCurrentInteraction() clears it before every load; updateRemoteShellVisuals() clears a sustained dismount.
-- restoreShellInteraction() arms a stability wait, then updateRemoteShellVisuals() publishes after the native ride
-- has settled. One small reliable packet is sent per event, never once per frame. The owner addresses the host or
-- each client directly because CoopDX does not relay a
-- generic broadcast consistently in every server/client direction; the host forwards a client event once.
-- Why/player effect: everyone is told which remote Mario should visibly have a shell, while the owner alone keeps
-- the real interactive object used by movement and collision.
local function publishShellVisual(s, active)
    local n = gNetworkPlayers[0]
    if n == nil or n.globalIndex == nil then return end
    local wasActive = shellVisual.active
    if not active then
        shellVisual.active, shellVisual.lost, shellVisual.resend, shellVisual.pending = false, 0, 0, 0
        shellVisual.states[n.globalIndex] = nil
        if not wasActive then return end
    else
        shellVisual.serial = (shellVisual.serial % 2147483646) + 1
        shellVisual.active, shellVisual.lost = true, 0
        shellVisual.level = s ~= nil and s.spLevel or shellVisual.level
        shellVisual.area = s ~= nil and s.spArea or shellVisual.area
        shellVisual.states[n.globalIndex] = {
            token = shellVisual.serial, level = shellVisual.level, area = shellVisual.area
        }
    end
    if network_player_connected_count() > 1 then
        local packet = string.pack("<BBBBBI4", shellVisual.packet, n.globalIndex, active and 1 or 0,
            shellVisual.level, shellVisual.area, shellVisual.serial)
        if network_is_server() then
            for i = 1, MAX_PLAYERS - 1 do
                local peer = gNetworkPlayers[i]
                if peer ~= nil and peer.connected then
                    pcall(network_send_bytestring_to, i, true, packet)
                end
            end
        else
            for i = 1, MAX_PLAYERS - 1 do
                local peer = gNetworkPlayers[i]
                if peer ~= nil and peer.connected and peer.type == NPT_SERVER then
                    pcall(network_send_bytestring_to, i, true, packet)
                    break
                end
            end
        end
    end
end
 
-- Records another player's shell visual event without touching gameplay objects.
-- CoopDX calls this through HOOK_ON_PACKET_BYTESTRING_RECEIVE after a restore, dismount, or late-player resend.
-- A client event is forwarded once by the host; the regular update loop creates/removes the local model from this
-- state, keeping packet handling short and deterministic.
-- Why/player effect: a restored shell becomes visible to everyone even when native object sync drops its copy.
local function receiveShellVisualPacket(data)
    if type(data) ~= "string" or #data < 9 then return end
    local ok, packet, owner, active, level, area, token = pcall(string.unpack, "<BBBBBI4", data)
    if not ok or packet ~= shellVisual.packet then return end
    if owner < 0 or owner >= MAX_PLAYERS then return end
    if active == 1 then
        shellVisual.states[owner] = {
            token = token, level = level, area = area
        }
    else
        shellVisual.states[owner] = nil
    end
    local localNetwork = gNetworkPlayers[0]
    if network_is_server() and localNetwork ~= nil and owner ~= localNetwork.globalIndex then
        for i = 1, MAX_PLAYERS - 1 do
            local peer = gNetworkPlayers[i]
            if peer ~= nil and peer.connected then pcall(network_send_bytestring_to, i, true, data) end
        end
    end
end
 
local function clearRestoredObject(m, keep)
	
	pcall(obj_mark_for_deletion, m.heldObj) --GHETTO FIX TO STOP HELD ITEM DUPLICATION AFTER RELOADING SERVER THEN LOADING SAVE WITH A HELD OBJECT (ACTS NOT LOADING CORRECTLY)
	pcall(obj_mark_for_deletion, m.interactObj)
	pcall(obj_mark_for_deletion, m.usedObj)
	--pcall(obj_mark_for_deletion, m.riddenObj)
	--m.action = ACT_IDLE
	--m.heldObj = nil
    local old, oldLocation = restoredObject, restoredObjectLocation
    local sameLocation = oldLocation == currentLocationKey()
    local oldIsLive = sameLocation and restoredObjectIsLive()
    clearRestoredTracking()
    if old == nil or not oldIsLive then return end
 
    if old == keep then
        if m ~= nil then
            if m.heldObj == old then m.heldObj = nil end
            if m.riddenObj == old then m.riddenObj = nil end
            if m.usedObj == old then m.usedObj = nil end
            if m.interactObj == old then m.interactObj = nil end
        end
        return
    end
 
    if m ~= nil and m.heldObj == old then
        mario_drop_held_object(m)
        if m.heldObj == old then m.heldObj = nil end
    end
    if m ~= nil and m.riddenObj == old then
        mario_stop_riding_object(m)
        if m.riddenObj == old then m.riddenObj = nil end
    end
    if m ~= nil then
        if m.usedObj == old then m.usedObj = nil end
        if m.interactObj == old then m.interactObj = nil end
    end
    pcall(obj_mark_for_deletion, old)
end
 
-- Clears only the temporary Lua state used by staged Bowser pickup restoration.
-- Called by releaseCurrentInteraction(), advanceBowserRestore(), and the protected Bowser-update recovery path.
-- It resets only mod-owned phase/frame/reference values and never edits the live root.
-- Why/player effect: cancelling a restore stops its pending steps without resetting or deleting Bowser.
local function clearBowserRestoreState()
    bowserRestoreObject, bowserRestoreFrames, bowserRestoreLocation = nil, 0, nil
    bowserRestorePhase, bowserRestoreSettle = 0, 0
end
 
-- Returns Mario's current held/ridden links and the previous checkpoint clone to a clean state.
-- Called once by apply() before Mario, inventory, camera, or the selected interaction is restored. It ends staged
-- Bowser work, reveals a guarded boss, clears the old private clone, invokes native drop/ride cleanup, and nulls
-- remaining pointers. The optional keep object is a live same-area shell that restoreShellInteraction() will reuse.
-- Why/player effect: loads swap interactions without duplicate shells or stuck poses, and a reloaded shared shell
-- remains visible to everyone instead of receiving a one-frame "stop riding and delete" network message.
local function releaseCurrentInteraction(m, keep)
    publishShellVisual(nil, false)
    clearBowserRestoreState()
    if heldBowserRoot ~= nil and currentLocationKey() == heldBowserLocation then
        pcall(function()
            local node = heldBowserRoot.header.gfx.node
            node.flags = (node.flags or 0) | BOWSER_RENDER_ACTIVE
        end)
    end
    heldBowserRoot, heldBowserLocation = nil, nil
    clearRestoredObject(m, keep)
    if m.heldObj ~= nil then
        mario_drop_held_object(m)
        if m.heldObj ~= nil then m.heldObj = nil end
    end
    if m.riddenObj ~= nil then
        if m.riddenObj == keep then
            m.riddenObj = nil
        else
            mario_stop_riding_object(m)
            if m.riddenObj ~= nil then m.riddenObj = nil end
        end
    end
    m.usedObj, m.interactObj = nil, nil
end
 
-- Copies saved generic state and supported behavior-specific timers into a reconstructed object.
-- Called by shell and ordinary-held restoration after spawn. It writes OBJECT_FIELDS, delayed/animation/scale
-- state, and Bob-omb fuse fields when appropriate.
-- Why/player effect: the object behaves from the saved moment instead of merely reappearing with reset behavior.
local function restoreObjectFields(o, s)
    if o == nil or s.spObjBhv == 0 then return end
    for _, f in ipairs(OBJECT_FIELDS) do o[f[2]] = s[f[1]] end
    o.bhvDelayTimer = s.spObjBhvTimer
    local anim = animInfo(o)
    if anim ~= nil then anim.animFrame = s.spObjAnimFrame end
    local scale = o.header and o.header.gfx and o.header.gfx.scale
    if scale ~= nil then scale.x, scale.y, scale.z = s.spObjScaleX, s.spObjScaleY, s.spObjScaleZ end
 
    if s.spObjBhv == id_bhvBobomb then
        o.oBobombBlinkTimer, o.oBobombFuseLit, o.oBobombFuseTimer =
            s.spBobombBlinkTimer, s.spBobombFuseLit, s.spBobombFuseTimer
    end
end
 
-- Creates an ordinary saved object at Mario's position and seeds its spawn fields.
-- Called by restoreShellInteraction() with synchronized=true and by restoreHeldInteraction() with false. It selects
-- saved/fallback behavior and model, rejects every Bowser root, then protects the chosen engine spawn call with pcall.
-- Why/player effect: ridden shells are visible to everyone, while carried personal items stay local and can never
-- create a second shared boss.
local function spawnCheckpointObject(m, s, fallbackBhv, fallbackModel, synchronized)
    local bhv = s.spObjBhv ~= 0 and s.spObjBhv or fallbackBhv
    local model = s.spObjBhv ~= 0 and s.spObjModel or fallbackModel
    if checkpointIsBowser(s) or bhv == id_bhvBowser or model == E_MODEL_BOWSER then
        return nil
    end
    if bhv == nil or bhv == 0 or model == nil then return nil end
 
    local spawn = synchronized and spawn_sync_object or spawn_non_sync_object
    local ok, o = pcall(spawn, bhv, model, m.pos.x, m.pos.y, m.pos.z, function(obj)
        obj.oBehParams = s.spObjBehParams
        obj.oBehParams2ndByte = s.spObjBehParams2
        obj.oFlags = s.spObjFlags
        obj.oInteractType = s.spObjInteractType
        obj.oInteractionSubtype = s.spObjInteractSubtype
        obj.oHomeX, obj.oHomeY, obj.oHomeZ = s.spObjHomeX, s.spObjHomeY, s.spObjHomeZ
        obj.oHeldState = FREE
        if synchronized then restoreObjectFields(obj, s) end
    end)
    if not ok then return nil end
    return o
end
 
-- Restores Mario's action, pose, motion, angles, and animation for a held/ridden interaction.
-- Called by shell/held restoration and the later stages of a Bowser-tail restore. It chooses a safe fallback action,
-- calls set_mario_action(), restores motion/body/animation fields, and aligns camera-status action.
-- Why/player effect: Mario resumes holding, riding, or spinning instead of standing beside the restored object.
local function restoreMarioInteraction(m, s, objectMode)
    local action = s.spIntAction
    if objectMode == OBJ_SHELL and (action == 0 or (action & ACT_FLAG_RIDING_SHELL) == 0) then
        action = s.spShellAction
        if action == 0 or (action & ACT_FLAG_RIDING_SHELL) == 0 then action = ACT_RIDING_SHELL_GROUND end
    elseif objectMode == OBJ_BOWSER and action == 0 then
        action = ACT_HOLDING_BOWSER
    elseif objectMode == OBJ_HELD and action == 0 then
        action = ACT_HOLD_IDLE
    end
 
    set_mario_action(m, action, s.spIntActionArg)
    m.prevAction = s.spIntPrevAction
    m.actionState, m.actionTimer, m.actionArg = s.spIntActionState, s.spIntActionTimer, s.spIntActionArg
    m.vel.x, m.vel.y, m.vel.z = s.spIntVelX, s.spIntVelY, s.spIntVelZ
    m.forwardVel, m.slideVelX, m.slideVelZ = s.spIntForwardVel, s.spIntSlideX, s.spIntSlideZ
    m.angleVel.x, m.angleVel.y, m.angleVel.z = s.spIntAngleVelX, s.spIntAngleVelY, s.spIntAngleVelZ
    m.twirlYaw = s.spIntTwirlYaw
    if m.marioBodyState ~= nil then m.marioBodyState.grabPos = s.spIntGrabPos end
    if m.marioObj ~= nil then
        m.marioObj.oMoveAngleYaw = m.faceAngle.y
        m.marioObj.oMoveAnglePitch = s.spIntMarioObjPitch
        m.marioObj.oAngleVelYaw = m.angleVel.y
        local anim = animInfo(m.marioObj)
        if anim ~= nil then anim.animFrame = s.spIntAnimFrame end
    end
    if m.statusForCamera ~= nil then m.statusForCamera.action = action end
end
 
-- Establishes matching held-object pointers on both Mario and the object.
-- Called by ordinary-held restoration and several Bowser stages after native pickup has created internal state.
-- It writes both sides of the owner/parent/interaction relationship and makes held Bowser intangible.
-- Why/player effect: the object follows Mario and responds normally to dropping or throwing.
local function linkHeldObject(m, o, bowserHeld)
    o.oHeldState, o.heldByPlayerIndex, o.parentObj = HELD, 0, m.marioObj
    if bowserHeld then o.oIntangibleTimer = -1 end
    m.heldObj, m.usedObj, m.interactObj = o, o, o
end
 
-- Records the restored clone, the original object's identity, and the area where both belong.
-- Called immediately after a shell or ordinary-held clone spawns. refreshOwnedItems(), allowInteract(), and later
-- cleanup consume these references and stable identities.
-- Why/player effect: the playable copy remains visible while its matching native original stays hidden locally.
local function trackRestoredObject(o, s)
    restoredObject = o
    restoredObjectKey, restoredObjectBehavior = objectKey(o), objectBehaviorId(o)
    restoredObjectSourceKey = s.spObjKey ~= 0 and tostring(s.spObjKey) or restoredObjectKey
    restoredObjectSourceBehavior = s.spObjBhv ~= 0 and s.spObjBhv or restoredObjectBehavior
    restoredObjectLocation = locationKey(s.spLevel, s.spArea)
end
 
-- Sends an updated synchronized object only after its CoopDX sync slot is ready.
-- Called by free/held Bowser restoration and ridden-shell restoration after changing synchronized state; private
-- held clones never reach this helper. It protects the send with readiness checking and pcall.
-- Why/player effect: everyone sees the same working Bowser and ridden shell while carried personal items stay local.
local function sendObjectSync(o, reliable)
    if not objectSyncInitialized(o) then return false end
    local ok = pcall(network_send_object, o, reliable == true)
    return ok
end
 
---------------------------------------------------------------------------------------------------
-- Resuming a Bowser fight without duplicating the boss
---------------------------------------------------------------------------------------------------
 
-- Purpose:
-- Bowser cannot be cloned like an item: each arena creates one synchronized root whose body, tail, jaw, attacks,
-- and fight rules form a native hierarchy. This section edits only that root and uses the real pickup sequence.
-- Call flow: load/beforeMario() wait for findBowserForCheckpoint(); apply() restores free or held state;
-- updateBowserRuntime()/updateBowserRetries() finish any engine work that becomes ready on later frames.
-- Player effect: a fight resumes without duplicate bosses, detached parts, missing tails, or frozen throws.
 
-- Finds the best active native Bowser root for this checkpoint.
-- Called by save(), load readiness checks, and both held/free restore paths. It scans only Bowser behavior roots,
-- prefers sync-ready and identity-matching candidates, and rejects an incomplete root in a standard arena.
-- Why/player effect: network arrival order cannot make the mod edit a child/partial boss or create a replacement.
local function findBowserForCheckpoint(s)
    local wantedValue = s.spBowserWorld ~= 0 and s.spBowserWorldKey or s.spObjKey
    local wanted = wantedValue ~= 0 and tostring(wantedValue) or nil
    local selected, bestScore = nil, -1
    local o = obj_get_first_with_behavior_id(id_bhvBowser)
    while o ~= nil do
        if o.activeFlags ~= DEACTIVATED then
            local score = (objectSyncInitialized(o) and 100 or 0)
                + (wanted ~= nil and objectKey(o) == wanted and 1 or 0)
            local syncId, selectedSyncId = o.oSyncID or 0, selected and (selected.oSyncID or 0) or 0
            if score > bestScore or (score == bestScore and syncId ~= 0
                and (selectedSyncId == 0 or syncId < selectedSyncId)) then
                selected, bestScore = o, score
            end
        end
        o = obj_get_next_with_same_behavior_id(o)
    end
    if selected == nil then return nil end
 
    -- Reject partial vanilla roots; touching them corrupts native child anchors.
    local level = s.spLevel
    local singleBossArena = level == LEVEL_BOWSER_1 or level == LEVEL_BOWSER_2 or level == LEVEL_BOWSER_3
    if singleBossArena and not objectSyncInitialized(selected) then return nil end
    return selected
end
 
-- Restores a free Bowser's position, movement, action, health, timers, and animation.
-- Called by apply() and updateBowserRetries(). It selects the native root, refuses one held by another player,
-- writes BOWSER_WORLD_FIELDS, schedules a one-frame animation correction, reveals, and synchronizes the root.
-- Why/player effect: Bowser returns where he was and continues his attack with the native hierarchy intact.
local function restoreBowserWorldSnapshot(s)
    if s.spBowserWorld == 0 then return true end
    local o = findBowserForCheckpoint(s)
    if o == nil then return false end
    if o.oHeldState == HELD and (o.heldByPlayerIndex or 0) ~= 0 then return false end
    -- Root-only restoration preserves the native body, jaw, flame, and tail children.
    for _, f in ipairs(BOWSER_WORLD_FIELDS) do o[f[2]] = s[f[1]] end --o.oAction = 5
    o.bhvDelayTimer = s.spBowserWorldDelayTimer
    o.oHeldState, o.heldByPlayerIndex, o.parentObj, o.oInteractStatus = FREE, 0, o, 0
    local anim = animInfo(o)
    if anim ~= nil then anim.animFrame = s.spBowserWorldAnimFrame end
    bowserWorldAnimObject = o
    bowserWorldAnimLocation = locationKey(s.spLevel, s.spArea)
    bowserWorldAnimFrame = s.spBowserWorldAnimFrame
    pcall(function()
        local node = o.header and o.header.gfx and o.header.gfx.node
        if node ~= nil then node.flags = (node.flags or 0) | BOWSER_RENDER_ACTIVE end
    end)
    sendObjectSync(o)
    return true
end
 
-- Changes only Bowser's root-model visibility bit inside pcall.
-- Called by the held-graph helper, its per-frame guard, and failure cleanup. It edits only the graphics-node bit,
-- never behavior or fight state, and protects stale graphics data with pcall.
-- Why/player effect: held and world rendering cannot draw two overlapping Bowsers.
local function setBowserWorldGraphActive(o, active)
    if o == nil then return false end
    local ok = pcall(function()
        local node = o.header and o.header.gfx and o.header.gfx.node
        if node == nil or type(node.flags) ~= "number" then return end
        node.flags = active and (node.flags | BOWSER_RENDER_ACTIVE) or (node.flags & ~BOWSER_RENDER_ACTIVE)
    end)
    return ok
end
 
-- Hides the world copy while Mario's held-object path draws Bowser and makes the root intangible.
-- Called during initial, staged, finished, and maintained tail attachment. It delegates visibility and disables
-- collision while native boss behavior continues.
-- Why/player effect: spinning shows one connected Bowser that can still be released or thrown normally.
local function hideHeldBowserWorldGraph(o)
    setBowserWorldGraphActive(o, false)
    if o ~= nil then o.oIntangibleTimer = -1 end
end
 
-- Maintains the temporary held-Bowser visibility guard and retires it when the hold ends.
-- Called by updateBowserRuntime() only while heldBowserRoot exists. Every frame it validates location/liveness and
-- the reciprocal held link, rehides a rewritten graph, or reveals/forgets the root after release.
-- Why/player effect: Bowser stays singular while spinning and becomes visible immediately after a throw.
local function maintainHeldBowserWorldGraph()
    local o = heldBowserRoot
    if o == nil then return end
    local m = gMarioStates[0]
    local here = currentLocationKey()
    if m == nil or o.activeFlags == DEACTIVATED
        or here ~= heldBowserLocation then
        heldBowserRoot, heldBowserLocation = nil, nil
        return
    end
    if m.heldObj == o and o.oHeldState == HELD then
        hideHeldBowserWorldGraph(o)
    else
        setBowserWorldGraphActive(o, true)
        heldBowserRoot, heldBowserLocation = nil, nil
    end
end
 
-- Reapplies the saved free-Bowser animation frame one update after restoring his action.
-- Called by updateBowserRuntime() when restoreBowserWorldSnapshot() has scheduled a root. It validates the root
-- and area, writes the saved frame once after native action setup, then clears its own record.
-- Why/player effect: a restored attack continues at the saved animation moment instead of visibly restarting.
local function finishBowserWorldAnimationRestore()
    local o = bowserWorldAnimObject
    if o == nil then return end
    if o.activeFlags == DEACTIVATED
        or currentLocationKey() ~= bowserWorldAnimLocation then
        bowserWorldAnimObject, bowserWorldAnimLocation, bowserWorldAnimFrame = nil, nil, 0
        return
    end
 
    local anim = animInfo(o)
    if anim ~= nil then anim.animFrame = bowserWorldAnimFrame end
    bowserWorldAnimObject, bowserWorldAnimLocation, bowserWorldAnimFrame = nil, nil, 0
end
 
-- Restores held-tail values that native pickup does not reconstruct, including tail angle and spin speed.
-- Called before native pickup and again when advanceBowserRestore() reaches the safe held stage. It writes only
-- supported health/appearance/tail-motion fields and deliberately leaves action transitions to the engine.
-- Why/player effect: spin angle/momentum return without freezing Bowser's release, throw, or respawn logic.
local function restoreBowserHeldSnapshot(o, s)
    o.oHealth, o.oOpacity, o.oBowserUnkF4 = s.spObjHealth, s.spObjOpacity, s.spBowserF4
    o.oBowserHeldAnglePitch, o.oBowserHeldAngleVelYaw = s.spBowserHeldPitch, s.spBowserHeldVelYaw
    o.oMoveFlags = 0
end
 
-- Advances native pickup, native holding, saved-spin restoration, and settlement across a few frames.
-- Called inside updateBowserRuntime() only while bowserRestoreObject is active. It validates the area/root, repairs
-- temporary link loss, moves through GRAB/HELD/SETTLE phases, and applies exact saved motion when native stage is
-- ready.
-- Why/player effect: staged setup prevents missing tails, disappearing bosses, and frozen throws.
local function advanceBowserRestore()
    local o = bowserRestoreObject
    if o == nil then return end
 
    local m, n, s = gMarioStates[0], gNetworkPlayers[0], localCheckpoint
    local area = playerArea(m, n)
    if m == nil or n == nil or o.activeFlags == DEACTIVATED
        or currentLocationKey() ~= bowserRestoreLocation
        or n.currLevelNum ~= s.spLevel or area ~= s.spArea then
        clearBowserRestoreState()
        return
    end
 
    bowserRestoreFrames = bowserRestoreFrames + 1
    -- Repair reciprocal links that native pickup may clear for one frame.
    if m.heldObj ~= o then
        o.oHeldState = FREE
        m.usedObj, m.interactObj = o, o
        pcall(mario_grab_used_object, m)
    end
    if m.heldObj ~= o then
        if bowserRestoreFrames >= 45 then
            clearBowserRestoreState()
        end
        return
    end
 
    linkHeldObject(m, o, true)
    hideHeldBowserWorldGraph(o)
 
    if bowserRestorePhase == BOWSER_RESTORE_GRAB then
        if m.action == ACT_PICKING_UP_BOWSER then
            -- Let native pickup initialize once, then finish its animation quickly.
            local anim = animInfo(m.marioObj)
            local cur = anim and anim.curAnim
            if bowserRestoreFrames > 1 and cur ~= nil then
                anim.animFrame = math.max((cur.loopEnd or 2) - 2, 0)
            end
        elseif m.action == ACT_HOLDING_BOWSER then
            bowserRestorePhase = BOWSER_RESTORE_HELD
        else
            set_mario_action(m, ACT_PICKING_UP_BOWSER, 0)
            m.actionState, m.actionTimer, m.actionArg = 1, 0, 0
        end
        if bowserRestoreFrames >= 12 and m.action ~= ACT_HOLDING_BOWSER then
            set_mario_action(m, ACT_HOLDING_BOWSER, 0)
            bowserRestorePhase = BOWSER_RESTORE_HELD
        end
        return
    end
 
    if bowserRestorePhase == BOWSER_RESTORE_SETTLE then
        if m.action ~= ACT_HOLDING_BOWSER then restoreMarioInteraction(m, s, OBJ_BOWSER) end
        bowserRestoreSettle = bowserRestoreSettle - 1
        if bowserRestoreSettle <= 0 then clearBowserRestoreState() end
        return
    end
 
    if m.action ~= ACT_HOLDING_BOWSER then set_mario_action(m, ACT_HOLDING_BOWSER, 0) end
    local targetStage = s.spBowserHeldStage
    local stage = o.oBowserUnk10E or 0
    if stage == 1 and targetStage >= 2 then
        -- Advance stage 1 through its native animation transition.
        local anim = animInfo(o)
        local cur = anim and anim.curAnim
        if cur ~= nil and anim ~= nil then anim.animFrame = math.max((cur.loopEnd or 2) - 2, 0) end
        return
    end
 
    if (targetStage <= 1 and stage >= targetStage) or stage >= 2 or bowserRestoreFrames >= 45 then
        restoreMarioInteraction(m, s, OBJ_BOWSER)
        restoreBowserHeldSnapshot(o, s)
        linkHeldObject(m, o, true)
        hideHeldBowserWorldGraph(o)
        sendObjectSync(o)
        bowserRestorePhase, bowserRestoreSettle = BOWSER_RESTORE_SETTLE, 3
    end
end
 
-- Selects the ready native Bowser, begins his genuine pickup routine, and arms the staged restore.
-- Called by restoreCheckpointInteraction() during apply() and updateBowserRetries() if the synchronized root
-- arrived late. It prepares both interaction endpoints and lets advanceBowserRestore() finish over safe frames.
-- Why/player effect: native setup preserves the complete boss hierarchy, so tail spinning and throwing work.
local function restoreBowserInteraction(m, s)
    local o = findBowserForCheckpoint(s)
    if o == nil then return false end
    if o.oHeldState == HELD and (o.heldByPlayerIndex or 0) ~= 0 then return false end
    if m.heldObj ~= nil and m.heldObj ~= o then pcall(mario_drop_held_object, m) end
    restoreBowserHeldSnapshot(o, s)
    o.oHeldState = FREE
    o.oInteractType = (o.oInteractType or 0) | INTERACT_GRABBABLE
    o.heldByPlayerIndex, o.oBowserUnk10E = 0, 0
    m.heldObj = nil
    m.usedObj, m.interactObj = o, o
    set_mario_action(m, ACT_PICKING_UP_BOWSER, 0)
    m.actionState, m.actionTimer, m.actionArg = 0, 0, 0
    if m.marioBodyState ~= nil then m.marioBodyState.grabPos = s.spIntGrabPos end
    pcall(mario_grab_used_object, m)
    if m.heldObj ~= o then return false end
    linkHeldObject(m, o, true)
    heldBowserRoot, heldBowserLocation = o, locationKey(s.spLevel, s.spArea)
    hideHeldBowserWorldGraph(o)
    if o.oHeldState ~= HELD then return false end
    if m.marioObj ~= nil then
        m.marioObj.oMoveAnglePitch = s.spBowserHeldPitch
        m.marioObj.oAngleVelYaw = s.spIntAngleVelY
    end
    bowserRestoreObject = o
    bowserRestoreFrames = 0
    bowserRestoreLocation = locationKey(s.spLevel, s.spArea)
    bowserRestorePhase, bowserRestoreSettle = BOWSER_RESTORE_GRAB, 0
    sendObjectSync(o)
    bowserTime = 0
    return true
end
 
---------------------------------------------------------------------------------------------------
-- Rebuilding ridden shells and ordinary held items
---------------------------------------------------------------------------------------------------
 
-- Purpose:
-- These final interaction paths use private clones for carried objects, synchronized shells for riding, and Bowser's
-- native-root
-- path above. apply() calls the dispatcher only after cleanup, Mario placement, inventory, timer, and camera setup.
-- Player effect: carried items remain personal, while every player can see a restored shell being ridden.
 
-- Recreates the saved land or underwater shell as one synchronized replacement and reconnects Mario's ridden state.
-- Called by restoreCheckpointInteraction() for OBJ_SHELL after releaseCurrentInteraction() has ended the previous
-- ride. It uses a minimal native spawn payload, restores remaining fields locally, links Mario, tracks the replacement,
-- and retries its first object send if CoopDX has not assigned the new network slot yet.
-- Why/player effect: the old shared shell disappears normally and exactly one fully restored replacement becomes
-- visible under Mario for every player, including when loading repeatedly or from another level.
local function restoreShellInteraction(m, s)
    local bhv = id_bhvKoopaShell
    if s.spShellWater ~= 0 then bhv = id_bhvKoopaShellUnderwater end
    -- Use stable native identifiers and a minimal spawn payload. Saved model/behavior values and the full generic
    -- field set are valid locally, but placing all of them in the spawn callback can make peers reject the object.
    local ok, shell = pcall(spawn_sync_object, bhv, E_MODEL_KOOPA_SHELL, --spawn_sync_object SHELL DOESN'T SPAWN FIRST GO WHEN RELOADING INTO LEVEL FROM OUTSIDE IT
        m.pos.x, m.pos.y, m.pos.z, function(obj)
            obj.oBehParams, obj.oBehParams2ndByte = s.spObjBehParams, s.spObjBehParams2
            obj.oAction, obj.oInteractStatus, obj.oHeldState = s.spObjAction, 0, FREE
            obj.heldByPlayerIndex = 0
        end)
    if not ok then shell = nil end
    if shell == nil then return false end
    restoreObjectFields(shell, s)
    shell.oHeldState, shell.heldByPlayerIndex = FREE, 0
    m.interactObj, m.usedObj, m.riddenObj = shell, shell, shell
    trackRestoredObject(shell, s)
    restoreMarioInteraction(m, s, OBJ_SHELL)
	soft_reset_camera(m.area.camera) --RESET MARIOS CAMERA SO IF LOADING A SAVE WITH A SHELL OVER QUICKSAND FROM OUTSIDE THE LEVEL IT DOESNT GET STUCK IN A SHAKY CAM EFFECT
    -- Native shell setup can briefly drop Mario's ridden pointer after this function returns. Publish only after
    -- updateRemoteShellVisuals() observes thirty consecutive fully-riding frames.
    shellVisual.pending = 30
    if not sendObjectSync(shell, true) then restoredObjectSyncFrames = 30 end
	invulnerable = false
    play_shell_music()
    return true
end
 
-- Recreates an ordinary carryable locally, passes it through native grab setup, and restores both ends.
-- Called by restoreCheckpointInteraction() from apply() only for OBJ_HELD checkpoints. It spawns and tracks the
-- local copy, primes Mario's interaction pointers, invokes mario_grab_used_object(), then restores saved fields.
-- Why/player effect: boxes, Bob-ombs, and other items behave as genuinely held objects without becoming shared.
local function restoreHeldInteraction(m, s)
    local o = spawnCheckpointObject(m, s, nil, nil, false)
    if o == nil then return false end
    trackRestoredObject(o, s)
    o.oHeldState = FREE
    o.oInteractType = s.spObjInteractType | INTERACT_GRABBABLE
    o.heldByPlayerIndex = 0
    m.heldObj = nil
    m.usedObj, m.interactObj = o, o
    mario_grab_used_object(m)
    restoreObjectFields(o, s)
    linkHeldObject(m, o, false)
    restoreMarioInteraction(m, s, OBJ_HELD)
    if objectBehaviorId(o) == id_bhvKoopaShellUnderwater then play_shell_music() end
    return true
end
 
-- Dispatches the checkpoint's interaction mode to the shell, ordinary-item, or native Bowser path.
-- Called once by apply(). OBJ_NONE ends immediately; shells use synchronized copies, held objects use private ones,
-- and Bowser uses the native root inside pcall so an engine edge case cannot stop the rest of the mod.
-- Why/player effect: each saved interaction returns through the engine-safe path for that object type.
local function restoreCheckpointInteraction(m, s)
    local objectMode = s.spObjMode
    if objectMode == OBJ_NONE then return true end
    if objectMode == OBJ_SHELL then return restoreShellInteraction(m, s) end
    if objectMode == OBJ_BOWSER then
        local ok, restored = pcall(restoreBowserInteraction, m, s)
        return ok and restored or false
    end
    if objectMode == OBJ_HELD then return restoreHeldInteraction(m, s) end
    return true
end
 
---------------------------------------------------------------------------------------------------
-- Returning to the saved place, view, time, and world state
---------------------------------------------------------------------------------------------------
 
-- Purpose:
-- This section owns the complete slot capture/apply pipeline plus the position, camera, and timer helpers it uses.
-- Call flow: marioUpdate() calls save()/load(); load() applies immediately or asks requestWarp()/beforeMario() to
-- wait; apply() restores subsystems in a strict order and arms only the delayed work the engine still requires.
-- Player effect: saves return to the same place and view, Princess's Slide times do not mix between players,
-- and Koopa's race keeps moving normally for everyone.
 
-- Clears every temporary flag used by an in-progress cross-area load.
-- Called after apply(), after a cancelled/replaced input, and when updatePendingLoad() exhausts recovery. It resets
-- mode, timeout, consecutive ready frames, and last-observed destination together.
-- Why/player effect: completed/cancelled/failed work cannot contaminate the next load request.
local function resetLoad()
    loadMode, timer, retries, lastLevel, lastArea = LOAD_NONE, 0, 0, nil, nil
end
 
-- Returns the saved coordinates with a small safety offset only beside an instant-warp surface.
-- Called only by apply(). It returns ordinary coordinates unchanged, or moves opposite the recorded displacement
-- (saved facing is the fallback) when the slot was on an instant-warp boundary.
-- Why/player effect: Mario lands on the intended side instead of instantly triggering the same warp again.
 
-- Camera helpers below are called only during save/apply and a few late camera passes. They never alter the
-- player's Free Camera/Analog Camera settings; only the view produced by those settings belongs to a slot.
local function checkpointPos(s)
    local x, y, z = s.spX, s.spY, s.spZ
    if s.spIW == 0 then return x, y, z end
    local sx, sy, sz = sign(s.spDX), sign(s.spDY), sign(s.spDZ)
    if sx ~= 0 or sy ~= 0 or sz ~= 0 then
        x, y, z = x - sx * IW_OFFSET, y - sy * math.min(IW_OFFSET, 80), z - sz * IW_OFFSET
    else
        local a = s.spAngleY
        x, z = x - sins(a) * IW_OFFSET, z - coss(a) * IW_OFFSET
    end
    return x, y, z
end
 
-- Writes x, y, and z into an existing engine camera vector.
-- Called repeatedly by restoreCameraView() for Camera and Lakitu current/goal/render vectors. It edits members
-- rather than replacing engine-owned vector objects.
-- Why/player effect: every camera point agrees immediately, so the loaded view cannot drift from an old target.
local function setCameraVector(v, x, y, z)
    if v == nil then return end
    v.x, v.y, v.z = x or 0, y or 0, z or 0
end
 
-- Captures the rendered camera position, focus, direction, distance, and smoothing values.
-- Called once by save(). It reads local Camera/LakituState, leaves the fresh snapshot invalid if unavailable,
-- and stores the rendered view without storing camera-control preferences.
-- Why/player effect: the exact view is remembered while the player's chosen camera mode remains unchanged.
local function captureCameraView(s, m)
    local c, l = m.area and m.area.camera, gLakituState
    if c == nil or l == nil or l.pos == nil or l.focus == nil then return end
    s.spCamValid = 1
    s.spCamPosX, s.spCamPosY, s.spCamPosZ = l.pos.x, l.pos.y, l.pos.z
    s.spCamFocusX, s.spCamFocusY, s.spCamFocusZ = l.focus.x, l.focus.y, l.focus.z
    s.spCamYaw, s.spCamNextYaw = c.yaw or l.yaw or 0, c.nextYaw or l.nextYaw or 0
    s.spCamOldPitch, s.spCamOldYaw, s.spCamFocusDistance = l.oldPitch or 0, l.oldYaw or 0, l.focusDistance or 0
    s.spCamFocHSpeed, s.spCamFocVSpeed = l.focHSpeed or 0.8, l.focVSpeed or 0.3
    s.spCamPosHSpeed, s.spCamPosVSpeed = l.posHSpeed or 0.3, l.posVSpeed or 0.3
end
 
-- Restores every current/target camera vector plus its saved angle, distance, and smoothing state.
-- Called by apply() immediately after soft_reset_camera() and briefly by latePlayModeRestore() after engine camera
-- work. It primes every vector/value and skips renderer interpolation until transition/water setup has settled.
-- Why/player effect: the view cuts directly to its saved angle instead of slowly panning through terrain.
 
-- Timer helpers below separate a local Princess's Slide clock from the one native Koopa race shared by the lobby.
-- save()/apply() decide ownership; Mario/update/play-mode callbacks advance or redraw only the local override.
local function restoreCameraView(s, m)
    local c, l = m and m.area and m.area.camera, gLakituState
    if s.spCamValid == 0 or c == nil or l == nil then return false end
    local px, py, pz = s.spCamPosX, s.spCamPosY, s.spCamPosZ
    local fx, fy, fz = s.spCamFocusX, s.spCamFocusY, s.spCamFocusZ
    setCameraVector(c.pos, px, py, pz); setCameraVector(c.focus, fx, fy, fz)
    setCameraVector(l.curPos, px, py, pz); setCameraVector(l.goalPos, px, py, pz); setCameraVector(l.pos, px, py, pz)
    setCameraVector(l.curFocus, fx, fy, fz); setCameraVector(l.goalFocus, fx, fy, fz); setCameraVector(l.focus, fx, fy, fz)
    c.yaw, c.nextYaw = s.spCamYaw, s.spCamNextYaw
    l.yaw, l.nextYaw = c.yaw, c.nextYaw
    l.oldPitch, l.oldYaw, l.focusDistance = s.spCamOldPitch, s.spCamOldYaw, s.spCamFocusDistance
    l.focHSpeed, l.focVSpeed = s.spCamFocHSpeed, s.spCamFocVSpeed
    l.posHSpeed, l.posVSpeed = s.spCamPosHSpeed, s.spCamPosVSpeed
    skip_camera_interpolation()
	--djui_chat_message_create("RESTORE CAM")
	--soft_reset_camera(m.area.camera) --RESET CAMERA TO STOP ZOOMED OUT ISSUES WHEN RESPAWNING INTOP A LEVEL FROM OUTSIDE OF IT
    return true
end
 
-- Reports whether the single lobby-wide Koopa the Quick race is currently active.
-- Called by save() and apply(). It reads the synchronized endpoint's begun/status fields without modifying them.
-- Why/player effect: checkpoint positions may load, but Koopa, his finish state, and the shared clock never rewind.
local function koopaRaceActive()
    local endpoint = obj_get_first_with_behavior_id(id_bhvKoopaRaceEndpoint)
    return endpoint ~= nil
        and (endpoint.oKoopaRaceEndpointRaceBegun or 0) ~= 0
        and (endpoint.oKoopaRaceEndpointRaceStatus or 0) == 0
end
 
-- Writes the private timer value and makes it visible on the local HUD.
-- Called when slide surfaces change the clock, during apply(), and by the pre-Mario/normal/late callbacks. Only
-- updateRaceTimer() advances the value; other callers reassert it where engine phases may overwrite the HUD.
-- Why/player effect: Princess's Slide consistently displays this player's exact restored time.
local function showRaceTimer(value)
    hud_set_value(HUD_DISPLAY_TIMER, value)
    --hud_set_value(HUD_DISPLAY_FLAGS, hud_get_value(HUD_DISPLAY_FLAGS) | HUD_DISPLAY_FLAG_TIMER)
end
 
-- Checks whether player zero remains in the level/area that owns the private timer.
-- Called by beforeMario(), updateRaceTimer(), and latePlayModeRestore() so all phases share one boundary rule.
-- Why/player effect: a slide clock follows this player only while they remain in that slide.
local function inPrivateTimerArea(m, n)
    return n ~= nil and n.currLevelNum == raceTimerLevel and playerArea(m, n) == raceTimerArea
end
 
-- Ends the private timer override and forgets which level/area owned it.
-- Called by save/apply/updateRaceTimer(). Passing false clears only the private state when Koopa owns the native
-- timer; otherwise the local HUD is hidden and optional non-slide native timer control is stopped when available.
-- Why/player effect: leaving a slide clears its clock without resetting another player's or Koopa's race.
local function clearRaceTimerOverride(hideNative)
    local n = gNetworkPlayers[0]
    local privateSlide = raceTimerLevel == LEVEL_PSS or (n ~= nil and n.currLevelNum == LEVEL_PSS)
    raceTimerOverride, raceTimerRunning = false, false
    raceTimerValue, raceTimerHold = 0, 0
    raceTimerLevel, raceTimerArea = -1, -1
    if hideNative == false then return end
    if not privateSlide and level_control_timer ~= nil then level_control_timer(TIMER_CONTROL_HIDE) end
    --hud_set_value(HUD_DISPLAY_FLAGS, hud_get_value(HUD_DISPLAY_FLAGS) & ~HUD_DISPLAY_FLAG_TIMER)
end
 
-- Watches only local Mario's Princess's Slide start and finish surfaces.
-- Called every local marioUpdate() before input handling. A start surface creates/resets this client's override;
-- its matching finish surface freezes it. It never observes another Mario or the shared running flag.
-- Why/player effect: another player's run, save/load, arrival, or departure cannot alter this player's clock.
local function updatePrivateSlideSurface(m)
    local n = gNetworkPlayers[0]
    if n == nil or n.currLevelNum ~= LEVEL_PSS then return end
	--if tempSLevel == nil and n ~= nil then
			--if m.floor.type == SURFACE_TIMER_START then --FIND OUR TIMER LEVEL STARTING POINT HERE
			--djui_chat_message_create("FOUND START TIMER")
			--local area, floorType = playerArea(m, n), m.floor and m.floor.type
			--tempSSX, tempSSY, tempSSZ, tempSLevel, tempArea, tempAct = m.pos.x, m.pos.y, m.pos.z, n.currLevelNum, playerArea(m, n), n.currActNum 
			--area = nil 
			--floorType = nil
			--end 
	--return 
	--end
	
	--local s = localCheckpoints[slot]
	--m, s
	--if inTimer ~= true then return end
	--if s.spSLevel ~= n.currLevelNum then s = nil return end --IF SPSLEVEL DOES NOT MATCH THE CURRENT LEVEL JUST RETURN
	
    local area, floorType = playerArea(m, n), m.floor and m.floor.type
    if floorType == SURFACE_TIMER_START then
	tempSSX, tempSSY, tempSSZ, tempSLevel, tempArea, tempAct = m.pos.x, m.pos.y, m.pos.z, n.currLevelNum, playerArea(m, n), n.currActNum --SET SLIDES SURFACE_TIMER_START LOCATION & LEVEL WHICH ITS IN
	--djui_chat_message_create("SAVED SLIDE START LOCATION")
        if not raceTimerOverride or not raceTimerRunning
            or raceTimerLevel ~= n.currLevelNum or raceTimerArea ~= area then
            raceTimerOverride, raceTimerRunning = true, true
            --raceTimerValue, raceTimerHold = 0, 1
			raceTimerHold = 1
            raceTimerLevel, raceTimerArea = n.currLevelNum, area
            showRaceTimer(0)
        end
    elseif floorType == SURFACE_TIMER_END and raceTimerOverride
        and raceTimerLevel == n.currLevelNum and raceTimerArea == area then
		refreshSlide = 1 --IF WE PASS THE END POINT IN SLIDE RACE SET REFRESH TIMER TO 1 SO WE CAN RELOAD THE ENTIRE LEVEL AT START WHEN NEEDED
        raceTimerRunning = false
        showRaceTimer(raceTimerValue)
    end
end

local function refreshSlideFunc(m) --GHETTO SLIDE FIX CODE (HAS LOADING SAVEPOINT BUGS) (WORKS AFTER LOADING SAVE WHEN HITTING SURFACE_TIMER_END AFTER SERVER RELOAD)

	--if slot == nil then slot = DEFAULT_SLOT end
	--if refreshSlide == 1 or tempSSX == nil then djui_chat_message_create("WARPING BACK") warp_to_warpnode(s.spSLevel, s.spSArea, s.spSAct, WARP_NODE_DEATH) refreshSlide = 2 end

	--local s, n = localCheckpoints[slot], gNetworkPlayers[0]
	local s, n = localCheckpoint, gNetworkPlayers[0]
	
	--djui_chat_message_create("RUNNING SLIDE")
	
	--if s.spSSX == nil then return end
	
	
	if refreshSlide > 1 then
	
		refreshSlide = refreshSlide + 1
	
		if refreshSlide == 3 then
		--djui_chat_message_create(tostring(s.spSSX))

		m.pos.x, m.pos.y, m.pos.z = s.spSSX, s.spSSY, s.spSSZ
		--refreshSlide = 0
		end
		
		if refreshSlide >= 4 then
		local x, y, z = checkpointPos(s)
		m.pos.x, m.pos.y, m.pos.z = x, y, z
		if raceTimerValue <= 3 then raceTimerRunning = false end --STOP TIMER IF SPAWNING OUTSIDE THE SLIDE/RACE BUT FROM ALSO INSIDE THE LEVEL
		refreshSlide = 0
		end
	end

	if refreshSlide == 1 then warp_to_warpnode(s.spSLevel, s.spSArea, s.spSAct, WARP_NODE_DEATH) refreshSlide = 2 end
	
	--if refreshSlide ~= 0 then refreshSlide(m, slot) end

end
 
-- Applies the complete in-memory checkpoint after the correct level and area are ready.
-- Called directly by load() for a ready same-area slot or by beforeMario() after a destination warp. It performs
-- cleanup, Mario/graph position, inventory, collectibles, timer ownership, safe land/water/air action, camera,
-- interactions, free Bowser, visibility, effects, and load reset in that exact order.
-- Why/player effect: this is the step that actually puts the player, nearby objects, timer, and view back exactly
-- as they were when the game was saved, so loading feels like returning to that moment rather than restarting it.
local function apply(m)
    local s = localCheckpoint
    if s == nil then resetLoad() return end
 
    interactionRetryFrames, bowserWorldRetryFrames = 0, 0
    shellRestoreFrames, shellRestoreAttempts = 0, 0
    bowserWorldAnimObject, bowserWorldAnimLocation, bowserWorldAnimFrame = nil, nil, 0
    -- Discard a previous load's unconsumed instant-warp guard.
    guardFrames = 0
    --local deferShell = s.spObjMode == OBJ_SHELL and m.riddenObj ~= nil
	local deferShell = s.spObjMode == OBJ_SHELL and (m.riddenObj ~= nil or loadMode ~= LOAD_NONE)
    releaseCurrentInteraction(m)
	if s.spObjMode == 2.0 then
	invulnerable = true
	else
	invulnerable = false
	end
 
    local x, y, z = checkpointPos(s)
    m.pos.x, m.pos.y, m.pos.z = x, y, z
    m.faceAngle.x, m.faceAngle.y, m.faceAngle.z = s.spAngleX, s.spAngleY, s.spAngleZ
    m.vel.x, m.vel.y, m.vel.z, m.forwardVel, m.slideVelX, m.slideVelZ = 0, 0, 0, 0, 0, 0
    -- Sync Mario's graph immediately to prevent repeated-load Y drift.
    if m.marioObj ~= nil then
        m.marioObj.oPosX, m.marioObj.oPosY, m.marioObj.oPosZ = x, y, z
        m.marioObj.oMoveAngleYaw = s.spAngleY
    end
	--djui_chat_message_create(tostring(s.spSSX))
    if m.area ~= nil then m.area.numRedCoins, m.area.numSecrets = s.spRedCoins, s.spSecrets end
    if keepCoins then m.numCoins = s.spCoins end
    m.numLives, m.numKeys = s.spLives, s.spKeys
    local capMask = MARIO_CAPS | MARIO_CAP_ON_HEAD | MARIO_CAP_IN_HAND
    m.flags = (m.flags & ~capMask) | (s.spCapFlags & capMask)
    m.capTimer = s.spCapTimer
 
    ownedGone, ownedGoneLocation = decodeSet(s.spGone), locationKey(s.spLevel, s.spArea)
    collectedByArea[ownedGoneLocation] = copySet(ownedGone)
    worldScanTicker = 0
 
    -- A shared Koopa race owns its timer and moving Koopa; loading changes Mario only.
    if koopaRaceActive() or s.spSharedRace ~= 0 then
        clearRaceTimerOverride(false)
    else
        -- Independent timers such as Princess's Slide resume from this player's frame.
        raceTimerValue, raceTimerOverride = s.spTimer, s.spTimerOn ~= 0
        raceTimerRunning = raceTimerOverride
        raceTimerHold, raceTimerLevel, raceTimerArea = raceTimerOverride and 1 or 0,
            raceTimerOverride and s.spLevel or -1, raceTimerOverride and s.spArea or -1
        if raceTimerOverride then
            -- PSS stays HUD-only for per-player ownership. Other timer types may need native show/start
            -- control as well as the HUD value to resume their game logic.
            if s.spLevel ~= LEVEL_PSS and level_control_timer ~= nil then
                level_control_timer(TIMER_CONTROL_SHOW)
                level_control_timer(TIMER_CONTROL_START)
            end
            showRaceTimer(raceTimerValue)
        else
            clearRaceTimerOverride()
        end
    end
 
    m.health = fullHP and maxHP or s.spHP
    if m.marioObj ~= nil then m.marioObj.oIntangibleTimer = 0 end
    -- Two protected frames absorb an immediate overlap after loading but stay below CoopDX's three-frame
    -- visibility threshold, so Mario remains steadily visible instead of blinking for half a second.
    m.hurtCounter, m.invincTimer = 0, 30
    -- Environment-appropriate neutral actions prevent dry-ground Y drift.
    --local neutralAction = s.spSwim ~= 0 and ACT_WATER_IDLE
        --or (s.spAir ~= 0 and ACT_FREEFALL or ACT_IDLE)
	if s.spAir ~= nil then 
	set_mario_action(m, ACT_FLYING, 0)
	else
    set_mario_action(m, ACT_WATER_IDLE, 0)
	end
    m.actionState, m.actionTimer, m.actionArg = 0, 0, 0
    -- A neutral status and soft reset still clear underwater camera carryover. Priming every current/goal
    -- camera point with the checkpoint view prevents that reset from creating a slow altitude transition.
    --if m.statusForCamera ~= nil then m.statusForCamera.action = neutralAction end
    --if m.area ~= nil and m.area.camera ~= nil then
        --soft_reset_camera(m.area.camera)
        --cameraRestoreFrames = restoreCameraView(s, m) and CAMERA_RESTORE_FRAMES or 0
    --else
        --cameraRestoreFrames = 0
    --end
	
	cameraRestoreFrames = 1
 
    if s.spIW ~= 0 then guardFrames, guardX, guardY, guardZ = 1, x, y, z end
 
    if deferShell then
        shellRestoreFrames, shellRestoreAttempts = 6, 30
    elseif not restoreCheckpointInteraction(m, s) and s.spObjMode == OBJ_BOWSER then
        -- Cross-area Bowser roots can appear a few frames after Mario.
        interactionRetryFrames = 30
    end
    if not restoreBowserWorldSnapshot(s) then bowserWorldRetryFrames = 30 end
    refreshOwnedItems()
 
    m.particleFlags = PARTICLE_SPARKLES
    if m.marioObj ~= nil then play_sound(SOUND_MENU_CLICK_FILE_SELECT, m.marioObj.header.gfx.cameraToObject) end
    resetLoad()
	
    djui_popup_create("\\#6fd83f\\Loaded " .. SAVE_SLOTS[activeSlot].name .. " savepoint\\#6fd83f\\", 1)
end
 
-- Captures every supported part of the local player into the chosen direction's independent checkpoint.
-- Called only by marioUpdate() after an unmodified D-pad press. It creates a fresh table, captures Mario/view/
-- inventory/collectibles/interactions/Bowser/timer/environment/instant-warp state, then writes that one slot.
-- Koopa is marked shared rather than copied.
-- Why/player effect: this saves the game to the chosen D-pad slot,
-- remembering the player's place, condition, items, timer, view, and interactions without affecting anyone else.
local function save(m, slot)
    local s, n = blankCheckpoint(), gNetworkPlayers[0]
    localCheckpoints[slot] = s
    activeSlot, localCheckpoint = slot, s
	--djui_chat_message_create(tostring(tempSSX))
	s.spSSX, s.spSSY, s.spSSZ, s.spSLevel, s.spSArea, s.spSAct = tempSSX, tempSSY, tempSSZ, tempSLevel, tempArea, tempAct --SLIDE REFRESH
    s.spLevel, s.spArea = n.currLevelNum, playerArea(m, n)
    s.spAct, s.spHP = n.currActNum, m.health
    s.spX, s.spY, s.spZ = m.pos.x, m.pos.y, m.pos.z
    s.spAngleX, s.spAngleY, s.spAngleZ = m.faceAngle.x, m.faceAngle.y, m.faceAngle.z
    captureCameraView(s, m)
    s.spRedCoins, s.spCoins = m.area and m.area.numRedCoins or 0, m.numCoins
    s.spSecrets = m.area and m.area.numSecrets or 0
    s.spLives, s.spKeys = m.numLives, m.numKeys
    local capMask = MARIO_CAPS | MARIO_CAP_ON_HEAD | MARIO_CAP_IN_HAND
    s.spCapFlags, s.spCapTimer = m.flags & capMask, m.capTimer
 
    local items = currentAreaSet()
    local ridden = m.riddenObj
    local riddenId = ridden ~= nil and objectBehaviorId(ridden) or -1
    s.spShell = ((m.action & ACT_FLAG_RIDING_SHELL) ~= 0
        or riddenId == id_bhvKoopaShell
        or riddenId == id_bhvKoopaShellUnderwater) and 1 or 0
    s.spShellWater = riddenId == id_bhvKoopaShellUnderwater and 1 or 0
    s.spShellAction = s.spShell ~= 0 and m.action or 0
 
    local interactionObject, interactionMode = nil, OBJ_NONE
    if s.spShell ~= 0 then
        interactionObject, interactionMode = ridden, OBJ_SHELL
    else
        local held = m.heldObj
        local bowserAction = m.action == ACT_PICKING_UP_BOWSER or m.action == ACT_HOLDING_BOWSER
            or m.action == ACT_RELEASING_BOWSER
        if held == nil and (m.action == ACT_PICKING_UP_BOWSER or m.action == ACT_HOLDING_BOWSER) then
            held = m.usedObj or m.interactObj
        end
        if held ~= nil then
            interactionObject = held
            interactionMode = (bowserAction or isBowserObject(held)) and OBJ_BOWSER or OBJ_HELD
        end
    end
    captureInteraction(s, m, interactionObject, interactionMode)
 
    -- Free Bowser state coexists with Mario's held or ridden object.
    if interactionMode ~= OBJ_BOWSER then
        captureBowserWorldSnapshot(s, findBowserForCheckpoint(s))
    end
 
    if s.spShell ~= 0 and ridden ~= nil then
        local rk = objectKey(ridden)
        if rk ~= nil then items[rk] = true end
    end
    s.spGone = encodeSet(items)
    local savedLocation = locationKey(s.spLevel, s.spArea)
    if ownedGoneLocation ~= savedLocation then
        -- A checkpoint saved elsewhere releases the previous area's hidden set.
        ownedGone, ownedGoneLocation = {}, nil
    end
    -- Koopa's race is globally shared, while slide timers remain player-private.
    s.spSharedRace = koopaRaceActive() and 1 or 0
    if s.spSharedRace ~= 0 then
        clearRaceTimerOverride(false)
    else
        local hudFlags = hud_get_value(HUD_DISPLAY_FLAGS)
        local timerVisible = (hudFlags & HUD_DISPLAY_FLAG_TIMER) ~= 0
        local timerRunning = level_control_timer_running()
        local restoredTimerHere = raceTimerOverride
            and s.spLevel == raceTimerLevel and s.spArea == raceTimerArea
        -- PSS ownership comes from player zero touching its start surface, never from the shared native HUD.
        -- For other timer types, the visible native timer remains the best signal that a race is active.
        s.spTimerOn = (restoredTimerHere and raceTimerRunning
            or (s.spLevel ~= LEVEL_PSS and timerVisible and timerRunning)) and 1 or 0
        if s.spTimerOn ~= 0 then
            -- Resaves capture the displayed override, not a transient native value.
            s.spTimer = restoredTimerHere and raceTimerValue
                or hud_get_value(HUD_DISPLAY_TIMER)
        else
            clearRaceTimerOverride()
        end
    end
 
    -- Require real water depth as well as a water action, rejecting stale swim flags on land.
    local waterAction = (m.action & ACT_FLAG_SWIMMING) ~= 0 or (m.action & ACT_FLAG_METAL_WATER) ~= 0
    local waterDepth = (m.waterLevel or -11000) - m.pos.y
    --s.spSwim = waterAction and waterDepth > 80 and 1 or 0
    --s.spAir = s.spSwim == 0 and ((m.action & ACT_FLAG_AIR) ~= 0) and 1 or 0
	if m.action == ACT_FLYING then s.spAir = ACT_FLYING else s.spAir = nil end
    s.spIW = (iwSurface(m.floor) or iwSurface(m.wall) or iwSurface(m.ceil)) and 1 or 0
    local recentIW = s.spIW ~= 0 and recentIWAge <= IW_RECENT
    s.spDX, s.spDY, s.spDZ = recentIW and recentDX or 0, recentIW and recentDY or 0, recentIW and recentDZ or 0
    if not writeCheckpoint(slot, packCheckpoint(s)) then
        djui_popup_create("\\#dd3232\\" .. SAVE_SLOTS[slot].name
            .. " save kept for this session; persistent file unavailable.\\#dd3232\\", 2)
    end
    m.particleFlags = PARTICLE_SPARKLES
    if m.marioObj ~= nil then play_sound(SOUND_MENU_CLICK_CHANGE_VIEW, m.marioObj.header.gfx.cameraToObject) end
    djui_popup_create("\\#e7b625\\Created " .. SAVE_SLOTS[slot].name .. " savepoint\\#e7b625\\", 1)
end
 
-- Starts one safe cross-area load and resets its timeout tracking.
-- Called only by load(). It records LOAD_LEVEL, clears progress tracking, asks CoopDX for the destination's normal
-- entry instead of its death exit, reports an unavailable destination immediately, and arms arena Bowser setup.
-- Why/player effect: loading between the castle and courses cannot start a death/Game Over transition, remove a
-- restored shell, or initialize the level twice; Mario is moved from the safe entry to the checkpoint when ready.
local function requestWarp(s, useNode)
    timer, lastLevel, lastArea = 0, nil, nil
    if useNode then
        loadMode = LOAD_NODE
		--djui_chat_message_create("USING NODE")
        warp_to_warpnode(s.spLevel, s.spArea, s.spAct, WARP_NODE_DEATH)	
    else
        loadMode = LOAD_LEVEL
		--djui_chat_message_create("USING NORMAL WARP")
        warp_to_level(s.spLevel, s.spArea, s.spAct)
    end
    bowserTime = 1
end
 
-- Selects one direction's checkpoint, then chooses an immediate load, a short Bowser wait, or a destination warp.
-- Called only by marioUpdate() for L Trigger plus a D-pad press. It selects the in-memory slot, applies in place when
-- already there, otherwise waits for Bowser or calls requestWarp(). It performs no disk work.
-- Why/player effect: this loads the game from the chosen D-pad slot, returning the player and supported gameplay
-- details to the saved moment whether that save is nearby, in another area, or in another level.
local function load(m, slot)
    local s, n = localCheckpoints[slot], gNetworkPlayers[0]
    if s == nil then
        djui_popup_create("\\#dd3232\\No " .. SAVE_SLOTS[slot].name .. " savepoint available.\\#dd3232\\", 1)
        return
    end
    activeSlot, localCheckpoint = slot, s
    local a = playerArea(m, n)
    local samePlace = atCheckpoint(s, m, n)
    if samePlace then
        if checkpointHasBowserState(s) and findBowserForCheckpoint(s) == nil then
            loadMode, timer, loadSettle = LOAD_BOWSER, 0, 0
            lastLevel, lastArea = n.currLevelNum, a
        else
            -- Delete the previous checkpoint clone before restoring a new one.
            -- This is needed when reloading a savepoint while Mario is already in the same area.
            clearRestoredObject(m)
            apply(m)
			--if refreshSlide == 1 and trackTimer then refreshSlideFunc(m) end
			if refreshSlide == 1 and trackTimer then refreshSlideFunc(m) end --ENTER REFRESHSLIDE TO RELOAD THE LEVEL
        end
        return
    end
    requestWarp(s, not samePlace)
end
 
-- Supplies the private timer and finishes a pending load before local Mario simulation.
-- Registered at HOOK_BEFORE_MARIO_UPDATE and restricted to player zero. It reasserts the slide value before finish
-- logic, then calls apply() only after the destination stays ready for several frames and any Bowser root exists.
-- Why/player effect: no physics/shared-timer frame slips through before the exact checkpoint is restored.
local function beforeMario(m)
    if m.playerIndex ~= 0 then return end
    -- pss_end_slide() reads the HUD timer during Mario's update. Reasserting the private value here makes
    -- the local finish use the restored elapsed time even though play-mode code just wrote the native clock.
    if raceTimerOverride then
        local n = gNetworkPlayers[0]
        if inPrivateTimerArea(m, n) then showRaceTimer(raceTimerValue) end
    end
    if loadMode == LOAD_NONE then return end
    local s, n = localCheckpoint, gNetworkPlayers[0]
    if m.area ~= nil and atCheckpoint(s, m, n) then
        -- Never attach before native Bowser sync and callbacks are initialized.
        if checkpointHasBowserState(s) and findBowserForCheckpoint(s) == nil then
            if loadMode ~= LOAD_BOWSER then timer, loadMode = 0, LOAD_BOWSER end
            return
        end
        apply(m)
    end
end
 
-- Reports whether CoopDX currently owns Mario for death, cutscene, teleport, bubble, or intangible logic.
-- Called by marioUpdate() only after a D-pad press, so the checks add no work to ordinary input frames.
-- Why/player effect: save/load waits instead of interrupting a transition and leaving Mario hidden or stuck.
local function blocked(m)
    return m == nil or m.health <= 0
        or (m.action & ACT_GROUP_MASK) == ACT_GROUP_CUTSCENE
        or (m.action & ACT_FLAG_INTANGIBLE) ~= 0
        or m.action == ACT_BUBBLED
        or (m.flags & MARIO_TELEPORTING) ~= 0
end
 
-- Handles four-direction save/load input and local observations for player zero only.
-- Registered at HOOK_MARIO_UPDATE for every Mario but returns immediately unless playerIndex is zero. It observes
-- the local slide/max-health state, exits cheaply without a D-pad press, maps the direction, cancels older load
-- work, then calls save() or load() depending on L Trigger.
-- Why/player effect: pressing a D-pad direction saves
-- to that direction's slot; holding L Trigger and pressing it loads that slot. Other players cannot trigger yours.
local function marioUpdate(m)
    if m.playerIndex ~= 0 then return end
    updatePrivateSlideSurface(m)
	if trackTimer and refreshSlide > 1 then refreshSlideFunc(m) end
    if m.health > maxHP then maxHP = m.health end
    local pressed = m.controller.buttonPressed
    if (pressed & SAVE_BUTTON_MASK) == 0 or blocked(m) then return end
    local slot = DEFAULT_SLOT
    for i, data in ipairs(SAVE_SLOTS) do if (pressed & data.button) ~= 0 then slot = i break end end
	--updatePrivateSlideSurface(m, slot)
	--if trackTimer and refreshSlide > 1 then refreshSlideFunc(m) end
    if loadMode ~= LOAD_NONE then resetLoad() end
    cameraRestoreFrames = 0
    if (m.controller.buttonDown & L_TRIG) ~= 0 then load(m, slot) else save(m, slot) end
end
 
---------------------------------------------------------------------------------------------------
-- Finishing delayed work without pausing gameplay
---------------------------------------------------------------------------------------------------
 
-- Purpose:
-- Bowser, synchronized objects, cross-area warps, private clocks, local pickup visibility, and the camera become
-- writable at different engine phases. These callbacks complete only the work whose state flags are active.
-- Call flow: HOOK_UPDATE calls the bounded helpers in order; HOOK_ON_PLAY_MODE_UPDATE handles the final camera/HUD
-- pass. Every normal path returns before object scans or protected work when nothing needs attention.
-- Player effect: restored fights, timers, collectibles, and cross-area loads settle correctly without a pause
-- or repeatedly rebuilding the checkpoint.
 
-- Advances staged Bowser pickup, held rendering, and the one-frame animation correction inside pcall.
-- Called first by update(). It returns before pcall unless one of the three Bowser records is active, then runs
-- their helpers together. On failure it reveals the root and clears only temporary mod state.
-- Why/player effect: normal frames pay almost nothing and a failed attachment falls back to a visible fight.
local function updateBowserRuntime()
    if bowserRestoreObject == nil and heldBowserRoot == nil and bowserWorldAnimObject == nil then return end
    local bowserOk = pcall(function()
        advanceBowserRestore(); maintainHeldBowserWorldGraph(); finishBowserWorldAnimationRestore()
    end)
    if not bowserOk then
        if heldBowserRoot ~= nil and currentLocationKey() == heldBowserLocation then
            setBowserWorldGraphActive(heldBowserRoot, true)
        end
        heldBowserRoot, heldBowserLocation = nil, nil
        clearBowserRestoreState()
        bowserWorldAnimObject, bowserWorldAnimLocation, bowserWorldAnimFrame = nil, nil, 0
    end
end
 
-- Completes one delayed synchronized-shell send after CoopDX assigns the replacement shell its network slot.
-- Armed by restoreShellInteraction() when its immediate send is too early. It stops on success, object loss, area
-- change, or after thirty frames.
-- Why/player effect: peers receive the fully initialized replacement instead of an incomplete or invisible shell.
local function updateRestoredObjectSync()
    if restoredObjectSyncFrames <= 0 then return end
    if not restoredObjectIsLive() or restoredObjectLocation ~= currentLocationKey() then
        restoredObjectSyncFrames = 0
    elseif sendObjectSync(restoredObject, true) then
        restoredObjectSyncFrames = 0
    else
        restoredObjectSyncFrames = restoredObjectSyncFrames - 1
    end
end
 
-- Waits a few frames between retiring a ridden shell and creating its same-area replacement.
-- Armed by apply() only when Mario was already riding a shell. update() holds Mario at the checkpoint while the
-- old synchronized object and its STOP_RIDING packet clear, then restores one replacement; a failed spawn receives
-- bounded retries and any area change cancels the work.
-- Why/player effect: repeated shell loads take only a fraction of a second but cannot reuse the old network slot
-- soon enough for its delayed deletion message to erase the new shell on other players' screens.
local function updateDelayedShellRestore()
    if shellRestoreFrames <= 0 then return end
    local m, n, s = gMarioStates[0], gNetworkPlayers[0], localCheckpoint
    if m == nil or n == nil or s == nil or s.spObjMode ~= OBJ_SHELL or not atCheckpoint(s, m, n) then
        shellRestoreFrames, shellRestoreAttempts = 0, 0
        return
    end

    local x, y, z = checkpointPos(s)
    m.pos.x, m.pos.y, m.pos.z = x, y, z
    m.vel.x, m.vel.y, m.vel.z, m.forwardVel, m.slideVelX, m.slideVelZ = 0, 0, 0, 0, 0, 0
    if m.marioObj ~= nil then
        m.marioObj.oPosX, m.marioObj.oPosY, m.marioObj.oPosZ = x, y, z
    end
    shellRestoreFrames = shellRestoreFrames - 1
    if shellRestoreFrames > 0 then return end
    if restoreShellInteraction(m, s) then
        shellRestoreAttempts = 0
        refreshOwnedItems()
    elseif shellRestoreAttempts > 1 then
        shellRestoreAttempts, shellRestoreFrames = shellRestoreAttempts - 1, 1
    else
        shellRestoreAttempts = 0
    end
end
 
-- Reports whether this peer already has a genuine ridden shell beside a remote Mario.
-- updateRemoteShellVisuals() calls it before creating a stand-in, checking both shell behaviors and a small radius.
-- Why/player effect: if CoopDX already delivered the real shell, the mod never draws a second shell over it.
local function remoteHasNativeShell(m)
    if m == nil or m.marioObj == nil then return false end
    for _, bhv in ipairs({id_bhvKoopaShell, id_bhvKoopaShellUnderwater}) do
        local o = obj_get_first_with_behavior_id(bhv)
        while o ~= nil do
            local dx, dy, dz = o.oPosX - m.pos.x, o.oPosY - m.pos.y, o.oPosZ - m.pos.z
            if (o.oAction or 0) == 1 and dx * dx + dy * dy + dz * dz < 40000 then return true end
            o = obj_get_next_with_same_behavior_id(o)
        end
    end
    return false
end
 
-- Maintains non-interactive shell models for remote players whose reconstructed gameplay shell was not delivered.
-- Called once per update. It reads the event-only per-player announcement, creates at most one local static model
-- per affected rider, copies that remote Mario's position/yaw, tolerates short native setup gaps, and removes the
-- model after a sustained dismount, warp, disconnect, or whenever a genuine native shell is present. No object or
-- per-frame network messages are generated here.
-- Why/player effect: other players consistently see the shell being ridden, while collision and control remain
-- owned by the rider's real local shell and the server receives no extra repeated work.
local function updateRemoteShellVisuals()
    local localMario, localNetwork = gMarioStates[0], gNetworkPlayers[0]
    if localMario == nil or localNetwork == nil then return end
    local riding = localMario.riddenObj ~= nil
    if shellVisual.pending > 0 then
        if localCheckpoint == nil or not atCheckpoint(localCheckpoint, localMario, localNetwork) then
            shellVisual.pending = 0
        elseif riding then
            shellVisual.pending = shellVisual.pending - 1
            if shellVisual.pending == 0 then publishShellVisual(localCheckpoint, true) end
        else
            shellVisual.pending = 30
        end
    end
    if shellVisual.active then
        if riding and shellVisual.level == localNetwork.currLevelNum
            and shellVisual.area == playerArea(localMario, localNetwork) then
            shellVisual.lost = 0
        else
            shellVisual.lost = shellVisual.lost + 1
            if shellVisual.lost > 90 then
                publishShellVisual(nil, false)
                if localCheckpoint ~= nil and localCheckpoint.spObjMode == OBJ_SHELL
                    and atCheckpoint(localCheckpoint, localMario, localNetwork) then shellVisual.pending = 1 end
            end
        end
    end
    local connected = network_player_connected_count()
    if connected ~= shellVisual.playerCount then
        shellVisual.playerCount = connected
        if shellVisual.active then shellVisual.resend = 30 end
    elseif shellVisual.resend > 0 then
        shellVisual.resend = shellVisual.resend - 1
        if shellVisual.resend == 0 and shellVisual.active then publishShellVisual(nil, true) end
    end
 
    local wanted = {}
    for i = 1, MAX_PLAYERS - 1 do
        local n, m = gNetworkPlayers[i], gMarioStates[i]
        local key = n and n.globalIndex or -1
        local state = shellVisual.states[key]
        local active = key >= 0 and n.connected and m ~= nil and m.marioObj ~= nil and state ~= nil
            and n.currLevelNum == localNetwork.currLevelNum
            and playerArea(m, n) == playerArea(localMario, localNetwork)
            and state.level == localNetwork.currLevelNum
            and state.area == playerArea(localMario, localNetwork)
        if active then
            wanted[key] = true
            local visual = shellVisual.visuals[key]
            if remoteHasNativeShell(m) then
                if visual ~= nil then pcall(obj_mark_for_deletion, visual) shellVisual.visuals[key] = nil end
            else
                if visual == nil or visual.activeFlags == DEACTIVATED then
                    visual = spawn_non_sync_object(id_bhvStaticObject, E_MODEL_KOOPA_SHELL,
                        m.pos.x, m.pos.y, m.pos.z, function(o)
                            o.oFlags, o.oInteractType, o.oIntangibleTimer = OBJ_FLAG_UPDATE_GFX_POS_AND_ANGLE, 0, -1
                    end)
                    shellVisual.visuals[key] = visual
                end
                if visual ~= nil then
                    visual.oPosX, visual.oPosY, visual.oPosZ = m.pos.x, m.pos.y, m.pos.z
                    visual.oMoveAngleYaw, visual.oFaceAngleYaw = m.faceAngle.y, m.faceAngle.y
                end
            end
        end
    end
    for key, visual in pairs(shellVisual.visuals) do
        if not wanted[key] then
            if visual ~= nil then pcall(obj_mark_for_deletion, visual) end
            shellVisual.visuals[key] = nil
        end
    end
    for key in pairs(shellVisual.states) do
        local i = network_local_index_from_global(key)
        local n = i ~= nil and i >= 0 and i < MAX_PLAYERS and gNetworkPlayers[i] or nil
        if n == nil or not n.connected or n.globalIndex ~= key then shellVisual.states[key] = nil end
    end
end
 
-- Advances this client's private race clock exactly once per frame.
-- Called by update() after Bowser staging. It returns unless an override exists, clears it on area exit, consumes
-- the one-frame restore hold, increments only while locally running, and redraws the HUD.
-- Why/player effect: Princess's Slide time belongs to this run and cannot advance from another Mario's flag.
local function updateRaceTimer()
    if not raceTimerOverride then return end
    local m, n = gMarioStates[0], gNetworkPlayers[0]
    if not inPrivateTimerArea(m, n) then
        clearRaceTimerOverride()
        return
    end
 
    if raceTimerHold > 0 then raceTimerHold = raceTimerHold - 1
    elseif raceTimerRunning and raceTimerValue < 17999 then raceTimerValue = raceTimerValue + 1 end
    if raceTimerOverride then showRaceTimer(raceTimerValue) end
end
 
-- Retries a free or held Bowser restore for a short fixed period when his root arrives after Mario.
-- Called by update() and exits unless apply() armed a retry counter. It validates atCheckpoint(), attempts free and
-- held paths independently, refreshes visibility after held success, and decrements/finalizes each bound.
-- Why/player effect: a slow synchronized boss can resume without a replacement or an endless loop.
local function updateBowserRetries()
    if bowserWorldRetryFrames <= 0 and interactionRetryFrames <= 0 then return end
    local m, n, s = gMarioStates[0], gNetworkPlayers[0], localCheckpoint
    local inArea = atCheckpoint(s, m, n)
 
    if bowserWorldRetryFrames > 0 then
        if not inArea or s.spBowserWorld == 0 then
            bowserWorldRetryFrames = 0
        elseif restoreBowserWorldSnapshot(s) then
            bowserWorldRetryFrames = 0
        else
            bowserWorldRetryFrames = bowserWorldRetryFrames - 1
        end
    end
 
    if interactionRetryFrames > 0 then
        if not inArea or not checkpointIsBowser(s)
            or (m.heldObj ~= nil and not isBowserObject(m.heldObj)) then
            interactionRetryFrames = 0
        elseif restoreBowserInteraction(m, s) then
            interactionRetryFrames = 0
            refreshOwnedItems()
        else
            interactionRetryFrames = interactionRetryFrames - 1
        end
    end
end
 
-- Initializes an ordinary arena Bowser a few frames after a level warp.
-- Called by update() only after requestWarp() arms bowserTime. On frame five it resets a newly created ordinary
-- arena root only when the selected slot contains neither held nor free Bowser state, then disarms itself.
-- Why/player effect: ordinary arena entry stays usable while an in-progress fight remains untouched.
local function updateWarpedBowserReset()
    if bowserTime < 1 then return end
    bowserTime = bowserTime + 1
    if bowserTime < 5 then return end
    local o = obj_get_first_with_behavior_id(id_bhvBowser)
    local m, s = gMarioStates[0], localCheckpoint
    if o ~= nil and (m == nil or m.heldObj ~= o) and s.spObjMode ~= OBJ_BOWSER
        and s.spBowserWorld == 0 then
        o.oAction = 0 --SET ACTION TO 0 SO BOWSER DOESN'T FREEZE WHEN RESPAWNING BACK INTO ARENA FROM OUTSIDE
    end
    bowserTime = 0
end
 
-- Watches a load waiting for a level, area, or Bowser root to become ready.
-- Called last by update() and exits for LOAD_NONE. It resets its timer on level/area progress, grants Bowser a
-- longer readiness window, and stops clearly without issuing another level initialization.
-- Why/player effect: an asynchronous destination gets time to settle but cannot death-warp, reload repeatedly,
-- duplicate level objects, or leave the lobby waiting forever.
local function updatePendingLoad()
    if loadMode == LOAD_NONE then return end
    local m, n, s = gMarioStates[0], gNetworkPlayers[0], localCheckpoint
    if m == nil or n == nil or s == nil then return end
    local a = playerArea(m, n)
    if n.currLevelNum ~= lastLevel or a ~= lastArea then lastLevel, lastArea, timer = n.currLevelNum, a, 0
    else timer = timer + 1 end
 
    -- Clamp node fallback to the configured timeout so direct warp is reachable.
    if loadMode == LOAD_NODE and timer >= LOAD_TIMEOUT then requestWarp(s, false) return end
 
    if timer >= LOAD_TIMEOUT then
        -- Bowser initialization receives a longer readiness window.
        if loadMode == LOAD_BOWSER and timer < BOWSER_READY_TIMEOUT then return end
        if retries < LOAD_RETRIES then
            retries = retries + 1
            requestWarp(s, loadMode ~= LOAD_LEVEL)
        else
            resetLoad()
            djui_popup_create("\\#dd3232\\SavePoint load stopped; press load again.\\#dd3232\\", 2)
        end
    end
end
 
-- Runs all follow-up tasks and the throttled collectible/instant-warp bookkeeping once per game frame.
-- Registered at HOOK_UPDATE. Existing Bowser work advances before retries, the timer advances before its late
-- HUD pass, and local visibility refreshes before pending-warp supervision. No persistence work occurs here.
-- Why/player effect: delayed pieces settle in order while normal play and every other player remain responsive.
local function update()
    updateBowserRuntime()
    if not pcall(updateDelayedShellRestore) then shellRestoreFrames, shellRestoreAttempts = 0, 0 end
    updateRemoteShellVisuals(); updateRestoredObjectSync(); updateRaceTimer()
    updateBowserRetries(); updateWarpedBowserReset()
    if recentIWAge <= IW_RECENT then recentIWAge = recentIWAge + 1 end
    worldScanTicker = worldScanTicker + 1
    if worldScanTicker >= 3 then worldScanTicker = 0; refreshOwnedItems() end
    updatePendingLoad()
end
 
-- Performs the camera's brief settling snaps and redraws the private timer after play-mode updates.
-- Registered at HOOK_ON_PLAY_MODE_UPDATE. It reasserts the saved view for a few frames and an in-area timer without
-- advancing it; either value may otherwise be overwritten by late engine transition or water-camera work.
-- Why/player effect: the view snaps instantly without getting stuck, then releases normally; slide time stays exact.
local function latePlayModeRestore()
    if cameraRestoreFrames > 0 then
        local m, n = gMarioStates[0], gNetworkPlayers[0]
		soft_reset_camera(m.area.camera)
        --if atCheckpoint(localCheckpoint, m, n) and restoreCameraView(localCheckpoint, m) then
            --cameraRestoreFrames = cameraRestoreFrames - 1
			--if cameraRestoreFrames <= 1 then
			--soft_reset_camera(m.area.camera)
			--cameraRestoreFrames = 0
			--end
        --else
            cameraRestoreFrames = 0
        --end
    end
    if not raceTimerOverride then return end
    local m, n = gMarioStates[0], gNetworkPlayers[0]
    if inPrivateTimerArea(m, n) then showRaceTimer(raceTimerValue) end
end
 
 
---------------------------------------------------------------------------------------------------
-- Recording pickups and protecting warp-edge loads
---------------------------------------------------------------------------------------------------
 
-- Purpose:
-- CoopDX calls these event handlers exactly when an interaction, instant warp, or physics step occurs. Using hooks
-- is both more accurate and cheaper than searching for those events in update(). Every handler rejects remote
-- Mario state before changing local records.
-- Player effect: your collected objects and instant-warp position restore correctly, while other players'
-- pickups, movement, and inputs never rewrite your checkpoint.
 
-- Records a successful collectible interaction for the local player before the object disappears.
-- Registered at HOOK_ON_INTERACT. It filters failed/remote/unsupported interactions, computes objectKey(), and adds
-- it to currentAreaSet(); save() later encodes that set.
-- Why/player effect: this player's pickup history is preserved without deleting the object for anyone else.
local function onInteract(m, o, interactType, interactValue)
    if interactValue == false or m == nil or m.playerIndex ~= 0 or not isOwnedItem(o, interactType) then return end
    local k = objectKey(o)
    if k == nil then return end
    currentAreaSet()[k] = true
end
 
-- Blocks local interaction with an original that the loaded checkpoint says is already gone.
-- Registered at HOOK_ALLOW_INTERACT. It always allows the restored/held/ridden object, returns before hashing when
-- no relevant local source/set is active, then blocks only a matching source or saved personal pickup.
-- Why/player effect: hidden originals cannot be collected twice while restored items remain usable.
local function allowInteract(m, o, interactType)
    if m == nil or m.playerIndex ~= 0 or o == nil then return end
    if o == restoredObject or o == m.heldObj or o == m.riddenObj then return end
    local here = currentLocationKey()
    local source = here == restoredObjectLocation and restoredObjectSourceKey ~= nil
        and (restoredObjectSourceBehavior == nil or restoredObjectSourceBehavior == 0
            or objectBehaviorId(o) == restoredObjectSourceBehavior)
    local owned = here == ownedGoneLocation and isOwnedItem(o, interactType)
    if not source and not owned then return end
    local k = objectKey(o)
    if k ~= nil and ((source and k == restoredObjectSourceKey) or (owned and ownedGone[k])) then return false end
end
 
-- Records the displacement supplied by an instant-warp event for a few frames.
-- Registered at HOOK_ON_INSTANT_WARP. It resets the short age window and copies the event vector; save() uses it
-- only while Mario still touches the boundary.
-- Why/player effect: checkpointPos() knows which side is safe when that slot later loads.
local function instantWarp(_area, _id, d)
    recentIWAge = 0
    recentDX, recentDY, recentDZ = 0, 0, 0
    if d ~= nil then recentDX, recentDY, recentDZ = d.x or 0, d.y or 0, d.z or 0 end
end
 
-- Holds Mario at the restored coordinates for one ground, air, or water physics step.
-- Registered at HOOK_BEFORE_PHYS_STEP and restricted to player zero. It runs only when apply() armed guardFrames,
-- rewrites the corrected position/zero motion, and returns the matching no-step result once.
-- Why/player effect: collision cannot consume the invisible warp-safety offset on the load frame.
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

local function tracktime()

	if not network_is_server() then
		djui_popup_create("\\#dd3232\\Host Command Only\\#dd3232\\", 1)
        return true
    end

    trackTimer = not trackTimer
    djui_chat_message_create("Keep track of timers: " .. (trackTimer and "\\#6fd83f\\enabled\\#6fd83f\\ HAS BUGS!" or "\\#dd3232\\disabled\\#dd3232\\"))
    return true
end
 
-- Registration order mirrors frame order: private timer/destination readiness before Mario, local input during
-- Mario update, bounded maintenance during normal update, then brief camera/HUD repair after play-mode work.
-- Event hooks record pickups/warps or protect one physics step. The result appears continuous to the player.
hook_event(HOOK_BEFORE_MARIO_UPDATE, beforeMario)
hook_event(HOOK_MARIO_UPDATE, marioUpdate)
hook_event(HOOK_UPDATE, update)
hook_event(HOOK_ON_PLAY_MODE_UPDATE, latePlayModeRestore)
hook_event(HOOK_ON_INSTANT_WARP, instantWarp)
hook_event(HOOK_BEFORE_PHYS_STEP, beforePhys)
hook_event(HOOK_ON_INTERACT, onInteract)
hook_event(HOOK_ALLOW_INTERACT, allowInteract)
hook_event(HOOK_ON_PACKET_BYTESTRING_RECEIVE, receiveShellVisualPacket)
hook_event(HOOK_ALLOW_HAZARD_SURFACE, function(m) return not invulnerable end)  --(USED FOR RESPAWNING WITH SHELL OVER GROUND HAZARDS)
 
for _, name in ipairs({"fullhp", "fh"}) do hook_chat_command(name, "Toggle full HP on load.", fullhp) end
for _, name in ipairs({"keepcoin", "kc"}) do hook_chat_command(name, "Toggle saved coin restoration.", keepcoin) end
for _, name in ipairs({"savetime", "st"}) do hook_chat_command(name, "Toggle saving timers. (Recommended for solo play only) \\#dd3232\\(HAS BUGS!)\\#dd3232\\", tracktime) end