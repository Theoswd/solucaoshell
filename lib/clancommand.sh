# TORNEIO DE EQUIPE (/clancommand)
#
# Equipe de 3 titas do mesmo cla, UMA batalha por torneio. Os botoes da luta
# sao os dos outros eventos (attack/dodge/heal), entao combate_ler e
# estado_luta servem sem alteracao. O que difere:
# 1. A inscricao tem id dinamico (/clancommand/?enterFight=<id>): o id do
#    torneio e raspado do href do botao "Aplicar", nunca fixo no codigo.
# 2. A inscricao abre horas antes. Duas fases, decididas pelo contador da
#    pagina (_cc_restam): inicio longe -> inscreve e libera a conta; inicio
#    perto -> espera a luta e luta. Nenhum horario codificado.
# 3. E uma batalha so: o laco e o do clancoliseum, nao o do king.
# Nao compra buff (?buyBuff= custa ouro): o bot nao gasta ouro.

# Tempo que falta para o inicio, em segundos, lido do contador da pagina.
# O numero do id <span id='time_N'> e o que falta em MILISSEGUNDOS (o texto vem
# arredondado). Vazio sem contador (torneio em andamento ou nenhum aberto).
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
# So a forma da pagina do evento (/clancommand/); a de /clancommand/myteam/
# e a tela da equipe, nao a entrada. O id muda a cada torneio.
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
# So o lider tem "Aplicar" e inscreve a equipe inteira; cedo, ele nao depende
# da janela de 5 min do run.sh. Inscrito ou sem nada a fazer, anota o inicio
# em $TMP/torneq_ate: ate la o clancommand_inscrever nao pede a pagina.
# Retorna 0 quando nao ha mais nada ate o inicio, 1 para tentar de novo.
_cc_antecipar() { # ARQUIVO LINK SEGUNDOS
    _ca_f="$1"; _ca_link="$2"; _ca_seg="$3"
    if [ -n "$_ca_link" ]; then
        (
          run_curl_exec "${URL}${_ca_link}" > "$_ca_f"
        ) </dev/null > /dev/null 2>&1 &
        time_exit 17

        # A recusa nao vem em texto ("Aplicar" aparece mesmo com equipe
        # incompleta): o sinal de que pegou e o link sumir da releitura.
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

# Inscreve o lider no PROXIMO torneio: logo depois da batalha e, na rotina,
# de hora em hora. Perto do inicio quem cuida e o clancommand_start.
clancommand_inscrever() {
    [ -n "$CLD" ] || return 1
    _ci_ate=; { read -r _ci_ate < "$TMP/torneq_ate"; } 2>/dev/null
    case "$_ci_ate" in ''|*[!0-9]*) _ci_ate=0 ;; esac
    if [ "$(date +%s)" -lt "$_ci_ate" ]; then
        unset _ci_ate; return 0
    fi

    _ci_f="$TMP/ccmd_insc"
    # ?close=reward: terminada a batalha, /clancommand/ mostra o RESULTADO
    # (sem "Aplicar" nem contador) ate alguem fecha-lo. Sem resultado aberto,
    # o jogo devolve a pagina do torneio.
    (
      run_curl_exec "$URL/clancommand/?close=reward" > "$_ci_f"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17

    _ci_rc=1
    if [ "`sessao_estado "$_ci_f"`" = viva ] && \
       [ "`estado_luta "$_ci_f" clancommand`" != luta ]; then
        _ci_seg=`_cc_restam "$_ci_f"`
        case "$_ci_seg" in ''|*[!0-9]*) _ci_seg=0 ;; esac
        # Sem contador: inscricao ainda fechada. Perto do inicio: clancommand_start.
        if [ "$_ci_seg" -gt 600 ]; then
            _cc_antecipar "$_ci_f" "`_cc_inscricao "$_ci_f"`" "$_ci_seg" && _ci_rc=0
        elif [ "$_ci_seg" = 0 ]; then
            printf "Torneio de equipe: sem contador na pagina - tenta de novo em 1h\n"
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

  # Qualquer botao de acao na tela: o combate_ler so da "em luta" com /dodge/,
  # e nao esta confirmado que este evento oferece esquiva (mesmo que no king.sh).
  _cc_acao() {
    [ -s ATK ] || [ -s ATKRND ] || [ -s DODGE ] || \
    [ -s HEAL ] || [ -s GRASS ] || [ -s STONE ]
  }

  cc_access() {
    # Alvo cinza uma vez por pagina.
    if alvo_grey "$src_ram"; then _grey=1; else _grey=0; fi
    set -- `combate_ler clancommand "$HPER" "$RPER" "$src_ram"`
    _emluta="$1"; RHP="$2"; HLHP="$3"; _hpat="$4"; _hp2at="$5"
    alvo_nome "$src_ram" > USER 2>/dev/null
    aliado_ler cla
    # HP lido uma vez; cura e esquiva comparadas uma vez por pagina.
    _hp=`cat HP`
    _cura=0; [ -s HEAL ] && awk -v hp="$_hp" -v hlhp="$HLHP" 'BEGIN { exit !(hp < hlhp) }' && _cura=1
    _caiu=0; [ -s DODGE ] && awk -v hp="$_hp" -v oldhp="$_old_hp" 'BEGIN { exit !(hp < oldhp) }' && _caiu=1

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

    # Sem acao na tela nao e "acabou" (transicao, rede ou unrip): rele UMA vez
    # antes de decidir; o _reconf trava a recursao.
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
  cat HP > old_HP 2>/dev/null; _old_hp="$_hp"; _caiu=0
  echo $(($(date +%s) - 20)) > last_dodge
  echo $(($(date +%s) - 90)) > last_heal
  echo $(($(date +%s) - LA)) > last_atk

  FIGHT_BREAK=`luta_teto`
  # Link vazio nunca vira requisicao: cada ramo exige o proprio link.
  # Um "date" por volta: o mesmo instante decide o teto e a recarga.
  while _atk0=$(date +%s); [ ! -s "BREAK_LOOP" ] && [ "$_atk0" -le "$FIGHT_BREAK" ]; do
    read -r _latk < last_atk; _latk=$(( _atk0 - _latk ))

    if [ -s HEAL ] && \
       [ "$_latk" -gt "$LA" ] && \
       [ "$_cura" = 1 ] && \
       { read -r _lrec < last_heal; [ $(( _atk0 - _lrec )) -gt 90 ]; }; then
      _saiu=0
      (
        read -r _l < HEAL; run_curl_exec "${URL}$_l" > "$src_ram"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17; pedido_nao_saiu || _saiu=1
      cc_access
      # Pedido que nao saiu (pedido_nao_saiu): a acao nao valeu.
      if [ "$_saiu" = 1 ]; then
        cat HP > old_HP; _old_hp="$_hp"; _caiu=0
        date +%s > last_heal
      fi
      # Relogio unico das acoes (como no Rei): a proxima acao, qualquer uma,
      # so depois de LA. Pedido que nao saiu tambem gasta a janela.
      echo "$_atk0" > last_atk

    elif [ -s DODGE ] && [ "$_grey" = 0 ] && \
         [ "$_latk" -gt "$LA" ] && \
         { read -r _lrec < last_dodge; [ $(( _atk0 - _lrec )) -gt 20 ]; } && \
         [ "$_caiu" = 1 ]; then
      _saiu=0
      (
        read -r _l < DODGE; run_curl_exec "${URL}$_l" > "$src_ram"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17; pedido_nao_saiu || _saiu=1
      cc_access
      # Pedido que nao saiu (pedido_nao_saiu): a acao nao valeu.
      if [ "$_saiu" = 1 ]; then
        cat HP > old_HP; _old_hp="$_hp"; _caiu=0
        date +%s > last_dodge
      fi
      # Relogio unico das acoes (como no Rei): a proxima acao, qualquer uma,
      # so depois de LA. Pedido que nao saiu tambem gasta a janela.
      echo "$_atk0" > last_atk

    # Aliado na frente: troca de alvo (troca_aliado, em allies.sh). So por
    # aliado: trocar tambem por inimigo forte deixava a conta sem atacar.
    elif [ -s ATKRND ] && [ "$_latk" -gt "$LA" ] && [ "$_grey" = 0 ] && \
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
      # RECARGA — UMA REQUISICAO POR CICLO. So rele com o alvo grey ou sem
      # ataque na leitura, para nao dormir sobre uma pagina sem acao.
      # Alvo cinza ou sem ataque: rele, mas so depois de LA da ultima acao
      # (colada no golpe, a releitura voltava com o mesmo alvo cinza).
      if { [ "$_grey" = 1 ] || [ ! -s ATK ]; } && [ "$_latk" -gt "$LA" ]; then
        (
          run_curl_exec "$URL/clancommand/" > "$src_ram"
        ) </dev/null > /dev/null 2>&1 &
        time_exit 17
        # A releitura ja e a reconfirmacao (sem a marca, o cc_access relia).
        _reconf=1
        cc_access
        sleep 1
      else
        # Fim do giro: nunca espera zero (com _latk == LA o "-gt" ainda nao
        # deixa o golpe sair e o laco giraria sem dormir).
        _resta=$(( LA - _latk ))
        [ "$_resta" -gt 0 ] || _resta=1
        # Relogio do aparelho voltou (last_atk no futuro): nunca mais que LA.
        [ "$_resta" -le "$LA" ] || _resta=$LA
        sleep "$_resta"
      fi
    fi
  done

  rm -f "$src_ram"
  unset src_ram cc_access _cc_acao _emluta _reconf _atk0 _latk _resta
  printf "Clancommand ok\n"
  [ -t 1 ] && clear
}

clancommand_start() {
  src_ram="$TMP/ccmd_src"

  # ?close=reward: fecha o resultado da batalha anterior, se aberto.
  (
    run_curl_exec "$URL/clancommand/?close=reward" > "$src_ram"
  ) </dev/null > /dev/null 2>&1 &
  time_exit 17

  # Luta ja em andamento (worker relancado): sem este ramo cairia no
  # "sem torneio" e abandonaria a luta.
  if [ "`estado_luta "$src_ram" clancommand`" = luta ]; then
    printf "Torneio de equipe em andamento - voltando para a luta\n"
    batalha_marcar clancommand
    # O /train, se sair, vem antes: a luta comeca com a pagina relida.
    full_relendo "$TMP/FULL" /clancommand/ "$src_ram"
    clancommand_fight
    clancommand_inscrever
    return 0
  fi

  _cc_link=`_cc_inscricao "$src_ram"`
  _cc_seg=`_cc_restam "$src_ram"`
  case "$_cc_seg" in *[!0-9]*) _cc_seg= ;; esac

  # Sem link de inscricao nao quer dizer sem torneio: so o LIDER tem
  # "Aplicar". "Sem torneio" exige a falta de link, de contador e da sala de
  # chat da equipe (changeRoom/?r=<id>). Com qualquer um, espera a luta.
  if [ -z "$_cc_link" ] && [ -z "$_cc_seg" ] && \
     ! grep -q -E 'changeRoom/[?]r=[0-9]+' "$src_ram" 2>/dev/null; then
    # Nada do torneio na pagina: libera a conta (mesmo criterio do
    # clancoliseum_start).
    printf "Torneio de equipe: sem inscricao disponivel agora - pulando\n"
    evento_cancelar clancommand 2>/dev/null
    rm -f "$src_ram"; unset src_ram _cc_link _cc_seg
    return 0
  fi

  # FASE A — INSCRICAO ANTECIPADA: faltando mais de 10 min, inscreve e
  # devolve a conta. Sem batalha_marcar (nao ha batalha a retomar ainda).
  if [ -n "$_cc_seg" ] && [ "$_cc_seg" -gt 600 ]; then
    _cc_antecipar "$src_ram" "$_cc_link" "$_cc_seg"
    evento_cancelar clancommand 2>/dev/null
    rm -f "$src_ram"; unset src_ram _cc_link _cc_seg
    return 0
  fi

  # FASE B — O INICIO ESTA PERTO: ENTRA E LUTA.
  # O link leva o id do torneio, nao um nonce: o /train no meio nao o
  # invalida, entao nao rele a pagina aqui.
  full_atualizar "$TMP/FULL"
  batalha_marcar clancommand
  if [ -n "$_cc_link" ]; then
    (
      run_curl_exec "${URL}${_cc_link}" > "$src_ram"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17
    printf "Torneio de equipe: entrando...\n"
  else
    # Membro: nada a apertar, so esperar a luta (mesmo com o lider ainda sem
    # inscrever: ele inscreve nesta mesma janela).
    printf "Torneio de equipe: %s - aguardando a luta\n" "`_cc_situacao "$src_ram"`"
  fi

  # Sem contador, o prazo vai ate a proxima meia hora cheia (o torneio
  # comeca as :00 ou :30, a janela do run.sh e de 5 min antes).
  [ -n "$_cc_seg" ] || _cc_seg=$(( 1800 - $(date +%s) % 1800 ))

  # Espera o jogo abrir a luta: contador + 90s de folga, teto de 10 min.
  _cc_lim=$(( _cc_seg + 90 ))
  [ "$_cc_lim" -gt 600 ] && _cc_lim=600
  BREAK=$(($(date +%s) + _cc_lim))
  ACCESS=`link_acao "$src_ram" clancommand`

  # Ate perto do inicio nao ha o que ler: o contador da pagina diz quando a
  # luta comeca. Dorme ate ~10s antes e so entao rele de 3 em 3s (eram ~100
  # releituras por torneio). A hora de entrar nao muda.
  _cc_dorme=$(( _cc_seg - 10 ))
  if [ "$_cc_dorme" -gt 0 ] && [ "`estado_luta "$src_ram" clancommand`" != luta ]; then
    printf " aguardando o inicio (%ss)...\n" "$_cc_seg"
    if type espera_interrompivel > /dev/null 2>&1; then espera_interrompivel "$_cc_dorme"; else sleep "$_cc_dorme"; fi
  fi
  unset _cc_dorme

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
    # Nada do torneio na pagina: limpa a anotacao (senao o descansar
    # "retomaria" uma luta inexistente) e guarda a pagina como prova do que o
    # jogo mostrou (inscricao recusada e HP da luta ainda sao suposicao).
    cp "$src_ram" "$TMP/ccmd_sem_luta.html" 2>/dev/null
    printf "Torneio de equipe: nenhuma luta na pagina (guardada em %s)\n" \
           "$TMP/ccmd_sem_luta.html"
    batalha_limpar
    rm -f "$src_ram"
    unset src_ram ACCESS
  fi
  unset _cc_link _cc_seg _cc_lim
}
