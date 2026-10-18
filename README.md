# mpv-tvh

TV, radio and music on macOS: mpv + Tvheadend, driven by a macro pad and Hammerspoon.

- **TV and radio** come from a Tvheadend server and are played in mpv.
- **Internet radio streams** can sit in the same station lists as Tvheadend channels.
- **A 12-key, 2-knob macro pad** sends fixed keys. Hammerspoon and mpv decide what each key does,
  depending on which app is in front.

## Repo layout

| Path | What it is | Lives at |
|---|---|---|
| `fish/__tvh.fish` | Shared player: reads the config, builds the playlist, launches mpv | `~/.config/fish/functions/` |
| `fish/tv.fish`, `fish/radio.fish` | Wrappers: `tv <channel>`, `radio <station>` | `~/.config/fish/functions/` |
| `fish/__tv_now.fish` | Now/next listing for `tv --now` / `radio --now` | `~/.config/fish/functions/` |
| `mpv/mpv.conf` | Decode, cache, deinterlace and screenshot settings | `~/.config/mpv/mpv.conf` |
| `mpv/input.conf` | mpv key bindings for the pad | `~/.config/mpv/input.conf` |
| `mpv/scripts/tv-epg.lua` | TV now/next overlay (mouse move or `g`) | `~/.config/mpv/scripts/` |
| `mpv/scripts/radio-epg.lua` | Permanent radio display: station, now/next or current track | `~/.config/mpv/scripts/` |
| `hammerspoon/init.lua` | Launchers, volume knob, default key profile | `~/.hammerspoon/init.lua` |
| `macropad/function_pad.yml` | Key map flashed to the pad | (flashed, not linked) |
| `examples/config.yml` | Example config: Tvheadend host, channels, mpv options | copy to `~/.config/mpv-tvh/config.yml` |

## The pad

```
 ┌──────┬──────┬──────┬──────┐   ◯ knob 1: scrub / channels
 │  1   │  2   │  3   │  4   │
 │ F13  │ F14  │ F15  │ F16  │   ◯ knob 2: volume
 ├──────┼──────┼──────┼──────┤
 │  5   │  6   │  7   │  8   │
 │ F17  │ F18  │ F19  │ F20  │
 ├──────┼──────┼──────┼──────┤
 │  TV  │Radio │spare │ Alt  │
 └──────┴──────┴──────┴──────┘
```

### Keys 1–8

| Key | Sends | In mpv (TV/radio) | Alt + key in mpv | Anywhere else |
|---|---|---|---|---|
| 1 | F13 | Channel 1 | – | Lock screen |
| 2 | F14 | Channel 2 | *(not available)* | Previous tab |
| 3 | F15 | Channel 3 | *(not available)* | Next tab |
| 4 | F16 | Channel 4 | Mute this player | Mic mute |
| 5 | F17 | Channel 5 | Screenshot | Screenshot area to clipboard |
| 6 | F18 | Channel 6 | A-B loop | Reopen closed tab |
| 7 | F19 | Channel 7 | Quit | Close tab/window |
| 8 | F20 | Channel 8 | Fullscreen | Move window to other display (Alt: maximise/restore) |

"Channel N" means playlist position N, so the same key picks the Nth TV channel or the Nth radio station.
`Shift+F13` (keyboard only) plays position 9 (Red Button on TV).

Alt + F14/F15 is unusable: macOS treats F14/F15 as the brightness keys, and Option + brightness opens
Display settings. Untick *Decrease/Increase display brightness* in System Settings → Keyboard →
Keyboard Shortcuts → Display so that plain F14/F15 get through.

### Bottom row

| Key | Sends | Action |
|---|---|---|
| TV | Ctrl+Opt+Cmd+F13 | Not running: start TV. In background: bring to front. In front: toggle its mute. |
| Radio | Ctrl+Opt+Cmd+F16 | Same, for the radio player. |
| spare | Ctrl+Opt+Cmd+F17 | Unbound (reserved for a music launcher). |
| Alt | Option | Held modifier for the keys and knob 1. |

TV and radio are separate mpv instances (sockets `/tmp/mpv-tv`, `/tmp/mpv-radio`), so both can run at
once and be muted independently.

### Knobs

| Knob | Turn | Press | With Alt held |
|---|---|---|---|
| 1 | Up/Down → seek −5 s / +5 s | Enter → pause | Previous/next channel; press opens the channel list (then turn to scroll, press to play) |
| 2 | Ctrl+Opt+Cmd+F18/F19 → Hammerspoon, 2% volume steps | System mute | – |

Knob 1 sends real Up/Down/Enter keys, so outside mpv it acts as arrow keys and Return.

## Install

Requirements (Homebrew):

```sh
brew install fish mpv jq yq
brew install --cask hammerspoon
```

`yq` must be [mikefarah/yq](https://github.com/mikefarah/yq) (Homebrew's `yq`), not the Python wrapper of the same name.

### 1. Config

Personal settings live outside the repo, in `~/.config/mpv-tvh/config.yml`
(override with `MPV_TVH_CONFIG`):

```sh
mkdir -p ~/.config/mpv-tvh
cp examples/config.yml ~/.config/mpv-tvh/config.yml
```

### 2. Link the repo into place

```sh
fish install.fish
```

This symlinks the repo's fish functions, mpv config and scripts, and Hammerspoon config into place.
Any real file it would replace is moved to `~/mpv-tvh-backup/<timestamp>/` first. Other mpv scripts
and fish functions are left alone, and it's safe to re-run (for example after adding a new script).

Hammerspoon needs Accessibility permission. It reloads itself when `init.lua` changes (the watcher
follows the symlink to the repo).

### Flashing the pad

Uses [ch57x-keyboard-tool](https://github.com/kriomant/ch57x-keyboard-tool) (pad ID `1189:8840`, model `ch57x-1`):

```sh
cargo install ch57x-keyboard-tool
ch57x-keyboard-tool validate macropad/function_pad.yml
sudo ch57x-keyboard-tool upload macropad/function_pad.yml
sudo ch57x-keyboard-tool led 0 "press red"
```

`ch57x-keyboard-tool show-keys` lists valid key names.

## Usage

```fish
tv                   # list channels
tv bbc2              # play (switches channel if TV is already running)
tv --default         # play the configured default (what the TV launcher key does)
radio atlantic252
tv --now             # now & next
```

### Config file

```yaml
tvheadend:
  host: 192.168.0.10:9981

tv:
  label: TV                  # window title prefix
  default: bbc1              # channel for `tv --default` / the launcher key
  mpv_opts:                  # extra mpv options for this player
    - --autofit=1280x720
  channels:
    - name: bbc1             # what you type
      title: BBC ONE HD      # what mpv shows
      uuid: "0123456789abcdef0123456789abcdef"   # Tvheadend channel, or
    - name: atlantic252
      url: https://stream4.themediasite.co.uk:8042/   # an internet stream
```

`radio:` has the same shape. Quote UUIDs: an unquoted hex string like `123e45…` can be read as a number.
Channel order is playlist order, so the first eight channels line up with pad keys 1–8.

List Tvheadend channel UUIDs:

```fish
curl -s 'http://HOST:9981/api/channel/grid?limit=500' | jq -r '.entries[] | "\(.uuid)  \(.name)"'
```

The fish functions pass the Tvheadend host to the mpv EPG scripts as a script option
(`tvh-host`), so the config is the only place it's set.

## Notes

- **One tuner:** Tvheadend can only receive one multiplex at a time. TV plus a Tvheadend radio station
  on a different multiplex will fail; internet streams don't use the tuner.
- **Internet streams:** no EPG, so `radio-epg.lua` shows the stream's `icy-title` (current track) instead,
  and `--now` lists them as "internet stream".

## Licence

See [LICENSE](LICENSE).
