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

# PORTAO UNICO DA RECONEXAO: $TMP/relogin = "PROXIMA_TENTATIVA RECUSAS".
#
# So o laco de entrada (sls.sh) tinha espera crescente. Depois do login, a
# varredura, o painel (atualiza_stats) e o descanso reconectavam cada um por
# si: com o servidor recusando a senha (o estrangulamento por IP responde
# igual a senha errada), cada conta mandava 1-2 POSTs por minuto e mantinha
# o proprio bloqueio. Agora toda reconexao fora da luta passa por aqui:
#   senha recusada   60s, 120s, 300s e dai 900s (+ PID % 10, contas nao
#                    reincidem juntas); zera quando a sessao volta
#   sem resposta     30s, sem escalar (nao diz nada sobre a senha)
# Marca mais de 30 min no futuro (relogio voltou) nao segura.
relogin_liberado() {
    _rg_p=0; { read -r _rg_p _rg_x < "$TMP/relogin"; } 2>/dev/null
    case "$_rg_p" in ''|*[!0-9]*) _rg_p=0 ;; esac
    RELOGIN_RESTA=$(( _rg_p - `date +%s` ))
    unset _rg_p _rg_x
    [ "$RELOGIN_RESTA" -le 0 ] || [ "$RELOGIN_RESTA" -gt 1800 ]
}

relogin_falhou() { # credencial|rede
    _rg_p=0; _rg_n=0; { read -r _rg_p _rg_n < "$TMP/relogin"; } 2>/dev/null
    case "$_rg_n" in ''|*[!0-9]*) _rg_n=0 ;; esac
    if [ "$1" = rede ]; then
        _rg_e=30
    else
        _rg_n=$(( _rg_n + 1 ))
        case "$_rg_n" in
            1) _rg_e=60 ;;
            2) _rg_e=120 ;;
            3) _rg_e=300 ;;
            *) _rg_e=900 ;;
        esac
        _rg_e=$(( _rg_e + $$ % 10 ))
    fi
    echo "$(( `date +%s` + _rg_e )) $_rg_n" > "$TMP/relogin" 2>/dev/null
    unset _rg_p _rg_n _rg_e
}

# So o [ -f ] do shell no caminho feliz: nenhum processo quando nao ha marca.
relogin_zerar() { [ -f "$TMP/relogin" ] && rm -f "$TMP/relogin" 2>/dev/null; return 0; }

# login_logoff [luta]: com "luta" a reconexao nao espera o portao (a luta tem
# hora; ela ja tem o proprio limite, tres por luta e o luta_pode_reconectar),
# mas a recusa conta para as tentativas seguintes.
login_logoff() {
    PAGE=`run_curl "${URL}/user"`

    if is_logged_in "$PAGE"; then
        relogin_zerar
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

    if [ "$1" != luta ] && ! relogin_liberado; then
        printf "[%s] %s — sessao expirada, nova tentativa de login em %ss\n" \
            "$SLS_TAG" "$SLS_USER" "$RELOGIN_RESTA"
        [ -n "$SLS_STATUS_FILE" ] && echo "login_retry" > "$SLS_STATUS_FILE"
        unset PAGE
        return 1
    fi

    printf "[%s] %s — sessao expirada, reconectando...\n" "$SLS_TAG" "$SLS_USER"
    rm -f "$TMP_COOKIE"

    cript_file="$TMP/cript_file"
    [ ! -f "$cript_file" ] && return 1

    # A trava global de login vale tambem na reconexao (login_autenticar):
    # sessoes derrubadas juntas reconectariam no mesmo instante.
    login_autenticar || { relogin_falhou credencial; return 1; }

    # Rede nao e senha recusada: o log diz qual foi.
    if [ "$LOGIN_ERRO" = rede ]; then _ll_porque="sem resposta do servidor"; else _ll_porque="login recusado"; fi

    if is_logged_in "$PAGE"; then
        unset _ll_porque
        relogin_zerar
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
    relogin_falhou "$LOGIN_ERRO"
    [ -n "$SLS_STATUS_FILE" ] && echo "login_retry" > "$SLS_STATUS_FILE"
    return 1
}
