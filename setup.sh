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

# Localiza o arquivo de contas — MESMA regra do play.sh.
#
# CORRECAO: o caminho vinha exclusivamente do diretorio do script, e as
# duas ferramentas podiam terminar em arquivos diferentes. Com mais de uma
# copia do repositorio no aparelho — o caso mais comum e clonar de novo
# depois de um problema — este menu anunciava "Contas cadastradas: 0"
# enquanto o ./play.sh subia as contas normalmente, sem nenhuma pista de
# que estavam lendo arquivos distintos.
#
# Agora, se o arquivo local nao existir, os lugares conhecidos sao
# procurados antes de desistir, e o caminho em uso e sempre exibido no
# menu. Um cadastro novo continua indo para o diretorio do repositorio.
resolve_accounts_file() {
    if [ -s "$SLSDIR/accounts.conf" ]; then
        printf '%s' "$SLSDIR/accounts.conf"
        return 0
    fi
    for _cand in "$HOME/solucaoshell/accounts.conf" \
                 "$HOME/.sls/accounts.conf"; do
        if [ -s "$_cand" ]; then
            printf '%s' "$_cand"
            unset _cand
            return 0
        fi
    done
    unset _cand
    printf '%s' "$SLSDIR/accounts.conf"
}

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

# ============================================================
#  SOMENTE SERVIDOR BR
#  O suporte aos outros 12 servidores foi removido a pedido.
#  O campo de servidor continua no accounts.conf (sempre "1")
#  para nao quebrar cadastros existentes.
# ============================================================
server_url()    { case "$1" in 1) printf %s ZnVyaWFkZXRpdGFzLm5ldA== | base64 -d ;; esac; }
server_tag()    { case "$1" in 1) echo "BR" ;; esac; }

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

    printf "%b%s%b\n" "$A2" "$_L" "$RESET"
    printf "  %bSLS%b %b· Gerenciador%b   %bBR%b\n" \
           "$A1" "$RESET" "$DIM" "$RESET" "$WHITE" "$RESET"
    printf "  %bMod Author: SB%b\n" "$DIM" "$RESET"
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

    # Verifica duplicata
    if [ -f "$ACCOUNTS_FILE" ] && grep -q "^${srv}|${user}|" "$ACCOUNTS_FILE" 2>/dev/null; then
        printf "${RED}Conta [%s] %s ja existe.${RESET}\n" "$tag" "$user"
        sleep 2; return
    fi

    printf "Senha: "
    stty -echo 2>/dev/null
    read -r pass
    stty echo 2>/dev/null
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

remove_account() {
    clear
    printf "${CYAN}=== Remover conta ===${RESET}\n\n"
    [ ! -f "$ACCOUNTS_FILE" ] || [ ! -s "$ACCOUNTS_FILE" ] && \
        printf "${RED}Nenhuma conta.${RESET}\n" && sleep 2 && return

    n=1
    while IFS='|' read -r srv user _enc || [ -n "$srv" ]; do
        case "$srv" in ''|\#*) continue ;; esac
        [ -z "$user" ] && continue
        tag=$(server_tag "$srv")
        printf "${GOLD}%d)${RESET} [%s] %s\n" "$n" "$tag" "$user"
        n=$((n + 1))
    done < "$ACCOUNTS_FILE"

    printf "\nNumero (0 = cancelar): "
    read -r choice
    [ "$choice" = "0" ] || [ -z "$choice" ] && return

    total=$(grep -c -E '^[0-9]+[|]' "$ACCOUNTS_FILE" 2>/dev/null)
    case "$total" in ''|*[!0-9]*) total=0 ;; esac
    case "$choice" in
        *[!0-9]*) printf "${RED}Invalido.${RESET}\n"; sleep 2; return ;;
    esac
    [ "$choice" -lt 1 ] || [ "$choice" -gt "$total" ] && \
        printf "${RED}Invalido.${RESET}\n" && sleep 2 && return

    # Extrai a linha escolhida (apenas linhas validas)
    line=$(grep '|' "$ACCOUNTS_FILE" | sed -n "${choice}p")
    srv=$(echo "$line" | cut -d'|' -f1)
    user=$(echo "$line" | cut -d'|' -f2)
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
            printf "${GREEN}Removida.${RESET}\n"
            acc_dir="$HOME/.sls/${tag}_${user}"
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
    [ ! -f "$ACCOUNTS_FILE" ] || [ ! -s "$ACCOUNTS_FILE" ] && \
        printf "${RED}Nenhuma conta.${RESET}\n" && sleep 2 && return

    n=1
    while IFS='|' read -r srv user _enc || [ -n "$srv" ]; do
        case "$srv" in ''|\#*) continue ;; esac
        [ -z "$user" ] && continue
        tag=$(server_tag "$srv")
        printf "${GOLD}%d)${RESET} [%s] %s\n" "$n" "$tag" "$user"
        n=$((n + 1))
    done < "$ACCOUNTS_FILE"

    printf "\nNumero: "
    read -r choice
    total=$(grep -c -E '^[0-9]+[|]' "$ACCOUNTS_FILE" 2>/dev/null)
    case "$total" in ''|*[!0-9]*) total=0 ;; esac
    case "$choice" in *[!0-9]*) printf "${RED}Invalido.${RESET}\n"; sleep 2; return ;; esac
    [ "$choice" -lt 1 ] || [ "$choice" -gt "$total" ] && \
        printf "${RED}Invalido.${RESET}\n" && sleep 2 && return

    line=$(grep '|' "$ACCOUNTS_FILE" | sed -n "${choice}p")
    srv=$(echo "$line" | cut -d'|' -f1)
    user=$(echo "$line" | cut -d'|' -f2)
    encoded=$(echo "$line" | cut -d'|' -f3)
    tag=$(server_tag "$srv")
    url=$(server_url "$srv")

    creds=$(echo "$encoded" | base64 -d 2>/dev/null)
    luser=$(echo "$creds" | sed 's/login=//;s/&pass=.*//')
    lpass=$(echo "$creds" | sed 's/.*&pass=//')
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
