clancoliseum_fight() {
  src_ram="$TMP/ccol_src"
  full_ram="$TMP/ccol_full"
  cd "$TMP" || return 1

  LA=4
  HPER=48
  RPER=15

  cf_access() {
    grep -o -E '(/clancoliseum/[a-z]{0,4}at[a-z]{0,3}k/[?]r[=][0-9]+)' "$src_ram" | sed -n '1p' > ATK 2>/dev/null
    grep -o -E '(/clancoliseum/at[a-z]{0,3}k[a-z]{3,6}/[?]r[=][0-9]+)' "$src_ram" | sed -n 1p > ATKRND 2>/dev/null
    grep -o -E '(/clancoliseum/dodge/[?]r[=][0-9]+)' "$src_ram" | sed -n 1p > DODGE 2>/dev/null
    grep -o -E '(/clancoliseum/heal/[?]r[=][0-9]+)' "$src_ram" | sed -n 1p > HEAL 2>/dev/null
    alvo_nome "$src_ram" > USER 2>/dev/null
    grep -o -E "(hp)[^A-Za-z0-9]{1,4}[0-9]{1,6}" "$src_ram" | sed "s,hp[']\\/[>],,;s,\ ,," > USH 2>/dev/null
    grep -o -E "(nbsp)[^A-Za-z0-9]{1,2}[0-9]{1,6}" "$src_ram" | sed -n 's,nbsp[;],,;s,\ ,,;1p' > ENH 2>/dev/null
    awk -v ush="$(cat USH)" -v rper="$RPER" 'BEGIN { printf "%.0f", ush * rper / 100 + ush }' > RHP
    awk -v ush="$(cat "$full_ram")" -v hper="$HPER" 'BEGIN { printf "%.0f", ush * hper / 100 }' > HLHP

    if grep -q -o '/dodge/' "$src_ram"; then
      # A pagina respondeu com a luta: sessao confirmada.
      _reconf=0
      sessao_marcar
      printf "Em batalha clancoliseum - HP: %s\n" "`cat USH`"
      # Morto com a luta ainda na tela (ver luta_hp, em info.sh).
      if luta_hp "`cat USH`"; then
        # ANTES DE ENCERRAR, TENTA VOLTAR.
        #
        # Morrer nao e o mesmo que sair do evento: havendo unrip na
        # pagina, ressuscitar() rele a luta e a conta continua. Era o
        # que faltava para as contas nao largarem o altar.
        if ressuscitar clancoliseum "$src_ram"; then
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
          run_curl_exec "${URL}/clancoliseum" > "$src_ram"
        ) </dev/null > /dev/null 2>&1 &
        time_exit 17
        cf_access
        return
      fi
      _reconf=0
      # Nem a releitura trouxe a esquiva: quem decide o fim e o jogo.
      # MORREMOS, e a pagina ja nao mostra a luta? A releitura acima
      # pode ter trazido o unrip — mesmo caminho do king.sh.
      if ressuscitar clancoliseum "$src_ram"; then
        cf_access
        return
      fi
      if luta_acabou "$src_ram" clancoliseum; then
        echo 1 > BREAK_LOOP
        printf "Battle over! (%s)\n" "$LUTA_MOTIVO"
      fi
    fi
  }

  luta_inicio clancoliseum
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
  # pagina. "${URL}$(cat HEAL)" com HEAL vazio baixava a PAGINA INICIAL.
  until [ -s "BREAK_LOOP" ] || [ "$(date +%s)" -gt "$FIGHT_BREAK" ]; do
    # Instante do INICIO da volta: o ataque marca o last_atk com ele para o
    # tempo do request contar DENTRO da recarga (LA), e nao somar-se a ela.
    _atk0=$(date +%s)
    if [ -s HEAL ] && \
       awk -v ush="$(cat USH)" -v hlhp="$(cat HLHP)" 'BEGIN { exit !(ush < hlhp) }' && \
       [ "$(($(date +%s) - $(cat last_heal)))" -gt 90 ]; then
      (
        run_curl_exec "${URL}$(cat HEAL)" > "$src_ram"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17
      cf_access
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
        (
          run_curl_exec "${URL}/clancoliseum" > "$src_ram"
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

  rm -f "$src_ram" "$full_ram"
  unset src_ram full_ram ACCESS cf_access
  printf "Clancoliseum ok\n"
  sleep 10s
  [ -t 1 ] && clear
}

clancoliseum_start() {
  src_ram="$TMP/ccol_src"
  full_ram="$TMP/ccol_full"

  case `date +%H:%M` in
  10:2[5-9]|14:5[5-9])
    # DISPONIBILIDADE PELO JOGO, NAO PELO CALENDARIO.
    #
    # O Coliseu do Cla tem temporadas: fora delas a pagina anuncia "Nova
    # temporada comeca em ..." e nao oferece inscricao. A versao anterior nao
    # verificava nada — pedia /train, mandava o enterFight as cegas e entrava
    # na espera bloqueante ate :30 (ou :00), de 3 em 3 segundos. Fora de
    # temporada isso deixava o worker ATE CINCO MINUTOS parado sem fazer nada,
    # duas vezes por dia e por conta, sem arena, sem stats, e ainda com a
    # sessao estacionada na pagina do coliseu.
    #
    # Agora a pagina e consultada ANTES, e a inscricao so acontece se o jogo
    # de fato a oferecer — o mesmo criterio do apply_event(), usado nos demais
    # eventos: existe link de enterFight? entao esta disponivel. O
    # clancoliseum/dodge cobre o caso de a luta ja estar em andamento.
    #
    # Nenhuma data e consultada: quando a temporada voltar, o bot volta a
    # participar sozinho, sem precisar de ajuste.
    (
      run_curl_exec "$URL/clancoliseum/?close=reward" > "$src_ram"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17

    if ! grep -q -E '/clancoliseum/(enterFight|dodge)' "$src_ram"; then
      printf "Clan coliseum: sem inscricao disponivel agora - pulando\n"
      # Sem inscricao nao ha evento a esperar: apaga a dedicacao para a conta
      # voltar JA para a rotina, em vez de ficar dez minutos parada.
      evento_cancelar 2>/dev/null
      rm -f "$src_ram" "$full_ram"
      unset src_ram full_ram
      return 0
    fi

    (
      run_curl_exec "$URL/train" | grep -o -E '\(([0-9]+)\)' | sed 's/[()]//g' > "$full_ram"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17
    # Inscricao: a batalha fica anotada para o worker relancado voltar a ela.
    batalha_marcar clancoliseum
    (
      run_curl_exec "$URL/clancoliseum/enterFight" > "$src_ram"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17
    printf "Clan coliseum will be started...\n"

    case `date +%H:%M` in
    10:2[5-9])
      while [ "`date +%M`" -gt "24" ] && [ "`date +%M`" -lt "30" ]; do
        sleep 3s
      done
      ;;
    14:5[5-9])
      while awk -v minute="`date +%M`" 'BEGIN { exit !(minute != 00) }' && [ "`date +%M`" -gt "54" ]; do
        sleep 3s
      done
      ;;
    esac

    (
      run_curl_exec "$URL/clancoliseum/" > "$src_ram"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17
    ACCESS=`link_acao "$src_ram" clancoliseum`
    printf " Entering...\n"
    printf " Waiting...\n"

    # ESPERA PELO INICIO: ERA DE 11 SEGUNDOS.
    #
    # Nao vindo a luta nesse prazo, o clancoliseum_fight entrava com a pagina
    # de espera e a dava por encerrada antes de comecar — ou, com o ACCESS
    # vazio da releitura, a luta nem era chamada. Como cada conta entra num
    # segundo diferente (evento_dedicar), umas pegavam o inicio e outras nao.
    # Agora sao 60s, esperando QUALQUER acao do evento, e o ACCESS mantem o
    # caminho do evento quando ainda nao ha acao (link_acao).
    BREAK=$(($(date +%s) + 60))

    until [ "`estado_luta "$src_ram" clancoliseum`" = luta ] || [ "$(date +%s)" -gt "$BREAK" ]; do
      printf " ...\n%s\n" "$ACCESS"
      (
        run_curl_exec "${URL}/clancoliseum/" > "$src_ram"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17
      ACCESS=`link_acao "$src_ram" clancoliseum`
      sleep 3
    done

    if [ -n "$ACCESS" ]; then
      clancoliseum_fight
    else
      # Nada do coliseu do cla na pagina: nao ha luta a retomar depois (ver o
      # mesmo caso no flagfight_start).
      batalha_limpar
      rm -f "$src_ram" "$full_ram"
      unset src_ram full_ram ACCESS
    fi
    ;;
  esac
}
