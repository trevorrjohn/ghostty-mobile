if [[ $- != *i* ]] || [[ -n ${GHOSTTY_CONNECT_SHELL_INTEGRATION:-} ]]; then
    return
fi

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    printf '%s\n' 'Ghostty Connect shell integration requires Bash 4.4 or newer.' >&2
    return
fi

GHOSTTY_CONNECT_SHELL_INTEGRATION=1

__ghostty_connect_precmd() {
    local command_status=$?
    printf '\e]133;D;%s\a\e]133;A;cl=line\a' "$command_status"
    return "$command_status"
}

# PS0 is rendered after a command is read but before it executes.
PS0=$'\e]133;C\a'"${PS0:-}"
PS1=$'\[\e]133;P;k=i\a\]'"$PS1"$'\[\e]133;B\a\]'
PS2=$'\[\e]133;P;k=s\a\]'"$PS2"$'\[\e]133;B\a\]'

if [[ -z ${PROMPT_COMMAND:-} ]]; then
    PROMPT_COMMAND=__ghostty_connect_precmd
elif [[ $(declare -p PROMPT_COMMAND 2>/dev/null) == 'declare -a '* ]]; then
    PROMPT_COMMAND=(__ghostty_connect_precmd "${PROMPT_COMMAND[@]}")
else
    PROMPT_COMMAND="__ghostty_connect_precmd;${PROMPT_COMMAND}"
fi
