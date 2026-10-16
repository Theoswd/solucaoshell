# shellcheck disable=SC2148
king_fight() {
  cd "$TMP" || return 1
  # LA = intervalo unico entre QUALQUER acao: o jogo recusa acao com menos de
  # ~4-5s da anterior, entao todas dividem o mesmo relogio.
  LA=5
  # Recarga propria de cada acao (alem do LA): esquiva 20s, cura 90s,
  # erva 60s, pedra 60s. Sem ela a mesma acao se repetiria a cada janela.
  LD=20
  LC=90
  LG=60
  LS=60
  # Limiar de vida por fase: rei em jogo 38% (dano no rei vem primeiro);
  # rei morto 67% (a luta segue entre jogadores e sobreviver vem primeiro).
  HPER_REI="38"
  HPER_POS="67"
  HPER="$HPER_REI"
  RPER=5

  # Estado da fase (ver fase_ler).
  _rei_morto=0    # 1 = rei fora da arena, a luta continua entre jogadores
  _sem_rei=0      # leituras seguidas sem o golpe forte do rei na pagina
  _reconf=0       # trava da reconfirmacao do fim da luta
  _reviveu=0      # trava do unrip (nao ressuscitar em laco)

  # HP maximo (FULL, do king_start): recalcula o limiar na hora em que a fase vira.
  _full=0
  [ -r FULL ] && { read -r _full < FULL; } 2>/dev/null
  case "$_full" in ''|*[!0-9]*) _full=0 ;; esac

  # Ha luta na tela? O combate_ler reescreve os arquivos de link a cada
  # leitura (vazio = ausente): basta sobrar QUALQUER acao do rei, nao so a esquiva.
  acao_disponivel() {
    [ -s KINGATK ] || [ -s ATK ]   || [ -s DODGE ] || \
    [ -s HEAL ]    || [ -s GRASS ] || [ -s STONE ]
  }

  # MORTE DO REI: a pagina nao anuncia; o kingatk some com a luta seguindo.
  # Tres leituras seguidas sem ele (~15s) viram a fase; a virada de pagina
  # adianta a contagem. Novo rei coroado (kingatk volta) = volta a fase do rei.
  fase_ler() {
    if [ -s KINGATK ]; then
      _sem_rei=0
      if [ "$_rei_morto" = 1 ]; then
        _rei_morto=0
        HPER="$HPER_REI"
        HLHP=`awk -v full="$_full" -v hper="$HPER" 'BEGIN { printf "%.0f", full * hper / 100 }'`
        printf "Rei na arena — prioridade no dano (cura abaixo de %s%%)\n" "$HPER_REI"
      fi
    elif [ "$_rei_morto" = 0 ]; then
      _sem_rei=$(( _sem_rei + 1 ))
      if [ "$_sem_rei" -ge 3 ]; then
        _rei_morto=1
        HPER="$HPER_POS"
        HLHP=`awk -v full="$_full" -v hper="$HPER" 'BEGIN { printf "%.0f", full * hper / 100 }'`
        printf "Rei morto — a batalha CONTINUA (esquiva liberada, elixir abaixo de %s%%)\n" "$HPER_POS"
      fi
    fi
  }

  cl_access() {
    # Alvo cinza uma vez por pagina (ver o mesmo ponto no clanfight.sh).
    if alvo_grey "$TMP/SRC"; then _grey=1; else _grey=0; fi
    set -- `combate_ler king "$HPER" "$RPER" "$TMP/SRC"`
    _emluta="$1"; RHP="$2"; HLHP="$3"; _hpat="$4"; _hp2at="$5"
    # Nome do ALVO (alvo_nome, em info.sh), para a protecao de aliados.
    alvo_nome "$TMP/SRC" > USER 2>/dev/null
    aliado_ler

    if [ "$_emluta" = "1" ] || acao_disponivel; then
      # A pagina respondeu com a luta: sessao confirmada.
      _reconf=0
      sessao_marcar
      fase_ler
      printf "Em batalha - HP: %s\n" "$_hpat"

      # Morto com botao na tela (luta_hp, em info.sh): o Rei mantem os botoes
      # depois da morte. Tenta ressuscitar uma vez; sem isso, encerra.
      if luta_hp "$_hpat"; then
        if ressuscitar king "$TMP/SRC"; then
          cl_access
          return
        fi
        LUTA_MOTIVO="o jogo declarou o personagem morto (HP 0 com a luta na tela)"
        batalha_limpar
        echo 1 > BREAK_LOOP
        printf "Battle over. (%s)\n" "$LUTA_MOTIVO"
        return
      fi
      # A trava da ressurreicao so solta no luta_hp, com vida de verdade na tela.
      return
    fi

    # SEM ACAO NA TELA nao e "batalha encerrada": pode ser (a) a virada do rei
    # morto, (b) a nossa morte (unrip) ou (c) transicao/rede. Rele /king UMA
    # vez; na segunda passada (_reconf=1) a pagina ja e a releitura.
    if [ "${_reconf:-0}" = 0 ]; then
    # A virada so conta com pagina do jogo: resposta vazia/de rede nao e o rei
    # caindo (trocaria a fase com o rei vivo).
    case "`estado_luta "$TMP/SRC" king`" in
      invalida|deslogado) _virada=0 ;;
      *)                  _virada=1 ;;
    esac
    (
      run_curl_exec "${URL}/king" > "$TMP/SRC"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17
    # (b) Morremos: ressuscita e volta para a luta relendo a pagina (os nonces
    # da anterior ja morreram). A trava _reviveu impede o laco.
    if ressuscitar king "$TMP/SRC"; then
      cl_access
      return
    fi

    # (a)/(c) A releitura pode ter trazido a luta de volta: reavalia UMA vez
    # (_reconf trava a recursao). A virada adianta a contagem da morte do rei.
      _reconf=1
      [ "$_virada" = 1 ] && _sem_rei=3
      cl_access
      return
    fi
    _reconf=0
    # Passada da releitura (daqui ou do ramo "sem link de ataque" do laco):
    # ressuscitar e virada valem aqui tambem; a trava _reviveu impede outro unrip.
    if ressuscitar king "$TMP/SRC"; then
      cl_access
      return
    fi
    case "`estado_luta "$TMP/SRC" king`" in
      invalida|deslogado) ;;
      *) _sem_rei=3 ;;
    esac
    # So o jogo declara o fim (morte ou fim), e e isso que o luta_acabou le.
    # Sem declaracao, o laco segue.
    if luta_acabou "$TMP/SRC" king; then
      echo 1 > BREAK_LOOP
      printf "Battle over. (%s)\n" "$LUTA_MOTIVO"
      sleep 3s
    fi
  }

  # ============================================================
  #  LACO DE LUTA DO REI — UMA ACAO POR JANELA DE LA (5s), nesta prioridade:
  #     1) CURA — vida abaixo do limiar da fase, recarga 90s;
  #     2) ESQUIVA — so com o rei morto, vida abaixo do limiar e cura
  #        indisponivel; recarga 20s (com o rei vivo cada janela e dano);
  #     3) ERVA / 4) PEDRA — so disponiveis e de graca, recarga 1min;
  #     5) ATAQUE — kingatk com o rei na arena, senao o normal.
  #  _last_act marca o INICIO da acao. Dentro dos 5s so espera, sem pedido.
  #  Link vazio nunca vira requisicao: "${URL}" sozinho baixaria a home.
  # ============================================================
  luta_inicio king
  cl_access
  _agora=`date +%s`
  _last_heal=$(( _agora - LC ))
  _last_dodge=$(( _agora - LD ))
  # Erva e pedra nao tem leitor no painel: ficam so em variavel.
  _last_grass=$(( _agora - LG ))
  _last_stone=$(( _agora - LS ))
  _last_act=$(( _agora - LA ))       # relogio unico das acoes
  # old_HP gravado uma vez para o painel mostrar o dano acumulado da luta.
  echo "$_hpat"       > old_HP
  echo "$_last_heal"  > last_heal
  echo "$_last_dodge" > last_dodge
  echo "$_last_act"   > last_atk     # o painel le last_atk como "ultima acao"
  : > BREAK_LOOP

  # Teto de seguranca (luta_teto): so segura laco que nunca resolve; quem
  # encerra a luta e o jogo, pelo luta_acabou.
  FIGHT_BREAK=`luta_teto`
  # Um "date" por volta: o mesmo instante decide o teto e o relogio de acao.
  while _agora=`date +%s`; [ ! -s "BREAK_LOOP" ] && [ "$_agora" -le "$FIGHT_BREAK" ]; do

    if [ $(( _agora - _last_act )) -ge "$LA" ]; then

      # PRIORIDADE 1 — CURA (elixir/esmalte): vida abaixo do limiar, recarga
      # 90s, sem teto de tempo. O FULL nunca e sobrescrito pelo HP atual.
      if [ -s HEAL ] && \
         awk -v ush="$_hpat" -v hlhp="$HLHP" 'BEGIN { exit !(ush < hlhp) }' && \
         [ $(( _agora - _last_heal )) -ge "$LC" ]; then
        (
          read -r _l < HEAL; run_curl_exec "${URL}$_l" > "$TMP/SRC"
        ) </dev/null > /dev/null 2>&1 &
        time_exit 17; _saiu=1; pedido_nao_saiu && _saiu=0
        cl_access
        # Pedido que nao saiu (pedido_nao_saiu): a cura nao valeu.
        if [ "$_saiu" = 1 ]; then _last_heal="$_agora"; echo "$_last_heal" > last_heal; fi
        _last_act="$_agora";  echo "$_last_act"  > last_atk

      # PRIORIDADE 2 — ESQUIVA: so com o rei morto, vida abaixo do limiar e a
      # cura acima sem pegar. Recarga 20s.
      elif [ "$_rei_morto" = 1 ] && [ -s DODGE ] && \
           awk -v ush="$_hpat" -v hlhp="$HLHP" 'BEGIN { exit !(ush < hlhp) }' && \
           [ $(( _agora - _last_dodge )) -ge "$LD" ]; then
        (
          read -r _l < DODGE; run_curl_exec "${URL}$_l" > "$TMP/SRC"
        ) </dev/null > /dev/null 2>&1 &
        time_exit 17; _saiu=1; pedido_nao_saiu && _saiu=0
        cl_access
        if [ "$_saiu" = 1 ]; then _last_dodge="$_agora"; echo "$_last_dodge" > last_dodge; fi
        _last_act="$_agora";   echo "$_last_act"   > last_atk

      # PRIORIDADE 3 — ERVA: so com link (GRASS) e de graca (o combate_ler
      # descarta o link pago em ouro). Recarga 1min.
      elif [ -s GRASS ] && [ $(( _agora - _last_grass )) -ge "$LG" ]; then
        (
          read -r _l < GRASS; run_curl_exec "${URL}$_l" > "$TMP/SRC"
        ) </dev/null > /dev/null 2>&1 &
        time_exit 17
        cl_access
        _last_grass="$_agora"
        _last_act="$_agora"; echo "$_last_act" > last_atk

      # PRIORIDADE 4 — PEDRA: mesma regra da erva.
      elif [ -s STONE ] && [ $(( _agora - _last_stone )) -ge "$LS" ]; then
        (
          read -r _l < STONE; run_curl_exec "${URL}$_l" > "$TMP/SRC"
        ) </dev/null > /dev/null 2>&1 &
        time_exit 17
        cl_access
        _last_stone="$_agora"
        _last_act="$_agora"; echo "$_last_act" > last_atk

      # PRIORIDADE 5 — ATAQUE: kingatk com o rei na arena, depois o normal.
      # So com link e com o alvo fora do grey (invulneravel).
      elif { [ -s KINGATK ] || [ -s ATK ]; } && \
           [ "$_grey" = 0 ]; then
        if [ -s KINGATK ]; then
          # O golpe forte e no REI, nao num jogador: nao ha aliado a poupar.
          (
            read -r _l < KINGATK; run_curl_exec "${URL}$_l" > "$TMP/SRC"
          ) </dev/null > /dev/null 2>&1 &
          time_exit 17
          cl_access
        elif [ -s ATKRND ] && troca_aliado "$_agora"; then
          # Aliado na frente (rei morto, luta entre jogadores): o atkrnd
          # sorteia outro alvo. Consome a janela de 5s como qualquer acao.
          (
            read -r _l < ATKRND; run_curl_exec "${URL}$_l" > "$TMP/SRC"
          ) </dev/null > /dev/null 2>&1 &
          time_exit 17
          cl_access
        else
          (
            read -r _l < ATK; run_curl_exec "${URL}$_l" > "$TMP/SRC"
          ) </dev/null > /dev/null 2>&1 &
          time_exit 17
          cl_access
        fi
        # Marca o INICIO da acao, para o request nao inflar o intervalo.
        _last_act="$_agora"; echo "$_last_act" > last_atk

      else
        # Alvo grey ou sem link de ataque: rele a pagina. Conta como o turno
        # do relogio, para nao virar atualizacao em rajada.
        (
          run_curl_exec "${URL}/king" > "$TMP/SRC"
        ) </dev/null > /dev/null 2>&1 &
        time_exit 17
        # A releitura acima ja e a reconfirmacao (ver clanfight.sh).
        _reconf=1
        cl_access
        _last_act="$_agora"; echo "$_last_act" > last_atk
      fi

    else
      # Dentro do intervalo: espera sem requisicao (pedido <5s atrapalha).
      _resta=$(( LA - ( _agora - _last_act ) ))
      # Relogio do aparelho voltou: nunca mais que LA.
      [ "$_resta" -le "$LA" ] || _resta=$LA
      [ "$_resta" -gt 0 ] && sleep "$_resta"
    fi

  done

  # ── SAIDA DA BATALHA ───────────────────────────────────────────────────────
  # A luta nao termina quando o rei cai. Na saida, uma ultima esquiva (se o
  # link estiver na pagina) para garantir a posicao na proxima rodada.
  if [ -s DODGE ]; then
    printf "Saindo da batalha — esquiva final\n"
    (
      run_curl_exec "${URL}$(cat DODGE)" > "$TMP/SRC"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17
  fi

  unset cl_access acao_disponivel fase_ler
  unset _rei_morto _sem_rei _reconf _reviveu _virada _full HPER_REI HPER_POS
  unset _last_dodge _last_grass _last_stone LD LC LG LS
  func_unset
  # Sem inscricao depois da luta: a de cada Rei e feita pelo king_start.
  printf "King ok\n"
  [ -t 1 ] && clear
}

king_start() {
  case `date +%H:%M` in
  (12:2[5-9]|16:2[5-9]|22:2[5-9])
    full_atualizar "$TMP/FULL"
    # Inscrita, a conta ja esta comprometida com o evento: a batalha fica
    # anotada para o worker relancado voltar a ela (batalha_retomar).
    batalha_marcar king
    (
      run_curl_exec "$URL/king/enterGame" > "$TMP/SRC"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17
    printf "King of the Immortals will be started...\n"
    # Ate :29:50-:29:59, escalonado por conta (janela_alvo, em info.sh).
    espera_janela 2500 `janela_alvo 2950 10`
    (
      run_curl_exec "$URL/king/enterGame" > "$TMP/SRC"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17
    printf "\nKing\n%s\n" "$URL"
    link_acao "$TMP/SRC" king > "$TMP/ACCESS" 2>/dev/null
    printf " Entering...\n%s\n" "`cat "$TMP/ACCESS"`"
    printf " Waiting...\n"
    cat "$TMP/SRC" | grep -o 'king/kingatk/' > "$TMP/EXIT" 2>/dev/null
    # 60s; termina tambem com QUALQUER acao do Rei na pagina.
    BREAK=$(($(date +%s) + 60))
    until [ -s "$TMP/EXIT" ] || [ "`estado_luta "$TMP/SRC" king`" = luta ] || \
          [ "$(date +%s)" -gt "$BREAK" ]; do
      printf " ...\n%s\n" "`cat "$TMP/ACCESS"`"
      # Rele a pagina do Rei sem clicar (o primeiro link podia ser sair da fila).
      (
        run_curl_exec "${URL}/king/" > "$TMP/SRC"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17
      link_acao "$TMP/SRC" king > "$TMP/ACCESS" 2>/dev/null
      cat "$TMP/SRC" | grep -o 'king/kingatk/' > "$TMP/EXIT" 2>/dev/null
      sleep 2
    done
    king_fight
    ;;
  esac
}
