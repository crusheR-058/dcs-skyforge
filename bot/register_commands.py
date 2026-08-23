"""Register the /dcs slash command with Discord.

Run once, and again whenever the command shape changes. Uses only the standard
library so it needs no virtualenv.

    set DISCORD_APP_ID=...
    set DISCORD_BOT_TOKEN=...
    set DISCORD_GUILD_ID=...
    python register_commands.py

Registers as a *guild* command, which appears instantly. Global commands can
take up to an hour to propagate, which makes debugging needlessly slow.
"""

import json
import os
import sys
import urllib.error
import urllib.request

API = "https://discord.com/api/v10"

SUB_COMMAND = 1
ATTACHMENT = 11
INTEGER = 4

COMMANDS = [
    {
        "name": "dcs",
        "description": "Control the DCS World server",
        "options": [
            {
                "name": "start",
                "description": "Boot the server (takes ~3-5 minutes to become joinable)",
                "type": SUB_COMMAND,
            },
            {
                "name": "stop",
                "description": "Shut the server down and stop billing",
                "type": SUB_COMMAND,
            },
            {
                "name": "status",
                "description": "Is it up, who is on it, and what is the address",
                "type": SUB_COMMAND,
            },
            {
                "name": "restart",
                "description": "Bounce the DCS process (~90s) - fixes a stuck mission",
                "type": SUB_COMMAND,
            },
            {
                "name": "perf",
                "description": "Post a CPU/FPS chart to the stats channel",
                "type": SUB_COMMAND,
                "options": [
                    {
                        "name": "hours",
                        "description": "How far back to plot (default 6, max 72)",
                        "type": INTEGER,
                        "required": False,
                    }
                ],
            },
            {
                "name": "update",
                "description": "Patch DCS to the latest build (only when nobody is flying)",
                "type": SUB_COMMAND,
            },
            {
                "name": "add-mission",
                "description": "Upload a .miz to load on the next restart",
                "type": SUB_COMMAND,
                "options": [
                    {
                        "name": "file",
                        "description": "Your .miz mission file",
                        "type": ATTACHMENT,
                        "required": True,
                    }
                ],
            },
        ],
    }
]


def main() -> int:
    app_id = os.environ.get("DISCORD_APP_ID")
    token = os.environ.get("DISCORD_BOT_TOKEN")
    guild_id = os.environ.get("DISCORD_GUILD_ID")

    missing = [
        name
        for name, value in (
            ("DISCORD_APP_ID", app_id),
            ("DISCORD_BOT_TOKEN", token),
            ("DISCORD_GUILD_ID", guild_id),
        )
        if not value
    ]
    if missing:
        print(f"Missing environment variables: {', '.join(missing)}", file=sys.stderr)
        return 1

    url = f"{API}/applications/{app_id}/guilds/{guild_id}/commands"

    request = urllib.request.Request(
        url,
        data=json.dumps(COMMANDS).encode("utf-8"),
        method="PUT",  # bulk overwrite: idempotent, and prunes stale commands
        headers={
            "Authorization": f"Bot {token}",
            "Content-Type": "application/json",
            "User-Agent": "dcs-server-bot (https://github.com, 1.0)",
        },
    )

    try:
        with urllib.request.urlopen(request) as response:
            registered = json.load(response)
    except urllib.error.HTTPError as exc:
        print(f"Discord returned {exc.code}: {exc.read().decode()}", file=sys.stderr)
        return 1

    for command in registered:
        subs = ", ".join(o["name"] for o in command.get("options", []))
        print(f"registered /{command['name']} ({subs})")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
