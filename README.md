# ATEM Proxy

A native macOS app that shares one connection to a Blackmagic ATEM switcher with many control clients, for one or more ATEMs at the same time.

Most ATEM models accept only 5 or 8 connections. Control panels, tally, automation and streaming software use them up quickly. ATEM Proxy connects to each switcher once and accepts any number of clients itself.

## Download

**[Download the latest version](https://github.com/steijehillewaert/atem-proxy/releases/latest/download/ATEM-Proxy.zip)** for macOS 14 or newer, Apple Silicon and Intel. It's signed and notarized by Apple.

Unzip it, move **ATEM Proxy** to Applications and open it. When macOS asks for local network access, allow it. Updates install from inside the app (ATEM Proxy › Check for Updates…), and it checks once a day.

## Features

- Proxy several ATEMs at once.
- Status, model, firmware, connected clients and a log per ATEM.
- Menu bar icon; proxies keep running when the window is closed.
- Finds ATEMs on the network and shows each proxy in ATEM Software Control.
- Open at login, optional Dock icon.

## Using several ATEMs

ATEM clients always connect to port 9910, so each ATEM needs its own IP address on the Mac:

| Proxy    | ATEM           | Clients connect to |
|----------|----------------|--------------------|
| Studio A | 192.168.10.240 | the Mac's main IP |
| Studio B | 192.168.10.241 | 192.168.10.201 (extra IP) |
| Studio C | 192.168.10.242 | 192.168.10.202 (extra IP) |

In the proxy editor, **Add IP Address to This Mac…** adds an extra IP (asks for your password). It lasts until the Mac restarts. For a permanent one, open System Settings › Network, duplicate your Ethernet service and give the copy a manual IP.

## Limits

- Media pool uploads and downloads don't go through the proxy. Connect directly to the ATEM for those.
- For clients that must never drop, such as the main panel, connect directly to the ATEM.
- Tested against simulated ATEMs. Please report problems with your model and firmware in [Issues](https://github.com/steijehillewaert/atem-proxy/issues).

## Source and license

The protocol engine, `AtemProxyKit/`, is based on [LibAtem](https://github.com/LibAtem/LibAtem) and [AtemProxy](https://github.com/LibAtem/AtemProxy) by Julian Waller, and its source is published here under the [GNU LGPL v3](LICENSE). It ships inside the app as `ATEM Proxy.app/Contents/Frameworks/AtemProxyKit.framework`, so you can rebuild it (`cd AtemProxyKit && swift build`) and swap it in. `Tools/CommandTableGenerator/` builds the command table from LibAtem.

ATEM and Blackmagic Design are trademarks of Blackmagic Design Pty. Ltd. This project is not affiliated with Blackmagic Design.
