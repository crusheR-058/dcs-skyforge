-- Publishes live server telemetry for the idle watchdog, /dcs status and the
-- performance logger.
--
-- Install to:
--   %USERPROFILE%\Saved Games\DCS.server\Scripts\Hooks\playercount.lua
-- (server\setup.ps1 does this for you.)
--
-- Writes C:\dcs-state\players.json roughly every 15 seconds:
--   {"players":3,"names":[{"n":"Crusher","s":2}],"mission":"Syria CAP",
--    "fps":58.2,"ts":1755600000}
--
-- Names feed /dcs status and the web board's roster. They are capped at
-- MAX_NAMES so a griefed or bot-flooded server cannot grow this file without
-- bound -- the watchdog parses it every 5 minutes and must never be slow.
--
-- If this file stops being updated -- DCS crashed, hung, or no mission is
-- loaded -- the watchdog treats the server as empty and shuts it down. That is
-- the intended behaviour: a DCS server nobody can join should not stay billed.

local watchdog = {}

local STATE_FILE = [[C:\dcs-state\players.json]]
local WRITE_INTERVAL = 15
local MAX_NAMES = 32

local lastWrite = 0
local frameCount = 0
local fps = 0

local function jsonEscape(value)
    local escaped = tostring(value or ""):gsub("\\", "\\\\"):gsub('"', '\\"')
    return escaped
end

local function countPlayers()
    local ok, list = pcall(net.get_player_list)
    if not ok or type(list) ~= "table" then
        return 0, {}
    end

    local count = 0
    local names = {}
    for _, id in pairs(list) do
        -- On a dedicated server, id 1 is the server slot itself, not a human.
        if id ~= 1 then
            -- MEASURED: net.get_player_list() includes raw TCP connections that
            -- have not authenticated yet. A bare `Test-NetConnection` -- or any
            -- internet port scanner finding 10308 -- therefore looks exactly
            -- like a player, which would hold the idle watchdog open forever
            -- and quietly turn a $40/month server into a $470/month one.
            --
            -- Only count clients that have completed login and have both a name
            -- and a ucid.
            local okName, name = pcall(net.get_player_info, id, "name")
            local okUcid, ucid = pcall(net.get_player_info, id, "ucid")

            if okName and okUcid and name and ucid and name ~= "" and ucid ~= "" then
                count = count + 1

                -- Coalition is decoration. If this call fails the player still
                -- counts -- never let a cosmetic lookup change the number the
                -- watchdog bills decisions on.
                if #names < MAX_NAMES then
                    local okSide, side = pcall(net.get_player_info, id, "side")
                    names[#names + 1] = string.format(
                        '{"n":"%s","s":%d}',
                        jsonEscape(name),
                        (okSide and type(side) == "number") and side or 0
                    )
                end
            end
        end
    end

    return count, names
end

local function currentMission()
    local ok, name = pcall(DCS.getMissionName)
    if ok and name and name ~= "" then
        return name
    end
    return "no mission"
end

local function publish(force)
    local now = os.time()

    if not force and (now - lastWrite) < WRITE_INTERVAL then
        return
    end

    -- Server-side simulation rate. This is the number that actually matters for
    -- "is the server struggling?" -- DCS's sim loop is single-threaded, so this
    -- falls long before total CPU looks busy.
    local elapsed = now - lastWrite
    if elapsed > 0 and lastWrite > 0 then
        fps = frameCount / elapsed
    end
    frameCount = 0
    lastWrite = now

    local file = io.open(STATE_FILE, "w")
    if not file then
        -- C:\dcs-state missing or not writable. Nothing useful to do from
        -- inside a hook; the watchdog will see a stale file and act on it.
        return
    end

    local count, names = countPlayers()

    file:write(string.format(
        '{"players":%d,"names":[%s],"mission":"%s","fps":%.1f,"ts":%d}',
        count,
        table.concat(names, ","),
        jsonEscape(currentMission()),
        fps,
        now
    ))
    file:close()
end

function watchdog.onSimulationFrame()
    frameCount = frameCount + 1
    publish(false)
end

function watchdog.onMissionLoadEnd()
    publish(true)
end

function watchdog.onSimulationStop()
    publish(true)
end

function watchdog.onPlayerConnect(id)
    -- Force a write so /dcs status reflects an arrival immediately.
    publish(true)
end

-- Deliberately no forced write on disconnect: in some DCS builds the player is
-- still in net.get_player_list() when this fires, so a forced write would
-- report one player too many. The periodic write corrects it within 15s, which
-- is irrelevant against a 20-minute idle threshold.

DCS.setUserCallbacks(watchdog)
