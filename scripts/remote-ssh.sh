#!/usr/bin/env bash
# Wrapper SSH para UNO Q. Requiere SSHPASS exportada en el shell del caller.
# Uso:
#   scripts/remote-ssh.sh 'comando remoto'
#   echo 'script multi-linea' | scripts/remote-ssh.sh

set -euo pipefail

if [[ -z "${SSHPASS:-}" ]]; then
  echo "ERROR: export SSHPASS='<password>' antes de usar este wrapper." >&2
  exit 2
fi

if ! command -v sshpass >/dev/null; then
  echo "ERROR: 'sshpass' no instalado (sudo apt-get install sshpass)." >&2
  exit 2
fi

HOST="arduino@192.168.0.105"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"

if [[ $# -gt 0 ]]; then
  # comando como argumento
  sshpass -e ssh $SSH_OPTS "$HOST" "$@"
else
  # comando vía stdin
  sshpass -e ssh $SSH_OPTS "$HOST" bash -s
fi
