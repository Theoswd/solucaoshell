campaign_func() {
    printf "Campaign\n"
    # Globais limpas: a caverna usa o mesmo RESULT.
    CAMPAIGN=""; RESULT=""
    fetch_page "/campaign/"

    if grep -q -o -E '/campaign/(go|fight|attack|end)/[?]r[=][0-9]+' "$TMP/SRC"; then
        CAMPAIGN=`grep -o -E '/campaign/(go|fight|attack|end)/[?]r[=][0-9]+' "$TMP/SRC" | head -n 1`
        BREAK=$(($(date +%s) + 90))

        while [ -n "$CAMPAIGN" ] && [ "$(date +%s)" -lt "$BREAK" ]; do
            case $CAMPAIGN in
                *go*|*fight*|*attack*|*end*)
                    # Regra do dono: nunca gasta ouro (ver botao_pago).
                    if botao_pago "$TMP/SRC" "$CAMPAIGN"; then
                        printf "Campaign: botao cobra ouro - para aqui\n"
                        break
                    fi
                    fetch_page "$CAMPAIGN"
                    RESULT=`echo "$CAMPAIGN" | cut -d'/' -f3`
                    printf "Campaign -> %s\n" "$RESULT"
                    CAMPAIGN=`grep -o -E '/campaign/(go|fight|attack|end)/[?]r[=][0-9]+' "$TMP/SRC" | head -n 1`
                    ;;
            esac
        done
    fi

    # QUANDO VOLTAR: o relogio da pagina (campanha_relogio, em crono.sh),
    # "Nova campanha em 7 h 38 min", relida uma vez se preciso. Ainda com
    # link de acao: proxima varredura. Sem relogio: feita agora espera as 8h
    # do jogo; sem nada feito, a pagina fica guardada e volta em 1h.
    if [ -n "$CAMPAIGN" ]; then
        relogio_anotar campanha 900
    else
        _cp=`campanha_relogio "$TMP/SRC"`
        # So a releitura que RESPONDEU diz se a campanha acabou: um clique sem
        # resposta tambem tira o link de acao.
        _cp_ok=1
        if [ -z "$_cp" ] && [ -n "$RESULT" ]; then
            if fetch_page "/campaign/" && [ -s "$TMP/SRC" ]; then
                _cp=`campanha_relogio "$TMP/SRC"`
                grep -q -E '/campaign/(go|fight|attack|end)/[?]r[=][0-9]+' "$TMP/SRC" && _cp_ok=0
            else
                _cp_ok=0
            fi
        fi
        # Sem relogio numa pagina que nao e do jogo com a conta logada (sessao
        # caida, erro do servidor): nao diz se a campanha acabou.
        [ -n "$_cp" ] || [ "`sessao_estado "$TMP/SRC"`" = viva ] || _cp_ok=0
        if [ -n "$_cp" ]; then
            relogio_anotar campanha $(( _cp + 60 ))
            printf "Campanha: a proxima em %s min\n" $(( _cp / 60 ))
        elif [ "$_cp_ok" = 0 ]; then
            # Sem resposta, ou a campanha ainda tem acao: volta na varredura.
            relogio_anotar campanha 900
        elif [ -n "$RESULT" ]; then
            relogio_anotar campanha 28800
        else
            cp "$TMP/SRC" "$TMP/campanha_sem_relogio.html" 2>/dev/null
            relogio_anotar campanha 3600
        fi
        unset _cp _cp_ok
    fi
    unset CAMPAIGN RESULT BREAK

    printf "Campaign ok\n"
}
