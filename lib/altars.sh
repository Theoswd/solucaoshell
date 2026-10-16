altars_fight() {
  cd "$TMP" || return 1
  # Sem apply_event aqui nem no fim: a inscricao e do altars_start.
  LA=4
  echo "48" > HPER
  echo "15" > RPER

  cf_access() {
    # Alvo cinza uma vez por pagina.
    if alvo_grey "$TMP/src.html"; then _grey=1; else _grey=0; fi
    grep -o -E '(/[a-z]+/[a-z]{0,4}at[a-z]{0,3}k/[?]r[=][0-9]+)' "$TMP/src.html" | sed -n 1p > ATK 2>/dev/null
    grep -o -E '(/[a-z]+/at[a-z]{0,3}k[a-z]{3,6}/[?]r[=][0-9]+)' "$TMP/src.html" | sed -n 1p > ATKRND 2>/dev/null
    grep -o -E '(/altars/dodge/[?]r[=][0-9]+)' "$TMP/src.html" | sed -n 1p > DODGE 2>/dev/null
    grep -o -E '(/altars/heal/[?]r[=][0-9]+)' "$TMP/src.html" | sed -n 1p > HEAL 2>/dev/null
    alvo_nome "$TMP/src.html" > USER 2>/dev/null
    aliado_ler cla
    grep -o -E "(hp)[^A-Za-z0-9]{1,4}[0-9]{1,6}" "$TMP/src.html" | sed "s,hp[']\\/[>],,;s,\ ,," > HP 2>/dev/null
    # HP da pagina lido uma vez; cura e esquiva comparadas uma vez por pagina.
    _hp=`cat HP`
    _cura=0; [ -s HEAL ] && awk -v ush="$_hp" -v hlhp="$_hlhp" 'BEGIN { exit !(ush < hlhp) }' && _cura=1
    _caiu=0; [ -s DODGE ] && awk -v ush="$_hp" -v oldhp="$_old_hp" 'BEGIN { exit !(ush < oldhp) }' && _caiu=1
    if grep -q -o '/dodge/' "$TMP/src.html"; then
      # A pagina respondeu com a luta: sessao confirmada.
      _reconf=0
      sessao_marcar
      printf "Em batalha - HP: %s\n" "$_hp"
      # Morto com a luta ainda na tela (ver luta_hp, em info.sh).
      if luta_hp "$_hp"; then
        # Antes de encerrar, tenta voltar: com unrip na pagina, ressuscitar()
        # rele a luta e a conta continua.
        if ressuscitar altars "$TMP/src.html"; then
          cf_access
          return
        fi
        LUTA_MOTIVO="o jogo declarou o personagem morto (HP 0 com a luta na tela)"
        batalha_limpar; echo 1 > BREAK_LOOP
        printf "Battle over! (%s)\n" "$LUTA_MOTIVO"
      fi
    else
      # RECONFIRMA antes de desistir (transicao/soluco de rede/link vazio->home):
      # rele a pagina de luta UMA vez e reavalia; so encerra se nao houver /dodge/.
      if [ "${_reconf:-0}" = 0 ]; then
        _reconf=1
        (
          run_curl_exec "${URL}/altars" > "$TMP/src.html"
        ) </dev/null > /dev/null 2>&1 &
        time_exit 17
        cf_access
        return
      fi
      _reconf=0
      # Nem a releitura trouxe a esquiva: quem decide o fim e o jogo. A
      # releitura pode ter trazido o unrip.
      if ressuscitar altars "$TMP/src.html"; then
        cf_access
        return
      fi
      if luta_acabou "$TMP/src.html" altars; then
        echo 1 > BREAK_LOOP
        printf "Battle over! (%s)\n" "$LUTA_MOTIVO"
      fi
    fi
  }

  # Limiar de cura uma vez por luta: depende so do HP maximo.
  awk -v ush="$(cat FULL)" -v hper="$(cat HPER)" 'BEGIN { printf "%.0f", ush * hper / 100 }' > HLHP
  _hlhp=`cat HLHP`; _old_hp=""
  luta_inicio altars
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
  # SEM RELEITURA NO TOPO DO LACO: cada ramo ja rele apos a sua acao.
  # Link vazio nunca vira requisicao: cada ramo exige o proprio link na pagina.
  # Um "date" por volta: o mesmo instante decide o teto e a recarga.
  while _atk0=$(date +%s); [ ! -s "BREAK_LOOP" ] && [ "$_atk0" -le "$FIGHT_BREAK" ]; do
    # _atk0 e o INICIO da volta: o tempo do request conta dentro da recarga.
    # Uma leitura so do last_atk por volta.
    read -r _latk < last_atk; _latk=$(( _atk0 - _latk ))
    # PRIORIDADE 1 — CURA: manter a conta viva vem antes da esquiva.
    if [ -s HEAL ] && \
       [ "$_cura" = 1 ] && \
       { read -r _lrec < last_heal; [ $(( _atk0 - _lrec )) -gt 90 ]; }; then
      _saiu=0
      (
        read -r _l < HEAL; run_curl_exec "${URL}$_l" > "$TMP/src.html"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17; pedido_nao_saiu || _saiu=1
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
        read -r _l < DODGE; run_curl_exec "${URL}$_l" > "$TMP/src.html"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17; pedido_nao_saiu || _saiu=1
      cf_access
      # Pedido que nao saiu (pedido_nao_saiu): a acao nao valeu.
      if [ "$_saiu" = 1 ]; then
        cat HP > old_HP; _old_hp="$_hp"; _caiu=0; date +%s > last_dodge
      fi

    # Aliado na frente: troca de alvo (troca_aliado, em allies.sh). So por
    # aliado (regra do dono), com fogo amigo para nao virar laco de trocas.
    elif [ -s ATKRND ] && [ "$_latk" -ne "$LA" ] && [ "$_grey" = 0 ] && \
         troca_aliado "$_atk0"; then
      (
        read -r _l < ATKRND; run_curl_exec "${URL}$_l" > "$TMP/src.html"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17
      cf_access
      echo "$_atk0" > last_atk

    elif [ -s ATK ] && \
         [ "$_latk" -gt "$LA" ]; then
      (
        read -r _l < ATK; run_curl_exec "${URL}$_l" > "$TMP/src.html"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17
      cf_access
      echo "$_atk0" > last_atk
    else
      # RECARGA DE ATAQUE — UMA REQUISICAO POR CICLO. So rele com o alvo grey
      # ou sem link de ataque (senao dormiria sobre pagina sem acao).
      if [ "$_grey" = 1 ] || [ ! -s ATK ]; then
        (
          run_curl_exec "${URL}/altars" > "$TMP/src.html"
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
  printf "Altars ok\n"
  [ -t 1 ] && clear
}

altars_start() {
  case `date +%H:%M` in
  (13:5[5-9]|20:5[5-9])
    full_atualizar "$TMP/FULL"

    fetch_page "/altars/?close=reward" "$TMP/src.html"
    # Inscricao: a batalha fica anotada para o worker relancado voltar a ela.
    batalha_marcar altars
    fetch_page "/altars/enterFight" "$TMP/src.html"
    printf "Ancient Altars will be started...\n"

    # Ate :59:50-:59:59, escalonado por conta (janela_alvo, em info.sh).
    espera_janela 5500 `janela_alvo 5950 10`

    fetch_page "/altars/enterFight" "$TMP/src.html"
    printf "Altars will be started...\n"
    link_acao "$TMP/src.html" altars > "$TMP/ACCESS" 2>/dev/null
    printf " Entering...\n"
    printf " Waiting...\n"
    # 60s; termina com LUTA na pagina (qualquer acao), nao so com a esquiva.
    BREAK=$(($(date +%s) + 60))
    until [ "`estado_luta "$TMP/src.html" altars`" = luta ] || [ "$(date +%s)" -gt "$BREAK" ]; do
      printf "%s\n ...\n%s\n" "$URL" "`cat "$TMP/ACCESS"`"
      fetch_page "/altars" "$TMP/src.html"
      link_acao "$TMP/src.html" altars > "$TMP/ACCESS" 2>/dev/null
      sleep 3
    done
    altars_fight
    ;;
  esac
}
