undying_fight() {
  cd "$TMP" || return 1
  LA=5

  # ============================================================
  #  VALE DOS IMORTAIS — POR QUE A CONTA ABANDONAVA ANTES DO FIM
  #
  #  1) LINK VAZIO -> BAIXAVA A HOME. O cf_access reparseia o link de golpe
  #     (hit/mana) a cada leitura. Numa leitura sem o link (troca de turno,
  #     mana regenerando, pagina de transicao), o arquivo HITMANA ficava
  #     VAZIO, e o ataque "run_curl ${URL}$(cat HITMANA)" virava
  #     "run_curl ${URL}" — baixava a PAGINA INICIAL. Sem out_gate, o proximo
  #     cf_access declarava "Battle over" e a conta saia da luta.
  #  2) UMA LEITURA SEM out_gate JA ENCERRAVA. Um unico soluco de rede ou uma
  #     pagina intermediaria (sem out_gate) bastava para abandonar, sem
  #     reconfirmar.
  #  3) DESVIO PARA A ARENA. O undying_start chama arena_fullmana logo antes
  #     desta funcao, o que leva a sessao para /arena. Se a luta comecasse
  #     lendo esse estado, o cf_access nao via out_gate e desistia.
  #
  #  AGORA: re-busca /undying no inicio (recupera do desvio da arena); NUNCA
  #  busca a home com link vazio (rele /undying para recuperar o link); e so
  #  encerra apos CONFIRMAR o fim com uma releitura. Um golpe a cada LA (5s).
  # ============================================================

  # Recupera a pagina de batalha (o arena_fullmana do start pode ter navegado
  # para fora). Sem isto a luta poderia comecar lendo uma pagina de arena.
  # Vindo do undying_start, que acabou de dar o primeiro golpe, a pagina e a
  # resposta dele: reler aqui era um pedido a toa, colado no golpe (<5s).
  if [ -z "$_VL_GOLPE0" ]; then
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

  # Confirma o fim da luta relendo /undying: um unico out_gate ausente pode ser
  # so uma pagina de transicao. Retorna 0 se REALMENTE acabou, 1 se ainda ha luta.
  #
  # "Realmente acabou" era "a releitura tambem veio sem out_gate": duas
  # leituras ruins seguidas — rede, sessao caida — e a conta saia do Vale
  # viva. Agora quem decide e o jogo (luta_acabou, em info.sh).
  luta_confirmada_fim() {
    (
      run_curl_exec "${URL}/undying" > "$TMP/SRC"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17
    # O Vale nao ressuscita: morreu, o luta_acabou encerra.
    luta_acabou "$TMP/SRC" undying
  }

  # VALE: E MONSTRO DO JOGO, NAO JOGADOR. A regra do dono do bot e fazer
  # dano, com o golpe, a erva e a pedra. Uma acao a cada LA (5s), nesta
  # ordem:
  #   1 erva   de graca, 1 min de recarga
  #   2 pedra  de graca, 1 min de recarga
  #   3 golpe  (hit/mana), o primeiro que a pagina oferece
  # Erva e pedra que cobram ouro ficam de fora (itens_gratis, em info.sh),
  # como no Rei. A conta de cada uma sai no log no fim da luta.
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
  # O golpe do undying_start conta no relogio de 5s e no resumo: a acao
  # seguinte saia 1-2s depois dele, e o jogo recusa acoes coladas (a erva
  # recusada so voltava 60s depois).
  if [ -n "$_VL_GOLPE0" ]; then
    _last_act="$_VL_GOLPE0"; _vl_t1="$_VL_GOLPE0"; _vl_h1="$_VL_HORA0"
    case "$_VL_LINK0" in */mana/*) _vl_mana=1 ;; *) _vl_hit=1 ;; esac
  fi
  unset _VL_GOLPE0 _VL_HORA0 _VL_LINK0
  echo "$_last_act" > last_atk
  _last_grass=$(( _agora - 60 )); _last_stone=$(( _agora - 60 ))
  : > BREAK_LOOP

  # TETO DE SEGURANCA (luta_teto, em info.sh). Era de 10 minutos contados da
  # entrada de cada conta; agora so segura o laco que nunca resolve.
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
          # Em luta, mas sem link nesta leitura: rele /undying para recuperar o
          # link — NUNCA busca a home com link vazio (era o que abandonava).
          (
            run_curl_exec "${URL}/undying" > "$TMP/SRC"
          ) </dev/null > /dev/null 2>&1 &
          time_exit 17
          cf_access
          _last_act="$_agora"; echo "$_last_act" > last_atk
        fi
      else
        # Sem out_gate: confirma o fim antes de desistir (evita abandono por
        # uma leitura de transicao ou soluco de rede).
        if luta_confirmada_fim; then
          echo 1 > BREAK_LOOP
          printf "Undying: luta encerrada (%s).\n" "$LUTA_MOTIVO"
        else
          cf_access
          _last_act="$_agora"; echo "$_last_act" > last_atk
        fi
      fi
    else
      # Dentro dos 5s: espera o restante sem requisitar (atualizar <5s tambem
      # atrapalha o proximo golpe).
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
  # Sem apply_event: inscrevia no Vale seguinte (ver king.sh). A inscricao e
  # a do undying_start.
  sleep 15s
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

    # Ate :59:50-:59:59, escalonado por conta (janela_alvo, em info.sh). O
    # laco abaixo ainda espera a hora virar antes do primeiro golpe.
    espera_janela 5500 `janela_alvo 5950 10`

    hpmp -now

    if awk -v hpper="$HPPER" 'BEGIN { exit !(hpper > 20) }' && \
       awk -v mpper="$MPPER" 'BEGIN { exit !(mpper > 10) }'; then
      arena_fullmana
    fi

    while awk -v minute="`date +%M`" 'BEGIN { exit !(minute != 00) }' && [ `date +%M` -gt "57" ]; do
      sleep 5s
    done

    # (A leitura de /undying/ que vinha aqui era descartada: o laco abaixo
    # rele a pagina antes de olhar o link.)
    > BREAK_LOOP
    BREAK=$(($(date +%s) + 11))

    until [ -s "BREAK_LOOP" ] || [ "$(date +%s)" -gt "$BREAK" ]; do
      (
        run_curl_exec "$URL/undying" > "$TMP/SRC"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17

      grep -o -E '/undying/(mana|hit)/[?][r][=][0-9]+' "$TMP/SRC" | head -n 1 > "$TMP/HITMANA" 2>/dev/null

      # So com o link inteiro (?r=nonce): com a pagina cortada no meio do link
      # o HITMANA ficava vazio e o pedido ia para a pagina inicial.
      if [ -s "$TMP/HITMANA" ]; then
        read -r _VL_LINK0 < "$TMP/HITMANA"
        _VL_GOLPE0=`date +%s`; _VL_HORA0=`date +%H:%M:%S`
        (
          run_curl_exec "${URL}${_VL_LINK0}" > "$TMP/SRC"
        ) </dev/null > /dev/null 2>&1 &
        time_exit 17
        echo "1" > BREAK_LOOP
        printf " ... undying iniciado\n"
      fi
      sleep 0.3s
    done

    # O arena_fullmana ja saiu antes da hora cheia (acima). Repetido aqui eram
    # tres pedidos depois do inicio do Vale, atrasando o primeiro golpe.
    undying_fight
    ;;
  esac
}
