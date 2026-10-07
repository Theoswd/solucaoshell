# TORNEIO DE EQUIPE (/clancommand)
#
# Equipe de 3 titas do mesmo cla, UMA batalha por torneio. Os botoes da luta
# sao os mesmos dos outros eventos (/clancommand/attack/?r=, /dodge/, /heal/),
# entao combate_ler e estado_luta servem SEM ALTERACAO: o verbo "attack" ja
# vira ATK no combate_ler, e no estado_luta ele casa o padrao "^at.*k".
#
# TRES COISAS DIFEREM DOS DEMAIS EVENTOS, E E O QUE ESTE ARQUIVO RESOLVE:
#
# 1. A INSCRICAO TEM ID DINAMICO. Nao e um caminho fixo como
#    /clanfight/enterFight: e /clancommand/?enterFight=<id>, com o id do
#    torneio no corpo da pagina. Hardcodar o id funciona hoje e falha no
#    torneio seguinte, por isso ele e raspado do href do botao "Aplicar".
#    (O mesmo id aparece no campo oculto "s" do chat da equipe e no
#    changeRoom/?r= — confirma que e o id do torneio, nao um nonce de clique.)
#
# 2. A INSCRICAO ABRE HORAS ANTES DO INICIO. Medido em 05/10/2026: o botao
#    "Aplicar" ja estava la com 4h23m de antecedencia. Segurar o worker esse
#    tempo esta fora de questao, entao o modulo tem DUAS FASES e decide em
#    qual esta pelo tempo que a propria pagina informa (ver _cc_restam):
#      - inicio longe  -> inscreve e LIBERA a conta para a rotina;
#      - inicio perto  -> espera a luta e luta.
#    Nenhum horario e codificado aqui. O jogo nao publica a grade do torneio
#    e ela nao foi observada repetir; ler o contador da pagina e a unica
#    forma que nao quebra quando o horario mudar.
#
# 3. E UMA BATALHA SO. Nao ha fases nem rei para morrer no meio, nem
#    reentrada: acabada a luta, o modulo sai. Por isso o laco e o do
#    clancoliseum (evento de batalha unica) e nao o do king.
#
# NAO COMPRA BUFF. /clancommand/myteam/?buyBuff=1|2|3 da +25% de vida, dano ou
# critico por 30 OURO cada. A politica do bot e nao gastar ouro — a mesma
# razao pela qual combate_ler descarta erva e pedra quando passam a cobrar.

# Tempo que falta para o inicio, em segundos, lido do contador da pagina.
#
# A pagina traz <span id='time_15808000'>4 h 23 min</span>: o numero no id e o
# que falta em MILISSEGUNDOS, preciso ao segundo, enquanto o texto vem
# arredondado em minutos. Vazio quando nao ha contador (torneio em andamento
# ou nenhum torneio aberto) — quem chama trata isso.
_cc_restam() { # ARQUIVO -> segundos
    awk '
        { t = t $0 " " }
        END {
            if (!match(t, "id=.?time_[0-9]+")) exit
            s = substr(t, RSTART, RLENGTH)
            sub(/^.*time_/, "", s)
            printf "%d\n", s / 1000
        }' "$1" 2>/dev/null
}

# Link de inscricao com o id do torneio, ou vazio se o jogo nao o oferece.
#
# ACEITA AS DUAS FORMAS, de proposito: o botao "Aplicar" aparece como
# /clancommand/?enterFight=<id> na pagina do evento e como
# /clancommand/myteam/?enterFight=<id> na pagina da equipe, e as duas inscrevem.
# Ler so a primeira forma daria falso "inscrito" quando a resposta da inscricao
# voltasse na forma do myteam — o teste de sucesso aqui e o link DESAPARECER.
_cc_inscricao() { # ARQUIVO -> /clancommand[/myteam]/?enterFight=<id>
    grep -o -E '/clancommand/(myteam/)?[?]enterFight=[0-9]+' "$1" 2>/dev/null | sed -n 1p
}

clancommand_fight() {
  src_ram="$TMP/ccmd_src"
  cd "$TMP" || return 1

  LA=4
  HPER=48
  RPER=15

  # Qualquer botao de acao na tela. combate_ler devolve "em luta" so quando ha
  # /dodge/, e nao esta confirmado que o Torneio de Equipe oferece esquiva —
  # sem esta checagem, um evento sem dodge nunca seria reconhecido como luta.
  # Mesma funcao que o king.sh usa pelo mesmo motivo.
  _cc_acao() {
    [ -s ATK ] || [ -s ATKRND ] || [ -s DODGE ] || \
    [ -s HEAL ] || [ -s GRASS ] || [ -s STONE ]
  }

  cc_access() {
    set -- `combate_ler clancommand "$HPER" "$RPER" "$src_ram"`
    _emluta="$1"; RHP="$2"; HLHP="$3"; _hpat="$4"; _hp2at="$5"
    alvo_nome "$src_ram" > USER 2>/dev/null

    if [ "$_emluta" = "1" ] || _cc_acao; then
      # A pagina respondeu com a luta: sessao confirmada.
      _reconf=0
      sessao_marcar
      printf "Em batalha clancommand - HP: %s\n" "$_hpat"
      # Morto com botao ainda na tela (ver luta_hp, em info.sh).
      if luta_hp "$_hpat"; then
        if ressuscitar clancommand "$src_ram"; then
          cc_access
          return
        fi
        LUTA_MOTIVO="o jogo declarou o personagem morto (HP 0 com a luta na tela)"
        batalha_limpar
        echo 1 > BREAK_LOOP
        printf "Battle over! (%s)\n" "$LUTA_MOTIVO"
      fi
      return
    fi

    # SEM ACAO NA TELA NAO E "ACABOU": pode ser transicao de pagina, soluco de
    # rede ou a nossa morte (a pagina passa a oferecer o unrip). Rele UMA vez
    # antes de decidir — o _reconf trava a recursao.
    if [ "${_reconf:-0}" = 0 ]; then
      _reconf=1
      (
        run_curl_exec "$URL/clancommand/" > "$src_ram"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17
      cc_access
      return
    fi
    _reconf=0

    if ressuscitar clancommand "$src_ram"; then
      cc_access
      return
    fi
    # Quem declara o fim e o jogo, nunca o bot.
    if luta_acabou "$src_ram" clancommand; then
      echo 1 > BREAK_LOOP
      printf "Battle over! (%s)\n" "$LUTA_MOTIVO"
    fi
  }

  luta_inicio clancommand
  cc_access
  > BREAK_LOOP
  cat HP > old_HP 2>/dev/null
  echo $(($(date +%s) - 20)) > last_dodge
  echo $(($(date +%s) - 90)) > last_heal
  echo $(($(date +%s) - LA)) > last_atk

  FIGHT_BREAK=`luta_teto`
  # Link vazio nunca vira requisicao: cada ramo exige o proprio link na
  # pagina, senao "${URL}$(cat HEAL)" com HEAL vazio baixaria a Home.
  until [ -s "BREAK_LOOP" ] || [ "$(date +%s)" -gt "$FIGHT_BREAK" ]; do
    _atk0=$(date +%s)
    _latk=$(( _atk0 - $(cat last_atk) ))

    if [ -s HEAL ] && \
       awk -v hp="$(cat HP)" -v hlhp="$(cat HLHP)" 'BEGIN { exit !(hp < hlhp) }' && \
       [ "$(($(date +%s) - $(cat last_heal)))" -gt 90 ]; then
      (
        run_curl_exec "${URL}$(cat HEAL)" > "$src_ram"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17
      cc_access
      cat HP > old_HP
      date +%s > last_heal

    elif [ -s DODGE ] && ! alvo_grey "$src_ram" && \
         [ "$(($(date +%s) - $(cat last_dodge)))" -gt 20 ] && \
         awk -v hp="$(cat HP)" -v oldhp="$(cat old_HP)" 'BEGIN { exit !(hp < oldhp) }'; then
      (
        run_curl_exec "${URL}$(cat DODGE)" > "$src_ram"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17
      cc_access
      cat HP > old_HP
      date +%s > last_dodge

    # ALIADO NA FRENTE: TROCA DE ALVO EM VEZ DE BATER NELE. A equipe e do
    # proprio cla, entao a protecao de aliados vale aqui como nas batalhas de
    # cla — o atkrnd sorteia outro alvo.
    elif [ -s ATKRND ] && \
         awk -v latk="$_latk" -v atktime="$LA" 'BEGIN { exit !(latk >= atktime) }' && \
         ! alvo_grey "$src_ram" && \
         { awk -v rhp="$(cat RHP)" -v hp2="$(cat HP2)" 'BEGIN { exit !(rhp < hp2) }' || \
           alvo_aliado USER cla; }; then
      (
        run_curl_exec "${URL}$(cat ATKRND)" > "$src_ram"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17
      cc_access
      echo "$_atk0" > last_atk

    elif [ -s ATK ] && \
         awk -v latk="$_latk" -v atktime="$LA" 'BEGIN { exit !(latk > atktime) }' && \
         ! alvo_grey "$src_ram"; then
      (
        run_curl_exec "${URL}$(cat ATK)" > "$src_ram"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17
      cc_access
      echo "$_atk0" > last_atk

    else
      # RECARGA — UMA REQUISICAO POR CICLO. O ultimo golpe ja trouxe o HP; so
      # relemos quando o alvo esta invulneravel (grey) ou quando a leitura
      # ficou sem ataque, para o laco nao dormir sobre uma pagina sem acao.
      if alvo_grey "$src_ram" || [ ! -s ATK ]; then
        (
          run_curl_exec "$URL/clancommand/" > "$src_ram"
        ) </dev/null > /dev/null 2>&1 &
        time_exit 17
        cc_access
        sleep 1
      else
        _resta=$(( LA - _latk ))
        [ "$_resta" -gt 0 ] && sleep "$_resta"
      fi
    fi
  done

  rm -f "$src_ram"
  unset src_ram cc_access _cc_acao _emluta _reconf _atk0 _latk _resta
  printf "Clancommand ok\n"
  sleep 10s
  [ -t 1 ] && clear
}

clancommand_start() {
  src_ram="$TMP/ccmd_src"

  (
    run_curl_exec "$URL/clancommand/" > "$src_ram"
  ) </dev/null > /dev/null 2>&1 &
  time_exit 17

  # LUTA JA EM ANDAMENTO: worker relancado no meio da batalha encontra a
  # pagina de combate e nenhum link de inscricao. Sem este ramo isso cairia no
  # "sem torneio" e a conta abandonaria a luta.
  if [ "`estado_luta "$src_ram" clancommand`" = luta ]; then
    printf "Torneio de equipe em andamento - voltando para a luta\n"
    batalha_marcar clancommand
    full_atualizar "$TMP/FULL"
    clancommand_fight
    return 0
  fi

  _cc_link=`_cc_inscricao "$src_ram"`
  if [ -z "$_cc_link" ]; then
    # DISPONIBILIDADE PELO JOGO, NAO PELO CALENDARIO: sem link de inscricao
    # nao ha torneio a esperar. Libera a conta em vez de deixa-la dez minutos
    # parada (mesmo criterio do clancoliseum_start).
    printf "Torneio de equipe: sem inscricao disponivel agora - pulando\n"
    evento_cancelar 2>/dev/null
    rm -f "$src_ram"; unset src_ram _cc_link
    return 0
  fi

  _cc_seg=`_cc_restam "$src_ram"`
  case "$_cc_seg" in ''|*[!0-9]*) _cc_seg=0 ;; esac

  # FASE A — INSCRICAO ANTECIPADA.
  #
  # Faltando mais de 10 minutos, inscreve e devolve a conta para a rotina. Nao
  # chama batalha_marcar: nao ha batalha a retomar ainda, e o marcador faria
  # um worker relancado procurar uma luta que so comeca horas depois.
  if [ "$_cc_seg" -gt 600 ]; then
    (
      run_curl_exec "${URL}${_cc_link}" > "$src_ram"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17

    # A INSCRICAO PODE TER SIDO RECUSADA, E O JOGO NAO DIZ ISSO EM TEXTO.
    #
    # A regra e "3 titas do mesmo cla", mas o botao "Aplicar" aparece mesmo com
    # a equipe incompleta — medido em 05/10/2026, com 2 de 3 membros o link
    # estava na pagina. O sinal de que pegou e o link DESAPARECER da releitura.
    # (Heuristica: falta confirmar com uma captura de inscricao aceita.)
    if [ -n "`_cc_inscricao "$src_ram"`" ]; then
      printf "Torneio de equipe: inscricao nao aceita (equipe incompleta? faltam 3 titas)\n"
    else
      printf "Torneio de equipe: inscrito, inicio em %s min\n" "$(( _cc_seg / 60 ))"
    fi
    evento_cancelar 2>/dev/null
    rm -f "$src_ram"; unset src_ram _cc_link _cc_seg
    return 0
  fi

  # FASE B — O INICIO ESTA PERTO: ENTRA E LUTA.
  full_atualizar "$TMP/FULL"
  batalha_marcar clancommand
  (
    run_curl_exec "${URL}${_cc_link}" > "$src_ram"
  ) </dev/null > /dev/null 2>&1 &
  time_exit 17
  printf "Torneio de equipe: entrando...\n"

  # Espera o jogo abrir a luta: o que falta do contador mais 90s de folga, com
  # teto de 10 min para o laco nunca virar espera infinita. O clancoliseum usa
  # 60s fixos porque la a inscricao sai 5 min antes; aqui o contador diz
  # exatamente quanto falta, entao o prazo acompanha o evento.
  _cc_lim=$(( _cc_seg + 90 ))
  [ "$_cc_lim" -gt 600 ] && _cc_lim=600
  BREAK=$(($(date +%s) + _cc_lim))
  ACCESS=`link_acao "$src_ram" clancommand`

  until [ "`estado_luta "$src_ram" clancommand`" = luta ] || \
        [ "$(date +%s)" -gt "$BREAK" ]; do
    printf " aguardando o inicio...\n"
    (
      run_curl_exec "$URL/clancommand/" > "$src_ram"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17
    ACCESS=`link_acao "$src_ram" clancommand`
    sleep 3
  done

  if [ -n "$ACCESS" ]; then
    clancommand_fight
  else
    # NADA DO TORNEIO NA PAGINA — E A PAGINA FICA GUARDADA.
    #
    # Sem a anotacao, o descansar logo depois "retomaria" uma luta que nao
    # existe (foi o que custou 90s por conta nas Bandeiras de 11/09).
    #
    # A copia e o mesmo recurso do flagfight_start, e aqui vale mais: duas
    # coisas neste modulo sao suposicao — como o jogo sinaliza inscricao
    # recusada e qual o markup do HP na pagina de luta. Quando o torneio
    # falhar, esta pagina e a prova do que o jogo mostrou, em vez de um log
    # dizendo so que nao deu.
    cp "$src_ram" "$TMP/ccmd_sem_luta.html" 2>/dev/null
    printf "Torneio de equipe: nenhuma luta na pagina (guardada em %s)\n" \
           "$TMP/ccmd_sem_luta.html"
    batalha_limpar
    rm -f "$src_ram"
    unset src_ram ACCESS
  fi
  unset _cc_link _cc_seg _cc_lim
}
