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

# "Все удары" (?usemana=1) da todos os golpes que a energia paga (~900 cada)
# num pedido so: menos processos que golpe a golpe (limite de ~32 do Android).
# Ele so aparece com energia para um golpe. O "1 УДАР" (?attack=1) aparece
# SEMPRE: sem energia nao golpeia, abre a oferta "Настойка бодрости ... 308
# золота" (pagina real de 20/11/2026). Por isso o bot nunca o clica.
# Nunca gasta ouro (botao_pago).
# Pedido sem resposta aparece como tal no log: antes a pagina vazia virava
# "sem energia" e o golpe sem resposta era mostrado como feito.
bossfight_func() {
    printf "Chefe\n"
    if ! fetch_page "/bossfight/"; then
        printf "  Chefe: sem resposta - tenta na proxima volta\n"
        return 0
    fi
    # A pagina traz o & cru (href="/bossfight/?usemana=1&r=N", 20/11/2026).
    _bf=`grep -o -E "/bossfight/[?]usemana=1&r=[0-9]+" "$TMP/SRC" | sed -n 1p`
    if [ -z "$_bf" ]; then
        printf "  Chefe: sem energia para um golpe agora\n"
    elif botao_pago "$TMP/SRC" "$_bf"; then
        printf "  Chefe: golpe cobra ouro - para aqui\n"
    elif fetch_page "$_bf"; then
        printf "  Chefe: %s\n" "$_bf"
    else
        printf "  Chefe: golpe sem resposta (%s) - tenta na proxima volta\n" "$_bf"
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
