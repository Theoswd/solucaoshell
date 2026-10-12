# shellcheck disable=SC2148
# loginlogoff.sh - relogin automatico quando sessao expira

login_logoff() {
    PAGE=`run_curl "${URL}/user"`

    if is_logged_in "$PAGE"; then
        # Sessao confirmada: libera a varredura que vem logo depois (ver
        # servidor_mudo) mesmo que o ultimo descanso tenha ficado sem resposta.
        sessao_marcar
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
        # Painel ja atualizado com esta leitura: o atualiza_stats da varredura
        # logo depois pedia /user e /train de novo.
        date +%s > "$TMP/last_stats" 2>/dev/null
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
    # Credencial ilegivel: um POST vazio contaria no limite de logins por IP
    # e seria lido como senha recusada (o do_login ja confere isto).
    if [ -z "$creds" ]; then
        [ "$_ll_lock" = "1" ] && login_unlock
        unset _ll_lock
        printf "[%s] %s — ERRO: cript_file ilegivel\n" "$SLS_TAG" "$SLS_USER"
        return 1
    fi
    # Sem echo|sed: ver do_login (sls.sh).
    luser=${creds#login=}; luser=${luser%%"&pass="*}
    lpass=${creds#"login=${luser}&pass="}
    unset creds

    # Senha pelo stdin, fora do argv (ver sls.sh).
    printf %s "$lpass" | run_curl \
        --data-urlencode "login=${luser}" \
        --data-urlencode "pass@-" \
        "${URL}/?sign_in=1" > /dev/null
    _ll_rc=$?

    unset luser lpass

    # Um /user so, como no do_login. Aqui havia um "sleep 1" e um /user
    # descartado antes deste, com a trava global de login presa.
    PAGE=`run_curl "${URL}/user"`
    _ll_rc2=$?
    [ "$_ll_rc" -eq 0 ] && _ll_rc=$_ll_rc2

    # A trava cobre so a autenticacao. Liberar aqui garante que ela sai em
    # qualquer caminho — sucesso, recusa ou erro de rede.
    [ "$_ll_lock" = "1" ] && login_unlock
    unset _ll_lock

    # Rede (POST ou /user sem resposta) nao e senha recusada: mesma separacao
    # do do_login.
    if [ "$_ll_rc" -ne 0 ] || [ -z "$PAGE" ]; then LOGIN_ERRO=rede; else LOGIN_ERRO=credencial; fi
    unset _ll_rc _ll_rc2

    if is_logged_in "$PAGE"; then
        sessao_marcar
        printf "[%s] %s — reconectado\n" "$SLS_TAG" "$SLS_USER"
        _acc=`extract_username "$PAGE"`
        [ -n "$_acc" ] && ACC=`echo "$_acc" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'`
        # Energia e HP maximo so existem em /train: uma requisicao por
        # ciclo de start(), nao por minuto.
        fetch_train_stats 2>/dev/null
        parse_status "$PAGE"
        unset _acc
        messages_info
        date +%s > "$TMP/last_stats" 2>/dev/null
        clan_id
        return 0
    fi

    printf "[%s] %s — falha ao reconectar\n" "$SLS_TAG" "$SLS_USER"
    [ -n "$SLS_STATUS_FILE" ] && echo "login_retry" > "$SLS_STATUS_FILE"
    return 1
}
