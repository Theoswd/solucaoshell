#!/bin/sh
# play.sh - Orquestrador multi-contas do solucaoshell

# Seguranca: sem umask, ~/.sls e o accounts.conf nasceriam 755/644.
umask 077

# Resolve o caminho real do script, seguindo links simbolicos: chamado por
# um atalho em $PREFIX/bin, o SLSDIR tem de ser a pasta do repositorio.
_self="$0"
_hops=0
while [ -L "$_self" ] && [ "$_hops" -lt 20 ]; do
    _link=$(readlink "$_self")
    case "$_link" in
        /*) _self="$_link" ;;
        *)  _self="$(dirname "$_self")/$_link" ;;
    esac
    _hops=$((_hops + 1))
done
_dir=$(dirname "$_self")
SLSDIR=$(cd "$_dir" && pwd -P)

# Comandos do usuario na raiz; o motor (worker, painel, batalhas) em lib/.
LIBDIR="$SLSDIR/lib"
export LIBDIR

unset _dir _self _link _hops
export SLSDIR

. "$LIBDIR/contas.sh"

ACCOUNTS_FILE=$(resolve_accounts_file)

termux-wake-lock 2>/dev/null
# O wake-lock vale para o Termux inteiro: pedido uma vez aqui, workers e
# sls.sh (que herdam a variavel) nao repetem — cada pedido sobe um "am" do
# Android, no aparelho que mata a sessao acima de 32 processos. Rodados a
# mao, sem o play.sh, eles pedem o seu.
SLS_WAKELOCK=1
export SLS_WAKELOCK
STATUS_DIR="$HOME/.sls/status"

# --restart / -r : derruba e sobe tudo de novo. Sem ele, as contas que ja
# estao rodando sao preservadas e o play.sh so se acopla ao painel.
FORCE_RESTART=0
RUN=""
for _arg in "$@"; do
    case "$_arg" in
        --restart|-r) FORCE_RESTART=1 ;;
        *)            [ -z "$RUN" ] && RUN="$_arg" ;;
    esac
done
unset _arg
[ -z "$RUN" ] && RUN="-boot"

GREEN='\033[32m'
GOLD='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[01;36m'
YELLOW='\033[1;33m'
RESET='\033[00m'

mkdir -p "$STATUS_DIR"

# PID do orquestrador para o stop.sh (roda como "./play.sh", um pgrep por
# caminho absoluto nao casa). Um painel so: o ./play.sh novo encerra o
# anterior; os workers seguem rodando (o play.sh nao tem trap que derrube conta).
_orq=$(cat "$STATUS_DIR/orchestrator.pid" 2>/dev/null)
case "$_orq" in
    ''|*[!0-9]*|"$$") ;;
    *) grep -q 'play\.sh' "/proc/$_orq/cmdline" 2>/dev/null && kill -TERM "$_orq" 2>/dev/null ;;
esac
unset _orq
echo "$$" > "$STATUS_DIR/orchestrator.pid"
chmod 700 "$HOME/.sls" 2>/dev/null
[ -f "$ACCOUNTS_FILE" ] && chmod 600 "$ACCOUNTS_FILE" 2>/dev/null

chmod +x "$LIBDIR/worker.sh" "$LIBDIR/sls.sh" 2>/dev/null

# setsid torna o worker lider de grupo: sem isso, matar o worker deixa o
# sls.sh filho orfao e vivo, e a conta fica com duas sessoes no mesmo cookie.
if command -v setsid > /dev/null 2>&1; then
    SETSID="setsid"
else
    SETSID=""
fi

# Remove CR (accounts.conf editado no Windows) e caracteres de controle.
clean_field() {
    printf '%s' "$1" | tr -d '\r' | tr -d '\000-\037'
}

# Mata o worker E seus filhos (grupo), so se o PID ainda for o worker desta
# conta (kill -0 ve existencia, nao identidade: PID reciclado).
# $1=PID  $2=pasta da conta. Retorna 1 se nao era o worker.
kill_worker_tree() {
    kw_pid="$1"
    worker_vivo "$kw_pid" "$2" || return 1

    kill -TERM "-$kw_pid" 2>/dev/null || kill -TERM "$kw_pid" 2>/dev/null
    # Ate 2s, saindo assim que o worker terminar.
    _kw_n=0
    while [ "$_kw_n" -lt 10 ] && kill -0 "$kw_pid" 2>/dev/null; do
        sleep 0.2; _kw_n=$((_kw_n + 1))
    done
    unset _kw_n
    if kill -0 "$kw_pid" 2>/dev/null; then
        kill -KILL "-$kw_pid" 2>/dev/null || kill -KILL "$kw_pid" 2>/dev/null
    fi
    return 0
}

# Sobe o worker de uma conta.  $1=srv  $2=usuario  $3=credencial (opcional)
# Retorna 0 = subiu, 1 = falhou, 2 = ja estava rodando e foi mantida.
launch_worker() {
    lw_srv="$1"
    lw_user="$2"
    lw_enc="$3"

    lw_tag=$(server_tag "$lw_srv")
    lw_host=$(server_url "$lw_srv")
    [ -n "$lw_tag" ] && [ -n "$lw_host" ] || return 1

    lw_id="${lw_tag}_${lw_user}"
    lw_dir="$HOME/.sls/${lw_id}"
    lw_status="$STATUS_DIR/${lw_id}.status"
    lw_pidf="$STATUS_DIR/${lw_id}.pid"
    lw_log="$lw_dir/sls.log"

    mkdir -p "$lw_dir"
    chmod 700 "$lw_dir" 2>/dev/null

    [ ! -f "$lw_dir/userAgent.txt" ] && [ -f "$LIBDIR/userAgent.txt" ] && \
        cp "$LIBDIR/userAgent.txt" "$lw_dir/userAgent.txt"

    # Seguranca: a credencial nunca vai no argv (ficaria em /proc/PID/cmdline);
    # vai para arquivo modo 600 e o worker recebe so a pasta da conta.
    if [ -n "$lw_enc" ]; then
        printf '%s\n' "$lw_enc" > "$lw_dir/cript_file"
        chmod 600 "$lw_dir/cript_file"
    fi

    if [ ! -s "$lw_dir/cript_file" ]; then
        printf "   sem credencial para %s - pulando\n" "$lw_id"
        return 1
    fi

    # NAO derruba um worker vivo: rodar ./play.sh so para ver o painel nao
    # pode forcar varios logins simultaneos do mesmo IP (o servidor recusa a
    # rajada como "senha incorreta"). Reiniciar tudo: ./play.sh --restart
    if [ -f "$lw_pidf" ]; then
        lw_old=$(cat "$lw_pidf" 2>/dev/null)
        if [ "$FORCE_RESTART" != "1" ] && worker_vivo "$lw_old" "$lw_dir"; then
            printf "   ${GREEN}ja rodando${RESET} (PID %s) - mantida\n" "$lw_old"
            unset lw_old
            return 2
        fi
        kill_worker_tree "$lw_old" "$lw_dir"
        rm -f "$lw_pidf"
        unset lw_old
    fi

    # Limpa o modo salvo para que a flag de linha de comando vença num
    # inicio limpo (o cave.sh regrava em runtime se trocar de modo).
    rm -f "$lw_dir/runmode_file"

    echo "starting" > "$lw_status"

    # 3<&- : quem chama le o accounts.conf pelo fd 3 (o laco daqui e o do
    # painel); sem fechar, o worker e cada curl dele herdavam um descritor
    # aberto no arquivo com as credenciais de TODAS as contas.
    nohup $SETSID sh "$LIBDIR/worker.sh" \
        "$lw_srv" "$lw_user" "$lw_tag" \
        "https://${lw_host}" "$lw_dir" "$lw_status" "$RUN" \
        < /dev/null >> "$lw_log" 2>&1 3<&- &

    return 0
}

if [ ! -f "$ACCOUNTS_FILE" ] || [ ! -s "$ACCOUNTS_FILE" ]; then
    printf "${RED}Nenhuma conta cadastrada.${RESET}\n"
    printf "Execute: ${GOLD}./setup.sh${RESET}\n"
    exit 1
fi

# Conta so linhas de conta (nao as comentadas). Sem "|| echo 0": o grep -c
# ja imprime 0 ao sair com status 1.
total=$(grep -c -E '^[0-9]+\|' "$ACCOUNTS_FILE" 2>/dev/null)
case "$total" in *[!0-9]*) total=0 ;; esac
[ -z "$total" ] && total=0

printf "${CYAN}solucaoshell - %s conta(s)${RESET}\n" "$total"
# Mostra o accounts.conf so quando nao e o do repositorio: o
# resolve_accounts_file procura em outras pastas (pode ser de outra instalacao).
[ "$ACCOUNTS_FILE" = "$SLSDIR/accounts.conf" ] || \
    printf "${GOLD}Contas:${RESET} %s\n" "$ACCOUNTS_FILE"
printf "\n"

# Android 12+ mata a sessao inteira (SIGKILL) acima de ~32 processos filhos
# do Termux ("processos fantasma").
# Limpa workers orfaos de execucoes anteriores: com nohup+setsid eles
# sobrevivem ao SIGKILL da sessao e contam para esse limite. Morrem os que
# nenhum .pid em $STATUS_DIR conhece.
#
# O SUBSHELL DE UM WORKER VIVO NAO E ORFAO. Um "( ... ) &" ou "$( ... )" do
# sls.sh e um fork: tem PID novo e o MESMO cmdline do sls.sh. Matar esse
# processo cortava a requisicao em andamento (pagina vazia, "servidor sem
# resposta", acao de luta perdida) a cada ./play.sh com o bot no ar. Fica
# vivo quem tem o GRUPO (com setsid, todo descendente do worker tem o PID
# dele como grupo) ou o PAI entre os PIDs conhecidos.
limpa_orfaos() {
    # PIDs que os arquivos de estado conhecem, lidos uma vez.
    _lo_vivos=" "
    for _lo_f in "$STATUS_DIR"/*.pid; do
        [ -f "$_lo_f" ] || continue
        _lo_x=""; { read -r _lo_x < "$_lo_f"; } 2>/dev/null
        case "$_lo_x" in ''|*[!0-9]*) ;; *) _lo_vivos="$_lo_vivos$_lo_x " ;; esac
    done
    _lo_n=0
    for _lo_p in /proc/[0-9]*; do
        _lo_pid=${_lo_p#/proc/}
        case "$_lo_pid" in *[!0-9]*) continue ;; esac
        [ "$_lo_pid" = "$$" ] && continue
        [ -r "$_lo_p/cmdline" ] || continue
        case "$(tr '\0' ' ' < "$_lo_p/cmdline" 2>/dev/null)" in
            *"$LIBDIR/worker.sh"*|*"$LIBDIR/sls.sh"*) ;;
            *) continue ;;
        esac
        case "$_lo_vivos" in *" $_lo_pid "*) continue ;; esac
        # /proc/PID/stat: "PID (nome) ESTADO PAI GRUPO ..."; o nome pode ter
        # espaco e parentese, entao corta ate o ultimo ") ".
        _lo_st=""; { read -r _lo_st < "$_lo_p/stat"; } 2>/dev/null
        _lo_st=${_lo_st##*") "}
        set -- $_lo_st
        case "$_lo_vivos" in *" ${2:-x} "*|*" ${3:-x} "*) continue ;; esac
        kill -TERM "$_lo_pid" 2>/dev/null
        _lo_n=$((_lo_n + 1))
    done
    [ "$_lo_n" -gt 0 ] && \
        printf "${GOLD}%s processo(s) orfao(s) encerrado(s).${RESET}\n\n" "$_lo_n"
    unset _lo_n _lo_p _lo_pid _lo_f _lo_x _lo_vivos _lo_st
}
limpa_orfaos

# Modo economico de processos (limite de ~32 do Android): acima de 3 contas
# o espacamento entre requisicoes e o proprio tempo de rede, sem um "sleep"
# parado por conta.
if [ -d /data/data/com.termux ] && [ "$total" -gt 3 ] && [ -z "$SLS_PACING" ]; then
    SLS_PACING=0
    export SLS_PACING
fi

if [ -d /data/data/com.termux ] && [ "$total" -gt 3 ]; then
    # Ate 44 colunas (tela de celular no Termux). A linha do adb fica
    # inteira de proposito: e para copiar.
    printf "${YELLOW}AVISO (Android 12+)${RESET}\n"
    printf "  O sistema pode matar o bot com\n"
    printf "  SIGKILL (signal 9).\n"
    printf "  Deixe o Termux em\n"
    printf "  ${CYAN}Bateria > Sem restricoes${RESET}.\n"
    printf "  No PC, com o celular ligado por cabo:\n"
    printf "  ${CYAN}adb shell settings put global settings_enable_monitor_phantom_procs false${RESET}\n\n"
fi

n=0
n_kept=0

# O `read` devolve 1 no EOF sem quebra de linha final; o `|| [ -n "$srv" ]`
# processa essa ultima linha (que o grep -c acima conta).
while IFS='|' read -r srv user encoded <&3 || [ -n "$srv" ]; do
    srv=$(clean_field "$srv")
    user=$(clean_field "$user")
    encoded=$(clean_field "$encoded")

    case "$srv" in
        ''|\#*) continue ;;
        *[!0-9]*) continue ;;
    esac
    [ -z "$user" ] || [ -z "$encoded" ] && continue
    case "$user" in
        */*) printf "${RED}Nome invalido (contem barra): %s${RESET}\n" "$user"; continue ;;
    esac

    tag=$(server_tag "$srv")
    if [ -z "$tag" ]; then
        printf "${RED}Servidor desconhecido: %s - pulando${RESET}\n" "$srv"
        continue
    fi

    n=$((n + 1))
    acc_id="${tag}_${user}"
    log_file="$HOME/.sls/${acc_id}/sls.log"
    pid_file="$STATUS_DIR/${acc_id}.pid"

    printf "${GOLD}[%d/%d]${RESET} [%s] %s\n" "$n" "$total" "$tag" "$user"

    launch_worker "$srv" "$user" "$encoded"
    case "$?" in
        1) continue ;;
        2) n_kept=$((n_kept + 1)); continue ;;   # ja rodava, nao mexeu
    esac

    pid=""
    _w=0
    # Ate 5s, de 0,2 em 0,2s: o worker grava o PID como primeira acao.
    while [ -z "$pid" ] && [ "$_w" -lt 25 ]; do
        sleep 0.2
        { read -r pid < "$pid_file"; } 2>/dev/null
        _w=$((_w + 1))
    done
    printf "   PID: %s | Log: %s\n" "${pid:-FALHOU}" "$log_file"
    [ -z "$pid" ] && printf "   ${RED}AVISO: worker nao iniciou. Verifique %s${RESET}\n" "$log_file"

    # Espacamento entre contas: o servidor limita login por IP, e contas
    # autenticando juntas caem e reincidem em bloco no backoff.
    if [ "$n" -lt "$total" ]; then
        # Janela total de ~3 min qualquer que seja o numero de contas,
        # entre 3s e 15s por conta.
        _base=$(( 180 / total ))
        [ "$_base" -lt 3 ] && _base=3
        [ "$_base" -gt 15 ] && _base=15
        _jit=$(( _base + (n + $$) % 4 ))
        printf "   aguardando %ss antes da proxima conta\n" "$_jit"
        sleep "$_jit"
    fi

done 3< "$ACCOUNTS_FILE"

if [ "$n" -eq 0 ]; then
    printf "${RED}Nenhuma conta valida encontrada em accounts.conf${RESET}\n"
    printf "Verifique o formato: srv|usuario|credencial_base64\n"
    exit 1
fi

printf "\n${GREEN}%s conta(s): %s iniciada(s), %s ja rodando.${RESET}\n\n" \
    "$n" "$((n - n_kept))" "$n_kept"

# Contas processadas tem de bater com as do arquivo: divergir e uma conta
# cadastrada e nunca iniciada (linha malformada, nome com barra, servidor
# desconhecido); avisa em vez de passar em silencio.
if [ "$n" -lt "$total" ]; then
    printf "${RED}AVISO: %s conta(s) do arquivo nao foram iniciadas.${RESET}\n" \
        "$((total - n))"
    printf "  Confira linhas malformadas em: ${CYAN}%s${RESET}\n" "$ACCOUNTS_FILE"
    printf "  O formato de cada linha e: ${CYAN}servidor|usuario|credencial${RESET}\n\n"
fi
printf "Ver o painel:  ${CYAN}./status.sh${RESET}  (nao mexe nas contas)\n"
printf "Log de conta:  ${CYAN}tail -f ~/.sls/BR_NomeConta/sls.log${RESET}\n"
printf "Reiniciar:     ${CYAN}./play.sh --restart${RESET}\n"
printf "Parar tudo:    ${CYAN}./stop.sh${RESET}\n\n"

# ============================================================
#  PAINEL (panel.sh, compartilhado com o status.sh). Aqui em
#  modo supervisor: relanca worker que morrer.
# ============================================================
. "$LIBDIR/panel.sh"
PANEL_SUPERVISE=1
[ "$HAS_TTY" = 0 ] && echo "[monitor] supervisionando $n conta(s); painel oculto (sem terminal)"
painel_loop
