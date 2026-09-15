flagfight_fight() {
  # Arquivos de batalha no diretorio da conta (sem mktemp)
  src_ram="$TMP/flag_src"
  full_ram="$TMP/flag_full"

  cd "$TMP" || return 1

  LA=4
  HPER=48
  RPER=15

  cf_access() {
    grep -o -E '(/[a-z]+/[a-z]{0,4}at[a-z]{0,3}k/[?]r[=][0-9]+)' "$src_ram" | sed -n '1p' > ATK 2>/dev/null
    grep -o -E '(/[a-z]+/at[a-z]{0,3}k[a-z]{3,6}/[?]r[=][0-9]+)' "$src_ram" | sed -n 1p > ATKRND 2>/dev/null
    grep -o -E '(/flagfight/dodge/[?]r[=][0-9]+)' "$src_ram" | sed -n 1p > DODGE 2>/dev/null
    grep -o -E '(/flagfight/heal/[?]r[=][0-9]+)' "$src_ram" | sed -n 1p > HEAL 2>/dev/null
    grep -o -E '(/[a-z]+/shield/[?]r[=][0-9]+)' "$src_ram" | sed -n 1p > SHIELD 2>/dev/null
    alvo_nome "$src_ram" > USER 2>/dev/null
    grep -o -E "(hp)[^A-Za-z0-9]{1,4}[0-9]{1,6}" "$src_ram" | sed "s,hp[']\\/[>],,;s,\ ,," > USH 2>/dev/null
    grep -o -E "(nbsp)[^A-Za-z0-9]{1,2}[0-9]{1,6}" "$src_ram" | sed -n 's,nbsp[;],,;s,\ ,,;1p' > ENH 2>/dev/null
    awk -v ush="$(cat USH)" -v rper="$RPER" 'BEGIN { printf "%.0f", ush * rper / 100 + ush }' > RHP
    awk -v ush="$(cat "$full_ram")" -v hper="$HPER" 'BEGIN { printf "%.0f", ush * hper / 100 }' > HLHP

    if grep -q -o '/dodge/' "$src_ram"; then
      # A pagina respondeu com a luta: sessao confirmada.
      _reconf=0
      sessao_marcar
      printf "Em batalha flagfight - HP: %s\n" "`cat USH`"
      # Morto com a luta ainda na tela (ver luta_hp, em info.sh).
      if luta_hp "`cat USH`"; then
        # ANTES DE ENCERRAR, TENTA VOLTAR.
        #
        # Morrer nao e o mesmo que sair do evento: havendo unrip na
        # pagina, ressuscitar() rele a luta e a conta continua. Era o
        # que faltava para as contas nao largarem o altar.
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
      # Nem a releitura trouxe a esquiva: quem decide o fim e o jogo.
      # MORREMOS, e a pagina ja nao mostra a luta? A releitura acima
      # pode ter trazido o unrip — mesmo caminho do king.sh.
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

  luta_inicio flagfight
  cf_access
  > BREAK_LOOP
  cat USH > old_HP
  echo $(($(date +%s) - 20)) > last_dodge
  echo $(($(date +%s) - 90)) > last_heal
  echo $(($(date +%s) - LA)) > last_atk

  # TETO DE SEGURANCA (luta_teto, em info.sh). Era de 10 minutos contados da
  # entrada de cada conta; agora so segura o laco que nunca resolve (rede
  # fora). Quem encerra a luta e o jogo, pelo luta_acabou.
  FIGHT_BREAK=`luta_teto`
  # LINK VAZIO NUNCA VIRA REQUISICAO: cada ramo exige o proprio link na
  # pagina. "${URL}$(cat SHIELD)" com SHIELD vazio baixava a PAGINA INICIAL.
  until [ -s "BREAK_LOOP" ] || [ "$(date +%s)" -gt "$FIGHT_BREAK" ]; do
    # Instante do INICIO da volta: o ataque marca o last_atk com ele para o
    # tempo do request contar DENTRO da recarga (LA), e nao somar-se a ela.
    _atk0=$(date +%s)
    if [ -s SHIELD ] && \
       awk -v ush="$(cat USH)" -v hlhp="$(cat HLHP)" 'BEGIN { exit !(ush < hlhp) }' && \
       [ "$(($(date +%s) - $(cat last_heal)))" -gt 90 ]; then
      (
        run_curl_exec "${URL}$(cat SHIELD)" > "$src_ram"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17
      cf_access
      # HP maximo (full_ram) preservado: vem do /train e nao pode ser trocado
      # pelo HP atual pos-escudo, senao o limiar HLHP cai a cada golpe e a
      # conta "acha" que esta sempre cheia. So a base do dodge (old_HP) muda.
      cat USH > old_HP
      date +%s > last_heal

    elif [ -s DODGE ] && ! alvo_grey "$src_ram" && \
         [ "$(($(date +%s) - $(cat last_dodge)))" -gt 20 ] && \
         awk -v ush="$(cat USH)" -v oldhp="$(cat old_HP)" 'BEGIN { exit !(ush < oldhp) }'; then
      (
        run_curl_exec "${URL}$(cat DODGE)" > "$src_ram"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17
      cf_access
      cat USH > old_HP
      date +%s > last_dodge

    elif [ -s ATKRND ] && { \
         awk -v latk="$(($(date +%s) - $(cat last_atk)))" -v atktime="$LA" 'BEGIN { exit !(latk != atktime) }' && \
         ! alvo_grey "$src_ram" && \
         awk -v rhp="$(cat RHP)" -v enh="$(cat ENH)" 'BEGIN { exit !(rhp < enh) }' || \
         awk -v latk="$(($(date +%s) - $(cat last_atk)))" -v atktime="$LA" 'BEGIN { exit !(latk != atktime) }' && \
         ! alvo_grey "$src_ram" && \
         alvo_aliado USER cla; }; then
      (
        run_curl_exec "${URL}$(cat ATKRND)" > "$src_ram"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17
      cf_access
      echo "$_atk0" > last_atk

    elif [ -s ATK ] && \
         awk -v latk="$(($(date +%s) - $(cat last_atk)))" -v atktime="$LA" 'BEGIN { exit !(latk > atktime) }'; then
      (
        run_curl_exec "${URL}$(cat ATK)" > "$src_ram"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17
      cf_access
      echo "$_atk0" > last_atk
    else
      # RECARGA DE ATAQUE — UMA REQUISICAO POR CICLO.
      # O ultimo golpe ja trouxe o HP. So relemos a pagina quando o alvo esta
      # momentaneamente invulneravel (grey); fora disso apenas esperamos o
      # restante da recarga, sem nova requisicao, para o intervalo entre
      # golpes ficar em 4-5s em vez de inflar com recargas de pagina.
      # Rele tambem quando a leitura nao tem link de ataque: a luta so
      # termina pelo luta_acabou, e sem esta releitura o laco dormiria sobre
      # uma pagina sem acao (rede, sessao, transicao) ate o teto.
      if alvo_grey "$src_ram" || [ ! -s ATK ]; then
        fetch_page "/flagfight" "$src_ram"
        cf_access
        [ -s ATK ] || sleep 1
      else
        _resta=$(( LA - ( $(date +%s) - $(cat last_atk) ) ))
        [ "$_resta" -gt 0 ] && sleep "$_resta"
      fi
    fi
  done

  rm -f "$src_ram" "$full_ram"
  unset src_ram full_ram ACCESS cf_access
  printf "Flagfight ok\n"
  sleep 10s
  apply_event flagfight
  [ -t 1 ] && clear
}

flagfight_start() {
  src_ram="$TMP/flag_src"
  full_ram="$TMP/flag_full"

  case `date +%H:%M` in
  (10:1[0-4]|16:1[0-4])
    (
      run_curl_exec "$URL/train" | grep -o -E '\(([0-9]+)\)' | head -n1 | sed 's/[()]//g' > "$full_ram"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17
    fetch_page "/flagfight/?close=reward" "$src_ram"
    # Inscricao: a batalha fica anotada para o worker relancado voltar a ela.
    batalha_marcar flagfight
    fetch_page "/flagfight/enterFight" "$src_ram"
    printf "Flagfight will be started...\n"

    # Espera ate :14:30 — e so dentro da janela. O laco antigo esperava o
    # relogio MOSTRAR 14:30: chegando depois de :14:59 (tres requisicoes
    # lentas acima), a conta ficava presa ate a hora seguinte (ver
    # espera_janela, em info.sh).
    espera_janela 1000 1430

    (
      run_curl_exec "$URL/flagfight/enterFight" > "$src_ram"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17
    link_acao "$src_ram" flagfight > "$TMP/ACCESS" 2>/dev/null
    printf " Entering...\n"
    printf " Waiting...\n"

    BREAK=$(($(date +%s) + 60))

    # A espera termina quando ha LUTA na pagina (qualquer acao do evento),
    # nao quando o primeiro link por acaso e a esquiva.
    until [ "`estado_luta "$src_ram" flagfight`" = luta ] || [ "$(date +%s)" -gt "$BREAK" ]; do
      printf " ...\n%s\n" "`cat "$TMP/ACCESS"`"
      fetch_page "/flagfight/" "$src_ram"
      link_acao "$src_ram" flagfight > "$TMP/ACCESS" 2>/dev/null
      sleep 3
    done

    if [ -s "$TMP/ACCESS" ]; then
      flagfight_fight
    else
      # SEM NADA DAS BANDEIRAS NA PAGINA.
      #
      # Medido nos logs (11/09 16:10, as 16 contas): a pagina lida nao tinha
      # nem o caminho /flagfight/ — nao havia luta aberta para a conta. A
      # batalha continuava anotada, e o descansar logo depois "retomava" uma
      # luta que nao existia: 90s a toa por conta. Aqui a anotacao sai, e a
      # pagina fica guardada para ver o que o jogo mostrou.
      cp "$src_ram" "$TMP/flag_sem_luta.html" 2>/dev/null
      printf "Bandeiras: nenhuma luta na pagina (guardada em %s)\n" "$TMP/flag_sem_luta.html"
      batalha_limpar
      rm -f "$src_ram" "$full_ram"
      unset src_ram full_ram
    fi
    ;;
  esac
}
