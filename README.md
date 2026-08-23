# DCS World Dedicated Server on AWS EC2

> **Values in this repo are placeholders.** It is published from a real,
> running deployment, so every account ID, IP, instance ID and password has
> been replaced with a documentation-range example:
>
> | Placeholder | What it is |
> |---|---|
> | `123456789012` | AWS account ID |
> | `203.0.113.10` | server public IP (RFC 5737) |
> | `i-0123456789abcdef0` | EC2 instance ID |
> | `vol-0123456789abcdef0` | root EBS volume ID |
> | `d111111abcdef8` | CloudFront distribution domain |
> | `abcdefghij` | API Gateway ID |
> | `000000000000000000` | Discord guild ID |
> | `CHANGE-ME` | DCS server join password |
>
> The PowerShell scripts in [`server/`](server/) take these as `param()`
> defaults, so pass your own or edit the defaults before deploying. Nothing
> here will reach someone else's server by accident, and nothing here is a
> working credential.

An on-demand DCS World server for a small group. It boots when someone types
`/dcs start` in Discord, and shuts itself down when the last person leaves.

**Cost: ~$40/month (≈ ₹3,500) at two 4-hour game nights a week**, including 18% GST.

> ## Deployed and running
>
> | | |
> |---|---|
> | Region | `ap-south-2` (Hyderabad) |
> | Instance | `i-0123456789abcdef0` — `r7a.xlarge`, 4× AMD EPYC 9R14 (Zen 4) @ 3.7 GHz, 32 GB |
> | **Join address** | **`203.0.113.10:10308`** — Multiplayer → **Connect by IP** |
> | Server name | `DCS SkyForge` |
> | **Join password** | **`CHANGE-ME`** |
> | Mission | `Pretense_caucasus_dynspawn_v2.miz` — dynamic spawn + hot start + dynamic cargo, all 21 airbases |
> | DCS | 2.9.28.26385 — WORLD, Caucasus, Marianas, Supercarrier, WWII-Armour |
> | Volume | 100 GB gp3 (grown from 90 mid-install), 25.6 GB free after three mods |
> | Rate | **$0.4980/hr** ($0.3140 baseline + 4 × $0.046 licence) |
>
> **Publicly listed** as `DCS SkyForge` (`isPublic = true`) — the password still
> gates entry; listing only makes it visible, with a padlock icon.
>
> **Voice:** SRS **2.3.8.2** on port 5002, matched to the client version. Clients
> auto-connect via `DCS-SRS-AutoConnectGameGUI.lua`; `-freqs` in chat lists
> frequencies.
>
> **Verified working:** account authorized (`Login success` / `Successfully got
> authorization data`), mission loaded, TCP+UDP 10308 reachable from the public
> internet, and **unattended startup confirmed — ~3 minutes from reboot to
> joinable with nobody touching anything.**
>
> **Mods:** Su-30MKI ("Flanker Ex" by Codename Flanker, `Su-30_EFM_V2.8.06b`)
> installed and **flight-tested in multiplayer**. Hercules 6.8.2 (Anubis) and
> UH-60L 2.1.5 (Kinkku) added 2026-08-21 -- the latter also registers
> `UH-60L_DAP` and a `KC-130J` tanker, so that one package is three airframes.
> Integrity checks are off, so client-side mods are accepted.

The design has exactly one organising principle: **the server should not exist
between game nights.** DCS is Windows-only, EC2 charges $0.046 per vCPU-hour for
the Windows licence, and running this 24/7 costs **~$547/month**. Everything here
exists to make sure that never happens by accident.

---

## The cost model

All figures verified against the **AWS Pricing API** and the **EC2 API** on
2026-08-19. Reproduce them yourself with the commands in
[Verifying the prices](#verifying-the-prices).

### How EC2 bills a Windows instance

The bill has two independent parts:

```
  total/hr  =  instance baseline rate  +  ($0.046 x ACTIVE vCPUs)
```

That second term is why `threads_per_core = 1` is set in the Terraform.
Disabling hyperthreading halves the active vCPU count, so it halves the licence
charge — **while the baseline rate is unchanged**. You keep all 4 physical cores.
DCS also tends to hold frame times better without SMT contention, so this is
cheaper *and* slightly faster.

Since October 2025, AWS's Optimize CPUs feature applies this saving to the
licence fee, not just the core count. The Pricing API shows both halves:

| m7i.2xlarge, Mumbai | $/hr |
|---|---|
| `License Included - Infrastructure` (baseline) | 0.4242 |
| Bundled Windows at the full 8 vCPUs | 0.7922 |
| **Our config: baseline + 4 × $0.046** | **0.6082** |

### Region choice: Mumbai vs Hyderabad

Verified against the live EC2 API — **the AMD Genoa families are not in Mumbai**:

| Region | Available (of those checked) |
|---|---|
| `ap-south-1` Mumbai | `m7i.2xlarge` `m6i.2xlarge` `c7i.2xlarge` `r7i.xlarge` |
| `ap-south-2` Hyderabad | the same, **plus `r7a.xlarge`** |

That makes it a real decision:

| | Mumbai `m7i.2xlarge` | Hyderabad `r7a.xlarge` |
|---|---|---|
| Cores | 4 × Sapphire Rapids @ 3.2 GHz | 4 × Zen 4 @ 3.7 GHz |
| RAM | 32 GB | 32 GB |
| SMT | disabled via Optimize CPUs | none to begin with |
| **$/hr (Windows)** | **0.6082** | **0.4980** |
| At 35 hrs/mo | $21.29 | $17.43 |

Hyderabad is **18% cheaper and roughly 20% faster per core** — and DCS is
single-thread bound, so per-core speed is the thing that matters. Storage is
priced identically ($0.0912/GB-month) in both, and `ap-south-2` has every
service this build needs (EC2, Lambda, EventBridge Scheduler, SSM, DLM).

The catch is latency. Mumbai has far better national peering and is the landing
point for most submarine cables. **Have your friends test both before deciding:**

```powershell
# Rough regional latency check from each player's machine
Test-Connection ec2.ap-south-1.amazonaws.com -Count 10 | Measure-Object ResponseTime -Average
Test-Connection ec2.ap-south-2.amazonaws.com -Count 10 | Measure-Object ResponseTime -Average
```

**Hyderabad was chosen** — cheaper on both axes that matter. But this is the one
decision made without data from the people who actually have to live with it, so
validate it: if anyone's ping to `ap-south-2` is much worse than to `ap-south-1`,
move. $3.86/month is not worth one friend having a bad time. Switching is two
lines in `terraform.tfvars` plus a `terraform apply` (the instance is replaced,
so do it *before* installing DCS, not after).

### Monthly bill, 35 playing hours

| Line item | Basis | USD |
|---|---|---|
| EC2 compute + Windows licence | 35 hrs × $0.4980 | 17.43 |
| EBS gp3 storage | 100 GB × $0.0912 — **billed 730 hrs** | 9.12 |
| Elastic IP | 730 hrs × $0.005 | 3.65 |
| Snapshots | ~71 GB used × $0.05, weekly retain 2 | 3.55 |
| Data transfer out | ~12 GB, under the 100 GB free allowance | 0.00 |
| Lambda, EventBridge, SSM Parameter Store | free tier | 0.00 |
| **Subtotal** | | **33.75** |
| GST 18% (AWS India bills via AISPL, in INR) | | 6.08 |
| **Total** | | **≈ $39.83** |

**One-time setup:** ~8 instance-hours for the download and install ≈ **$4.70**.

**New AWS account?** The post-July-2025 free tier gives $100 on signup plus $100
more for five onboarding tasks — realistically your **first 4–5 months are free**.

Snapshot cost is dominated by the first full copy, so retention *count* drives it
far more than cadence. If you'd rather not pay $3.25/month to avoid ever redoing
the install, delete `aws_dlm_lifecycle_policy.snapshots` — the DCS install is
free to re-download and all config lives in this repo.

### Two things worth internalising

**1. Compute is only half the bill.** The always-on floor — storage + IP +
snapshots — is **$16.32/month even in a month you never fly**. So install only
the terrains you actually use. They're free to install on a dedicated server,
which is precisely the trap. Every 10 GB trimmed saves $0.91/month forever.

### Sizing the disk

Measured DCS 2.9.25 **dedicated server** module sizes. The server build ships
without textures and sounds, so these are far smaller than the client equivalents
(client Syria is ~70 GB; server Syria is 37.3 GB).

| Fixed overhead | GB | | Terrain | GB | | Terrain | GB |
|---|---|---|---|---|---|---|---|
| Windows Server 2022 | ~16 | | Caucasus *(free)* | 11.1 | | Syria | 37.3 |
| Page file (capped) | 8 | | Marianas *(free)* | 10.0 | | Normandy | 38.4 |
| Update growth / yr | ~5 | | Marianas WWII | 6.5 | | Falklands | 37.7 |
| DCS WORLD base | 20.0 | | Nevada | 7.1 | | Sinai | 45.3 |
| Missions, tracks, logs | ~5 | | Supercarrier | 0.2 | | Afghanistan | 59.7 |
| Free-space margin | ~10 | | The Channel | 18.0 | | Kola | 66.7 |
| **Total** | **~64** | | Persian Gulf | 22.7 | | Iraq | 69.3 |

**Provision 64 GB + the terrains you install.** Now 100 GB: 64 + Caucasus +
Marianas, grown from 90 during install, then the 3.8 GB Su-30 mod on top —
28.9 GB free.

Windows' system-managed page file would have sized itself against 32 GB of RAM
and taken roughly that much disk — ~$2.92/month to hold a file a headless server
never meaningfully touches. `user_data` caps it at 8 GB.

**Growing the volume** is online and needs no downtime. Do it *before* adding a
terrain, because the updater needs the installed **and** download size free
simultaneously (Syria: 37.3 + 12.5 = 49.8 GB):

```powershell
aws ec2 modify-volume --volume-id vol-0123456789abcdef0 --size 130 --region ap-south-2
# then, inside Windows:
Resize-Partition -DriveLetter C -Size (Get-PartitionSupportedSize -DriveLetter C).SizeMax
```

**2. The failure mode is human, not technical.**

| Usage | USD/mo incl. GST |
|---|---|
| 20 hrs | ~$30 |
| **35 hrs (planned)** | **~$40** |
| 60 hrs | ~$53 |
| 120 hrs | ~$88 |
| **24/7** | **~$447** |

Hence three *independent* stop mechanisms: the in-guest idle watchdog, a nightly
EventBridge force-stop, and a budget alarm. Any one can fail silently.

> **If you ever genuinely want a persistent 24/7 server, stop using EC2.**
> Hetzner with a Windows licence is ~$65/month and managed DCS hosts are $30–60 —
> 8–10× cheaper at that duty cycle. EC2 is the right tool here *because* you want
> the server gone between sessions.

---

## What you do and don't need to buy

**You do not need to buy any terrain modules for the server.** Eagle Dynamics is
explicit: *"Terrain and WWII units doesn't asked activations when launched in
server mode without rendering, server owner shouldn't buy them."* The modular
dedicated-server installer ships without textures and sounds, and headless
terrains need no activation.

**Your friends still need to own** the terrain the mission uses and any paid
aircraft they want to fly. That part is unchanged.

---

## Layout

```
infra/          Terraform: instance, networking, IAM, safety nets, Lambda
  main.tf         VPC/SG/IAM/instance/EIP
  automation.tf   nightly force-stop, budget alarm, snapshot policy
  bot.tf          Discord bot Lambda + Function URL
  user_data.ps1.tftpl   first-boot Windows prep

bot/            Discord slash-command bot
  handler.py      Ed25519 verification, /dcs start|stop|status
  build.ps1       vendors PyNaCl for the Lambda runtime
  register_commands.py

server/         Runs on the Windows instance
  setup.ps1             one-time post-DCS-install configuration
  watchdog.ps1          idle shutdown (the script that protects the budget)
  serverSettings.lua    annotated DCS config template
  Hooks/playercount.lua publishes live player count
```

---

## How it runs (and why it's built this way)

Two findings from the live build shaped the final design. Both are non-obvious
and both will bite anyone who rebuilds this from the original plan.

### DCS will not run headlessly in session 0

Started as SYSTEM on an `-AtStartup` trigger, `DCS_server.exe` reaches ~222 MB,
writes exactly 10 log lines, and hangs forever. It is blocked on a **`DCS Login`
dialog** (a plain Win32 `#32770`) that has no session to draw into. UI Automation
cannot even enumerate the window from session 0 — it reports zero windows.

The working arrangement:

| | |
|---|---|
| Autologon | enabled for `Administrator`, so an interactive session always exists |
| `DCS-Server` task | `-AtLogOn`, running as `Administrator`, `LogonType Interactive` |
| First login | driven once into the dialog by `server\dcs-login-uia.ps1` |

**A hand-written `autologin.cfg` does not work** — DCS ignores it. The file must
be produced by DCS itself after a real login with *Save password* and *Auto
login* ticked. After that it never prompts again, which is what makes remote
start work.

The autologon password sits in the registry. That is acceptable here *only*
because 3389 is closed to the internet and all admin goes through SSM.

### A bare TCP connect looks like a player

`net.get_player_list()` includes sockets that have not authenticated. A single
`Test-NetConnection` against port 10308 — or any internet port scanner finding a
well-known DCS port — shows up as a connected player. Left unhandled that pins
the idle watchdog open forever and quietly turns a $38/month server into a
$447/month one.

`server\Hooks\playercount.lua` therefore counts a client only once it has **both
a name and a ucid**. Verified: 2 probe connections → reported as 0 players.

### Security note

This account uses **root credentials**. Create an IAM or Identity Center user
and use that instead — root access keys cannot be scoped or rotated cleanly, and
this project can publish a public Lambda URL.

---

## Remaining steps

Everything below is optional; the server is already playable.

### 1. Test it with a friend  ← do this first

Have someone open DCS → **Multiplayer → Connect by IP** → `203.0.113.10:10308`,
password `CHANGE-ME`. Then watch the count land server-side:

```powershell
aws ssm send-command --region ap-south-2 --instance-ids i-0123456789abcdef0 `
  --document-name AWS-RunPowerShellScript `
  --parameters commands='Get-Content C:\dcs-state\players.json' `
  --query Command.CommandId --output text
```

Then leave it empty and confirm it stops itself within 20 minutes — the test
that separates a $38 month from a $447 one.

### 2. Admin access (RDP), if you ever need it

There is no inbound RDP port; you tunnel through SSM:

```powershell
aws ec2 get-password-data --instance-id i-0123456789abcdef0 `
  --priv-launch-key "dcs-admin.pem" --region ap-south-2 --query PasswordData --output text

aws ssm start-session --target i-0123456789abcdef0 --region ap-south-2 `
  --document-name AWS-StartPortForwardingSession `
  --parameters portNumber=3389,localPortNumber=13389
```

Then `mstsc /v:localhost:13389`, user `Administrator`.

Most day-to-day work needs no RDP at all — `aws ssm send-command` with
`AWS-RunPowerShellScript` is how this whole server was built and configured.

### 3. Swap in your own missions

Drop `.miz` files into
`C:\Users\Administrator\Saved Games\DCS.server\Missions\` and list them in
`missionList` in `serverSettings.lua`. The current mission is a dynamic-spawn
Caucasus map chosen as a working default — replace it with whatever your group
actually wants to fly.

### 4. Wire up Discord — deployed, one manual step left

| | |
|---|---|
| **Interactions URL** | `https://abcdefghij.execute-api.ap-south-1.amazonaws.com/` |
| Lambda | `dcs-server-bot` in **ap-south-1**, controls the instance in ap-south-2 |
| Commands | `/dcs start`, `/dcs stop`, `/dcs status` — registered to guild `000000000000000000` |
| Locked to | that guild only; set `discord_role_id` to also require a role |

**Lambda Function URLs do not work in this account.** With `authorization_type
= "NONE"` and a resource policy granting `Principal: "*"` on
`lambda:InvokeFunctionUrl`, every request still returned
`403 Forbidden … urls-auth.html` and **no log stream was ever created** — the
request never reached the function. Not an Organizations SCP (the account is
standalone). The pre-existing `arma3-discord` bot in the same account shows the
identical fingerprint: a leftover `FunctionURLAllowPublicAccess` statement, no
URL config, and an API Gateway in front of it.

So the bot is fronted by an **API Gateway HTTP API** (`POST /`, `AWS_PROXY`,
payload format 2.0). Payload 2.0 hands the handler the same event shape a
Function URL would, so `handler.py` needed no changes. Verified: forged and
unsigned requests now return the handler's own **401**, not an upstream 403.

Two regional constraints worth remembering: Hyderabad has no Function URLs at
all, hence `var.bot_region` — and the Lambda therefore needs `TARGET_REGION` so
boto3 points at the server's region rather than its own.

1. Discord Developer Portal → New Application. Copy the **Public Key**.
2. Build the Lambda package (vendors PyNaCl's **Linux** wheels from Windows, no
   Docker needed):

```powershell
cd bot
.\build.ps1
```

3. Put the key in `terraform.tfvars` as `discord_public_key`, along with
   `discord_guild_id` and (recommended) `discord_role_id` — that last one is the
   difference between "my friends" and "anyone who wanders into the Discord"
   being able to spend your money.
4. `terraform apply`, then copy the `discord_interactions_url` output into
   **General Information → Interactions Endpoint URL**. Discord immediately
   sends a signed PING; if it saves, signature verification works.
5. Register the commands:

```powershell
cd bot
$env:DISCORD_APP_ID="..."; $env:DISCORD_BOT_TOKEN="..."; $env:DISCORD_GUILD_ID="..."
python register_commands.py
```

### 5. Installing aircraft mods

**You cannot install aircraft modules on a DCS dedicated server.** Its entire
installable module list is terrains plus `WORLD`, `SUPERCARRIER` and
`WWII-ARMOUR` — there is no FC3, Su-25T or Su-33 module for it. You don't need
them either: `WORLD` already ships 37 aircraft definitions in
`CoreMods\aircraft` and the FC3 liveries in `Bazar\Liveries`. A mod's "requires
FC3" note is a **client** requirement, exactly like terrain ownership.

Community mods *are* installed server-side, because the server needs them to
parse missions containing those slots. They're far too big for Discord's
10–25 MB attachment cap, so they travel by S3:

```powershell
# 1. from your laptop -- parallel and resumable
aws s3 sync "$env:USERPROFILE\Saved Games\DCS\Mods\aircraft\<ModFolder>" `
  s3://dcs-skyforge-transfer-123456789012/<prefix>/ --region ap-south-2

# 2. on the server, via SSM
& C:\dcs-state\install-mod.ps1 -Prefix "<prefix>/" -ModName "<ModFolder>"

# 3. restart to load it
Start-ScheduledTask -TaskName DCS-Server
```

`ModName` must match the original folder name — the mod's `Entry.lua` resolves
everything relative to `current_mod_path`.

**Don't trim a mod to save upload time.** Read its `Entry.lua` first: the Su-30
mod `dofile()`s its Weapons and FM scripts, needs `Cockpit/Scripts/` for
`make_flyable()`, and `mount_vfs`'s Textures, Shapes, Liveries and Skins — so
almost nothing is safely omittable despite 3.26 GB of it being art the server
never draws.

**Never install a mod's `Scripts\Hooks\` file on the server.** Mod packages
often bundle one -- the UH-60L ships `bhHook.lua` to drive its door gunners.
These are **client-side**: they call `Export.LoGetSelfData()` and
`LoGetPlayerPlaneId()`, which mean nothing on a headless server with no local
player, and `bhHook.lua` also calls `tcp:close()` on a possibly-`nil` socket in
`onSimulationStop`. A GUI hook is what crashed this server twice on 2026-08-21
(see the live-map note below). Install **only** `Mods\aircraft\<ModFolder>`;
the Hooks file belongs in each *pilot's* own `Saved Games\DCS\Scripts\Hooks\`.

**Every pilot needs the identical mod version locally**, or the airframe will
not appear in their dynamic-spawn list. Server-side install alone is not enough.

**Log noise you can ignore** after installing a mod:
`negative drag/weight of payload` (the mod's own payload data — ED's stock
modules produce identical errors) and `No suitable driver found to mount
bazar/...` (normal under `--norender`).

### 6. Bake an AMI

Once it all works, snapshot it. Rebuilding then takes 10 minutes instead of a day.

```powershell
aws ec2 create-image --instance-id i-0123456789abcdef0 --name "dcs-server-$(Get-Date -f yyyyMMdd)" --region ap-south-2
```

---

## Verify before you trust it

Run these in order. **Step 4 is the one that matters** — it is the difference
between a $38 month and a $447 month.

| # | Test | Pass condition |
|---|---|---|
| 1 | `describe-instances ... CpuOptions` | `CoreCount: 4, ThreadsPerCore: 1` |
| 2 | SSM session connects | works with an **empty** inbound security group |
| 3 | Friend connects to `<ip>:10308` | joins the server |
| 4 | **Leave it empty and walk away** | instance reaches `stopped` on its own within 45 min |
| 5 | Reboot | DCS comes back up unattended |
| 6 | `/dcs start` in Discord | `running` in ~60 s, joinable in ~5 min |
| 7 | After 30 days: Cost Explorer by service | within ~15% of $38 |

Watch the watchdog reason in real time:

```powershell
Get-Content C:\dcs-state\watchdog.log -Tail 20 -Wait
& C:\dcs-state\watchdog.ps1 -WhatIf -Verbose   # dry run, never shuts down
```

---

## Running it

### Game night

Nothing to do. `infra/schedules.tf` pre-starts the server 15 minutes before
each entry in `var.game_nights` (Wed and Sat 19:45 IST by default), and
`server/announce.ps1` posts to Discord the moment it is genuinely joinable —
process up, hook writing, port 10308 listening. Those are three to five minutes
after the instance starts, and announcing the wrong one teaches people to
ignore the message.

`/dcs start` still works for an unscheduled session, and the announcement fires
for that too since it is triggered by boot rather than by the schedule.

Nobody needs to stop it. The watchdog does that 20 minutes after the last
person leaves, so a night nobody turns up to costs one grace period — roughly
$0.40 — and stops itself.

Change the nights in `terraform.tfvars`:

```hcl
game_nights = {
  wednesday = "cron(45 19 ? * WED *)"
  saturday  = "cron(45 19 ? * SAT *)"
}
```

EventBridge cron is six fields — `minute hour day-of-month month day-of-week
year` — and day-of-month/day-of-week are mutually exclusive, so one is always
`?`. Set `enable_game_nights = false` to drop the whole idea.

### Patch day — automated

DCS updates every few weeks and **the server build must match the client build**
or nobody can join. The failure is unusually nasty: it hits everyone at once,
and what players see is a bare "connection failed" that says nothing about
patching.

So it runs itself. `maintenance_boot_cron` starts the instance at 05:00 IST on
Thursday, `maintenance_update_cron` fires `server/update-dcs.ps1` ten minutes
later, and the idle watchdog stops the box afterwards. The result — updated,
already current, or failed — is posted to the Discord webhook, including a
reminder that everyone must update their own client to the same build.

Thursday is deliberate: it leaves days of slack before the weekend rather than
discovering a broken build at the start of Saturday night.

Cost is about **$0.40/week** — the instance boots solely to patch and is then
stopped by the watchdog after its first-join grace period.

For a mid-week hotfix, `/dcs update` does the same thing on demand. It refuses
while anyone is connected; patching takes DCS down for several minutes and
there is no polite way to do that to someone on final.

The ten-minute gap between the two schedules is not padding. SSM `SendCommand`
against an instance whose agent has not registered yet **fails outright rather
than queueing**, and a cold Windows boot to SSM-online is about three minutes.

Manual fallback, if the automation is ever disabled:

```powershell
aws ssm send-command --region ap-south-2 --instance-ids i-0123456789abcdef0 \
  --document-name AWS-RunPowerShellScript \
  --parameters 'commands=["& C:\\dcs-state\\update-dcs.ps1 -Reason manual"]'
```

### Monthly cost review

```powershell
aws ce get-cost-and-usage --time-period Start=2026-08-01,End=2026-09-01 `
  --granularity MONTHLY --metrics UnblendedCost --group-by Type=DIMENSION,Key=SERVICE
```

If EC2 compute is well above ~$17, the instance is running when it shouldn't be.
Check `C:\dcs-state\watchdog.log` first.

### Taking a break

Storage keeps billing at ~$13.68/month whether or not you play. For a long
break, snapshot and delete the volume:

```powershell
aws ec2 create-snapshot --volume-id vol-0123456789abcdef0 --description "DCS hiatus" --region ap-south-2
terraform destroy   # note: root volume has delete_on_termination = false
```

---

## Verifying the prices

Nothing here is quoted from memory. Reproduce it:

```powershell
# Which instance families actually exist in a region
aws ec2 describe-instance-type-offerings --location-type region --region ap-south-2 `
  --filters "Name=instance-type,Values=m7i.2xlarge,r7a.xlarge,m7a.2xlarge" `
  --query "InstanceTypeOfferings[].InstanceType" --output text

# Authoritative Windows pricing, both halves of the bill
$f = @('Type=TERM_MATCH,Field=instanceType,Value=r7a.xlarge',
       'Type=TERM_MATCH,Field=location,Value=Asia Pacific (Hyderabad)',
       'Type=TERM_MATCH,Field=tenancy,Value=Shared',
       'Type=TERM_MATCH,Field=capacitystatus,Value=Used',
       'Type=TERM_MATCH,Field=operatingSystem,Value=Windows')
$r = aws pricing get-products --service-code AmazonEC2 --region us-east-1 --filters $f --output json | ConvertFrom-Json
foreach ($p in $r.PriceList) {
  $o = $p | ConvertFrom-Json
  $o.terms.OnDemand.PSObject.Properties.Value.priceDimensions.PSObject.Properties.Value |
    ForEach-Object { "{0,-40} {1}" -f $o.product.attributes.licenseModel, $_.pricePerUnit.USD }
}
```

---

## Troubleshooting

**A pilot's stats are missing and nothing errors.** Check whether their name
is non-ASCII. DCS and Pretense write JSON as **UTF-8 without a BOM**, and
PowerShell 5.1's `Get-Content` *without* `-Encoding UTF8` decodes BOM-less
files as ANSI. `Терминатор` becomes `Ð¢ÐµÑ€Ð¼Ð¸Ð½Ð°Ñ‚Ð¾Ñ€`, the humans
whitelist never matches the correctly-decoded log, and that pilot's entire
combat record is dropped in silence. He had 1,184 combat log lines and zero
rows in `combat.json`.

The rule now applied throughout `server\`:

```powershell
# reading anything DCS or Pretense wrote
Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json

# writing anything Lua or a browser will read -- UTF-8 with NO BOM
[IO.File]::WriteAllText($file, $json, (New-Object Text.UTF8Encoding($false)))
```

Both halves matter and they fail in opposite directions. `Set-Content -Encoding
utf8` **emits** a BOM on 5.1, which Lua rejects with `unexpected symbol near`
and `response.json()` throws on — that cost a DCS restart when it landed in
`Config\dcs-grpc.lua`. Verify with:

```powershell
$b=[IO.File]::ReadAllBytes($f); $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF
```

**`ConvertFrom-Json` nests arrays when piped.** On 5.1, `@(Get-Content f -Raw |
ConvertFrom-Json)` on a JSON *array* returns one element containing the array;
called positionally, `@(ConvertFrom-Json (Get-Content f -Raw))` enumerates
correctly. Measured 1 vs 29 on the airbase cache. The output still looked like
valid JSON, with 29 airbases collapsed into one entry whose `n` was a list of
29 names.

**PowerShell strips quotes from native-command arguments.** `-d '{"a":1}'`
reaches `grpcurl.exe` as `{a:1}` and is rejected as malformed JSON — silently,
returning null. `'{}'` survives because it contains no quotes, which is exactly
why the simple gRPC calls worked and every parameterised one did not. Escape
them (`$body -replace '"','\"'`) before passing.

**A long-running child hangs SSM Run Command.** `Start-Process` for something
like a 24-hour `grpcurl` stream leaves it in the caller's process tree, and Run
Command waits on the whole tree. Launch it via Task Scheduler instead, which
owns the process independently.

**The web board is frozen but every health check says the publisher is fine.**
Check that the log is *growing*, not that the task reports success:

```powershell
$a=(Get-Item C:\dcs-state\skyforge-upload.log).Length; Start-Sleep 20
"$a -> $((Get-Item C:\dcs-state\skyforge-upload.log).Length)"
```

A scheduled task whose action is `powershell.exe -Command "..."` with nested
quotes can be stored mis-escaped: powershell exits **0 without running
anything**, so `LastTaskResult=0`, `State=Ready` and `LastRunTime` all look
perfectly healthy while no work happens. This froze the board for a full day on
2026-08-21. The fix is `-EncodedCommand` with a base64 payload — one token, no
quotes for the scheduler to mangle — which is what `setup.ps1` now registers.
**Never trust `LastTaskResult` as evidence of work; trust the artefact.**

**`aws s3` fails on the server with `'str' object has no attribute 'get'` or
`max_bandwidth must be a positive integer`.** Something wrote a malformed key
into `C:\Windows\System32\config\systemprofile\.aws\config` (SSM runs as
SYSTEM, so that is the profile it uses). Note `aws configure set
default.s3.max_bandwidth 0` does **not** clear a throttle — 0 is rejected, and
removing the value leaves a dangling `s3 =` that breaks the parser differently.
Reset the file to just `[default]`.

**Friends can't connect.** Four things must agree on the port: the security
group, the Windows Firewall rule, `serverSettings.lua`, and `var.dcs_port`. DCS
needs **both TCP and UDP**. Check from outside with
`Test-NetConnection <ip> -Port 10308`.

**The instance shuts down mid-session.** The hook isn't reporting. Check
`C:\dcs-state\players.json` is being updated and that
`playercount.lua` is in the **running account's** `Saved Games\DCS.server\Scripts\Hooks\`.
The watchdog's network fallback should prevent this, but the hook is the fix.

**DCS doesn't start after reboot.** It may need an interactive session. Enable
autologon for Administrator and change the `DCS-Server` trigger from `-AtStartup`
to `-AtLogOn`.

**Config changes have no effect.** DCS reads `Saved Games` from *the account the
task runs as*. If the task runs as SYSTEM it uses
`C:\Windows\System32\config\systemprofile\Saved Games\` and silently ignores what
you edited as Administrator. `setup.ps1` runs it as Administrator for this reason.

**Discord says "interaction failed".** Discord hangs up at 3 seconds. Check the
Lambda logs in `/aws/lambda/dcs-server-bot`. A 401 means the public key in
`terraform.tfvars` doesn't match the Developer Portal.

**Terraform wants to replace the instance.** It shouldn't — `ami` and `user_data`
are in `ignore_changes` precisely because Amazon republishes the Windows AMI
monthly and a replacement would destroy the DCS install. If you see a replacement
planned, stop and work out why before applying.

---

## Sources

- [DCS World Dedicated Server — requirements and module policy](https://www.digitalcombatsimulator.com/en/downloads/world/server/)
- [AWS — Optimize CPUs for License-Included instances](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/optimize-cpu.html)
- [AWS — Optimize CPUs licence savings announcement (Oct 2025)](https://aws.amazon.com/about-aws/whats-new/2025/10/amazon-ec2-optimize-cpu-license-included-instances)
- [AWS — public IPv4 address charge](https://aws.amazon.com/blogs/aws/new-aws-public-ipv4-address-charge-public-ip-insights)
- [AWS Free Tier — $200 credits](https://aws.amazon.com/about-aws/whats-new/2025/07/aws-free-tier-credits-month-free-plan/)
- [AWS — India tax and GST](https://aws.amazon.com/tax-help/india/)
- [Discord — receiving and responding to interactions](https://discord.com/developers/docs/interactions/receiving-and-responding)
