function __tvh --description 'Shared Tvheadend / internet stream player for tv and radio'
    set -l kind $argv[1]
    set -e argv[1]

    # --- Config -----------------------------------------------------------
    set -l cfg ~/.config/mpv-tvh/config.yml
    set -q MPV_TVH_CONFIG; and set cfg $MPV_TVH_CONFIG

    # Needs mikefarah's yq (Homebrew's yq), not the Python yq wrapper
    if not command -q yq; or not yq --version 2>&1 | string match -q '*mikefarah*'
        echo "$kind: needs yq (mikefarah/yq) to read its config: brew install yq" >&2
        return 1
    end
    if not test -r $cfg
        echo "$kind: config not found: $cfg" >&2
        echo "  copy examples/config.yml from the mpv-tvh repo to get started" >&2
        return 1
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
    set -l mpv_opts (yq ".$kind.mpv_opts // [] | .[]" $cfg)
    set -l names (yq ".$kind.channels // [] | .[] | .name" $cfg)
    set -l titles (yq ".$kind.channels // [] | .[] | .title // .name" $cfg)
    set -l srcs (yq ".$kind.channels // [] | .[] | .url // .uuid // \"\"" $cfg)

    if test (count $names) -eq 0
        echo "$kind: no channels in $cfg" >&2
        return 1
    end
    for i in (seq (count $names))
        if test -z "$srcs[$i]"
            echo "$kind: channel '$names[$i]' has no uuid or url" >&2
            return 1
        end
        if test -z "$host"; and not string match -q 'http*' -- $srcs[$i]
            echo "$kind: channel '$names[$i]' needs tvheadend.host in $cfg" >&2
            return 1
        end
    end

    set -l sock /tmp/mpv-$kind

    # --- Commands ---------------------------------------------------------

    # Now & next listing
    if test "$argv[1]" = --now; or test "$argv[1]" = -n
        __tv_now "$host" $names $srcs
        return $status
    end

    # Configured default channel (used by the Hammerspoon launchers)
    if test "$argv[1]" = --default; or test "$argv[1]" = -d
        if test -n "$default"
            set argv[1] $default
        else
            set argv[1] $names[1]
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
        for i in (seq (count $names))
            printf "  %-15s %s\n" $names[$i] $titles[$i]
        end
        return 1
    end

    set -l idx (contains -i -- $argv[1] $names)
    if test -z "$idx"
        echo "$kind: unknown channel '$argv[1]'" >&2
        echo "try one of: $names" >&2
        return 1
    end

    # Already running? Switch channel in that player instead of starting another
    if pgrep -f "[i]pc-server=$sock" >/dev/null
        echo '{"command":["playlist-play-index",'(math $idx - 1)']}' | nc -U -w 1 $sock >/dev/null
        echo "→ $titles[$idx] (switched running $label player)"
        return 0
    end

    # Build the playlist: UUIDs go via Tvheadend, URLs are used as-is
    set -l m3u (mktemp -t $kind.XXXXXX.m3u)
    echo "#EXTM3U" > $m3u
    for i in (seq (count $srcs))
        set -l src $srcs[$i]
        string match -q 'http*' -- $src; or set src "http://$host/stream/channel/$src"
        echo "#EXTINF:-1,$titles[$i]" >> $m3u
        echo $src >> $m3u
    end

    echo "→ $titles[$idx] (F8 for channel list, < / > to switch)"

    # The EPG scripts read the Tvheadend host from script-opts
    mpv $mpv_opts \
        --script-opts-append=tvh-host=$host \
        --title="$label"' · ${media-title}' \
        --input-ipc-server=$sock \
        --playlist-start=(math $idx - 1) \
        --playlist=$m3u \
        $argv[2..]

    rm -f $m3u
end
