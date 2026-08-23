-- =====================================================================
--  DO NOT INSTALL THIS FILE. IT CRASHES DCS.
-- =====================================================================
--
--  Kept in the repo as a record of a failed approach, not as working code.
--
--  Both v1 and v2 of this hook crashed the dedicated server. The crash
--  handler fired ~34 seconds after load (".crash" and ".dmp" written, then
--  "track file empty / packing mission instead"), and the server kept port
--  10308 open while dead -- so it looked healthy while every client sat on
--  "loading". It took two outages to isolate, because the first time I
--  changed the mission and removed the hook in the same restart.
--
--  The cause is almost certainly net.dostring_in('server', ...) itself:
--  running Lua in the mission environment from a Hooks callback appears to be
--  unsafe on this build regardless of what that Lua does. v2 measured ZERO
--  performance cost (CPU 0.4%->0.3%, FPS 63.7->63.7) and still crashed, which
--  rules out the "too much work on the sim thread" theory entirely.
--
--  WHAT TO USE INSTEAD: DCS-gRPC. It does its work in a Rust DLL off the
--  simulation thread and rate-limits the Lua side. Measured cost on the same
--  server: FPS 63.6 against a 63.5 baseline. See server/grpc-bridge.ps1 and
--  server/grpc-events.ps1.
--
-- =====================================================================

-- SkyForge live map exporter (v2 -- deliberately minimal).
--
-- Install to:
--   %USERPROFILE%\Saved Games\DCS.server\Scripts\Hooks\skyforge-export.lua
--
-- Writes C:\dcs-state\live.json. A PowerShell task pushes it to S3 and the web
-- board reads it from CloudFront. No API server in the path.
--
-- WHY THIS VERSION IS SO CONSERVATIVE
--
-- v1 of this hook is the prime suspect for an outage that left every client
-- stuck on the loading screen while the server itself looked perfectly healthy.
-- It walked every coalition, every group category, every group and every unit
-- on the map, every 5 seconds, through net.dostring_in. On a Pretense Caucasus
-- map that is hundreds of units, on a server whose simulation loop is
-- single-threaded and already the bottleneck. Block that thread long enough and
-- the client join handshake starves -- which fails silently, server-side.
--
-- So v2 asks for as little as it possibly can:
--
--   * AIRCRAFT ONLY. Ground and ship units are skipped entirely -- they are the
--     overwhelming majority of objects and the least interesting on a map.
--     Zone ownership already comes from Pretense's own save file, for free.
--   * 15s interval instead of 5s.
--   * Airbases every 20th pass (~5 min); they change rarely.
--   * Projection refs once per mission, then never again.
--   * MAX_UNITS hard cap.
--   * Everything in pcall, and a permanent self-disable after repeated errors.
--
-- If sim FPS moves at all after enabling this, take it out. A map is not worth
-- a single frame of anyone's sortie.

local SkyForge = {}

local EXPORT_FILE     = [[C:\dcs-state\live.json]]
local EXPORT_INTERVAL = 15    -- seconds between exports
local BASES_EVERY     = 20    -- export airbases every Nth pass (~5 minutes)
local MAX_UNITS       = 150
local MAX_ERRORS      = 5     -- stop trying entirely after this many failures

local lastExport = 0
local pass       = 0
local errors     = 0
local disabled   = false

local cachedBases = '[]'
local cachedRefs  = '[]'

-- Aircraft only. Group.Category: 0 = AIRPLANE, 1 = HELICOPTER.
local GATHER_UNITS = [[
    local ok, res = pcall(function()
        local out, n = {}, 0
        for _, side in ipairs({1, 2}) do
            for _, cat in ipairs({0, 1}) do
                for _, grp in ipairs(coalition.getGroups(side, cat) or {}) do
                    if n >= ]] .. MAX_UNITS .. [[ then break end
                    if grp and grp:isExist() then
                        for _, u in ipairs(grp:getUnits() or {}) do
                            if n >= ]] .. MAX_UNITS .. [[ then break end
                            if u and u:isExist() then
                                local p = u:getPoint()
                                local lat, lon = coord.LOtoLL(p)
                                local player = u:getPlayerName()
                                n = n + 1
                                out[n] = string.format(
                                    '{"t":"%s","c":%d,"lat":%.5f,"lon":%.5f,"alt":%d,"cat":%d%s}',
                                    (u:getTypeName() or '?'):gsub('"', ''),
                                    side, lat, lon, math.floor(p.y or 0), cat,
                                    player and (',"p":"' .. player:gsub('"', '') .. '"') or '')
                            end
                        end
                    end
                end
            end
        end
        return '[' .. table.concat(out, ',') .. ']'
    end)
    if ok then return res end
    return '[]'
]]

local GATHER_BASES = [[
    local ok, res = pcall(function()
        local out, n = {}, 0
        for _, ab in ipairs(world.getAirbases() or {}) do
            if ab and ab:isExist() then
                local p = ab:getPoint()
                local lat, lon = coord.LOtoLL(p)
                n = n + 1
                out[n] = string.format('{"n":"%s","c":%d,"lat":%.5f,"lon":%.5f}',
                    (ab:getName() or ''):gsub('"', ''), ab:getCoalition() or 0, lat, lon)
            end
        end
        return '[' .. table.concat(out, ',') .. ']'
    end)
    if ok then return res end
    return '[]'
]]

-- Pretense stores positions as raw DCS metres. Three (x,z)->(lat,lon) pairs let
-- the browser derive an affine transform and place them itself.
local GATHER_REFS = [[
    local ok, res = pcall(function()
        local out, n = {}, 0
        for _, pt in ipairs({ {0,0}, {100000,0}, {0,100000} }) do
            local lat, lon = coord.LOtoLL({x = pt[1], y = 0, z = pt[2]})
            n = n + 1
            out[n] = string.format('{"x":%d,"z":%d,"lat":%.6f,"lon":%.6f}', pt[1], pt[2], lat, lon)
        end
        return '[' .. table.concat(out, ',') .. ']'
    end)
    if ok then return res end
    return '[]'
]]

local function ask(source)
    local ok, result = pcall(net.dostring_in, 'server', source)
    if not ok or type(result) ~= 'string' or result == '' then return nil end
    return result
end

local function export()
    local units = ask(GATHER_UNITS)
    if not units then
        errors = errors + 1
        if errors >= MAX_ERRORS then
            disabled = true
            pcall(net.log, 'SkyForge export disabled after repeated failures')
        end
        return
    end
    errors = 0

    if cachedRefs == '[]' then cachedRefs = ask(GATHER_REFS) or '[]' end
    if pass % BASES_EVERY == 1 then cachedBases = ask(GATHER_BASES) or cachedBases end

    local players, pn = {}, 0
    local okList, list = pcall(net.get_player_list)
    if okList and type(list) == 'table' then
        for _, id in pairs(list) do
            if id ~= 1 then
                local okName, name = pcall(net.get_player_info, id, 'name')
                local okSide, side = pcall(net.get_player_info, id, 'side')
                if okName and name and name ~= '' then
                    pn = pn + 1
                    players[pn] = string.format('{"name":"%s","side":%d}',
                        name:gsub('"', ''), (okSide and side) or 0)
                end
            end
        end
    end

    local mission = 'unknown'
    local okM, m = pcall(DCS.getMissionName)
    if okM and m then mission = m:gsub('"', '') end

    local f = io.open(EXPORT_FILE, 'w')
    if not f then return end
    f:write(string.format(
        '{"mission":"%s","players":[%s],"world":{"units":%s,"bases":%s,"refs":%s},"ts":%d}',
        mission, table.concat(players, ','), units, cachedBases, cachedRefs, os.time()))
    f:close()
end

function SkyForge.onSimulationFrame()
    if disabled then return end
    local now = os.time()
    if (now - lastExport) < EXPORT_INTERVAL then return end
    lastExport = now
    pass = pass + 1
    pcall(export)
end

function SkyForge.onMissionLoadEnd()
    -- A new mission may be a new theatre; drop cached geometry.
    cachedBases, cachedRefs = '[]', '[]'
    pass, errors, disabled = 0, 0, false
end

DCS.setUserCallbacks(SkyForge)
