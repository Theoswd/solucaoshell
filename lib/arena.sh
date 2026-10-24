# shellcheck disable=SC2148
arena_duel() {
    printf "Arena\n"

    # Regra do dono: missao do cla so para a atividade que vai acontecer.
    # Com ataque na tela, ajuda ou toma (cq_antes) e rele a arena: o nonce
    # da primeira leitura nao vale depois das paginas de missao.
    fetch_page "/arena/"
    if grep -q -E '/arena/attack/[0-9]+/[?]r[=][0-9]+' "$TMP/SRC" && [ -n "$CLD" ]; then
        cq_antes arena 2>/dev/null
        fetch_page "/arena/"
    fi

    BREAK=$(($(date +%s) + 60))
    count=0

    # Quem manda e a PRESENCA do link de ataque real (com nonce), dentro do
    # teto de 60s; o link do Laboratorio do Mago pode vir na pagina antes.
    while [ "$(date +%s)" -lt "$BREAK" ]; do
        # O alvo e o slot 1 (/arena/attack/1/), como no original; o generico
        # [0-9]+ e so reserva para a pagina sem o slot 1.
        ACCESS=`grep -o -E '/arena/attack/1/[?]r[=][0-9]+' "$TMP/SRC" | sed -n '1p'`
        [ -n "$ACCESS" ] || \
            ACCESS=`grep -o -E '/arena/attack/[0-9]+/[?]r[=][0-9]+' "$TMP/SRC" | sed -n '1p'`
        if [ -z "$ACCESS" ]; then
            printf "  Arena: sem ataque disponivel agora\n"
            break
        fi
        # Regra do dono: nunca gasta ouro (ver botao_pago).
        if botao_pago "$TMP/SRC" "$ACCESS"; then
            printf "  Arena: ataque cobra ouro - para aqui\n"
            break
        fi
        fetch_page "$ACCESS"
        count=$((count + 1))
        printf "  Attack %s\n" "$count"
        sleep 0.6s
    done

    # Sem ataque: nem mochila nem missao (nada mudou nelas).
    if [ "$count" -eq 0 ]; then
        printf "Arena ok\n"
        return 0
    fi

    fetch_page "/inv/bag/"
    SELL=`grep -o -E '(/inv/bag/sellAll/1/[?]r[=][0-9]+)' "$TMP/SRC" | sed -n '1p'`
    # Sem nada a vender o fetch_page "" pediria a HOME (e o painel piscaria
    # "Pagina Principal").
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
