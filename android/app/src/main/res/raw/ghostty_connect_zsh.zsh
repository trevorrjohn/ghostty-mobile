if [[ ! -o interactive || -n ${GHOSTTY_CONNECT_SHELL_INTEGRATION:-} ]]; then
    return
fi

GHOSTTY_CONNECT_SHELL_INTEGRATION=1
typeset -gi _ghostty_connect_command_running=0

autoload -Uz add-zsh-hook

__ghostty_connect_preexec() {
    print -n -- $'\e]133;C\a'
    _ghostty_connect_command_running=1
}

__ghostty_connect_precmd() {
    local command_status=$?
    if (( _ghostty_connect_command_running )); then
        print -n -- $'\e]133;D;'${command_status}$'\a'
        _ghostty_connect_command_running=0
    fi
    print -n -- $'\e]133;A;cl=line\a'
}

add-zsh-hook preexec __ghostty_connect_preexec
add-zsh-hook precmd __ghostty_connect_precmd

PROMPT=$'%{\e]133;P;k=i\a%}'"$PROMPT"$'%{\e]133;B\a%}'
PROMPT2=$'%{\e]133;P;k=s\a%}'"$PROMPT2"$'%{\e]133;B\a%}'
