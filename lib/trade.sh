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
#
# CLIQUE SEM RESPOSTA NAO VIRA SEGUNDA TROCA. O servidor pode ter trocado
# mesmo com o tempo esgotado, a pagina cortada ou o worker morto no meio
# (SIGKILL do Android). Antes do clique fica $TMP/trade_pendente =
# "DATA OURO_ANTES LOTE TENTATIVAS"; na passagem seguinte do mesmo dia o OURO
# da pagina decide (a prata vem abreviada, "408,1M", e a caverna e a arena a
# mexem): subiu o lote, a troca saiu; igual, tenta de novo (duas tentativas
# no dia); ouro ilegivel ou abreviado, nao arrisca e da o dia por feito.

# Ouro da conta no cabecalho de $TMP/SRC, inteiro; vazio se ilegivel ou
# abreviado (K/M: a precisao nao enxerga o lote).
trade_ouro() {
    _to=`grep -o -E "gold\.png' alt='g'/>[^0-9]{0,40}[0-9][0-9.,']{0,14}[KMBkmb]?" "$TMP/SRC" 2>/dev/null | head -n1`
    _to=${_to##*>}
    case "$_to" in
        *[KMBkmb]) _to="" ;;
        *) _to=`printf '%s' "$_to" | tr -cd '0-9'` ;;
    esac
    printf '%s' "$_to"
    unset _to
}

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

    # Clique de antes ficou sem resposta? O ouro desta pagina diz se saiu.
    _pd_d=""; _pd_o=""; _pd_l=""; _pd_n=0
    { read -r _pd_d _pd_o _pd_l _pd_n < "$TMP/trade_pendente"; } 2>/dev/null
    case "$_pd_n" in ''|*[!0-9]*) _pd_n=0 ;; esac
    if [ -n "$_pd_d" ] && [ "$_pd_d" != "$_hoje" ]; then
        rm -f "$TMP/trade_pendente" 2>/dev/null; _pd_d=""
    fi
    if [ -n "$_pd_d" ]; then
        # Pagina que nao veio ou sem a conta: nao decide nada.
        if [ "`sessao_estado "$TMP/SRC"`" != viva ]; then
            printf "Trade: sem resposta ao conferir a troca anterior - tenta depois\n"
            unset _hoje _ult _dias _pd_d _pd_o _pd_l _pd_n
            return 0
        fi
        _pd_a=`trade_ouro`
        case "$_pd_o$_pd_a$_pd_l" in *[!0-9]*|'') _pd_ok=ilegivel ;; *) _pd_ok="" ;; esac
        if [ -z "$_pd_ok" ] && [ -n "$_pd_o" ] && [ -n "$_pd_a" ] && [ -n "$_pd_l" ]; then
            [ "$_pd_a" -ge $(( _pd_o + _pd_l )) ] && _pd_ok=saiu || _pd_ok=nao_saiu
        else
            _pd_ok=ilegivel
        fi
        if [ "$_pd_ok" != nao_saiu ] || [ "$_pd_n" -ge 2 ]; then
            case "$_pd_ok" in
                saiu)     printf "Trade: a troca anterior saiu (ouro %s -> %s) - 1x hoje\n" "$_pd_o" "$_pd_a" ;;
                ilegivel) printf "Trade: ouro ilegivel, a troca anterior pode ter saido - nao repete hoje\n" ;;
                *)        printf "Trade: duas tentativas sem confirmacao - nao repete hoje\n" ;;
            esac
            printf '%s' "$_hoje" > "$TMP/last_trade" 2>/dev/null
            rm -f "$TMP/trade_pendente" 2>/dev/null
            printf "Trade ok\n"
            unset _hoje _ult _dias _pd_d _pd_o _pd_l _pd_n _pd_a _pd_ok
            return 0
        fi
        printf "Trade: a troca anterior nao saiu (ouro %s) - tenta de novo\n" "$_pd_a"
        unset _pd_a _pd_ok
    fi

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

    # A marca vai ANTES do clique: o worker pode morrer no meio do pedido.
    # A troca que a passagem anterior ja conferia (nao saiu) segue o mesmo
    # ouro de antes; a primeira le o desta pagina.
    if [ -n "$_pd_d" ]; then
        printf '%s %s %s %s\n' "$_hoje" "$_pd_o" "$_lote" $(( _pd_n + 1 )) > "$TMP/trade_pendente" 2>/dev/null
    else
        # Ouro ilegivel vira "-": a conferencia da por feito, sem repetir.
        _pd_o=`trade_ouro`
        printf '%s %s %s 1\n' "$_hoje" "${_pd_o:--}" "$_lote" > "$TMP/trade_pendente" 2>/dev/null
    fi
    # Clique sem resposta nao da o dia por feito: a proxima passagem confere
    # pelo ouro. Resposta que nao e pagina do jogo com a conta logada (login,
    # erro) tambem.
    if ! fetch_page "$_cl" || [ "`sessao_estado "$TMP/SRC"`" != viva ]; then
        printf "Trade: sem resposta na troca - confere pelo ouro na proxima passagem\n"
        unset _hoje _ult _dias _pr _prata _lote _cl _pd_d _pd_o _pd_l _pd_n
        return 0
    fi
    printf '%s' "$_hoje" > "$TMP/last_trade" 2>/dev/null
    rm -f "$TMP/trade_pendente" 2>/dev/null
    printf "Trade: prata %s — trocou por %s de ouro (1x hoje)\n" "$_pr" "$_lote"
    printf "Trade ok\n"
    unset _hoje _ult _dias _pr _prata _lote _cl
}

# A BENCAO FOI REMOVIDA: custa ouro. O blessing.sh continua como tranca do
# lado do HTTP: bloqueia a URL antes do curl sair.
