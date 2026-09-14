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
  (
    run_curl_exec "${URL}/undying" > "$TMP/SRC"
  ) </dev/null > /dev/null 2>&1 &
  time_exit 17

  # Le a pagina: extrai o link de golpe e diz se ainda estamos na luta
  # (retorno 0 = em luta, 1 = fora). NAO encerra a luta sozinho.
  cf_access() {
    grep -o -E '/undying/(hit|mana)/[?][r][=][0-9]+' "$TMP/SRC" | sed -n '1p' > HITMANA 2>/dev/null
    if grep -q -o 'out_gate' "$TMP/SRC"; then
      sessao_marcar
      # O Vale nao le HP (sem luta_hp): marca aqui que a conta lutou, para o
      # fim sem botao valer em 15s e nao 90s (LUTA_FORA_LUTOU, em info.sh).
      _lt_lutou=1
      printf "Em batalha undying\n"
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
    # MORREMOS? Ressuscitar devolve a luta — entao nao e fim.
    ressuscitar undying "$TMP/SRC" && return 1
    luta_acabou "$TMP/SRC" undying
  }

  luta_inicio undying
  cf_access
  _agora=`date +%s`
  _last_act=$(( _agora - LA ))
  echo "$_last_act" > last_atk
  : > BREAK_LOOP

  # TETO DE SEGURANCA (luta_teto, em info.sh). Era de 10 minutos contados da
  # entrada de cada conta; agora so segura o laco que nunca resolve.
  FIGHT_BREAK=`luta_teto`
  until [ -s "BREAK_LOOP" ] || [ "`date +%s`" -gt "$FIGHT_BREAK" ]; do
    _agora=`date +%s`

    # Relogio de 5s entre golpes (o jogo recusa acoes coladas <4s).
    if [ $(( _agora - _last_act )) -ge "$LA" ]; then
      if grep -q -o 'out_gate' "$TMP/SRC"; then
        if [ -s HITMANA ]; then
          # Golpe (hit/mana) a cada 5s.
          (
            run_curl_exec "${URL}$(cat HITMANA)" > "$TMP/SRC"
          ) </dev/null > /dev/null 2>&1 &
          time_exit 17
          cf_access
          _last_act="$_agora"; echo "$_last_act" > last_atk
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
      [ "$_resta" -gt 0 ] && sleep "$_resta"
    fi
  done

  unset cf_access luta_confirmada_fim
  printf "Undying ok\n"
  sleep 15s
  apply_event undying
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

    until (case `date +%M` in (5[5-9]) exit 1;; esac); do
      sleep 2
    done

    hpmp -now

    if awk -v hpper="$HPPER" 'BEGIN { exit !(hpper > 20) }' && \
       awk -v mpper="$MPPER" 'BEGIN { exit !(mpper > 10) }'; then
      arena_fullmana
    fi

    while awk -v minute="`date +%M`" 'BEGIN { exit !(minute != 00) }' && [ `date +%M` -gt "57" ]; do
      sleep 5s
    done

    (
      run_curl_exec "$URL/undying/" > "$TMP/SRC"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17
    grep -o -E '/undying/(mana|hit)/[?][r][=][0-9]+' "$TMP/SRC" | head -n 1 > "$TMP/HITMANA" 2>/dev/null

    > BREAK_LOOP
    BREAK=$(($(date +%s) + 11))

    until [ -s "BREAK_LOOP" ] || [ "$(date +%s)" -gt "$BREAK" ]; do
      (
        run_curl_exec "$URL/undying" > "$TMP/SRC"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17

      grep -o -E '/undying/(mana|hit)/[?][r][=][0-9]+' "$TMP/SRC" | head -n 1 > "$TMP/HITMANA" 2>/dev/null

      if grep -q -o -E '/undying/(hit|mana)' "$TMP/SRC"; then
        (
          run_curl_exec "${URL}$(cat "$TMP/HITMANA")" > "$TMP/SRC"
        ) </dev/null > /dev/null 2>&1 &
        time_exit 17
        echo "1" > BREAK_LOOP
        printf " ... undying iniciado\n"
      fi
      sleep 0.3s
    done

    arena_fullmana
    undying_fight
    ;;
  esac
}
