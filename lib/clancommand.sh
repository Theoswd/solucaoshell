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
# SO A FORMA DA PAGINA DO EVENTO. A pagina da equipe tem um botao equivalente,
# /clancommand/myteam/?enterFight=<id>, mas /clancommand/myteam/ e a tela de
# ver e montar a equipe, nao e por onde se entra no torneio. E as duas formas
# nunca convivem: medido nas capturas, cada pagina traz apenas a sua, e este
# modulo sempre pede /clancommand/.
#
# O id MUDA a cada torneio (medidos: 98418211, 58198404, 34500465), e e por
# isso que ele sai daqui, do href do botao, em vez de ficar fixo no codigo.
_cc_inscricao() { # ARQUIVO -> /clancommand/?enterFight=<id>
    grep -o -E '/clancommand/[?]enterFight=[0-9]+' "$1" 2>/dev/null | sed -n 1p
}

# Para o log do membro (sem botao "Aplicar"): a pagina diz se o lider ja
# inscreveu a equipe. Sem acento no teste: os bytes UTF-8 variam.
_cc_situacao() { # ARQUIVO -> texto
    if grep -q -E 'der n[^ ]{1,3}o se inscreveu' "$1" 2>/dev/null; then
        printf 'lider ainda nao inscreveu a equipe'
    else
        printf 'membro da equipe, sem botao de inscricao'
    fi
}

# INSCRICAO ANTECIPADA, NUMA PAGINA /clancommand/ JA LIDA.
#
# So o lider tem o botao "Aplicar" e ele inscreve a equipe inteira (captura
# de 09/10/2026, ver clancommand_start). Inscrever cedo tira do lider a
# dependencia da janela de cinco minutos do run.sh: se o worker dele estiver
# preso ou fora nessa hora, a equipe toda perdia o torneio.
#
# Inscrito, ou sem nada a fazer (membro, ou lider que ja inscreveu), anota
# o inicio do torneio em $TMP/torneq_ate: ate la o clancommand_inscrever nao
# pede mais a pagina. Sem a anotacao, cada conta de cla leria /clancommand/
# a cada hora o dia inteiro; com ela, uma vez por torneio.
#
# Retorna 0 quando nao ha mais nada a fazer ate o inicio, 1 quando vale
# tentar de novo depois (inscricao recusada).
_cc_antecipar() { # ARQUIVO LINK SEGUNDOS
    _ca_f="$1"; _ca_link="$2"; _ca_seg="$3"
    if [ -n "$_ca_link" ]; then
        (
          run_curl_exec "${URL}${_ca_link}" > "$_ca_f"
        ) </dev/null > /dev/null 2>&1 &
        time_exit 17

        # A INSCRICAO PODE TER SIDO RECUSADA, E O JOGO NAO DIZ ISSO EM TEXTO.
        #
        # A regra e "3 titas do mesmo cla", mas o botao "Aplicar" aparece
        # mesmo com a equipe incompleta — medido em 05/10/2026, com 2 de 3
        # membros o link estava na pagina. O sinal de que pegou e o link
        # DESAPARECER da releitura. (Heuristica: falta confirmar com uma
        # captura de inscricao aceita.)
        if [ -n "`_cc_inscricao "$_ca_f"`" ]; then
            printf "Torneio de equipe: inscricao nao aceita (equipe incompleta? faltam 3 titas)\n"
            unset _ca_f _ca_link _ca_seg
            return 1
        fi
        printf "Torneio de equipe: equipe inscrita, inicio em %s min\n" "$(( _ca_seg / 60 ))"
    else
        printf "Torneio de equipe: %s, inicio em %s min\n" \
               "`_cc_situacao "$_ca_f"`" "$(( _ca_seg / 60 ))"
    fi
    echo $(( $(date +%s) + _ca_seg )) > "$TMP/torneq_ate" 2>/dev/null
    unset _ca_f _ca_link _ca_seg
    return 0
}

# Inscreve o lider no PROXIMO torneio: chamado logo depois da batalha e, na
# rotina (tarefas_livres), de hora em hora ate a inscricao abrir. Fora da
# luta e longe do inicio — perto dele quem cuida e o clancommand_start, na
# janela do run.sh.
clancommand_inscrever() {
    [ -n "$CLD" ] || return 1
    _ci_ate=; { read -r _ci_ate < "$TMP/torneq_ate"; } 2>/dev/null
    case "$_ci_ate" in ''|*[!0-9]*) _ci_ate=0 ;; esac
    if [ "$(date +%s)" -lt "$_ci_ate" ]; then
        unset _ci_ate; return 0
    fi

    _ci_f="$TMP/ccmd_insc"
    (
      run_curl_exec "$URL/clancommand/" > "$_ci_f"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17

    _ci_rc=1
    if [ "`sessao_estado "$_ci_f"`" = viva ] && \
       [ "`estado_luta "$_ci_f" clancommand`" != luta ]; then
        _ci_seg=`_cc_restam "$_ci_f"`
        case "$_ci_seg" in ''|*[!0-9]*) _ci_seg=0 ;; esac
        # Sem contador: a inscricao do proximo ainda nao abriu (ou o torneio
        # saiu de temporada). Perto do inicio: e a vez do clancommand_start.
        if [ "$_ci_seg" -gt 600 ]; then
            _cc_antecipar "$_ci_f" "`_cc_inscricao "$_ci_f"`" "$_ci_seg" && _ci_rc=0
        fi
    fi
    rm -f "$_ci_f"
    unset _ci_ate _ci_f _ci_seg
    return "$_ci_rc"
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
    # ALVO CINZA, UMA VEZ POR PAGINA. Toda pagina nova da luta passa por
    # aqui (cada requisicao do laco, a releitura e o ressuscitar), e o
    # laco consultava o mesmo arquivo ate tres vezes por volta, um awk
    # cada. O resultado e o mesmo; muda so quantas vezes e calculado.
    if alvo_grey "$src_ram"; then _grey=1; else _grey=0; fi
    set -- `combate_ler clancommand "$HPER" "$RPER" "$src_ram"`
    _emluta="$1"; RHP="$2"; HLHP="$3"; _hpat="$4"; _hp2at="$5"
    alvo_nome "$src_ram" > USER 2>/dev/null
    aliado_ler cla

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
  # UM "date" POR VOLTA: o mesmo instante decide o teto e a recarga.
  while _atk0=$(date +%s); [ ! -s "BREAK_LOOP" ] && [ "$_atk0" -le "$FIGHT_BREAK" ]; do
    # (_atk0 vem da condicao do laco)
    read -r _latk < last_atk; _latk=$(( _atk0 - _latk ))

    if [ -s HEAL ] && \
       awk -v hp="$(cat HP)" -v hlhp="$(cat HLHP)" 'BEGIN { exit !(hp < hlhp) }' && \
       { read -r _lrec < last_heal; [ $(( _atk0 - _lrec )) -gt 90 ]; }; then
      (
        read -r _l < HEAL; run_curl_exec "${URL}$_l" > "$src_ram"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17
      cc_access
      cat HP > old_HP
      date +%s > last_heal

    elif [ -s DODGE ] && [ "$_grey" = 0 ] && \
         { read -r _lrec < last_dodge; [ $(( _atk0 - _lrec )) -gt 20 ]; } && \
         awk -v hp="$(cat HP)" -v oldhp="$(cat old_HP)" 'BEGIN { exit !(hp < oldhp) }'; then
      (
        read -r _l < DODGE; run_curl_exec "${URL}$_l" > "$src_ram"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17
      cc_access
      cat HP > old_HP
      date +%s > last_dodge

    # ALIADO NA FRENTE: TROCA DE ALVO EM VEZ DE BATER NELE (troca_aliado,
    # em allies.sh, com o fogo amigo). So por aliado, como nas outras
    # batalhas de cla: aqui havia tambem "inimigo bem mais forte", e com 3
    # adversarios todos fortes a conta passava a luta trocando sem atacar
    # (medido: 6 trocas e 0 golpes em 20s).
    elif [ -s ATKRND ] && [ "$_latk" -ge "$LA" ] && [ "$_grey" = 0 ] && \
         troca_aliado "$_atk0"; then
      (
        read -r _l < ATKRND; run_curl_exec "${URL}$_l" > "$src_ram"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17
      cc_access
      echo "$_atk0" > last_atk

    elif [ -s ATK ] && \
         [ "$_latk" -gt "$LA" ] && \
         [ "$_grey" = 0 ]; then
      (
        read -r _l < ATK; run_curl_exec "${URL}$_l" > "$src_ram"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17
      cc_access
      echo "$_atk0" > last_atk

    else
      # RECARGA — UMA REQUISICAO POR CICLO. O ultimo golpe ja trouxe o HP; so
      # relemos quando o alvo esta invulneravel (grey) ou quando a leitura
      # ficou sem ataque, para o laco nao dormir sobre uma pagina sem acao.
      if [ "$_grey" = 1 ] || [ ! -s ATK ]; then
        (
          run_curl_exec "$URL/clancommand/" > "$src_ram"
        ) </dev/null > /dev/null 2>&1 &
        time_exit 17
        cc_access
        sleep 1
      else
        # FIM DO GIRO. Acorda no mesmo instante de antes (LA - _latk), mas
        # nunca com espera zero: no segundo em que _latk == LA o golpe ainda
        # nao sai ("-gt") e o laco girava sem dormir esse segundo inteiro
        # (19 a 37 voltas medidas, ~170 processos por golpe). Nesse segundo a
        # pagina nao muda, entao nenhuma acao que dependa dela passa a valer.
        _resta=$(( LA - _latk ))
        [ "$_resta" -gt 0 ] || _resta=1
        sleep "$_resta"
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
    clancommand_inscrever
    return 0
  fi

  _cc_link=`_cc_inscricao "$src_ram"`
  _cc_seg=`_cc_restam "$src_ram"`
  case "$_cc_seg" in *[!0-9]*) _cc_seg= ;; esac

  # SEM LINK DE INSCRICAO NAO QUER DIZER SEM TORNEIO.
  #
  # Este teste era so "sem link? pula". Mas SO O LIDER tem o botao
  # "Aplicar": ele inscreve a equipe inteira. Captura de 09/10/2026, pagina
  # /clancommand/ de um membro:
  #     Tempo restante ate o inicio 16 h 50 min
  #     Participantes: 10 equipes
  #     Lider nao se inscreveu para a batalha      [Atualizar]
  #     Meu time  Abyssal X  Poder: 218597         [Mostrar]
  # Nenhum "Aplicar". O modulo mandava todo membro de volta para a rotina, e
  # so o lider lutava o torneio.
  #
  # Agora "sem torneio" exige a falta das tres coisas: link de inscricao,
  # contador de inicio (que o membro ve, como na captura) e a sala de chat da
  # equipe (changeRoom/?r=<id>, onde o 3.9.65 mediu o mesmo id do torneio).
  # Com qualquer uma delas, a conta espera a luta como as demais. Custo do
  # erro oposto: uma conta sem equipe espera ate o inicio (no maximo ~6 min)
  # e sai sem luta.
  if [ -z "$_cc_link" ] && [ -z "$_cc_seg" ] && \
     ! grep -q -E 'changeRoom/[?]r=[0-9]+' "$src_ram" 2>/dev/null; then
    # DISPONIBILIDADE PELO JOGO, NAO PELO CALENDARIO: nada do torneio na
    # pagina, nao ha o que esperar. Libera a conta em vez de deixa-la dez
    # minutos parada (mesmo criterio do clancoliseum_start).
    printf "Torneio de equipe: sem inscricao disponivel agora - pulando\n"
    evento_cancelar 2>/dev/null
    rm -f "$src_ram"; unset src_ram _cc_link _cc_seg
    return 0
  fi

  # FASE A — INSCRICAO ANTECIPADA.
  #
  # Faltando mais de 10 minutos, inscreve e devolve a conta para a rotina. Nao
  # chama batalha_marcar: nao ha batalha a retomar ainda, e o marcador faria
  # um worker relancado procurar uma luta que so comeca horas depois.
  if [ -n "$_cc_seg" ] && [ "$_cc_seg" -gt 600 ]; then
    _cc_antecipar "$src_ram" "$_cc_link" "$_cc_seg"
    evento_cancelar 2>/dev/null
    rm -f "$src_ram"; unset src_ram _cc_link _cc_seg
    return 0
  fi

  # FASE B — O INICIO ESTA PERTO: ENTRA E LUTA.
  full_atualizar "$TMP/FULL"
  batalha_marcar clancommand
  if [ -n "$_cc_link" ]; then
    (
      run_curl_exec "${URL}${_cc_link}" > "$src_ram"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17
    printf "Torneio de equipe: entrando...\n"
  else
    # MEMBRO: NAO HA O QUE APERTAR, SO ESPERAR A LUTA. Espera mesmo com o
    # lider ainda sem inscrever: o worker do lider inscreve nesta mesma
    # janela (11:25 / 17:55), e o membro que ja desistiu perde a luta.
    printf "Torneio de equipe: %s - aguardando a luta\n" "`_cc_situacao "$src_ram"`"
  fi

  # SEM CONTADOR NA PAGINA, O PRAZO VAI ATE A PROXIMA MEIA HORA CHEIA. O
  # torneio comeca as :00 ou :30 (11:30 e 18:00), e a janela do run.sh e de
  # cinco minutos antes. Contar 0 aqui dava 90s de espera chamado as 11:25, e
  # a conta desistia antes do inicio.
  [ -n "$_cc_seg" ] || _cc_seg=$(( 1800 - $(date +%s) % 1800 ))

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
    clancommand_inscrever
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
