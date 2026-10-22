# shellcheck disable=SC2148
# loginlogoff.sh - relogin automatico quando sessao expira

# A AUTENTICACAO, UMA SO PARA O LOGIN (do_login) E A RECONEXAO.
#
# Credencial do cript_file, trava global de login, GET de /?sign_in=1 (vindo
# de outra pagina o servidor recusa a senha certa), POST com a senha pelo
# stdin (fora do argv, que aparece no ps) e o /user.
#   0 = os pedidos sairam. PAGE = o /user. LOGIN_ERRO=rede quando o POST ou
#       o /user ficou sem resposta, senao LOGIN_ERRO=credencial: quem chama
#       le a pagina e decide.
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
    # O $? colado no POST: com outro comando no meio, uma falha de rede no
    # POST viraria senha recusada.
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

# RECONEXAO COM ESPERA CRESCENTE. Login recusado em sequencia virava rajada
# (162 POSTs em 1h medidos, de tres caminhos: painel, descanso e start), e o
# servidor pune justamente a rajada do mesmo IP. Falhou: a proxima tentativa
# so depois de 60s, 300s e 900s (a escada do login inicial, sls.sh); rede sem
# resposta, 60s. Reconectou, ou uma pagina provou a sessao (sessao_marcar):
# a escada zera.   $TMP/reconn_falha = "falhas epoch_da_proxima_tentativa"
reconexao_em_espera() {
    _re_n=0; _re_ate=0; { read -r _re_n _re_ate < "$TMP/reconn_falha"; } 2>/dev/null
    case "$_re_ate" in ''|*[!0-9]*) _re_ate=0 ;; esac
    _re_t=`date +%s`
    # Marca mais de 1h adiante e relogio voltando: nao trava a conta.
    if [ "$_re_t" -lt "$_re_ate" ] && [ $(( _re_ate - _re_t )) -le 3600 ]; then
        RECONN_FALTA=$(( _re_ate - _re_t ))
        unset _re_n _re_ate _re_t; return 0
    fi
    unset _re_n _re_ate _re_t
    return 1
}
reconexao_falhou() {   # rede|credencial
    _re_n=0; _re_ate=0; { read -r _re_n _re_ate < "$TMP/reconn_falha"; } 2>/dev/null
    case "$_re_n" in ''|*[!0-9]*) _re_n=0 ;; esac
    _re_n=$(( _re_n + 1 ))
    if [ "$1" = rede ]; then _re_e=60
    else case "$_re_n" in 1) _re_e=60 ;; 2) _re_e=300 ;; *) _re_e=900 ;; esac
    fi
    echo "$_re_n $(( `date +%s` + _re_e ))" > "$TMP/reconn_falha" 2>/dev/null
    printf "[%s] %s — nova tentativa de reconexao em %ss\n" "$SLS_TAG" "$SLS_USER" "$_re_e"
    unset _re_n _re_ate _re_e
}

login_logoff() {   # [inicio]
    # Do start() (inicio) com a Home do descanso viva ha menos de 5 min: a
    # sessao ja esta provada e o /user seria so a mesma prova (67 por dia). O
    # painel tem o atualiza_stats. O descanso apaga o .home_ok quando a acha
    # caida, entao uma prova velha nao vale.
    if [ "$1" = inicio ]; then
        _ll_ok=0; { read -r _ll_ok < "$TMP/.home_ok"; } 2>/dev/null
        case "$_ll_ok" in ''|*[!0-9]*) _ll_ok=0 ;; esac
        if type agora_s > /dev/null 2>&1; then agora_s; _ll_t=$_AGORA; else _ll_t=`date +%s`; fi
        if [ "$_ll_ok" -gt 0 ] && [ $(( _ll_t - _ll_ok )) -ge 0 ] && [ $(( _ll_t - _ll_ok )) -lt 300 ]; then
            unset _ll_ok _ll_t
            clan_id
            return 0
        fi
        unset _ll_ok _ll_t
    fi
    PAGE=`run_curl "${URL}/user"`

    if is_logged_in "$PAGE"; then
        # Sessao confirmada: libera a varredura logo depois (ver servidor_mudo).
        sessao_marcar
        _acc=`extract_username "$PAGE"`
        [ -n "$_acc" ] && ACC=`echo "$_acc" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'`
        # Aproveita o /user em maos para HP/MP; energia e HP maximo so
        # existem em /train (uma requisicao por ciclo de start()).
        fetch_train_stats 2>/dev/null
        parse_status "$PAGE"
        unset _acc PAGE
        messages_info
        # Painel ja atualizado: poupa o /user e /train do atualiza_stats.
        date +%s > "$TMP/last_stats" 2>/dev/null
        clan_id
        return 0
    fi

    # SERVIDOR MUDO NAO E SESSAO EXPIRADA: so a pagina do jogo sem conta
    # (sessao_estado = deslogado) prova que a sessao caiu. Senao o cookie fica.
    if [ "`printf '%s' "$PAGE" | sessao_estado -`" != deslogado ]; then
        printf "[%s] %s — servidor sem resposta, sessao mantida (sem novo login)\n" \
            "$SLS_TAG" "$SLS_USER"
        servidor_mudo_marcar
        unset PAGE
        return 1
    fi

    # Falhou ha pouco: nada de POST agora (nem apagar o cookie).
    if reconexao_em_espera; then
        printf "[%s] %s — sessao caida; reconexao em espera (%ss)\n" "$SLS_TAG" "$SLS_USER" "$RECONN_FALTA"
        unset PAGE RECONN_FALTA
        return 1
    fi

    printf "[%s] %s — sessao expirada, reconectando...\n" "$SLS_TAG" "$SLS_USER"
    rm -f "$TMP_COOKIE"

    cript_file="$TMP/cript_file"
    [ ! -f "$cript_file" ] && return 1

    # A trava global de login vale tambem na reconexao (login_autenticar):
    # sessoes derrubadas juntas reconectariam no mesmo instante.
    login_autenticar || { reconexao_falhou credencial; return 1; }

    # Rede nao e senha recusada: o log diz qual foi.
    if [ "$LOGIN_ERRO" = rede ]; then _ll_porque="sem resposta do servidor"; else _ll_porque="login recusado"; fi

    if is_logged_in "$PAGE"; then
        unset _ll_porque
        sessao_marcar
        printf "[%s] %s — reconectado\n" "$SLS_TAG" "$SLS_USER"
        _acc=`extract_username "$PAGE"`
        [ -n "$_acc" ] && ACC=`echo "$_acc" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'`
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
    reconexao_falhou "$LOGIN_ERRO"
    [ -n "$SLS_STATUS_FILE" ] && echo "login_retry" > "$SLS_STATUS_FILE"
    return 1
}
