#!/bin/sh
# setup.sh - Gerenciamento de contas do solucaoshell

# CORRECAO (seguranca): sem umask o accounts.conf nascia 644 (legivel por
# qualquer processo do mesmo UID no Termux).
umask 077

# Resolve o caminho real do script, seguindo links simbolicos.
#
# CORRECAO: era so "dirname $0". Chamado por um link simbolico (ou por um
# atalho em $PREFIX/bin), o SLSDIR apontava para a pasta do LINK e nao para
# a do repositorio — e o accounts.conf gravado era outro.
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

# O motor mora em lib/. Os comandos do usuario ficam na raiz; tudo que e
# biblioteca (worker, painel, modulos de batalha) e carregado daqui.
LIBDIR="$SLSDIR/lib"
export LIBDIR

unset _dir _self _link _hops

. "$LIBDIR/contas.sh"

ACCOUNTS_FILE=$(resolve_accounts_file)

# Carrega funcoes de verificacao de sessao
. "$LIBDIR/session_check.sh"

# Paleta sorteada a cada abertura do menu.
# A semente vem do PID e dos segundos do relogio, entao o conjunto de
# cores muda a cada execucao sem depender de $RANDOM (que nao existe
# em sh/dash/toybox).
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

    # LARGURA ADAPTATIVA A TELA DO CELULAR.
    #
    # A linha divisoria era fixa em 68 caracteres: em telas estreitas ela
    # estourava e quebrava em duas, e o caminho do arquivo (longo) piorava.
    # Aqui a largura vem do proprio terminal (stty size -> tput cols -> 40 de
    # reserva), entao a moldura cabe em qualquer aparelho. O teto de 60 evita
    # esticar demais num terminal largo de PC.
    _cols=$(stty size 2>/dev/null | awk '{print $2}')
    case "$_cols" in ''|*[!0-9]*) _cols=$(tput cols 2>/dev/null) ;; esac
    case "$_cols" in ''|*[!0-9]*) _cols=40 ;; esac
    [ "$_cols" -lt 16 ] && _cols=16
    [ "$_cols" -gt 60 ] && _cols=60
    _L=$(printf '%*s' "$_cols" '' | tr ' ' '-')

    # Reavalia a cada abertura: o arquivo pode ter sido criado por "Adicionar"
    # ou esvaziado por "Remover".
    ACCOUNTS_FILE=$(resolve_accounts_file)

    # Titulo centralizado numa linha so (32 colunas, ASCII).
    _pad=$(( (_cols - 32) / 2 )); [ "$_pad" -lt 0 ] && _pad=0
    printf "%b%s%b\n" "$A2" "$_L" "$RESET"
    printf "%*s%bSLS%b %b- Gerenciador de Contas -%b %bBR%b\n" "$_pad" '' \
           "$A1" "$RESET" "$DIM" "$RESET" "$WHITE" "$RESET"
    printf "%b%s%b\n\n" "$A2" "$_L" "$RESET"

    printf "   %b1%b - Listar contas\n"   "$A1" "$RESET"
    printf "   %b2%b - Adicionar conta\n" "$A1" "$RESET"
    printf "   %b3%b - Remover conta\n"   "$A1" "$RESET"
    printf "   %b4%b - Testar login\n\n"  "$A1" "$RESET"
    printf "   %b0%b - Sair\n\n"          "$DIM" "$RESET"

    # Aviso discreto SO quando o arquivo de contas nao esta no lugar padrao
    # (o velho diagnostico do "estou lendo o arquivo errado"). No uso normal
    # nada aparece, e o menu fica limpo.
    if [ "$ACCOUNTS_FILE" != "$SLSDIR/accounts.conf" ]; then
        printf "  %b(!) contas lidas de outro local%b\n\n" "$GOLD" "$RESET"
    fi

    printf "%b%s%b\n" "$A2" "$_L" "$RESET"
    printf "  %bOpcao:%b " "$WHITE" "$RESET"
}

list_accounts() {
    clear
    printf "${CYAN}=== Contas cadastradas ===${RESET}\n\n"
    if [ ! -f "$ACCOUNTS_FILE" ] || [ ! -s "$ACCOUNTS_FILE" ]; then
        printf "${RED}Nenhuma conta cadastrada ainda.${RESET}\n"
    else
        n=1
        while IFS='|' read -r srv user _enc || [ -n "$srv" ]; do
            case "$srv" in ''|\#*) continue ;; esac
            [ -z "$user" ] && continue
            url=$(server_url "$srv")
            tag=$(server_tag "$srv")
            printf "${GOLD}%d)${RESET} [%s] %-20s %s\n" "$n" "$tag" "$user" "$url"
            n=$((n + 1))
        done < "$ACCOUNTS_FILE"
    fi
    printf "\nENTER para voltar..."
    read -r _d
}

# Servidor unico: nao ha o que escolher.
show_servers() {
    printf "
${CYAN}Servidor: BR${RESET}
"
}

add_account() {
    clear
    printf "${CYAN}=== Adicionar conta ===${RESET}\n"
    show_servers
    srv=1

    url=$(server_url "$srv")
    tag=$(server_tag "$srv")

    printf "Usuario (%s): " "$url"
    read -r user
    user=$(printf %s "$user" | tr -d '[:cntrl:]')

    # CORRECAO: nao havia validacao. Um "|" no nome corrompe o formato
    # do accounts.conf e uma "/" quebra o caminho do diretorio da conta.
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

    printf "Senha: "
    # Ctrl+C na senha nao pode deixar o terminal sem eco.
    trap 'stty echo 2>/dev/null; printf "\n"; exit 130' INT TERM
    stty -echo 2>/dev/null
    # IFS= : sem ele o read tira espacos do comeco e do fim da senha.
    IFS= read -r pass
    stty echo 2>/dev/null
    trap - INT TERM
    printf "\n"
    [ -z "$pass" ] && printf "${RED}Senha vazia.${RESET}\n" && sleep 2 && return

    printf "Testando login em %s...\n" "$url"

    if test_login "https://$url" "$user" "$pass"; then
        encoded=$(printf "login=%s&pass=%s" "$user" "$pass" | base64 | tr -d '[:space:]')
        printf "%s|%s|%s\n" "$srv" "$user" "$encoded" >> "$ACCOUNTS_FILE"
        chmod 600 "$ACCOUNTS_FILE" 2>/dev/null
        printf "${GREEN}[OK] Conta [%s] %s adicionada!${RESET}\n" "$tag" "$user"
    else
        printf "${RED}Login nao confirmado automaticamente.${RESET}\n"
        printf "Isso pode ocorrer por bloqueio de IP no teste.\n"
        printf "Salvar mesmo assim? (y/n): "
        read -r force
        case "$force" in
            y|Y)
                encoded=$(printf "login=%s&pass=%s" "$user" "$pass" | base64 | tr -d '[:space:]')
                printf "%s|%s|%s\n" "$srv" "$user" "$encoded" >> "$ACCOUNTS_FILE"
                chmod 600 "$ACCOUNTS_FILE" 2>/dev/null
                printf "${GOLD}Conta salva sem validacao.${RESET}\n"
                ;;
            *) printf "Conta nao salva.\n" ;;
        esac
    fi

    unset pass encoded
    sleep 2
}

# Lista as contas numeradas, le o numero e deixa srv, user e encoded da
# escolhida. Lista e escolha saem da mesma contas_validas (contas.sh), entao
# o numero da tela e sempre a conta certa. Volta 1 se cancelou ou invalido.
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
    printf "${CYAN}=== Remover conta ===${RESET}\n\n"
    escolher_conta || return
    tag=$(server_tag "$srv")

    printf "Remover [%s] %s? (y/n): " "$tag" "$user"
    read -r confirm
    case "$confirm" in
        y|Y)
            # CORRECAO: "grep -v" trata o nome como REGEX. Um nome com
            # metacaractere (., *, [) removeria a conta errada. O awk abaixo
            # compara os campos 1 e 2 como texto literal.
            awk -F'|' -v s="$srv" -v u="$user" '!($1==s && $2==u)' \
                "$ACCOUNTS_FILE" > "$ACCOUNTS_FILE.tmp" && \
                mv "$ACCOUNTS_FILE.tmp" "$ACCOUNTS_FILE"
            acc_dir="$HOME/.sls/${tag}_${user}"
            # Derruba o worker: sem isto a conta sumia do painel e seguia
            # jogando ate o stop.sh. Depois do awk, para o painel (que le o
            # accounts.conf a cada volta) nao relancar.
            _pf="$HOME/.sls/status/${tag}_${user}"
            _pid=$(cat "$_pf.pid" 2>/dev/null)
            # .pid antes do kill: painel sem PID gravado nao relanca.
            rm -f "$_pf.pid" "$_pf.status"
            if worker_vivo "$_pid" "$acc_dir"; then
                kill -TERM "-$_pid" 2>/dev/null || kill -TERM "$_pid" 2>/dev/null
            fi
            unset _pf _pid
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
    printf "${CYAN}=== Testar login ===${RESET}\n\n"
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
        printf "${GREEN}[OK] Login confirmado.${RESET}\n"
    else
        printf "${RED}[FALHOU] Login nao confirmado.${RESET}\n"
        printf "Nota: pode ser bloqueio de IP. O bot pode funcionar mesmo assim.\n"
    fi
    unset lpass
    sleep 3
}

# Loop principal
while true; do
    show_menu
    read -r opt
    case "$opt" in
        1) list_accounts ;;
        2) add_account ;;
        3) remove_account ;;
        4) test_account ;;
        0) printf "\nSaindo...\n"; exit 0 ;;
    esac
done
