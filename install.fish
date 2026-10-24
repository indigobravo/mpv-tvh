#!/usr/bin/env fish
# Link this repo's files into place: fish functions, mpv config and scripts,
# the Hammerspoon module (and load it from your ~/.hammerspoon/init.lua). Any real file that would be replaced is moved to
# ~/mpv-tvh-backup/<timestamp>/ first. Safe to re-run.
#
# Your personal config (~/.config/mpv-tvh/config.json) is not touched.

set repo (cd (dirname (status filename)); and pwd)
set bak ~/mpv-tvh-backup/(date +%Y%m%d-%H%M%S)

function link_into -a bak dir
    mkdir -p $dir
    for src in $argv[3..]
        set dst $dir/(basename $src)
        if test -e $dst; and not test -L $dst
            mkdir -p $bak
            mv $dst $bak/
            echo "backed up  $dst"
        end
        ln -sf $src $dst
        echo "linked     $dst"
    end
end

# Links into this repo whose file has gone (renamed or removed)
for l in ~/.config/fish/functions/* ~/.config/mpv/scripts/* ~/.config/mpv/* ~/.hammerspoon/*
    if test -L $l; and not test -e $l; and string match -q "$repo/*" -- (readlink $l)
        rm $l
        echo "removed    $l (stale link)"
    end
end

link_into $bak ~/.config/fish/functions $repo/fish/*.fish
link_into $bak ~/.config/mpv/scripts    $repo/mpv/scripts/*.lua
link_into $bak ~/.config/mpv            $repo/mpv/input.conf $repo/mpv/mpv.conf
link_into $bak ~/.hammerspoon           $repo/hammerspoon/mpv-tvh.lua

# Hammerspoon: your own ~/.hammerspoon/init.lua loads mpv-tvh.lua. Make
# one if there isn't one (or it's the old link into this repo), or add the
# line to yours
set init ~/.hammerspoon/init.lua
if not test -e $init; or begin; test -L $init; and string match -q "$repo/*" -- (readlink $init); end
    rm -f $init
    printf '%s\n' '-- Your Hammerspoon config. mpv-tvh adds its pad handling with:' 'require("mpv-tvh")' > $init
    echo "created    $init"
else if not grep -q 'mpv-tvh' $init                     # (already loads it, or says why not)
    printf '\n%s\n' 'require("mpv-tvh")   -- mpv-tvh: the macro pad (added by its install.fish)' >> $init
    echo "added      require(\"mpv-tvh\") to $init"
end

if test -d $bak
    echo
    echo "Originals saved in $bak"
end
if test -e ~/.config/mpv-tvh/config.yml; and not test -e ~/.config/mpv-tvh/config.json
    echo
    echo "Your config.yml is no longer read: convert it to config.json with"
    echo "  yq -o=json ~/.config/mpv-tvh/config.yml > ~/.config/mpv-tvh/config.json"
else if not test -e ~/.config/mpv-tvh/config.json; and not test -e ~/.config/mpv-tvh/presets.json
    echo
    echo "Switch it on with: preamp"
    echo "It asks where your Tvheadend server is (or press DEMO to try it first)."
end
