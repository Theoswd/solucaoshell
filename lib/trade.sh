# TROCA PRATA -> OURO, UMA VEZ POR DIA.
#
# E o unico ponto do bot que mexe com ouro — e no sentido de GANHAR: paga
# em prata, que e recurso renovavel. Gasto de ouro nao existe em lugar
# nenhum.
#
# A pagina oferece tres lotes:
#   /trade/exchange/gold/1?r=N       1800 prata ->   1 ouro
#   /trade/exchange/gold/10?r=N     18000 prata ->  10 ouro
#   /trade/exchange/gold/100?r=N   180000 prata -> 100 ouro
#
# (A implementacao original procurava /trade/exchange/silver/N, que e o
# sentido contrario — comprar prata com ouro.)
#
# O lote e escolhido pela reserva de prata: so usa um lote se o saldo
# aguentar essa mesma troca, uma por dia, durante um ano inteiro. Isso
# mantem a economia estavel — quem tem pouca prata cai para o lote menor
# em vez de drenar o caixa.
#
#   lote 100 -> reserva de 65.700.000 de prata (365 x 180.000)
#   lote  10 -> reserva de  6.570.000
#   lote   1 -> reserva de    657.000
#   abaixo disso nao troca
#
# O horizonte da reserva vem de FUNC_trade_dias (padrao 365).
#
# UMA OLHADA POR DIA: o marcador em $TMP/last_trade guarda a data. Ele e
# gravado a cada pagina lida — trocando ou nao. Antes so a troca feita
# marcava o dia: com prata abaixo da reserva, a pagina era reaberta a cada
# varredura (:00, :30 e na ociosa) o dia inteiro. Sem saldo legivel
# (pagina que nao veio), o dia fica em aberto e a proxima varredura tenta.
func_trade() {
    [ "${FUNC_trade:-y}" = "y" ] || return 1

    _hoje=`date +%Y%m%d`
    _ult=`cat "$TMP/last_trade" 2>/dev/null`
    if [ "$_ult" = "$_hoje" ]; then
        unset _hoje _ult
        return 0
    fi

    printf "Trade\n"

    _dias=${FUNC_trade_dias:-365}
    case "$_dias" in ''|*[!0-9]*) _dias=365 ;; esac

    fetch_page "/trade/exchange"
    # Saldo da conta e sempre alt='s'; alt='' e taxa de cambio da propria loja.
    _pr=`grep -o -E "silver\.png' alt='s'/> ?[0-9][0-9.,']{0,14}[KMBkmb]?" "$TMP/SRC" | sed -E "s@.*/> ?@@" | head -n1`
    _prata=`valor_num "$_pr"`
    case "$_prata" in ''|*[!0-9]*) _prata=0 ;; esac

    if   [ "$_prata" -ge $((180000 * _dias)) ]; then _lote=100
    elif [ "$_prata" -ge $((18000  * _dias)) ]; then _lote=10
    elif [ "$_prata" -ge $((1800   * _dias)) ]; then _lote=1
    else
        printf "Trade: prata insuficiente para trocar com seguranca (%s)\n" "$_pr"
        [ -n "$_pr" ] && printf %s "$_hoje" > "$TMP/last_trade" 2>/dev/null
        printf "Trade ok\n"
        unset _hoje _ult _dias _pr _prata _lote
        return 0
    fi

    _cl=`grep -o -E "/trade/exchange/gold/${_lote}[?]r=[0-9]+" "$TMP/SRC" | sed -n 1p`
    if [ -z "$_cl" ]; then
        printf "Trade: lote de %s indisponivel agora\n" "$_lote"
        printf %s "$_hoje" > "$TMP/last_trade" 2>/dev/null
        printf "Trade ok\n"
        unset _hoje _ult _dias _pr _prata _lote _cl
        return 0
    fi

    # Clique sem resposta nao gasta a troca do dia: tenta na proxima passagem.
    # Resposta que nao e pagina do jogo com a conta logada (login, erro) tambem.
    if ! fetch_page "$_cl" || [ "`sessao_estado "$TMP/SRC"`" != viva ]; then
        printf "Trade: sem resposta na troca - tenta de novo depois\n"
        unset _hoje _ult _dias _pr _prata _lote _cl
        return 0
    fi
    printf '%s' "$_hoje" > "$TMP/last_trade" 2>/dev/null
    printf "Trade: prata %s — trocou por %s de ouro (1x hoje)\n" "$_pr" "$_lote"
    printf "Trade ok\n"
    unset _hoje _ult _dias _pr _prata _lote _cl
}

# A BENCAO FOI REMOVIDA.
#
# Ela custa 100 de ouro em /effshop/ e o bot nao gasta ouro. O blessing.sh
# continua como tranca do lado do HTTP: bloqueia a URL antes do curl sair.
