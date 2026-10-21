function preamp --description 'mpv-tvh preamp: choose the source you hear (tv, tuner, net, cd)'
    set -l cfg (__tvh_config)              # yours, or the demo's
    set -l input $argv[1]
    if test -n "$input"; and not contains -- $input tv tuner net cd vid
        echo "usage: preamp [tv|tuner|net|cd|vid]" >&2
        return 1
    end

    # Already on: just choose the source
    if pgrep -f '[i]pc-server=/tmp/mpv-preamp' >/dev/null
        test -n "$input"; and echo '{"command":["script-message","preamp-select","'$input'"]}' \
            | nc -U -w 1 /tmp/mpv-preamp >/dev/null
        return 0
    end

    set -l opts
    test -r $cfg; and set opts (yq '.preamp.panel_opts // [] | .[]' $cfg)
    # STACK puts the faceplates where the TV window goes
    set -l tv_geometry
    test -r $cfg; and set tv_geometry (string replace -- '--geometry=' '' \
        (string match -- '--geometry=*' (yq '.tv.mpv_opts // [] | .[]' $cfg)))
    test (count $opts) -eq 0; and set opts --geometry=1816x364
    # STACK's second row (pixels): under the preamp and the TV faceplate,
    # 20px (10pt on Retina) apart, as Hammerspoon stacks them. Sources the
    # preamp starts while stacked open there, so they don't jump.
    set -l row2
    set -l pg (string match -r -- '^--geometry=(\d+)x(\d+)\+(\d+)\+(\d+)$' $opts)
    set -l tg
    test -r $cfg; and set tg (string match -r -- '^--geometry=(\d+)x(\d+)' (yq '.tv.panel_opts // [] | .[]' $cfg))
    if test (count $pg) -eq 5; and test (count $tg) -eq 3
        set row2 +$pg[4]+(math $pg[5] + $pg[3] + 20 + $tg[3] + 20)
    end
    mpv --idle=yes --force-window=yes --osc=no --no-border \
        --macos-app-activation-policy=accessory --title=Preamp \
        --input-ipc-server=/tmp/mpv-preamp \
        --script-opts-append=preamp-input=$input \
        --script-opts-append=preamp-stack=$tv_geometry[1] \
        --script-opts-append=preamp-row2=$row2 $opts >/dev/null 2>&1 &
    disown
end
