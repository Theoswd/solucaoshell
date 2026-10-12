undying_fight() {
  cd "$TMP" || return 1
  LA=5

  # ============================================================
  #  VALE DOS IMORTAIS — NAO ABANDONAR A LUTA ANTES DO FIM
  #  - Link vazio nunca vira pedido: "${URL}" sozinho baixa a home, sem
  #    out_gate, e a conta sairia da luta. Sem link, rele /undying.
  #  - Uma leitura sem out_gate nao encerra: confirma com releitura.
  #  - O undying_start chama arena_fullmana antes, o que leva a sessao para
  #    /arena: a luta comeca relendo /undying. Um golpe a cada LA (5s).
  # ============================================================

  # Rele /undying (o arena_fullmana pode ter navegado para fora), exceto
  # quando o golpe do undying_start ja respondeu: a pagina e a resposta dele,
  # e reler seria um pedido colado no golpe (<5s).
  if [ "${_VL_PAGINA0:-0}" != 1 ]; then
  (
    run_curl_exec "${URL}/undying" > "$TMP/SRC"
  ) </dev/null > /dev/null 2>&1 &
  time_exit 17
  fi

  # Le a pagina: extrai o link de golpe e diz se ainda estamos na luta
  # (retorno 0 = em luta, 1 = fora). NAO encerra a luta sozinho.
  cf_access() {
    grep -o -E '/undying/(hit|mana)/[?][r][=][0-9]+' "$TMP/SRC" | sed -n '1p' > HITMANA 2>/dev/null
    # Erva e pedra de graca (nunca as que cobram ouro): GRASS e STONE.
    itens_gratis undying "$TMP/SRC"
    # Portao na pagina: lido uma vez aqui, o laco usa a marca (_gate).
    _gate=0
    if grep -q -o 'out_gate' "$TMP/SRC"; then
      _gate=1
      sessao_marcar
      # O Vale nao le HP (sem luta_hp): marca aqui que a conta lutou, para o
      # fim sem botao valer em 15s e nao 90s (LUTA_FORA_LUTOU, em info.sh).
      _lt_lutou=1
      printf "Em batalha undying\n"
      # A primeira pagina da luta fica guardada: e a prova dos botoes que o
      # Vale oferece (golpes, erva, pedra), para conferir depois.
      [ "$_vl_pg" = 1 ] || { cp "$TMP/SRC" "$TMP/vale_luta.html" 2>/dev/null; _vl_pg=1; }
      return 0
    fi
    return 1
  }

  # Confirma o fim relendo /undying: quem decide e o jogo (luta_acabou).
  # Retorna 0 se REALMENTE acabou, 1 se ainda ha luta.
  luta_confirmada_fim() {
    (
      run_curl_exec "${URL}/undying" > "$TMP/SRC"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17
    # O Vale nao ressuscita: morreu, o luta_acabou encerra.
    luta_acabou "$TMP/SRC" undying
  }

  # Vale: monstro do jogo, nao jogador. Regra do dono: fazer dano. Uma acao
  # a cada LA (5s), nesta ordem: 1 erva, 2 pedra (de graca, recarga 1 min;
  # itens_gratis descarta as que cobram ouro), 3 golpe (hit/mana).
  _vl_pg=0; _vl_hit=0; _vl_mana=0; _vl_erva=0; _vl_pedra=0; _vl_t1=""; _vl_h1=""
  # Uma acao: o link do arquivo, a releitura da pagina e o relogio.
  _vl_acao() {
    (
      read -r _l < "$1"; run_curl_exec "${URL}$_l" > "$TMP/SRC"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17
    [ -n "$_vl_t1" ] || { _vl_t1="$_agora"; _vl_h1=`date +%H:%M:%S`; }
    cf_access
    _last_act="$_agora"; echo "$_last_act" > last_atk
  }

  luta_inicio undying
  cf_access
  _agora=`date +%s`
  _last_act=$(( _agora - LA ))
  # O golpe do undying_start conta no relogio de 5s e no resumo: o jogo
  # recusa acoes coladas.
  if [ -n "$_VL_GOLPE0" ]; then
    _last_act="$_VL_GOLPE0"; _vl_t1="$_VL_GOLPE0"; _vl_h1="$_VL_HORA0"
    case "$_VL_LINK0" in */mana/*) _vl_mana=1 ;; *) _vl_hit=1 ;; esac
  fi
  unset _VL_GOLPE0 _VL_HORA0 _VL_LINK0 _VL_PAGINA0
  echo "$_last_act" > last_atk
  _last_grass=$(( _agora - 60 )); _last_stone=$(( _agora - 60 ))
  : > BREAK_LOOP

  # Teto de seguranca (luta_teto): so segura o laco que nunca resolve.
  FIGHT_BREAK=`luta_teto`
  # Um "date" por volta: o mesmo instante decide o teto e o relogio de acao.
  while _agora=`date +%s`; [ ! -s "BREAK_LOOP" ] && [ "$_agora" -le "$FIGHT_BREAK" ]; do

    # Relogio de 5s entre golpes (o jogo recusa acoes coladas <4s).
    if [ $(( _agora - _last_act )) -ge "$LA" ]; then
      if [ "$_gate" = 1 ]; then
        if [ -s GRASS ] && [ $(( _agora - _last_grass )) -ge 60 ]; then
          _vl_acao GRASS
          _last_grass="$_agora"; _vl_erva=$(( _vl_erva + 1 ))
        elif [ -s STONE ] && [ $(( _agora - _last_stone )) -ge 60 ]; then
          _vl_acao STONE
          _last_stone="$_agora"; _vl_pedra=$(( _vl_pedra + 1 ))
        elif [ -s HITMANA ]; then
          # Golpe (hit/mana) a cada 5s.
          read -r _hm < HITMANA
          case "$_hm" in
            */mana/*) _vl_mana=$(( _vl_mana + 1 )) ;;
            *)        _vl_hit=$(( _vl_hit + 1 )) ;;
          esac
          _vl_acao HITMANA
        else
          # Em luta, mas sem link nesta leitura: rele /undying (nunca a home).
          (
            run_curl_exec "${URL}/undying" > "$TMP/SRC"
          ) </dev/null > /dev/null 2>&1 &
          time_exit 17
          cf_access
          _last_act="$_agora"; echo "$_last_act" > last_atk
        fi
      else
        # Sem out_gate: confirma o fim antes de desistir.
        if luta_confirmada_fim; then
          echo 1 > BREAK_LOOP
          printf "Undying: luta encerrada (%s).\n" "$LUTA_MOTIVO"
        else
          cf_access
          _last_act="$_agora"; echo "$_last_act" > last_atk
        fi
      fi
    else
      # Dentro dos 5s: espera o restante sem requisitar.
      _resta=$(( LA - ( _agora - _last_act ) ))
      # Relogio do aparelho voltou: nunca mais que LA.
      [ "$_resta" -le "$LA" ] || _resta=$LA
      [ "$_resta" -gt 0 ] && sleep "$_resta"
    fi
  done

  cp "$TMP/SRC" "$TMP/vale_fim.html" 2>/dev/null
  printf "Vale: %s golpes (hit %s, mana %s), erva %s, pedra %s; primeiro golpe %s, ultimo %ss depois\n" \
         "$(( _vl_hit + _vl_mana ))" "$_vl_hit" "$_vl_mana" "$_vl_erva" "$_vl_pedra" \
         "${_vl_h1:--}" "$(( _last_act - ${_vl_t1:-$_last_act} ))"
  unset cf_access luta_confirmada_fim _vl_acao _vl_pg _vl_hit _vl_mana _vl_erva _vl_pedra _vl_t1 _vl_h1 \
        _last_grass _last_stone
  printf "Undying ok\n"
  # Sem apply_event: a inscricao e a do undying_start.
}

undying_start() {
  cd "$TMP" || return 1

  case `date +%H:%M` in
  (09:5[5-9]|15:5[5-9]|21:5[5-9])
    hpmp -fix
    use_elixir
    # Inscricao: a batalha fica anotada para o worker relancado voltar a ela.
    batalha_marcar undying
    apply_event undying
    printf "Valley of the Immortals will be started... %s\n" "`date +%Hh:%Mm`"

    # Ate :59:50-:59:59, escalonado por conta (janela_alvo, em info.sh).
    espera_janela 5500 `janela_alvo 5950 10`

    hpmp -now

    if awk -v hpper="$HPPER" 'BEGIN { exit !(hpper > 20) }' && \
       awk -v mpper="$MPPER" 'BEGIN { exit !(mpper > 10) }'; then
      arena_fullmana
    fi

    while awk -v minute="`date +%M`" 'BEGIN { exit !(minute != 00) }' && [ `date +%M` -gt "57" ]; do
      sleep 5s
    done

    > BREAK_LOOP
    BREAK=$(($(date +%s) + 11))

    until [ -s "BREAK_LOOP" ] || [ "$(date +%s)" -gt "$BREAK" ]; do
      (
        run_curl_exec "$URL/undying" > "$TMP/SRC"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17

      grep -o -E '/undying/(mana|hit)/[?][r][=][0-9]+' "$TMP/SRC" | head -n 1 > "$TMP/HITMANA" 2>/dev/null

      # So com o link inteiro (?r=nonce): sem ele o pedido iria para a home.
      if [ -s "$TMP/HITMANA" ]; then
        read -r _VL_LINK0 < "$TMP/HITMANA"
        _VL_GOLPE0=`date +%s`; _VL_HORA0=`date +%H:%M:%S`
        (
          run_curl_exec "${URL}${_VL_LINK0}" > "$TMP/SRC"
        ) </dev/null > /dev/null 2>&1 &
        _VL_PAGINA0=0
        time_exit 17 && [ "${TE_RC:-0}" = 0 ] && [ -s "$TMP/SRC" ] && _VL_PAGINA0=1
        echo "1" > BREAK_LOOP
        printf " ... undying iniciado\n"
      fi
      sleep 0.3s
    done

    # O arena_fullmana ja saiu antes da hora cheia.
    undying_fight
    ;;
  esac
}
