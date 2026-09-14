# shellcheck disable=SC2148
# loginlogoff.sh - relogin automatico quando sessao expira

login_logoff() {
    PAGE=`run_curl "${URL}/user"`

    if is_logged_in "$PAGE"; then
        _acc=`extract_username "$PAGE"`
        [ -n "$_acc" ] && ACC=`echo "$_acc" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'`
        # A pagina /user ja esta em maos: aproveita para atualizar HP/MP
        # antes de descarta-la. Antes o PAGE era descartado aqui e o
        # messages_info imprimia campos vazios.
        # Energia e HP maximo so existem em /train: uma requisicao por
        # ciclo de start(), nao por minuto.
        fetch_train_stats 2>/dev/null
        parse_status "$PAGE"
        unset _acc PAGE
        messages_info
        clan_id
        return 0
    fi

    # SERVIDOR MUDO NAO E SESSAO EXPIRADA.
    #
    # O /user vazio (curl sem conexao) ou uma pagina que nao e do jogo caia
    # aqui como "sessao expirada": o cookie era APAGADO e o login refeito
    # contra um servidor que nao respondia — 557 "falha ao reconectar" nos
    # logs de 12/09, todas com erro de curl. So a pagina do jogo sem conta
    # (sessao_estado = deslogado) prova que a sessao caiu.
    if [ "`printf '%s' "$PAGE" | sessao_estado -`" != deslogado ]; then
        printf "[%s] %s — servidor sem resposta, sessao mantida (sem novo login)\n" \
            "$SLS_TAG" "$SLS_USER"
        servidor_mudo_marcar
        unset PAGE
        return 1
    fi

    printf "[%s] %s — sessao expirada, reconectando...\n" "$SLS_TAG" "$SLS_USER"
    rm -f "$TMP_COOKIE"

    cript_file="$TMP/cript_file"
    [ ! -f "$cript_file" ] && return 1

    # TRAVA GLOBAL DE LOGIN TAMBEM NA RECONEXAO.
    #
    # O do_login (sls.sh) ja serializa a autenticacao inicial, mas esta
    # reconexao nao pegava a trava. Com muitas contas isso importa: quando o
    # servidor derruba varias sessoes ao mesmo tempo — o caso comum com 15
    # contas no mesmo IP — todas reconectavam no mesmo instante. O servidor
    # estrangula essa rajada e responde com a MESMA mensagem de "senha
    # incorreta", entao contas boas caem no backoff longo e ficam fora do ar
    # justamente quando mais precisavam voltar.
    _ll_lock=0
    if type login_lock > /dev/null 2>&1; then
        login_lock
        _ll_lock=1
    fi

    # Mesmo motivo do do_login: a sessao precisa passar pela pagina de
    # login antes do POST, senao o servidor recusa a credencial correta.
    run_curl "${URL}/?sign_in=1" > /dev/null 2>&1

    creds=`base64 -d "$cript_file" 2>/dev/null`
    luser=`echo "$creds" | sed 's/login=//;s/&pass=.*//'`
    lpass=`echo "$creds" | sed 's/.*&pass=//'`
    unset creds

    # Senha pelo stdin, fora do argv (ver sls.sh).
    printf %s "$lpass" | run_curl \
        --data-urlencode "login=${luser}" \
        --data-urlencode "pass@-" \
        "${URL}/?sign_in=1" > /dev/null

    sleep 1

    run_curl \
        "${URL}/user" > /dev/null

    unset luser lpass

    # A trava cobre so a autenticacao. Liberar aqui garante que ela sai em
    # qualquer caminho — sucesso, recusa ou erro de rede.
    [ "$_ll_lock" = "1" ] && login_unlock
    unset _ll_lock

    PAGE=`run_curl "${URL}/user"`

    if is_logged_in "$PAGE"; then
        printf "[%s] %s — reconectado\n" "$SLS_TAG" "$SLS_USER"
        _acc=`extract_username "$PAGE"`
        [ -n "$_acc" ] && ACC=`echo "$_acc" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'`
        # Energia e HP maximo so existem em /train: uma requisicao por
        # ciclo de start(), nao por minuto.
        fetch_train_stats 2>/dev/null
        parse_status "$PAGE"
        unset _acc
        messages_info
        clan_id
        return 0
    fi

    printf "[%s] %s — falha ao reconectar\n" "$SLS_TAG" "$SLS_USER"
    [ -n "$SLS_STATUS_FILE" ] && echo "login_retry" > "$SLS_STATUS_FILE"
    return 1
}
