typeset _terminal_tabs_integration_zdotdir="${TERMINAL_TABS_INTEGRATION_ZDOTDIR:-${ZDOTDIR}}"
typeset _terminal_tabs_original_zdotdir="${TERMINAL_TABS_ORIGINAL_ZDOTDIR:-${HOME}}"
ZDOTDIR="${_terminal_tabs_original_zdotdir}"
if [[ -r "${ZDOTDIR}/.zlogin" ]]; then
    source "${ZDOTDIR}/.zlogin"
fi
ZDOTDIR="${_terminal_tabs_integration_zdotdir}"
unset _terminal_tabs_integration_zdotdir _terminal_tabs_original_zdotdir
