#!/usr/bin/env bash

# Setup-time bar and dock harmonization (plan D01). Sourced by setup.sh; functions only.
# Uses setup.sh helpers: copy_file_atomic, is_dry_run, print_message, record_warning.

# SHA-256 digests of every Waybar style.css this repository has shipped. A file with one
# of these digests is an unmodified stock copy; any other content belongs to the user.
HSS_STOCK_WAYBAR_STYLE_DIGESTS=(
    114f17cf134a3bcf461e3c3641574feef099481e6a0f165c2c5deec588eef3ed
    2b186ca9cdc15ff57a228d306886d893f476405117751d74c7822bff9588f9e2
    2c4be3a2fe6a0bb25d316eced80a1cb61badef4bd10ea077d11aac3467130b97
    2c7ef5eea7555b5e37824fb5bdcc287d5c24ee14f80e1807dc78bd5cb50618c8
    408c8db7c5eaa558ea554866a727338229010e772a2dd1065882587f57d73438
    441272ca38a0376f2f2eaa16b1b03f806fd6c64cd761f7786e7b345cc3190dc2
    699d6b96db198c233002162c9b58cc3b1b220effeac8f3de0bdd519795147368
    7f676e664221092fff6391d398a531dfa01a6bf4f622cd2f47cec6d534c7b6e9
    975b076bea032ad60c0dfd76177cf17b7fff5ec896bb103e11495b21e1829eb3
    983282bc2c01a2685e087b6eb0a045bfa29b8d6f4048789758758d22f55d6136
    9d5c99d85dc9257594958c729b4dfd8d98bbde196d3f291840639cb546622e39
    bda7f1d5a9ae8c7e9e48d98afd5201179a3eeadc3e715524c852ec2d19668f3f
    debc7068ba86f6c8263d0b3834ecc7bebf4d2268ed41092ae9ea4d31f79964e0
    ec40abf82ab29552759dd743b054e0e3770c7335dc976ec561945c3858250034
)

# panels_waybar_style_is_stock FILE: succeed when FILE is an unmodified earlier stock style.
panels_waybar_style_is_stock() {
    local file=$1 digest known
    [ -f "$file" ] || return 1
    digest=$(sha256sum -- "$file" | cut -d' ' -f1) || return 1
    for known in "${HSS_STOCK_WAYBAR_STYLE_DIGESTS[@]}"; do
        [ "$digest" = "$known" ] && return 0
    done
    return 1
}

# panels_upgrade_stock_waybar_style: replace an unmodified stock Waybar style.css with the
# themed stock style (which carries the hss-theme region and theme color names). Call it
# only when harmonization is adopted (fresh or apply mode), before configure_harmonization
# renders the theme. Customized files are preserved and reported, never rewritten.
panels_upgrade_stock_waybar_style() {
    local source="$SETUP_SCRIPT_ROOT/dotfiles/.config/waybar/style.css" file
    local -a files=("$HOME/dotfiles/.config/waybar/style.css" "$HOME/.config/waybar/style.css")
    [ -r "$source" ] || return 0
    for file in "${files[@]}"; do
        [ -L "$file" ] && [ "$file" != "${files[0]}" ] && continue
        [ -f "$file" ] || continue
        cmp -s -- "$source" "$file" && continue
        if panels_waybar_style_is_stock "$file"; then
            copy_file_atomic "$file" "$source" "Upgrade the stock Waybar style to the themed style" || return 1
        elif ! grep -Fq 'hss-theme:waybar' "$file"; then
            print_message "Keeping customized $file; the Waybar theme region is added only with adoption, and its colors apply to rules that use the @hss_* names."
            record_warning "configure_panels" "Customized Waybar style kept: $(basename -- "$file")"
        fi
    done
}
