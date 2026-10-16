# TROCA PRATA -> OURO, UMA VEZ POR DIA.
#
# Unico ponto do bot que mexe com ouro, no sentido de GANHAR (paga em prata).
#   /trade/exchange/gold/1?r=N       1800 prata ->   1 ouro
#   /trade/exchange/gold/10?r=N     18000 prata ->  10 ouro
#   /trade/exchange/gold/100?r=N   180000 prata -> 100 ouro
#
# So usa um lote se o saldo aguentar essa mesma troca, uma por dia, durante
# FUNC_trade_dias (padrao 365): lote 100 pede 65.700.000 de prata, lote 10
# 6.570.000, lote 1 657.000; abaixo disso nao troca.
#
# UMA OLHADA POR DIA: $TMP/last_trade guarda a data, gravada a cada pagina
# lida, trocando ou nao. Sem saldo legivel, o dia fica em aberto.
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

# A BENCAO FOI REMOVIDA: custa ouro. O blessing.sh continua como tranca do
# lado do HTTP: bloqueia a URL antes do curl sair.
