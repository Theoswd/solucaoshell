altars_fight() {
  cd "$TMP" || return 1
  # CORRECAO: sem o argumento, o apply_event monta "/${1}/" com $1
  # vazio e pede "//" — um request invalido que ainda gravava "//"
  # como atividade da conta no painel.
  apply_event altars
  LA=4
  echo "48" > HPER
  echo "15" > RPER

  cf_access() {
    grep -o -E '(/[a-z]+/[a-z]{0,4}at[a-z]{0,3}k/[?]r[=][0-9]+)' "$TMP/src.html" | sed -n 1p > ATK 2>/dev/null
    grep -o -E '(/[a-z]+/at[a-z]{0,3}k[a-z]{3,6}/[?]r[=][0-9]+)' "$TMP/src.html" | sed -n 1p > ATKRND 2>/dev/null
    grep -o -E '(/altars/dodge/[?]r[=][0-9]+)' "$TMP/src.html" | sed -n 1p > DODGE 2>/dev/null
    grep -o -E '(/altars/heal/[?]r[=][0-9]+)' "$TMP/src.html" | sed -n 1p > HEAL 2>/dev/null
    alvo_nome "$TMP/src.html" > USER 2>/dev/null
    grep -o -E "(hp)[^A-Za-z0-9]{1,4}[0-9]{1,6}" "$TMP/src.html" | sed "s,hp[']\\/[>],,;s,\ ,," > HP 2>/dev/null
    grep -o -E "(nbsp)[^A-Za-z0-9]{1,2}[0-9]{1,6}" "$TMP/src.html" | sed -n 's,nbsp[;],,;s,\ ,,;1p' > HP2 2>/dev/null
    awk -v ush="$(cat HP)" -v rper="$(cat RPER)" 'BEGIN { printf "%.0f", ush * rper / 100 + ush }' > RHP
    awk -v ush="$(cat FULL)" -v hper="$(cat HPER)" 'BEGIN { printf "%.0f", ush * hper / 100 }' > HLHP
    if grep -q -o '/dodge/' "$TMP/src.html"; then
      # A pagina respondeu com a luta: sessao confirmada.
      _reconf=0
      sessao_marcar
      printf "Em batalha - HP: %s\n" "`cat HP`"
      # Morto com a luta ainda na tela (ver luta_hp, em info.sh).
      if luta_hp "`cat HP`"; then
        # ANTES DE ENCERRAR, TENTA VOLTAR.
        #
        # Morrer nao e o mesmo que sair do evento: havendo unrip na
        # pagina, ressuscitar() rele a luta e a conta continua. Era o
        # que faltava para as contas nao largarem o altar.
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
      # Nem a releitura trouxe a esquiva: quem decide o fim e o jogo.
      # MORREMOS, e a pagina ja nao mostra a luta? A releitura acima
      # pode ter trazido o unrip — mesmo caminho do king.sh.
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

  luta_inicio altars
  cf_access
  : > BREAK_LOOP; cat HP > old_HP
  echo $(($(date +%s) - 20)) > last_dodge
  echo $(($(date +%s) - 90)) > last_heal
  echo $(($(date +%s) - LA)) > last_atk

  # TETO DE SEGURANCA (luta_teto, em info.sh). Era de 10 minutos contados da
  # entrada de cada conta; agora so segura o laco que nunca resolve (rede
  # fora). Quem encerra a luta e o jogo, pelo luta_acabou.
  FIGHT_BREAK=`luta_teto`
  # SEM RELEITURA NO TOPO DO LACO (era reparse redundante; cada ramo ja rele).
  #
  # LINK VAZIO NUNCA VIRA REQUISICAO: cada ramo exige o proprio link na
  # pagina. "${URL}$(cat HEAL)" com HEAL vazio baixava a PAGINA INICIAL, e a
  # leitura seguinte — sem luta nenhuma — contava para o fim da batalha.
  until [ -s "BREAK_LOOP" ] || [ "$(date +%s)" -gt "$FIGHT_BREAK" ]; do
    # Instante do INICIO da volta: o ataque marca o last_atk com ele para o
    # tempo do request contar DENTRO da recarga (LA), e nao somar-se a ela.
    _atk0=$(date +%s)
    # PRIORIDADE 1 — CURA: manter a conta viva vem antes da esquiva. Nos
    # altares a conta apanha muito; curar primeiro evita a morte por esperar
    # a releitura de HP que so viria depois da esquiva.
    if [ -s HEAL ] && \
       awk -v ush="$(cat HP)" -v hlhp="$(cat HLHP)" 'BEGIN { exit !(ush < hlhp) }' && \
       [ "$(($(date +%s) - $(cat last_heal)))" -gt 90 ]; then
      (
        run_curl_exec "${URL}$(cat HEAL)" > "$TMP/src.html"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17
      cf_access
      # HP maximo (FULL) preservado: vem do /train e nao pode ser trocado
      # pelo HP atual pos-cura, senao o limiar HLHP cai a cada golpe e a
      # conta "acha" que esta sempre cheia. So a base do dodge (old_HP) muda.
      cat HP > old_HP
      date +%s > last_heal

    # PRIORIDADE 2 — ESQUIVA: so quando a cura nao foi necessaria/possivel.
    elif [ -s DODGE ] && ! alvo_grey "$TMP/src.html" && \
         [ "$(($(date +%s) - $(cat last_dodge)))" -gt 20 ] && \
         awk -v ush="$(cat HP)" -v oldhp="$(cat old_HP)" 'BEGIN { exit !(ush < oldhp) }'; then
      (
        run_curl_exec "${URL}$(cat DODGE)" > "$TMP/src.html"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17
      cf_access
      cat HP > old_HP; date +%s > last_dodge

    elif [ -s ATKRND ] && { \
         awk -v latk="$(($(date +%s) - $(cat last_atk)))" -v atktime="$LA" 'BEGIN { exit !(latk != atktime) }' && \
         ! alvo_grey "$TMP/src.html" && \
         awk -v rhp="$(cat RHP)" -v enh="$(cat HP2)" 'BEGIN { exit !(rhp < enh) }' || \
         awk -v latk="$(($(date +%s) - $(cat last_atk)))" -v atktime="$LA" 'BEGIN { exit !(latk != atktime) }' && \
         ! alvo_grey "$TMP/src.html" && \
         alvo_aliado USER cla; }; then
      (
        run_curl_exec "${URL}$(cat ATKRND)" > "$TMP/src.html"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17
      cf_access
      echo "$_atk0" > last_atk

    elif [ -s ATK ] && \
         awk -v latk="$(($(date +%s) - $(cat last_atk)))" -v atktime="$LA" 'BEGIN { exit !(latk > atktime) }'; then
      (
        run_curl_exec "${URL}$(cat ATK)" > "$TMP/src.html"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17
      cf_access
      echo "$_atk0" > last_atk
    else
      # RECARGA DE ATAQUE — UMA REQUISICAO POR CICLO (rele so se alvo grey).
      # Rele tambem quando a leitura nao tem link de ataque: a luta so
      # termina pelo luta_acabou, e sem esta releitura o laco dormiria sobre
      # uma pagina sem acao (rede, sessao, transicao) ate o teto.
      if alvo_grey "$TMP/src.html" || [ ! -s ATK ]; then
        (
          run_curl_exec "${URL}/altars" > "$TMP/src.html"
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
  # CORRECAO: sem o argumento, o apply_event monta "/${1}/" com $1
  # vazio e pede "//" — um request invalido que ainda gravava "//"
  # como atividade da conta no painel.
  apply_event altars
  printf "Altars ok\n"
  sleep 10s
  [ -t 1 ] && clear
}

altars_start() {
  case `date +%H:%M` in
  (13:5[5-9]|20:5[5-9])
    (
      run_curl_exec "$URL/train" | grep -o -E '\(([0-9]+)\)' | sed 's/[()]//g' > "$TMP/FULL"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17

    fetch_page "/altars/?close=reward" "$TMP/src.html"
    # Inscricao: a batalha fica anotada para o worker relancado voltar a ela.
    batalha_marcar altars
    fetch_page "/altars/enterFight" "$TMP/src.html"
    printf "Ancient Altars will be started...\n"

    until (case `date +%M` in (55|56|57|58|59) exit 1;; esac); do
      sleep 2
    done

    fetch_page "/altars/enterFight" "$TMP/src.html"
    printf "Altars will be started...\n"
    link_acao "$TMP/src.html" altars > "$TMP/ACCESS" 2>/dev/null
    printf " Entering...\n"
    printf " Waiting...\n"
    # 60s (eram 30), e a espera termina quando ha LUTA na pagina — qualquer
    # acao do evento —, nao quando o primeiro link por acaso e a esquiva.
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
