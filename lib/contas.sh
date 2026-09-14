# contas.sh - Arquivo de contas e servidor, comum a play.sh, setup.sh e status.sh
#
# Carregado depois de SLSDIR/LIBDIR definidos.

# Localiza o arquivo de contas.
#
# Com mais de uma copia do repositorio no aparelho, o ./setup.sh cadastrava
# num accounts.conf e o ./play.sh lia outro. Se o arquivo local nao existir,
# os lugares conhecidos sao procurados antes de desistir; um cadastro novo
# continua indo para o diretorio do repositorio.
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
