if status is-interactive
    # Commands to run in interactive sessions can go here
end

# Global, not universal: setup and theme changes never write fish_variables.
set -g fish_greeting ""

# FZF configuration
set -gx FZF_CTRL_T_COMMAND '
    find . -maxdepth 1 -type d ! -name ".*" -printf "%P/\n" | sort
    find . -maxdepth 1 -type f ! -name ".*" -printf "%P\n" | sort
    find . -maxdepth 1 -type d -name ".*" ! -name "." ! -name ".." -printf "%P/\n" | sort
    find . -maxdepth 1 -type f -name ".*" -printf "%P\n" | sort
'

# Keybindings
bind \cl 'clear; commandline -f repaint'

# History
set -x fish_history default

# Vim Mode
fish_vi_key_bindings

# Source Starship Prompt when it is installed. Without your own ~/.config/starship.toml
# or STARSHIP_CONFIG, use the repository configuration in ~/starship.toml, whose
# Catppuccin palette follows the desktop theme switch.
if status is-interactive; and type -q starship
    if not set -q STARSHIP_CONFIG; and not test -e ~/.config/starship.toml; and test -r ~/starship.toml
        set -gx STARSHIP_CONFIG ~/starship.toml
    end
    starship init fish | source
end

# Initialize zoxide
if type -q zoxide
    zoxide init fish | source
end

# Syntax and pager colours generated for the current Catppuccin variant. They are set
# after conf.d/fish_frozen_theme.fish, so they take precedence; delete this region to
# keep your own colours.
# >>> hss-theme:fish >>>
if status is-interactive; and test -r ~/.config/hss-theme/generated/fish/theme.fish
    source ~/.config/hss-theme/generated/fish/theme.fish
end
# <<< hss-theme:fish <<<
