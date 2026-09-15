# shellcheck disable=SC2155
coliseum_fight() {
    # Arquivos de batalha gravados no diretorio da conta (sem mktemp)
    src_ram="$TMP/col_src"
    full_ram="$TMP/col_full"

    LA=5
    HPER=38
    RPER=5

    printf "Coliseum\n"

    # HP maximo
    (
        run_curl_exec "$URL/train" | grep -o -E '\(([0-9]+)\)' | head -n1 | sed 's/[()]//g' > "$full_ram"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 20

    # Desativa graficos
    (
        run_curl_exec "$URL/settings/graphics/0" > /dev/null
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17

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
    # "sed -n 1p" em todo link: repetido na pagina, viraria duas linhas e o
    # curl recusaria a URL.
    go_stop=`grep -o -E '/coliseum/enterFight/[?]r[=][0-9]+' "$src_ram" | sed -n 1p`

    # LUTA JA EM ANDAMENTO: o worker relancado no meio de uma luta do coliseu
    # (batalha_retomar) encontra a pagina de combate, sem link de inscricao.
    # Antes isso caia em "nao foi possivel iniciar" e a conta abandonava.
    _col_estado=`estado_luta "$src_ram" coliseum`

    if [ -n "$go_stop" ] || [ "$_col_estado" = "luta" ]; then
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
            # Resposta vazia (rede) deixa o link vazio: sem o padrao, a
            # espera pedia a Home a cada 3s em vez da pagina do coliseu.
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
      fi

        cl_access() {
            # Os relogios de cura/esquiva/ataque eram zerados AQUI, a cada
            # leitura: a recarga de 90s da cura nunca valia e, com a vida
            # baixa, a cura era tentada quase a cada volta. Sairam para antes
            # do laco, onde sao iniciados uma vez so.

            USH=`grep -o -E '(hp)[^A-z0-9]{1,4}[0-9]{2,5}' "$src_ram" | grep -o -E '[0-9]{2,5}' | sed 's,\ ,,g'`
            ENH=`grep -o -E '(nbsp)[^A-Za-z0-9]{1,2}[0-9]{1,6}' "$src_ram" | sed -n 's,nbsp[;],,;s,\ ,,;1p'`
            USER=`grep -o -E '([[:upper:]][[:lower:]]{0,15}( [[:upper:]][[:lower:]]{0,13})?)[[:space:]][^[:alnum:]]s' "$src_ram" | sed -n 's,\ [<]s,,;s,\ ,_,;2p'`

            ATK=`grep -o -E '/coliseum/atk/[?]r[=][0-9]+' "$src_ram" | sed -n 1p`
            ATKRND=`grep -o -E '/coliseum/atkrnd/[?]r[=][0-9]+' "$src_ram" | sed -n 1p`
            DODGE=`grep -o -E '/coliseum/dodge/[?]r[=][0-9]+' "$src_ram" | sed -n 1p`
            HEAL=`grep -o -E '/coliseum/heal/[?]r[=][0-9]+' "$src_ram" | sed -n 1p`

            RHP=`awk -v ush="$USH" -v rper="$RPER" 'BEGIN { printf "%.0f", ush * rper / 100 + ush }'`
            HLHP=`awk -v ush="$(cat "$full_ram")" -v hper="$HPER" 'BEGIN { printf "%.0f", ush * hper / 100 }'`

            if grep -q -o '/dodge/' "$src_ram"; then
                # A pagina respondeu com a luta: sessao confirmada.
                _reconf=0
                sessao_marcar
                printf "Em batalha - HP: %s\n" "$USH"
                # Morto com a luta ainda na tela (ver luta_hp, em info.sh).
                # O USH daqui exige 2 a 5 digitos: com a vida entre 1 e 9 ele
                # viria vazio e contaria como zero — a conta VIVA seria dada
                # por morta. Para a morte, a leitura aceita de 1 a 6 digitos.
                _col_hp=`grep -o -E "(hp)[^A-Za-z0-9]{1,4}[0-9]{1,6}" "$src_ram" | head -n 1 | grep -o -E '[0-9]+$'`
                if luta_hp "$_col_hp"; then
                  # ANTES DE ENCERRAR, TENTA VOLTAR.
                  #
                  # Morrer nao e o mesmo que sair do evento: havendo unrip na
                  # pagina, ressuscitar() rele a luta e a conta continua. Era o
                  # que faltava para as contas nao largarem o altar.
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
                # RECONFIRMA antes de decidir: uma unica leitura sem /dodge/
                # pode ser transicao, soluco de rede ou um link vazio ter
                # baixado a home. Rele /coliseum uma vez e reavalia.
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
                # Quem decide o fim e o jogo: morte, ou o ?end_fight da tela
                # de encerramento (luta_acabou, em info.sh). Antes o
                # ?end_fight so relia a pagina, sem encerrar, e o laco seguia
                # mandando acoes ate o teto; e qualquer outra leitura sem
                # esquiva encerrava a luta com a conta viva.
                # MORREMOS, e a pagina ja nao mostra a luta? A releitura acima
                # pode ter trazido o unrip — mesmo caminho do king.sh.
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

        luta_inicio coliseum
        cl_access
        OLDHP=$USH
        BREAK_LOOP=""
        first_time=`date +%s`
        last_heal=$(($(date +%s) - 90))
        last_dodge=$(($(date +%s) - 20))
        last_atk=$(($(date +%s) - LA))

        # TETO DE SEGURANCA (luta_teto, em info.sh): so segura o laco que
        # nunca resolve. Quem encerra a luta e o jogo, pelo luta_acabou.
        #
        # LINK VAZIO NUNCA VIRA REQUISICAO: cada ramo exige o proprio link
        # na pagina; "${URL}${HEAL}" com HEAL vazio pedia a pagina inicial.
        COL_BREAK=`luta_teto`
        until [ -n "$BREAK_LOOP" ] || [ "$(date +%s)" -gt "$COL_BREAK" ]; do
            now=`date +%s`
            time_since_last_heal=$((now - last_heal))
            time_since_last_dodge=$((now - last_dodge))
            time_since_last_atk=$((now - last_atk))

            if [ -n "$HEAL" ] && \
               awk -v ush="$USH" -v hlhp="$HLHP" 'BEGIN { exit !(ush < hlhp) }' && \
               [ "$time_since_last_heal" -gt 90 ]; then
                (
                    run_curl_exec "${URL}${HEAL}" > "$src_ram"
                ) </dev/null > /dev/null 2>&1 &
                time_exit 17
                cl_access
                # HP maximo (full_ram) preservado: vem do /train. Troca-lo
                # pelo HP atual pos-cura fazia o limiar HLHP cair a cada
                # golpe e a conta "achar" que continuava com HP cheio.
                last_heal=$now
                last_atk=$now

            elif [ -n "$DODGE" ] && ! alvo_grey "$src_ram" && \
                 [ "$time_since_last_dodge" -gt 20 ] && \
                 awk -v ush="$USH" -v oldhp="$OLDHP" 'BEGIN { exit !(ush < oldhp) }'; then
                (
                    run_curl_exec "${URL}${DODGE}" > "$src_ram"
                ) </dev/null > /dev/null 2>&1 &
                time_exit 17
                cl_access
                OLDHP=$USH
                last_dodge=$now
                last_atk=$now

            elif [ -n "$ATKRND" ] && \
                 awk -v latk="$time_since_last_atk" -v atktime="$LA" 'BEGIN { exit !(latk != atktime) }' && \
                 ! alvo_grey "$src_ram" && \
                 awk -v rhp="$RHP" -v enh="$ENH" 'BEGIN { exit !(rhp < enh) }'; then
                (
                    run_curl_exec "${URL}${ATKRND}" > "$src_ram"
                ) </dev/null > /dev/null 2>&1 &
                time_exit 17
                cl_access
                last_atk=$now

            elif [ -n "$ATK" ] && \
                 awk -v latk="$time_since_last_atk" -v atktime="$LA" 'BEGIN { exit !(latk > atktime) }'; then
                (
                    run_curl_exec "${URL}${ATK}" > "$src_ram"
                ) </dev/null > /dev/null 2>&1 &
                time_exit 17
                cl_access
                last_atk=$now

            else
                # RECARGA DE ATAQUE — UMA REQUISICAO POR CICLO.
                # O ultimo golpe ja trouxe o HP. So relemos a pagina quando o
                # alvo esta momentaneamente invulneravel (grey); fora disso
                # apenas esperamos o restante da recarga, sem nova requisicao,
                # para o intervalo entre golpes ficar em 4-5s.
                # Rele tambem quando a leitura nao tem link de ataque: a luta
                # so termina pelo luta_acabou, e sem esta releitura o laco
                # dormiria sobre uma pagina sem acao ate o teto.
                if alvo_grey "$src_ram" || [ -z "$ATK" ]; then
                    (
                        run_curl_exec "${URL}/coliseum" > "$src_ram"
                    ) </dev/null > /dev/null 2>&1 &
                    time_exit 17
                    cl_access
                    [ -n "$ATK" ] || sleep 1
                else
                    _resta=$(( LA - time_since_last_atk ))
                    [ "$_resta" -gt 0 ] && sleep "$_resta"
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

            # O LACO DA MISSAO TEM TETO.
            #
            # Ele so terminava quando a missao 11 sumisse da lista. Com o
            # coliseu sem luta para entrar, o coliseum_fight voltava na hora e
            # o laco repetia coliseum_fight + /quest/ para sempre — no dia 1
            # do mes, das 0h as 9h, e depois das 9h tambem: a conta perdia os
            # eventos do dia inteiro. Seis tentativas ou 20 minutos.
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
        sleep 5s
    fi
}
