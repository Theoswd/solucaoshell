# shellcheck disable=SC2155
# shellcheck disable=SC2154

SILVER_SPENT_TOTAL=0

# CAVERNA SEM OURO: o impulso de sorte (/cave/chance/2/) foi REMOVIDO e nao
# ha caminho de codigo que chegue a essa compra. O monstro e evitado.

# Preco do speedUp: o icone de prata logo DEPOIS do link (nao o saldo do
# cabecalho). Sem preco perto do link, 0.
# Conferido na pagina real (22/10): o rotulo e "Acelerar para <img
# .../silver.png' alt=''/> 41580" e o preco e o TOTAL para terminar agora
# (cai com o tempo que falta; o preco por minuto depende do nivel da conta).
read_speedup_silver_cost() {
    _sc=`grep -o -E "/cave/speedUp/[^<]*(<[^>]*>[^<]*){0,4}<[^>]*silver\.png[^>]*>[^0-9<]{0,40}[0-9][0-9.,']*[KMBkmb]?" "$TMP/SRC" \
         | head -n1 | grep -o -E "[0-9][0-9.,']*[KMBkmb]?$"`
    SPEEDUP_SILVER_COST=`valor_num "$_sc"`
    case "$SPEEDUP_SILVER_COST" in ''|*[!0-9]*) SPEEDUP_SILVER_COST=0 ;; esac
    unset _sc
}

check_cave_limits() {
    # So resta o limite de PRATA: o bot nao gasta ouro na caverna.
    _sl=${CAVE_SILVER_LIMIT:-0}
    case "$_sl" in ''|*[!0-9]*) _sl=0 ;; esac

    # Runmode por conta, em $TMP. Basta sair: o worker.sh desta conta
    # reinicia o sls.sh em ~15s e ele le o runmode_file atualizado.
    if [ "$_sl" -gt 0 ] && [ "${SILVER_SPENT_TOTAL:-0}" -ge "$_sl" ]; then
        printf "Limite de prata atingido (%s/%s)\n" "${SILVER_SPENT_TOTAL:-0}" "$_sl"
        sleep 3
        echo "-boot" > "$TMP/runmode_file"
        exit 0
    fi
    unset _sl
}

set_cave_limits() {
    # O worker sobe sem terminal (stdin em /dev/null): o limite vem do config.
    _s=$(get_config CAVE_SILVER_LIMIT 2>/dev/null)
    case "$_s" in ''|*[!0-9]*) _s=0 ;; esac
    CAVE_SILVER_LIMIT="$_s"
    printf "Caverna: limite de prata=%s (0 = sem limite)\n" \
        "$CAVE_SILVER_LIMIT"
    unset _s
}

bottom_info() {
    printf "%s | HP %s (%s%%) | MP %s (%s%%)\n" "$ACC" "$NOWHP" "$HPPER" "$NOWMP" "$MPPER" > "$TMP/bottom_file"
    printf " ~ Press [x] to exit\n" >> "$TMP/bottom_file"
    cat "$TMP/bottom_file"
}

cave_start() {
    clan_id
    fetch_page "/cave/"
    set_cave_limits

    while echo "$RUN" | grep -q -E '[-]cv'; do
        CAVE=`grep -o -E '/cave/(gather|down|speedUp)/[?]r[=][0-9]+' "$TMP/SRC" | sed -n '1p'`
        RESULT=`echo "$CAVE" | cut -d'/' -f3`

        # A condicao do laco e CONSTANTE: sem link de acao, sai. A espera e
        # porque o laco principal chama o cave_start de novo na hora.
        if [ -z "$CAVE" ]; then
            printf "Caverna sem acao disponivel agora\n"
            espera_interrompivel 60
            break
        fi
        # CAVERNA SEM OURO tambem no modo -cv (o cave_routine e o
        # caverna_noite ja conferiam). A espera e a mesma do "sem acao": o
        # laco principal chama o cave_start de novo na hora.
        if botao_pago "$TMP/SRC" "$CAVE"; then
            printf "Caverna: %s cobra ouro - para aqui\n" "$RESULT"
            espera_interrompivel 60
            break
        fi

        MONSTER_RUNAWAY=`grep -o -E '/cave/runaway/[?]r=[0-9]+' "$TMP/SRC" | head -n1`

        # MONSTRO: sempre foge (enfrentar so valia com impulso pago em ouro).
        if [ -n "$MONSTER_RUNAWAY" ]; then
            printf "Monster found - running away (no gold spent)\n"
            fetch_page "$MONSTER_RUNAWAY"
            # O link de acao (e o nonce ?r=) e o da pagina de ANTES da fuga:
            # o servidor recusa. A volta seguinte o tira da pagina nova.
            continue
        fi

        read_speedup_silver_cost
        fetch_page "$CAVE"

        case $RESULT in
            down*)
                printf "New search\n"
                ;;
            gather*)
                printf "Start mining\n"
                ;;
            speedUp*)
                printf "Speeding up mining\n"
                ;;
        esac

        # So o acelerar gasta prata: o preco lido na pagina nao conta quando
        # a acao foi pesquisa ou mineracao (encerrava a caverna antes da hora).
        if [ "$RESULT" = speedUp ] && [ "$SPEEDUP_SILVER_COST" -gt 0 ]; then
            SILVER_SPENT_TOTAL=$((SILVER_SPENT_TOTAL + SPEEDUP_SILVER_COST))
        fi

        bottom_info
        fetch_page "/cave/"
        check_cave_limits
    done
}

cave_routine() {
    printf "Cave\n"

    # Tomada agora ou antes (o cq_antes caverna ja a toma): ver cq_falta.
    if checkQuest 5 apply || cq_ativa 5; then
        count=0
        printf "Quests available speeding up mine to complete!\n"
    else
        count=8
    fi

    # LIMITE DE TEMPO: sem teto, a caverna em espera repetiria /cave/ sem fim.
    CAVE_BREAK=$(($(date +%s) + 240))

    fetch_page "/cave/"

    while [ "$(date +%s)" -lt "$CAVE_BREAK" ]; do
        CAVE=`grep -o -E '/cave/(gather|down|runaway|speedUp)/[?]r[=][0-9]+' "$TMP/SRC" | sed -n '1p'`
        RESULT=`echo "$CAVE" | cut -d'/' -f3`

        # Sem link de acao, a caverna esta em espera: sai.
        if [ -z "$CAVE" ]; then
            printf "Caverna sem acao disponivel agora
"
            break
        fi

        if [ "$RESULT" = "speedUp" ] && [ "$count" -ge 8 ]; then
            printf "Cave limit reached\n"
            break
        fi
        if botao_pago "$TMP/SRC" "$CAVE"; then
            printf "Caverna: %s cobra ouro - para aqui\n" "$RESULT"
            break
        fi

        case $RESULT in
            gather|down|runaway|speedUp)
                fetch_page "$CAVE"
                case $RESULT in
                    down*)
                        printf "New search\n"
                        count=$((count + 1))
                        ;;
                    gather*)
                        printf "Start mining\n"
                        ;;
                    runaway*)
                        printf "Running away\n"
                        ;;
                    speedUp*)
                        printf "Speed up mining\n"
                        ;;
                esac
                ;;
        esac

        fetch_page "/cave/"
    done

    checkQuest 5 end
    printf "Cave ok\n"
}

# ============================================================
#  CAVERNA DA MADRUGADA (00:30-02:40), A PEDIDO DO DONO
#
#  Das 00:30 as 02:40 a conta se concentra na caverna, acelerando com prata:
#  nova pesquisa -> acelera -> inicia mineracao -> acelera -> nova pesquisa...
#  Monstro na pesquisa: foge (o runaway) e segue. Depois das 02:40 e o
#  Coliseu (run.sh) e a caverna volta ao ritmo comum (sem acelerar).
#
#  LIMITE: 15% da prata que a conta tinha na primeira leitura da noite
#  (CAVE_NOITE_PCT). Atingido, a caverna fica pausada ate a noite seguinte.
#  O gasto e o maior de dois numeros: a soma do preco lido nos botoes de
#  acelerar e a queda da prata no cabecalho desde o inicio. Assim o limite
#  vale mesmo que o preco do botao nao seja lido.
#
#  Estado em disco ($TMP/cave_noite), para o worker relancado nao recomecar a
#  conta: "AAAAMMDD PRATA_INICIAL GASTO_NOS_BOTOES PAUSADA"
# ============================================================
CAVE_NOITE_PCT=${CAVE_NOITE_PCT:-15}
CAVE_NOITE_BLOCO=${CAVE_NOITE_BLOCO:-240}

# Agora e a janela da caverna (00:30 <= hora < 02:40)?
caverna_noite_janela() {
    hora_atual; minuto_atual
    _cnj=$(( ${_HOR:-0} * 60 + ${_MIN:-0} ))
    [ "$_cnj" -ge 30 ] && [ "$_cnj" -lt 160 ]
    _cnj=$?
    return $_cnj
}

# Janela da caverna E limite desta noite ainda nao atingido. So le o disco.
caverna_noite_ativa() {
    caverna_noite_janela || return 1
    _cna_d=; _cna_f=0
    { read -r _cna_d _cna_x _cna_y _cna_f < "$TMP/cave_noite"; } 2>/dev/null
    _cna_r=0
    [ "$_cna_d" = "`date +%Y%m%d`" ] && [ "$_cna_f" = 1 ] && _cna_r=1
    unset _cna_d _cna_x _cna_y _cna_f
    return $_cna_r
}

# Prata da conta numa pagina, em numero inteiro ("1819,8M" -> 1819800000).
# Vazio quando a pagina nao traz o icone. Um awk, sem {n,m} (mawk).
#
# VALE O ULTIMO ICONE DE PRATA, NAO O PRIMEIRO. Na caverna a prata da conta
# fica no RODAPE ("lvl 105 | g 132 | s 1819,8M"), e antes dela a dica da
# aceleracao traz o mesmo icone com o preco por minuto:
#     Minutos 1 de aceleracao preco <img .../silver.png' alt='s'/> <span class='bold'>1260</span>
# (pagina real de 22/10). O primeiro icone dava 1260 como prata da conta: o
# limite da noite virava 189 e o primeiro acelerar (41580) ja parava tudo.
prata_pagina() {
    awk '
        { t = t $0 " " }
        END {
            p = "silver[.]png'"'"' alt='"'"'s'"'"'/>[^0-9]*[0-9][0-9.,'"'"']*[KMBkmb]?"
            v = ""
            while (match(t, p)) { v = substr(t, RSTART, RLENGTH); t = substr(t, RSTART + RLENGTH) }
            if (v == "") exit
            sub(/^[^0-9]*/, "", v)
            m = 1; u = toupper(substr(v, length(v), 1))
            if (u == "K") m = 1000; else if (u == "M") m = 1000000; else if (u == "B") m = 1000000000
            if (m > 1) { v = substr(v, 1, length(v) - 1); gsub(/'"'"'/, "", v); gsub(/,/, ".", v) }
            else gsub(/[^0-9]/, "", v)
            if (v == "") exit
            printf "%.0f\n", v * m
        }' "$1" 2>/dev/null
}

_cn_gravar() {
    printf '%s %s %s %s\n' "$_cn_dia" "$_cn_base" "$_cn_soma" "$_cn_fim" > "$TMP/cave_noite" 2>/dev/null
}

# Um bloco de ate CAVE_NOITE_BLOCO segundos de caverna. Entre os blocos a
# rotina segue (checklist, Liga, carreira, descanso), cada uma no seu horario.
# 0 = fez alguma acao; 1 = nada (pausada, sem acao ou sem pagina).
caverna_noite() {
    _cn_dia=`date +%Y%m%d`
    _cn_d=; _cn_base=0; _cn_soma=0; _cn_fim=0
    { read -r _cn_d _cn_base _cn_soma _cn_fim < "$TMP/cave_noite"; } 2>/dev/null
    if [ "$_cn_d" != "$_cn_dia" ]; then _cn_base=0; _cn_soma=0; _cn_fim=0; fi
    case "$_cn_base" in ''|*[!0-9]*) _cn_base=0 ;; esac
    case "$_cn_soma" in ''|*[!0-9]*) _cn_soma=0 ;; esac
    if [ "$_cn_fim" = 1 ]; then
        unset _cn_dia _cn_d _cn_base _cn_soma _cn_fim
        return 1
    fi
    _cn_pct=$CAVE_NOITE_PCT
    case "$_cn_pct" in ''|*[!0-9]*) _cn_pct=15 ;; esac

    printf "Caverna da madrugada\n"
    fetch_page "/cave/" || { unset _cn_dia _cn_d _cn_base _cn_soma _cn_fim _cn_pct; return 1; }
    _cn_agora=`prata_pagina "$TMP/SRC"`
    if [ "$_cn_base" -eq 0 ]; then
        case "$_cn_agora" in
            ''|*[!0-9]*|0)
                printf "Caverna: prata da conta nao lida - sem acelerar agora\n"
                unset _cn_dia _cn_d _cn_base _cn_soma _cn_fim _cn_pct _cn_agora
                return 1 ;;
        esac
        _cn_base=$_cn_agora
        _cn_gravar
        printf "Caverna: limite da noite %s%% de %s = %s de prata\n" \
            "$_cn_pct" "$_cn_base" "$(( _cn_base * _cn_pct / 100 ))"
    fi
    _cn_lim=$(( _cn_base * _cn_pct / 100 ))

    _cn_acao=1
    _cn_ate=$(( `date +%s` + ${CAVE_NOITE_BLOCO:-240} ))
    while [ "`date +%s`" -lt "$_cn_ate" ]; do
        CAVE=`grep -o -E '/cave/(gather|down|runaway|speedUp)/[?]r[=][0-9]+' "$TMP/SRC" | sed -n '1p'`
        RESULT=`echo "$CAVE" | cut -d'/' -f3`
        if [ -z "$CAVE" ]; then
            printf "Caverna sem acao disponivel agora\n"
            break
        fi
        if botao_pago "$TMP/SRC" "$CAVE"; then
            printf "Caverna: %s cobra ouro - para aqui\n" "$RESULT"
            break
        fi

        # Gasto ate aqui: o maior entre a soma dos botoes e a queda da prata.
        _cn_gasto=$_cn_soma
        case "$_cn_agora" in
            ''|*[!0-9]*) ;;
            *) [ $(( _cn_base - _cn_agora )) -gt "$_cn_gasto" ] && _cn_gasto=$(( _cn_base - _cn_agora )) ;;
        esac

        _cn_preco=0
        if [ "$RESULT" = speedUp ]; then
            read_speedup_silver_cost
            _cn_preco=$SPEEDUP_SILVER_COST
            # Limite atingido, ou este clique passaria dele: pausa a noite.
            if [ "$_cn_gasto" -ge "$_cn_lim" ] || \
               [ $(( _cn_gasto + _cn_preco )) -gt "$_cn_lim" ]; then
                _cn_fim=1
                _cn_gravar
                printf "Caverna: %s%% da prata gasto (%s de %s) - pausada ate a proxima noite\n" \
                    "$_cn_pct" "$_cn_gasto" "$_cn_lim"
                break
            fi
        fi

        fetch_page "$CAVE"
        _cn_acao=0
        case $RESULT in
            down)    printf "New search\n" ;;
            gather)  printf "Start mining\n" ;;
            runaway) printf "Monster - running away\n" ;;
            speedUp) printf "Speed up (%s de prata)\n" "$_cn_preco"
                     _cn_soma=$(( _cn_soma + _cn_preco ))
                     _cn_gravar ;;
        esac

        fetch_page "/cave/"
        _cn_agora=`prata_pagina "$TMP/SRC"`
    done

    unset _cn_dia _cn_d _cn_base _cn_soma _cn_fim _cn_pct _cn_lim _cn_agora _cn_gasto _cn_preco _cn_ate
    return $_cn_acao
}
