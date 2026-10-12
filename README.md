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

Go to [discord.com/developers/applications](https://discord.com/developers/applications), create a new application, and copy the **Application ID**.

### 2. Build

```sh
git clone https://github.com/CassetteLab/cassette-discord-rpc.git
cd cassette-discord-rpc
swift build -c release
sudo install -d /usr/local/bin
sudo install -m 755 .build/release/CassetteDiscordRPC /usr/local/bin/
```

> `install -m 755` sets the executable bit explicitly. A plain `cp` can leave the binary non-executable (e.g. after copying through Finder or from a downloaded archive), and the shell then reports `command not found`.

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

### 4. Launch at login (optional)

```sh
cp Resources/fr.mathieu-dubart.cassette-discord-rpc.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/fr.mathieu-dubart.cassette-discord-rpc.plist
```

### 5. Run manually

```sh
CassetteDiscordRPC
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

**Nothing shows up in Discord**: make sure Discord (or Vesktop) is running and its IPC socket exists (`ls $TMPDIR | grep discord-ipc`), then check the logs of the launch agent:

```sh
cat /tmp/cassette-discord-rpc.log /tmp/cassette-discord-rpc.err
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
