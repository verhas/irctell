# Irctell

**An IRC client for macOS, built for conversations that keep going.**

Irctell brings channels and private chats together in a native Mac app, with a searchable local history, useful notifications, scripting, and optional voice. Your network settings and logs stay on your Mac.

[Visit the Irctell website](https://verhas.github.io/irctell/) · [Download the latest release](https://github.com/verhas/irctell/releases/latest) · [Report an issue](https://github.com/verhas/irctell/issues)

![Irctell app icon](Irctell/Assets.xcassets/AppIcon.appiconset/icon_256x256.png)

## Made for everyday IRC

- **Multiple networks, one window.** Keep networks in tabs and move between channels and private conversations without losing your place.
- **A history you can search.** Irctell keeps conversations locally, with nick history, memos, mentions, and private messages easy to find.
- **Replies when you need them.** Optional Apple Intelligence reply suggestions run on your Mac. Review and edit a suggestion before sending it.
- **Scripts that fit your routine.** Run a script when a message, timer, or other event matches your rules. Scripts can use a plain text or JSON Lines protocol; permissions and limits are configurable.
- **Listen in.** Have messages read aloud with system voices or optional Kokoro natural voices, with per-nick voice choices and spoken abbreviations.
- **Choose how to connect.** Use TLS, SASL, Tor, SOCKS, or an SSH tunnel where your network setup calls for it.

## Requirements

- macOS 26 or later
- Apple Intelligence features require a supported Mac and enabled Apple Intelligence. They are optional; IRC messaging does not depend on them.
- Natural Kokoro voices are an optional download. System voices work without them.

## Get Irctell

Download the latest DMG from [GitHub Releases](https://github.com/verhas/irctell/releases/latest), open it, and move Irctell to Applications. The release page lists the available version and build notes.

## Build from source

You need Xcode and its command line tools. From a terminal:

```sh
git clone https://github.com/verhas/irctell.git
cd irctell
./build.sh
```

The first build downloads a pinned sherpa-onnx archive and checks its SHA-256 before using it. To launch the app after building:

```sh
./build.sh run
```

See `./build.sh --help` for build, test, packaging, and release commands. Developer ID signing and notarization require your own Apple credentials and signing setup.

## Documentation

- [Scripting guide](SCRIPTING.md)
- [Agent and MCP design notes](MCP.md)
- [Release notes](https://github.com/verhas/irctell/releases)

## Privacy

Irctell stores its network configuration, credentials, and conversation history locally. IRC traffic goes to the networks you configure. Optional picture downloads contact the image host, and optional model/voice downloads contact their distribution hosts. Local reply suggestions use Apple Intelligence on your Mac.

## License

No license file is present yet. Until one is added, all rights are reserved; contact the maintainer for permission to reuse or redistribute the code.
