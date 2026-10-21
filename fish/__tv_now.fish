function __tv_now --description 'Print now/next grid for tv channels (internal)'
    # Arguments: host, then N names, then N sources (Tvheadend UUIDs or stream URLs)
    set -l host $argv[1]
    set -l half (math (count $argv) - 1)
    set -l names $argv[2..(math 1 + $half / 2)]
    set -l srcs $argv[(math 2 + $half / 2)..-1]

    printf "\n  %-15s  %-12s  %s\n" "channel" "when" "programme"
    printf "  %-15s  %-12s  %s\n" "───────────────" "────────────" "──────────────────────────────────"

    for i in (test (count $names) -gt 0; and seq (count $names))
        set -l name $names[$i]
        set -l src $srcs[$i]

        if string match -q 'http*' -- $src
            printf "  %-15s  %-12s  %s\n\n" $name "—" "(internet stream, no guide)"
            continue
        end

        set -l json (curl -sS --max-time 3 \
            "http://$host/api/epg/events/grid?limit=2&channel=$src" 2>/dev/null)

        if test -z "$json"
            printf "  %-15s  %s\n" $name "(no response)"
            continue
        end

        # NOW
        set -l now_title (echo $json | jq -r '.entries[0].title // "(untitled)"')
        set -l now_stop  (echo $json | jq -r '.entries[0].stop // empty')

        if test -n "$now_stop"
            set -l ends (date -j -f %s $now_stop +%H:%M 2>/dev/null)
            printf "  \033[1m%-15s\033[0m  ends %s     %s\n" $name $ends $now_title
        else
            printf "  %-15s  %-12s  %s\n" $name "—" "(no data)"
        end

        # NEXT
        set -l next_title (echo $json | jq -r '.entries[1].title // "(untitled)"')
        set -l next_start (echo $json | jq -r '.entries[1].start // empty')

        if test -n "$next_start"
            set -l starts (date -j -f %s $next_start +%H:%M 2>/dev/null)
            printf "  %-15s  from %s    %s\n" "" $starts $next_title
        end

        echo
    end
end
