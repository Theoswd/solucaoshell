#!/bin/sh
# stop.sh - Para todos os workers do solucaoshell

# Caminho real, seguindo links simbolicos (como o play.sh): chamado por um
# atalho, o SLSDIR seria a pasta do atalho e as redes de seguranca abaixo
# (pkill pelo caminho do lib/, play.sh desta pasta) nao achariam nada.
_self="$0"
_hops=0
while [ -L "$_self" ] && [ "$_hops" -lt 20 ]; do
    _link=$(readlink "$_self")
    case "$_link" in
        /*) _self="$_link" ;;
        *)  _self="$(dirname "$_self")/$_link" ;;
    esac
    _hops=$((_hops + 1))
done
_dir=`dirname "$_self"`
SLSDIR=`cd "$_dir" && pwd -P`
unset _self _link _hops

# Comandos do usuario na raiz; o motor (worker, painel, batalhas) em lib/.
LIBDIR="$SLSDIR/lib"
export LIBDIR

unset _dir

STATUS_DIR="$HOME/.sls/status"

GREEN='\033[32m'
GOLD='\033[0;33m'
RESET='\033[00m'

printf "${GOLD}Parando todos os workers do solucaoshell...${RESET}\n\n"

# E O play.sh (ou status.sh) DESTE BOT?   script_do_bot PID NOME
# O shell rodando o script: argv[0] e o sh e argv[1] o caminho do NOME, que
# resolvido (relativo ao cwd do processo) cai nesta pasta. Um "nano play.sh"
# ou "less status.sh" aberto aqui nao e: antes o pgrep -f + o cwd os matavam
# (o play.sh ate com KILL), e um play.sh lancado de outra pasta escapava.
script_do_bot() {
    [ -r "/proc/$1/cmdline" ] || return 1
    _sb_a0=""; _sb_a1=""
    { IFS= read -r _sb_a0; IFS= read -r _sb_a1; } <<EOF_SB
$(tr '\0' '\n' < "/proc/$1/cmdline" 2>/dev/null)
EOF_SB
    case "${_sb_a0##*/}" in sh|-sh|bash|dash|ash|busybox) ;; *) return 1 ;; esac
    case "$_sb_a1" in "$2"|*/"$2") ;; *) return 1 ;; esac
    case "$_sb_a1" in
        /*)  _sb_d="${_sb_a1%/*}" ;;
        */*) _sb_d="$(readlink "/proc/$1/cwd" 2>/dev/null)/${_sb_a1%/*}" ;;
        *)   _sb_d="$(readlink "/proc/$1/cwd" 2>/dev/null)" ;;
    esac
    _sb_d=$(cd "$_sb_d" 2>/dev/null && pwd -P)
    [ -n "$_sb_d" ] && [ "$_sb_d" = "$SLSDIR" ]
}

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

# Rede de seguranca: qualquer play.sh DESTE bot (script_do_bot), nao um de
# outro projeto nem um editor aberto no arquivo.
for p in $(pgrep -f "play\.sh" 2>/dev/null); do
    [ "$p" = "$$" ] && continue
    script_do_bot "$p" play.sh || continue
    kill -TERM "$p" 2>/dev/null
done

# Da ao supervisor um instante para sair antes de derrubar os workers; sem
# isso ele poderia relancar um ultimo worker entre o TERM e a sua saida.
sleep 1

# Confirma que o supervisor morreu (KILL) antes de prosseguir: enquanto ele
# viver, qualquer worker morto sera relancado.
for p in $(pgrep -f "play\.sh" 2>/dev/null); do
    [ "$p" = "$$" ] && continue
    script_do_bot "$p" play.sh && kill -KILL "$p" 2>/dev/null
done

stopped=0
termos=""

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
        # A espera e UMA SO, depois do laco (eram 2s fixos por conta, em
        # serie: 10 contas, 20s).
        kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
        termos="$termos $pid"
        echo "stopped" > "$STATUS_DIR/${acc_id}.status"
        printf "  ${GREEN}[OK]${RESET} %s (PID %s)\n" "$acc_id" "$pid"
        stopped=$((stopped + 1))
    else
        echo "stopped" > "$STATUS_DIR/${acc_id}.status"
        printf "  ${GOLD}[JA PARADO]${RESET} %s\n" "$acc_id"
    fi

    rm -f "$pid_file"
done

# Ate 2s para todos sairem juntos, saindo assim que o ultimo terminar; quem
# sobrar leva KILL no grupo.
_n=0
while [ -n "$termos" ] && [ "$_n" -lt 10 ]; do
    _vivos=""
    for pid in $termos; do kill -0 "$pid" 2>/dev/null && _vivos="$_vivos $pid"; done
    termos="$_vivos"
    [ -n "$termos" ] || break
    sleep 0.2
    _n=$((_n + 1))
done
for pid in $termos; do
    kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
done
unset _n _vivos termos

# Painel aberto tambem para: o ./status.sh le o panel.sh uma vez so e, de pe
# durante um "stop + git pull + play", mostraria o layout antigo. E somente
# leitura; so alcanca o que roda a partir DESTE diretorio.
for p in $(pgrep -f "status\.sh" 2>/dev/null); do
    [ "$p" = "$$" ] && continue
    script_do_bot "$p" status.sh || continue
    kill -TERM "$p" 2>/dev/null
done

# Rede de seguranca para orfaos de execucoes antigas (antes do setsid).
pkill -f "$LIBDIR/sls.sh" 2>/dev/null
pkill -f "$LIBDIR/worker.sh" 2>/dev/null

# Trava global de login: um worker morto segurando-a a deixa para tras, e
# com o PID reciclado ela so cairia no teto de 180s. Tudo ja foi encerrado,
# entao remove-la aqui e seguro.
rm -rf "$HOME/.sls/.login.lock" 2>/dev/null
# Disjuntor (info.sh): sonda presa e estado da sessao que acabou; a proxima
# subida volta a medir do zero.
rm -rf "$HOME/.sls/net" 2>/dev/null

printf "\n${GREEN}%s worker(s) encerrado(s).${RESET}\n" "$stopped"
# "|| :" : fora do Termux o comando nao existe, e o 127 pararia o
# "./stop.sh && git pull && ./play.sh" do README.
termux-wake-unlock 2>/dev/null || :
