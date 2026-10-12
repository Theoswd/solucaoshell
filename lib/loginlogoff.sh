# shellcheck disable=SC2148
# loginlogoff.sh - relogin automatico quando sessao expira

# A AUTENTICACAO, UMA SO PARA O LOGIN E A RECONEXAO.
#
# Era a mesma sequencia em duas copias, o do_login (sls.sh) e o login_logoff
# abaixo: credencial do cript_file, trava global de login, GET da pagina de
# login (vindo de outra pagina o servidor recusa a senha certa), POST com a
# senha pelo stdin (fora do argv, que aparece no ps) e o /user.
#   0 = os pedidos sairam. PAGE = o /user. LOGIN_ERRO=rede quando o POST ou
#       o /user ficou sem resposta (o curl falhou ou veio vazio), senao
#       LOGIN_ERRO=credencial: quem chama le a pagina e decide.
#   1 = credencial ilegivel. Nada sai: um POST vazio contaria no limite de
#       logins por IP e seria lido como senha recusada.
login_autenticar() {
    _la_creds=`base64 -d "$TMP/cript_file" 2>/dev/null`
    if [ -z "$_la_creds" ]; then
        printf "[%s] %s — ERRO: cript_file ilegivel\n" "$SLS_TAG" "$SLS_USER"
        LOGIN_ERRO=credencial
        unset _la_creds
        return 1
    fi
    # Sem echo|sed: o echo do dash interpreta "\", e uma senha com "\n" ou
    # "\c" chegava alterada ao servidor.
    luser=${_la_creds#login=}; luser=${luser%%"&pass="*}
    lpass=${_la_creds#"login=${luser}&pass="}
    unset _la_creds

    # A trava cobre so a autenticacao: sai antes de qualquer decisao, em todo
    # caminho (sucesso, recusa ou rede).
    type login_lock > /dev/null 2>&1 && login_lock
    run_curl "${URL}/?sign_in=1" > /dev/null 2>&1
    printf %s "$lpass" | run_curl \
        --data-urlencode "login=${luser}" \
        --data-urlencode "pass@-" \
        "${URL}/?sign_in=1" > /dev/null
    # O $? colado no POST: com outro comando no meio ele era o desse comando
    # (sempre 0), e uma falha de rede no POST virava senha recusada, que
    # escala a espera ate 15 min.
    _la_rc=$?
    unset luser lpass
    PAGE=`run_curl "${URL}/user" 2>/dev/null`
    _la_rc2=$?
    type login_unlock > /dev/null 2>&1 && login_unlock

    if [ "$_la_rc" -ne 0 ] || [ "$_la_rc2" -ne 0 ] || [ -z "$PAGE" ]; then
        LOGIN_ERRO=rede
    else
        LOGIN_ERRO=credencial
    fi
    unset _la_rc _la_rc2
    return 0
}

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

    # A TRAVA GLOBAL DE LOGIN TAMBEM NA RECONEXAO (ver login_autenticar).
    # Quando o servidor derruba varias sessoes de uma vez (15 contas no mesmo
    # IP), todas reconectavam no mesmo instante; o servidor estrangula a
    # rajada com a MESMA mensagem de "senha incorreta", e contas boas caiam
    # no backoff longo justo quando precisavam voltar.
    login_autenticar || return 1

    # Rede (POST ou /user sem resposta) nao e senha recusada: o log diz qual
    # foi, como o do_login separa.
    if [ "$LOGIN_ERRO" = rede ]; then _ll_porque="sem resposta do servidor"; else _ll_porque="login recusado"; fi

    if is_logged_in "$PAGE"; then
        unset _ll_porque
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

    printf "[%s] %s — falha ao reconectar (%s)\n" "$SLS_TAG" "$SLS_USER" "$_ll_porque"
    unset _ll_porque
    [ -n "$SLS_STATUS_FILE" ] && echo "login_retry" > "$SLS_STATUS_FILE"
    return 1
}
