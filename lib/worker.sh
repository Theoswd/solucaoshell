#!/bin/sh
# worker.sh - Loop de uma conta individual

# CORRECAO (seguranca): a credencial base64 chegava como argv[3] e ficava
# legivel em /proc/PID/cmdline durante toda a vida do worker (que roda para
# sempre). O "unset SLS_ENCODED" nao ajudava: ele limpa a variavel, nao o
# argv do kernel. Agora o play.sh grava a credencial em cript_file (modo 600)
# e o worker recebe apenas o caminho do diretorio da conta.
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

# Rotaciona o log da conta.
#
# CORRECAO: o play.sh redireciona a saida do worker com ">>" e nada limitava
# o crescimento. Com o busy-loop do crono.sh o sls.log chegava a encher o
# armazenamento do aparelho, e o Android passava a matar o processo — o que
# aparentava "bug aleatorio". O busy-loop foi corrigido; isto e a rede de
# protecao para qualquer coisa que volte a gerar log em excesso.
rotate_log() {
    _lg="$SLS_ACC_DIR/sls.log"
    [ -f "$_lg" ] || return 0
    _sz=$(wc -c < "$_lg" 2>/dev/null)
    case "$_sz" in ''|*[!0-9]*) return 0 ;; esac
    if [ "$_sz" -gt 5242880 ]; then
        rm -f "$_lg.1"
        mv "$_lg" "$_lg.1" 2>/dev/null
        : > "$_lg"
    fi
    unset _lg _sz
}

rotate_log
echo "running" > "$SLS_STATUS_FILE"

# SUBSTITUI este processo pelo sls.sh, em vez de ficar parado esperando por
# ele num laco.
#
# CORRECAO (SIGKILL / "signal 9" no Android 12): o worker.sh existia so
# para relancar o sls.sh quando ele saisse — um processo permanente POR
# CONTA que passava a vida bloqueado. Com 6 contas sao 6 processos parados,
# e o Android 12 mata a sessao inteira acima de 32 processos.
#
# Medido no aparelho do relato (Moto E22, Android 12, limite 32): o Termux
# ja marcava 26 processos com apenas DUAS contas no ar. Com seis nao havia
# como caber.
#
# Com o exec o sls.sh herda este PID, entao o arquivo .pid segue valido e o
# stop.sh continua encontrando a conta. Quem relanca agora e o play.sh, que
# ja verifica a cada volta do painel se o PID morreu — antes eram 15s de
# espera aqui, agora sao no maximo 20s la, sem custar um processo parado.
exec sh "$LIBDIR/sls.sh" "$RUN" < /dev/null
