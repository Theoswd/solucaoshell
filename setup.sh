#!/bin/sh
# setup.sh - Gerenciamento de contas do solucaoshell

# Seguranca: sem umask o accounts.conf nasceria 644.
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

. "$LIBDIR/contas.sh"

ACCOUNTS_FILE=$(resolve_accounts_file)

. "$LIBDIR/session_check.sh"

# Paleta sorteada a cada abertura do menu, com semente do PID e do relogio
# ($RANDOM nao existe em sh/dash/toybox).
_seed=$(( ($$ + $(date +%s)) % 6 ))
case "$_seed" in
    0) A1='[1;36m'; A2='[1;34m' ;;
    1) A1='[1;35m'; A2='[1;31m' ;;
    2) A1='[1;32m'; A2='[1;33m' ;;
    3) A1='[1;33m'; A2='[0;33m' ;;
    4) A1='[1;34m'; A2='[1;35m' ;;
    *) A1='[1;31m'; A2='[1;36m' ;;
esac

GREEN='[1;32m'
GOLD='[1;33m'
RED='[1;31m'
CYAN="$A1"
DIM='[2m'
WHITE='[1;37m'
RESET='[0m'

show_menu() {
    clear
    medir_tela

    # Reavalia a cada abertura ("Adicionar"/"Remover" mudam o arquivo).
    ACCOUNTS_FILE=$(resolve_accounts_file)

    # Titulo centralizado numa linha so (27 colunas, ASCII; o emoji soma 3).
    _ti=""; _tw=27
    [ "$SETUP_EMOJI" = 1 ] && { _ti="🔱 "; _tw=30; }
    _pad=$(( (_cols - _tw) / 2 )); [ "$_pad" -lt 0 ] && _pad=0
    printf "%b%s%b\n" "$A2" "$_L" "$RESET"
    printf "%*s%s%bSLS%b %b- Gerenciador de Contas%b\n" "$_pad" '' "$_ti" \
           "$A1" "$RESET" "$WHITE" "$RESET"
    unset _ti _tw
    printf "%b%s%b\n\n" "$A2" "$_L" "$RESET"

    printf "   %b1%b - Listar Contas\n"   "$A1" "$RESET"
    printf "   %b2%b - Adicionar Conta\n" "$A1" "$RESET"
    printf "   %b3%b - Remover Contas\n"  "$A1" "$RESET"
    printf "   %b4%b - Testar Login\n\n"  "$A1" "$RESET"
    printf "   %b5%b - Atualizar Repositorio\n" "$A1" "$RESET"
    printf "   %b6%b - Modo de Batalha\n"       "$A1" "$RESET"
    printf "   %b7%b - Adicionar Aliados\n\n"   "$A1" "$RESET"
    printf "   %b0%b - Sair\n\n"          "$DIM" "$RESET"

    # Aviso so quando o arquivo de contas nao esta no lugar padrao.
    if [ "$ACCOUNTS_FILE" != "$SLSDIR/accounts.conf" ]; then
        printf "  %b%s contas lidas de outro local%b\n\n" "$GOLD" "${E_AVISO:-(!) }" "$RESET"
    fi

    rodape
}

# Largura do terminal em _cols (stty size -> tput cols -> 40 de reserva),
# entre 16 e 60 colunas, para a moldura caber na tela do celular; a linha
# da moldura em _L.
medir_tela() {
    _cols=$(stty size 2>/dev/null | awk '{print $2}')
    case "$_cols" in ''|*[!0-9]*) _cols=$(tput cols 2>/dev/null) ;; esac
    case "$_cols" in ''|*[!0-9]*) _cols=40 ;; esac
    [ "$_cols" -lt 16 ] && _cols=16
    [ "$_cols" -gt 60 ] && _cols=60
    _L=$(printf '%*s' "$_cols" '' | tr ' ' '-')
}

# Titulo de tela centralizado entre duas linhas.  $1 = texto (ASCII: o
# ${#} conta bytes no dash, e acento tiraria o titulo do centro)
# $2 = emoji da tela, so com o emoji ligado (carregar_icones).
titulo() {
    medir_tela
    _tt="$1"; _tw=${#1}
    # O emoji ocupa 2 colunas, mais o espaco depois dele.
    if [ "$SETUP_EMOJI" = 1 ] && [ -n "$2" ]; then _tt="$2 $1"; _tw=$((_tw + 3)); fi
    _pad=$(( (_cols - _tw) / 2 )); [ "$_pad" -lt 0 ] && _pad=0
    printf "%b%s%b\n" "$A2" "$_L" "$RESET"
    printf "%*s%b%s%b\n" "$_pad" '' "$A1" "$_tt" "$RESET"
    printf "%b%s%b\n\n" "$A2" "$_L" "$RESET"
    unset _tt _tw
}

# Emoji como no painel: so no modo 1 do lib/panel.sh. A escolha manual
# ganha (SLS_EMOJI=N no comando, depois "echo N > ~/.sls/emoji"); sem ela,
# Android/Termux fica sem emoji (muito aparelho nao tem a fonte e mostra
# caixa vazia) e o resto com (aparelho_android, em contas.sh). Na primeira
# abertura no Android o emoji_perguntar ja gravou a escolha.
setup_emoji() {
    _em="$SLS_EMOJI"
    if [ -z "$_em" ] && [ -r "$HOME/.sls/emoji" ]; then
        read -r _em < "$HOME/.sls/emoji" 2>/dev/null || :
    fi
    case "$_em" in 0|1|2) ;; *) _em="" ;; esac
    if [ -z "$_em" ]; then
        if aparelho_android; then _em=2; else _em=1; fi
    fi
    [ "$_em" = 1 ]
}

# Icones das mensagens. Sem emoji, o texto de sempre ([OK], [FALHOU]).
# So emoji de codepoint unico, sem seletor de variacao (U+FE0F): o
# terminal que ignora o seletor desenha caixa ou o glifo de texto.
carregar_icones() {
    if setup_emoji; then
        SETUP_EMOJI=1
        T_OK="✅"; T_FALHA="❌"
        E_OK="✅ "; E_ERR="❌ "; E_AVISO="🚨 "; E_PARA="🛑 "; E_ROLA="🔄 "; E_SOBE="🤖 "
    else
        SETUP_EMOJI=0
        T_OK="[OK]"; T_FALHA="[FALHOU]"
        E_OK=""; E_ERR=""; E_AVISO=""; E_PARA=""; E_ROLA=""; E_SOBE=""
    fi
}

# Emoji de cada modo, para o titulo da tela do modo.
modo_emoji() {
    case "$1" in -cv) echo "💀" ;; -cl) echo "🔥" ;; *) echo "🤖" ;; esac
}

# Linha de baixo e o "Opcao:" dos menus.
rodape() {
    printf "%b%s%b\n" "$A2" "$_L" "$RESET"
    printf "  %bOpcao:%b " "$WHITE" "$RESET"
}

list_accounts() {
    clear
    titulo "Contas Cadastradas" "📜"
    if [ ! -f "$ACCOUNTS_FILE" ] || [ ! -s "$ACCOUNTS_FILE" ]; then
        printf "${RED}Nenhuma conta cadastrada ainda.${RESET}\n"
    else
        n=1
        while IFS='|' read -r srv user _enc || [ -n "$srv" ]; do
            case "$srv" in ''|\#*) continue ;; esac
            [ -z "$user" ] && continue
            url=$(server_url "$srv")
            tag=$(server_tag "$srv")
            # Modo de batalha so quando nao e o normal (opcao 6).
            _m=$(modo_da_conta "$HOME/.sls/${tag}_${user}")
            [ -n "$_m" ] && _m=" ($(modo_nome "$_m"))"
            printf "${GOLD}%d)${RESET} [%s] %-20s %s%s\n" "$n" "$tag" "$user" "$url" "$_m"
            n=$((n + 1))
        done < "$ACCOUNTS_FILE"
    fi
    printf "\nENTER para voltar..."
    read -r _d
}

# Conta cadastrada nao joga sozinha: ou o bot ja esta no ar (o painel a sobe
# na volta seguinte), ou falta o ./play.sh.
aviso_subir() {
    if bot_no_ar; then
        printf "O bot ja esta rodando: a conta sobe sozinha em ate 1 minuto.\n"
    else
        printf "Para comecar a jogar: ${CYAN}./play.sh${RESET}\n"
    fi
}

# O play.sh (o painel que relanca as contas) esta no ar?
bot_no_ar() {
    _as=$(cat "$HOME/.sls/status/orchestrator.pid" 2>/dev/null)
    # .pid velho (play.sh morto): so vale se o PID ainda for um play.sh.
    case "$_as" in
        ''|*[!0-9]*) _as="" ;;
        *) grep -q 'play\.sh' "/proc/$_as/cmdline" 2>/dev/null || _as="" ;;
    esac
    [ -n "$_as" ]
}

show_servers() {
    printf "${CYAN}Servidores:${RESET}\n\n"
    printf "   %b1%b - Servidor Brasileiro\n" "$A1" "$RESET"
    printf "   %b2%b - Servidor Russo\n\n"    "$A1" "$RESET"
}

# Le a senha em $pass mostrando um * por tecla (backspace apaga). Sem
# terminal (o stty falha), le a linha inteira sem eco, como antes.
# $1 = pergunta ("Senha: "), escrita DEPOIS de desligar o eco: a senha
# digitada ou colada no instante em que a pergunta aparece nao vaza na tela.
ler_senha() {
    pass=""
    _stty=$(stty -g 2>/dev/null)
    if [ -z "$_stty" ] || ! stty -echo -icanon min 1 time 0 2>/dev/null; then
        stty -echo 2>/dev/null
        printf '%s' "$1"
        # IFS= : sem ele o read tira espacos do comeco e do fim da senha.
        IFS= read -r pass
        stty echo 2>/dev/null
        return 0
    fi
    printf '%s' "$1"
    _del=$(printf '\177'); _bs=$(printf '\010'); _cr=$(printf '\r')
    while :; do
        # Um byte por vez. O ENTER chega vazio: o $(...) tira a quebra de
        # linha (e o fim da entrada tambem para aqui).
        _c=$(dd bs=1 count=1 2>/dev/null)
        case "$_c" in
            ''|"$_cr") break ;;
            "$_del"|"$_bs")
                if [ -n "$pass" ]; then
                    pass=${pass%?}
                    printf '\b \b'
                fi ;;
            *[[:cntrl:]]*) ;;
            *) pass="$pass$_c"; printf '*' ;;
        esac
    done
    stty "$_stty" 2>/dev/null
    unset _c _del _bs _cr _stty
}

# Nome que o jogo mostra depois do login do test_login (ele deixa a pagina
# /user em _page), para provar que a conta entrou mesmo.
mostra_logado() {
    _nome=$(extract_username "$_page")
    [ -n "$_nome" ] && printf "Logado no jogo como: ${WHITE}%s${RESET}\n" "$_nome"
    unset _nome
}

# Le o servidor da conta nova em $srv. ENTER fica no BR (servidor 1).
escolher_servidor() {
    printf "Servidor [1]: "
    read -r srv
    srv=$(printf %s "$srv" | tr -d '[:space:][:cntrl:]')
    [ -n "$srv" ] || srv=1
    if [ -z "$(server_tag "$srv")" ]; then
        printf "${RED}Servidor invalido: %s${RESET}\n" "$srv"
        sleep 2
        return 1
    fi
}

add_account() {
    clear
    titulo "Adicionar Conta" "🥷"
    show_servers
    escolher_servidor || return

    url=$(server_url "$srv")
    tag=$(server_tag "$srv")

    printf "Usuario (%s): " "$url"
    read -r user
    user=$(printf %s "$user" | tr -d '[:cntrl:]')

    # Um "|" no nome corrompe o accounts.conf; uma "/" quebra o caminho da conta.
    case "$user" in
        *"|"*) printf "${RED}Nome nao pode conter | ${RESET}\n"; sleep 2; return ;;
        */*)   printf "${RED}Nome nao pode conter / ${RESET}\n"; sleep 2; return ;;
    esac
    [ -z "$user" ] && printf "${RED}Usuario vazio.${RESET}\n" && sleep 2 && return

    # Verifica duplicata (texto exato: "." ou "*" no nome nao sao curinga)
    if [ -f "$ACCOUNTS_FILE" ] && cut -d'|' -f1,2 "$ACCOUNTS_FILE" 2>/dev/null | tr -d '\r' | grep -qxF "${srv}|${user}"; then
        printf "${RED}Conta [%s] %s ja existe.${RESET}\n" "$tag" "$user"
        sleep 2; return
    fi

    # Conta que nao esta no accounts.conf: um "stopped" que sobrou dela
    # (removida antes) seguraria o painel de subi-la com o bot no ar.
    rm -f "$HOME/.sls/status/${tag}_${user}.status" 2>/dev/null

    # Ctrl+C na senha nao pode deixar o terminal sem eco (nem sem o ENTER).
    trap 'stty echo icanon 2>/dev/null; printf "\n"; exit 130' INT TERM
    ler_senha "Senha: "
    trap - INT TERM
    printf "\n"
    [ -z "$pass" ] && printf "${RED}Senha vazia.${RESET}\n" && sleep 2 && return

    printf "Testando login em %s...\n" "$url"

    if test_login "https://$url" "$user" "$pass"; then
        encoded=$(printf "login=%s&pass=%s" "$user" "$pass" | base64 | tr -d '[:space:]')
        printf "%s|%s|%s\n" "$srv" "$user" "$encoded" >> "$ACCOUNTS_FILE"
        chmod 600 "$ACCOUNTS_FILE" 2>/dev/null
        printf "${GREEN}%s Conta [%s] %s adicionada!${RESET}\n" "$T_OK" "$tag" "$user"
        mostra_logado
        aviso_subir
    else
        printf "${RED}%sLogin nao confirmado automaticamente.${RESET}\n" "$E_ERR"
        printf "Isso pode ocorrer por bloqueio de IP no teste.\n"
        printf "Salvar mesmo assim? (y/n): "
        read -r force
        case "$force" in
            y|Y)
                encoded=$(printf "login=%s&pass=%s" "$user" "$pass" | base64 | tr -d '[:space:]')
                printf "%s|%s|%s\n" "$srv" "$user" "$encoded" >> "$ACCOUNTS_FILE"
                chmod 600 "$ACCOUNTS_FILE" 2>/dev/null
                printf "${GOLD}%sConta salva sem validacao.${RESET}\n" "$E_AVISO"
                aviso_subir
                ;;
            *) printf "Conta nao salva.\n" ;;
        esac
    fi

    unset pass encoded
    sleep 2
}

# Lista as contas numeradas e deixa srv, user e encoded da escolhida (lista e
# escolha saem da mesma contas_validas). Volta 1 se cancelou ou invalido.
escolher_conta() {
    if [ -z "$(contas_validas)" ]; then
        printf "${RED}Nenhuma conta.${RESET}\n"; sleep 2; return 1
    fi
    _n=1
    contas_validas | while IFS='|' read -r srv user _enc; do
        printf "${GOLD}%d)${RESET} [%s] %s\n" "$_n" "$(server_tag "$srv")" "$user"
        _n=$((_n + 1))
    done

    printf "\nNumero (0 = cancelar): "
    read -r choice
    line=""
    case "$choice" in
        ''|0) return 1 ;;
        *[!0-9]*) ;;
        *) line=$(contas_validas | sed -n "${choice}p") ;;
    esac
    if [ -z "$line" ]; then
        printf "${RED}Invalido.${RESET}\n"; sleep 2; return 1
    fi
    srv=${line%%|*}; line=${line#*|}
    user=${line%%|*}; encoded=${line#*|}
}

remove_account() {
    clear
    titulo "Remover Contas" "💣"
    escolher_conta || return
    tag=$(server_tag "$srv")

    printf "Remover [%s] %s? (y/n): " "$tag" "$user"
    read -r confirm
    case "$confirm" in
        y|Y)
            # awk compara os campos 1 e 2 como texto literal ("grep -v" veria
            # o nome como regex e removeria a conta errada).
            awk -F'|' -v s="$srv" -v u="$user" '!($1==s && $2==u)' \
                "$ACCOUNTS_FILE" > "$ACCOUNTS_FILE.tmp" && \
                mv "$ACCOUNTS_FILE.tmp" "$ACCOUNTS_FILE"
            acc_dir="$HOME/.sls/${tag}_${user}"
            # Derruba o worker (senao seguiria jogando ate o stop.sh). Depois
            # do awk, para o painel (que le o accounts.conf) nao relancar.
            _pf="$HOME/.sls/status/${tag}_${user}"
            _pid=$(cat "$_pf.pid" 2>/dev/null)
            # "stopped" ANTES de apagar o .pid, e o .pid antes do kill. O
            # painel que ja abriu o accounts.conf antigo ve, sem .pid e sem
            # status, uma "conta nova" e a relancava; com "stopped" nao sobe.
            echo stopped > "$_pf.status" 2>/dev/null
            rm -f "$_pf.pid"
            if worker_vivo "$_pid" "$acc_dir"; then
                kill -TERM "-$_pid" 2>/dev/null || kill -TERM "$_pid" 2>/dev/null
            fi
            unset _pf _pid
            # A credencial (cript_file) e a sessao do jogo (cookie.txt) da
            # conta removida saem SEMPRE; antes so com o "y" abaixo, e a senha
            # ficava em ~/.sls depois de a conta sair do accounts.conf. Logs
            # e marcadores ficam a criterio da pergunta.
            # O modo de batalha (opcao 6) sai junto: a conta recadastrada
            # comeca no normal.
            rm -f "$acc_dir/cript_file" "$acc_dir/cookie.txt" \
                "$acc_dir/modo_batalha" 2>/dev/null
            printf "${GREEN}Removida.${RESET}\n"
            if [ -d "$acc_dir" ]; then
                printf "Remover dados em %s? (y/n): " "$acc_dir"
                read -r rd
                case "$rd" in y|Y) rm -rf "$acc_dir" && printf "Dados removidos.\n" ;; esac
            fi
            ;;
        *) printf "Cancelado.\n" ;;
    esac
    sleep 2
}

test_account() {
    clear
    titulo "Testar Login" "🎯"
    escolher_conta || return
    tag=$(server_tag "$srv")
    url=$(server_url "$srv")

    creds=$(printf '%s' "$encoded" | base64 -d 2>/dev/null)
    # Sem echo|sed: ver do_login (lib/sls.sh).
    luser=${creds#login=}; luser=${luser%%"&pass="*}
    lpass=${creds#"login=${luser}&pass="}
    unset creds

    printf "Testando [%s] %s...\n" "$tag" "$user"

    if test_login "https://$url" "$luser" "$lpass"; then
        printf "${GREEN}%s Login confirmado.${RESET}\n" "$T_OK"
        mostra_logado
    else
        printf "${RED}%s Login nao confirmado.${RESET}\n" "$T_FALHA"
        printf "Nota: pode ser bloqueio de IP. O bot pode funcionar mesmo assim.\n"
    fi
    unset lpass
    # ENTER em vez de 3s: da tempo de ler o nome com que a conta entrou.
    printf "\nENTER para voltar..."
    read -r _d
}

# ---- 5. Atualizar Repositorio ----------------------------------------------

atualizar_menu() {
    while true; do
        clear
        titulo "Atualizar Repositorio" "🔄"
        printf "   %b1%b - git pull pelo setup\n\n" "$A1" "$RESET"
        printf "   %b0%b - Voltar\n\n" "$DIM" "$RESET"
        rodape
        read -r _o
        case "$_o" in
            1) git_pull_setup ;;
            0|'') return ;;
        esac
    done
}

# Puxa o que mudou no GitHub, como no README: para o bot, "git pull
# --ff-only" e sobe de novo. Sem nada novo, nao para nada.
git_pull_setup() {
    clear
    titulo "Atualizar Repositorio" "🔄"
    if ! command -v git > /dev/null 2>&1 || [ ! -d "$SLSDIR/.git" ]; then
        printf "${RED}%sSem git, ou %s nao e um clone do repositorio.${RESET}\n" "$E_ERR" "$SLSDIR"
        sleep 3; return
    fi

    printf "Procurando atualizacao...\n"
    if ! git -C "$SLSDIR" fetch --quiet 2>/dev/null; then
        printf "${RED}%sNao consegui falar com o GitHub. Confira a internet.${RESET}\n" "$E_ERR"
        sleep 3; return
    fi
    _novos=$(git -C "$SLSDIR" rev-list --count HEAD..@{u} 2>/dev/null)
    case "$_novos" in
        ''|*[!0-9]*)
            printf "${RED}%sO repositorio nao tem um ramo remoto para atualizar.${RESET}\n" "$E_ERR"
            sleep 3; return ;;
        0)
            printf "${GREEN}%sJa esta na versao mais nova.${RESET}\n" "$E_OK"
            sleep 2; return ;;
    esac

    printf "\n${GOLD}%s%s atualizacao(oes):${RESET}\n" "$E_AVISO" "$_novos"
    git -C "$SLSDIR" log --oneline --no-decorate HEAD..@{u} 2>/dev/null | head -n 10
    printf "\n"

    printf "%sParando o bot...\n" "$E_PARA"
    sh "$SLSDIR/stop.sh"

    printf "\nAtualizando...\n"
    if git -C "$SLSDIR" pull --ff-only; then
        printf "${GREEN}%s Repositorio atualizado.${RESET}\n" "$T_OK"
    else
        # Arquivo mudado a mao na pasta (ou historico diferente): o pull
        # recusa e nada muda. O bot sobe de novo na versao que estava.
        printf "${RED}%sNao deu para atualizar: tem arquivo mudado na pasta.${RESET}\n" "$E_ERR"
        git -C "$SLSDIR" status --short 2>/dev/null | head -n 10
    fi
    chmod +x "$SLSDIR"/*.sh 2>/dev/null

    printf "\n%sSubindo o bot...\n" "$E_SOBE"
    sleep 2
    # O play.sh fica com o terminal (painel); o setup termina aqui.
    exec sh "$SLSDIR/play.sh"
}

# ---- 6. Modo de Batalha ----------------------------------------------------
#
# O modo fica por conta em ~/.sls/<TAG>_<nome>/modo_batalha: -cv (Caverna)
# ou -cl (Coliseu); sem o arquivo, o cronograma normal. O play.sh le esse
# arquivo ao subir cada conta (launch_worker), quando nao recebe um modo na
# linha de comando.

modo_nome() {
    case "$1" in -cv) echo "Caverna" ;; -cl) echo "Coliseu" ;; *) echo "Normal" ;; esac
}

# Modo salvo da conta (vazio = normal).  $1 = pasta da conta
modo_da_conta() {
    _md=""
    { read -r _md < "$1/modo_batalha"; } 2>/dev/null
    case "$_md" in -cv|-cl) printf '%s' "$_md" ;; esac
    unset _md
}

modo_menu() {
    while true; do
        clear
        titulo "Modo de Batalha" "🎮"
        printf "   %b1%b - Caverna\n" "$A1" "$RESET"
        printf "   %b2%b - Coliseu\n" "$A1" "$RESET"
        printf "   %b3%b - Normal (todos os eventos)\n\n" "$A1" "$RESET"
        printf "   %b0%b - Voltar\n\n" "$DIM" "$RESET"
        rodape
        read -r _o
        case "$_o" in
            1) aplicar_modo -cv ;;
            2) aplicar_modo -cl ;;
            3) aplicar_modo "" ;;
            0|'') return ;;
        esac
    done
}

# Para quem vai o modo $1: algumas contas ou todas.
aplicar_modo() {
    while true; do
        clear
        titulo "Modo $(modo_nome "$1")" "$(modo_emoji "$1")"
        printf "   %b1%b - Escolher contas\n" "$A1" "$RESET"
        printf "   %b2%b - Definir para todas\n\n" "$A1" "$RESET"
        printf "   %b0%b - Voltar\n\n" "$DIM" "$RESET"
        rodape
        read -r _o
        case "$_o" in
            1) escolher_contas "$1" || continue ;;
            2) _escolhidas=$(contas_validas) ;;
            0|'') return ;;
            *) continue ;;
        esac
        if [ -z "$_escolhidas" ]; then
            printf "${RED}Nenhuma conta cadastrada.${RESET}\n"; sleep 2; return
        fi
        gravar_modo "$1" "$_escolhidas"
        unset _escolhidas
        return
    done
}

# Lista as contas com o modo de cada uma e le varios numeros ("1 3" ou
# "1,3"). Deixa as linhas escolhidas em _escolhidas, na ordem do arquivo e
# cada conta uma vez so. Volta 1 se cancelou ou se um numero nao existe.
escolher_contas() {
    clear
    titulo "Modo $(modo_nome "$1")" "$(modo_emoji "$1")"
    if [ -z "$(contas_validas)" ]; then
        printf "${RED}Nenhuma conta.${RESET}\n"; sleep 2; return 1
    fi
    _n=1
    contas_validas | while IFS='|' read -r srv user _enc; do
        tag=$(server_tag "$srv")
        printf "${GOLD}%d)${RESET} [%s] %-20s %s\n" "$_n" "$tag" "$user" \
            "$(modo_nome "$(modo_da_conta "$HOME/.sls/${tag}_${user}")")"
        _n=$((_n + 1))
    done

    printf "\nNumeros das contas, ex: 1 3 (0 = cancelar): "
    read -r choice
    choice=$(printf '%s' "$choice" | tr ',;' '  ')
    case "$(printf '%s' "$choice" | tr -d ' ')" in ''|0) return 1 ;; esac
    _escolhidas=" "
    _total=$(contas_validas | wc -l | tr -d ' ')
    for _c in $choice; do
        case "$_c" in
            *[!0-9]*|0) _c="" ;;
            *) [ "$_c" -le "$_total" ] || _c="" ;;
        esac
        if [ -z "$_c" ]; then
            printf "${RED}Numero invalido.${RESET}\n"; sleep 2
            unset _total _c; _escolhidas=""; return 1
        fi
        _escolhidas="$_escolhidas$_c "
    done
    # Os numeros viram as linhas do accounts.conf (a mesma contas_validas
    # da lista acima, para o numero da tela ser a conta certa).
    _escolhidas=$(contas_validas | awk -v esc="$_escolhidas" \
        'index(esc, " " NR " ") > 0')
    unset _total _c _n
}

# Grava o modo $1 nas contas $2 (linhas do accounts.conf) e, com o bot no
# ar, oferece reiniciar as que estao rodando para valer na hora.
gravar_modo() {
    clear
    titulo "Modo $(modo_nome "$1")" "$(modo_emoji "$1")"
    _vivos=""
    _nv=0
    while IFS='|' read -r srv user _enc; do
        [ -n "$user" ] || continue
        tag=$(server_tag "$srv")
        acc_dir="$HOME/.sls/${tag}_${user}"
        _antes=$(modo_da_conta "$acc_dir")
        mkdir -p "$acc_dir" && chmod 700 "$acc_dir" 2>/dev/null
        if [ -n "$1" ]; then
            printf '%s\n' "$1" > "$acc_dir/modo_batalha"
        else
            rm -f "$acc_dir/modo_batalha"
        fi
        printf "${GREEN}[%s] %s: %s -> %s${RESET}\n" "$tag" "$user" \
            "$(modo_nome "$_antes")" "$(modo_nome "$1")"
        _pid=$(cat "$HOME/.sls/status/${tag}_${user}.pid" 2>/dev/null)
        if worker_vivo "$_pid" "$acc_dir"; then
            _vivos="$_vivos$_pid|$acc_dir
"
            _nv=$((_nv + 1))
        fi
    done <<FIM
$2
FIM

    printf "\n"
    if [ "$_nv" -eq 0 ]; then
        if bot_no_ar; then
            printf "Vale quando a conta subir.\n"
        else
            printf "Vale quando o bot subir: ${CYAN}./play.sh${RESET}\n"
        fi
    elif ! bot_no_ar; then
        # Sem o painel do play.sh ninguem relancaria a conta derrubada.
        printf "%s conta(s) rodando sem o painel. Para valer agora:\n" "$_nv"
        printf "${CYAN}./play.sh --restart${RESET}\n"
    else
        printf "Reiniciar %s conta(s) agora para valer? (y/n): " "$_nv"
        read -r _r
        case "$_r" in
            y|Y)
                # O .pid fica: o painel ve o worker morto e o relanca ja no
                # modo novo. Sem as marcas de relancamento ele nao espera a
                # pausa de quem cai seguido (relanca_espera, panel.sh). Varias
                # de uma vez nao fazem rajada: o login_lock (sls.sh) deixa uma
                # conta autenticar por vez.
                while IFS='|' read -r _pid acc_dir; do
                    [ -n "$_pid" ] || continue
                    rm -f "$acc_dir/.relancado" "$acc_dir/.relancado_n"
                    kill -TERM "-$_pid" 2>/dev/null || kill -TERM "$_pid" 2>/dev/null
                done <<FIM
$_vivos
FIM
                printf "%sReiniciando: as contas voltam no modo novo, uma por vez.\n" "$E_ROLA"
                ;;
            *) printf "Vale no proximo reinicio (${CYAN}./play.sh --restart${RESET}).\n" ;;
        esac
    fi
    unset _antes _pid _r _vivos _nv
    printf "\nENTER para voltar..."
    read -r _d
}

# ---- 7. Adicionar Aliados --------------------------------------------------
#
# Lista de IDs por servidor, comum a todas as contas dele (lib/allies.sh):
# ~/.sls/aliados_<TAG>.conf, linhas "j|ID" (jogador) ou "c|ID" (cla). O bot
# confere cada ID ja logado e grava os nomes em ~/.sls/aliados_<TAG>.nomes,
# que a lista daqui mostra. Os membros do cla de cada conta sao aliados sem
# cadastro.

servidor_nome() { case "$1" in 1) echo "Brasileiro" ;; 2) echo "Russo" ;; esac; }

aliados_menu() {
    while true; do
        clear
        titulo "Adicionar Aliados" "🤝"
        printf "   %b1%b - Adicionar jogador (ID)\n" "$A1" "$RESET"
        printf "   %b2%b - Adicionar cla (ID)\n" "$A1" "$RESET"
        printf "   %b3%b - Listar aliados\n" "$A1" "$RESET"
        printf "   %b4%b - Remover aliado\n\n" "$A1" "$RESET"
        printf "   %b0%b - Voltar\n\n" "$DIM" "$RESET"
        rodape
        read -r _o
        case "$_o" in
            1) aliado_adicionar j ;;
            2) aliado_adicionar c ;;
            3) aliados_listar ;;
            4) aliado_remover ;;
            0|'') return ;;
        esac
    done
}

# O ID de um numero ou de um link colado (/user/ID/ ou /clan/ID) em _id.
#   aliado_ler_id TIPO TEXTO   (TIPO j = jogador, c = cla; 1 = invalido)
aliado_ler_id() {
    _id=""
    _in=$(printf '%s' "$2" | tr -d '[:space:][:cntrl:]')
    case "$_in" in
        */user/*)
            if [ "$1" = c ]; then
                printf "${RED}%sEsse e o link de um jogador: use a opcao 1.${RESET}\n" "$E_ERR"; return 1
            fi
            _in=${_in#*/user/} ;;
        */clan/*)
            if [ "$1" = j ]; then
                printf "${RED}%sEsse e o link de um cla: use a opcao 2.${RESET}\n" "$E_ERR"; return 1
            fi
            _in=${_in#*/clan/} ;;
    esac
    _id=${_in%%[!0-9]*}
    # Depois do numero so pode vir "/" ou "?" do link (ex.: 473431/?show=).
    case "${_in#"$_id"}" in ''|/*|\?*) ;; *) _id="" ;; esac
    case "$_id" in ''|0*) _id="" ;; esac
    [ "${#_id}" -le 12 ] || _id=""
    if [ -z "$_id" ]; then
        printf "${RED}%sID invalido: %s${RESET}\n" "$E_ERR" "$2"; return 1
    fi
    unset _in
}

# Linhas validas da lista do servidor $1 (TAG), na ordem do arquivo.
aliados_validos() {
    # Sem a lista ainda: nada (o "<" de arquivo que nao existe reclama no dash).
    [ -f "$HOME/.sls/aliados_$1.conf" ] || return 0
    tr -d '\r ' < "$HOME/.sls/aliados_$1.conf" | grep -E '^[jc]\|[0-9]+$'
}

# Lista numerada do servidor $1 (TAG), com o que o bot achou de cada ID.
aliados_linhas() {
    aliados_validos "$1" | awk -F'|' -v nf="$HOME/.sls/aliados_$1.nomes" '
        BEGIN {
            while ((getline l < nf) > 0) {
                split(l, c, "|"); k = c[1] "|" c[2]
                if (c[1] == "j" || c[3] == "-") nome[k] = c[3]
                else membros[k]++
            }
        }
        {
            k = $1 "|" $2; i++
            if ($1 == "j") {
                tipo = "Jogador"
                d = (k in nome) ? (nome[k] == "-" ? "ID nao encontrado" : nome[k]) : "aguardando o bot"
            } else {
                tipo = "Cla    "
                d = (k in membros) ? membros[k] " membro(s)" : ((k in nome) ? "ID nao encontrado" : "aguardando o bot")
            }
            printf "%d) %s %-10s %s\n", i, tipo, $2, d
        }'
}

# Lista mudou: as contas do servidor $1 (TAG) refazem os aliados na proxima
# volta, sem esperar as 12h (marca "aliados3" do crono.sh).
aliados_avisar_bot() {
    for _d in "$HOME/.sls/$1_"*/; do
        [ -d "$_d" ] && rm -f "${_d}last_aliados3" 2>/dev/null
    done
    unset _d
}

aliado_adicionar() {
    clear
    if [ "$1" = j ]; then
        titulo "Adicionar Jogador Aliado" "🥷"; _qual="jogador"; _ex="473431 ou o link .../user/473431/"
    else
        titulo "Adicionar Cla Aliado" "👑"; _qual="cla"; _ex="2092 ou o link .../clan/2092"
    fi
    show_servers
    escolher_servidor || return
    tag=$(server_tag "$srv")

    printf "ID ou link do %s (ex.: %s): " "$_qual" "$_ex"
    read -r _txt
    aliado_ler_id "$1" "$_txt" || { sleep 2; return; }

    _conf="$HOME/.sls/aliados_${tag}.conf"
    mkdir -p "$HOME/.sls" && chmod 700 "$HOME/.sls" 2>/dev/null
    if aliados_validos "$tag" | grep -qxF "$1|$_id"; then
        printf "${GOLD}%sEsse %s ja esta na lista do servidor %s.${RESET}\n" \
            "$E_AVISO" "$_qual" "$(servidor_nome "$srv")"
        sleep 2; return
    fi
    printf '%s|%s\n' "$1" "$_id" >> "$_conf"
    chmod 600 "$_conf" 2>/dev/null
    aliados_avisar_bot "$tag"

    printf "\n${GREEN}%s %s %s adicionado ao servidor %s.${RESET}\n" \
        "$T_OK" "$_qual" "$_id" "$(servidor_nome "$srv")"
    printf "O bot confere o ID ja logado e busca o nome na proxima volta.\n"
    printf "Para ver o nome: 3 - Listar aliados.\n"
    unset _qual _ex _txt _conf
    printf "\nENTER para voltar..."
    read -r _d
}

aliados_listar() {
    clear
    titulo "Aliados" "🤝"
    _tem=0
    for _s in 1 2; do
        _t=$(server_tag "$_s")
        [ -n "$(aliados_validos "$_t")" ] || continue
        _tem=1
        printf "${WHITE}Servidor %s${RESET}\n" "$(servidor_nome "$_s")"
        aliados_linhas "$_t"
        printf "\n"
    done
    [ "$_tem" = 1 ] || printf "Nenhum aliado cadastrado.\n\n"
    printf "Os membros do cla de cada conta sao aliados sem cadastro.\n"
    unset _tem _s _t
    printf "\nENTER para voltar..."
    read -r _d
}

aliado_remover() {
    clear
    titulo "Remover Aliado" "💣"
    show_servers
    escolher_servidor || return
    tag=$(server_tag "$srv")
    if [ -z "$(aliados_validos "$tag")" ]; then
        printf "${RED}Nenhum aliado no servidor %s.${RESET}\n" "$(servidor_nome "$srv")"
        sleep 2; return
    fi
    printf "\n"
    aliados_linhas "$tag"
    printf "\nNumero (0 = cancelar): "
    read -r choice
    _l=""
    case "$choice" in
        ''|0) return ;;
        *[!0-9]*) ;;
        *) _l=$(aliados_validos "$tag" | sed -n "${choice}p") ;;
    esac
    if [ -z "$_l" ]; then
        printf "${RED}Invalido.${RESET}\n"; sleep 2; return
    fi
    case "$_l" in j*) _qual="jogador" ;; *) _qual="cla" ;; esac
    printf "Remover o %s %s? (y/n): " "$_qual" "${_l#?|}"
    read -r confirm
    case "$confirm" in
        y|Y)
            _conf="$HOME/.sls/aliados_${tag}.conf"
            # Compara a linha sem espaco e sem CR, como o aliados_validos.
            awk -v l="$_l" '{ x = $0; gsub(/[\r ]/, "", x) } x != l' "$_conf" \
                > "$_conf.tmp" && mv "$_conf.tmp" "$_conf"
            aliados_avisar_bot "$tag"
            printf "${GREEN}%s Removido: deixa de ser aliado na proxima volta de cada conta.${RESET}\n" "$T_OK"
            ;;
        *) printf "Cancelado.\n" ;;
    esac
    unset _l _qual _conf
    sleep 2
}

emoji_perguntar
carregar_icones

# Loop principal
while true; do
    show_menu
    read -r opt
    case "$opt" in
        1) list_accounts ;;
        2) add_account ;;
        3) remove_account ;;
        4) test_account ;;
        5) atualizar_menu ;;
        6) modo_menu ;;
        7) aliados_menu ;;
        0) printf "\nSaindo...\n"; exit 0 ;;
    esac
done
