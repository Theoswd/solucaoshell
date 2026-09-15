# check.sh
#
# O CONTADOR DESTE ARQUIVO TEM NOME PROPRIO.
#
# Era um `i` solto: `for i in 1 2`, `i=$((i + 1))`. Nao existe escopo em sh,
# entao o valor sobrava no ambiente do worker depois da funcao retornar
# (medido: check_missions deixava i=17, check_rewards deixava i=12). E o
# func_cat usa `${i:-60}` como tempo de espera do ciclo ocioso.
#
# Hoje isso nao custa nada, porque o func_cat so e chamado de dentro do
# func_sleep, que define o i logo antes (conferido: a espera sai 15s, nao
# 17s). Mas basta alguem chamar o func_cat de outro lugar para o bot passar
# a descansar 12 segundos em vez de 60.
check_missions() {
    printf "Checking Missions\n"

    fetch_page "/quest/"

    for _ck_i in 1 2; do
        click=`grep -o -E "/quest/openChest/$_ck_i/[?]r=[0-9]+" "$TMP/SRC" | head -n1`
        if [ -n "$click" ]; then
            fetch_page "$click"
            printf "Chest %s opened\n" "$_ck_i"
        fi
    done

    if [ "$FUNC_collect_mission_rewards" = "n" ]; then
        return
    fi

    # CORRECAO: o laco de missoes lia $TMP/SRC, mas ao abrir os baus acima o
    # fetch_page ja tinha sobrescrito o SRC com a pagina de resultado do bau —
    # entao os links /quest/end/ eram procurados na pagina errada e as missoes
    # concluidas nao eram recolhidas. Rebusca a pagina de missoes (que ja
    # reflete o estado apos abrir os baus).
    fetch_page "/quest/"

    _ck_i=0
    while [ "$_ck_i" -le 16 ]; do
        click=`grep -o -E "/quest/end/${_ck_i}[?]r=[0-9]+" "$TMP/SRC" | sed -n '1p'`
        if [ -n "$click" ]; then
            fetch_page "$click"
            printf "Mission %s Completed\n" "$_ck_i"
        fi
        _ck_i=$((_ck_i + 1))
    done

    fetch_page "/collector/"
    # "sed -n 1p": link repetido na pagina virava duas linhas e o curl
    # recusava a URL, sem nada no log.
    click=`grep -o -E "/collector/reward/element/[?]r=[0-9]+" "$TMP/SRC" | sed -n 1p`
    if [ -n "$click" ]; then
        fetch_page "$click"
        printf "Collection collected\n"
    fi

    printf "Missions ok\n"
}

check_rewards() {
    if [ "$FUNC_check_rewards" = "n" ]; then
        return
    fi

    fetch_page "/relic/reward/"

    _ck_i=0
    while [ "$_ck_i" -le 11 ]; do
        click=`grep -o -E "/relic/reward/${_ck_i}/[?]r=[0-9]+" "$TMP/SRC" | sed -n 1p`
        if [ -n "$click" ]; then
            fetch_page "$click"
            printf "Relic %s collected\n" "$_ck_i"
        fi
        _ck_i=$((_ck_i + 1))
    done
}

apply_event() {
    event_path="${1}"
    fetch_page "/${event_path}/"
    APPLY=`grep -o -E "/${event_path}/enter(Game|Fight)/[?]r=[0-9]+" "$TMP/SRC" | sed -n 1p`
    if [ -n "$APPLY" ]; then
        fetch_page "$APPLY"
        printf "Applied for battle\n"
    fi
}

use_elixir() {
    if [ "$FUNC_use_elixir" = "n" ]; then
        return
    fi

    # CORRECAO: pegava o i-esimo link (`sed -n "${_ck_i}p"`) de uma pagina que
    # muda a cada uso — os indices desalinhavam apos o primeiro elixir — e
    # reaproveitava o nonce `?r=` da PRIMEIRA leitura, que o servidor pode
    # recusar. Agora rebusca a pagina a cada volta (nonce fresco) e usa sempre
    # o PRIMEIRO link disponivel; quando nao ha mais, encerra.
    _ck_i=1
    while [ "$_ck_i" -le 4 ]; do
        fetch_page "/inv/chest/"
        click=`grep -o -E "/inv/chest/use/[0-9]+/1/[?]r=[0-9]+" "$TMP/SRC" | sed -n 1p`
        if [ -z "$click" ]; then
            printf "No more URLs to process.\n"
            break
        fi
        fetch_page "$click"
        _ck_i=$((_ck_i + 1))
    done

    printf "Applied all elixir\n"
}
