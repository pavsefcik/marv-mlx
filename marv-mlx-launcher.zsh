# marv-mlx — your MLX model manager
# Add this line to ~/.zshrc:
#   source "/path/to/marv-mlx-launcher.zsh"
# Then reload your shell:  source ~/.zshrc

_MARV_MLX_DIR="${0:A:h}"
# NOTE: do NOT `exec` here. marv-mlx() is defined in the user's interactive shell,
# so exec would replace that shell with the marv-mlx process — when marv-mlx exits the
# terminal window closes with it. Plain fork-and-wait keeps the shell alive.
marv-mlx() { zsh "$_MARV_MLX_DIR/marv-mlx.zsh" "$@"; }
