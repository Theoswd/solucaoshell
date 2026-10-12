#!/bin/sh
# worker.sh - Loop de uma conta individual

# Seguranca: a credencial nunca vai no argv (legivel em /proc/PID/cmdline);
# o play.sh grava em cript_file (modo 600) e o worker recebe so a pasta.
SLS_SRV="$1"
SLS_USER="$2"
SLS_TAG="$3"
SLS_URL="$4"
SLS_ACC_DIR="$5"
SLS_STATUS_FILE="$6"
RUN="${7:--boot}"

if [ -z "$SLS_SRV" ] || [ -z "$SLS_URL" ] || [ -z "$SLS_ACC_DIR" ] || [ -z "$SLS_STATUS_FILE" ]; then
    printf "ERRO: worker.sh deve ser chamado pelo play.sh\n"
    exit 1
fi

export SLS_SRV SLS_USER SLS_TAG SLS_URL SLS_ACC_DIR SLS_STATUS_FILE

umask 077

_dir=$(dirname "$0")
# Este script vive em lib/: a raiz do bot e o diretorio de cima.
LIBDIR=$(cd "$_dir" && pwd)
SLSDIR=$(cd "$LIBDIR/.." && pwd)
export LIBDIR
unset _dir
export SLSDIR

PID_FILE="${SLS_STATUS_FILE%.status}.pid"

echo "$$" > "$PID_FILE"
echo "starting" > "$SLS_STATUS_FILE"

termux-wake-lock 2>/dev/null

printf "[%s] %s — worker PID=%s\n" "$SLS_TAG" "$SLS_USER" "$$"

mkdir -p "$SLS_ACC_DIR"
chmod 700 "$SLS_ACC_DIR" 2>/dev/null

if [ ! -s "$SLS_ACC_DIR/cript_file" ]; then
    printf "[%s] %s — ERRO: cript_file ausente. Rode ./setup.sh\n" "$SLS_TAG" "$SLS_USER"
    echo "dead" > "$SLS_STATUS_FILE"
    exit 1
fi
chmod 600 "$SLS_ACC_DIR/cript_file" 2>/dev/null

echo "running" > "$SLS_STATUS_FILE"

# SUBSTITUI este processo pelo sls.sh (exec), sem ficar parado esperando:
# o Android 12 mata a sessao inteira acima de ~32 processos, e um processo
# parado POR CONTA nao cabe. O sls.sh herda este PID (o .pid segue valido
# para o stop.sh); quem relanca e o play.sh, que confere o PID a cada volta
# do painel. A pasta da conta vai no cmdline so para o worker_vivo
# (contas.sh); o sls.sh nao le o $2.
exec sh "$LIBDIR/sls.sh" "$RUN" "$SLS_ACC_DIR" < /dev/null
