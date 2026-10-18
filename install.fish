#!/usr/bin/env fish
# Link this repo's files into place: fish functions, mpv config and scripts,
# Hammerspoon config. Any real file that would be replaced is moved to
# ~/mpv-tvh-backup/<timestamp>/ first. Safe to re-run.
#
# Your personal config (~/.config/mpv-tvh/config.yml) is not touched.

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

link_into $bak ~/.config/fish/functions $repo/fish/*.fish
link_into $bak ~/.config/mpv/scripts    $repo/mpv/scripts/*.lua
link_into $bak ~/.config/mpv            $repo/mpv/input.conf $repo/mpv/mpv.conf
link_into $bak ~/.hammerspoon           $repo/hammerspoon/init.lua

if test -d $bak
    echo
    echo "Originals saved in $bak"
end
if not test -e ~/.config/mpv-tvh/config.yml
    echo
    echo "No config yet. Create one with:"
    echo "  mkdir -p ~/.config/mpv-tvh; and cp $repo/examples/config.yml ~/.config/mpv-tvh/config.yml"
end
