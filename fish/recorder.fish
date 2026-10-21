function recorder --description 'mpv-tvh RC-252 recorder: records the preamp'"'"'s REC OUT source'
    set -l cfg (__tvh_config)              # yours, or the demo's
    pgrep -f '[i]pc-server=/tmp/mpv-recorder' >/dev/null; and return 0

    set -l opts
    set -l folder
    if test -r $cfg
        set opts (yq '.recorder.panel_opts // [] | .[]' $cfg)
        set folder (yq '.recorder.folder // ""' $cfg)
        # default: a recordings folder in the CD player's music folder
        if test -z "$folder"
            set -l lib (yq '.music.library // ""' $cfg)
            test -n "$lib"; and set folder $lib/recordings
        end
    end
    test -z "$folder"; and set folder ~/Music/recordings
    set folder (string replace -r -- '^~' $HOME $folder)
    test (count $opts) -eq 0; and set opts --geometry=1816x182

    mpv --idle=yes --force-window=yes --osc=no --no-border \
        --macos-app-activation-policy=accessory --title=Recorder \
        --input-ipc-server=/tmp/mpv-recorder \
        --script-opts-append=rec-dir=$folder $opts >/dev/null 2>&1 &
    disown
end
