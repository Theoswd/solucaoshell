# shellcheck disable=SC2155
# shellcheck disable=SC2154

SILVER_SPENT_TOTAL=0

# CAVERNA SEM OURO.
#
# O impulso de sorte (/cave/chance/2/) e o unico gasto de ouro que existia
# aqui, e ele so servia para poder enfrentar o monstro. A politica do bot e
# nao gastar ouro, entao o impulso, o leitor do preco, o contador de ouro
# gasto e o limite de ouro foram REMOVIDOS — nao ha mais caminho de codigo
# que chegue a essa compra. O monstro continua sendo evitado, como ja era.

# Preco do speedUp: o icone de prata logo DEPOIS do link. O segundo grep
# recebia o arquivo inteiro e ignorava o pipe: lia o saldo do cabecalho, e
# "98'765" cortado no apostrofo virava custo 98. Sem preco perto do link, 0.
# ponytail: formato do botao nao conferido em pagina real; so o modo -cv usa.
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

    # CORRECAO (multi-contas): gravava em "$SLSDIR/runmode_file", arquivo
    # compartilhado por todas as contas. Agora e por conta, em $TMP.
    # E a re-execucao aninhada ("$SLSDIR/sls.sh" -boot seguida de exit 0)
    # foi removida: bastava sair, porque o worker.sh desta conta ja reinicia
    # o sls.sh em ~15s e ele le o runmode_file atualizado.
    if [ "$_sl" -gt 0 ] && [ "${SILVER_SPENT_TOTAL:-0}" -ge "$_sl" ]; then
        printf "Limite de prata atingido (%s/%s)\n" "${SILVER_SPENT_TOTAL:-0}" "$_sl"
        sleep 3
        echo "-boot" > "$TMP/runmode_file"
        exit 0
    fi
    unset _sl
}

set_cave_limits() {
    # O worker sobe sem terminal (stdin em /dev/null): o limite vem do config
    # da conta. O antigo "read" no terminal girava para sempre sem TTY.
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

        # CORRECAO: a condicao deste laco ("$RUN" contem -cv) e CONSTANTE,
        # entao sem link de acao ele girava para sempre — e o fetch_page
        # "$CAVE" com CAVE vazio pedia a HOME a cada volta. O cave_routine ja
        # tinha esta guarda; o cave_start (modo -cv) ficou sem.
        # A espera e porque o laco principal chama o cave_start de novo na
        # hora: sem ela eram /clan + /cave/ sem pausa, o dia inteiro.
        if [ -z "$CAVE" ]; then
            printf "Caverna sem acao disponivel agora\n"
            espera_interrompivel 60
            break
        fi

        # A contagem de minerios/ervas so existia para decidir o impulso de
        # sorte pago em ouro. Sem ele, eram sete processos por volta do laco
        # (grep, sed, dois echo|grep|wc) para um valor que ninguem mais le.
        MONSTER_RUNAWAY=`grep -o -E '/cave/runaway/[?]r=[0-9]+' "$TMP/SRC" | head -n1`

        # MONSTRO: sempre foge.
        #
        # Enfrentar o monstro so valia com o impulso de sorte comprado com
        # OURO. Sem essa compra o ataque nao compensa, entao o ramo de
        # ataque (e o CAN_ATTACK_MONSTER que o destrancava) foi removido.
        if [ -n "$MONSTER_RUNAWAY" ]; then
            printf "Monster found - running away (no gold spent)\n"
            fetch_page "$MONSTER_RUNAWAY"
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

        if [ "$SPEEDUP_SILVER_COST" -gt 0 ]; then
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

    # LIMITE DE TEMPO: o laco abaixo era "while true", sem limite e sem
    # saida quando nao ha acao disponivel. Com a caverna em espera, CAVE
    # ficava vazio, o case nao casava com nada, e o laco repetia
    # fetch_page "/cave/" indefinidamente — cerca de 3600 requisicoes por
    # hora, por conta. Era a maior fonte de carga do bot.
    CAVE_BREAK=$(($(date +%s) + 240))

    fetch_page "/cave/"

    while [ "$(date +%s)" -lt "$CAVE_BREAK" ]; do
        CAVE=`grep -o -E '/cave/(gather|down|runaway|speedUp)/[?]r[=][0-9]+' "$TMP/SRC" | sed -n '1p'`
        RESULT=`echo "$CAVE" | cut -d'/' -f3`

        # Sem link de acao, a caverna esta em espera: sai em vez de
        # repetir a mesma requisicao ate o tempo acabar.
        if [ -z "$CAVE" ]; then
            printf "Caverna sem acao disponivel agora
"
            break
        fi

        # A contagem de minerios/ervas so existia para decidir o impulso de
        # sorte pago em ouro. Sem ele, eram sete processos por volta do laco
        # (grep, sed, dois echo|grep|wc) para um valor que ninguem mais le.
        # O impulso de sorte de 3 minerios (/cave/chance/2/) custa OURO e foi
        # removido junto com a chave FUNC_cave_boost. A caverna segue so com
        # o que e de graca.

        if [ "$RESULT" = "speedUp" ] && [ "$count" -ge 8 ]; then
            printf "Cave limit reached\n"
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
