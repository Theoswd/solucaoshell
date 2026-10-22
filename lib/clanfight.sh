#
#/clanfight/dodge/?r=0
#/clanfight/attack/?r=0
#/clanfight/attackrandom/?r=0
#/clanfight/heal/?r=0
#/clanfight/stone/?r=0
#/clanfight/grass/?r=0
#/clanfight/?out_gate
clanfight_fight() {
  cd "$TMP" || return 1
  LA=4
  HPER=48
  RPER=15
  cf_access() {
    # Alvo cinza uma vez por pagina.
    if alvo_grey "$TMP/SRC"; then _grey=1; else _grey=0; fi
    erva_gratis clanfight "$TMP/SRC" > GRASS
    alvo_nome "$TMP/SRC" > USER 2>/dev/null
    aliado_ler cla
    luta_ler "$TMP/SRC" HP \
        -e '(/[a-z]+/[a-z]{0,4}at[a-z]{0,3}k/[^A-Za-z0-9]r[^A-Za-z0-9][0-9]+)' \
        -e '(/[a-z]+/at[a-z]{0,3}k[a-z]{3,6}/[^A-Za-z0-9]r[^A-Za-z0-9][0-9]+)' \
        -e '(/clanfight/dodge/[^A-Za-z0-9]r[^A-Za-z0-9][0-9]+)' \
        -e '(/clanfight/heal/[^A-Za-z0-9]r[^A-Za-z0-9][0-9]+)' \
        -e "(hp)[^A-Za-z0-9]{1,4}[0-9]{1,6}"
    # HP da pagina lido uma vez; cura e esquiva comparadas uma vez por pagina.
    _cura=0; { [ -s HEAL ] || [ -s GRASS ]; } && luta_menor "$_hp" "$_hlhp" && _cura=1
    _caiu=0; [ -s DODGE ] && luta_menor "$_hp" "$_old_hp" && _caiu=1
    if [ "$_emluta" = 1 ]; then
      # A pagina respondeu com a luta: sessao confirmada.
      _reconf=0
      sessao_marcar
      printf "Em batalha clanfight - HP: %s\n" "$_hp"
      # Morto com a luta ainda na tela (ver luta_hp, em info.sh).
      if luta_hp "$_hp"; then
        # Antes de encerrar, tenta voltar: com unrip na pagina, ressuscitar()
        # rele a luta e a conta continua.
        if ressuscitar clanfight "$TMP/SRC"; then
          cf_access
          return
        fi
        LUTA_MOTIVO="o jogo declarou o personagem morto (HP 0 com a luta na tela)"
        batalha_limpar; echo 1 > BREAK_LOOP
        printf "Battle is over! (%s)\n" "$LUTA_MOTIVO"
      fi
    else
      # RECONFIRMA antes de desistir: uma leitura sem /dodge/ pode ser
      # transicao, rede ou link vazio que baixou a home. Rele UMA vez.
      if [ "${_reconf:-0}" = 0 ]; then
        _reconf=1
        (
          run_curl_exec "${URL}/clanfight" > "$TMP/SRC"
        ) </dev/null > /dev/null 2>&1 &
        time_exit 17
        cf_access
        return
      fi
      _reconf=0
      # Nem a releitura trouxe a esquiva: quem decide o fim e o jogo. A
      # releitura pode ter trazido o unrip.
      if ressuscitar clanfight "$TMP/SRC"; then
        cf_access
        return
      fi
      if luta_acabou "$TMP/SRC" clanfight; then
        echo 1 > BREAK_LOOP
        printf "Battle is over! (%s)\n" "$LUTA_MOTIVO"
      fi
    fi
  }

  # Limiar de cura uma vez por luta: depende so do HP maximo.
  awk -v ush="$(cat FULL)" -v hper="$HPER" 'BEGIN { printf "%.0f", ush * hper / 100 }' > HLHP
  _hlhp=`cat HLHP`; _old_hp=""
  luta_inicio clanfight
  # Zerado ANTES da primeira leitura: uma luta ja encerrada (retomada) grava
  # o BREAK_LOOP nela.
  : > BREAK_LOOP
  cf_access
  cat HP > old_HP; _old_hp="$_hp"; _caiu=0
  echo $(($(date +%s) - 20)) > last_dodge
  echo $(($(date +%s) - 90)) > last_heal
  echo $(($(date +%s) - LA)) > last_atk

  # Teto de seguranca (luta_teto): quem encerra a luta e o jogo, pelo luta_acabou.
  FIGHT_BREAK=`luta_teto`
  # Link vazio nunca vira requisicao: cada ramo exige o proprio link na pagina.
  # SEM RELEITURA NO TOPO DO LACO: cada ramo ja rele apos a sua acao.
  # Um "date" por volta: o mesmo instante decide o teto e a recarga.
  while _atk0=$(date +%s); [ ! -s "BREAK_LOOP" ] && [ "$_atk0" -le "$FIGHT_BREAK" ]; do
    # _atk0 e o INICIO da volta: o tempo do request conta dentro da recarga.
    # Uma leitura so do last_atk por volta.
    read -r _latk < last_atk; _latk=$(( _atk0 - _latk ))
    # PRIORIDADE 1 — CURA: manter a conta viva vem antes da esquiva.
    if { [ -s HEAL ] || [ -s GRASS ]; } && \
       [ "$_cura" = 1 ] && \
       { read -r _lrec < last_heal; [ $(( _atk0 - _lrec )) -gt 90 ]; }; then
      _saiu=0
      if [ -s HEAL ]; then
        (
          read -r _l < HEAL; run_curl_exec "${URL}$_l" > "$TMP/SRC"
        ) </dev/null > /dev/null 2>&1 &
        time_exit 17; pedido_nao_saiu || _saiu=1
        sleep 0.3s
        # A cura trocou a pagina: o link da erva (nonce ?r=) sai da nova.
        erva_gratis clanfight "$TMP/SRC" > GRASS
      fi
      if [ -s GRASS ]; then
        (
          read -r _l < GRASS; run_curl_exec "${URL}$_l" > "$TMP/SRC"
        ) </dev/null > /dev/null 2>&1 &
        time_exit 17; pedido_nao_saiu || _saiu=1
      fi
      cf_access
      # FULL nunca e trocado pelo HP atual pos-cura; so a base do dodge muda.
      # Pedido que nao saiu (pedido_nao_saiu): a acao nao valeu.
      if [ "$_saiu" = 1 ]; then
        cat HP > old_HP; _old_hp="$_hp"; _caiu=0
        date +%s > last_heal
      fi

    # PRIORIDADE 2 — ESQUIVA: so quando a cura nao foi necessaria/possivel.
    elif [ -s DODGE ] && [ "$_grey" = 0 ] && \
         { read -r _lrec < last_dodge; [ $(( _atk0 - _lrec )) -gt 20 ]; } && \
         [ "$_caiu" = 1 ]; then
      _saiu=0
      (
        read -r _l < DODGE; run_curl_exec "${URL}$_l" > "$TMP/SRC"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17; pedido_nao_saiu || _saiu=1
      cf_access
      # Pedido que nao saiu (pedido_nao_saiu): a acao nao valeu.
      if [ "$_saiu" = 1 ]; then
        cat HP > old_HP; _old_hp="$_hp"; _caiu=0
        date +%s > last_dodge
      fi

    # Aliado na frente: troca de alvo (troca_aliado, em allies.sh). So por
    # aliado (regra do dono), com fogo amigo para nao virar laco de trocas.
    elif [ -s ATKRND ] && [ "$_latk" -ne "$LA" ] && [ "$_grey" = 0 ] && \
         troca_aliado "$_atk0"; then
      (
        read -r _l < ATKRND; run_curl_exec "${URL}$_l" > "$TMP/SRC"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17
      cf_access
      echo "$_atk0" > last_atk
      sleep 0.3s

    elif [ -s ATK ] && \
         [ "$_latk" -gt "$LA" ]; then
      (
        read -r _l < ATK; run_curl_exec "${URL}$_l" > "$TMP/SRC"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17
      cf_access
      echo "$_atk0" > last_atk
    else
      # RECARGA DE ATAQUE — UMA REQUISICAO POR CICLO. So rele com o alvo grey
      # ou sem link de ataque (senao dormiria sobre pagina sem acao); fora
      # disso espera o restante da recarga, sem requisicao.
      if [ "$_grey" = 1 ] || [ ! -s ATK ]; then
        (
          run_curl_exec "${URL}/clanfight" > "$TMP/SRC"
        ) </dev/null > /dev/null 2>&1 &
        time_exit 17
        # A releitura ja e a reconfirmacao (sem a marca, o cf_access relia).
        _reconf=1
        cf_access
        # Sempre: com o alvo cinza e ataque na tela, a releitura seguia sem pausa.
        sleep 1
      else
        # Fim do giro: nunca espera zero (com _latk == LA o "-gt" ainda nao
        # deixa o golpe sair e o laco giraria sem dormir).
        _resta=$(( LA - _latk ))
        [ "$_resta" -gt 0 ] || _resta=1
        # Relogio do aparelho voltou (last_atk no futuro): nunca mais que LA.
        [ "$_resta" -le "$LA" ] || _resta=$LA
        sleep "$_resta"
      fi
    fi
  done

  unset cf_access _random
  func_unset
  printf "ClanFight ok\n"
  [ -t 1 ] && clear
}

clanfight_start() {
  # Chave FUNC_clan_fight (corrigida do antigo "figth"). Desligado depois do
  # evento_dedicar: cancela, senao a conta ficaria parada no evento_espera.
  [ "${FUNC_clan_fight:-y}" = "y" ] || { evento_cancelar clanfight; return 0; }
  cd "$TMP" || return 1
  case `date +%H:%M` in
  10:5[5-9]|18:5[5-9])
    full_atualizar "$TMP/FULL"
    (
      run_curl_exec "$URL/clanfight/?close=reward" > "$TMP/SRC"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17
    # Inscricao: a batalha fica anotada para o worker relancado voltar a ela.
    batalha_marcar clanfight
    (
      run_curl_exec "$URL/clanfight/enterFight" > "$TMP/SRC"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17
    printf "The clan tournament will be started...\n"
    # Espera ate :59:30, so dentro da janela (espera_janela), escalonado por
    # conta em :59:00-:59:29 (janela_alvo).
    espera_janela 5500 `janela_alvo 5900`
    (
      run_curl_exec "$URL/clanfight/enterFight" > "$TMP/SRC"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17
    link_acao "$TMP/SRC" clanfight > "$TMP/ACCESS" 2>/dev/null
    printf " Entering...\n"
    printf " Waiting...\n"
    # 95s: com a inscricao escalonada a conta pode entrar em :59:00.
    BREAK=$(($(date +%s) + 95))
    # Termina com LUTA na pagina (qualquer acao), nao so com a esquiva.
    until [ "`estado_luta "$TMP/SRC" clanfight`" = luta ] || [ "$(date +%s)" -gt "$BREAK" ]; do
      printf " ...\n%s\n" "`cat "$TMP/ACCESS"`"
      (
        run_curl_exec "${URL}/clanfight/" > "$TMP/SRC"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17
      link_acao "$TMP/SRC" clanfight > "$TMP/ACCESS" 2>/dev/null
      sleep 3
    done
    clanfight_fight
    ;;
  esac
}
