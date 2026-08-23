"""Discord slash-command bot for starting and stopping the DCS server.

Exposed on a Lambda Function URL with authorization_type = NONE, because
Discord signs its requests with Ed25519 and cannot present SigV4 credentials.
That makes verify_signature() the *only* thing standing between this URL and
anyone on the internet starting an EC2 instance on your bill. It runs before
anything else and fails closed.

Commands:  /dcs start | stop | status | restart | add-mission | perf

Fronted by an API Gateway HTTP API rather than a Lambda Function URL -- Function
URLs return 403 in this account regardless of policy, and are unavailable in
ap-south-2 entirely. Either way the endpoint is public, so verify_signature() is
the only thing standing between it and anyone on the internet starting an EC2
instance on the owner's bill. It runs before anything else and fails closed.
"""

import base64
import json
import logging
import os
import time
import urllib.error
import urllib.request
from urllib.parse import urlparse

import boto3
from botocore.exceptions import ClientError
from nacl.exceptions import BadSignatureError
from nacl.signing import VerifyKey

log = logging.getLogger()
log.setLevel(logging.INFO)

INSTANCE_ID = os.environ["INSTANCE_ID"]
DISCORD_PUBLIC_KEY = os.environ["DISCORD_PUBLIC_KEY"]
ALLOWED_GUILD_ID = os.environ.get("ALLOWED_GUILD_ID", "")
ALLOWED_ROLE_ID = os.environ.get("ALLOWED_ROLE_ID", "")
PLAYER_PARAM = os.environ.get("PLAYER_PARAM", "/dcs/playercount")
SERVER_HOST = os.environ.get("SERVER_HOST", "")
DCS_PORT = os.environ.get("DCS_PORT", "10308")

# The hook script republishes every ~15s. Anything older than this means the
# hook died, DCS died, or no mission is loaded -- in all three cases we should
# not claim to know the player count.
PLAYER_DATA_MAX_AGE_SEC = 180

QUEUED_PARAM = os.environ.get("QUEUED_PARAM", "/dcs/queued-mission")

# CloudFront origin for the web board's JSON. The in-guest publisher rewrites
# status.json every ~15 seconds, whereas the watchdog only refreshes the SSM
# parameter every 5 minutes -- so this is both fresher and richer (roster, sim
# FPS, uptime, zone balance). It is public data over plain HTTPS, which also
# avoids granting this Lambda cross-region S3 access it would not otherwise
# need.
BOARD_URL = os.environ.get("BOARD_URL", "").rstrip("/")

# Discord hangs up at 3 seconds and never retries. describe_instances, this
# fetch and an SSM read all have to fit inside that budget, so the timeout is
# deliberately tight: a slow board is not worth a failed interaction.
BOARD_TIMEOUT_SEC = 1.5

# Discord's own limit is 25 MB for most guilds; 50 leaves headroom for boosted
# servers without letting an upload threaten the 100 GB volume.
MAX_MISSION_BYTES = 50 * 1024 * 1024

ALLOWED_ATTACHMENT_HOSTS = {"cdn.discordapp.com", "media.discordapp.net"}

# This Lambda runs in a different region to the instance it controls: Lambda
# Function URLs are unavailable in ap-south-2, so the bot lives in ap-south-1
# while the server sits in Hyderabad. Without an explicit region boto3 would
# default to the Lambda's own and never find the instance.
TARGET_REGION = os.environ.get("TARGET_REGION") or os.environ["AWS_REGION"]

ec2 = boto3.client("ec2", region_name=TARGET_REGION)
ssm = boto3.client("ssm", region_name=TARGET_REGION)

# Discord interaction types
PING = 1
APPLICATION_COMMAND = 2

# Discord response types
PONG = 1
CHANNEL_MESSAGE = 4

EPHEMERAL = 64


# ---------------------------------------------------------------------------
# Request verification
# ---------------------------------------------------------------------------


def verify_signature(event) -> bytes:
    """Return the raw request body, or raise if the signature does not verify.

    Discord signs the concatenation of the timestamp header and the raw body.
    The body must be used byte-for-byte as received -- re-serialising the JSON
    changes whitespace and key order and the signature stops matching.
    """
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    signature = headers.get("x-signature-ed25519")
    timestamp = headers.get("x-signature-timestamp")

    if not signature or not timestamp:
        raise BadSignatureError("missing signature headers")

    raw_body = event.get("body") or ""
    body_bytes = (
        base64.b64decode(raw_body)
        if event.get("isBase64Encoded")
        else raw_body.encode("utf-8")
    )

    VerifyKey(bytes.fromhex(DISCORD_PUBLIC_KEY)).verify(
        timestamp.encode("utf-8") + body_bytes,
        bytes.fromhex(signature),
    )
    return body_bytes


def caller_is_authorised(interaction) -> bool:
    """Guild and (optionally) role gate.

    Without this, anyone who learns the Function URL and your application's
    public key relationship still cannot forge a signature -- but anyone who
    gets *added to the Discord* could spend your money. The role check is the
    difference between "my friends" and "anyone who wanders in".
    """
    if ALLOWED_GUILD_ID and interaction.get("guild_id") != ALLOWED_GUILD_ID:
        log.warning("rejected interaction from guild %s", interaction.get("guild_id"))
        return False

    if ALLOWED_ROLE_ID:
        roles = (interaction.get("member") or {}).get("roles") or []
        if ALLOWED_ROLE_ID not in roles:
            log.warning("rejected caller lacking role %s", ALLOWED_ROLE_ID)
            return False

    return True


# ---------------------------------------------------------------------------
# Server state
# ---------------------------------------------------------------------------


def instance_state() -> str:
    resp = ec2.describe_instances(InstanceIds=[INSTANCE_ID])
    return resp["Reservations"][0]["Instances"][0]["State"]["Name"]


def player_info():
    """Current player count, or None when we cannot vouch for the number."""
    try:
        value = ssm.get_parameter(Name=PLAYER_PARAM)["Parameter"]["Value"]
        data = json.loads(value)
    except (ClientError, json.JSONDecodeError, KeyError):
        return None

    if time.time() - float(data.get("ts", 0)) > PLAYER_DATA_MAX_AGE_SEC:
        return None

    return data


def board_status():
    """Live status from the web board's CloudFront origin, or None."""
    if not BOARD_URL:
        return None

    try:
        request = urllib.request.Request(
            f"{BOARD_URL}/status.json", headers={"Cache-Control": "no-cache"}
        )
        with urllib.request.urlopen(request, timeout=BOARD_TIMEOUT_SEC) as response:
            data = json.loads(response.read().decode("utf-8"))
    except (OSError, ValueError):
        # URLError and socket.timeout are both OSError; a truncated body is a
        # ValueError. Every one of them means the same thing here: fall back.
        return None

    if time.time() - float(data.get("ts", 0)) > PLAYER_DATA_MAX_AGE_SEC:
        return None

    return data


def live_state():
    """Best available view of the running server, freshest source first."""
    return board_status() or player_info()


def format_uptime(seconds) -> str:
    seconds = int(seconds or 0)
    hours, minutes = seconds // 3600, (seconds % 3600) // 60
    if hours >= 24:
        return f"{hours // 24}d {hours % 24}h"
    return f"{hours}h {minutes}m" if hours else f"{minutes}m"


def format_roster(names) -> str:
    """Connected pilots grouped by coalition. DCS sides: 1 = red, 2 = blue."""
    buckets = {2: [], 1: [], 0: []}

    for entry in names or []:
        if isinstance(entry, dict):
            side = entry.get("s", 0)
            side = int(side) if isinstance(side, (int, float)) else 0
            buckets.setdefault(side, []).append(str(entry.get("n", "?")))
        else:
            buckets[0].append(str(entry))

    rows = []
    for side, icon in ((2, "🔵"), (1, "🔴"), (0, "⚪")):
        who = buckets.get(side) or []
        if who:
            rows.append(f"{icon} " + " · ".join(who))

    return "\n".join(rows)


def address() -> str:
    return f"{SERVER_HOST}:{DCS_PORT}" if SERVER_HOST else "(no address configured)"


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------


def cmd_start(interaction) -> str:
    state = instance_state()

    if state == "running":
        return f"Server is already up. Connect to **{address()}**"

    if state in ("pending", "stopping", "shutting-down"):
        return f"Server is `{state}` right now -- give it a moment and try `/dcs status`."

    if state != "stopped":
        return f"Cannot start from state `{state}`. Poke the admin."

    ec2.start_instances(InstanceIds=[INSTANCE_ID])
    return (
        f"Starting the server. DCS takes about **3-5 minutes** to become joinable.\n"
        f"Address will be **{address()}** -- use `/dcs status` to check."
    )


def cmd_stop(interaction) -> str:
    state = instance_state()

    if state in ("stopped", "stopping"):
        return f"Server is already `{state}`."

    players = player_info()
    if players and players.get("players", 0) > 0:
        return (
            f"**{players['players']} player(s) still connected.** "
            f"Not stopping. Try again once they disconnect, or let the idle "
            f"watchdog handle it automatically."
        )

    ec2.stop_instances(InstanceIds=[INSTANCE_ID])
    return "Stopping the server. Billing stops once it reaches `stopped`."


def cmd_add_mission(interaction) -> str:
    """Validate a Discord-uploaded .miz and queue it for the next restart.

    The file never passes through this Lambda -- we hand the CDN URL to the
    instance and it downloads directly, which keeps a 50 MB upload out of a
    256 MB function and off the Lambda's own egress.

    Only cheap checks happen here (extension, size, URL host) so the uploader
    gets an instant answer to obvious mistakes. The expensive checks -- is it a
    real .miz, which terrain does it need, is the Lua sandbox still intact --
    run on the instance and report back through /dcs status, because
    SendCommand is fire-and-forget and Discord hangs up after 3 seconds.
    """
    attachment = extract_attachment(interaction.get("data") or {})
    if attachment is None:
        return "No file attached. Use `/dcs add-mission file:<your .miz>`."

    filename = attachment.get("filename") or ""
    size = attachment.get("size") or 0
    url = attachment.get("url") or ""

    if not filename.lower().endswith(".miz"):
        return f"`{filename}` is not a `.miz` file."

    if size > MAX_MISSION_BYTES:
        return (
            f"`{filename}` is {size / 1048576:.1f} MB; the limit is "
            f"{MAX_MISSION_BYTES // 1048576} MB."
        )

    # The instance fetches this URL, so a URL from anywhere other than Discord
    # would turn an upload into a server-side request forgery primitive. Discord
    # populates `resolved`, so this should always hold -- which is exactly why
    # it is cheap to assert rather than assume.
    host = urlparse(url).hostname or ""
    if host not in ALLOWED_ATTACHMENT_HOSTS:
        log.warning("rejected attachment from unexpected host %s", host)
        return "That attachment did not come from Discord's CDN. Refusing."

    state = instance_state()
    if state != "running":
        return (
            f"Server is **{state}** â€” it must be running to accept a mission.\n"
            f"Use `/dcs start`, wait for it to come up, then try again."
        )

    uploader = ((interaction.get("member") or {}).get("user") or {}).get(
        "username", "someone"
    )

    try:
        ssm.send_command(
            InstanceIds=[INSTANCE_ID],
            DocumentName="AWS-RunPowerShellScript",
            Comment="DCS mission upload via Discord",
            Parameters={
                "commands": [
                    "& C:\\dcs-state\\add-mission.ps1 "
                    f"-Url '{url}' -FileName '{filename}' -UploadedBy '{uploader}'"
                ]
            },
        )
    except ClientError as exc:
        log.exception("mission upload failed")
        return f"Upload failed: `{exc.response['Error']['Code']}`"

    return (
        f"Got **{filename}** ({size / 1048576:.1f} MB). Validatingâ€¦\n"
        f"Run `/dcs status` in ~15 seconds to see whether it was accepted."
    )


def cmd_perf(interaction) -> str:
    """Render a performance chart and post it to the Discord webhook.

    Deliberately posts to a webhook rather than replying inline: the chart is a
    PNG rendered on the instance, and getting an image back through an
    interaction response would mean shipping it via the Lambda. The webhook
    lets the server post directly.
    """
    state = instance_state()
    if state != "running":
        return f"Server is **{state}** — no live data to chart. Use `/dcs start`."

    hours = 6
    for option in (interaction.get("data") or {}).get("options") or []:
        for sub in option.get("options") or []:
            if sub.get("name") == "hours":
                hours = max(1, min(72, int(sub.get("value", 6))))

    try:
        ssm.send_command(
            InstanceIds=[INSTANCE_ID],
            DocumentName="AWS-RunPowerShellScript",
            Comment="DCS perf report via Discord",
            Parameters={
                "commands": [
                    rf"& C:\dcs-state\perf-report.ps1 -Hours {hours}"
                ]
            },
        )
    except ClientError as exc:
        log.exception("perf report failed")
        return f"Could not generate the report: `{exc.response['Error']['Code']}`"

    return (
        f"Rendering the last **{hours}h** of performance data. "
        f"The chart will appear in the stats channel in a few seconds."
    )


def cmd_restart(interaction) -> str:
    """Restart the DCS process, not the instance.

    Rebooting the box takes ~3 minutes and is almost never what you want. The
    common need -- a wedged mission, a config change, a stuck slot -- is fixed
    by bouncing DCS_server.exe, which is back in about 90 seconds.

    This deliberately does NOT refuse when players are connected: a restart is
    most often wanted precisely when something is broken for the people on the
    server. It reports who it is about to drop instead. Gate it with
    discord_role_id if that is too much power for the whole guild.
    """
    state = instance_state()

    if state != "running":
        return f"Server is **{state}** â€” nothing to restart. Use `/dcs start`."

    players = player_info()
    dropped = players.get("players", 0) if players else 0

    try:
        ssm.send_command(
            InstanceIds=[INSTANCE_ID],
            DocumentName="AWS-RunPowerShellScript",
            Comment="DCS restart via Discord",
            Parameters={
                "commands": [
                    "Stop-ScheduledTask -TaskName DCS-Server -ErrorAction SilentlyContinue",
                    "Stop-Process -Name DCS_server -Force -ErrorAction SilentlyContinue",
                    "Start-Sleep -Seconds 5",
                    "Start-ScheduledTask -TaskName DCS-Server",
                ]
            },
        )
    except ClientError as exc:
        log.exception("restart failed")
        return f"Restart failed: `{exc.response['Error']['Code']}`"

    warning = ""
    if dropped:
        who = "1 player" if dropped == 1 else f"{dropped} players"
        warning = f"\n**{who} dropped** â€” they can rejoin once it is back."

    return f"Restarting DCS. Joinable again in about **90 seconds**.{warning}"


def cmd_status(interaction) -> str:
    state = instance_state()

    if state != "running":
        return f"Server is **{state}**. Use `/dcs start` to bring it up."

    live = live_state()

    if live is None:
        return (
            f"Instance is **running**, but DCS is not reporting yet.\n"
            f"It is probably still loading -- give it a couple of minutes.\n"
            f"Address: **{address()}**"
        )

    count = live.get("players", 0)
    mission = live.get("mission") or "unknown"

    if count == 0:
        headline = "**Nobody flying**"
        dot = "\u26AA"
    else:
        who = "1 pilot" if count == 1 else f"{count} pilots"
        headline = f"**{who} flying**"
        dot = "\U0001F7E2"

    lines = [f"{dot} {headline} \u2014 *{mission}*"]

    connect = f"Connect **{address()}**"
    if live.get("srs"):
        connect += f"  \u00b7  SRS `{live['srs']}`"
    lines.append(connect)

    roster = format_roster(live.get("names"))
    if roster:
        lines.append("")
        lines.append(roster)

    # A compact facts line rather than separate rows: Discord renders short
    # messages far better in a busy channel, and this gets read at a glance
    # mid-session.
    facts = []

    zones = live.get("zones") or {}
    blue, red = int(zones.get("blue", 0) or 0), int(zones.get("red", 0) or 0)
    if blue or red:
        held = blue + red
        pct = round(blue * 100 / held) if held else 0
        facts.append(f"\U0001F535 {blue} \u00b7 \U0001F534 {red} ({pct}% blue)")

    if live.get("fps"):
        facts.append(f"{live['fps']} fps")

    if live.get("uptime"):
        facts.append(f"up {format_uptime(live['uptime'])}")

    if facts:
        lines.append("")
        lines.append("  \u00b7  ".join(facts))

    # Surface the outcome of the last upload here, because add-mission cannot
    # answer synchronously (SendCommand is fire-and-forget).
    queued = queued_mission()
    if queued:
        if queued.get("ok"):
            name = queued.get("mission", "a mission")
            theatre = queued.get("theatre", "")
            by = queued.get("by", "someone")
            where = f" ({theatre})" if theatre else ""
            lines.append(
                f"\n\U0001F4E5 **Queued:** `{name}`{where}, uploaded by {by}.\n"
                f"Loads on the next `/dcs restart`."
            )
        else:
            lines.append(
                f"\n\u26A0\uFE0F **Last upload rejected:** {queued.get('message', '')}"
            )

    return "\n".join(lines)


def cmd_update(interaction) -> str:
    """Run the DCS updater on demand.

    Patch day is the one failure that locks everybody out at once: DCS refuses
    a client whose build differs from the server's, so the morning after an ED
    release nobody can join until this runs. A weekly maintenance schedule
    normally handles it; this command exists for the mid-week hotfix.

    Refuses while anyone is connected. Updating stops DCS for several minutes
    and there is no version of that which is polite to do to someone on final.
    """
    state = instance_state()
    if state != "running":
        return f"Server is **{state}** \u2014 start it first with `/dcs start`."

    live = live_state()
    if live and live.get("players", 0) > 0:
        count = live["players"]
        who = "1 pilot is" if count == 1 else f"{count} pilots are"
        return (
            f"**{who} still connected.** Updating stops DCS for several "
            f"minutes, so I am not doing it now. Try again once the field is "
            f"clear, or let the weekly maintenance window handle it."
        )

    try:
        ssm.send_command(
            InstanceIds=[INSTANCE_ID],
            DocumentName="AWS-RunPowerShellScript",
            Comment="DCS update via Discord",
            Parameters={
                "commands": [r"& C:\dcs-state\update-dcs.ps1 -Reason discord"]
            },
        )
    except ClientError as exc:
        log.exception("update failed")
        return f"Could not start the update: `{exc.response['Error']['Code']}`"

    return (
        "Starting the DCS updater. It stops the server, patches, and brings it "
        "back \u2014 usually **5\u201315 minutes**, longer for a big release.\n"
        "Progress is posted to the stats channel, and `/dcs status` will show "
        "it back up."
    )


COMMANDS = {
    "start": cmd_start,
    "stop": cmd_stop,
    "status": cmd_status,
    "restart": cmd_restart,
    "add-mission": cmd_add_mission,
    "perf": cmd_perf,
    "update": cmd_update,
}


def extract_attachment(data):
    """Pull the resolved attachment object out of an interaction, or None.

    Discord sends the attachment's id as the option value and the actual object
    (url, filename, size) separately under data.resolved.attachments.
    """
    resolved = (data.get("resolved") or {}).get("attachments") or {}

    def walk(options):
        for option in options or []:
            if option.get("type") == 11:  # ATTACHMENT
                return resolved.get(option.get("value"))
            found = walk(option.get("options"))
            if found:
                return found
        return None

    return walk(data.get("options"))


def queued_mission():
    """Result of the most recent upload, or None if nothing has been uploaded."""
    try:
        value = ssm.get_parameter(Name=QUEUED_PARAM)["Parameter"]["Value"]
        return json.loads(value)
    except (ClientError, json.JSONDecodeError, KeyError):
        return None


def resolve_subcommand(data) -> str:
    """Accept both `/dcs start` (subcommand) and a flat `/dcs-start` command."""
    for option in data.get("options") or []:
        if option.get("type") == 1:  # SUB_COMMAND
            return option.get("name", "")

    name = data.get("name", "")
    return name.split("-", 1)[1] if name.startswith("dcs-") else name


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def reply(content: str, ephemeral: bool = False):
    payload = {"type": CHANNEL_MESSAGE, "data": {"content": content}}
    if ephemeral:
        payload["data"]["flags"] = EPHEMERAL

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(payload),
    }


def lambda_handler(event, context):
    # Fail closed, before anything else, and before any AWS API call.
    try:
        body_bytes = verify_signature(event)
    except (BadSignatureError, ValueError) as exc:
        log.warning("signature rejected: %s", exc)
        return {"statusCode": 401, "body": "invalid request signature"}

    interaction = json.loads(body_bytes)

    if interaction.get("type") == PING:
        return {
            "statusCode": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"type": PONG}),
        }

    if interaction.get("type") != APPLICATION_COMMAND:
        return reply("Unsupported interaction type.", ephemeral=True)

    if not caller_is_authorised(interaction):
        return reply("You are not allowed to control this server.", ephemeral=True)

    subcommand = resolve_subcommand(interaction.get("data") or {})
    handler = COMMANDS.get(subcommand)

    if handler is None:
        return reply(f"Unknown command `{subcommand}`.", ephemeral=True)

    try:
        return reply(handler(interaction))
    except ClientError as exc:
        log.exception("AWS call failed")
        return reply(f"AWS error: `{exc.response['Error']['Code']}`", ephemeral=True)
