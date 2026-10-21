# Language Settings
set -gx LC_ALL de_CH.UTF-8
set -gx LANG de_CH.UTF-8
set -gx LANGUAGE de_CH:en_US

# Editor and Terminal Settings
set -gx EDITOR nvim
set -gx VISUAL nvim
set -gx TERMINAL kitty
set -gx BROWSER zen-browser
set -gx MANPAGER "nvim +Man!"
set -gx MENU_DMENU "wofi --dmenu"

# PATH settings
# The list below comes first, in this order. Directories inherited from the session or
# login manager, fish_user_paths and other tools that are not listed are kept after it.
set -l hss_path /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin \
  $HOME/go/bin \
  $HOME/.local/bin \
  $HOME/.vscode/extensions \
  $HOME/.fzf/bin \
  /opt/rocm/bin /opt/rocm/hipopen/bin /opt/rocm/opencl/bin \
  /usr/local/sbin /usr/local/bin /usr/lib/jvm/default/bin \
  /usr/bin/site_perl /usr/bin/vendor_perl /usr/bin/core_perl \
  /usr/lib/rustup/bin \
  $HOME/.local/scripts \
  $HOME/.local/share/applications \
  $HOME/.config/hypr/scripts \
  $HOME/.config/waybar/scripts \
  $HOME/.npm-global/bin
for hss_dir in $PATH
    contains -- $hss_dir $hss_path; or set -a hss_path $hss_dir
end
set -x PATH $hss_path
set -e hss_dir


# Make scripts executable
# NOTE: This currently runs `find ... -exec chmod +x` on every interactive shell start.
# That can be expensive and also mutates files as a side effect of launching a shell.
# Consider moving this to setup-time or a one-shot command instead.
set -l SCRIPTS_DIR_EXE \
  $HOME/.local/scripts \
  $HOME/.local/share/applications \
  $HOME/.config/hypr/scripts \
  $HOME/.config/waybar/scripts

if status is-interactive
    if type -q find
        for dir in $SCRIPTS_DIR_EXE
            if test -d $dir
                command find $dir -type f -name '*.sh' -exec chmod +x '{}' ';'
                command find $dir -type f -name '*.desktop' -exec chmod +x '{}' ';'
            end
        end
    end
end

# Python Environment Variables for Certificates
set -gx UV_NATIVE_TLS true
set -gx SSL_CERT_FILE /etc/ssl/certs/ca-certificates.crt
set -gx REQUESTS_CA_BUNDLE $SSL_CERT_FILE
set -x PYTHONHTTPSVERIFY 1

