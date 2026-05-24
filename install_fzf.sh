#!/bin/bash
set -euo pipefail

HISTSIZE=20000
HISTFILESIZE=20000

git clone --depth 1 https://github.com/junegunn/fzf.git /opt/fzf
/opt/fzf/install

cat >> ~/.bashrc <<'EOF'

export HISTSIZE=20000
export HISTFILESIZE=20000
shopt -s histappend
EOF

echo "HISTSIZE/HISTFILESIZE=20000 及 histappend 已写入 ~/.bashrc"