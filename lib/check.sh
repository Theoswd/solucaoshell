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

# UM GREP POR PAGINA, NAO UM POR INDICE.
#
# As missoes (0 a 16) e as reliquias (0 a 11) eram procuradas com um
# grep|sed por indice, ~90 processos a cada 20 min por conta, quase sempre
# sem link nenhum. Agora _ck_lista guarda os links da pagina numa linha
# cada, e _ck_lista volta a ler so depois de um clique (a pagina mudou). O
# _ck_link acha o primeiro link do indice na lista, como o grep|sed achava.
_ck_lista() {
    _ck_l=`grep -o -E "${1}[?]r=[0-9]+" "$TMP/SRC"`
}

# _ck_link PREFIXO_COM_INDICE? -> click (vazio e 1 quando nao ha)
_ck_link() {
    click=""
    _ck_t="
$_ck_l"
    case "$_ck_t" in
        *"
$1"*) ;;
        *) unset _ck_t; return 1 ;;
    esac
    _ck_t=${_ck_t#*"
$1"}
    click="$1${_ck_t%%"
"*}"
    unset _ck_t
}

check_missions() {
    printf "Checking Missions\n"

    fetch_page "/quest/"

    # A RESPOSTA DE UM CLIQUE NAO E A LISTA DE MISSOES.
    #
    # O SRC passa a ser a pagina de resultado do bau (ou da missao), entao o
    # proximo link era procurado na pagina errada: saia um por passagem. Cada
    # clique rele /quest/, que tambem traz o nonce novo.
    _ck_lista "/quest/openChest/[0-9]+/"
    for _ck_i in 1 2; do
        if _ck_link "/quest/openChest/$_ck_i/?"; then
            fetch_page "$click"
            printf "Chest %s opened\n" "$_ck_i"
            fetch_page "/quest/"
            _ck_lista "/quest/openChest/[0-9]+/"
        fi
    done

    if [ "$FUNC_collect_mission_rewards" = "n" ]; then
        return
    fi

    _ck_i=0
    _ck_lista "/quest/end/[0-9]+"
    while [ "$_ck_i" -le 16 ]; do
        if _ck_link "/quest/end/${_ck_i}?"; then
            fetch_page "$click"
            printf "Mission %s Completed\n" "$_ck_i"
            fetch_page "/quest/"
            _ck_lista "/quest/end/[0-9]+"
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
    _ck_lista "/relic/reward/[0-9]+/"
    while [ "$_ck_i" -le 11 ]; do
        if _ck_link "/relic/reward/${_ck_i}/?"; then
            fetch_page "$click"
            printf "Relic %s collected\n" "$_ck_i"
            fetch_page "/relic/reward/"
            _ck_lista "/relic/reward/[0-9]+/"
        fi
        _ck_i=$((_ck_i + 1))
    done
    unset _ck_l
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
