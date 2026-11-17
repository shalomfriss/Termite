typeset _terminal_tabs_integration_zdotdir="${TERMINAL_TABS_INTEGRATION_ZDOTDIR:-${ZDOTDIR}}"
typeset _terminal_tabs_original_zdotdir="${TERMINAL_TABS_ORIGINAL_ZDOTDIR:-${HOME}}"
ZDOTDIR="${_terminal_tabs_original_zdotdir}"
if [[ -r "${ZDOTDIR}/.zshrc" ]]; then
    source "${ZDOTDIR}/.zshrc"
fi
ZDOTDIR="${_terminal_tabs_integration_zdotdir}"
unset _terminal_tabs_integration_zdotdir _terminal_tabs_original_zdotdir

autoload -Uz vcs_info
zstyle ':vcs_info:git:*' formats ' [%b]'
if (( ${precmd_functions[(Ie)vcs_info]} == 0 )); then
    precmd_functions+=(vcs_info)
fi
setopt prompt_subst
PROMPT='%n@%m %~${vcs_info_msg_0_} %# '
