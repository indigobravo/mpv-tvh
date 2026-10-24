# The guide

[← README](../README.md)

![The EG-252 TV guide: eight channels against time, the selected programme set to record, and its details underneath](../images/guide.svg)

The TV and the radio each have a guide. It opens directly under the stack, the faceplates'
width, and runs down to the bottom of the screen, so the taller your screen the more you see.
Open and close it with GUIDE on the preamp, the pad's GUIDE key, or by clicking a
faceplate's display.

Pad keys 1–4 switch page: **1** the guide, **2** recordings, **3** presets, **4** streams.
Hold the pad's LAYER key and turn knob 2 for the volume.

## Listings

A week of listings, as far as Tvheadend's EPG goes, for the channels on your pad keys.

- Knob 1 moves through a channel's programmes; knob 2 changes channel.
- Press either knob to watch what's on now, or to record a later programme. Hold LAYER and press to record
  every episode (a Tvheadend series link). Press again to cancel.
- Programmes recording, scheduled or series-linked are marked in red, whoever set them up.
- Page Up / Page Down move a day; Esc goes back to now.

Tvheadend does the recording, so the Mac needn't be on.

## Recordings

Key 2 lists what's recording and scheduled first, then what's been recorded.

- Press a knob (WATCH) to play a recording. It plays on the TV, from either guide: the faceplate
  lights PVR and says PLAYBACK, and the preamp says PLAYBACK too. ◀ ▶ skip back and on 30 seconds, knob 1 seeks, and PLAY pauses. Pad keys
  1–8 go back to live TV; STOP, or the end of the recording, goes back to the channel you were
  on, stopped.
- DELETE (pressed twice) removes it from Tvheadend.
- CANCEL REC, STOP REC and CANCEL ALL do what they say.

## Presets and SETUP

**SETUP** on the preamp opens the TV's guide at its SETUP page. Type your Tvheadend server's
address (`tvheadend.local`, or an IP address; `:9981` is added if you leave the port off), or
press FIND to look for it on your network, then CONNECT. The first time, the guide goes straight
on to the presets.

Until mpv-tvh is set up (no config, and SETUP never connected), switching on opens SETUP by
itself. DEMO (or Esc) closes it and carries on with the demo.

**The first CONNECT** fills the keys for you: the first eight TV channels and the first eight
radio stations, in Tvheadend's channel order. Then it walks you through them in two steps: the
TV's keys, then NEXT: RADIO for the radio's, then DONE for the guide (holding LAYER and pressing a knob does
NEXT and DONE too). Change any key on the way.

If the TV or radio has nothing on its keys later (you cleared them, say), its faceplate says so,
and choosing it on the preamp, or opening its guide, goes straight to its presets.

**Presets** (key 3) list every channel on the server.

- Knob 1 steps through the filters: ALL, HD, SD, UHD and RADIO, from the type Tvheadend gives each
  service, then any channel tags you've made in Tvheadend (Favourites, say).
- Knob 2 moves through the channels. Pressing a knob puts the selected one on the next free pad
  key, or takes it off. RADIO's are the radio's keys; the rest are the TV's.
- CLEAR KEYS (pressed twice) empties them.

The TV and radio pick up the new channels when you leave the presets or streams, or close the
guide, without stopping what's playing if it's still there.

mpv-tvh doesn't log in to Tvheadend for the presets yet: set Tvheadend to allow your network
without a login.

## Streams

Key 4 keeps internet radio and TV links.

- Copy a stream's link, then press a knob (or ADD LINK) to add it. mpv-tvh checks it, names it
  from the station where the stream says its name, and makes it TV if it has a picture, radio if
  not.
- Type to rename the one selected; knob 1 switches it between TV and radio; REMOVE (pressed
  twice) deletes it.

Streams then show up in the presets with Tvheadend's channels, to put on a key. They work without
Tvheadend too.
