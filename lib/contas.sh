# contas.sh - Arquivo de contas e servidor, comum a play.sh, setup.sh e status.sh
#
# Carregado depois de SLSDIR/LIBDIR definidos.

# Localiza o arquivo de contas. Sem o local, procura os lugares conhecidos
# (outra copia do repositorio no aparelho); cadastro novo vai para o
# diretorio do repositorio.
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

# Servidores: 1 = BR, 2 = RU (mesma engine; mapa do russo de 26/10/2026).
# O numero fica no accounts.conf; a sigla nomeia a pasta da conta (BR_x,
# RU_x), o status e o disjuntor, e o worker le dela o fuso e o que muda de
# um servidor para o outro (SLS_TAG).
server_url() {
    case "$1" in
        1) printf %s ZnVyaWFkZXRpdGFzLm5ldA== | base64 -d ;;
        2) printf %s dGl3YXIucnU= | base64 -d ;;
    esac
}
server_tag() { case "$1" in 1) echo "BR" ;; 2) echo "RU" ;; esac; }

# Contas do accounts.conf, na ordem do arquivo. O setup.sh usa esta mesma
# funcao para lista, contagem e escolha por numero (um filtro diferente
# desalinharia o numero da tela com a conta).
contas_validas() {
    tr -d '\r' < "$ACCOUNTS_FILE" 2>/dev/null | grep -E '^[0-9]+\|[^|]'
}

# O PID ainda e um worker deste bot, vivo?  $2 = pasta da conta (opcional)
# Confere a IDENTIDADE pelo cmdline: o kernel recicla PIDs.
worker_vivo() {
    wv_pid="$1"
    [ -n "$wv_pid" ] || return 1
    case "$wv_pid" in *[!0-9]*) return 1 ;; esac
    kill -0 "$wv_pid" 2>/dev/null || return 1
    [ -r "/proc/$wv_pid/cmdline" ] || return 0
    # Um processo so (o tr): o painel chama isto para cada conta a cada volta.
    wv_cl=$(tr '\0' '\n' < "/proc/$wv_pid/cmdline" 2>/dev/null)
    # Aceita worker.sh E sls.sh: o worker.sh faz exec do sls.sh, entao
    # depois da troca o PID e o mesmo mas o cmdline e o do sls.sh.
    case "$wv_cl" in *worker.sh*|*sls.sh*) ;; *) return 1 ;; esac
    # Com a pasta, confere tambem DE QUAL conta (apos reiniciar o aparelho, o
    # PID antigo de uma pode ser o worker novo de outra). Sem pasta no
    # cmdline e um sls.sh antigo: vale so o teste de cima.
    [ -n "$2" ] || return 0
    case "$wv_cl" in *"/.sls/"*) ;; *) return 0 ;; esac
    wv_nl='
'
    case "$wv_nl$wv_cl$wv_nl" in *"$wv_nl$2$wv_nl"*) return 0 ;; esac
    return 1
}

# E Android/Termux? PREFIX do Termux, "uname -o" ou getprop (so existe no
# Android): qualquer pista basta. A mesma regra do painel_e_android
# (panel.sh), que o painel guarda em cache.
aparelho_android() {
    case "${PREFIX:-}" in *com.termux*) return 0 ;; esac
    [ "`uname -o 2>/dev/null`" = "Android" ] && return 0
    command -v getprop > /dev/null 2>&1
}

# Tem gente olhando? (Termux:Boot e cron sobem sem terminal.)
tem_terminal() { [ -t 0 ] && [ -t 1 ]; }

# EMOJI NO APARELHO: o script nao enxerga a tela, e um aparelho sem fonte
# de emoji (Moto E22 e afins) mostra caixa vazia com o cursor andando as
# mesmas 2 colunas. Por isso, na primeira abertura no Android sem escolha
# gravada, mostra os emoji e pergunta uma vez; a resposta vai para
# ~/.sls/emoji (1 = emoji, 2 = simbolos), que o painel e o setup leem.
# Nao pergunta com SLS_EMOJI no comando, com escolha valida ja gravada,
# fora do Android (la o padrao e emoji) nem sem terminal.
emoji_perguntar() {
    [ -z "$SLS_EMOJI" ] || return 0
    _ep=""
    { read -r _ep < "$HOME/.sls/emoji"; } 2>/dev/null
    case "$_ep" in 0|1|2) unset _ep; return 0 ;; esac
    aparelho_android || { unset _ep; return 0; }
    tem_terminal || { unset _ep; return 0; }
    printf "\nTeste de emoji:  🔱  💀  🔥  ✅\n"
    printf "Aparecem 4 desenhos (e nao quadrados vazios)? (s/n): "
    read -r _ep
    mkdir -p "$HOME/.sls" 2>/dev/null
    case "$_ep" in
        s|S|y|Y) echo 1 > "$HOME/.sls/emoji"; printf "Emoji ligado.\n" ;;
        *)       echo 2 > "$HOME/.sls/emoji"; printf "Sem emoji: o bot usa simbolos.\n" ;;
    esac
    printf "Para trocar depois: ./status.sh -icones\n\n"
    # Uma vez so: da tempo de ler antes do menu limpar a tela.
    sleep 2
    unset _ep
}
