#!/bin/sh
# shellcheck disable=SC1091
# sls.sh - Worker de conta individual (nao interativo)
# Executado pelo worker.sh

umask 077

# Normalmente SLSDIR e LIBDIR chegam prontos do worker.sh. O calculo aqui
# e a rede de seguranca de quem chamar o sls.sh direto: o arquivo vive em
# lib/, entao a raiz e o diretorio de cima.
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

# Modo de execucao.
#
# CORRECAO (multi-contas): a versao anterior IGNORAVA o "$1" que o worker.sh
# passa e lia "$SLSDIR/runmode_file" — um arquivo unico, compartilhado por
# TODAS as contas. Resultado: "./play.sh -cv" e "-cl" nao tinham efeito, e
# uma conta trocando de modo trocava o modo de todas as outras.
# Agora: o runmode_file e por conta (escrito pelo run.sh/cave.sh em runtime)
# e tem prioridade; o play.sh o apaga a cada lancamento, entao a flag de
# linha de comando vence num inicio limpo.
if [ -s "$TMP/runmode_file" ]; then
    RUN=$(cat "$TMP/runmode_file" 2>/dev/null)
elif [ -n "$1" ]; then
    RUN="$1"
fi
[ -z "$RUN" ] && RUN='-boot'
export RUN

if [ -d /data/data/com.termux/files/usr/share/doc ]; then
    termux-wake-lock 2>/dev/null
fi

cd "$SLSDIR" || exit 1
for _lib in \
    requeriments.sh loginlogoff.sh \
    flagfight.sh clanid.sh crono.sh arena.sh coliseum.sh \
    campaign.sh run.sh altars.sh clandmg.sh clanfight.sh \
    clancoliseum.sh king.sh undying.sh trade.sh career.sh \
    cave.sh allies.sh check.sh league.sh clanquest.sh \
    specialevent.sh function.sh \
    blessing.sh
do
    [ -f "$LIBDIR/$_lib" ] && . "$LIBDIR/$_lib"
done
unset _lib


# CORRECAO: a ordem era language_setup depois load_config. Como o
# language_setup criava o config.cfg contendo so LANGUAGE=, o load_config
# encontrava o arquivo "ja existente" e nunca gravava os defaults. Agora o
# load_config vem primeiro e garante todas as chaves.
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

# Login com retry — delay crescente com jitter, nunca mata o worker
# TRAVA GLOBAL DE LOGIN
#
# O servidor limita autenticacao por IP e, quando estrangula,
# responde com a MESMA mensagem de "senha incorreta". Com varias
# contas subindo juntas, viram dezenas de POSTs de login em poucos
# minutos: contas boas passam a parecer contas com senha errada e
# caem no backoff longo.
#
# Medido com 10 contas: 5 a 8 recusas por conta, inclusive nas que
# depois entraram normalmente.
#
# Aqui so uma conta autentica por vez. O mkdir e atomico em POSIX,
# entao serve de trava sem precisar de flock (que o toybox nao tem).
# O PID de quem segura fica gravado: se o dono morrer, a trava e
# liberada em vez de bloquear todo mundo para sempre.
LOCKDIR="$HOME/.sls/.login.lock"

login_lock() {
    _n=0
    while [ "$_n" -lt 180 ]; do
        if mkdir "$LOCKDIR" 2>/dev/null; then
            echo $$ > "$LOCKDIR/pid" 2>/dev/null
            return 0
        fi
        _dono=`cat "$LOCKDIR/pid" 2>/dev/null`
        case "$_dono" in
            # PID ainda nao gravado: o dono acabou de criar a trava e
            # esta a caminho de escrever. Apagar aqui era uma corrida —
            # dois processos entravam ao mesmo tempo. So espera.
            ''|*[!0-9]*) : ;;
            *) kill -0 "$_dono" 2>/dev/null || rm -rf "$LOCKDIR" 2>/dev/null ;;
        esac
        sleep 1
        _n=$((_n + 1))
    done
    # Nao conseguiu em 3 minutos: segue assim mesmo, para uma trava
    # presa nunca impedir a conta de tentar.
    return 0
}

login_unlock() { rm -rf "$LOCKDIR" 2>/dev/null; }

do_login() {
    # REAPROVEITA A SESSAO EXISTENTE.
    #
    # O servidor manda Set-Cookie: PHPSESSID com Max-Age de 30 dias.
    # A versao anterior fazia um POST de login a cada inicializacao,
    # mesmo com a sessao ainda valida no cookie.txt. Com varias contas
    # reiniciando, isso gerava rajadas de autenticacao do mesmo IP — e o
    # servidor passa a recusar com a MESMA mensagem de "senha incorreta",
    # o que faz o problema parecer credencial errada quando nao e.
    #
    # Testar a sessao custa uma requisicao GET; autenticar custa duas e
    # conta para o limite. Na pratica isso elimina quase todos os logins.
    if [ -s "$TMP_COOKIE" ]; then
        # Distingue FALHA DE REDE de CREDENCIAL RECUSADA.
        #
        # O curl devolve codigo != 0 quando nao conseguiu falar com o
        # servidor (28 = timeout, 7 = conexao recusada, 6 = DNS). Isso
        # nao diz nada sobre a senha — e so o servidor tropecando ou a
        # rede oscilando. Tratar os dois casos igual fazia um soluco de
        # 10 segundos jogar a conta para 5 ou 15 minutos de espera.
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
        # cortada) nao prova sessao morta: e rede. Sem isto a conta ia para
        # o POST de login com o servidor tropecando — e uma recusa ali conta
        # como credencial, que escala a espera ate 15 min.
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
        # Explicito para nao herdar o LOGIN_ERRO da tentativa anterior: sem
        # credencial nao adianta reencurtar a espera como se fosse rede.
        LOGIN_ERRO=credencial
        return 1
    fi

    creds=$(base64 -d "$cript_file" 2>/dev/null)
    if [ -z "$creds" ]; then
        printf "[%s] %s — ERRO: cript_file ilegivel\n" "$SLS_TAG" "$SLS_USER"
        return 1
    fi
    luser=$(echo "$creds" | sed 's/login=//;s/&pass=.*//')
    lpass=$(echo "$creds" | sed 's/.*&pass=//')
    unset creds

    # O GET INICIAL PRECISA SER A PAGINA DE LOGIN, NAO A HOME.
    #
    # Esta linha ja foi "run_curl ${URL}/" e isso quebrou a autenticacao de
    # todas as contas. O servidor exige que a sessao passe pela pagina de
    # login (/?sign_in=1) antes de aceitar o POST de credencial; vindo da
    # home, ele responde "Nome de usuario ou senha digitado incorretamente"
    # mesmo com a senha certa — o que faz parecer credencial invalida.
    #
    # Comprovado alternando as duas formas com a mesma credencial:
    #   GET /            -> recusado   (2 de 2)
    #   GET /?sign_in=1  -> LOGOU      (2 de 2)
    #
    # A versao original do projeto enviava o POST de login DUAS vezes. Esse
    # primeiro POST parecia duplicacao inutil e foi removido, mas era ele que
    # inicializava o fluxo de login. Agora um GET na propria pagina de login
    # cumpre esse papel, sem enviar a credencial duas vezes.
    login_lock
    run_curl "${URL}/?sign_in=1" > /dev/null 2>&1

    # Senha pelo stdin (pass@-), nao na linha de comando do curl: o argv
    # fica visivel em /proc e no ps durante o login.
    printf %s "$lpass" | run_curl --data-urlencode "login=${luser}" \
             --data-urlencode "pass@-" \
             "${URL}/?sign_in=1" > /dev/null
    # O $? TEM de ser lido AQUI, colado no comando.
    #
    # CORRECAO (contas que ficam fora do ar com muitas contas): antes o
    # "unset luser lpass" vinha entre o POST e a leitura, entao "_rc2=$?"
    # capturava o status do UNSET — que e sempre 0. A deteccao de falha de
    # REDE no POST de login nunca disparava.
    #
    # O estrago aparece no backoff: uma falha de rede durante o POST (o caso
    # comum quando ha 15 contas do mesmo IP e o servidor estrangula) caia no
    # ramo "credencial", como se a senha estivesse errada. Esse ramo escala a
    # espera — 60s, depois 300s e depois 900s. Uma oscilacao de poucos
    # segundos jogava a conta para QUINZE MINUTOS parada, repetidamente, e o
    # painel a mostrava fora do ar quase o tempo todo.
    _rc2=$?
    unset luser lpass

    PAGE=$(run_curl "${URL}/user" 2>/dev/null)
    _rc3=$?

    # A trava cobre apenas a autenticacao. Liberar aqui, antes de
    # avaliar o resultado, garante que ela sai em qualquer caminho —
    # sucesso, recusa ou erro de rede.
    login_unlock

    if [ "$_rc2" -ne 0 ] || [ "$_rc3" -ne 0 ] || [ -z "$PAGE" ]; then
        LOGIN_ERRO=rede
        unset PAGE
        return 1
    fi
    LOGIN_ERRO=credencial
    if is_logged_in "$PAGE"; then
        ACC=$(extract_username "$PAGE")
        [ -z "$ACC" ] && ACC="$SLS_USER"
        export ACC
        # HP maximo muda pouco: busca uma vez por login, para o percentual.
        fetch_train_stats 2>/dev/null
        parse_status "$PAGE"
        # Grava a linha de status ja no login. Antes o msg_file so era
        # escrito dentro de start(), que roda apenas em minutos
        # especificos — entao o func_cat nao tinha o que exibir por
        # muito tempo, ou exibia um arquivo antigo.
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
    if do_login; then
        break
    fi

    # FALHA DE REDE nao escala o backoff.
    #
    # O curl devolve codigo != 0 quando nao conseguiu falar com o servidor
    # (28 timeout, 7 recusado, 6 DNS). Isso nao diz nada sobre a senha.
    # Tratar igual a uma credencial recusada fazia um soluco de poucos
    # segundos no servidor jogar a conta para 5 ou 15 minutos parada — e,
    # com varias contas subindo juntas, todas caiam nisso ao mesmo tempo.
    if [ "${LOGIN_ERRO:-credencial}" = "rede" ]; then
        _wait=$(( 20 + ($$ % 20) ))
        printf "[%s] %s — servidor nao respondeu, nova tentativa em %ss\n" \
            "$SLS_TAG" "$SLS_USER" "$_wait"
        [ -n "$SLS_STATUS_FILE" ] && echo "login_retry" > "$SLS_STATUS_FILE"
        servidor_mudo_marcar
        sleep "$_wait"
        login_delay=30
        login_try=0
        # O COOKIE FICA. Apagar aqui transformava cada soluco de rede num
        # login completo na tentativa seguinte: com o servidor voltando, as
        # 16 contas faziam POST de login em vez de reaproveitar a sessao de
        # 30 dias (visto em 12/09 18:18: 16 "login OK", 0 "reaproveitada").
        # Se o cookie estiver mesmo morto, o GET /user da proxima tentativa
        # mostra a pagina sem conta e o POST acontece normalmente.
        continue
    fi

    # CREDENCIAL RECUSADA: aqui sim o backoff cresce, porque insistir de
    # segundo em segundo com senha errada so alimenta o rate-limit do IP.
    login_try=$((login_try + 1))

    # Jitter: sem ele todas as contas que falham reincidem EM BLOCO no
    # mesmo instante, do mesmo IP. Backoff sem aleatoriedade nao dispersa
    # carga, apenas a agenda.
    _half=$(( login_delay / 2 ))
    _wait=$(( _half + ( ($$ + login_try) % (_half + 1) ) ))

    printf "[%s] %s — login falhou (tentativa %s), nova tentativa em %ss\n" \
        "$SLS_TAG" "$SLS_USER" "$login_try" "$_wait"
    [ -n "$SLS_STATUS_FILE" ] && echo "login_retry" > "$SLS_STATUS_FILE"
    sleep "$_wait"

    # A partir da 4a recusa o teto sobe para 15 min.
    # ESCALADA SUAVE NO INICIO.
    #
    # Medido: uma conta com credencial CORRETA e recusada em cerca de
    # 1 de cada 3 tentativas. Tres diagnosticos seguidos na mesma conta
    # deram recusado / funcionou / funcionou. Ou seja, uma recusa
    # isolada nao prova senha errada — o servidor simplesmente nega as
    # vezes quando ha varias contas do mesmo IP no ar.
    #
    # Escalar para 5 ou 15 minutos ja na segunda recusa deixava uma
    # conta boa parada por muito tempo a toa. As tres primeiras
    # recusas agora tem espera curta; a escalada so vale para o caso
    # em que a recusa e mesmo persistente.
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

# Limpa o estado de combate entre ciclos.
# CORRECAO: a lista nao incluia CLD, FULL, RHP, HLHP, NOWHP, NOWMP, HPPER,
# MPPER nem ACCESS, entao valores velhos vazavam para o ciclo seguinte e
# contaminavam decisoes de cura/ataque.
func_unset() {
    unset HP1 HP2 YOU USER CLAN ENTER ATK ATKRND DODGE HEAL GRASS STONE \
          BEXIT OUTGATE LEAVEFIGHT WDRED CAVE BREAK NEWCAVE \
          FULL RHP HLHP ACCESS SHIELD UNRIP KINGATK
}

[ -n "$SLS_STATUS_FILE" ] && echo "running" > "$SLS_STATUS_FILE"

# LIGA DO DIA NA ENTRADA.
#
# A visita da Liga e as 00:30 (league.sh). Com o bot desligado nesse
# horario, ela e feita aqui, logo depois do login: recompensa e cinco lutas.
# Ja feita no dia, o marcador fecha a Liga e nada acontece. Batalha para
# retomar e minuto de inscricao de evento vem primeiro — nesses casos a
# varredura seguinte faz a Liga. Modo caverna nao joga a Liga.
case "$RUN" in
    *-cv*) ;;
    *) if ! batalha_pendente && liga_fora_da_inscricao; then
           liga_do_dia
       fi ;;
esac

printf "[%s] %s — loop principal iniciado\n" "$SLS_TAG" "$ACC"

# PAUSA
#
# Pausar nao desloga: o worker apenas deixa de agir e continua vivo,
# com a sessao intacta. Ao retomar, ele volta de onde parou sem
# precisar autenticar de novo.
#
#   $HOME/.sls/PAUSED   pausa todas as contas
#   $TMP/PAUSED         pausa somente esta conta
while true; do
    if [ -f "$HOME/.sls/PAUSED" ] || [ -f "$TMP/PAUSED" ]; then
        [ -n "$SLS_STATUS_FILE" ] && echo "paused" > "$SLS_STATUS_FILE"
        sleep 30
        continue
    fi
    [ -n "$SLS_STATUS_FILE" ] && echo "running" > "$SLS_STATUS_FILE"
    sls_start
done
