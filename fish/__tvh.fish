function __tvh --description 'Shared Tvheadend / internet stream player for tv and radio'
    set -l kind $argv[1]
    set -e argv[1]

    # --- Config -----------------------------------------------------------
    # Your config, or (without one) the demo
    set -l cfg (__tvh_config)
    set -l demo
    test $status -ne 0; and set demo 1

    if not command -q jq
        echo "$kind: needs jq to read its config: brew install jq" >&2
        return 1
    end
    if not test -r $cfg
        echo "$kind: config not found, and no demo config at $cfg" >&2
        echo "  copy examples/config.json from the mpv-tvh repo to ~/.config/mpv-tvh/config.json" >&2
        return 1
    end
    if not jq -e . $cfg >/dev/null 2>&1
        echo "$kind: $cfg isn't valid JSON (jq . $cfg shows where)" >&2
        return 1
    end
    if test -n "$demo"
        echo "$kind: demo mode (not set up yet: SETUP on the preamp)"
    end
    if not contains -- $kind tv radio
        echo "__tvh: invalid player '$kind' (tv or radio)" >&2
        return 1
    end
    if test (jq -r ".$kind | type" $cfg) != object
        echo "$kind: no \"$kind\" section in $cfg" >&2
        return 1
    end

    set -l host (jq -r '.tvheadend.host // ""' $cfg)
    set -l label (jq -r ".$kind.label // \"$kind\"" $cfg)
    set -l default (jq -r ".$kind.default // \"\"" $cfg)
    set -l start (jq -r ".$kind.start // \"\"" $cfg)
    set -l mpv_opts (jq -r ".$kind.mpv_opts // [] | .[]" $cfg)
    set -l panel_opts (jq -r ".$kind.panel_opts // [] | .[]" $cfg)
    set -l guide_opts (jq -r ".$kind.guide_opts // [] | .[]" $cfg)
    set -l names (jq -r ".$kind.channels // [] | .[] | .name" $cfg)
    set -l titles (jq -r ".$kind.channels // [] | .[] | (.title // .name)" $cfg)
    set -l srcs (jq -r ".$kind.channels // [] | .[] | (.url // .uuid // \"\")" $cfg)

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
        if test (count $pu) -gt 0
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

    # The TV and radio can start with no channels once SETUP has been run:
    # their presets come later
    set -l empty_ok
    test -n "$host"; and set empty_ok 1
    if test (count $names) -eq 0; and test -z "$empty_ok"
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

    set -l sock /tmp/mpv-$kind

    # --- Commands ---------------------------------------------------------

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

    # Configured default channel (used by the Hammerspoon launchers and the
    # preamp). The TV and radio start stopped on it, unless `start:` names a
    # channel to play straight away; PLAY plays it
    set -l stopped
    if contains -- "$argv[1]" --default -d
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
            set argv[1] ""                              # no channels yet
        end
    end

    # Usage and channel list
    if test (count $argv) -eq 0
        echo "usage:"
        echo "  $kind <channel>     play a channel (< / > to switch)"
        echo "  $kind --default     play the default channel"
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
    else if test -z "$idx"; and test -n "$empty_ok"; and test -z "$argv[1]"
        # no channels yet: start idle, for the presets
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
    else
        echo "→ $label (no channels yet: presets, key 3 in the guide)"
    end

    # The guide: directly under the stack (the radio's faceplate), the
    # faceplates' width, 20 pixels down (Hammerspoon then stretches it to the
    # bottom of the screen), unless guide_opts places it
    if test (count $guide_opts) -eq 0
        set -l rg (string match -r -- '^--geometry=(\d+)x(\d+)\+(-?\d+)\+(-?\d+)$' \
            (string match -- '--geometry=*' (jq -r '.radio.mpv_opts // [] | .[]' $cfg)))
        if test (count $rg) -eq 5
            set guide_opts --geometry=$rg[2]x(math --scale=0 "$rg[2] * 0.45")+$rg[4]+(math $rg[5] + $rg[3] + 20)
        end
    end
    test (count $guide_opts) -eq 0; and set guide_opts '--geometry=100%x50%+0-0'
    set -a guide_opts --macos-app-activation-policy=accessory --auto-window-resize=no
    set -l guide_opt --script-opts-append=lib-opts=(string join '|' -- $guide_opts)

    # The TV's faceplate: a second, media-less mpv window that mirrors and
    # drives the player. It closes itself when the player quits.
    if test "$kind" = tv; and test (count $panel_opts) -gt 0
        and not pgrep -f "[i]pc-server=/tmp/mpv-panel-$kind" >/dev/null
        rm -f /tmp/mpv-$kind.state.json
        mpv --idle=yes --force-window=yes --osc=no --no-border \
            --macos-app-activation-policy=accessory \
            --title="$label panel" \
            --input-ipc-server=/tmp/mpv-panel-$kind \
            --script-opts-append=tvh-host=$host --script-opts-append=tvh-demo=$demo \
            $guide_opt \
            $panel_opts >/dev/null 2>&1 &
        disown
    end

    # Already running? Switch channel in that player instead of starting another
    if pgrep -f "[i]pc-server=$sock" >/dev/null
        rm -f $m3u
        test -n "$panel_only"; and return 0
        test -n "$idx"; or return 0
        test -n "$stopped"; and return 0                  # --default: leave it as it is
        echo '{"command":["playlist-play-index",'(math $idx - 1)']}' | nc -U -w 1 $sock >/dev/null
        echo "→ $titles[$idx] (switched running $label player)"
        return 0
    end

    # The radio is its own faceplate: its guide
    set -l extra
    test "$kind" = radio; and set extra $guide_opt
    set -l list
    if test -n "$stopped"; and test -n "$idx"         # loaded, not playing (player-state.lua)
        set list --idle=yes --script-opts-append=tvh-list=$m3u --script-opts-append=tvh-pos=(math $idx - 1)
    else if test -n "$idx"
        set list --playlist-start=(math $idx - 1) --playlist=$m3u
    else                                               # no channels yet: wait for the presets
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
