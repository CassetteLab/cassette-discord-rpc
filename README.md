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
cp .build/release/CassetteDiscordRPC /usr/local/bin/
```

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
