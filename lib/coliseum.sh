# HP maximo e, se o /train saiu, o /coliseum relido (full_relendo, info.sh).
# 0 = releu a pagina, 1 = nada saiu e a pagina e a mesma.
coliseum_hpmax() { full_relendo "$full_ram" /coliseum "$src_ram"; }

# shellcheck disable=SC2155
coliseum_fight() {
    # A chave vale aqui tambem: o horario da madrugada (run.sh) chama direto.
    # COLISEU_SEM_LUTA=1: este pulso nao achou luta (a madrugada nao repete
    # o pulso no mesmo minuto).
    COLISEU_SEM_LUTA=1
    [ "$FUNC_coliseum" = "n" ] && return 0
    # Arquivos de batalha gravados no diretorio da conta (sem mktemp)
    src_ram="$TMP/col_src"
    full_ram="$TMP/col_full"

    LA=5
    HPER=38
    RPER=5

    printf "Coliseum\n"

    # O preparo so quando ha luta: o modo grafico fica gravado na conta (uma
    # vez por worker); o /train, so antes de entrar numa luta.
    if [ -z "$COLISEU_GRAFICO" ]; then
        (
            run_curl_exec "$URL/settings/graphics/0" > /dev/null
        ) </dev/null > /dev/null 2>&1 &
        time_exit 17
        COLISEU_GRAFICO=1
    fi

    # Pagina do coliseu
    (
        run_curl_exec "$URL/coliseum" > "$src_ram"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17

    # Encerra luta pendente
    if grep -q -o '?end_fight' "$src_ram"; then
        (
            run_curl_exec "$URL/coliseum/?end_fight=true" > /dev/null
        ) </dev/null > /dev/null 2>&1 &
        time_exit 17
        (
            run_curl_exec "$URL/coliseum" > "$src_ram"
        ) </dev/null > /dev/null 2>&1 &
        time_exit 17
    fi

    access_link=`grep -o -E '/coliseum(/[A-Za-z]+/[?]r[=][0-9]+|/)' "$src_ram" | sed -n '1p'`
    # "sed -n 1p" em todo link: repetido na pagina viraria duas linhas.
    go_stop=`grep -o -E '/coliseum/enterFight/[?]r[=][0-9]+' "$src_ram" | sed -n 1p`

    # HP maximo so com luta, antes de entrar. Se saiu o /train, o servidor
    # recusa o nonce (?r=) da pagina velha: rele o /coliseum e pega o link.
    if [ -n "$go_stop" ] && coliseum_hpmax; then
        access_link=`grep -o -E '/coliseum(/[A-Za-z]+/[?]r[=][0-9]+|/)' "$src_ram" | sed -n '1p'`
        go_stop=`grep -o -E '/coliseum/enterFight/[?]r[=][0-9]+' "$src_ram" | sed -n 1p`
    fi

    # Luta ja em andamento (worker relancado): pagina de combate sem link de
    # inscricao; sem este ramo a conta abandonaria.
    _col_estado=`estado_luta "$src_ram" coliseum`
    # Sem resposta ou sem sessao nao e "sem luta": o pulso tenta de novo.
    case "$_col_estado" in invalida|deslogado) COLISEU_SEM_LUTA=0 ;; esac

    if [ -n "$go_stop" ] || [ "$_col_estado" = "luta" ]; then
      COLISEU_SEM_LUTA=0
      if [ -n "$go_stop" ]; then
        # Inscricao: a batalha fica anotada para o worker relancado voltar.
        batalha_marcar coliseum
        printf "  Entering...\n"
        (
            run_curl_exec "${URL}${go_stop}" > "$src_ram"
        ) </dev/null > /dev/null 2>&1 &
        time_exit 17

        access_link=`grep -o -E '/coliseum(/[A-Za-z]+/[?]r[=][0-9]+|/)' "$src_ram" | grep -v 'dodge' | sed -n 1p`
        printf " Preparing for battle, waiting for other players...\n"

        first_time=`date +%s`
        until grep -q -o 'coliseum/dodge/' "$src_ram" || awk -v ltime="$(($(date +%s) - first_time))" 'BEGIN { exit !(ltime > 30) }'; do
            # Resposta vazia deixa o link vazio: o padrao evita pedir a Home.
            (
                run_curl_exec "${URL}${access_link:-/coliseum/}" > "$src_ram"
            ) </dev/null > /dev/null 2>&1 &
            time_exit 17
            access_link=`grep -o -E '/(coliseum/[A-Za-z]+/[?]r[=][0-9]+|coliseum)' "$src_ram" | grep -v 'dodge' | sed -n 1p`
            printf " Preparing...\n"
            sleep 3s
        done
      else
        printf "  Luta do coliseu em andamento - voltando para ela\n"
        # Retomada sem HP maximo em disco: le agora (com a pagina relida).
        [ -s "$full_ram" ] || coliseum_hpmax
      fi

        cl_access() {
            # Alvo cinza uma vez por pagina (ver o mesmo ponto no clanfight.sh).
            if alvo_grey "$src_ram"; then _grey=1; else _grey=0; fi
            # Os relogios de cura/esquiva/ataque sao iniciados uma vez, antes
            # do laco, nunca aqui (a recarga de 90s nunca valeria).

            # UM GREP PARA A PAGINA (eram seis grep|sed, ~29 processos por
            # pagina): os mesmos padroes, e o primeiro achado de cada um sai
            # como antes (ver luta_ler, em info.sh). HP: os digitos do fim do
            # 1o "hp"; ENH: o 1o "nbsp" com o sed "s,nbsp;,,;s, ,," de antes.
            USH=""; ENH=""; ATK=""; ATKRND=""; DODGE=""; HEAL=""; _emluta=0
            _cl_l=`grep -o -E -e '(hp)[^A-Za-z0-9]{1,4}[0-9]{1,6}' -e '(nbsp)[^A-Za-z0-9]{1,2}[0-9]{1,6}' \
                -e '/coliseum/atk/[?]r[=][0-9]+' -e '/coliseum/atkrnd/[?]r[=][0-9]+' \
                -e '/coliseum/dodge/[?]r[=][0-9]+' -e '/coliseum/heal/[?]r[=][0-9]+' \
                -e '/dodge/' "$src_ram" 2>/dev/null`
            _cl_hp=0; _cl_en=0
            while IFS= read -r _cl_x; do
                case "$_cl_x" in
                    '') ;;
                    /dodge/) _emluta=1 ;;
                    hp*) [ "$_cl_hp" = 1 ] || { USH=${_cl_x##*[!0-9]}; _cl_hp=1; } ;;
                    nbsp*)
                        if [ "$_cl_en" = 0 ]; then
                            case "$_cl_x" in *"nbsp;"*) _cl_x="${_cl_x%%"nbsp;"*}${_cl_x#*"nbsp;"}" ;; esac
                            case "$_cl_x" in *" "*) _cl_x="${_cl_x%%" "*}${_cl_x#*" "}" ;; esac
                            ENH=$_cl_x; _cl_en=1
                        fi ;;
                    /coliseum/atk/*)    [ -n "$ATK" ]    || ATK=$_cl_x ;;
                    /coliseum/atkrnd/*) [ -n "$ATKRND" ] || ATKRND=$_cl_x ;;
                    /coliseum/dodge/*)  _emluta=1; [ -n "$DODGE" ] || DODGE=$_cl_x ;;
                    /coliseum/heal/*)   [ -n "$HEAL" ]   || HEAL=$_cl_x ;;
                esac
            done <<EOF
$_cl_l
EOF
            unset _cl_l _cl_x _cl_hp _cl_en

            RHP=`awk -v ush="$USH" -v rper="$RPER" 'BEGIN { printf "%.0f", ush * rper / 100 + ush }'`
            # Marcas da pagina, calculadas uma vez por pagina.
            _cura=0; [ -n "$HEAL" ] && luta_menor "$USH" "$HLHP" && _cura=1
            _caiu=0; [ -n "$DODGE" ] && luta_menor "$USH" "$OLDHP" && _caiu=1
            _forte=0; [ -n "$ATKRND" ] && luta_menor "$RHP" "$ENH" && _forte=1

            if [ "$_emluta" = 1 ]; then
                # A pagina respondeu com a luta: sessao confirmada.
                _reconf=0
                sessao_marcar
                printf "Em batalha - HP: %s\n" "$USH"
                # Morto com a luta ainda na tela (ver luta_hp, em info.sh).
                if luta_hp "$USH"; then
                  # Antes de encerrar, tenta voltar: com unrip na pagina,
                  # ressuscitar() rele a luta e a conta continua.
                  if ressuscitar coliseum "$src_ram"; then
                    cl_access
                    return
                  fi
                    LUTA_MOTIVO="o jogo declarou o personagem morto (HP 0 com a luta na tela)"
                    batalha_limpar
                    BREAK_LOOP=1
                    printf "Battle over. (%s)\n" "$LUTA_MOTIVO"
                fi
            else
                # RECONFIRMA antes de decidir: uma leitura sem /dodge/ pode ser
                # transicao, rede ou link vazio. Rele /coliseum uma vez.
                if [ "${_reconf:-0}" = 0 ]; then
                    _reconf=1
                    (
                        run_curl_exec "${URL}/coliseum" > "$src_ram"
                    ) </dev/null > /dev/null 2>&1 &
                    time_exit 17
                    cl_access
                    return
                fi
                _reconf=0
                # Quem decide o fim e o jogo: morte, ou o ?end_fight da tela de
                # encerramento (luta_acabou). A releitura pode ter trazido o unrip.
                if ressuscitar coliseum "$src_ram"; then
                  cl_access
                  return
                fi
                if luta_acabou "$src_ram" coliseum; then
                    BREAK_LOOP=1
                    printf "Battle over. (%s)\n" "$LUTA_MOTIVO"
                fi
            fi
        }

        # LIMIAR DE CURA, UMA VEZ POR LUTA: o HP maximo nao muda durante ela.
        HLHP=`awk -v ush="$(cat "$full_ram")" -v hper="$HPER" 'BEGIN { printf "%.0f", ush * hper / 100 }'`
        OLDHP=""
        luta_inicio coliseum
        cl_access
        OLDHP=$USH; _caiu=0
        BREAK_LOOP=""
        first_time=`date +%s`
        last_heal=$(($(date +%s) - 90))
        last_dodge=$(($(date +%s) - 20))
        last_atk=$(($(date +%s) - LA))

        # Teto de seguranca (luta_teto): quem encerra a luta e o jogo.
        # Link vazio nunca vira requisicao: cada ramo exige o proprio link.
        COL_BREAK=`luta_teto`
        # Um "date" por volta: o mesmo instante decide o teto e as recargas.
        while now=`date +%s`; [ -z "$BREAK_LOOP" ] && [ "$now" -le "$COL_BREAK" ]; do
            time_since_last_heal=$((now - last_heal))
            time_since_last_dodge=$((now - last_dodge))
            time_since_last_atk=$((now - last_atk))

            # Relogio unico das acoes (como no Rei): cura, esquiva e troca de
            # alvo tambem so depois de LA da ultima acao.
            if [ -n "$HEAL" ] && \
               [ "$time_since_last_atk" -gt "$LA" ] && \
               [ "$_cura" = 1 ] && \
               [ "$time_since_last_heal" -gt 90 ]; then
                (
                    run_curl_exec "${URL}${HEAL}" > "$src_ram"
                ) </dev/null > /dev/null 2>&1 &
                time_exit 17; _saiu=1; pedido_nao_saiu && _saiu=0
                cl_access
                # full_ram nunca e trocado pelo HP atual pos-cura.
                # Pedido que nao saiu (pedido_nao_saiu): a cura nao valeu.
                [ "$_saiu" = 1 ] && last_heal=$now
                last_atk=$now

            elif [ -n "$DODGE" ] && [ "$_grey" = 0 ] && \
                 [ "$time_since_last_atk" -gt "$LA" ] && \
                 [ "$time_since_last_dodge" -gt 20 ] && \
                 [ "$_caiu" = 1 ]; then
                (
                    run_curl_exec "${URL}${DODGE}" > "$src_ram"
                ) </dev/null > /dev/null 2>&1 &
                time_exit 17; _saiu=1; pedido_nao_saiu && _saiu=0
                cl_access
                if [ "$_saiu" = 1 ]; then
                    OLDHP=$USH; _caiu=0
                    last_dodge=$now
                fi
                last_atk=$now

            elif [ -n "$ATKRND" ] && \
                 [ "$time_since_last_atk" -gt "$LA" ] && \
                 [ "$_grey" = 0 ] && \
                 [ "$_forte" = 1 ]; then
                (
                    run_curl_exec "${URL}${ATKRND}" > "$src_ram"
                ) </dev/null > /dev/null 2>&1 &
                time_exit 17
                cl_access
                last_atk=$now

            # Ataque so com o alvo fora do cinza (invulneravel), como no Rei.
            elif [ -n "$ATK" ] && \
                 [ "$time_since_last_atk" -gt "$LA" ] && \
                 [ "$_grey" = 0 ]; then
                (
                    run_curl_exec "${URL}${ATK}" > "$src_ram"
                ) </dev/null > /dev/null 2>&1 &
                time_exit 17
                cl_access
                last_atk=$now

            else
                # RECARGA DE ATAQUE — UMA REQUISICAO POR CICLO. So rele com o
                # alvo grey ou sem link de ataque; fora disso espera o restante.
                # So depois de LA da ultima acao (colada no golpe, a releitura
                # voltava com o mesmo alvo cinza).
                if { [ "$_grey" = 1 ] || [ -z "$ATK" ]; } && [ "$time_since_last_atk" -gt "$LA" ]; then
                    (
                        run_curl_exec "${URL}/coliseum" > "$src_ram"
                    ) </dev/null > /dev/null 2>&1 &
                    time_exit 17
                    # A releitura ja e a reconfirmacao.
                    _reconf=1
                    cl_access
                    # Sempre: com o alvo cinza e ataque na tela, a releitura seguia sem pausa.
                    sleep 1
                else
                    # Fim do giro: nunca espera zero.
                    _resta=$(( LA - time_since_last_atk ))
                    [ "$_resta" -gt 0 ] || _resta=1
                    sleep "$_resta"
                fi
            fi
        done

        rm -f "$src_ram" "$full_ram"
        unset last_heal last_dodge last_atk USH ENH USER ATK ATKRND DODGE HEAL BREAK_LOOP
        func_unset

        printf "The battle is over!\n"
    else
        printf "It was not possible to start the battle at this time.\n"
    fi
}

coliseum_start() {
    if [ "$FUNC_coliseum" = "n" ]; then
        return
    fi

    if (case `date +%H:%M` in
        (09:2[4-9]|09:5[4-9]|10:1[0-4]|10:2[4-9]|10:5[4-9]|12:2[4-9]|13:5[4-9]|14:5[4-9]|15:5[4-9]|16:1[0-4]|16:2[4-9]|18:5[4-9]|20:5[4-9]|21:2[4-9]|21:5[4-9]|22:2[4-9])
            exit 1
            ;;
        esac)
    then
        if echo "$RUN" | grep -q -E '[-]boot'; then
            (
                run_curl_exec "${URL}/quest/" > "$TMP/SRC"
            ) </dev/null > /dev/null 2>&1 &
            time_exit 20

            # O laco da missao 11 tem teto (seis tentativas ou 20 min): sem
            # luta no coliseu ele repetia coliseum_fight + /quest/ para sempre.
            _q11_fim=$(( `date +%s` + 1200 ))
            _q11_n=0
            while grep -q -o -E '/coliseum/[?]quest_t[=]quest&quest_id[=]11&qz[=][a-z0-9]+' "$TMP/SRC" \
                  && [ "$_q11_n" -lt 6 ] && [ "`date +%s`" -lt "$_q11_fim" ]; do
                _q11_n=$((_q11_n + 1))
                coliseum_fight
                (
                    run_curl_exec "${URL}/quest/" > "$TMP/SRC"
                ) </dev/null > /dev/null 2>&1 &
                time_exit 20

                ENDQUEST=`grep -o -E '/quest/end/11[?]r[=][A-Za-z0-9]+' "$TMP/SRC" | sed -n 1p`
                if [ -n "$ENDQUEST" ]; then
                    (
                        run_curl_exec "${URL}${ENDQUEST}" > "$TMP/SRC"
                    ) </dev/null > /dev/null 2>&1 &
                    time_exit 20
                fi
            done
            unset _q11_fim _q11_n

        elif echo "$RUN" | grep -q -E '[-]cl'; then
            coliseum_fight
        fi
    else
        printf "Battle or event time...\n"
    fi
}
