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

# Servidor unico (BR). O campo de servidor continua no accounts.conf (sempre
# "1") para nao quebrar cadastros existentes.
server_url() { case "$1" in 1) printf %s ZnVyaWFkZXRpdGFzLm5ldA== | base64 -d ;; esac; }
server_tag() { case "$1" in 1) echo "BR" ;; esac; }

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
