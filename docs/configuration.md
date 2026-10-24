# Configuration

[← README](../README.md)

Most setups don't need a config: SETUP on the preamp connects Tvheadend, and the presets (key 3
in the guide) and streams (key 4) pick the channels. A config is for your own window positions,
the channel the TV or radio starts on, and channels you'd rather list by hand.

mpv-tvh reads `~/.config/mpv-tvh/config.json` (or the file `MPV_TVH_CONFIG` names), with `jq`.
`examples/config.json` is a full one to copy:

```sh
mkdir -p ~/.config/mpv-tvh
cp examples/config.json ~/.config/mpv-tvh/config.json
```

Check it with `jq . ~/.config/mpv-tvh/config.json`: it prints the file, or where it's broken.

## Which file is used

| You have | It uses |
|---|---|
| `config.json` | Your config |
| No config, SETUP run | `examples/defaults.json`, with your presets as the channels |
| Neither | `examples/demo.json`: test cards and internet radio |

The Tvheadend address and presets that SETUP saves are kept in
`~/.config/mpv-tvh/presets.json`. They win over the config's Tvheadend address and channels.
Internet streams in the config stay, after the presets. Delete `presets.json` to start again.

## A minimal config

```json
{
  "tvheadend": { "host": "192.168.0.10:9981" },
  "tv": {
    "default": "bbc1",
    "channels": [
      { "name": "bbc1", "title": "BBC ONE HD", "uuid": "0123456789abcdef0123456789abcdef" },
      { "name": "atlantic252", "url": "https://stream4.themediasite.co.uk:8042/" }
    ]
  },
  "radio": {
    "default": "radio4",
    "channels": [
      { "name": "radio4", "title": "BBC Radio 4", "uuid": "00112233445566778899aabbccddeeff" }
    ]
  }
}
```

## The settings

| Setting | What it is |
|---|---|
| `tvheadend.host` | The server, `host:port` |
| `tv`, `radio` | The two players, used by the `tv` and `radio` commands |
| `.label` | The player's name in its window title |
| `.default` | The channel it starts on, stopped (`tv --default`) |
| `.start` | A channel to play straight away when it starts, instead |
| `.channels` | The channels, in pad-key order: the first eight are keys 1–8 |
| `.mpv_opts` | Options for the player's mpv |
| `.panel_opts` | Options for the TV's faceplate window |
| `.guide_opts` | Options for the guide window |
| `preamp.panel_opts` | Options for the preamp's window |

Each channel has:

| Key | What it is |
|---|---|
| `name` | What you type: `tv bbc1` |
| `title` | What the display shows (defaults to `name`) |
| `uuid` | A Tvheadend channel, or |
| `url` | An internet stream (no tuner, no guide) |

List your Tvheadend channel UUIDs with:

```sh
curl -s 'http://HOST:9981/api/channel/grid?limit=500' | jq -r '.entries[] | "\(.uuid)  \(.name)"'
```

## Window positions

Positions are `--geometry` options in pixels (Retina pixels on a Retina screen). The examples
are laid out for a MacBook Air: the stack down the left, the TV picture top right.

| Setting | Window | Default |
|---|---|---|
| `preamp.panel_opts` | The preamp | Top of the stack |
| `tv.mpv_opts` | The TV picture | Top right |
| `tv.panel_opts` | The TV faceplate | Under the preamp |
| `radio.mpv_opts` | The radio, which is its own faceplate | Under the TV's |
| `tv.guide_opts`, `radio.guide_opts` | The guides | Under the stack, down to the bottom of the screen |

Keep the preamp twice a faceplate's height, at the same width (1816×364 and 1816×182 in the
examples), so the preamp and faceplates line up.

## From config.yml

Earlier versions read `config.yml` with `yq`. If you still have one, mpv-tvh says so; convert it
once with:

```sh
yq -o=json ~/.config/mpv-tvh/config.yml > ~/.config/mpv-tvh/config.json
```
