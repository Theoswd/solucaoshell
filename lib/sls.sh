#!/bin/sh
# shellcheck disable=SC1091
# sls.sh - Worker de conta individual (nao interativo)
# Executado pelo worker.sh

umask 077

# SLSDIR e LIBDIR chegam do worker.sh; o calculo e para quem chamar o sls.sh
# direto (o arquivo vive em lib/).
if [ -z "$LIBDIR" ]; then
    _d=$(dirname "$0")
    LIBDIR=$(cd "$_d" && pwd)
    unset _d
    export LIBDIR
fi
if [ -z "$SLSDIR" ]; then
    SLSDIR=$(cd "$LIBDIR/.." && pwd)
    export SLSDIR
fi

if [ -z "$SLS_SRV" ] || [ -z "$SLS_URL" ] || [ -z "$SLS_ACC_DIR" ]; then
    printf "ERRO: sls.sh deve ser chamado pelo worker.sh\n"
    exit 1
fi

URL="$SLS_URL"
UR="$SLS_SRV"
TMP="$SLS_ACC_DIR"
TMP_COOKIE="$TMP/cookie.txt"
export URL UR TMP TMP_COOKIE

# Servidor unico (BR): fuso fixo.
export TZ="America/Bahia"

mkdir -p "$TMP"
chmod 700 "$TMP" 2>/dev/null

[ -n "$SLS_STATUS_FILE" ] && echo "loading" > "$SLS_STATUS_FILE"

. "$LIBDIR/info.sh"
. "$LIBDIR/session_check.sh"

# Modo de execucao: o runmode_file e por conta (escrito pelo run.sh/cave.sh)
# e tem prioridade; o play.sh o apaga a cada lancamento, entao a flag de
# linha de comando ("$1") vence num inicio limpo.
if [ -s "$TMP/runmode_file" ]; then
    RUN=$(cat "$TMP/runmode_file" 2>/dev/null)
elif [ -n "$1" ]; then
    RUN="$1"
fi
[ -z "$RUN" ] && RUN='-boot'
export RUN

if [ -z "$SLS_WAKELOCK" ] && [ -d /data/data/com.termux/files/usr/share/doc ]; then
    termux-wake-lock 2>/dev/null
fi

cd "$SLSDIR" || exit 1
for _lib in \
    requeriments.sh loginlogoff.sh \
    flagfight.sh clanid.sh crono.sh arena.sh coliseum.sh \
    campaign.sh run.sh altars.sh clandmg.sh clanfight.sh \
    clancoliseum.sh clancommand.sh king.sh undying.sh trade.sh career.sh \
    cave.sh allies.sh check.sh league.sh clanquest.sh \
    specialevent.sh function.sh \
    blessing.sh
do
    [ -f "$LIBDIR/$_lib" ] && . "$LIBDIR/$_lib"
done
unset _lib

# load_config antes de qualquer language_setup: garante todas as chaves.
load_config

if [ ! -f "$TMP/userAgent.txt" ] && [ -f "$LIBDIR/userAgent.txt" ]; then
    cp "$LIBDIR/userAgent.txt" "$TMP/userAgent.txt"
fi
random_ua 2>/dev/null
[ -z "$vUserAgent" ] && vUserAgent="Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36"
export vUserAgent

[ ! -f "$TMP/allies.txt" ]  && : > "$TMP/allies.txt"
[ ! -f "$TMP/callies.txt" ] && : > "$TMP/callies.txt"

printf "[%s] %s — iniciando (modo %s)\n" "$SLS_TAG" "$SLS_USER" "$RUN"

# TRAVA GLOBAL DE LOGIN
#
# O servidor limita autenticacao por IP e, quando estrangula, responde com a
# MESMA mensagem de "senha incorreta". Aqui so uma conta autentica por vez.
# O mkdir e atomico em POSIX (o toybox nao tem flock). O PID de quem segura
# fica gravado: se o dono morrer, a trava e liberada.
LOCKDIR="$HOME/.sls/.login.lock"

login_lock() {
    _n=0
    _lk_meu=0
    # De 3 em 3s, teto de 180s; o login_espacar ja impoe 10s entre logins.
    while [ "$_n" -lt 60 ]; do
        if mkdir "$LOCKDIR" 2>/dev/null; then
            _lk_meu=1
            echo $$ > "$LOCKDIR/pid" 2>/dev/null
            # Dentro da trava: espaca este login do anterior (info.sh).
            type login_espacar > /dev/null 2>&1 && login_espacar
            return 0
        fi
        _dono=; { read -r _dono < "$LOCKDIR/pid"; } 2>/dev/null
        case "$_dono" in
            # PID ainda nao gravado: o dono esta a caminho de escrever.
            # Apagar aqui seria corrida (dois entrariam juntos). So espera.
            ''|*[!0-9]*) : ;;
            *) kill -0 "$_dono" 2>/dev/null || rm -rf "$LOCKDIR" 2>/dev/null ;;
        esac
        sleep 3
        _n=$((_n + 1))
    done
    # Nao conseguiu em 3 minutos: segue assim mesmo, para uma trava presa
    # nunca impedir a conta de tentar, mantendo ao menos o espacamento.
    type login_espacar > /dev/null 2>&1 && login_espacar
    return 0
}

# So apaga a trava quem a criou: senao o proximo da fila entraria junto com
# quem esta autenticando.
login_unlock() {
    type login_espacar_marcar > /dev/null 2>&1 && login_espacar_marcar
    [ "${_lk_meu:-0}" = 1 ] && rm -rf "$LOCKDIR" 2>/dev/null
    _lk_meu=0
}

do_login() {
    # REAPROVEITA A SESSAO EXISTENTE (PHPSESSID vale 30 dias): testar custa
    # um GET; autenticar custa dois e conta para o limite por IP.
    if [ -s "$TMP_COOKIE" ]; then
        # Distingue FALHA DE REDE (curl != 0) de CREDENCIAL RECUSADA: um
        # soluco de rede nao pode escalar a espera.
        PAGE=$(run_curl "${URL}/user" 2>/dev/null)
        _rc=$?
        if [ "$_rc" -ne 0 ] || [ -z "$PAGE" ]; then
            LOGIN_ERRO=rede
            unset PAGE
            return 1
        fi
        LOGIN_ERRO=credencial
        if is_logged_in "$PAGE"; then
            ACC=$(extract_username "$PAGE")
            [ -z "$ACC" ] && ACC="$SLS_USER"
            export ACC
            fetch_train_stats 2>/dev/null
            parse_status "$PAGE"
            messages_info
            printf "[%s] %s — sessao reaproveitada (sem novo login)
" "$SLS_TAG" "$ACC"
            unset PAGE
            return 0
        fi
        # Resposta que nao e pagina do jogo (erro do servidor, pagina
        # cortada) nao prova sessao morta: e rede, nao escala o backoff.
        if [ "`printf '%s' "$PAGE" | sessao_estado -`" != deslogado ]; then
            LOGIN_ERRO=rede
            unset PAGE
            return 1
        fi
        unset PAGE
    fi

    cript_file="$TMP/cript_file"
    if [ ! -s "$cript_file" ]; then
        printf "[%s] %s — ERRO: sem credenciais\n" "$SLS_TAG" "$SLS_USER"
        # Explicito para nao herdar o LOGIN_ERRO da tentativa anterior.
        LOGIN_ERRO=credencial
        return 1
    fi

    # Autenticacao (login_autenticar, em loginlogoff.sh): o GET de
    # /?sign_in=1 antes do POST e obrigatorio; vindo da home, o servidor
    # recusa a senha certa.
    login_autenticar || return 1

    if [ "$LOGIN_ERRO" = rede ]; then
        unset PAGE
        return 1
    fi
    if is_logged_in "$PAGE"; then
        ACC=$(extract_username "$PAGE")
        [ -z "$ACC" ] && ACC="$SLS_USER"
        export ACC
        # HP maximo muda pouco: busca uma vez por login, para o percentual.
        fetch_train_stats 2>/dev/null
        parse_status "$PAGE"
        # Grava a linha de status ja no login, para o func_cat ter o que exibir.
        messages_info
        printf "[%s] %s — login OK\n" "$SLS_TAG" "$ACC"
        unset PAGE
        return 0
    fi
    # Depois do POST, so a pagina do jogo sem conta e recusa de credencial.
    # Pagina de erro do servidor e rede: nao escala o backoff.
    if [ "`printf '%s' "$PAGE" | sessao_estado -`" != deslogado ]; then
        LOGIN_ERRO=rede
    fi
    unset PAGE
    return 1
}

login_delay=30
login_try=0
while true; do
    # Disjuntor aberto: o login espera a sonda (disjuntor_segura) em vez de
    # cada conta tentar a cada 20-40s.
    if disjuntor_segura; then
        [ -n "$SLS_STATUS_FILE" ] && echo "login_retry" > "$SLS_STATUS_FILE"
        sleep 20
        continue
    fi
    if do_login; then
        break
    fi

    # FALHA DE REDE nao escala o backoff: nao diz nada sobre a senha.
    if [ "${LOGIN_ERRO:-credencial}" = "rede" ]; then
        _wait=$(( 20 + ($$ % 20) ))
        printf "[%s] %s — servidor nao respondeu, nova tentativa em %ss\n" \
            "$SLS_TAG" "$SLS_USER" "$_wait"
        [ -n "$SLS_STATUS_FILE" ] && echo "login_retry" > "$SLS_STATUS_FILE"
        servidor_mudo_marcar
        sleep "$_wait"
        login_delay=30
        login_try=0
        # O COOKIE FICA: apagar transformaria cada soluco de rede num login
        # completo. Se estiver mesmo morto, o GET /user da proxima tentativa
        # mostra a pagina sem conta e o POST acontece normalmente.
        continue
    fi

    # CREDENCIAL RECUSADA: aqui sim o backoff cresce (insistir alimenta o
    # rate-limit do IP).
    login_try=$((login_try + 1))

    # Jitter: sem ele as contas que falham reincidem em bloco no mesmo instante.
    _half=$(( login_delay / 2 ))
    _wait=$(( _half + ( ($$ + login_try) % (_half + 1) ) ))

    printf "[%s] %s — login falhou (tentativa %s), nova tentativa em %ss\n" \
        "$SLS_TAG" "$SLS_USER" "$login_try" "$_wait"
    [ -n "$SLS_STATUS_FILE" ] && echo "login_retry" > "$SLS_STATUS_FILE"
    sleep "$_wait"

    # Escalada suave: o servidor recusa as vezes credencial correta com
    # varias contas no IP. Tres primeiras recusas: 60s; ate a 6a: 5 min;
    # depois 15 min.
    if   [ "$login_try" -le 3 ]; then _cap=60
    elif [ "$login_try" -le 6 ]; then _cap=300
    else                               _cap=900
    fi
    [ "$login_delay" -lt "$_cap" ] && login_delay=$((login_delay * 2))
    [ "$login_delay" -gt "$_cap" ] && login_delay=$_cap
    rm -f "$TMP_COOKIE"
done

clan_id 2>/dev/null

sls_start() {
    case "$RUN" in
        *-cv*) cave_start ;;
        *-cl*) sls_play ;;
        *)     sls_play ;;
    esac
}

# Limpa o estado de combate entre ciclos: links e limiares de uma luta nao
# podem vazar para a seguinte. So nomes que algum modulo ainda atribui.
func_unset() {
    unset ATK ATKRND DODGE HEAL RHP HLHP ACCESS CAVE BREAK
}

[ -n "$SLS_STATUS_FILE" ] && echo "running" > "$SLS_STATUS_FILE"

# LIGA DO DIA NA ENTRADA: a visita da Liga e as 00:30 (league.sh); com o bot
# desligado nesse horario, ela e feita aqui. Batalha para retomar e minuto de
# inscricao de evento vem primeiro. Modo caverna nao joga a Liga.
case "$RUN" in
    *-cv*) ;;
    *) if ! batalha_pendente && liga_fora_da_inscricao; then
           liga_do_dia
       fi ;;
esac

printf "[%s] %s — loop principal iniciado\n" "$SLS_TAG" "$ACC"

# PAUSA: nao desloga, o worker so deixa de agir e mantem a sessao.
#   $HOME/.sls/PAUSED   pausa todas as contas
#   $TMP/PAUSED         pausa somente esta conta

# Limite dos logs da conta (5 MB), conferido a cada 10 voltas. Copia e
# esvazia no lugar, sem mv: o processo continua escrevendo no arquivo que o
# play.sh abriu com ">>".
_rl_voltas=0
rotate_log() {
    _rl_voltas=$(( _rl_voltas + 1 ))
    [ $(( _rl_voltas % 10 )) -eq 1 ] || return 0
    for _lg in "$TMP/sls.log" "$TMP/ERROR_DEBUG"; do
        _sz=$(wc -c < "$_lg" 2>/dev/null)
        case "$_sz" in ''|*[!0-9]*) continue ;; esac
        [ "$_sz" -gt 5242880 ] && tail -c 1048576 "$_lg" > "$_lg.1" && : > "$_lg"
    done
    unset _lg _sz
}

while true; do
    if [ -f "$HOME/.sls/PAUSED" ] || [ -f "$TMP/PAUSED" ]; then
        [ -n "$SLS_STATUS_FILE" ] && echo "paused" > "$SLS_STATUS_FILE"
        sleep 30
        continue
    fi
    [ -n "$SLS_STATUS_FILE" ] && echo "running" > "$SLS_STATUS_FILE"
    rotate_log
    sls_start
done
