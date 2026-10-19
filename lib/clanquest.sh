# clanquest.sh - Missoes do Cla e combinacao com as atividades
#
# A pagina /clan/<CLD>/quest/ lista 8 missoes, cada uma ligada a uma
# atividade. Mapeamento confirmado no jogo:
#
#   1 Gladiador                    Lute na Arena 20x na Liga     -> liga
#   2 Gladiador Lendario           Vença 15x na Liga             -> liga
#   3 Guerreiro da Arena           Lute 75x na Arena             -> arena
#   4 Guerreiro Lendario da Arena  Vença 50x na Arena            -> arena
#   5 Procura por Recursos         Faça 8 pesquisas na Caverna   -> caverna
#   6 Mestre dos torneios          Participe de 6 torneios       -> carreira
#   7 Alquimista                   Faça 2 Elixires               -> elixir
#   8 Velho Lojista                Obtenha 3 pedras ou ervas     -> loja
#
# Regra do dono: antes da atividade, a missao DELA. Se alguem do cla ja a
# tomou e nao concluiu, AJUDA (prioridade); senao, toma. Nunca toma missao de
# atividade que nao vai fazer, e nunca gasta ouro (ver botao_pago).

# IDs de missao por tipo de atividade
cq_ids() {
    case "$1" in
        liga)     echo "1 2" ;;
        arena)    echo "3 4" ;;
        caverna)  echo "5" ;;
        carreira) echo "6" ;;
        elixir)   echo "7" ;;
        mercador) echo "8" ;;
        *)        echo "" ;;
    esac
}

# Baixa a pagina de missoes do cla em $TMP/CQUEST, reaproveitada enquanto
# ninguem clica: todo clique chama cq_invalidar. O teto de tempo cobre outro
# membro do cla mexendo na missao pelo site.
CQ_VALIDADE=${CQ_VALIDADE:-45}

# Marca a pagina como velha. Chamado depois de TODO clique que a altera.
cq_invalidar() { _CQ_TS=0; }

# A ultima requisicao desta conta foi a propria pagina de missoes? So
# reaproveita se nada saiu no meio: o servidor recusa o nonce (?r=) de pagina
# velha, em silencio. O $TMP/.ult_req e gravado pelo motor a cada requisicao.
cq_ultima_foi_ela() {
    _cu=""
    [ -r "$TMP/.ult_req" ] && read -r _cu < "$TMP/.ult_req" 2>/dev/null
    [ "$_cu" = "/clan/${CLD}/quest/" ]
    _cu_rc=$?
    unset _cu
    return $_cu_rc
}

cq_pagina() {
    [ -n "$CLD" ] || clan_id
    [ -n "$CLD" ] || return 1

    _cq_ts="${_CQ_TS:-0}"
    case "$_cq_ts" in '' | *[!0-9]* ) _cq_ts=0 ;; esac
    if [ -s "$TMP/CQUEST" ] && [ "$_cq_ts" -gt 0 ] \
       && [ $(( `date +%s` - _cq_ts )) -ge 0 ] \
       && [ $(( `date +%s` - _cq_ts )) -lt "$CQ_VALIDADE" ] \
       && cq_ultima_foi_ela; then
        unset _cq_ts
        return 0
    fi
    unset _cq_ts

    fetch_page "/clan/${CLD}/quest/" "$TMP/CQUEST"
    if [ -s "$TMP/CQUEST" ]; then
        _CQ_TS=`date +%s`
        # O motor ja grava isto; repetido para valer com fetch_page substituido
        # (testes).
        printf %s "/clan/${CLD}/quest/" > "$TMP/.ult_req" 2>/dev/null
        return 0
    fi
    _CQ_TS=0
    return 1
}

# cq_tomar <tipo>
# Toma a missao do cla correspondente aquela atividade, se houver.
# Devolve 0 se tomou alguma (a atividade vale a pena agora).
# Rele a pagina depois de cada clique (nonce novo) e so confirma se o link
# "take" daquela missao sumiu.
cq_tomar() {
    _tipo="$1"
    [ "${FUNC_clan_quests:-y}" = "y" ] || return 1

    _tomou=1
    for _id in `cq_ids "$_tipo"`; do
        cq_pagina || break
        _cl=`grep -o -E "/clan/${CLD}/quest/take/${_id}/[?]r=[0-9]+" "$TMP/CQUEST" | sed -n 1p`
        [ -n "$_cl" ] || continue
        fetch_page "$_cl"
        cq_invalidar
        if cq_pagina && ! grep -q "/clan/${CLD}/quest/take/${_id}/" "$TMP/CQUEST"; then
            printf "Missao do cla tomada (%s #%s)\n" "$_tipo" "$_id"
            _tomou=0
        else
            printf "Missao do cla nao confirmada (%s #%s)\n" "$_tipo" "$_id"
        fi
    done
    unset _tipo _id _cl
    return $_tomou
}

# cq_assumir <tipo>
# A missao da atividade, com a regra do dono: o botao de ajuda (missao de um
# companheiro, ainda aberta) vem antes do de tomar. Confirma relendo: o
# botao clicado tem de sumir. 0 = ajudou ou tomou alguma.
cq_assumir() {
    _ca_tipo="$1"
    _ca_ok=1
    if [ "${FUNC_clan_help:-y}" = "y" ]; then
        for _ca_id in `cq_ids "$_ca_tipo"`; do
            cq_pagina || break
            _ca_cl=`grep -o -E "/clan/${CLD}/quest/help/${_ca_id}/?[?]r=[0-9]+" "$TMP/CQUEST" | sed -n 1p`
            [ -n "$_ca_cl" ] || continue
            fetch_page "$_ca_cl"
            cq_invalidar
            if cq_pagina && ! grep -q -E "/clan/${CLD}/quest/help/${_ca_id}/?[?]" "$TMP/CQUEST"; then
                printf "Ajudando missao do cla de um companheiro (%s #%s)\n" "$_ca_tipo" "$_ca_id"
                _ca_ok=0
            else
                printf "Ajuda em missao do cla nao confirmada (%s #%s)\n" "$_ca_tipo" "$_ca_id"
            fi
        done
    fi
    # Sem ajuda possivel para nenhuma missao do tipo: toma a que estiver livre.
    if [ "$_ca_ok" = 1 ] && cq_tomar "$_ca_tipo"; then _ca_ok=0; fi
    unset _ca_tipo _ca_id _ca_cl
    return $_ca_ok
}

# cq_falta <id>: quanto falta na missao que esta com ESTA conta (tomada agora
# ou antes, ja sem link de tomar).
#
# O "Cancelar missao" nao prova nada: conta com cargo o ve em todo o cla. So
# quem executa ou ajuda tem o botao "Va la", entre o "Trofeu" e o cancelar:
#
#   Alquimista Faça 2 Elixires Progresso: 0 de 2 Troféu: 1 645
#   Interpretada por: ... Ajudante: ... <a href='/lab/alchemy/'>Vá lá</a>
#   <a href='/clan/ID/quest/delete/7/?r=N'>Cancelar missão</a>
#
# Devolve 1 (e nada imprime) quando a missao nao esta com a conta ou acabou.
cq_falta() {
    cq_pagina || return 1
    tr '<' '\n' < "$TMP/CQUEST" | awk -v id="$1" '
        /^a [^>]*\/quest\/delete\/[0-9]+\// {
            n = $0; sub(/.*\/quest\/delete\//, "", n); sub(/\/.*/, "", n)
            if (n == id) {
                p = txt; sub(/.*Progresso: */, "", p)
                feito = p + 0; sub(/^[0-9]+ *de */, "", p); alvo = p + 0
                if (vai && alvo > feito) { print alvo - feito; ok = 1 }
                exit
            }
            txt = ""; vai = 0; next
        }
        /Trof/ { vai = 0 }
        /^a / && !/\/user\/|\/clan\// { vai = 1 }
        { l = $0; sub(/^[^>]*>/, " ", l); gsub(/[ \t\r]+/, " ", l); txt = txt l }
        END { exit !ok }'
}
cq_ativa() { cq_falta "$1" > /dev/null; }

# cq_concluir
# Recolhe as missoes ja concluidas.
cq_concluir() {
    [ "${FUNC_clan_quests:-y}" = "y" ] || return 1
    _n=0
    for _id in 1 2 3 4 5 6 7 8; do
        # Releitura so depois de um clique (o cq_pagina reaproveita).
        cq_pagina || break
        _cl=`grep -o -E "/clan/${CLD}/quest/end/${_id}/?[?]r=[0-9]+" "$TMP/CQUEST" | sed -n 1p`
        if [ -n "$_cl" ] && fetch_page "$_cl"; then
            cq_invalidar
            printf "Missao do cla concluida (#%s)\n" "$_id"
            _n=$((_n + 1))
        fi
    done
    unset _id _cl
    [ "$_n" -gt 0 ]
}

# cq_ajudar
# Apoia missoes de companheiros que estejam perto de concluir.
# A ajuda nao cobra ouro no jogo.
cq_ajudar() {
    [ "${FUNC_clan_help:-y}" = "y" ] || return 1
    cq_pagina || return 1

    for _id in 1 2 3 4 5 6 7 8; do
        cq_pagina || break
        _cl=`grep -o -E "/clan/${CLD}/quest/help/${_id}/?[?]r=[0-9]+" "$TMP/CQUEST" | sed -n 1p`
        [ -n "$_cl" ] || continue
        fetch_page "$_cl" || continue
        cq_invalidar
        printf "Ajuda em missao do cla (#%s)\n" "$_id"
    done
    unset _id _cl
    return 0
}

# Concluir missao pagando ouro foi removido: as missoes so avancam pelo jogo.

# cq_antes <tipo>
# Chamada antes de cada atividade: recolhe concluidas, ajuda ou toma a do
# tipo (cq_assumir), e devolve 0 se a atividade esta combinada com alguma.
cq_antes() {
    [ -n "$CLD" ] || return 1
    cq_concluir > /dev/null 2>&1
    cq_assumir "$1"
}

# Sorteio portatil de 1..N: sem shuf (ausente em toybox enxuto) nem $RANDOM
# (nao existe em dash). Semeia com o PID para contas no mesmo segundo.
cq_sorteia() {
    _sn="$1"
    _sc=`cat "$TMP/rnd_seq" 2>/dev/null`
    case "$_sc" in ''|*[!0-9]*) _sc=0 ;; esac
    _sc=$((_sc + 1))
    printf '%s' "$_sc" > "$TMP/rnd_seq" 2>/dev/null
    awk -v n="$_sn" -v s="$$" -v c="$_sc" \
        'BEGIN{ srand(s * 7919 + c * 104729 + systime()); printf "%d", int(rand()*n)+1 }'
    unset _sn _sc
}

# Missao 7 do cla: produzir elixir no laboratorio. So produz o que falta na
# missao; sem missao ativa nao produz nada.
cq_elixir() {
    [ -n "$CLD" ] || return 1
    # Tomada agora ou numa volta anterior (cq_falta). Ja ativa, no maximo uma
    # leva por hora: producao que nao contou nao vira gasto a cada checklist.
    cq_assumir elixir || ativ_liberada cq_elixir 60 || return 1
    _max=`cq_falta 7` || { unset _max; return 1; }
    [ "$_max" -le 3 ] 2>/dev/null || _max=3
    ativ_marcar cq_elixir

    fetch_page "/lab/alchemy/" || return 1
    _i=`cq_sorteia 4`
    fetch_page "/lab/alchemy/${_i}/" || return 1

    _cl=`grep -o -E "/lab/alchemy/${_i}/makePotion[?]r=[0-9]+" "$TMP/SRC" | sed -n 1p`
    [ -n "$_cl" ] || { unset _i _cl; return 1; }
    if botao_pago "$TMP/SRC" "$_cl"; then
        printf "Elixir cobra ouro - nao produz (missao do cla)\n"
        unset _i _cl _max; return 1
    fi

    case "$_i" in
        1) printf "Elixir de forca\n" ;;
        2) printf "Elixir de vida\n" ;;
        3) printf "Elixir de agilidade\n" ;;
        4) printf "Elixir de protecao\n" ;;
    esac

    # O QUE FALTA NA MISSAO, NAO UM NUMERO FIXO. Cada volta rebusca o link:
    # o nonce ?r= muda a cada producao.
    _n=1
    while [ "$_n" -le "$_max" ]; do
        [ -n "$_cl" ] || break
        fetch_page "$_cl"
        printf "Elixir %s de %s\n" "$_n" "$_max"
        _n=$((_n + 1))
        [ "$_n" -le "$_max" ] || break
        _cl=`grep -o -E "/lab/alchemy/${_i}/makePotion[?]r=[0-9]+" "$TMP/SRC" | sed -n 1p`
        botao_pago "$TMP/SRC" "$_cl" && break
    done
    unset _n _max

    cq_concluir 2>/dev/null
    unset _i _cl
    return 0
}

# Missao 8 do cla ("Velho Lojista"): pedras ou ervas do mercador do Coliseu,
# /coliseum/merchant/ (NAO a troca de prata).
cq_mercador() {
    [ -n "$CLD" ] || return 1
    # Mesma regra do cq_elixir: tomada agora, ou ja ativa (uma leva por hora).
    cq_assumir mercador || ativ_liberada cq_mercador 60 || return 1
    _max=`cq_falta 8` || { unset _max; return 1; }
    [ "$_max" -le 3 ] 2>/dev/null || _max=3
    ativ_marcar cq_mercador

    fetch_page "/coliseum/merchant/" || return 1
    _i=`cq_sorteia 2`
    _cl=`grep -o -E "/coliseum/merchant/${_i}/startMaking[?]r=[0-9]+&ref=lab" "$TMP/SRC" | sed -n 1p`
    [ -n "$_cl" ] || { unset _i _cl; return 1; }
    if botao_pago "$TMP/SRC" "$_cl"; then
        printf "Mercador cobra ouro - nao produz (missao do cla)\n"
        unset _i _cl _max; return 1
    fi

    case "$_i" in
        1) printf "Produzindo pedras\n" ;;
        2) printf "Produzindo ervas\n" ;;
    esac

    # O que falta na missao ("Obtenha 3 pedras ou ervas" na pagina real).
    # Cada volta rebusca o link, porque o nonce ?r= muda a cada producao.
    _n=1
    while [ "$_n" -le "$_max" ]; do
        [ -n "$_cl" ] || break
        fetch_page "$_cl"
        printf "Producao %s de %s\n" "$_n" "$_max"
        _n=$((_n + 1))
        [ "$_n" -le "$_max" ] || break
        _cl=`grep -o -E "/coliseum/merchant/${_i}/startMaking[?]r=[0-9]+&ref=lab" "$TMP/SRC" | sed -n 1p`
        botao_pago "$TMP/SRC" "$_cl" && break
    done
    unset _max
    unset _n

    cq_concluir 2>/dev/null
    unset _i _cl
    return 0
}
