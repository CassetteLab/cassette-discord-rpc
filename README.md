# cassette-discord-rpc

A standalone macOS daemon that reads what [Cassette](https://github.com/CassetteLab/cassette) is playing and displays it in Discord via Rich Presence.

## Requirements

- macOS 13+
- [Cassette](https://github.com/CassetteLab/cassette)
- Discord or Vesktop running in the background

## How it works

Cassette sends HTTP requests to `localhost:47832` on every track change. The daemon receives them, fetches the album artwork from MusicBrainz / Cover Art Archive, and updates your Discord Rich Presence through the local IPC protocol (Unix socket).

## Installation

### 1. Create a Discord application

Go to [discord.com/developers/applications](https://discord.com/developers/applications), create a new application, and copy the **Application ID**. Its name doesn't matter: the presence shows the track being played.

### 2. Install the binary

**Option A: prebuilt binary**

```sh
curl -fL -o /tmp/CassetteDiscordRPC https://github.com/CassetteLab/cassette-discord-rpc/releases/latest/download/CassetteDiscordRPC
sudo install -d /usr/local/bin
sudo install -m 755 /tmp/CassetteDiscordRPC /usr/local/bin/
```

> Download it with `curl` rather than your browser: a browser download is quarantined by macOS, and the binary isn't notarized.

**Option B: build from source**

```sh
git clone https://github.com/CassetteLab/cassette-discord-rpc.git
cd cassette-discord-rpc
swift build -c release
sudo install -d /usr/local/bin
sudo install -m 755 .build/release/CassetteDiscordRPC /usr/local/bin/
```

> `install -m 755` sets the executable bit explicitly. A plain `cp` can leave the binary non-executable, and the shell then reports `command not found`.

### 3. Create the config file

```sh
mkdir -p ~/.config/cassette-discord-rpc
nano ~/.config/cassette-discord-rpc/config.json
```

```json
{
  "clientId": "YOUR_APPLICATION_ID"
}
```

If port `47832` is already taken on your machine, add the optional `port` field:

```json
{
  "clientId": "YOUR_APPLICATION_ID",
  "port": 47832
}
```

### 4. Start the daemon

The recommended way is a launch agent: it starts the daemon at login and restarts it if it ever crashes.

```sh
mkdir -p ~/Library/LaunchAgents
curl -fL -o ~/Library/LaunchAgents/fr.mathieu-dubart.cassette-discord-rpc.plist \
  https://raw.githubusercontent.com/CassetteLab/cassette-discord-rpc/main/Resources/fr.mathieu-dubart.cassette-discord-rpc.plist
launchctl load ~/Library/LaunchAgents/fr.mathieu-dubart.cassette-discord-rpc.plist
```

To try it without the launch agent, run `CassetteDiscordRPC` in a terminal instead. Don't do both: the second instance exits with `Address already in use`.

### 5. Check that it works

```sh
curl -s localhost:47832/health
```

`"discord":"ready"` means the daemon is talking to Discord. Play something in Cassette and `presenceActive` turns `true`.

Cassette reports a track when it starts, pauses or resumes. If a track was already playing when the daemon started, pause and resume it, or skip to the next one.

## Updating

Install the new binary (step 2), then restart the launch agent. It keeps running the old binary until it is restarted:

```sh
launchctl kickstart -k gui/$(id -u)/fr.mathieu-dubart.cassette-discord-rpc
```

## Troubleshooting

**`command not found: CassetteDiscordRPC`**: check that the binary exists and is executable:

```sh
ls -la /usr/local/bin/CassetteDiscordRPC   # must show -rwxr-xr-x
sudo chmod 755 /usr/local/bin/CassetteDiscordRPC
```

If Gatekeeper blocks it, remove the quarantine attribute:

```sh
sudo xattr -d com.apple.quarantine /usr/local/bin/CassetteDiscordRPC
```

**`address already in use`**: the launch agent is probably already running the daemon. Don't start it manually on top of it:

```sh
launchctl list | grep cassette
lsof -i :47832
```

**Nothing shows up in Discord**: ask the daemon what it sees:

```sh
curl -s localhost:47832/health
```

- `"discord":"ready"`: connected to Discord. If `lastError` is set, Discord rejected the presence and says why.
- `"discord":"searching"`: no Discord IPC socket. Start Discord or Vesktop; the daemon reconnects on its own.
- `curl` fails: the daemon isn't running.

Also check that Discord shares your activity: **User Settings → Activity Privacy → Share your detected activities with others**.

The daemon logs to the unified log (not to stdout), so follow it live with:

```sh
log stream --level info --predicate 'subsystem == "fr.mathieu-dubart.cassette-discord-rpc"'
```

## Uninstall

```sh
launchctl unload ~/Library/LaunchAgents/fr.mathieu-dubart.cassette-discord-rpc.plist
rm ~/Library/LaunchAgents/fr.mathieu-dubart.cassette-discord-rpc.plist
sudo rm /usr/local/bin/CassetteDiscordRPC
rm -rf ~/.config/cassette-discord-rpc
```

## Documentation

Design decisions and notes on how this daemon fits the wider ecosystem live in the
**[CassetteLab knowledge vault](https://github.com/CassetteLab/obsidian)** — an Obsidian
vault versioned with Git.

Anything that explains **why** a choice was made lives there rather than in this repo.

> The vault is private to the organisation — open an issue if you need access.

---

## License

MIT
