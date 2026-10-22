flagfight_fight() {
  # Arquivos de batalha no diretorio da conta (sem mktemp)
  src_ram="$TMP/flag_src"
  full_ram="$TMP/flag_full"

  cd "$TMP" || return 1

  LA=4
  HPER=48
  RPER=15

  cf_access() {
    # Alvo cinza uma vez por pagina.
    if alvo_grey "$src_ram"; then _grey=1; else _grey=0; fi
    alvo_nome "$src_ram" > USER 2>/dev/null
    aliado_ler cla
    luta_ler "$src_ram" USH \
        -e '(/[a-z]+/[a-z]{0,4}at[a-z]{0,3}k/[?]r[=][0-9]+)' \
        -e '(/[a-z]+/at[a-z]{0,3}k[a-z]{3,6}/[?]r[=][0-9]+)' \
        -e '(/flagfight/dodge/[?]r[=][0-9]+)' \
        -e '(/flagfight/heal/[?]r[=][0-9]+)' \
        -e '(/[a-z]+/shield/[?]r[=][0-9]+)' \
        -e "(hp)[^A-Za-z0-9]{1,4}[0-9]{1,6}"
    # HP da pagina lido uma vez; cura e esquiva comparadas uma vez por pagina.
    _cura=0; [ -s SHIELD ] && luta_menor "$_hp" "$_hlhp" && _cura=1
    _caiu=0; [ -s DODGE ] && luta_menor "$_hp" "$_old_hp" && _caiu=1

    if [ "$_emluta" = 1 ]; then
      # A pagina respondeu com a luta: sessao confirmada.
      _reconf=0
      sessao_marcar
      printf "Em batalha flagfight - HP: %s\n" "$_hp"
      # Morto com a luta ainda na tela (ver luta_hp, em info.sh).
      if luta_hp "$_hp"; then
        # Antes de encerrar, tenta voltar: com unrip na pagina, ressuscitar()
        # rele a luta e a conta continua.
        if ressuscitar flagfight "$src_ram"; then
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
          run_curl_exec "${URL}/flagfight" > "$src_ram"
        ) </dev/null > /dev/null 2>&1 &
        time_exit 17
        cf_access
        return
      fi
      _reconf=0
      # Nem a releitura trouxe a esquiva: quem decide o fim e o jogo. A
      # releitura pode ter trazido o unrip.
      if ressuscitar flagfight "$src_ram"; then
        cf_access
        return
      fi
      if luta_acabou "$src_ram" flagfight; then
        echo 1 > BREAK_LOOP
        printf "Battle over! (%s)\n" "$LUTA_MOTIVO"
      fi
    fi
  }

  # Limiar de cura uma vez por luta: depende so do HP maximo.
  awk -v ush="$(cat "$full_ram")" -v hper="$HPER" 'BEGIN { printf "%.0f", ush * hper / 100 }' > HLHP
  _hlhp=`cat HLHP`; _old_hp=""
  luta_inicio flagfight
  # Zerado ANTES da primeira leitura: uma luta ja encerrada (retomada) grava
  # o BREAK_LOOP nela.
  : > BREAK_LOOP
  cf_access
  cat USH > old_HP; _old_hp="$_hp"; _caiu=0
  echo $(($(date +%s) - 20)) > last_dodge
  echo $(($(date +%s) - 90)) > last_heal
  echo $(($(date +%s) - LA)) > last_atk

  # Teto de seguranca (luta_teto): quem encerra a luta e o jogo, pelo luta_acabou.
  FIGHT_BREAK=`luta_teto`
  # Link vazio nunca vira requisicao: cada ramo exige o proprio link na pagina.
  # Um "date" por volta: o mesmo instante decide o teto e a recarga.
  while _atk0=$(date +%s); [ ! -s "BREAK_LOOP" ] && [ "$_atk0" -le "$FIGHT_BREAK" ]; do
    # _atk0 e o INICIO da volta: o tempo do request conta dentro da recarga.
    # Uma leitura so do last_atk por volta.
    read -r _latk < last_atk; _latk=$(( _atk0 - _latk ))
    if [ -s SHIELD ] && \
       [ "$_cura" = 1 ] && \
       { read -r _lrec < last_heal; [ $(( _atk0 - _lrec )) -gt 90 ]; }; then
      _saiu=0
      (
        read -r _l < SHIELD; run_curl_exec "${URL}$_l" > "$src_ram"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17; pedido_nao_saiu || _saiu=1
      cf_access
      # full_ram nunca e trocado pelo HP atual pos-escudo; so a base do dodge muda.
      # Pedido que nao saiu (pedido_nao_saiu): a acao nao valeu.
      if [ "$_saiu" = 1 ]; then
        cat USH > old_HP; _old_hp="$_hp"; _caiu=0
        date +%s > last_heal
      fi

    elif [ -s DODGE ] && [ "$_grey" = 0 ] && \
         { read -r _lrec < last_dodge; [ $(( _atk0 - _lrec )) -gt 20 ]; } && \
         [ "$_caiu" = 1 ]; then
      _saiu=0
      (
        read -r _l < DODGE; run_curl_exec "${URL}$_l" > "$src_ram"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17; pedido_nao_saiu || _saiu=1
      cf_access
      # Pedido que nao saiu (pedido_nao_saiu): a acao nao valeu.
      if [ "$_saiu" = 1 ]; then
        cat USH > old_HP; _old_hp="$_hp"; _caiu=0
        date +%s > last_dodge
      fi

    # Aliado na frente: troca de alvo (troca_aliado, em allies.sh). So por
    # aliado (regra do dono), com fogo amigo para nao virar laco de trocas.
    elif [ -s ATKRND ] && [ "$_latk" -ne "$LA" ] && [ "$_grey" = 0 ] && \
         troca_aliado "$_atk0"; then
      (
        read -r _l < ATKRND; run_curl_exec "${URL}$_l" > "$src_ram"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17
      cf_access
      echo "$_atk0" > last_atk

    elif [ -s ATK ] && \
         [ "$_latk" -gt "$LA" ]; then
      (
        read -r _l < ATK; run_curl_exec "${URL}$_l" > "$src_ram"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17
      cf_access
      echo "$_atk0" > last_atk
    else
      # RECARGA DE ATAQUE — UMA REQUISICAO POR CICLO. So rele com o alvo grey
      # ou sem link de ataque (senao dormiria sobre pagina sem acao); fora
      # disso espera o restante da recarga, sem requisicao.
      if [ "$_grey" = 1 ] || [ ! -s ATK ]; then
        fetch_page "/flagfight" "$src_ram"
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

  rm -f "$src_ram" "$full_ram"
  unset src_ram full_ram ACCESS cf_access
  printf "Flagfight ok\n"
  # Sem apply_event: a inscricao e do flagfight_start.
  [ -t 1 ] && clear
}

flagfight_start() {
  src_ram="$TMP/flag_src"
  full_ram="$TMP/flag_full"

  case `date +%H:%M` in
  (10:1[0-4]|16:1[0-4])
    full_atualizar "$full_ram"
    fetch_page "/flagfight/?close=reward" "$src_ram"
    # Inscricao: a batalha fica anotada para o worker relancado voltar a ela.
    batalha_marcar flagfight
    fetch_page "/flagfight/enterFight" "$src_ram"
    printf "Flagfight will be started...\n"

    # Espera ate :14:30, so dentro da janela (espera_janela, em info.sh).
    espera_janela 1000 `janela_alvo 1400`

    (
      run_curl_exec "$URL/flagfight/enterFight" > "$src_ram"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17
    link_acao "$src_ram" flagfight > "$TMP/ACCESS" 2>/dev/null
    printf " Entering...\n"
    printf " Waiting...\n"

    # 95s: a inscricao e escalonada por conta (janela_alvo).
    BREAK=$(($(date +%s) + 95))

    # Termina com LUTA na pagina (qualquer acao), nao so com a esquiva.
    until [ "`estado_luta "$src_ram" flagfight`" = luta ] || [ "$(date +%s)" -gt "$BREAK" ]; do
      printf " ...\n%s\n" "`cat "$TMP/ACCESS"`"
      fetch_page "/flagfight/" "$src_ram"
      link_acao "$src_ram" flagfight > "$TMP/ACCESS" 2>/dev/null
      sleep 3
    done

    if [ -s "$TMP/ACCESS" ]; then
      flagfight_fight
    else
      # Nada das Bandeiras na pagina: limpa a anotacao (senao o descansar
      # "retomaria" uma luta inexistente) e guarda a pagina para ver o que o
      # jogo mostrou.
      cp "$src_ram" "$TMP/flag_sem_luta.html" 2>/dev/null
      printf "Bandeiras: nenhuma luta na pagina (guardada em %s)\n" "$TMP/flag_sem_luta.html"
      batalha_limpar
      rm -f "$src_ram" "$full_ram"
      unset src_ram full_ram
    fi
    ;;
  esac
}
