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
# A ideia e sempre TOMAR a missao antes de executar a atividade, para que
# o progresso conte. Fazer a atividade sem a missao ativa desperdiça a
# tentativa.

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

# Baixa a pagina de missoes do cla em $TMP/CQUEST.
#
# A PAGINA E REAPROVEITADA ENQUANTO NINGUEM CLICA.
#
# Medido: um ciclo de tarefas_livres pedia esta MESMA pagina 23 vezes, de 41
# requisicoes no total. Ela e consultada por tres caminhos — as cq_* daqui, o
# checkQuest (clanid.sh) e o clanQuests — e o cq_antes sozinho pedia duas
# vezes seguidas, porque cq_concluir e cq_tomar chamam cada um o cq_pagina.
#
# O conteudo so muda quando ALGUEM CLICA num link dela. Entao: reaproveita
# enquanto ninguem clicou, e todo clique chama cq_invalidar para a proxima
# consulta buscar de novo. O teto de tempo cobre o caso de outro membro do
# cla mexer na missao pelo site, sem o bot saber.
CQ_VALIDADE=${CQ_VALIDADE:-45}

# Marca a pagina como velha. Chamado depois de TODO clique que a altera.
cq_invalidar() { _CQ_TS=0; }

# A ultima requisicao desta conta foi a propria pagina de missoes?
#
# SO REAPROVEITA SE NADA SAIU NO MEIO.
#
# O cache guardava a leitura por 45s mesmo com outras requisicoes no meio —
# o checkQuest "end" roda DEPOIS da arena, da caverna, da carreira. Os links
# da pagina levam um nonce (?r=), e o proprio projeto registra, no king.sh e
# no check.sh, o servidor recusando nonce de pagina antiga: a missao nao era
# tomada nem encerrada, em silencio. O $TMP/.ult_req (gravado pelo motor a
# cada requisicao) diz se houve outra depois; havendo, le de novo. As duas
# leituras seguidas do cq_antes — a economia medida — continuam uma so.
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
        # O motor ja grava isto; repetido aqui para valer tambem quando o
        # fetch_page for substituido (testes).
        printf %s "/clan/${CLD}/quest/" > "$TMP/.ult_req" 2>/dev/null
        return 0
    fi
    _CQ_TS=0
    return 1
}

# cq_tomar <tipo>
# Toma a missao do cla correspondente aquela atividade, se houver.
# Devolve 0 se tomou alguma (a atividade vale a pena agora).
cq_tomar() {
    _tipo="$1"
    [ "${FUNC_clan_quests:-y}" = "y" ] || return 1
    cq_pagina || return 1

    _tomou=1
    for _id in `cq_ids "$_tipo"`; do
        _cl=`grep -o -E "/clan/${CLD}/quest/take/${_id}/[?]r=[0-9]+" "$TMP/CQUEST" | sed -n 1p`
        if [ -n "$_cl" ]; then
            fetch_page "$_cl"
            cq_invalidar
            printf "Missao do cla tomada (%s #%s)\n" "$_tipo" "$_id"
            _tomou=0
        fi
    done
    unset _tipo _id _cl
    return $_tomou
}

# cq_concluir
# Recolhe as missoes ja concluidas.
cq_concluir() {
    [ "${FUNC_clan_quests:-y}" = "y" ] || return 1
    cq_pagina || return 1
    _n=0
    for _id in 1 2 3 4 5 6 7 8; do
        _cl=`grep -o -E "/clan/${CLD}/quest/end/${_id}/?[?]r=[0-9]+" "$TMP/CQUEST" | sed -n 1p`
        if [ -n "$_cl" ]; then
            fetch_page "$_cl"
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
# A ajuda nao cobra ouro no jogo (conferido pelo dono do bot, 14/09).
cq_ajudar() {
    [ "${FUNC_clan_help:-y}" = "y" ] || return 1
    cq_pagina || return 1

    for _id in 1 2 3 4 5 6 7 8; do
        _cl=`grep -o -E "/clan/${CLD}/quest/help/${_id}/?[?]r=[0-9]+" "$TMP/CQUEST" | sed -n 1p`
        [ -n "$_cl" ] || continue
        fetch_page "$_cl"
        cq_invalidar
        printf "Ajuda em missao do cla (#%s)\n" "$_id"
    done
    unset _id _cl
    return 0
}

# CONCLUIR MISSAO DO CLA PAGANDO OURO: REMOVIDO.
#
# A funcao cq_forcar_ouro pagava com ouro as missoes do cla que travavam.
# O bot nao gasta ouro, entao ela foi apagada junto com as chaves
# FUNC_quest_force_gold e FUNC_quest_gold_min. As missoes agora so avancam
# pelo jogo: cq_concluir recolhe as prontas e cq_ajudar apoia as dos
# companheiros.

# cq_antes <tipo>
# Chamada antes de cada atividade: recolhe concluidas, toma a do tipo,
# e devolve 0 se a atividade esta combinada com alguma missao.
cq_antes() {
    [ -n "$CLD" ] || return 1
    cq_concluir > /dev/null 2>&1
    cq_tomar "$1"
}

# Sorteio portatil de 1..N. Nao usa shuf (ausente em ash/toybox enxutos)
# nem $RANDOM (nao existe em dash). Semeia com o PID para que contas
# diferentes no mesmo segundo nao escolham sempre a mesma opcao.
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

# Missao 7 do cla: produzir elixir no laboratorio (secao 17 do prompt).
# So produz o necessario para a missao: toma a missao, faz a pocao e
# encerra. Sem missao ativa nao produz nada.
cq_elixir() {
    [ -n "$CLD" ] || return 1
    cq_tomar elixir || return 1

    fetch_page "/lab/alchemy/" || return 1
    _i=`cq_sorteia 4`
    fetch_page "/lab/alchemy/${_i}/" || return 1

    _cl=`grep -o -E "/lab/alchemy/${_i}/makePotion[?]r=[0-9]+" "$TMP/SRC" | sed -n 1p`
    [ -n "$_cl" ] || { unset _i _cl; return 1; }

    case "$_i" in
        1) printf "Elixir de forca\n" ;;
        2) printf "Elixir de vida\n" ;;
        3) printf "Elixir de agilidade\n" ;;
        4) printf "Elixir de protecao\n" ;;
    esac

    # TRES POCOES, NAO DUAS.
    #
    # CORRECAO: a missao pede TRES elixires e a funcao clicava duas vezes —
    # produzia, rebuscava o link e produzia de novo. Faltando o terceiro, a
    # missao nunca fechava e o slot do cla ficava ocupado ate expirar.
    # E o mesmo defeito que o cq_mercador ja teve e que foi corrigido la;
    # aqui passou batido. Agora os dois usam o mesmo laco, e cada volta
    # rebusca o link porque o nonce ?r= muda a cada producao.
    #
    # O custo e o minimo da missao, que e para ser pago: sem produzir, a
    # missao nao conclui.
    _n=1
    while [ "$_n" -le 3 ]; do
        [ -n "$_cl" ] || break
        fetch_page "$_cl"
        printf "Elixir %s de 3\n" "$_n"
        _n=$((_n + 1))
        [ "$_n" -le 3 ] || break
        _cl=`grep -o -E "/lab/alchemy/${_i}/makePotion[?]r=[0-9]+" "$TMP/SRC" | sed -n 1p`
    done
    unset _n

    cq_concluir 2>/dev/null
    unset _i _cl
    return 0
}

# Missao 8 do cla: obter pedras ou ervas com o mercador do Coliseu
# (secao 18). A missao chama "Velho Lojista", mas a loja dela NAO e a
# troca de prata: e /coliseum/merchant/.
cq_mercador() {
    [ -n "$CLD" ] || return 1
    cq_tomar mercador || return 1

    fetch_page "/coliseum/merchant/" || return 1
    _i=`cq_sorteia 2`
    _cl=`grep -o -E "/coliseum/merchant/${_i}/startMaking[?]r=[0-9]+&ref=lab" "$TMP/SRC" | sed -n 1p`
    [ -n "$_cl" ] || { unset _i _cl; return 1; }

    case "$_i" in
        1) printf "Produzindo pedras\n" ;;
        2) printf "Produzindo ervas\n" ;;
    esac

    # ALINHADO AO ORIGINAL: TRES producoes, nao duas.
    #
    # A missao do mercador pede tres itens; a nossa versao clicava duas vezes
    # e a missao nunca fechava. Cada volta rebusca o link, porque o nonce ?r=
    # muda a cada producao.
    _n=1
    while [ "$_n" -le 3 ]; do
        [ -n "$_cl" ] || break
        fetch_page "$_cl"
        printf "Producao %s de 3\n" "$_n"
        _n=$((_n + 1))
        [ "$_n" -le 3 ] || break
        _cl=`grep -o -E "/coliseum/merchant/${_i}/startMaking[?]r=[0-9]+&ref=lab" "$TMP/SRC" | sed -n 1p`
    done
    unset _n

    cq_concluir 2>/dev/null
    unset _i _cl
    return 0
}
