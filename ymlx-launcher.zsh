# ymlx — your MLX model manager
# Add this line to ~/.zshrc:
#   source "/path/to/ymlx-launcher.zsh"
# Then reload your shell:  source ~/.zshrc

_YMLX_DIR="${0:A:h}"
# NOTE: do NOT `exec` here. ymlx() is defined in the user's interactive shell,
# so exec would replace that shell with the ymlx process — when ymlx exits the
# terminal window closes with it. Plain fork-and-wait keeps the shell alive.
ymlx() { zsh "$_YMLX_DIR/ymlx.zsh" "$@"; }
