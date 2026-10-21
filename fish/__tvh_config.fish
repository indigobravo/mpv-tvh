function __tvh_config --description 'mpv-tvh: the config file to use (prints its path; status 1 = the demo)'
    # Yours: ~/.config/mpv-tvh/config.yml, or the file $MPV_TVH_CONFIG names
    set -l cfg ~/.config/mpv-tvh/config.yml
    set -q MPV_TVH_CONFIG; and set cfg $MPV_TVH_CONFIG
    if test -r $cfg
        echo $cfg
        return 0
    end
    # None: once SETUP has saved a Tvheadend address (presets.json), the
    # defaults (examples/defaults.yml: the layout, no channels; the presets
    # are the channels); before that, the demo (examples/demo.yml: test
    # cards for TV, internet radio, and everything else as usual)
    set -l here (realpath (status filename) 2>/dev/null; or echo (status filename))
    set -l examples (dirname (dirname $here))/examples
    set -l presets ~/.config/mpv-tvh/presets.json
    if test -r $presets; and command -q jq
        set -l host (jq -r '.host // ""' $presets 2>/dev/null)
        if test -n "$host"
            echo $examples/defaults.yml
            return 0
        end
    end
    echo $examples/demo.yml
    return 1
end
