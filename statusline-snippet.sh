# Add this to your Claude Code statusline script (the one set as statusLine.command in
# ~/.claude/settings.json). It shares what the statusline already knows with the Touch Bar app.
#
# Expects:  $input    the JSON Claude Code passes on stdin   (input=$(cat))
# Optional: $git_branch, $git_dirty, $pct_used, and the rate-limit variables below.

tb_session_id=$(echo "$input" | jq -r '.session_id // empty')
if [ -n "$tb_session_id" ]; then
    mkdir -p "$HOME/.claude/cache/touchbar"
    echo "$input" | jq -c --arg branch "${git_branch:-}${git_dirty:-}" \
        --argjson ctx "${pct_used:-$(echo "$input" | jq -r '.context_window.used_percentage // 0')}" \
        '. + {tb_branch: $branch, tb_ctx_pct: $ctx}' \
        > "$HOME/.claude/cache/touchbar/$tb_session_id.json" 2>/dev/null
fi

five_hour_pct=${five_hour_pct:-$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty' | awk '{printf "%.0f", $1}')}
if [ -n "$five_hour_pct" ]; then
    five_hour_reset_epoch=${five_hour_reset_epoch:-$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // 0')}
    seven_day_pct=${seven_day_pct:-$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // 0' | awk '{printf "%.0f", $1}')}
    seven_day_reset_epoch=${seven_day_reset_epoch:-$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // 0')}
    mkdir -p "$HOME/.claude/cache"
    printf '{"five_pct":%s,"five_reset":%s,"week_pct":%s,"week_reset":%s,"updated":%s}\n' \
        "${five_hour_pct:-0}" "${five_hour_reset_epoch:-0}" "${seven_day_pct:-0}" "${seven_day_reset_epoch:-0}" "$(date +%s)" \
        > "$HOME/.claude/cache/usage-latest.json" 2>/dev/null
fi
