#!/bin/sh
# stop.sh - Para todos os workers do solucaoshell

_dir=`dirname "$0"`
SLSDIR=`cd "$_dir" && pwd`

# Comandos do usuario na raiz; o motor (worker, painel, batalhas) em lib/.
LIBDIR="$SLSDIR/lib"
export LIBDIR

unset _dir

STATUS_DIR="$HOME/.sls/status"

GREEN='\033[32m'
GOLD='\033[0;33m'
RESET='\033[00m'

printf "${GOLD}Parando todos os workers do solucaoshell...${RESET}\n\n"

# ============================================================
#  O ORQUESTRADOR MORRE PRIMEIRO: o play.sh supervisiona e RELANCA
#  worker morto; vivo durante o laco abaixo, relancaria um worker
#  com PID novo que sobreviveria ao stop.
# ============================================================
orch_pid=$(cat "$STATUS_DIR/orchestrator.pid" 2>/dev/null)
case "$orch_pid" in
    ""|*[!0-9]*) ;;
    # So se ainda for um play.sh: sem trap, o .pid fica para tras e o PID
    # pode ter sido reciclado para outro processo do usuario.
    *) grep -q 'play\.sh' "/proc/$orch_pid/cmdline" 2>/dev/null && kill -TERM "$orch_pid" 2>/dev/null ;;
esac
rm -f "$STATUS_DIR/orchestrator.pid"

# Rede de seguranca: qualquer play.sh cujo diretorio de trabalho seja o do
# bot. Comparar o cwd evita acertar um play.sh de outro projeto.
for p in $(pgrep -f "play\.sh" 2>/dev/null); do
    [ "$p" = "$$" ] && continue
    _cwd=$(readlink -f "/proc/$p/cwd" 2>/dev/null)
    [ "$_cwd" = "$SLSDIR" ] || continue
    kill -TERM "$p" 2>/dev/null
done

# Da ao supervisor um instante para sair antes de derrubar os workers; sem
# isso ele poderia relancar um ultimo worker entre o TERM e a sua saida.
sleep 1

# Confirma que o supervisor morreu (KILL) antes de prosseguir: enquanto ele
# viver, qualquer worker morto sera relancado.
for p in $(pgrep -f "play\.sh" 2>/dev/null); do
    [ "$p" = "$$" ] && continue
    _cwd=$(readlink -f "/proc/$p/cwd" 2>/dev/null)
    [ "$_cwd" = "$SLSDIR" ] && kill -KILL "$p" 2>/dev/null
done

stopped=0

for pid_file in "$STATUS_DIR"/*.pid; do
    [ -f "$pid_file" ] || continue

    acc_id=`basename "$pid_file" .pid`
    # orchestrator.pid e do proprio play.sh, nao de uma conta.
    [ "$acc_id" = "orchestrator" ] && continue
    pid=`cat "$pid_file" 2>/dev/null`

    case "$pid" in
        ''|*[!0-9]*)
            printf "  ${GOLD}[PID INVALIDO]${RESET} %s\n" "$acc_id"
            rm -f "$pid_file"
            continue
            ;;
    esac

    # Confere o cmdline antes de sinalizar: kill -0 ve existencia, nao
    # identidade (PID reciclado pelo kernel).
    ours=0
    if [ -r "/proc/$pid/cmdline" ]; then
        tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null \
            | grep -qE 'worker\.sh|sls\.sh' && ours=1
    elif kill -0 "$pid" 2>/dev/null; then
        ours=1
    fi

    if [ "$ours" -eq 1 ]; then
        # Sinaliza o GRUPO (worker lancado com setsid): alcanca tambem o
        # sls.sh filho, que senao seguiria orfao com a sessao do jogo ativa.
        kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
        sleep 2
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
        fi
        echo "stopped" > "$STATUS_DIR/${acc_id}.status"
        printf "  ${GREEN}[OK]${RESET} %s (PID %s)\n" "$acc_id" "$pid"
        stopped=$((stopped + 1))
    else
        echo "stopped" > "$STATUS_DIR/${acc_id}.status"
        printf "  ${GOLD}[JA PARADO]${RESET} %s\n" "$acc_id"
    fi

    rm -f "$pid_file"
done

# Painel aberto tambem para: o ./status.sh le o panel.sh uma vez so e, de pe
# durante um "stop + git pull + play", mostraria o layout antigo. E somente
# leitura; so alcanca o que roda a partir DESTE diretorio.
for p in $(pgrep -f "status\.sh" 2>/dev/null); do
    [ "$p" = "$$" ] && continue
    _cwd=$(readlink -f "/proc/$p/cwd" 2>/dev/null)
    [ "$_cwd" = "$SLSDIR" ] || continue
    kill -TERM "$p" 2>/dev/null
done

# Rede de seguranca para orfaos de execucoes antigas (antes do setsid).
pkill -f "$LIBDIR/sls.sh" 2>/dev/null
pkill -f "$LIBDIR/worker.sh" 2>/dev/null

# Trava global de login: um worker morto segurando-a a deixa para tras, e
# com o PID reciclado ela so cairia no teto de 180s. Tudo ja foi encerrado,
# entao remove-la aqui e seguro.
rm -rf "$HOME/.sls/.login.lock" 2>/dev/null

printf "\n${GREEN}%s worker(s) encerrado(s).${RESET}\n" "$stopped"
# "|| :" : fora do Termux o comando nao existe, e o 127 pararia o
# "./stop.sh && git pull && ./play.sh" do README.
termux-wake-unlock 2>/dev/null || :
