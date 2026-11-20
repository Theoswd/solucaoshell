# shellcheck disable=SC2148
# bossfight.sh - Batalha com o chefe (/bossfight/), so no servidor RU.
#
# Atualizacao de 18/11/2026 (forum do tiwar.ru, "Битве титанов 15 лет!"):
# cada golpe gasta a MESMA energia da arena e da uma peca de equipamento; o
# jogo veste a mais forte, guarda a mais fraca na colecao e desmancha a
# repetida em prata, sozinho.
#
# Regra do dono (20/11/2026): no RU a energia e do chefe; a arena so quando
# uma missao de arena do cla pede (energia_ru).

# "Все удары" (?usemana=1) gasta a energia toda num pedido so: menos
# processos que golpe a golpe (limite de ~32 do Android). Sem ele, 1 golpe.
# Nunca gasta ouro (botao_pago).
bossfight_func() {
    printf "Chefe\n"
    fetch_page "/bossfight/"
    # A pagina traz o & cru (href="/bossfight/?usemana=1&r=N", 20/11/2026).
    _bf=`grep -o -E "/bossfight/[?]usemana=1&r=[0-9]+" "$TMP/SRC" | sed -n 1p`
    [ -n "$_bf" ] || _bf=`grep -o -E "/bossfight/[?]attack=1&r=[0-9]+" "$TMP/SRC" | sed -n 1p`
    if [ -z "$_bf" ]; then
        printf "  Chefe: sem golpe disponivel agora\n"
    elif botao_pago "$TMP/SRC" "$_bf"; then
        printf "  Chefe: golpe cobra ouro - para aqui\n"
    else
        fetch_page "$_bf"
        printf "  Chefe: %s\n" "$_bf"
    fi
    unset _bf
}

# Arena so com missao de arena do cla: ajudou ou tomou agora (cq_antes) ou ja
# esta com a conta (cq_ativa 3/4). Senao, a energia vai para o chefe.
energia_ru() {
    if [ -n "$CLD" ] && { cq_antes arena 2>/dev/null || cq_ativa 3 || cq_ativa 4; }; then
        arena_duel
    else
        bossfight_func
    fi
}
