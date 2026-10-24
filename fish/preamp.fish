function preamp --description 'mpv-tvh preamp: switch on the TV and radio, and choose which you hear (tv, tuner)'
    set -l cfg (__tvh_config)              # yours, or the demo's
    set -l unset $status                   # 1: not set up yet, so ask for Tvheadend at switch-on
    set -l demo
    test $unset -ne 0; and set demo 1
    set -l input $argv[1]
    if test -n "$input"; and not contains -- $input tv tuner
        echo "usage: preamp [tv|tuner]" >&2
        return 1
    end

    # Already on: just choose the source
    if pgrep -f '[i]pc-server=/tmp/mpv-preamp' >/dev/null
        test -n "$input"; and echo '{"command":["script-message","preamp-select","'$input'"]}' \
            | nc -U -w 1 /tmp/mpv-preamp >/dev/null
        return 0
    end

    set -l opts
    test -r $cfg; and set opts (jq -r '.preamp.panel_opts // [] | .[]' $cfg)
    test (count $opts) -eq 0; and set opts --geometry=1816x364
    # Tvheadend, for the tuner's signal (SETUP's address, in presets.json, wins)
    set -l host
    test -r $cfg; and set host (jq -r '.tvheadend.host // ""' $cfg)
    mpv --idle=yes --force-window=yes --osc=no --no-border \
        --macos-app-activation-policy=accessory --title=Preamp \
        --script-opts-append=tvh-host=$host --script-opts-append=preamp-demo=$demo \
        --input-ipc-server=/tmp/mpv-preamp \
        --script-opts-append=preamp-input=$input $opts >/dev/null 2>&1 &
    disown
end
