# Install

[← README](../README.md)

You'll need macOS, [Homebrew](https://brew.sh) and a [Tvheadend](https://tvheadend.org) server.
Internet radio and TV streams work without one, and so does the demo.

## 1. What it runs on

```sh
brew install mpv fish jq ffmpeg
brew install --cask hammerspoon
```

- `jq` reads the config and the presets.
- `ffmpeg` brings `ffprobe`, which the guide uses to check a stream link before keeping it.

## 2. The installer

```sh
git clone https://github.com/indigobravo/mpv-tvh.git
cd mpv-tvh
./install.fish
```

This symlinks the fish functions, the mpv config and scripts, and the Hammerspoon module
(`mpv-tvh.lua`) into place, and loads the module from your `~/.hammerspoon/init.lua`: it adds
`require("mpv-tvh")` to yours, or makes one with just that. Anything already there is moved to `~/mpv-tvh-backup/` first. Links to files that have
gone from the repo are removed, so it's safe to run again after a `git pull`.

## 3. Switch it on and connect Tvheadend

```sh
preamp
```

Until it's set up, switching on opens the guide at SETUP and asks where your Tvheadend server
is. Type its address, or press FIND to look for it on your network, then CONNECT.

Or press **DEMO** (or Esc) to try it first: the TV shows test cards and the radio plays internet
stations (BBC World Service, SomaFM, Radio Paradise). It asks again the next time you switch on,
and **SETUP** on the preamp gets you back to it any time.

## 4. Pick your channels

After CONNECT, the first eight TV channels and the first eight radio stations go on the pad's
keys, in Tvheadend's channel order. The guide then shows you the TV's keys, then NEXT: RADIO
the radio's, so you can change any of them, then DONE. See
[Presets and SETUP](guide.md#presets-and-setup).

From then on the demo's gone. Without a config, mpv-tvh uses `examples/defaults.json` (the same
layout, no channels) and your presets. That's all the TV and radio need.

## 5. A config, if you want one

For internet streams in the config, your own window positions and the rest, copy the example:

```sh
mkdir -p ~/.config/mpv-tvh
cp examples/config.json ~/.config/mpv-tvh/config.json
```

See [Configuration](configuration.md).

## 6. Hammerspoon

Open Hammerspoon, give it Accessibility access when it asks, and turn on *Launch Hammerspoon at
login*. It handles the macro pad, puts the guide under the faceplates, and tells the preamp
the Mac's volume and output. See [The macro pad](macropad.md).

## 7. Logins

If your Tvheadend needs a login to set up recordings, or to read the tuner's signal, put it in
`~/.netrc` (and `chmod 600 ~/.netrc`):

```
machine 192.168.0.10 login me password secret
```

The guide and the preamp use it. Playing a stream or a recording is done by mpv, which doesn't
read `~/.netrc`, so Tvheadend has to allow streaming from your network without a login.

## Try it from a terminal

`preamp` switches the whole stack on. `tv bbc1` and `radio --default` each work on
their own too.
