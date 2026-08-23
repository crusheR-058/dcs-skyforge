# ---------------------------------------------------------------------------
# Region and instance sizing
#
# Verified against the live EC2 API on 2026-08-19:
#
#   ap-south-1 (Mumbai)     m7i.2xlarge  m6i.2xlarge  c7i.2xlarge  r7i.xlarge
#   ap-south-2 (Hyderabad)  m7i.2xlarge  m6i.2xlarge  c7i.2xlarge  r7i.xlarge
#                           r7a.xlarge   <-- AMD Genoa, only in Hyderabad
#
# The AMD Genoa families (m7a / r7a) are NOT offered in Mumbai. If you pick
# Hyderabad, use r7a.xlarge: it is both cheaper and faster per core, and needs
# no Optimize-CPUs trick because 7a instances have no SMT to begin with.
#
#   Mumbai    m7i.2xlarge  4x Sapphire Rapids @ 3.2 GHz  32 GB  $0.6082/hr
#   Hyderabad r7a.xlarge   4x Zen 4          @ 3.7 GHz  32 GB  $0.4980/hr
#
# Both prices are Windows License Included with 4 active vCPUs, confirmed
# against the AWS Pricing API. See README.md for the full comparison.
# ---------------------------------------------------------------------------

variable "region" {
  description = "AWS region. ap-south-1 = Mumbai, ap-south-2 = Hyderabad."
  type        = string
  default     = "ap-south-1"
}

variable "transfer_bucket" {
  description = <<-EOT
    S3 bucket used to hand large files to the server -- aircraft mods and the
    like, which are far too big for Discord's attachment limit and have no
    business passing through a 256 MB Lambda. The instance gets read-only
    access.

    Objects are retained indefinitely (the 7-day expiry rule was deliberately
    removed). It doubles as the mod backup: re-uploading the 3.8 GB Su-30 mod
    over a ~4 Mbps uplink takes over two hours, whereas restoring from here to
    the instance is same-region, free, and takes about two minutes. ~$0.10/month
    is cheap insurance against an AMI rebuild.
  EOT
  type        = string
  default     = "dcs-skyforge-transfer-123456789012"
}

variable "board_bucket" {
  description = <<-EOT
    S3 bucket holding the SkyForge web board (the static app plus the JSON the
    DCS instance publishes). Kept private -- CloudFront reads it through an
    Origin Access Control, so there is no public bucket to misconfigure.
  EOT
  type        = string
  default     = "skyforge-board-123456789012"
}

variable "bot_region" {
  description = <<-EOT
    Region for the Discord bot Lambda. Must be a region that supports Lambda
    Function URLs -- ap-south-2 (Hyderabad) does NOT, which is why this is
    separate from var.region. ap-south-1 (Mumbai) is the natural pick when the
    server is in Hyderabad: same country, and the bot only makes a couple of
    control-plane calls per session so cross-region latency is irrelevant.
  EOT
  type        = string
  default     = "ap-south-1"
}

variable "instance_type" {
  description = "EC2 instance type. Must exist in var.region -- see the table above."
  type        = string
  default     = "m7i.2xlarge"
}

variable "core_count" {
  description = "Physical cores to activate."
  type        = number
  default     = 4
}

variable "threads_per_core" {
  description = <<-EOT
    Set to 1 to disable hyperthreading. This is a real money lever: EC2 bills the
    Windows licence at $0.046 per ACTIVE vCPU-hour, so halving the vCPU count
    halves the licence charge while the instance rate is unchanged. DCS also
    tends to hold frame times better without SMT contention.

    Must be 1 for m7a/c7a/r7a, which have no SMT at all.
  EOT
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 2], var.threads_per_core)
    error_message = "threads_per_core must be 1 or 2."
  }
}

variable "root_volume_gb" {
  description = <<-EOT
    Root volume size. Billed 730 hours a month whether or not you ever boot the
    instance, so it is the line item most worth getting right.

    Sized from measured DCS 2.9.25 *dedicated server* module sizes (the server
    build ships without textures and sounds, so these are far smaller than the
    equivalent client install):

      Fixed overhead                        ~64 GB
        Windows Server 2022 in use    ~16
        Page file (capped by user_data) 8
        Windows Update growth / yr      ~5
        DCS WORLD base                 20.0
        Missions, tracks, logs          ~5
        Free-space safety margin       ~10

      Terrains (add only what you fly)
        Caucasus       11.1     Persian Gulf   22.7
        Marianas       10.0     Sinai          45.3
        Nevada          7.1     Normandy       38.4
        Supercarrier    0.2     Syria          37.3
        Marianas WWII   6.5     Falklands      37.7
        The Channel    18.0     Afghanistan    59.7

    So: 64 + sum(terrains), rounded up.
      90 GB = free terrains only (Caucasus + Marianas)   <-- current default
     125 GB = + Syria
     150 GB = + Syria + Persian Gulf

    Terrains cost nothing to install on a dedicated server, but each player must
    own the terrain to join a mission on it.

    Growing this later is online and non-destructive -- see README.md. To ADD a
    terrain you need its installed AND download size free at the same time
    (Syria: 37.3 + 12.5 = 49.8 GB), so grow the volume BEFORE installing.
  EOT
  type        = number
  default     = 90
}

# ---------------------------------------------------------------------------
# Access
# ---------------------------------------------------------------------------

variable "key_pair_name" {
  description = <<-EOT
    Existing EC2 key pair name. Required: Windows encrypts the Administrator
    password with this key, and you need that password to RDP in over the SSM
    tunnel to run the DCS installer. Create one with:
      aws ec2 create-key-pair --key-name dcs-admin --region <region> \
        --query KeyMaterial --output text > dcs-admin.pem
  EOT
  type        = string
}

variable "admin_email" {
  description = "Email address for budget alerts."
  type        = string
}

# ---------------------------------------------------------------------------
# Game server
# ---------------------------------------------------------------------------

variable "server_name" {
  description = "Name tag for the instance."
  type        = string
  default     = "dcs-server"
}

variable "dcs_port" {
  description = "DCS game port, TCP and UDP. Must match serverSettings.lua."
  type        = number
  default     = 10308
}

variable "enable_srs" {
  description = "Open port 5002 TCP+UDP for DCS-SimpleRadio-Standalone."
  type        = bool
  default     = true
}

variable "srs_port" {
  description = "SRS server port."
  type        = number
  default     = 5002
}

# ---------------------------------------------------------------------------
# Cost controls
# ---------------------------------------------------------------------------

variable "monthly_budget_usd" {
  description = <<-EOT
    Monthly budget threshold in USD, pre-GST. The plan targets ~$41/month
    pre-GST at 35 playing hours, so 60 leaves headroom without being so loose
    that a runaway instance goes unnoticed.
  EOT
  type        = number
  default     = 60
}

variable "nightly_stop_cron" {
  description = <<-EOT
    Backstop force-stop schedule, in var.schedule_timezone. This fires
    regardless of what the in-guest watchdog believes, and is the rule that
    saves you the month the watchdog silently fails.
  EOT
  type        = string
  default     = "cron(0 3 * * ? *)"
}

variable "schedule_timezone" {
  description = "IANA timezone for the nightly stop schedule."
  type        = string
  default     = "Asia/Kolkata"
}

variable "windows_timezone" {
  description = "Windows timezone ID set on the instance at first boot."
  type        = string
  default     = "India Standard Time"
}

variable "snapshot_retain_count" {
  description = <<-EOT
    Daily snapshots to retain. Only the first stores the full volume; the rest
    are incremental, so seven dailies cost barely more than two weeklies --
    roughly $5/month against a ~72 GB volume.

    This protects the DCS install, mods and config. It is NOT the campaign's
    main safety net: server\campaign-backup.ps1 pushes the Pretense save to S3
    every 15 minutes, because that is the one genuinely irreplaceable thing
    here and a day-old snapshot of it is not good enough.
  EOT
  type        = number
  default     = 7
}

# ---------------------------------------------------------------------------
# Discord bot
# ---------------------------------------------------------------------------

variable "discord_public_key" {
  description = <<-EOT
    Ed25519 public key from the Discord Developer Portal (General Information).
    The Lambda verifies every request signature against this. Leave empty to
    skip deploying the bot entirely.
  EOT
  type        = string
  default     = ""
}

variable "discord_guild_id" {
  description = "Discord server (guild) ID. Commands from any other guild are rejected."
  type        = string
  default     = ""
}

variable "discord_role_id" {
  description = <<-EOT
    Optional Discord role ID required to run the commands. Leave empty to allow
    anyone in the guild. Setting this is the difference between your friends
    starting the server and anyone who wanders into the Discord doing so.
  EOT
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Game nights and automatic patching
# ---------------------------------------------------------------------------

variable "enable_game_nights" {
  description = <<-EOT
    Pre-start the server on a schedule so nobody has to remember /dcs start
    and nobody waits out a cold boot. Costs nothing extra when people turn up
    -- the hours would have been burned anyway -- and one watchdog grace
    period (~$0.40) on a night they do not.
  EOT
  type        = bool
  default     = true
}

variable "game_nights" {
  description = <<-EOT
    Game nights, as name => cron, evaluated in var.schedule_timezone. Set the
    time ~15 minutes BEFORE people actually want to fly: a cold boot to
    joinable is 3-5 minutes, and server\announce.ps1 posts to Discord the
    moment it is genuinely up.

    EventBridge cron is six fields: minute hour day-of-month month day-of-week
    year. Note day-of-week and day-of-month are mutually exclusive -- one must
    be "?".

    Change these to whatever the group actually plays, or set
    enable_game_nights = false to drop the whole idea.
  EOT
  type        = map(string)

  default = {
    wednesday = "cron(45 19 ? * WED *)"
    saturday  = "cron(45 19 ? * SAT *)"
  }
}

variable "enable_auto_update" {
  description = <<-EOT
    Run the DCS updater weekly in an unattended maintenance window.

    This is the highest-value automation here: a DCS client refuses to join a
    server on a different build, so the first session after an Eagle Dynamics
    release fails for everyone at once, and the error players see says nothing
    about patching. Catching it on a Thursday morning beats discovering it at
    the start of Saturday night.

    Costs roughly one watchdog grace period per week (~$0.40) because the
    instance boots solely to patch and is then stopped by the idle watchdog.
  EOT
  type        = bool
  default     = true
}

variable "maintenance_boot_cron" {
  description = "When to start the instance for its weekly patch window."
  type        = string
  default     = "cron(0 5 ? * THU *)"
}

variable "maintenance_update_cron" {
  description = <<-EOT
    When to fire the updater. Must be comfortably after
    var.maintenance_boot_cron -- SSM SendCommand fails outright against an
    instance whose agent has not registered yet, it does not queue. Ten
    minutes against a ~3 minute boot is deliberate slack.
  EOT
  type        = string
  default     = "cron(10 5 ? * THU *)"
}

variable "board_url" {
  description = <<-EOT
    Public base URL of the web board's data directory. The Discord bot reads
    status.json from here for /dcs status: the in-guest publisher rewrites it
    every ~15 seconds, whereas the watchdog only refreshes the SSM parameter
    every 5 minutes, and it carries the roster, sim FPS, uptime and zone
    balance that SSM does not.

    Leave empty to fall back to the SSM parameter.
  EOT
  type        = string
  default     = ""
}
