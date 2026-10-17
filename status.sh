#!/bin/sh
# status.sh - Painel do solucaoshell, SOMENTE LEITURA
#
# Mostra as contas sem tocar em nenhum processo: nao sobe, nao mata e nao
# relanca worker; sair com ctrl+c nao para conta nenhuma. Serve para rever
# os workers que sobreviveram ao fechamento do Termux sem rodar o play.sh.
#
# Uso:
#   ./status.sh            painel continuo
#   ./status.sh -1         imprime uma vez e sai (bom para script)
#   ./status.sh -n 5       atualiza a cada 5 segundos
#   ./status.sh -cols      regua de calibracao da largura (tela do celular)
#   ./status.sh -icones    escolhe emoji, simbolo ou texto olhando a tela

umask 077

# Resolve o caminho real do script, seguindo links simbolicos.
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
_dir=$(dirname "$_self")
SLSDIR=$(cd "$_dir" && pwd -P)

# Comandos do usuario na raiz; o motor (worker, painel, batalhas) em lib/.
LIBDIR="$SLSDIR/lib"
export LIBDIR

unset _dir _self _link _hops
export SLSDIR

STATUS_DIR="$HOME/.sls/status"

PANEL_ONCE=0
PANEL_COLS_INFO=0
PANEL_ICONS_INFO=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        -1|--once) PANEL_ONCE=1 ;;
        -n)        shift; PANEL_INTERVAL="$1" ;;
        -cols|--cols|-dpi|--dpi) PANEL_COLS_INFO=1 ;;
        -icones|--icones|-emoji|--emoji) PANEL_ICONS_INFO=1 ;;
        # Resumo das ultimas batalhas (lib/batalhas.sh): so le os logs.
        -batalhas|--batalhas) shift; exec sh "$LIBDIR/batalhas.sh" "$@" ;;
        # Telemetria das requisicoes (lib/rede.sh): so le os req.stat.
        -rede|--rede) shift; exec sh "$LIBDIR/rede.sh" "$@" ;;
        -h|--help)
            printf "uso: ./status.sh [-1] [-n SEGUNDOS] [-cols] [-icones] [-batalhas [EVENTO] [CONTA]] [-rede [MIN]]\n"
            printf "  -1        imprime uma vez e sai\n"
            printf "  -n SEG    intervalo de atualizacao (padrao 5; 10 no Termux)\n"
            printf "  -cols     regua de calibracao da largura da tela\n"
            printf "  -icones   desenha os tres conjuntos de icones, para escolher\n"
            printf "  -batalhas ultima batalha de cada evento por conta (EVENTO: Rei, Vale,\n"
            printf "            Altares, Torneio, Duelo, ColiseuCla, Bandeiras, Equipe, Coliseu)\n"
            printf "  -rede     requisicoes por conta nos ultimos MIN minutos (padrao 10):\n"
            printf "            req/min, tempo medio, P95, sem resposta e HTTP 5xx\n"
            exit 0
            ;;
    esac
    shift
done
# Padrao 5s: o painel so LE arquivos que os workers gravam a cada requisicao,
# entao atualizar rapido nao custa nada as contas. Ajustavel com -n.
case "${PANEL_INTERVAL:-5}" in ''|*[!0-9]*) PANEL_INTERVAL=5 ;; esac
export PANEL_INTERVAL

. "$LIBDIR/contas.sh"

# Calibracao nao depende de conta nem de worker no ar: roda antes das checagens.
if [ "$PANEL_COLS_INFO" = 1 ] || [ "$PANEL_ICONS_INFO" = 1 ]; then
    PANEL_SUPERVISE=0
    . "$LIBDIR/panel.sh"
    [ "$PANEL_COLS_INFO" = 1 ]  && painel_calibrar
    [ "$PANEL_ICONS_INFO" = 1 ] && painel_icones
    exit 0
fi

ACCOUNTS_FILE=$(resolve_accounts_file)

if [ ! -s "$ACCOUNTS_FILE" ]; then
    printf "Nenhuma conta cadastrada em:\n%s\n" "$ACCOUNTS_FILE"
    printf "Execute: ./setup.sh\n"
    exit 1
fi

if [ ! -d "$STATUS_DIR" ]; then
    printf "As contas nunca foram iniciadas aqui.\n"
    printf "(%s nao existe)\n" "$STATUS_DIR"
    printf "Execute: ./play.sh\n"
    exit 1
fi

# Somente leitura: o panel.sh nao relanca nada com PANEL_SUPERVISE=0.
PANEL_SUPERVISE=0
. "$LIBDIR/panel.sh"

# Sem terminal (arquivo, pipe) o painel continuo nao imprime: so uma volta.
if [ "$HAS_TTY" = 0 ]; then
    PANEL_ONCE=1
    PANEL_DRAW=1
fi
export PANEL_ONCE PANEL_DRAW

painel_loop
