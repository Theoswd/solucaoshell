#!/bin/sh
# session_check.sh

# Decide se a pagina recebida corresponde a uma sessao ativa.
#
# CORRECAO: a versao anterior devolvia "nao logado" se a substring "sign_in"
# aparecesse em QUALQUER lugar da pagina (inclusive num link de rodape) e
# devolvia "logado" se aparecesse a palavra "exit" — generica demais. O
# resultado eram relogins desnecessarios e falsos positivos. Agora o sinal
# negativo e a presenca do FORMULARIO de login (campo de senha ou action de
# sign_in), que so existe na pagina deslogada.
# Decide se a pagina recebida corresponde a uma sessao ativa.
#
# CORRECAO 1: a versao original devolvia "nao logado" se a substring
# "sign_in" aparecesse em QUALQUER lugar da pagina, e "logado" se aparecesse
# a palavra "exit" — generica demais. O sinal negativo agora e a presenca do
# FORMULARIO de login, que so existe na pagina deslogada.
#
# CORRECAO 2: o marcador positivo era "[level" (entre colchetes), que NAO
# existe no HTML deste jogo. O que existe e o icone:
#     <img src='/images/icon/level.png' alt=''/> 40 nivel
# Com isso o teste caia no fallback generico "/user", presente ate em pagina
# deslogada. Agora usa o icone, que so aparece logado.
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

# Extrai o nome da conta da pagina logada.
#
# CORRECAO: a primeira tentativa era class='white', que no HTML atual casa
# com numeros de status — dai o log exibir coisas como "(40/40) - login OK"
# no lugar do nome. A pagina do usuario logado traz o nome em dois lugares
# confiaveis: no <title> e num <b> antes do icone de level.
extract_username() {
    page="$1"

    acc=`printf '%s' "$page" | grep -o -E "<title>[^<]{1,40}" | head -n1 | sed 's/<title>//'`
    acc=`printf '%s' "$acc" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'`
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

    # CORRECAO: o padrao era "/tmp/sls_test_$$.txt". O Termux NAO tem /tmp
    # (usa $PREFIX/tmp, exposto em $TMPDIR). O curl nao conseguia gravar o
    # cookie, a sessao se perdia entre as duas chamadas e o teste de login
    # falhava SEMPRE — todo mundo via "Login nao confirmado".
    _cookie="${4:-${TMPDIR:-/tmp}/sls_test_$$.txt}"

    # A sessao precisa passar pela pagina de login antes do POST.
    # Vindo direto, o servidor recusa a credencial correta com
    # "Nome de usuario ou senha digitado incorretamente".
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
