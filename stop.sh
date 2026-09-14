#!/bin/sh
# stop.sh - Para todos os workers do solucaoshell

_dir=`dirname "$0"`
SLSDIR=`cd "$_dir" && pwd`

# O motor mora em lib/. Os comandos do usuario ficam na raiz; tudo que e
# biblioteca (worker, painel, modulos de batalha) e carregado daqui.
LIBDIR="$SLSDIR/lib"
export LIBDIR

unset _dir

STATUS_DIR="$HOME/.sls/status"

GREEN='\033[32m'
RED='\033[0;31m'
GOLD='\033[0;33m'
RESET='\033[00m'

printf "${GOLD}Parando todos os workers do solucaoshell...${RESET}\n\n"

# ============================================================
#  O ORQUESTRADOR MORRE PRIMEIRO — SENAO ELE RELANCA O QUE MATAMOS.
#
#  O play.sh roda como supervisor (painel_loop com PANEL_SUPERVISE=1) e
#  RELANCA qualquer worker cujo PID tenha morrido. Se matassemos os workers
#  antes, o supervisor — ainda vivo durante todo o laco de encerramento —
#  relancaria no meio do caminho um worker ja derrubado: ele ganharia um PID
#  NOVO, o kill deste script (que guarda o PID ANTIGO) erraria, o "rm do .pid"
#  o deixaria orfao, e o worker seguiria rodando apos o stop — exatamente o
#  sintoma de "mandei parar e continua rodando".
#
#  Matando o supervisor ANTES, nenhum relance acontece durante o restante do
#  encerramento, e o worker realmente termina.
# ============================================================
orch_pid=$(cat "$STATUS_DIR/orchestrator.pid" 2>/dev/null)
case "$orch_pid" in
    ""|*[!0-9]*) ;;
    *) kill -TERM "$orch_pid" 2>/dev/null ;;
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
    # orchestrator.pid e o PID do proprio play.sh, nao de uma conta:
    # sem isto ele virava uma linha "orchestrator  stopped" no painel.
    [ "$acc_id" = "orchestrator" ] && continue
    pid=`cat "$pid_file" 2>/dev/null`

    case "$pid" in
        ''|*[!0-9]*)
            printf "  ${GOLD}[PID INVALIDO]${RESET} %s\n" "$acc_id"
            rm -f "$pid_file"
            continue
            ;;
    esac

    # CORRECAO: antes bastava "kill -0 $pid" para disparar o kill. O kill -0
    # verifica EXISTENCIA, nao IDENTIDADE — com o PID reciclado pelo kernel,
    # o kill -9 acertava um processo inocente do usuario. Agora confere o
    # cmdline antes de sinalizar.
    ours=0
    if [ -r "/proc/$pid/cmdline" ]; then
        tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null \
            | grep -qE 'worker\.sh|sls\.sh' && ours=1
    elif kill -0 "$pid" 2>/dev/null; then
        ours=1
    fi

    if [ "$ours" -eq 1 ]; then
        # Sinaliza o GRUPO de processos: o worker foi lancado com setsid,
        # entao isso alcanca tambem o sls.sh filho. Antes so o pai morria e
        # o filho continuava rodando orfao, mantendo a sessao do jogo ativa.
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

# O orquestrador (play.sh) ja foi encerrado no inicio deste script, antes do
# laco de workers, para nao relancar nada durante o encerramento.

# PAINEL ABERTO TAMBEM PARA AQUI.
#
# O ./status.sh le o panel.sh uma unica vez, quando sobe, e fica desenhando
# para sempre. Deixado de pe durante um "stop + git pull + play", ele
# continua mostrando o layout ANTIGO — e a atualizacao parece nao ter
# funcionado. E o caso classico do WSL, onde o README recomenda tmux e o
# painel fica num painel do tmux que sobrevive a tudo.
#
# Encerrar nao custa nada: o status.sh e somente leitura, nao toca em conta
# nenhuma. Igual a rede de seguranca do play.sh acima, so alcanca o que roda
# a partir DESTE diretorio.
for p in $(pgrep -f "status\.sh" 2>/dev/null); do
    [ "$p" = "$$" ] && continue
    _cwd=$(readlink -f "/proc/$p/cwd" 2>/dev/null)
    [ "$_cwd" = "$SLSDIR" ] || continue
    kill -TERM "$p" 2>/dev/null
done

# Rede de seguranca para orfaos de execucoes antigas (antes do setsid).
pkill -f "$LIBDIR/sls.sh" 2>/dev/null
pkill -f "$LIBDIR/worker.sh" 2>/dev/null

# TRAVA GLOBAL DE LOGIN — libera para o proximo ./play.sh.
#
# O login e serializado por uma trava atomica ($HOME/.sls/.login.lock). Se um
# worker foi morto enquanto a segurava, o diretorio da trava fica para tras.
# No proximo arranque, os novos workers so a liberam se o PID gravado estiver
# morto — mas esse PID pode ter sido RECICLADO pelo kernel para um processo
# vivo, e ai a trava so cai depois do teto de 180s, atrasando o login de todas
# as contas. Como aqui tudo ja foi encerrado, remove-la e sempre seguro e
# garante um restart (e um git pull) limpo.
rm -rf "$HOME/.sls/.login.lock" 2>/dev/null

printf "\n${GREEN}%s worker(s) encerrado(s).${RESET}\n" "$stopped"
termux-wake-unlock 2>/dev/null
