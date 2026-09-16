# shellcheck disable=SC2148
arena_duel() {
    printf "Arena\n"

    checkQuest 3 apply
    checkQuest 4 apply

    fetch_page "/arena/"

    BREAK=$(($(date +%s) + 60))
    count=0

    # CORRECAO: o laco era "until grep 'lab/wizard' ...". Em alguns estados a
    # pagina da arena ja traz o link do Laboratorio do Mago e o laco terminava
    # ANTES de atacar — a conta "ia na arena" mas nao golpeava (energia nao
    # caia). Agora quem manda e a PRESENCA do link de ataque real (com nonce),
    # slot generico [0-9]+ (nao fixo em /1/), dentro do teto de 60s.
    while [ "$(date +%s)" -lt "$BREAK" ]; do
        # ALINHADO AO ORIGINAL: o alvo e o slot 1 (/arena/attack/1/), que e o
        # que o original ataca sempre. O generico [0-9]+ fica so de reserva,
        # para a pagina que por algum motivo nao ofereca o slot 1 — assim o
        # comportamento e identico ao do original no caso normal, sem parar de
        # golpear no caso incomum.
        ACCESS=`grep -o -E '/arena/attack/1/[?]r[=][0-9]+' "$TMP/SRC" | sed -n '1p'`
        [ -n "$ACCESS" ] || \
            ACCESS=`grep -o -E '/arena/attack/[0-9]+/[?]r[=][0-9]+' "$TMP/SRC" | sed -n '1p'`
        if [ -z "$ACCESS" ]; then
            printf "  Arena: sem ataque disponivel agora\n"
            break
        fi
        fetch_page "$ACCESS"
        count=$((count + 1))
        printf "  Attack %s\n" "$count"
        sleep 0.6s
    done

    # Sem ataque nao ha item novo na mochila: 48 aberturas por dia a toa.
    if [ "$count" -eq 0 ]; then
        checkQuest 3 end
        checkQuest 4 end
        printf "Arena ok\n"
        return 0
    fi

    fetch_page "/inv/bag/"
    SELL=`grep -o -E '(/inv/bag/sellAll/1/[?]r[=][0-9]+)' "$TMP/SRC" | sed -n '1p'`
    # CORRECAO: sem nada a vender o SELL fica vazio e o fetch_page ""
    # requisitava a HOME — um pedido a toa por passagem na arena que ainda
    # sobrescrevia $TMP/pagina, fazendo o painel (e a atividade que os outros
    # jogadores veem) piscar "Pagina Principal" no meio da arena.
    if [ -n "$SELL" ]; then
        fetch_page "$SELL"
        printf "Sell all items ok\n"
    else
        printf "Nada a vender na mochila\n"
    fi

    checkQuest 3 end
    checkQuest 4 end

    printf "Arena ok\n"
}

arena_fullmana() {
    printf "energy arena ...\n"
    (
        run_curl_exec "${URL}/arena/quit" | sed "s/href='/\n/g" | grep 'attack/1' | head -n1 | awk -F/ '{ print $5 }' | tr -cd '[:digit:]' > "$TMP/ARENA"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17
    # Sem o nonce da pagina, "attack/1/?r=" e "lastPlayer/?r=" sao pedidos
    # invalidos: para aqui.
    [ -s "$TMP/ARENA" ] || { printf "Energy arena: sem ataque na pagina\n"; return 1; }
    printf " - 1 Attack...\n"
    (
        run_curl_exec "${URL}/arena/attack/1/?r=`cat "$TMP/ARENA"`" | sed "s/href='/\n/g" | grep 'arena/lastPlayer' | head -n1 | awk -F\' '{ print $1 }' | tr -cd '[:digit:]' > "$TMP/ATK1"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17
    [ -s "$TMP/ATK1" ] || { printf "Energy arena: sem ataque cheio na pagina\n"; return 1; }
    printf " - Full Attack...\n"
    (
        run_curl_exec "${URL}/arena/lastPlayer/?r=`cat "$TMP/ATK1"`&fullmana=true" > /dev/null
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17
    printf "Energy arena ok\n"
}
