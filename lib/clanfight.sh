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
  awk -v ush="$(cat FULL)" -v hper="$HPER" 'BEGIN { printf "%.0f", ush * hper / 100 }' > HLHP

  cf_access() {
    grep -o -E '(/[a-z]+/[a-z]{0,4}at[a-z]{0,3}k/[^A-Za-z0-9]r[^A-Za-z0-9][0-9]+)' "$TMP/SRC" | sed -n '1p' > ATK 2>/dev/null
    grep -o -E '(/[a-z]+/at[a-z]{0,3}k[a-z]{3,6}/[^A-Za-z0-9]r[^A-Za-z0-9][0-9]+)' "$TMP/SRC" | sed -n 1p > ATKRND 2>/dev/null
    grep -o -E '(/clanfight/dodge/[^A-Za-z0-9]r[^A-Za-z0-9][0-9]+)' "$TMP/SRC" | sed -n 1p > DODGE 2>/dev/null
    grep -o -E '(/clanfight/heal/[^A-Za-z0-9]r[^A-Za-z0-9][0-9]+)' "$TMP/SRC" | sed -n 1p > HEAL 2>/dev/null
    grep -o -E '(/clanfight/grass/[^A-Za-z0-9]r[^A-Za-z0-9][0-9]+)' "$TMP/SRC" > GRASS 2>/dev/null
    alvo_nome "$TMP/SRC" > USER 2>/dev/null
    grep -o -E "(hp)[^A-Za-z0-9]{1,4}[0-9]{1,6}" "$TMP/SRC" | sed "s,hp[']\\/[>],,;s,\ ,," > HP 2>/dev/null
    grep -o -E "(nbsp)[^A-Za-z0-9]{1,2}[0-9]{1,6}" "$TMP/SRC" | sed -n 's,nbsp[;],,;s,\ ,,;1p' > HP2 2>/dev/null
    awk -v ush="$(cat HP)" -v rper="$RPER" 'BEGIN { printf "%.0f", ush * rper / 100 + ush }' > RHP
    awk -v ush="$(cat FULL)" -v hper="$HPER" 'BEGIN { printf "%.0f", ush * hper / 100 }' > HLHP
    if grep -q -o '/dodge/' "$TMP/SRC"; then
      # A pagina respondeu com a luta: sessao confirmada.
      _reconf=0
      sessao_marcar
      printf "Em batalha clanfight - HP: %s\n" "`cat HP`"
      # Morto com a luta ainda na tela (ver luta_hp, em info.sh).
      if luta_hp "`cat HP`"; then
        # ANTES DE ENCERRAR, TENTA VOLTAR.
        #
        # Morrer nao e o mesmo que sair do evento: havendo unrip na
        # pagina, ressuscitar() rele a luta e a conta continua. Era o
        # que faltava para as contas nao largarem o altar.
        if ressuscitar clanfight "$TMP/SRC"; then
          cf_access
          return
        fi
        LUTA_MOTIVO="o jogo declarou o personagem morto (HP 0 com a luta na tela)"
        batalha_limpar; echo 1 > BREAK_LOOP
        printf "Battle is over! (%s)\n" "$LUTA_MOTIVO"
      fi
    else
      # RECONFIRMA antes de desistir: uma unica leitura sem /dodge/ pode ser
      # pagina de transicao, soluco de rede ou o efeito de um link vazio ter
      # baixado a home. Rele a pagina de luta UMA vez e reavalia; so encerra a
      # luta se realmente nao houver mais /dodge/.
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
      # Nem a releitura trouxe a esquiva: quem decide o fim e o jogo.
      # MORREMOS, e a pagina ja nao mostra a luta? A releitura acima
      # pode ter trazido o unrip — mesmo caminho do king.sh.
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

  luta_inicio clanfight
  cf_access
  > BREAK_LOOP
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
  # SEM RELEITURA NO TOPO DO LACO.
  # A resposta do ultimo golpe/cura/esquiva ja atualizou o HP nos arquivos;
  # reler aqui era uma reparse redundante (8 grep + 2 awk por volta). Cada
  # ramo abaixo ja rele apos a sua acao.
  until [ -s "BREAK_LOOP" ] || [ "$(date +%s)" -gt "$FIGHT_BREAK" ]; do
    # Instante do INICIO da volta: o ataque marca o last_atk com ele, e nao
    # com a hora em que o request TERMINA. Assim o tempo do proprio request
    # (~1-2s) conta DENTRO da recarga (LA), em vez de somar-se a ela — sem
    # isso o intervalo entre golpes era LA + duracao do request (~6-8s).
    _atk0=$(date +%s)
    # Uma leitura so do last_atk por volta: dois "cat" na mesma condicao podiam
    # devolver segundos diferentes e liberar o golpe antes da recarga.
    _latk=$(( _atk0 - $(cat last_atk) ))
    # PRIORIDADE 1 — CURA: manter a conta viva vem antes da esquiva. Com o
    # HP abaixo do limiar, cura na hora; nao esquiva e fica sem reler o HP.
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
         awk -v latk="$_latk" -v atktime="$LA" 'BEGIN { exit !(latk != atktime) }' && \
         ! alvo_grey "$TMP/SRC" && \
         awk -v rhp="$(cat RHP)" -v enh="$(cat HP2)" 'BEGIN { exit !(rhp < enh) }' || \
         awk -v latk="$_latk" -v atktime="$LA" 'BEGIN { exit !(latk != atktime) }' && \
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
         awk -v latk="$_latk" -v atktime="$LA" 'BEGIN { exit !(latk > atktime) }'; then
      (
        run_curl_exec "${URL}$(cat ATK)" > "$TMP/SRC"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17
      cf_access
      echo "$_atk0" > last_atk
    else
      # RECARGA DE ATAQUE — UMA REQUISICAO POR CICLO.
      # O ultimo golpe ja trouxe o HP atual. So relemos a pagina quando o
      # alvo esta momentaneamente invulneravel (grey), para ver quando libera.
      # Fora disso apenas esperamos o restante da recarga, SEM nova
      # requisicao, para o intervalo entre golpes ficar em 4-5s em vez de
      # inflar com recargas de pagina.
      # Rele tambem quando a leitura nao tem link de ataque: a luta so
      # termina pelo luta_acabou, e sem esta releitura o laco dormiria sobre
      # uma pagina sem acao (rede, sessao, transicao) ate o teto.
      if alvo_grey "$TMP/SRC" || [ ! -s ATK ]; then
        (
          run_curl_exec "${URL}/clanfight" > "$TMP/SRC"
        ) </dev/null > /dev/null 2>&1 &
        time_exit 17
        cf_access
        [ -s ATK ] || sleep 1
      else
        _resta=$(( LA - _latk ))
        [ "$_resta" -gt 0 ] && sleep "$_resta"
      fi
    fi
  done

  unset cf_access _random
  func_unset
  printf "ClanFight ok\n"
  sleep 10s
  [ -t 1 ] && clear
}

clanfight_start() {
  # CHAVE COM ERRO DE DIGITACAO, E NINGUEM A LIA.
  #
  # O config.cfg trazia "FUNC_clan_figth" (figth, nao fight) desde sempre, e
  # nenhum arquivo do projeto procurava por esse nome — nem pelo certo. Quem
  # desligasse o Torneio dos Clas no config continuava entrando no evento.
  # O nome foi corrigido e passa a ser respeitado aqui.
  [ "${FUNC_clan_fight:-y}" = "y" ] || return 0
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
    # Espera ate :59:30 — e so dentro da janela. O laco antigo esperava o
    # relogio MOSTRAR 59:30: chegando depois de :59:59 (tres requisicoes
    # lentas acima), a conta ficava presa ate a hora seguinte, com o Torneio
    # ja em andamento (ver espera_janela, em info.sh).
    # O alvo e escalonado por conta dentro de :59:00-:59:29 (janela_alvo):
    # todas pediam a inscricao no mesmo segundo, do mesmo IP.
    espera_janela 5500 `janela_alvo 5900`
    (
      run_curl_exec "$URL/clanfight/enterFight" > "$TMP/SRC"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17
    link_acao "$TMP/SRC" clanfight > "$TMP/ACCESS" 2>/dev/null
    printf " Entering...\n"
    printf " Waiting...\n"
    # 95s, nao 60: com a inscricao escalonada (janela_alvo) a conta pode
    # entrar ja em :59:00, e a luta so aparece em :00.
    BREAK=$(($(date +%s) + 95))
    # A espera termina quando ha LUTA na pagina (qualquer acao do evento),
    # nao quando o primeiro link por acaso e a esquiva.
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
