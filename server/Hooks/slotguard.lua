-- Blocks specific airframes from being slotted or dynamically spawned.
--
-- Install to:
--   %USERPROFILE%\Saved Games\DCS.server\Scripts\Hooks\slotguard.lua
--
-- Why a hook and not the mission or the mod:
--   * The mission uses DCS dynamic spawn with unlimitedAircrafts=true on every
--     airbase, so there is no per-aircraft allowlist in the .miz to edit.
--   * Deleting variants from the Su-30 mod folder would desync the server from
--     clients that still have all eight, which breaks the integrity check for
--     everyone rather than blocking one airframe.
--   * A hook is mission-independent: it keeps working across mission swaps and
--     needs no repack of a .miz that carries campaign edits.
--
-- onPlayerTryChangeSlot did not fire for dynamic spawn slots before DCS
-- 2.9.12.5336. This server runs 2.9.28.26385, so it does.
--
-- SAFETY: this hook FAILS OPEN. If the aircraft type cannot be resolved it
-- allows the slot and logs why. A guard that cannot identify an airframe must
-- never lock every pilot out of every aircraft -- a block that silently does
-- nothing is recoverable, a server nobody can slot into during game night is
-- not.

local slotguard = {}

local LOG_FILE = [[C:\dcs-state\slotguard.log]]

-- Type strings exactly as the mod registers them in its FLANKERS table
-- (Mods/aircraft/Su-30_EFM_V2.8.06b BASE PACKAGE/.../config.lua). The NAME
-- field is the DCS unit type; DISPLAY_NAME is only what the UI shows.
local BLOCKED = {
    ['Su-30SM']     = 'Su-30SM',
    ['Su-30SM-AG']  = 'Su-30SM AG',
    ['Su-30MKA']    = 'Su-30MKA',
    ['Su-30MKA-AG'] = 'Su-30MKA AG',
    ['Su-30MKM']    = 'Su-30MKM',
    ['Su-30MKM-AG'] = 'Su-30MKM AG',
}

-- Kept deliberately as a comment rather than a table: Su-30MKI and Su-30MKI-AG
-- are permitted by simply not appearing in BLOCKED, along with every other
-- airframe on the server. An allowlist would block any new module the squadron
-- installs until someone remembered to update this file.

local function log(msg)
    local ok, f = pcall(io.open, LOG_FILE, 'a')
    if ok and f then
        f:write(os.date('%Y-%m-%d %H:%M:%S ') .. tostring(msg) .. '\n')
        f:close()
    end
end

-- Multicrew slots carry a seat suffix: unitId "_1", "_2". The Su-30 is a
-- two-seater, so this is not hypothetical -- without stripping it the lookup
-- misses and the back seat stays spawnable.
local function baseSlot(slotID)
    local s = tostring(slotID or '')
    return (s:gsub('_%d+$', ''))
end

-- DCS exposes slot metadata through more than one accessor depending on
-- whether the slot is authored in the mission or created by dynamic spawn.
-- Try each, take the first that yields a non-empty string.
local function resolveType(side, slotID)
    local base = baseSlot(slotID)

    local ok, t = pcall(function() return DCS.getUnitType(base) end)
    if ok and type(t) == 'string' and t ~= '' then return t, 'DCS.getUnitType' end

    ok, t = pcall(function() return DCS.getUnitType(slotID) end)
    if ok and type(t) == 'string' and t ~= '' then return t, 'DCS.getUnitType(raw)' end

    -- Dynamic spawn slots: the slot list carries the type alongside the id.
    ok, t = pcall(function()
        local slots = DCS.getAvailableSlots(side)
        if type(slots) ~= 'table' then return nil end
        for _, s in pairs(slots) do
            local id = tostring(s.unitId or s.slotId or s.id or '')
            if id == base or id == tostring(slotID) then
                return s.type or s.unitType
            end
        end
        return nil
    end)
    if ok and type(t) == 'string' and t ~= '' then return t, 'getAvailableSlots' end

    return nil, nil
end

function slotguard.onPlayerTryChangeSlot(playerID, side, slotID)
    -- Spectators and the server slot itself are not aircraft.
    if slotID == nil or slotID == '' or tostring(slotID) == '0' then return end

    local unitType, via = resolveType(side, slotID)

    if not unitType then
        -- Fail open, but say so loudly enough that it gets noticed and fixed.
        log(('ALLOW (type unresolved) player=%s side=%s slot=%s')
            :format(tostring(playerID), tostring(side), tostring(slotID)))
        return
    end

    local label = BLOCKED[unitType]
    if not label then return end   -- permitted airframe, including Su-30MKI

    local name = 'unknown'
    local okName, n = pcall(net.get_player_info, playerID, 'name')
    if okName and n then name = n end

    log(('BLOCK %s player=%s slot=%s via=%s')
        :format(unitType, name, tostring(slotID), tostring(via)))

    pcall(net.send_chat_to,
        label .. ' is not available on this server. Use the Su-30MKI or Su-30MKI AG.',
        playerID)

    return false
end

DCS.setUserCallbacks(slotguard)
