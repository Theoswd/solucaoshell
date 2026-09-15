# shellcheck disable=SC2148
king_fight() {
  cd "$TMP" || return 1
  # LA = intervalo unico entre QUALQUER acao (ataque, erva, pedra, cura,
  # esquiva). O jogo recusa uma acao que venha menos de ~4-5s depois da
  # anterior, entao todas compartilham o MESMO relogio: uma por vez, a cada 5s.
  LA=5
  # RECARGA PROPRIA DE CADA ACAO (alem do intervalo unico de 5s):
  #   esquiva        20s
  #   esmalte/cura   90s  (1min30)
  #   erva           60s  (1min)
  #   pedra          60s  (1min)
  # Sem elas a conta repetiria a mesma acao a cada janela de 5s — o jogo
  # recusa e a janela vira golpe perdido. Com a recarga, entre um uso e o
  # seguinte a conta volta a atacar.
  LD=20
  LC=90
  LG=60
  LS=60
  # LIMIAR DE VIDA, POR FASE DA BATALHA:
  #   rei em jogo -> 38%: o que conta e dano no rei, curar cedo custa golpe.
  #   rei morto   -> 67%: a luta segue entre jogadores e quem morre perde a
  #                  posicao — sobreviver passa na frente do dano.
  HPER_REI="38"
  HPER_POS="67"
  HPER="$HPER_REI"
  RPER=5

  # Estado da fase (ver "MORTE DO REI" mais abaixo).
  _rei_morto=0    # 1 = rei fora da arena, a luta continua entre jogadores
  _sem_rei=0      # leituras seguidas sem o golpe forte do rei na pagina
  _reconf=0       # trava da reconfirmacao do fim da luta
  _reviveu=0      # trava do unrip (nao ressuscitar em laco)

  # HP maximo (vem do /train, gravado pelo king_start). Guardado em variavel
  # para recalcular o limiar de cura NA HORA em que a fase vira, sem esperar
  # a leitura seguinte. Lido com o "read" embutido: nenhum processo a mais.
  _full=0
  [ -r FULL ] && { read -r _full < FULL; } 2>/dev/null
  case "$_full" in ''|*[!0-9]*) _full=0 ;; esac

  # LEITURA DA PAGINA: DE 23 PROCESSOS PARA 2.
  #
  # Esta funcao lia o MESMO arquivo 23 vezes — sete grep, nove sed, dois awk
  # e cinco "$(cat ...)" — e roda duas a tres vezes por volta do laco de
  # luta. Davam 50 a 70 processos por volta, por conta, com todas as contas
  # entrando no evento no mesmo minuto. E o que estourava o teto de 32
  # processos do Android 12 e trazia o "signal 9" de volta justamente em
  # evento.
  #
  # Agora um unico awk le a pagina uma vez e grava os mesmos arquivos, com o
  # mesmo conteudo — conferido byte a byte em cinco cenarios: luta completa,
  # sem kingatk/stone, luta encerrada, pagina vazia e HP ausente.
  #
  # Sobram dois processos: o awk e o grep do nome do alvo, que continua
  # separado por depender de "sed -n 2p" com substituicoes proprias.

  # HA LUTA NA TELA?
  #
  # O combate_ler reescreve os sete arquivos de link a CADA leitura (vazio =
  # link ausente na pagina), entao basta perguntar se sobrou ALGUMA acao do
  # rei. Nenhum processo: sao testes embutidos do shell.
  #
  # ERA AQUI O DEFEITO PRINCIPAL: a luta so era reconhecida pelo link de
  # ESQUIVA. Quando o rei morre a pagina muda de forma (some o golpe forte e,
  # na virada, tambem a esquiva) — e o bot dava a batalha por encerrada com
  # ataque, cura e itens ainda na tela.
  acao_disponivel() {
    [ -s KINGATK ] || [ -s ATK ]   || [ -s DODGE ] || \
    [ -s HEAL ]    || [ -s GRASS ] || [ -s STONE ]
  }

  # MORTE DO REI — TROCA DE FASE
  #
  # A pagina nao anuncia a morte; o que ela mostra e que o golpe forte
  # (kingatk) deixou de existir enquanto a luta continua. Tres leituras
  # seguidas sem ele (~15s) para nao confundir com a ausencia passageira do
  # link — e a virada de pagina da luta ja adianta essa contagem, porque
  # sumir e voltar e o sinal mais forte de que o rei caiu.
  #
  # Se um novo rei for coroado o kingatk volta e a fase volta com ele: a
  # esquiva desliga de novo e a prioridade e dano, como era antes.
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
    set -- `combate_ler king "$HPER" "$RPER" "$TMP/SRC"`
    _emluta="$1"; RHP="$2"; HLHP="$3"; _hpat="$4"; _hp2at="$5"
    # Nome do ALVO (ver alvo_nome, em info.sh). A leitura antiga devolvia
    # "Fulano_&" em toda pagina do Rei: a protecao de aliados nunca agia.
    alvo_nome "$TMP/SRC" > USER 2>/dev/null

    if [ "$_emluta" = "1" ] || acao_disponivel; then
      # A pagina respondeu com a luta: sessao confirmada.
      _reconf=0
      sessao_marcar
      fase_ler
      printf "Em batalha - HP: %s\n" "$_hpat"

      # MORTO COM BOTAO NA TELA (ver luta_hp, em info.sh). No Rei a pagina
      # mantem os botoes depois da morte: a conta ficava "lutando" com HP 0
      # ate o teto de 30 min. Primeiro tenta a ressurreicao, uma vez; sem ela,
      # o jogo ja declarou a morte.
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
      # A trava da ressurreicao so solta com vida de verdade na tela. Antes
      # ela zerava a cada leitura com botao, e com HP 0 + botao isso viraria
      # um unrip a cada tres leituras.
      # (o destravamento passou para o luta_hp, que e o ponto que ja
    # distingue vida de zero; ver info.sh)
      return
    fi

    # SEM ACAO NA TELA — E NENHUM DOS CASOS ABAIXO E "BATALHA ENCERRADA":
    #   (a) a virada do rei morto (a pagina troca de forma por um instante);
    #   (b) a nossa morte (a pagina passa a oferecer o unrip);
    #   (c) uma pagina de transicao ou um soluco de rede.
    # Rele /king antes de decidir qualquer coisa.
    (
      run_curl_exec "${URL}/king" > "$TMP/SRC"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17
    # (b) Morremos: ressuscita e VOLTA para a luta, relendo a pagina do
    # unrip (clicar e seguir com os links da pagina anterior nao funciona:
    # os nonces dela ja morreram). A trava _reviveu impede o laco.
    #
    # As duas copias deste bloco viraram ressuscitar(), no info.sh, e com
    # isso todos os eventos passaram a tentar voltar antes de encerrar — o
    # Rei era o unico que tentava.
    if ressuscitar king "$TMP/SRC"; then
      cl_access
      return
    fi

    # (a)/(c) A releitura de /king pode ter trazido a luta de volta — e era
    # exatamente isso que o codigo antigo jogava fora: ele so procurava o
    # unrip nesta pagina e, sem ele, gravava BREAK_LOOP e anunciava "Battle
    # over" com a batalha em andamento. Reavalia UMA vez (o _reconf trava a
    # recursao) e so entao desiste. A virada de pagina adianta a contagem da
    # morte do rei: se na volta nao houver kingatk, a fase muda na hora.
    if [ "${_reconf:-0}" = 0 ]; then
      _reconf=1
      _sem_rei=3
      cl_access
      return
    fi
    _reconf=0
    # Nem a releitura trouxe acao do Rei. Ainda assim nao e o bot quem decide
    # que a luta acabou: so o jogo declara (morte ou fim), e e isso que o
    # luta_acabou le. Sem declaracao, o laco segue na pagina do Rei.
    if luta_acabou "$TMP/SRC" king; then
      echo 1 > BREAK_LOOP
      printf "Battle over. (%s)\n" "$LUTA_MOTIVO"
      sleep 3s
    fi
  }

  # ============================================================
  #  LACO DE LUTA DO REI — UMA ACAO POR CICLO, 4 A 5 SEGUNDOS
  #
  #  RELOGIO UNICO DE ACOES (LA = 5s):
  #  O jogo recusa qualquer acao que venha menos de ~4-5s depois da anterior
  #  (o golpe/item "falha" e nao acerta). Por isso ATAQUE, ERVA, PEDRA, CURA e
  #  ESQUIVA compartilham UM SO relogio (_last_act): sai UMA acao por vez, a
  #  cada 5s. A cada janela escolhe-se UMA acao, nesta prioridade:
  #     1) CURA (elixir/esmalte) — com a vida abaixo do limiar da fase,
  #        recarga propria de 90s e SO com o link na pagina;
  #     2) ESQUIVA — so com o rei ja morto, so com a vida abaixo do limiar e
  #        so quando a cura NAO estava disponivel (sem elixir na pagina ou
  #        ainda em recarga). Recarga propria de 20s;
  #     3) ERVA  — so quando disponivel, de graca, recarga de 1min;
  #     4) PEDRA — so quando disponivel, de graca, recarga de 1min;
  #     5) ATAQUE — kingatk (golpe forte) enquanto o rei estiver na arena,
  #        senao o ataque normal.
  #  O _last_act e marcado no INICIO da acao, para o tempo do request contar
  #  DENTRO do intervalo em vez de somar-se a ele. Dentro dos 5s o bot so
  #  espera, SEM nenhuma requisicao (uma atualizacao de pagina <5s tambem
  #  atrapalharia a proxima acao).
  #
  #  LINK VAZIO NUNCA VIRA REQUISICAO: todo ramo exige o arquivo do link
  #  nao-vazio antes de agir. Pedir "${URL}$(cat ATK)" com ATK vazio baixava a
  #  PAGINA INICIAL, e a leitura seguinte — sem nenhum link de luta — dava a
  #  batalha por encerrada. Era o mesmo defeito ja corrigido no Vale dos
  #  Imortais.
  #
  #  ESQUIVA: continua DESLIGADA enquanto o rei esta em jogo — ali cada janela
  #  de 5s tem de virar dano no rei. Ela entra depois que o rei morre, e ainda
  #  assim so para segurar a vida, quando nao ha elixir para usar.
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

  # TETO DE SEGURANCA (luta_teto, em info.sh). Era de 10 minutos contados da
  # entrada de CADA conta — e a luta continua entre os jogadores depois que o
  # rei cai. Agora so segura o laco que nunca resolve (rede fora): quem
  # encerra a luta e o jogo, pelo luta_acabou.
  FIGHT_BREAK=`luta_teto`
  until [ -s "BREAK_LOOP" ] || [ "`date +%s`" -gt "$FIGHT_BREAK" ]; do
    _agora=`date +%s`

    # RELOGIO UNICO: so age uma vez a cada LA (5s). Qualquer acao (ataque,
    # erva, pedra, cura, esquiva) antes disso "falha" no jogo, entao todas
    # esperam o mesmo intervalo. Dentro dos 5s o bot so espera, sem NENHUMA
    # requisicao.
    if [ $(( _agora - _last_act )) -ge "$LA" ]; then

      # PRIORIDADE 1 — CURA (elixir/esmalte): vida abaixo do limiar da fase
      # cura primeiro, para a conta nao morrer (recarga propria de 90s). So
      # com o link na pagina. O HP maximo (FULL, do /train) NUNCA e
      # sobrescrito pelo HP atual pos-cura.
      #
      # CORRECAO: havia tambem um teto de 300s ("-lt 300") nesta condicao.
      # Como o relogio da cura so anda quando a conta cura, passados cinco
      # minutos SEM curar a cura ficava proibida pelo resto da luta — em uma
      # batalha de dez minutos era a metade dela sem elixir, justamente na
      # parte em que a vida ja esta baixa.
      if [ -s HEAL ] && \
         awk -v ush="$_hpat" -v hlhp="$HLHP" 'BEGIN { exit !(ush < hlhp) }' && \
         [ $(( _agora - _last_heal )) -ge "$LC" ]; then
        (
          run_curl_exec "${URL}$(cat HEAL)" > "$TMP/SRC"
        ) </dev/null > /dev/null 2>&1 &
        time_exit 17
        cl_access
        _last_heal="$_agora"; echo "$_last_heal" > last_heal
        _last_act="$_agora";  echo "$_last_act"  > last_atk

      # PRIORIDADE 2 — ESQUIVA: SO depois da morte do rei (_rei_morto=1), so
      # com a vida abaixo do limiar da fase e so quando a cura acima NAO
      # pegou — ou seja, exatamente o "nao tem elixir, ve se tem esquiva".
      # Recarga de 20s para nao virar esquiva em serie: entre uma e outra a
      # conta volta a atacar.
      elif [ "$_rei_morto" = 1 ] && [ -s DODGE ] && \
           awk -v ush="$_hpat" -v hlhp="$HLHP" 'BEGIN { exit !(ush < hlhp) }' && \
           [ $(( _agora - _last_dodge )) -ge "$LD" ]; then
        (
          run_curl_exec "${URL}$(cat DODGE)" > "$TMP/SRC"
        ) </dev/null > /dev/null 2>&1 &
        time_exit 17
        cl_access
        _last_dodge="$_agora"; echo "$_last_dodge" > last_dodge
        _last_act="$_agora";   echo "$_last_act"   > last_atk

      # PRIORIDADE 3 — ERVA: acao propria, SO quando disponivel (link na
      # pagina = arquivo GRASS nao-vazio) e SO de graca — o combate_ler
      # descarta o link quando a etiqueta do botao pede ouro. Recarga de 1min.
      elif [ -s GRASS ] && [ $(( _agora - _last_grass )) -ge "$LG" ]; then
        (
          run_curl_exec "${URL}$(cat GRASS)" > "$TMP/SRC"
        ) </dev/null > /dev/null 2>&1 &
        time_exit 17
        cl_access
        _last_grass="$_agora"
        _last_act="$_agora"; echo "$_last_act" > last_atk

      # PRIORIDADE 4 — PEDRA: mesma regra da erva — so quando disponivel
      # (STONE nao-vazio), so de graca e com recarga de 1min.
      elif [ -s STONE ] && [ $(( _agora - _last_stone )) -ge "$LS" ]; then
        (
          run_curl_exec "${URL}$(cat STONE)" > "$TMP/SRC"
        ) </dev/null > /dev/null 2>&1 &
        time_exit 17
        cl_access
        _last_stone="$_agora"
        _last_act="$_agora"; echo "$_last_act" > last_atk

      # PRIORIDADE 5 — ATAQUE: kingatk (golpe forte) enquanto o rei estiver na
      # arena; depois da morte dele sobra o ataque normal, que e como a luta
      # entre jogadores continua. So com link de verdade e so quando o alvo
      # NAO esta grey (invulneravel).
      elif { [ -s KINGATK ] || [ -s ATK ]; } && \
           ! alvo_grey "$TMP/SRC"; then
        if [ -s KINGATK ]; then
          # O golpe forte e no REI, nao num jogador: nao ha aliado a poupar.
          (
            run_curl_exec "${URL}$(cat KINGATK)" > "$TMP/SRC"
          ) </dev/null > /dev/null 2>&1 &
          time_exit 17
          cl_access
        elif [ -s ATKRND ] && alvo_aliado USER; then
          # ALIADO NA FRENTE: TROCA DE ALVO EM VEZ DE BATER NELE.
          #
          # Depois que o rei morre a luta continua entre jogadores, e o alvo
          # da vez pode ser alguem da lista de aliados. O /king/atkrnd sorteia
          # outro alvo — e o mesmo recurso que as batalhas de cla ja usavam
          # para nao acertar cla aliado.
          #
          # Consome a janela de 5s como qualquer acao: trocar de alvo tambem
          # e uma jogada, e nao pode virar rajada.
          printf "Alvo aliado — trocando de alvo\n"
          (
            run_curl_exec "${URL}$(cat ATKRND)" > "$TMP/SRC"
          ) </dev/null > /dev/null 2>&1 &
          time_exit 17
          cl_access
        else
          (
            run_curl_exec "${URL}$(cat ATK)" > "$TMP/SRC"
          ) </dev/null > /dev/null 2>&1 &
          time_exit 17
          cl_access
        fi
        # Marca o INICIO da acao (nao o fim do request): o intervalo ate a
        # proxima acao fica em ~LA (5s), sem inflar com o tempo do request.
        _last_act="$_agora"; echo "$_last_act" > last_atk

      else
        # Alvo grey (invulneravel), ou nenhum link de ataque nesta leitura:
        # rele a pagina para ver quando o rei — ou o proximo alvo — libera.
        # Conta como o turno do relogio (5s), para nao virar atualizacao em
        # rajada (<5s tambem atrapalha).
        (
          run_curl_exec "${URL}/king" > "$TMP/SRC"
        ) </dev/null > /dev/null 2>&1 &
        time_exit 17
        cl_access
        _last_act="$_agora"; echo "$_last_act" > last_atk
      fi

    else
      # Dentro do intervalo de 5s: espera o restante SEM nenhuma requisicao —
      # uma atualizacao de pagina antes de 5s atrapalharia a proxima acao.
      _resta=$(( LA - ( _agora - _last_act ) ))
      [ "$_resta" -gt 0 ] && sleep "$_resta"
    fi

  done

  # ── SAIDA DA BATALHA ───────────────────────────────────────────────────────
  # POS-MORTE DO REI: a luta NAO termina quando o rei cai. O laco acima segue
  # atacando, curando e esquivando ate a pagina nao oferecer mais nenhuma acao
  # (fim confirmado com releitura) ou ate o teto de 10 minutos.
  # Aqui e a saida de verdade: uma ultima esquiva, se o link ainda estiver na
  # pagina, para garantir a posicao na proxima rodada.
  if [ -s DODGE ]; then
    printf "Saindo da batalha — esquiva final\n"
    (
      run_curl_exec "${URL}$(cat DODGE)" > "$TMP/SRC"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17
  fi

  unset cl_access acao_disponivel fase_ler
  unset _rei_morto _sem_rei _reconf _reviveu _full HPER_REI HPER_POS
  unset _last_dodge _last_grass _last_stone LD LC LG LS
  func_unset
  # CORRECAO: sem o argumento, o apply_event monta "/${1}/" com $1
  # vazio e pede "//" — um request invalido que ainda gravava "//"
  # como atividade da conta no painel.
  apply_event king
  printf "King ok\n"
  sleep 10s
  [ -t 1 ] && clear
}

king_start() {
  case `date +%H:%M` in
  (12:2[5-9]|16:2[5-9]|22:2[5-9])
    (
      run_curl_exec "$URL/train" | grep -o -E '\(([0-9]+)\)' | head -n1 | sed 's/[()]//g' > "$TMP/FULL"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17
    # Inscrita, a conta ja esta comprometida com o evento: a batalha fica
    # anotada para o worker relancado voltar a ela (batalha_retomar).
    batalha_marcar king
    (
      run_curl_exec "$URL/king/enterGame" > "$TMP/SRC"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17
    printf "King of the Immortals will be started...\n"
    until (case `date +%M` in (2[5-9]) exit 1;; esac); do
      sleep 3
    done
    (
      run_curl_exec "$URL/king/enterGame" > "$TMP/SRC"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17
    printf "\nKing\n%s\n" "$URL"
    link_acao "$TMP/SRC" king > "$TMP/ACCESS" 2>/dev/null
    printf " Entering...\n%s\n" "`cat "$TMP/ACCESS"`"
    printf " Waiting...\n"
    cat "$TMP/SRC" | grep -o 'king/kingatk/' > "$TMP/EXIT" 2>/dev/null
    # 60s (eram 30), e a espera tambem termina com QUALQUER acao do Rei na
    # pagina, nao so com o golpe forte.
    BREAK=$(($(date +%s) + 60))
    until [ -s "$TMP/EXIT" ] || [ "`estado_luta "$TMP/SRC" king`" = luta ] || \
          [ "$(date +%s)" -gt "$BREAK" ]; do
      printf " ...\n%s\n" "`cat "$TMP/ACCESS"`"
      (
        run_curl_exec "${URL}$(cat "$TMP/ACCESS")" > "$TMP/SRC"
      ) </dev/null > /dev/null 2>&1 &
      time_exit 17
      cat "$TMP/SRC" | sed 's/href=/\n/g' | grep '/king/' | head -n 1 | awk -F"[']" '{ print $2 }' > "$TMP/ACCESS" 2>/dev/null
      cat "$TMP/SRC" | grep -o 'king/kingatk/' > "$TMP/EXIT" 2>/dev/null
      sleep 2
    done
    king_fight
    ;;
  esac
}
