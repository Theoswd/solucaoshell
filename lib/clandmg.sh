#
#/clandmgfight/dodge/?r=0
#/clandmgfight/attack/?r=0
#/clandmgfight/attackrandom/?r=0
#/clandmgfight/heal/?r=0
#/clandmgfight/stone/?r=0
#/clandmgfight/grass/?r=0
#/clandmgfight/?out_gate
clandmgfight_fight() {
  cd "$TMP" || return 1
  LA=4
  HPER=48
  RPER=15
  awk -v ush="$(cat FULL)" -v hper="$HPER" 'BEGIN { printf "%.0f", ush * hper / 100 }' > HLHP

  cf_access() {
    grep -o -E '(/[a-z]+/[a-z]{0,4}at[a-z]{0,3}k/[^A-Za-z0-9]r[^A-Za-z0-9][0-9]+)' "$TMP/SRC" | sed -n '1p' > ATK 2>/dev/null
    grep -o -E '(/[a-z]+/at[a-z]{0,3}k[a-z]{3,6}/[^A-Za-z0-9]r[^A-Za-z0-9][0-9]+)' "$TMP/SRC" | sed -n 1p > ATKRND 2>/dev/null
    grep -o -E '(/clandmgfight/dodge/[^A-Za-z0-9]r[^A-Za-z0-9][0-9]+)' "$TMP/SRC" | sed -n 1p > DODGE 2>/dev/null
    grep -o -E '(/clandmgfight/heal/[^A-Za-z0-9]r[^A-Za-z0-9][0-9]+)' "$TMP/SRC" | sed -n 1p > HEAL 2>/dev/null
    grep -o -E '(/clandmgfight/grass/[^A-Za-z0-9]r[^A-Za-z0-9][0-9]+)' "$TMP/SRC" > GRASS 2>/dev/null
    alvo_nome "$TMP/SRC" > USER 2>/dev/null
    grep -o -E "(hp)[^A-Za-z0-9]{1,4}[0-9]{1,6}" "$TMP/SRC" | sed "s,hp[']\\/[>],,;s,\ ,," > HP 2>/dev/null
    grep -o -E "(nbsp)[^A-Za-z0-9]{1,2}[0-9]{1,6}" "$TMP/SRC" | sed -n 's,nbsp[;],,;s,\ ,,;1p' > HP2 2>/dev/null
    awk -v ush="$(cat HP)" -v rper="$RPER" 'BEGIN { printf "%.0f", ush * rper / 100 + ush }' > RHP
    awk -v ush="$(cat FULL)" -v hper="$HPER" 'BEGIN { printf "%.0f", ush * hper / 100 }' > HLHP
    if grep -q -o '/dodge/' "$TMP/SRC"; then
      # A pagina respondeu com a luta: sessao confirmada.
      _reconf=0
      sessao_marcar
      printf "Em batalha clandmg - HP: %s\n" "`cat HP`"
      # Morto com a luta ainda na tela (ver luta_hp, em info.sh).
      if luta_hp "`cat HP`"; then
        # ANTES DE ENCERRAR, TENTA VOLTAR.
        #
        # Morrer nao e o mesmo que sair do evento: havendo unrip na
        # pagina, ressuscitar() rele a luta e a conta continua. Era o
        # que faltava para as contas nao largarem o altar.
        if ressuscitar clandmgfight "$TMP/SRC"; then
          cf_access
          return
        fi
        LUTA_MOTIVO="o jogo declarou o personagem morto (HP 0 com a luta na tela)"
        batalha_limpar; echo 1 > BREAK_LOOP
        printf "Battle is over! (%s)\n" "$LUTA_MOTIVO"
      fi
    else
      # RECONFIRMA antes de desistir (transicao/soluco de rede/link vazio->home):
      # rele a pagina de luta UMA vez e reavalia; so encerra se nao houver /dodge/.
      if [ "${_reconf:-0}" = 0 ]; then
        _reconf=1
        (
          run_curl_exec "${URL}/clandmgfight" > "$TMP/SRC"
        ) </dev/null > /dev/null 2>&1 &
        time_exit 17
        cf_access
        return
      fi
      _reconf=0
      # Nem a releitura trouxe a esquiva: quem decide o fim e o jogo.
      # MORREMOS, e a pagina ja nao mostra a luta? A releitura acima
      # pode ter trazido o unrip — mesmo caminho do king.sh.
      if ressuscitar clandmgfight "$TMP/SRC"; then
        cf_access
        return
      fi
      if luta_acabou "$TMP/SRC" clandmgfight; then
        echo 1 > BREAK_LOOP
        printf "Battle is over! (%s)\n" "$LUTA_MOTIVO"
      fi
    fi
  }

  luta_inicio clandmgfight
  cf_access
  : > BREAK_LOOP
  cat HP > old_HP
  echo $(($(date +%s) - 20)) > last_dodge
  echo $(($(date +%s) - 90)) > last_heal
  echo $(($(date +%s) - LA)) > last_atk

  # TETO DE SEGURANCA (luta_teto, em info.sh). Era de 10 minutos contados da
  # entrada de cada conta; agora so segura o laco que nunca resolve (rede
  # fora). Quem encerra a luta e o jogo, pelo luta_acabou.
  FIGHT_BREAK=`luta_teto`
  # LINK VAZIO NUNCA VIRA REQUISICAO: cada ramo exige o proprio link na
  # pagina. "${URL}$(cat HEAL)" com HEAL vazio baixava a PAGINA INICIAL.
  #
  # SEM RELEITURA NO TOPO DO LACO (era reparse redundante; cada ramo ja rele).
  until [ -s "BREAK_LOOP" ] || [ "$(date +%s)" -gt "$FIGHT_BREAK" ]; do
    # Instante do INICIO da volta: o ataque marca o last_atk com ele para o
    # tempo do request contar DENTRO da recarga (LA), e nao somar-se a ela.
    _atk0=$(date +%s)
    # PRIORIDADE 1 — CURA: manter a conta viva vem antes da esquiva.
    if { [ -s HEAL ] || [ -s GRASS ]; } && \
       awk -v ush="$(cat HP)" -v hlhp="$(cat HLHP)" 'BEGIN { exit !(ush < hlhp) }' && \
       [ "$(($(date +%s) - $(cat last_heal)))" -gt 90 ]; then
      if [ -s HEAL ]; then
        (
          run_curl_exec "${URL}$(cat HEAL)" > "$TMP/SRC"
        ) </dev/null > /dev/null 2>&1 &
        time_exit 17
        sleep 0.3s
      fi
      if [ -s GRASS ]; then
        (
          run_curl_exec "${URL}$(cat GRASS)" > "$TMP/SRC"
        ) </dev/null > /dev/null 2>&1 &
        time_exit 17
      fi
      cf_access
      # HP maximo (FULL) preservado: vem do /train e nao pode ser trocado
      # pelo HP atual pos-cura, senao o limiar HLHP cai a cada golpe e a
      # conta "acha" que esta sempre cheia. So a base do dodge (old_HP) muda.
      cat HP > old_HP
      date +%s > last_heal

    # PRIORIDADE 2 — ESQUIVA: so quando a cura nao foi necessaria/possivel.
    elif [ -s DODGE ] && ! alvo_grey "$TMP/SRC" && \
         [ "$(($(date +%s) - $(cat last_dodge)))" -gt 20 ] && \
         awk -v ush="$(cat HP)" -v oldhp="$(cat old_HP)" 'BEGIN { exit !(ush < oldhp) }'; then
      (
        run_curl_exec "${URL}$(cat DODGE)" > "$TMP/SRC"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17
      cf_access
      cat HP > old_HP
      date +%s > last_dodge

    elif [ -s ATKRND ] && { \
         awk -v latk="$(($(date +%s) - $(cat last_atk)))" -v atktime="$LA" 'BEGIN { exit !(latk != atktime) }' && \
         ! alvo_grey "$TMP/SRC" && \
         awk -v rhp="$(cat RHP)" -v enh="$(cat HP2)" 'BEGIN { exit !(rhp < enh) }' || \
         awk -v latk="$(($(date +%s) - $(cat last_atk)))" -v atktime="$LA" 'BEGIN { exit !(latk != atktime) }' && \
         ! alvo_grey "$TMP/SRC" && \
         alvo_aliado USER cla; }; then
      (
        run_curl_exec "${URL}$(cat ATKRND)" > "$TMP/SRC"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17
      cf_access
      echo "$_atk0" > last_atk
      sleep 0.3s

    elif [ -s ATK ] && \
         awk -v latk="$(($(date +%s) - $(cat last_atk)))" -v atktime="$LA" 'BEGIN { exit !(latk > atktime) }'; then
      (
        run_curl_exec "${URL}$(cat ATK)" > "$TMP/SRC"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17
      cf_access
      echo "$_atk0" > last_atk
    else
      # RECARGA DE ATAQUE — UMA REQUISICAO POR CICLO (rele so se alvo grey).
      # Rele tambem quando a leitura nao tem link de ataque: a luta so
      # termina pelo luta_acabou, e sem esta releitura o laco dormiria sobre
      # uma pagina sem acao (rede, sessao, transicao) ate o teto.
      if alvo_grey "$TMP/SRC" || [ ! -s ATK ]; then
        (
          run_curl_exec "${URL}/clandmgfight" > "$TMP/SRC"
        ) </dev/null > /dev/null 2>&1 &
        time_exit 17
        cf_access
        [ -s ATK ] || sleep 1
      else
        _resta=$(( LA - ( $(date +%s) - $(cat last_atk) ) ))
        [ "$_resta" -gt 0 ] && sleep "$_resta"
      fi
    fi
  done

  unset cf_access _random
  func_unset
  printf "Clan duel ok\n"
  [ -t 1 ] && clear
}

clandmgfight_start() {
  cd "$TMP" || return 1
  apply_event clandmgfight
  case `date +%H:%M` in
  09:2[5-9]|21:2[5-9])
    (
      run_curl_exec "$URL/train" | grep -o -E '\(([0-9]+)\)' | head -n1 | sed 's/[()]//g' > "$TMP/FULL"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17
    (
      run_curl_exec "$URL/clandmgfight/?close=reward" > "$TMP/SRC"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17
    # Inscricao: a batalha fica anotada para o worker relancado voltar a ela.
    batalha_marcar clandmgfight
    (
      run_curl_exec "$URL/clandmgfight/enterFight" > "$TMP/SRC"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17
    printf "The clan duel will be started...\n"
    # Espera ate :29:30 — e so dentro da janela (ver espera_janela, em
    # info.sh). O laco antigo esperava o relogio MOSTRAR 29:30: chegando
    # depois de :29:59, a conta ficava parada ate o ramo de desistencia de
    # :45 e perdia o duelo inteiro. Agora, atrasada, ela segue direto para a
    # inscricao — o duelo aceita entrada durante :3x, como o ramo abaixo.
    espera_janela 2500 `janela_alvo 2900`
    (
      run_curl_exec "$URL/clandmgfight/enterFight" > "$TMP/SRC"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17
    link_acao "$TMP/SRC" clandmgfight > "$TMP/ACCESS" 2>/dev/null
    printf " Entering...\n"
    printf " Waiting...\n"
    # 95s: a inscricao e escalonada por conta (janela_alvo).
    BREAK=$(($(date +%s) + 95))
    until [ "`estado_luta "$TMP/SRC" clandmgfight`" = luta ] || [ "$(date +%s)" -gt "$BREAK" ]; do
      printf " ...\n%s\n" "`cat "$TMP/ACCESS"`"
      (
        run_curl_exec "${URL}/clandmgfight/" > "$TMP/SRC"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17
      link_acao "$TMP/SRC" clandmgfight > "$TMP/ACCESS" 2>/dev/null
      sleep 3
    done
    clandmgfight_fight
    sleep 10s
    fetch_page /clandmgfight/enterFight
    clandmgfight_start
    ;;
  09:[3-4][0-9]|21:[3-4][0-9])
    printf "The clan duel will be started...\n"
    batalha_marcar clandmgfight
    (
      run_curl_exec "$URL/clandmgfight/enterFight" > "$TMP/SRC"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17
    link_acao "$TMP/SRC" clandmgfight > "$TMP/ACCESS" 2>/dev/null
    printf " Entering...\n"
    printf " Waiting...\n"
    BREAK=$(($(date +%s) + 60))
    until [ "`estado_luta "$TMP/SRC" clandmgfight`" = luta ] || [ "$(date +%s)" -gt "$BREAK" ]; do
      printf " ...\n%s\n" "`cat "$TMP/ACCESS"`"
      (
        run_curl_exec "${URL}/clandmgfight/" > "$TMP/SRC"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17
      link_acao "$TMP/SRC" clandmgfight > "$TMP/ACCESS" 2>/dev/null
      sleep 3
    done
    clandmgfight_fight
    sleep 10s
    fetch_page /clandmgfight/enterFight
    clandmgfight_start
    ;;
  esac
}
