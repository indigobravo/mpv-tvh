function __tvh --description 'Shared Tvheadend / internet stream player for tv and radio'
    set -l kind $argv[1]
    set -e argv[1]

    # --- Config -----------------------------------------------------------
    # Your config, or (without one) the demo
    set -l cfg (__tvh_config)
    set -l demo
    test $status -ne 0; and set demo 1

    # Needs mikefarah's yq (Homebrew's yq), not the Python yq wrapper
    if not command -q yq; or not yq --version 2>&1 | string match -q '*mikefarah*'
        echo "$kind: needs yq (mikefarah/yq) to read its config: brew install yq" >&2
        return 1
    end
    if not test -r $cfg
        echo "$kind: config not found, and no demo config at $cfg" >&2
        echo "  copy examples/config.yml from the mpv-tvh repo to ~/.config/mpv-tvh/config.yml" >&2
        return 1
    end
    if test -n "$demo"
        echo "$kind: demo mode (no ~/.config/mpv-tvh/config.yml; see the README to set it up)"
    end
    if not string match -qr '^[a-z0-9_]+$' -- $kind; or test "$kind" = tvheadend
        echo "__tvh: invalid player '$kind'" >&2
        return 1
    end
    if test (yq ".$kind | type" $cfg) != '!!map'
        echo "$kind: no '$kind:' section in $cfg" >&2
        return 1
    end

    set -l host (yq '.tvheadend.host // ""' $cfg)
    set -l label (yq ".$kind.label // \"$kind\"" $cfg)
    set -l default (yq ".$kind.default // \"\"" $cfg)
    set -l start (yq ".$kind.start // \"\"" $cfg)
    set -l mpv_opts (yq ".$kind.mpv_opts // [] | .[]" $cfg)
    set -l panel_opts (yq ".$kind.panel_opts // [] | .[]" $cfg)
    set -l vu_opts (yq ".$kind.vu_opts // [] | .[]" $cfg)
    set -l list_opts (yq ".$kind.list_opts // [] | .[]" $cfg)
    set -l library (yq ".$kind.library // \"\"" $cfg)
    set -l library_opts (yq ".$kind.library_opts // [] | .[]" $cfg)
    set -l names (yq ".$kind.channels // [] | .[] | .name" $cfg)
    set -l titles (yq ".$kind.channels // [] | .[] | .title // .name" $cfg)
    set -l srcs (yq ".$kind.channels // [] | .[] | .url // .uuid // \"\"" $cfg)

    # Presets, set up from the guide (SETUP on the preamp, then key 3):
    # ~/.config/mpv-tvh/presets.json holds the Tvheadend address and up to
    # eight TV channels and eight radio stations (Tvheadend's, or streams kept
    # in the guide's key 4). They take the place of the
    # config's Tvheadend channels; its internet streams stay, after them.
    set -l presets ~/.config/mpv-tvh/presets.json
    if test -r $presets; and command -q jq
        set -l ph (jq -r '.host // ""' $presets 2>/dev/null)
        if test -n "$ph"
            set host $ph
            set demo                                    # set up: not the demo any more
        end
        set -l pu (jq -r ".$kind // [] | .[] | .url // .uuid" $presets 2>/dev/null)   # streams: their link
        if contains -- $kind tv radio; and test (count $pu) -gt 0
            set -l pt (jq -r ".$kind // [] | .[] | .title" $presets)
            set -l keep_n; set -l keep_t; set -l keep_s
            for i in (test (count $srcs) -gt 0; and seq (count $srcs))
                if string match -qr '^https?://' -- $srcs[$i]   # internet streams stay
                    set -a keep_n $names[$i]; set -a keep_t $titles[$i]; set -a keep_s $srcs[$i]
                end
            end
            set names; set titles; set srcs
            for i in (seq (count $pu))
                set -a names (string lower -- $pt[$i] | string replace -ra '[^a-z0-9]+' '')
                set -a titles $pt[$i]
                set -a srcs $pu[$i]
            end
            set -a names $keep_n; set -a titles $keep_t; set -a srcs $keep_s
            contains -- "$default" $names; or set default $names[1]
            contains -- "$start" $names; or set start
        end
    end

    # YouTube and music can start with nothing configured: links are pasted
    # into YouTube's panel, music is dropped on its playlist window. So can
    # the TV and radio once SETUP has been run: their presets come later
    set -l empty_ok youtube music video
    test -n "$host"; and set -a empty_ok tv radio
    if test (count $names) -eq 0; and not contains -- $kind $empty_ok
        echo "$kind: no channels in $cfg" >&2
        return 1
    end
    for i in (test (count $names) -gt 0; and seq (count $names))
        if test -z "$srcs[$i]"
            echo "$kind: channel '$names[$i]' has no uuid or url" >&2
            return 1
        end
        if test -z "$host"; and not string match -qr '^[a-z]+://' -- $srcs[$i]
            echo "$kind: channel '$names[$i]' needs tvheadend.host in $cfg" >&2
            return 1
        end
    end

    # MPV_TVH_AT=+X+Y (the preamp, when stacked): open the faceplate there
    # instead (the radio's window is its faceplate)
    if set -q MPV_TVH_AT; and string match -qr '^\+\d+\+\d+$' -- $MPV_TVH_AT
        set -l re '^(--geometry=\d+x\d+)\+\d+\+\d+$'
        if test "$kind" = radio
            set mpv_opts (string replace -r -- $re '$1'$MPV_TVH_AT $mpv_opts)
        else
            set panel_opts (string replace -r -- $re '$1'$MPV_TVH_AT $panel_opts)
        end
    end

    set -l sock /tmp/mpv-$kind

    # --- Commands ---------------------------------------------------------

    # Now & next listing
    if test "$argv[1]" = --now; or test "$argv[1]" = -n
        __tv_now "$host" $names $srcs
        return $status
    end

    # --reload: give a running TV or radio player its channels again (the
    # guide does this when the presets change); it stays stopped, or keeps
    # playing the same channel
    if test "$argv[1]" = --reload
        pgrep -f "[i]pc-server=$sock" >/dev/null; or return 0
        set -l m3u (mktemp -t $kind.XXXXXX.m3u)
        echo "#EXTM3U" > $m3u
        for i in (test (count $srcs) -gt 0; and seq (count $srcs))
            set -l src $srcs[$i]
            string match -qr '^[a-z]+://' -- $src; or set src "http://$host/stream/channel/$src"
            echo "#EXTINF:-1,$titles[$i]" >> $m3u
            echo $src >> $m3u
        end
        jq -nc --arg p $m3u '{command: ["script-message", "tvh-load", $p]}' | nc -U -w 1 $sock >/dev/null
        return 0
    end

    # --panel: reopen the faceplate of a running player (the preamp uses it)
    set -l panel_only
    if test "$argv[1]" = --panel
        pgrep -f "[i]pc-server=$sock" >/dev/null; or return 0
        set panel_only 1
        set argv ""
    end

    # YouTube and music on their own just start (default, saved queue, or idle)
    contains -- $kind youtube music video; and test (count $argv) -eq 0; and set argv --default

    # Music, video: a file or folder to add to the queue and play
    set -l music_add
    if contains -- $kind music video; and test -n "$argv[1]"; and test -e "$argv[1]"
        set music_add (realpath -- $argv[1])
        set argv[1] ""
    end

    # Configured default channel (used by the Hammerspoon launchers and the
    # preamp). TV and radio start stopped on it, unless `start:` names a
    # channel to play straight away; PLAY plays it
    set -l stopped
    if contains -- $kind tv radio; and contains -- "$argv[1]" --default -d
        if test -n "$start"
            set argv[1] $start
        else
            set stopped 1
        end
    end
    if test "$argv[1]" = --default; or test "$argv[1]" = -d
        if test -n "$default"
            set argv[1] $default
        else if test (count $names) -gt 0
            set argv[1] $names[1]
        else
            set argv[1] ""                              # YouTube with nothing configured
        end
    end

    # Usage and channel list
    if test (count $argv) -eq 0
        echo "usage:"
        echo "  $kind <channel>     play a channel (< / > to switch)"
        echo "  $kind --default     play the default channel"
        echo "  $kind --now         show now & next"
        echo
        echo "channels:"
        for i in (test (count $names) -gt 0; and seq (count $names))
            printf "  %-15s %s\n" $names[$i] $titles[$i]
        end
        return 1
    end

    set -l idx (contains -i -- $argv[1] $names)
    if test -n "$panel_only"
        # nothing to play
    else if test -z "$idx"; and contains -- $kind $empty_ok; and test -z "$argv[1]"
        # nothing to pick: start idle (YouTube: links from the panel and the
        # recent list; music: the saved queue and the playlist window)
    else if test -z "$idx"
        echo "$kind: unknown channel '$argv[1]'" >&2
        echo "try one of: $names" >&2
        return 1
    end

    # Build the playlist: UUIDs go via Tvheadend, URLs are used as-is
    set -l m3u (mktemp -t $kind.XXXXXX.m3u)
    echo "#EXTM3U" > $m3u
    for i in (test (count $srcs) -gt 0; and seq (count $srcs))
        set -l src $srcs[$i]
        string match -qr '^[a-z]+://' -- $src; or set src "http://$host/stream/channel/$src"
        echo "#EXTINF:-1,$titles[$i]" >> $m3u
        echo $src >> $m3u
    end

    if test -n "$idx"
        echo "→ $titles[$idx] (F8 for channel list, < / > to switch)"
    else if test "$kind" = music
        echo "→ $label (drop music files or folders on its playlist window)"
    else if test "$kind" = video
        echo "→ $label (pick a video in its library: LIBRARY on the preamp)"
    else if contains -- $kind tv radio
        echo "→ $label (no channels yet: presets, key 3 in the guide)"
    else
        echo "→ $label (copy a YouTube link, then click its panel)"
    end

    # Two picture slots: the primary is the TV window (the TV, and the
    # radio's VU meter); the secondary, 30 pixels below it and the same size,
    # is for everything else: the YouTube and video player pictures, the
    # other VU meters and the playlists (unless their own options place them)
    set -l tv_geometry (string match -- '--geometry=*' (yq '.tv.mpv_opts // [] | .[]' $cfg))
    set -l secondary $tv_geometry
    set -l g (string match -r -- '^--geometry=(\d+)x(\d+)\+(-?\d+)\+(-?\d+)$' $tv_geometry[1])
    test (count $g) -eq 5; and set secondary --geometry=$g[2]x$g[3]+$g[4]+(math $g[5] + $g[3] + 30)
    # The radio has no picture, so its VU meter takes the primary slot, the
    # TV window's (over the TV picture while the tuner's chosen)
    if test (count $vu_opts) -eq 0; and test "$kind" = radio; and test (count $tv_geometry) -gt 0
        set vu_opts $tv_geometry[1]
    end
    test (count $vu_opts) -eq 0; and set vu_opts $secondary
    set -a vu_opts --macos-app-activation-policy=accessory
    set -l vu_opt --script-opts-append=vu-opts=(string join '|' -- $vu_opts)
    # Music's playlist window goes in the secondary slot too; dropped files are added to it
    # (not played in it), and it keeps its size
    test (count $list_opts) -eq 0; and set list_opts $secondary
    set -a list_opts --macos-app-activation-policy=accessory --drag-and-drop=append --auto-window-resize=no
    set -l list_opt --script-opts-append=list-opts=(string join '|' -- $list_opts)
    # Recordings (the recorder, and YouTube's SAVE): recorder.folder, or a
    # recordings folder in the music folder
    set -l music_lib (yq '.music.library // "~/Music"' $cfg)
    set -l rec_dir (yq '.recorder.folder // ""' $cfg)
    test -z "$rec_dir"; and set rec_dir $music_lib/recordings
    set rec_dir (string replace -r -- '^~' $HOME $rec_dir)
    # The library window (CD, video): the bottom half of the screen unless
    # library_opts places it; it browses library (default: ~/Music for the
    # CD player, the recordings for the video player)
    # Directly under the stack, the faceplates' width, 20 pixels down: the
    # TV's (its guide) under the radio's faceplate, the CD's and video's
    # under their own (Hammerspoon then stretches it to the bottom of the
    # screen and hides what it covers)
    if contains -- $kind tv radio music video; and test (count $library_opts) -eq 0
        set -l above (string match -- '--geometry=*' $panel_opts)
        contains -- $kind tv radio; and set above (yq '.radio.mpv_opts // [] | .[]' $cfg)
        set -l rg (string match -r -- '^--geometry=(\d+)x(\d+)\+(-?\d+)\+(-?\d+)$' $above)
        if test (count $rg) -eq 5
            set library_opts --geometry=$rg[2]x(math --scale=0 "$rg[2] * 0.45")+$rg[4]+(math $rg[5] + $rg[3] + 20)
        end
    end
    test (count $library_opts) -eq 0; and set library_opts '--geometry=100%x50%+0-0'
    set -a library_opts --macos-app-activation-policy=accessory --auto-window-resize=no
    if test -z "$library"
        set library ~/Music
        test "$kind" = video; and set library $rec_dir
    end
    set library (string replace -r -- '^~' $HOME $library)
    set -l lib_opt --script-opts-append=lib-opts=(string join '|' -- $library_opts) \
        --script-opts-append=lib-root=$library --script-opts-append=rec-dir=$rec_dir

    # Control panel (TV, YouTube, music): a second, media-less mpv window showing a
    # faceplate that mirrors and drives this player. It closes itself when the
    # player quits.
    if test "$kind" != radio; and test (count $panel_opts) -gt 0
        and not pgrep -f "[i]pc-server=/tmp/mpv-panel-$kind" >/dev/null
        rm -f /tmp/mpv-$kind.state.json
        mpv --idle=yes --force-window=yes --osc=no --no-border \
            --macos-app-activation-policy=accessory \
            --title="$label panel" \
            --input-ipc-server=/tmp/mpv-panel-$kind \
            --script-opts-append=tvh-host=$host --script-opts-append=tvh-demo=$demo \
            $vu_opt $list_opt $lib_opt \
            $panel_opts >/dev/null 2>&1 &
        disown
    end

    # Already running? Switch channel in that player instead of starting another
    set -l add_json
    test -n "$music_add"; and set add_json (jq -nc --arg p $music_add '{command: ["script-message", "music-add", $p, "play"]}')
    if pgrep -f "[i]pc-server=$sock" >/dev/null
        rm -f $m3u
        test -n "$panel_only"; and return 0
        if test -n "$add_json"
            echo $add_json | nc -U -w 1 $sock >/dev/null
            echo "→ added $music_add"
            return 0
        end
        test -n "$idx"; or return 0
        test -n "$stopped"; and return 0                  # --default: leave it as it is
        echo '{"command":["playlist-play-index",'(math $idx - 1)']}' | nc -U -w 1 $sock >/dev/null
        echo "→ $titles[$idx] (switched running $label player)"
        return 0
    end


    # Radio: its faceplate opens the VU meter. YouTube: sound only until the
    # preamp's PICTURE shows the picture, in the secondary slot
    # (unless mpv_opts places it); stays open when the playlist ends; no TV
    # deinterlacing (mpv.conf) on progressive video.
    set -l extra
    test "$kind" = radio; and set extra $vu_opt $lib_opt   # its VU meter, REC and guide
    if test "$kind" = youtube
        set extra --idle=yes --force-window=no --vid=no --ytdl=yes --macos-app-activation-policy=accessory \
            --deinterlace=no --vf=
        string match -q -- '--geometry=*' $mpv_opts; or set -a extra $secondary
    end
    # Video: the picture in the secondary slot (unless mpv_opts places it); off
    # until you play something (or PICTURE); carries on where each video was
    # left (resume)
    if test "$kind" = video
        set extra --idle=yes --force-window=no --vid=no --macos-app-activation-policy=accessory \
            --deinterlace=no --vf= --audio-display=no \
            --watch-later-options-remove=volume --watch-later-options-remove=mute \
            --watch-later-options-remove=vid --watch-later-options-remove=af   # resume the place, not the sound
        string match -q -- '--geometry=*' $mpv_opts; or set -a extra $secondary
    end
    if test "$kind" = video; and test -n "$add_json"    # a file or folder given, once it's up
        sh -c 'sleep 2; printf "%s\n" "$1" | nc -U -w 1 "$2" >/dev/null 2>&1' sh $add_json $sock &
        disown
    end
    # Music: sound only (no cover-art window); stays open when the queue ends
    if test "$kind" = music
        set extra --idle=yes --force-window=no --vid=no --audio-display=no \
            --macos-app-activation-policy=accessory
        # a file or folder given on the command line, once the player is up
        if test -n "$add_json"
            sh -c 'sleep 2; printf "%s\n" "$1" | nc -U -w 1 "$2" >/dev/null 2>&1' sh $add_json $sock &
            disown
        end
    end
    set -l list
    if test -n "$stopped"; and test -n "$idx"         # loaded, not playing (player-state.lua)
        set list --idle=yes --script-opts-append=tvh-list=$m3u --script-opts-append=tvh-pos=(math $idx - 1)
    else if test -n "$idx"
        set list --playlist-start=(math $idx - 1) --playlist=$m3u
    else if contains -- $kind tv radio                 # no channels yet: wait for the presets
        set list --idle=yes
    end
    # Test cards (the demo's TV) are made by mpv itself (av://lavfi:...): mpv
    # only plays those from a playlist when told it's safe (this one's ours)
    string match -q 'av://*' -- $srcs; and set -a list --load-unsafe-playlists

    # The overlay scripts read these from script-opts
    mpv $extra $mpv_opts \
        --script-opts-append=tvh-host=$host --script-opts-append=tvh-demo=$demo \
        --title="$label"' · ${media-title}' \
        --input-ipc-server=$sock \
        $list $argv[2..]

    rm -f $m3u
end
