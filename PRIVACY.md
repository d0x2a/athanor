# Privacy Policy

Athanor (on the Mac App Store as Athanor: Script Runner) is made by Dox2A Labs LLC.

Effective October 13, 2026.

## The short version

Athanor collects no data. It has no accounts, no analytics, no ads and no
tracking, and it sends nothing about you or your Mac to Dox2A Labs or anyone
else.

## What stays on your Mac

Athanor keeps these files on your Mac, and only there:

- **Your script list** (`scripts.toml`): the scripts you add, with their
  commands, folders and settings.
- **Logs**: what each script prints, with timestamps, so you can read it in
  Athanor.
- **Run state**: which scripts are running and how each one last ended.
- **Settings**: your preferences, such as the keyboard shortcut and
  notifications.

The App Store version keeps all of them in its own folder,
`~/Library/Containers/com.d0x2a.athanor`. Deleting the app removes them. The
version from GitHub or Homebrew keeps them in `~/.config/athanor`,
`~/Library/Logs/Athanor` and `~/Library/Application Support/Athanor`.

Athanor never uploads these files. You can read, edit or delete them yourself.

## Network

Athanor itself makes only the connections you set up:

- A script set to be ready **when a port opens** makes Athanor connect to that
  port on your own Mac.
- A script set to be ready **when a URL answers** makes Athanor request that
  URL until it responds.

It doesn't check for updates or contact any server of its own.

The scripts you run are your own programs. Athanor starts them, but what they
do, including what they send over the network, is up to them and whoever made
them.

## Notifications

Notifications about scripts that crash or finish are made on your Mac and
shown by macOS. They aren't sent through any server.

## Apple

If you install Athanor from the Mac App Store, Apple handles the download and
any purchase under [Apple's privacy policy](https://www.apple.com/legal/privacy/).
If you've chosen to share analytics with app developers in macOS settings,
Apple may give Dox2A Labs anonymous crash reports and usage statistics.
Dox2A Labs uses them only to fix bugs.

## Children

Athanor is a developer tool, not directed at children, and it collects no data
from anyone.

## Changes

Any change to this policy will be made in this file, with a new effective
date. Its full history is in this repository.

## Contact

Questions about this policy: open an issue at
<https://github.com/d0x2a/athanor/issues>.
