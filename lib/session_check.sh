#!/bin/sh
# session_check.sh

# Decide se a pagina recebida corresponde a uma sessao ativa.
#
# O sinal negativo e o FORMULARIO de login (so existe na pagina deslogada),
# nao a substring "sign_in" solta. O positivo e o icone de level, que so
# aparece logado:
#     <img src='/images/icon/level.png' alt=''/> 40 nivel
is_logged_in() {
    page="$1"
    [ -z "$page" ] && return 1

    # Rodape de toda pagina do jogo (ver sessao_estado): user=0 e visitante.
    # O /user anonimo e um 404 que nao traz formulario de login.
    case "$page" in
        *'jsInterface.event("user=0'[!0-9]*) return 1 ;;
        *'jsInterface.event("user='[1-9]*)   return 0 ;;
    esac

    if echo "$page" | grep -qiE "name=['\"]?pass['\"]?|action=[^>]*sign_in|[?&]sign_in=1"; then
        return 1
    fi

    echo "$page" | grep -q "icon/level\.png"     && return 0
    echo "$page" | grep -qi "\[level"            && return 0
    echo "$page" | grep -qiE "/logout|[?&]exit"  && return 0

    return 1
}

# Extrai o nome da conta da pagina logada: do <title> ou do <b> antes do
# icone de level (class='white' casa com numeros de status).
extract_username() {
    page="$1"

    # Sem processo: o texto depois do primeiro <title>, ate o "<" ou o fim da
    # linha, com ate 40 caracteres. Fora disso, o grep de sempre.
    acc=""
    case "$page" in
        *"<title>"*)
            acc=${page#*"<title>"}; acc=${acc%%"<"*}; acc=${acc%%"
"*}
            [ "${#acc}" -le 40 ] || acc="" ;;
    esac
    if [ -n "$acc" ]; then
        acc=${acc#"${acc%%[![:space:]]*}"}; acc=${acc%"${acc##*[![:space:]]}"}
    else
        acc=`printf '%s' "$page" | grep -o -E "<title>[^<]{1,40}" | head -n1 | sed 's/<title>//'`
        acc=`printf '%s' "$acc" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'`
    fi
    # Descarta titulos de erro (pagina 404/deslogada), que nao sao nome de conta.
    case "$acc" in
        *[Ee]rror*|*404*|*[Nn]ot*found*|"") acc="" ;;
    esac
    if [ -n "$acc" ]; then echo "$acc"; return; fi

    acc=`printf '%s' "$page" \
        | grep -o -E "<b>[^<]{1,30}</b> <img src='/images/icon/level\.png'" \
        | head -n1 | sed "s|<b>||;s|</b>.*||"`
    if [ -n "$acc" ]; then echo "$acc"; return; fi

    acc=`echo "$page" | grep -o -E "[A-Za-z0-9_.][A-Za-z0-9_. -]*\[level" \
        | sed 's/\[level//' | sed 's/[[:space:]]*$//' | head -n1`
    [ -n "$acc" ] && echo "$acc" && return

    acc=`echo "$page" | sed -n "s/.*href='\/user\/[0-9]*'>\([^<]*\)<\/a>.*/\1/p" | head -n1`
    [ -n "$acc" ] && echo "$acc" && return

    echo ""
}

test_login() {
    _url="$1"
    _user="$2"
    _pass="$3"

    # O Termux NAO tem /tmp (usa $PREFIX/tmp, em $TMPDIR).
    _cookie="${4:-${TMPDIR:-/tmp}/sls_test_$$.txt}"

    # A sessao precisa passar pela pagina de login antes do POST: vindo
    # direto, o servidor recusa a credencial correta.
    curl -sS -L --proto '=https' --proto-redir '=https' \
        --connect-timeout 15 --max-time 45 \
        -c "$_cookie" -b "$_cookie" "${_url}/?sign_in=1" > /dev/null


    # Senha pelo stdin, fora do argv (ver sls.sh).
    printf %s "$_pass" | curl -sS -L --proto '=https' --proto-redir '=https' \
        --connect-timeout 15 --max-time 45 \
        -c "$_cookie" -b "$_cookie" \
        --data-urlencode "login=${_user}" \
        --data-urlencode "pass@-" \
        "${_url}/?sign_in=1" > /dev/null

    _page=`curl -sS -L --proto '=https' --proto-redir '=https' \
        --connect-timeout 15 --max-time 45 \
        -c "$_cookie" -b "$_cookie" "${_url}/user"`

    rm -f "$_cookie"

    is_logged_in "$_page"
}
