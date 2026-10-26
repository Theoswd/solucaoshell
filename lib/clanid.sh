# ID DO CLA: UMA CONSULTA POR HORA, COM OU SEM CLA.
#
# A pagina vai para um rascunho e so a resposta do jogo com a conta logada
# decide: ID achado grava, sem ID e conta sem cla. Decidido, a proxima
# consulta sai em CLAN_ID_MIN (60) minutos; sem resposta, em 5, e o ID que
# ja se conhecia fica.
clan_id() {
    cd "$TMP" || return 1
    if [ -z "$CLD" ] && [ -s "$TMP/CLD" ]; then
        read -r CLD < "$TMP/CLD" 2>/dev/null
        case "$CLD" in ''|*[!0-9]*) CLD="" ;; esac
    fi
    _ci_min=${CLAN_ID_MIN:-60}
    case "$_ci_min" in ''|*[!0-9]*) _ci_min=60 ;; esac
    if ! ativ_liberada clan_id "$_ci_min"; then
        unset _ci_min
        [ -n "$CLD" ]
        return
    fi

    fetch_page "/clan" "$TMP/CLANID"
    if [ "`sessao_estado "$TMP/CLANID"`" != viva ]; then
        echo $(( `date +%s` - (_ci_min - 5) * 60 )) > "$TMP/last_clan_id" 2>/dev/null
        unset _ci_min
        [ -n "$CLD" ]
        return
    fi
    ativ_marcar clan_id

    CLD=`grep -o -E '/clan/[0-9]+/' "$TMP/CLANID" | head -n 1 | awk -F'/' '{ print $3 }'`
    if [ -z "$CLD" ]; then
        : > "$TMP/CLD"
        printf "Conta sem cla (nova consulta em %s min)\n" "$_ci_min"
        unset _ci_min
        return 1
    fi
    echo "$CLD" > "$TMP/CLD"
    unset _ci_min
}

checkQuest() {
    quest_id="$1"
    action="$2"

    if [ "${FUNC_clan_missions:-y}" != "y" ]; then
        return 1
    fi

    if [ -z "$CLD" ]; then
        printf "CLAN ID not available, trying to fetch it.\n"
        clan_id
        if [ -z "$CLD" ]; then
            printf "Failed to retrieve CLAN ID.\n"
            return 1
        fi
    fi

    # Usa a mesma pagina das cq_* (cq_pagina, em $TMP/CQUEST), e nao o
    # $TMP/SRC, que e o buffer compartilhado por todos os modulos.
    cq_pagina || {
        printf "Pagina de missoes do cla indisponivel.\n"
        return 1
    }

    case "$action" in
        apply)
            click=`grep -o -E "/quest/take/$quest_id/[?]r=[0-9]+" "$TMP/CQUEST" | sed -n '1p'`
            ;;
        end)
            click=`grep -o -E "/quest/end/$quest_id/[?]r=[0-9]+" "$TMP/CQUEST" | sed -n '1p'`
            ;;
        *)
            return 1
            ;;
    esac

    if [ -n "$click" ]; then
        fetch_page "/clan/${CLD}${click}"
        cq_invalidar
        return 0
    fi

    return 1
}

# ============================================================
#  MASMORRA DO CLA
#
# Abre a pagina, procura o link de golpe e executa se ele estiver la.
# Devolve 0 SOMENTE quando um golpe saiu de verdade; sem link, imprime no
# log o que viu na pagina.
# ============================================================

# Link de golpe, procurado na pagina ja baixada.
masmorra_golpe() {
    # O caminho conhecido tem prioridade; a leitura frouxa (/<secao>/attack/)
    # e reserva para quando o nome da secao mudar, nunca para escolher outro
    # link tendo o certo a mao.
    _mg=`grep -o -E "/clandungeon/at[a-z]{0,3}k/[^A-Za-z0-9]r[^A-Za-z0-9][0-9]+" "$1" 2>/dev/null | sed -n 1p`
    [ -n "$_mg" ] || _mg=`grep -o -E "/[a-z]{4,20}/at[a-z]{0,3}k/[^A-Za-z0-9]r[^A-Za-z0-9][0-9]+" "$1" 2>/dev/null | sed -n 1p`
    # Golpe que cobra ouro (acabaram os gratuitos): nao e golpe para o bot.
    botao_pago "$1" "$_mg" && _mg=""
    printf '%s' "$_mg"
    unset _mg
}

# O que a pagina tem, quando nao tem o golpe. So para o log.
masmorra_dump() {
    printf "Masmorra: sem link de golpe na pagina. O que veio:\n"
    _mdz=`wc -c < "$1" 2>/dev/null`
    printf "  tamanho: %s bytes\n" "${_mdz:-0}"
    sed 's/<[^>]*>/ /g' "$1" 2>/dev/null | tr -s ' \t' ' ' \
        | grep -o -i -E ".{0,30}(golpe|acesso|masmorra|dungeon).{0,30}" \
        | head -n 3 | sed 's/^/  texto: /'
    grep -o -E "/[a-z0-9_-]{3,24}/[a-z0-9_-]{0,24}/?[^A-Za-z0-9]r[^A-Za-z0-9][0-9]+" "$1" 2>/dev/null \
        | sort -u | head -n 6 | sed 's/^/  link: /'
    unset _mdz
}

# PAGINA PRINCIPAL DO CLA, LIDA UMA VEZ ($TMP/CLANPG).
#
# Lida pelo clan_lider e pelo clanDungeon no mesmo start(). O bot so LE esta
# pagina, entao o teto de tempo basta para guardar a leitura.
CLAN_VALIDADE=${CLAN_VALIDADE:-45}

clan_pagina() {
    [ -n "$CLD" ] || return 1

    _clp_ts="${_CLAN_TS:-0}"
    case "$_clp_ts" in '' | *[!0-9]* ) _clp_ts=0 ;; esac
    # Idade negativa = relogio voltou: a leitura nao vale.
    if [ -s "$TMP/CLANPG" ] && [ "$_clp_ts" -gt 0 ] \
       && [ $(( `date +%s` - _clp_ts )) -ge 0 ] \
       && [ $(( `date +%s` - _clp_ts )) -lt "$CLAN_VALIDADE" ]; then
        unset _clp_ts
        return 0
    fi
    unset _clp_ts

    fetch_page "/clan/${CLD}/" "$TMP/CLANPG" 2>/dev/null
    if [ -s "$TMP/CLANPG" ]; then
        _CLAN_TS=`date +%s`
        return 0
    fi
    _CLAN_TS=0
    return 1
}

clanDungeon() {
    [ -n "$CLD" ] || return 1

    printf "Masmorra do cla\n"
    # O "?close" dispensa o painel de recompensa da rodada anterior, que
    # fica na frente do link de golpe.
    fetch_page "/clandungeon/?close" "$TMP/DUNGEON" 2>/dev/null
    [ -s "$TMP/DUNGEON" ] || { printf "Masmorra: pagina vazia\n"; return 1; }

    _cl=`masmorra_golpe "$TMP/DUNGEON"`

    # Sem golpe na pagina fixa: procura a porta da masmorra no menu do cla.
    if [ -z "$_cl" ]; then
        clan_pagina
        # So caminhos: o "[a-z0-9/]" ja descarta /images/dungeon.png e
        # qualquer coisa com ponto, que seria um arquivo e nao uma pagina.
        _porta=`grep -o -E "/[a-z0-9/]{0,20}dungeon[a-z0-9/]{0,20}" "$TMP/CLANPG" 2>/dev/null \
                | grep -v -E "image|/js/|/css/" | sed -n 1p`
        if [ -n "$_porta" ] && [ "$_porta" != "/clandungeon/" ]; then
            printf "Masmorra: entrando por %s\n" "$_porta"
            fetch_page "$_porta" "$TMP/DUNGEON" 2>/dev/null
            _cl=`masmorra_golpe "$TMP/DUNGEON"`
        fi
        unset _porta
    fi

    # Golpes gratuitos restantes. O numero vem separado por tags no HTML
    # cru, entao e preciso remove-las antes de casar.
    _golpes=`sed 's/<[^>]*>//g' "$TMP/DUNGEON" 2>/dev/null \
             | grep -oE "(Golpes mais|Осталось ударов):[^0-9]{0,8}[0-9]{1,3}" | grep -oE '[0-9]{1,3}$' | head -n1`
    [ -n "$_golpes" ] && printf "Masmorra: %s golpes disponiveis\n" "$_golpes"

    if [ -z "$_cl" ]; then
        masmorra_dump "$TMP/DUNGEON"
        unset _cl _golpes
        return 1
    fi

    # SOMENTE GOLPES GRATUITOS: o link seguido e sempre o de ataque; quando
    # os gratuitos acabam o link some e o laco encerra. Tetos de 180s e
    # FUNC_masmorra_max golpes, caso o link um dia pare de sumir.
    _max=${FUNC_masmorra_max:-15}
    case "$_max" in ''|*[!0-9]*) _max=15 ;; esac
    _br=$(($(date +%s) + 180))
    _n=0
    while [ "$(date +%s)" -lt "$_br" ] && [ "$_n" -lt "$_max" ]; do
        [ -n "$_cl" ] || break
        if ! fetch_page "$_cl" "$TMP/DUNGEON"; then
            printf "Masmorra: falha de rede no golpe %s\n" "$((_n + 1))"
            break
        fi
        _n=$((_n + 1))
        printf "Masmorra: golpe %s\n" "$_n"
        sleep 1
        _cl=`masmorra_golpe "$TMP/DUNGEON"`
    done

    unset _golpes _br _max
    # Feita so quando o link de golpe SUMIU numa pagina do jogo (a de login
    # tambem nao tem o link). Cortado por rede ou teto ainda ha golpe, e o 0
    # levaria a masmorra_marcar a esperar 8h.
    if [ "$_n" -gt 0 ] && [ -z "$_cl" ] && [ "`sessao_estado "$TMP/DUNGEON"`" = viva ]; then
        printf "Masmorra do cla ok (%s golpes)\n" "$_n"
        unset _n _cl
        return 0
    fi
    [ "$_n" -gt 0 ] && printf "Masmorra: %s golpe(s) e ainda ha golpe - volta mais cedo\n" "$_n"
    unset _n _cl
    return 1
}

# Conta e lider/oficial do cla?
# A pagina do cla so mostra o link de administracao para quem tem cargo.
clan_lider() {
    [ -n "$CLD" ] || return 1
    clan_pagina || return 1
    grep -q -E "/clan/${CLD}/[0-9]+/adm/" "$TMP/CLANPG"
}

# Estatua do Cla: mantem os bonus ativos em /clan/<CLD>/built/.
#
#   ?privateUpgrade=true&r=N   Bonus Pessoal   (ouro DA CONTA — NUNCA usado)
#   ?goldUpgrade=true&r=N      Cla Bonus Ouro  (ouro da TESOURARIA do cla)
#   ?silverUpgrade=true&r=N    Cla Bonus Prata (prata da TESOURARIA do cla)
#
# Bonus ja ativo: o link some e a pagina mostra "Tempo de sobra". Apos uma
# tentativa espera FUNC_estatua_horas antes de repetir: reclicar com a
# tesouraria sem saldo nao muda nada, so gasta requisicao.
estatua_liberada() {
    _h=${FUNC_estatua_horas:-6}
    case "$_h" in ''|*[!0-9]*) _h=6 ;; esac
    _u=`cat "$TMP/last_estatua" 2>/dev/null`
    case "$_u" in ''|*[!0-9]*) _u=0 ;; esac
    _u=$(( $(date +%s) - _u ))
    [ "$_u" -lt 0 ] || [ "$_u" -ge $((_h * 3600)) ]    # negativo: relogio voltou
}
estatua_marcar() { date +%s > "$TMP/last_estatua" 2>/dev/null; }

clan_statue() {
    [ "${FUNC_clan_statue:-y}" = "y" ] || return 1
    [ -n "$CLD" ] || return 1

    # O PORTAO VEM ANTES DO CARGO: o clan_lider baixa /clan/<CLD>/, e com ele
    # na frente toda varredura (:00 e :30) pedia a pagina do cla para nada.
    # Se a ultima tentativa foi recusada, espera antes de repetir.
    estatua_liberada || return 1

    # Bonus do cla so podem ser ativados por quem tem cargo. Conta SEM cargo
    # (pagina do cla lida com a sessao viva) espera o mesmo intervalo antes de
    # perguntar de novo; pagina que nao respondeu nao marca nada.
    if ! clan_lider; then
        [ "`sessao_estado "$TMP/CLANPG"`" = viva ] && estatua_marcar
        return 1
    fi

    fetch_page "/clan/${CLD}/built/" "$TMP/STATUE"
    [ -s "$TMP/STATUE" ] || return 1

    # OS DOIS BONUS DO CLA (tesouraria). NUNCA o Pessoal (privateUpgrade), o
    # unico que tira ouro da conta: nao entra na lista e nenhum link com ele
    # e pedido.
    for _up in silverUpgrade goldUpgrade; do
        case "$_up" in
            silverUpgrade) _nm="PRATA"; _moeda="prata" ;;
            goldUpgrade)   _nm="OURO";  _moeda="ouro" ;;
        esac
        _cl=`grep -o -E "/clan/${CLD}/built/[?]${_up}=true&r=[0-9]+" "$TMP/STATUE" | sed -n 1p`
        case "$_cl" in *privateUpgrade*) _cl="" ;; esac
        if [ -n "$_cl" ]; then
            fetch_page "$_cl" "$TMP/STATUE2"
            # Reler a PAGINA DA ESTATUA: a resposta do clique nao traz o link
            # mesmo quando a ativacao falha. Sem resposta, sai SEM marcar
            # (pagina vazia diria "ativado" e esconderia o bonus de ouro).
            if ! fetch_page "/clan/${CLD}/built/" "$TMP/STATUE2" || [ ! -s "$TMP/STATUE2" ]; then
                printf "Estatua: sem resposta ao conferir o bonus de %s\n" "$_nm"
                unset _nm _moeda _up _cl
                return 1
            fi
            # Link ainda na pagina relida = nao ativou.
            if grep -q "${_up}=true" "$TMP/STATUE2" 2>/dev/null; then
                printf "Estatua: bonus de %s nao ativou (%s do cla insuficiente)\n" "$_nm" "$_moeda"
            else
                printf "Estatua do cla: bonus de %s ativado (tesouraria do cla)\n" "$_nm"
            fi
            # A pagina relida vale para o proximo bonus: ja reflete o que
            # foi ativado e traz o nonce (?r=) atual.
            cp "$TMP/STATUE2" "$TMP/STATUE" 2>/dev/null
        fi
    done
    unset _nm _moeda
    # Marca a tentativa, com ou sem sucesso (os bonus duram 48h).
    estatua_marcar
    unset _up _cl
    return 0
}

