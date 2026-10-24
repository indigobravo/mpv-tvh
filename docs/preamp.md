# The preamp and faceplates

[← README](../README.md)

## PR-252 preamp

The preamp sits at the top of the stack and chooses what you hear. Switching it on starts the TV
and the radio, on TV.

**INPUT: TV and TUNER.** Both keep running and stay tuned: the one chosen plays at full volume
and the other at none. Switching back is instant, and finds live TV and radio where they are
now.

**GUIDE** opens and closes the chosen source's [guide](guide.md).

**MUTE** and the big **VOLUME** knob (scroll over it) set the Mac's volume.

**The display** shows the sources running and the one chosen, the volume, what's playing, level
bars, the sound device (OUT), the tuner's signal, and the [macro pad](macropad.md)'s layer:
**PAD** with **CH**, **TRANS** or **DISP** lit.

**DISPLAY buttons:**

| Button | Does |
|---|---|
| CLOCK | Show the time on the lower line |
| DIM | Darken the display and stop the level bars |
| COLOUR | Follow the source's display colour (AUTO), or pick one |
| SCROLL | When long text scrolls: AUTO (while the preamp's in front), OFF, ON |

**SETUP** (TVHEADEND, level with POWER) connects Tvheadend and picks presets, in the guide.
POWER switches everything off.

### Signal

While the chosen source is playing a Tvheadend channel, the preamp finds which of Tvheadend's
tuners it's on and shows that tuner's signal as five bars, and its SNR. They come from
Tvheadend's `/api/status/inputs` every few seconds. Internet streams and recordings have no
tuner, so the meter goes dark.

Tvheadend only shows tuner status to admin users. If the meter stays dark while a channel plays,
give the preamp an admin login in `~/.netrc` (see [Install](install.md#7-logins)). Signal and
SNR are only filled in for DVB-T, DVB-C and DVB-S tuners while they're in use.

## TV-252 and TU-252 faceplates

The TV and radio have the same front:

| Part | Does |
|---|---|
| DIM, COLOUR, SCROLL | As on the preamp, for this faceplate (the clock is on the preamp) |
| The display | Lamps, the channel, and now and next from Tvheadend's guide. Click it to open the guide |
| ◀ ▶ | The channel before or after (in a recording: back or on 30 seconds) |
| PLAY · PAUSE | Play, pause, and after STOP play again |
| STOP | Stop the stream, which frees the tuner |

The lamps:

| Lamp | Lit when |
|---|---|
| DVB | Playing a Tvheadend channel |
| NET | Playing an internet stream |
| PVR | Playing back a Tvheadend recording: the lower line says PLAYBACK (or PAUSED), and which channel it was recorded from |
| HD, 16:9, STEREO / 5.1, SUBS | TV: what the channel's sending |
| TUNED, STEREO, RDS | Radio: tuned, stereo, and station or track text |
| EPG | TV: there's guide data |
| TIMER | Tvheadend is recording, or will record, now or next |
| P01–P08 | The preset playing |
| SIG | Seconds of stream buffered |

If a channel won't tune because Tvheadend's tuners are busy recording, the faceplate says so. If
the recording is on a channel in your list, it switches to that one.

Scroll over a faceplate to change channel; drag it to move it.
