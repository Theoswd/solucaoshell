# shellcheck disable=SC2034
fetch_available_fights() {
    fetch_page "/league/" "$TMP/LEAGUE_SRC"

    if [ -f "$TMP/LEAGUE_SRC" ]; then
        printf "Looking for available fights...\n"
        AVAILABLE_FIGHTS=`grep -o -E '<b>[0-5]</b>' "$TMP/LEAGUE_SRC" | head -n 1 | sed -n 's/.*<b>\([0-5]\)<\/b>.*/\1/p'`

        case "$AVAILABLE_FIGHTS" in
            [0-5])
                printf "Available fights: %s\n" "$AVAILABLE_FIGHTS"
                ;;
            *)
                printf "Error: No available fights or not found.\n" >> "$TMP/ERROR_DEBUG"
                AVAILABLE_FIGHTS=0
                ;;
        esac
    else
        printf "The LEAGUE_SRC file was not found.\n" >> "$TMP/ERROR_DEBUG"
        AVAILABLE_FIGHTS=0
    fi

    AVAILABLE_FIGHTS=${AVAILABLE_FIGHTS:-0}
    [ "$AVAILABLE_FIGHTS" -gt 0 ]
}

get_enemy_stat() {
    index=$1
    stat_num=$2
    attempts=0
    max_attempts=10

    while [ "$attempts" -lt "$max_attempts" ]; do
        stat=`grep -o -E ': [0-9]+' "$TMP/SRC" | sed -n "$((index + stat_num))s/: //p" | tr -d '()' | tr -d ' '`

        if [ -n "$stat" ] && [ "$stat" -gt 49 ]; then
            echo "$stat"
            return 0
        fi
        stat_num=$((stat_num + 1))
        attempts=$((attempts + 1))
    done

    printf "Error: Stat not found after %s attempts.\n" "$max_attempts" >> "$TMP/ERROR_DEBUG"
    return 1
}

# ---------------------------------------------------------------------------
#  RECOMPENSA DA LIGA DOS FAVORITOS — ESTADO SEPARADO DAS LUTAS
#
#  Concluir as cinco lutas NAO significa recompensa coletada. A recompensa
#  as vezes demora a aparecer, e liberar cinco lutas novas nao pode apagar o
#  estado pendente. Por isso "pendente" e um marcador em disco, por conta,
#  que sobrevive a reinicios do worker:
#
#     $TMP/league_reward_pending
#
#  A coleta so e dada como concluida quando o SERVIDOR confirma: o botao
#  takeReward some da pagina apos o clique. Enquanto nao confirma, o estado
#  fica pendente e a proxima passagem tenta de novo (recompensa atrasada).
#  A Liga nao fica travada esperando — o worker segue as outras atividades e
#  volta no proximo intervalo (portao de 30 min), que serve de nova tentativa
#  sem loop infinito.
# ---------------------------------------------------------------------------
league_reward_marcar()   { : > "$TMP/league_reward_pending" 2>/dev/null; }
league_reward_limpar()   { rm -f "$TMP/league_reward_pending" 2>/dev/null; }
league_reward_pendente() { [ -f "$TMP/league_reward_pending" ]; }

# ---------------------------------------------------------------------------
#  A LIGA DO DIA — UMA VISITA, AS 00:30
#
#  O jogo da cinco lutas por dia, restauradas a meia-noite junto com a
#  recompensa do dia anterior. Zeradas, a pagina mostra quanto falta:
#
#     Lutas disponiveis: <b>0</b><br/>Tempo restante para restauro: 05:29:02
#
#  (lido as 18:30:58 = meia-noite). Medido nos logs das 17 contas: a
#  recompensa foi coletada 193 vezes com as cinco lutas ja restauradas e so 2
#  com o contador em zero, contra 12.917 leituras "ainda indisponivel" com o
#  contador zerado. A Liga era aberta a cada 30 minutos o dia inteiro a toa.
#
#  Agora ha uma visita por dia: coleta a recompensa e faz as cinco lutas.
#  Com o contador em zero o bot anota a reabertura — restauro + 30 min, as
#  00:30, horario sem evento em que a varredura das 00:30 ja roda — e so
#  volta a Liga depois dela. O relogio vem da pagina, entao vale mesmo com o
#  fuso do aparelho diferente do servidor. Bot desligado as 00:30: a visita
#  e feita na entrada, logo depois do login (liga_do_dia, no sls.sh).
#
#     $TMP/league_restauro   (epoch da reabertura: restauro + 30 min)
# ---------------------------------------------------------------------------
LIGA_ABRE_APOS=1800

# Segundos ate o restauro, lidos da pagina da Liga ($1). So vale com o
# contador em zero: sem "<b>0</b>" seguido do relogio, nao devolve nada.
league_restauro_segundos() {
    grep -o -E '<b>0</b><br/>[^<]*[0-9]{1,2}:[0-9]{2}:[0-9]{2}' "$1" 2>/dev/null | head -n 1 | \
        grep -o -E '[0-9]{1,2}:[0-9]{2}:[0-9]{2}$' | \
        awk -F: '{ print $1 * 3600 + $2 * 60 + $3 }'
}

# Anota a reabertura (restauro + 30 min). Sem relogio legivel na pagina, nao
# anota: a Liga segue no intervalo de sempre.
league_restauro_marcar() {
    _rs=`league_restauro_segundos "$1"`
    case "$_rs" in ''|*[!0-9]*) unset _rs; return 1 ;; esac
    if [ "$_rs" -gt 86400 ]; then unset _rs; return 1; fi
    echo $(( `date +%s` + _rs + LIGA_ABRE_APOS )) > "$TMP/league_restauro" 2>/dev/null
    unset _rs
}

# 0 = a Liga ainda esta fechada. Vencido ou ilegivel, o marcador sai.
league_restauro_pendente() {
    _re=`cat "$TMP/league_restauro" 2>/dev/null`
    case "$_re" in ''|*[!0-9]*) rm -f "$TMP/league_restauro"; unset _re; return 1 ;; esac
    # Mais de 2 dias adiante e relogio do aparelho errado (ver relogio_liberado).
    _re=$(( _re - `date +%s` ))
    if [ "$_re" -gt 0 ] && [ "$_re" -le 172800 ]; then
        LEAGUE_RESTAURO_MIN=$(( (_re + 59) / 60 ))
        unset _re
        return 0
    fi
    rm -f "$TMP/league_restauro"
    unset _re
    return 1
}

# A VISITA DO DIA: missao do cla de Liga, recompensa e as cinco lutas. Chamada
# pela varredura (00:30 em diante) e na entrada do bot. Fechada, nao faz nada:
# nem toma a missao do cla (lutas que nao vao acontecer) nem marca o intervalo.
liga_do_dia() {
    league_restauro_pendente && return 1
    cq_antes liga 2>/dev/null
    league_play 2>/dev/null
    ativ_marcar liga
}

# Na entrada do bot a Liga espera se for hora de inscricao de evento (:10-:14
# Bandeiras, :25-:29 e :55-:59 os demais): o evento vem primeiro e a
# varredura seguinte faz a Liga.
liga_fora_da_inscricao() {
    case `date +%M` in
        1[0-4]|2[5-9]|5[5-9]) return 1 ;;
    esac
    return 0
}

# Tenta coletar a recompensa e confirma pela resposta real do servidor.
#   retorno 0 = coleta confirmada (o botao sumiu)
#   retorno 1 = recompensa ainda indisponivel ou coleta nao confirmada
league_collect_reward() {
    fetch_page "/league/"
    _lr_click=`grep -o -E "/league/takeReward/\?r=[0-9]+" "$TMP/SRC" | sed -n 1p`
    if [ -z "$_lr_click" ]; then
        unset _lr_click
        return 1
    fi

    printf "[LIGA] Recompensa encontrada. Tentando coletar.\n"
    fetch_page "$_lr_click"

    # CONFIRMACAO REAL: recarrega a pagina; se o botao sumiu, o servidor
    # aceitou a coleta. So entao a recompensa e dada como recebida.
    fetch_page "/league/"
    if grep -q -o -E "/league/takeReward/\?r=[0-9]+" "$TMP/SRC"; then
        printf "[LIGA] Falha ao coletar recompensa. Nova tentativa sera programada.\n"
        unset _lr_click
        return 1
    fi
    printf "[LIGA] Coleta confirmada pelo servidor.\n"
    unset _lr_click
    return 0
}

league_play() {
    # Liga do dia ja feita: nada a fazer ate as 00:30.
    if league_restauro_pendente; then
        printf "[LIGA] Liga do dia ja feita - reabre as 00:30 (faltam %s min).\n" "$LEAGUE_RESTAURO_MIN"
        unset LEAGUE_RESTAURO_MIN
        return 0
    fi
    printf "League\n"
    load_config
    checkQuest 2 apply
    checkQuest 1 apply

    PLAYER_STRENGTH=`player_stats`
    fetch_available_fights

    # Sem lutas na entrada = ciclo de cinco ja concluido numa passagem
    # anterior: ha (ou havera) recompensa. Marca como pendente para a coleta
    # nao depender do laco de lutas, que nem chega a rodar quando fights=0.
    if [ "${AVAILABLE_FIGHTS:-0}" -eq 0 ]; then
        league_reward_marcar
    fi

    # RECOMPENSA PENDENTE PRIMEIRO: coleta agora (inclui a recompensa que
    # apareceu atrasada apos uma passagem anterior) antes de qualquer luta.
    if league_reward_pendente; then
        printf "[LIGA] Verificando recompensa pendente.\n"
        if league_collect_reward; then
            league_reward_limpar
        else
            printf "[LIGA] Recompensa ainda indisponivel. Estado preservado como pendente.\n"
        fi
    fi

    action="check_fights"
    fights_done=0
    j=1
    enemy_index=1

    # O LACO DAS LUTAS TEM TETO.
    #
    # Ele so terminava com o contador de lutas em zero ou sem botao de luta.
    # Uma luta que o servidor nao registra — resposta de erro, sem energia —
    # nao desce o contador: o bot voltava ao mesmo adversario para sempre,
    # tres requisicoes por volta, e a conta ficava presa na Liga, perdendo
    # o cronograma. Cinco lutas cabem com folga em 40 voltas e 5 minutos.
    _lg_fim=$(( `date +%s` + 300 ))
    _lg_voltas=0
    _lg_falhas=0
    while [ "$AVAILABLE_FIGHTS" -gt 0 ] && [ "$_lg_voltas" -lt 40 ] && \
          [ "`date +%s`" -lt "$_lg_fim" ]; do
        _lg_voltas=$((_lg_voltas + 1))
        case "$action" in
            check_fights)
                fetch_page "/league/"
                click=`grep -o -E "/league/fight/[0-9]{1,3}/\?r=[0-9]{1,8}" "$TMP/SRC" | sed -n "${j}p"`

                if [ -n "$click" ]; then
                    ENEMY_NUMBER=`echo "$click" | grep -o -E '[0-9]+' | head -n 1`
                    INDEX=$(((enemy_index - 1) * 4))
                    E_STRENGTH=`get_enemy_stat "$INDEX" 1`
                    E_HEALTH=`get_enemy_stat "$INDEX" 2`
                    E_AGILITY=`get_enemy_stat "$INDEX" 3`
                    E_PROTECTION=`get_enemy_stat "$INDEX" 4`
                    printf "Enemy Number: %s\n" "$ENEMY_NUMBER"
                    action="fight_or_skip"
                else
                    printf "No fight buttons found for button %s\n" "$j" >> "$TMP/ERROR_DEBUG"
                    action="exit_loops"
                fi
                ;;

            fight_or_skip)
                if [ "$PLAYER_STRENGTH" -gt "$E_STRENGTH" ] || [ -f "$TMP/POTION" ]; then
                    printf "Strength (%s) > enemy (%s). Fighting %s.\n" "$PLAYER_STRENGTH" "$E_STRENGTH" "$ENEMY_NUMBER"
                    _lg_antes=$AVAILABLE_FIGHTS
                    fetch_page "$click"
                    fights_done=$((fights_done + 1))
                    enemy_index=1
                    j=1
                    last_click=`grep -o -E "/league/fight/[0-9]{1,3}/\?r=[0-9]{1,8}" "$TMP/SRC" | sed -n "${j}p"`
                    ENEMY_NUMBER=`echo "$last_click" | grep -o -E '[0-9]+' | head -n 1`
                    fetch_available_fights
                    action="check_fights"
                    # LUTA QUE NAO CONTOU.
                    #
                    # Medido nos logs: uma conta clicou 17 vezes no mesmo adversario
                    # com o contador parado em 3, outra 9 vezes — e
                    # horas depois as mesmas lutas contaram. Insistir no mesmo
                    # adversario so gastava o teto de 5 minutos. Agora a
                    # primeira luta que nao desce o contador passa para o
                    # proximo adversario; a segunda seguida encerra a Liga
                    # nesta passagem (as lutas continuam la ate a meia-noite).
                    # A resposta do jogo fica guardada para ver o motivo.
                    if [ "$AVAILABLE_FIGHTS" -lt "$_lg_antes" ]; then
                        _lg_falhas=0
                    else
                        _lg_falhas=$((_lg_falhas + 1))
                        cp "$TMP/SRC" "$TMP/liga_luta_nao_contou.html" 2>/dev/null
                        printf "[LIGA] A luta nao contou (lutas disponiveis: %s).\n" "$AVAILABLE_FIGHTS"
                        if [ "$_lg_falhas" -ge 2 ]; then
                            printf "[LIGA] Duas lutas seguidas sem contar - volta na proxima passagem (resposta em %s).\n" "$TMP/liga_luta_nao_contou.html"
                            action="exit_loops"
                        else
                            enemy_index=2
                            j=3
                        fi
                    fi
                    if [ -f "$TMP/POTION" ]; then
                        rm "$TMP/POTION"
                    fi
                else
                    printf "Strength (%s) < enemy (%s). Skipping.\n" "$PLAYER_STRENGTH" "$E_STRENGTH"
                    enemy_index=$((enemy_index + 1))
                    j=$((j + 2))
                    last_click=`grep -o -E "/league/fight/[0-9]{1,3}/\?r=[0-9]{1,8}" "$TMP/SRC" | sed -n "${j}p"`
                    ENEMY_NUMBER=`echo "$last_click" | grep -o -E '[0-9]+' | head -n 1`
                    fetch_available_fights
                    if [ -z "$last_click" ] && [ "$AVAILABLE_FIGHTS" -gt 1 ]; then
                        printf "Reached the last enemy. Attacking and using a potion...\n"
                        j=$((j - 2))
                        click=`grep -o -E "/league/fight/[0-9]{1,3}/\?r=[0-9]{1,8}" "$TMP/SRC" | sed -n "${j}p"`
                        fetch_page "$click"
                        fights_done=$((fights_done + 1))
                        fetch_available_fights
                        sleep 1s
                        potion_click=`grep -o -E "/league/potion/\?r=[0-9]+" "$TMP/SRC" | sed -n 1p`
                        # Sem pocao o POTION nao pode nascer: com ele a
                        # volta seguinte ataca o 1o adversario sem olhar a
                        # forca e perde uma luta.
                        if [ -n "$potion_click" ] && fetch_page "$potion_click"; then
                            printf "Used a potion\n"
                            echo "potion used" > "$TMP/POTION"
                            E_STRENGTH=50
                            enemy_index=1
                            j=1
                            action="check_fights"
                        else
                            printf "[LIGA] Sem pocao e os adversarios sao mais fortes - volta na proxima passagem.\n"
                            action="exit_loops"
                        fi
                    else
                        action="check_fights"
                    fi
                fi
                ;;

            exit_loops)
                break
                ;;
        esac

        case "$AVAILABLE_FIGHTS" in
            *[!0-9]*)
                printf "Error: %s is not a valid number.\n" "$AVAILABLE_FIGHTS" >> "$TMP/ERROR_DEBUG"
                AVAILABLE_FIGHTS=0
                ;;
            *)
                if [ "$AVAILABLE_FIGHTS" -eq 0 ]; then
                    # Cinco lutas concluidas: ha recompensa a coletar. Apenas
                    # MARCA como pendente; a coleta (com confirmacao real) e
                    # feita fora do laco. Nunca deduzir "coletada" das lutas.
                    printf "[LIGA] Lutas concluidas. Recompensa pendente=sim.\n"
                    league_reward_marcar
                fi
                ;;
        esac
    done
    [ "$_lg_voltas" -ge 40 ] || [ "`date +%s`" -ge "$_lg_fim" ] && \
        printf "[LIGA] Teto do laco atingido (%s voltas) - segue para as demais atividades.\n" "$_lg_voltas"
    unset _lg_fim _lg_voltas _lg_falhas _lg_antes

    # COLETA DA RECOMPENSA — fora do laco de lutas.
    #
    # Chega aqui quem terminou as cinco lutas nesta passagem. Se ha recompensa
    # pendente, tenta coletar e confirma pelo servidor; so limpa o estado com a
    # confirmacao. Se a recompensa ainda nao apareceu, o marcador fica para a
    # proxima passagem — a Liga nao trava esperando e o worker segue as demais
    # atividades. Liberar cinco lutas novas NAO apaga este estado.
    if league_reward_pendente; then
        if league_collect_reward; then
            league_reward_limpar
        else
            printf "[LIGA] Recompensa ainda indisponivel. A instancia continuara outras atividades.\n"
        fi
    fi

    # Contador em zero: a Liga do dia esta feita e so reabre as 00:30 (ver acima). A
    # ultima leitura do contador esta no LEAGUE_SRC.
    if [ "${AVAILABLE_FIGHTS:-0}" -eq 0 ] && league_restauro_marcar "$TMP/LEAGUE_SRC"; then
        league_restauro_pendente && \
            printf "[LIGA] Lutas zeradas - a Liga reabre as 00:30 (em %s min).\n" "$LEAGUE_RESTAURO_MIN"
        unset LEAGUE_RESTAURO_MIN
    fi

    unset click ENEMY_NUMBER PLAYER_STRENGTH E_STRENGTH AVAILABLE_FIGHTS fights_done enemy_index j

    checkQuest 2 end
    checkQuest 1 end

    printf "League Routine Completed ok\n"
}
