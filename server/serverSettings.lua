--[[
    Template for:
      %USERPROFILE%\Saved Games\DCS.server\Config\serverSettings.lua

    Copy this in, edit the marked values, then start the server.

    NOTE: DCS rewrites this file when the server shuts down, and it strips
    comments when it does. Treat the copy in this repo as the reference and
    re-copy it if you ever need to reset. Do not commit a real password.
--]]

cfg =
{
    -- ---------------------------------------------------------------------
    -- Identity
    -- ---------------------------------------------------------------------

    ["name"] = "DCS SkyForge",
    ["description"] = "Private server. Ask in Discord for the password.",

    -- SET A PASSWORD. Without one, your server is listed publicly and
    -- strangers will join, which costs you CPU and bandwidth you are paying
    -- for by the hour.
    ["password"] = "CHANGE ME",

    -- true = advertise on the public server browser. The password above still
    -- gates entry; listing only makes the server visible, with a padlock icon
    -- showing it is protected.
    --
    -- Safe here because the player-count hook only counts clients that have
    -- completed login (name AND ucid), so the curiosity connects a public
    -- listing attracts cannot hold the idle watchdog open and keep the instance
    -- billing. That fix was made before this was ever switched on.
    ["isPublic"] = true,

    -- ---------------------------------------------------------------------
    -- Network
    --
    -- Must match var.dcs_port in infra/variables.tf, the Windows Firewall
    -- rules from user_data, and the security group. All four have to agree or
    -- connections fail with no useful error.
    -- ---------------------------------------------------------------------

    ["port"] = 10308,
    ["bind_address"] = "",

    -- Sized for the 4-core instance in the plan. Raising this is the fastest
    -- way to turn a smooth server into a stuttering one.
    ["maxPlayers"] = 16,

    -- 0 = no ping limit. Set e.g. 300 to kick players whose connection is bad
    -- enough to degrade everyone else's experience.
    ["maxPing"] = 0,

    -- ---------------------------------------------------------------------
    -- Integrity checking -- DELIBERATELY ALL OFF
    --
    -- The "pure" settings reject clients whose files differ from the server's.
    -- They are the single most common reason a friend with mods cannot join,
    -- so they are off here: this group flies community aircraft such as the
    -- Su-30MKI.
    --
    -- Understand the trade: with these off the server cannot tell a livery pack
    -- from a cheat. That is an acceptable trade for a private, password-locked
    -- server full of people you know, and a bad one for a public server.
    -- ---------------------------------------------------------------------

    ["require_pure_clients"] = false,
    ["require_pure_textures"] = false,
    ["require_pure_models"] = false,
    ["require_pure_scripts"] = false,

    -- ---------------------------------------------------------------------
    -- Mission rotation
    --
    -- Absolute paths to .miz files. Put missions somewhere stable such as
    -- C:\dcs-missions so an AMI rebuild does not scatter them.
    -- ---------------------------------------------------------------------

    ["missionList"] =
    {
        -- [1] = "C:\\dcs-missions\\caucasus-cap.miz",
    },

    ["listLoop"] = true,
    ["listShuffle"] = false,
    ["listStartIndex"] = 1,

    -- 1 = resume the mission when the first player joins. Keeps the sim from
    -- burning CPU simulating an empty world, which matters when you are paying
    -- $0.61 an hour for that CPU.
    ["mode"] = 0,

    ["advanced"] =
    {
        ["resume_mode"] = 1,
        ["pause_on_load"] = false,

        -- Server-side admin over the WebGUI on port 8088. Reach it by SSM
        -- tunnel only -- it is NOT open in the security group, deliberately.
        ["allow_players_pool"] = false,

        -- Export permissions. Needed by Tacview, SRS and LotAtc.
        ["allow_ownship_export"] = true,
        ["allow_object_export"] = true,
        ["allow_sensor_export"] = true,

        ["allow_change_skin"] = true,
        ["allow_change_tailno"] = true,
        ["allow_change_position"] = false,
        ["allow_dynamic_radio"] = false,
        -- Lets people join using ED's time-limited module trials. Note this is
        -- about ED's trial system, NOT community mods -- mod aircraft are
        -- allowed by the require_pure_* settings above, not by this.
        ["allow_trial_only_clients"] = true,

        ["voice_chat_server"] = false, -- using SRS instead

        ["event_Connect"] = true,
        ["event_Crash"] = true,
        ["event_Eject"] = true,
        ["event_Takeoff"] = true,
        ["event_Role"] = true,
        ["disable_events"] = false,
    },
}
