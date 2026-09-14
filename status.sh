#!/bin/sh
# status.sh - Painel do solucaoshell, SOMENTE LEITURA
#
# Mostra as contas sem tocar em nenhum processo: nao sobe, nao mata e nao
# relanca worker. Pode ser aberto e fechado a vontade, e sair com ctrl+c nao
# para conta nenhuma.
#
# POR QUE ESTE ARQUIVO EXISTE
#
# O painel morava dentro do play.sh, no mesmo processo que lanca e supervisiona
# os workers. Os workers sobem com nohup+setsid, entao eles SOBREVIVEM quando o
# Termux e fechado ou morto pelo Android (SIGKILL / "signal 9") — mas o painel
# morre junto com o play.sh. As contas continuavam jogando e ficavam invisiveis.
#
# E para rever o painel a unica saida era rodar ./play.sh de novo, que derrubava
# as contas boas e disparava 6 logins simultaneos do mesmo IP — recusados pelo
# servidor, jogando todas no backoff. O ato de olhar quebrava o que funcionava.
#
# Uso:
#   ./status.sh            painel continuo, atualiza a cada 20s
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

# O motor mora em lib/. Os comandos do usuario ficam na raiz; tudo que e
# biblioteca (worker, painel, modulos de batalha) e carregado daqui.
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
        -h|--help)
            printf "uso: ./status.sh [-1] [-n SEGUNDOS] [-cols] [-icones]\n"
            printf "  -1        imprime uma vez e sai\n"
            printf "  -n SEG    intervalo de atualizacao (padrao 5)\n"
            printf "  -cols     regua de calibracao da largura da tela\n"
            printf "  -icones   desenha os tres conjuntos de icones, para escolher\n"
            exit 0
            ;;
    esac
    shift
done
# Padrao 5s (era 20s): o painel so LE arquivos (pagina/stats/combate ja sao
# gravados a cada requisicao pelos workers), entao atualizar mais rapido
# deixa o "log de atividade" praticamente em tempo real, seguindo o bot entre
# as paginas, sem custo para as contas. Ajustavel com -n.
case "${PANEL_INTERVAL:-5}" in ''|*[!0-9]*) PANEL_INTERVAL=5 ;; esac
export PANEL_INTERVAL

# Localiza o arquivo de contas — MESMA regra do play.sh e do setup.sh.
resolve_accounts_file() {
    if [ -s "$SLSDIR/accounts.conf" ]; then
        printf '%s' "$SLSDIR/accounts.conf"
        return 0
    fi
    for _cand in "$HOME/solucaoshell/accounts.conf" \
                 "$HOME/.sls/accounts.conf"; do
        if [ -s "$_cand" ]; then
            printf '%s' "$_cand"
            unset _cand
            return 0
        fi
    done
    unset _cand
    printf '%s' "$SLSDIR/accounts.conf"
}

# Calibracao da largura: nao depende de conta nem de worker no ar, entao
# roda antes das checagens (e util justamente em aparelho recem-instalado).
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

# Sem terminal (redirecionado para arquivo, pipe, etc.) o painel nao imprime
# nada — imprimir a cada 20s num arquivo so geraria lixo. Nesse caso o modo
# de uma volta e o unico que faz sentido.
if [ "$HAS_TTY" = 0 ]; then
    PANEL_ONCE=1
    PANEL_DRAW=1
fi
export PANEL_ONCE PANEL_DRAW

painel_loop
