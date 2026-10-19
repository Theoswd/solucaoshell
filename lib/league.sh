# shellcheck disable=SC2034

# PAGINA DA LIGA EM $TMP/LEAGUE_SRC, LIDA SO QUANDO PRECISA.
#
# A leitura guardada vale enquanto nada sair depois dela: o nonce (?r=) dos
# links morre com a requisicao seguinte (ver cq_ultima_foi_ela). Toda leitura
# da Liga passa por aqui, entao o arquivo e sempre a mais nova.
liga_ler() {
    _ll=""; { read -r _ll < "$TMP/.ult_req"; } 2>/dev/null
    if [ "$_ll" = "/league/" ] && [ -s "$TMP/LEAGUE_SRC" ]; then unset _ll; return 0; fi
    unset _ll
    fetch_page "/league/" "$TMP/LEAGUE_SRC"
}

fetch_available_fights() {
    liga_ler

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
#  RECOMPENSA DA LIGA — ESTADO SEPARADO DAS LUTAS ($TMP/league_reward_pending)
#
#  Concluir as cinco lutas NAO significa recompensa coletada: ela as vezes
#  demora a aparecer. O marcador em disco sobrevive a reinicios e so sai
#  quando o SERVIDOR confirma (o botao takeReward some apos o clique). A Liga
#  nao trava esperando: a proxima passagem tenta de novo.
# ---------------------------------------------------------------------------
league_reward_marcar()   { : > "$TMP/league_reward_pending" 2>/dev/null; }
league_reward_limpar()   { rm -f "$TMP/league_reward_pending" 2>/dev/null; }
league_reward_pendente() { [ -f "$TMP/league_reward_pending" ]; }

# ---------------------------------------------------------------------------
#  A LIGA DO DIA — UMA VISITA, AS 00:30
#
#  Cinco lutas por dia, restauradas a meia-noite junto com a recompensa.
#  Zeradas, a pagina mostra quanto falta:
#
#     Lutas disponiveis: <b>0</b><br/>Tempo restante para restauro: 05:29:02
#
#  Com o contador em zero o bot anota a reabertura (restauro + 30 min, as
#  00:30) e so volta a Liga depois dela. O relogio vem da pagina, entao vale
#  mesmo com o fuso do aparelho diferente. Bot desligado as 00:30: a visita e
#  feita na entrada (liga_do_dia, no sls.sh).
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

# Anota a volta para as proximas 00:30 do relogio do aparelho (ate 24h).
league_volta_0030() {
    _lv=`date +%H:%M:%S`
    _lv_h=${_lv%%:*}; _lv=${_lv#*:}; _lv_m=${_lv%%:*}; _lv_s=${_lv#*:}
    _lv=$(( ${_lv_h#0} * 3600 + ${_lv_m#0} * 60 + ${_lv_s#0} ))
    if [ "$_lv" -lt 1800 ]; then _lv=$(( 1800 - _lv )); else _lv=$(( 86400 - _lv + 1800 )); fi
    echo $(( `date +%s` + _lv )) > "$TMP/league_restauro" 2>/dev/null
    unset _lv _lv_h _lv_m _lv_s
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
    league_play 2>/dev/null
    ativ_marcar liga
}

# AS ATIVIDADES CABEM NO INTERVALO ENTRE OS EVENTOS (regra do dono).
#
# Inicio (HHMM) das janelas de inscricao do cronograma, as mesmas dos ramos do
# sls_play (run.sh; um teste confere). Cada uma dura 5 min. Fora delas e sem
# uma comecando nos proximos EVENTO_MARGEM minutos, a rotina pode rodar: a
# atividade mais longa (caverna, ate 4 min) nao invade a inscricao. Durante o
# evento em si quem segura a conta e o evento_espera.
EVENTO_JANELAS="0925 0955 1010 1025 1055 1125 1225 1355 1455 1555 1610 1625 1755 1855 2055 2125 2155 2225"
EVENTO_MARGEM=5

# 0 = pode rodar atividade agora; 1 = janela de evento ou perto dela.
liga_fora_da_inscricao() {
    # Hora do relogio da volta (crono.sh); carregado sozinho, o date.
    if type minuto_atual > /dev/null 2>&1 && type hora_atual > /dev/null 2>&1; then
        hora_atual; minuto_atual; _lfi_m=$(( _HOR * 60 + _MIN ))
    else
        _lfi_m=`date +%H:%M`; _lfi_h=${_lfi_m%:*}; _lfi_m=${_lfi_m#*:}
        _lfi_m=$(( ${_lfi_h#0} * 60 + ${_lfi_m#0} ))
    fi
    for _lfi_j in $EVENTO_JANELAS; do
        _lfi_h=${_lfi_j%??}; _lfi_h=${_lfi_h#0}; _lfi_w=${_lfi_j#??}; _lfi_w=${_lfi_w#0}
        _lfi_w=$(( _lfi_h * 60 + _lfi_w ))
        if [ "$_lfi_m" -ge $(( _lfi_w - EVENTO_MARGEM )) ] && [ "$_lfi_m" -lt $(( _lfi_w + 5 )) ]; then
            unset _lfi_m _lfi_h _lfi_w _lfi_j
            return 1
        fi
    done
    unset _lfi_m _lfi_h _lfi_w _lfi_j
    return 0
}

# Tenta coletar a recompensa e confirma pela resposta real do servidor.
#   retorno 0 = coleta confirmada (o botao sumiu)
#   retorno 1 = recompensa ainda indisponivel ou coleta nao confirmada
league_collect_reward() {
    liga_ler
    cp "$TMP/LEAGUE_SRC" "$TMP/SRC" 2>/dev/null
    _lr_click=`grep -o -E "/league/takeReward/\?r=[0-9]+" "$TMP/SRC" | sed -n 1p`
    if [ -z "$_lr_click" ]; then
        unset _lr_click
        return 1
    fi

    printf "[LIGA] Recompensa encontrada. Tentando coletar.\n"
    fetch_page "$_lr_click"

    # CONFIRMACAO REAL: recarrega a pagina; se o botao sumiu, o servidor
    # aceitou. Releitura sem resposta nao confirma nada.
    if ! fetch_page "/league/" "$TMP/LEAGUE_SRC" || [ ! -s "$TMP/LEAGUE_SRC" ]; then
        printf "[LIGA] Sem resposta ao conferir a coleta. Fica pendente.\n"
        unset _lr_click
        return 1
    fi
    if grep -q -o -E "/league/takeReward/\?r=[0-9]+" "$TMP/LEAGUE_SRC"; then
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

    # LUTAS PRIMEIRO: sem luta no dia, as missoes 1 e 2 do cla ocupariam vaga
    # a toa. O cq_antes recolhe as concluidas e toma as duas.
    fetch_available_fights
    if [ "${AVAILABLE_FIGHTS:-0}" -gt 0 ]; then
        cq_antes liga 2>/dev/null
        PLAYER_STRENGTH=`player_stats`
    fi

    # Sem lutas na entrada = ciclo de cinco ja concluido: marca a recompensa
    # como pendente (o laco de lutas nem roda com fights=0).
    if [ "${AVAILABLE_FIGHTS:-0}" -eq 0 ]; then
        league_reward_marcar
    fi

    # RECOMPENSA PENDENTE PRIMEIRO, inclusive a que apareceu atrasada.
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

    # O LACO DAS LUTAS TEM TETO (40 voltas, 5 min): uma luta que o servidor
    # nao registra nao desce o contador e prenderia a conta na Liga.
    _lg_fim=$(( `date +%s` + 300 ))
    _lg_travada=0
    _lg_voltas=0
    _lg_falhas=0
    # Forca nao lida (/train sem resposta): comparado com vazio, todo
    # adversario pareceria mais forte e a Liga iria direto para a pocao.
    case "$PLAYER_STRENGTH" in
        ''|*[!0-9]*)
            PLAYER_STRENGTH=""
            [ "${AVAILABLE_FIGHTS:-0}" -gt 0 ] && \
                printf "[LIGA] Forca do personagem nao lida - lutas na proxima passagem.\n" ;;
    esac
    while [ -n "$PLAYER_STRENGTH" ] && [ "$AVAILABLE_FIGHTS" -gt 0 ] && [ "$_lg_voltas" -lt 40 ] && \
          [ "`date +%s`" -lt "$_lg_fim" ]; do
        _lg_voltas=$((_lg_voltas + 1))
        case "$action" in
            check_fights)
                liga_ler
                cp "$TMP/LEAGUE_SRC" "$TMP/SRC" 2>/dev/null
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
                # Forca do adversario ilegivel: o "-gt" com vazio da falso e
                # a Liga pularia todos ate a pocao.
                case "$E_STRENGTH" in
                    ''|*[!0-9]*)
                        printf "[LIGA] Forca do adversario nao lida - volta na proxima passagem.\n"
                        action="exit_loops"; continue ;;
                esac
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
                    # LUTA QUE NAO CONTOU: a primeira passa para o proximo
                    # adversario; a segunda seguida encerra a Liga nesta
                    # passagem. A resposta do jogo fica guardada.
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
                    # Pular nao muda o contador: a pagina lida continua valendo.
                    if [ -z "$last_click" ] && [ "$AVAILABLE_FIGHTS" -gt 1 ]; then
                        printf "Reached the last enemy. Attacking and using a potion...\n"
                        j=$((j - 2))
                        click=`grep -o -E "/league/fight/[0-9]{1,3}/\?r=[0-9]{1,8}" "$TMP/SRC" | sed -n "${j}p"`
                        fetch_page "$click"
                        fights_done=$((fights_done + 1))
                        fetch_available_fights
                        sleep 1s
                        # Primeiro da pagina RELIDA (LEAGUE_SRC), onde o nonce
                        # vale; sem a pocao nela, da resposta da luta, como
                        # sempre foi (a pagina real nao foi conferida).
                        _lg_pg="$TMP/LEAGUE_SRC"
                        potion_click=`grep -o -E "/league/potion/\?r=[0-9]+" "$_lg_pg" | sed -n 1p`
                        if [ -z "$potion_click" ]; then
                            _lg_pg="$TMP/SRC"
                            potion_click=`grep -o -E "/league/potion/\?r=[0-9]+" "$_lg_pg" | sed -n 1p`
                        fi
                        if botao_pago "$_lg_pg" "$potion_click"; then
                            printf "[LIGA] A pocao cobra ouro - nao usa.\n"
                            potion_click=""
                        fi
                        # Sem pocao o POTION nao pode nascer: a volta seguinte
                        # atacaria sem olhar a forca e perderia uma luta.
                        if [ -z "$potion_click" ]; then
                            printf "[LIGA] Sem pocao e os adversarios sao mais fortes - volta as 00:30.\n"
                            _lg_travada=1
                            action="exit_loops"
                        elif fetch_page "$potion_click"; then
                            printf "Used a potion\n"
                            echo "potion used" > "$TMP/POTION"
                            E_STRENGTH=50
                            enemy_index=1
                            j=1
                            action="check_fights"
                        else
                            printf "[LIGA] A pocao nao respondeu (rede) - volta na proxima passagem.\n"
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
                    # Cinco lutas concluidas: apenas MARCA a recompensa como
                    # pendente; nunca deduzir "coletada" das lutas.
                    printf "[LIGA] Lutas concluidas. Recompensa pendente=sim.\n"
                    league_reward_marcar
                fi
                ;;
        esac
    done
    [ "$_lg_voltas" -ge 40 ] || [ "`date +%s`" -ge "$_lg_fim" ] && \
        printf "[LIGA] Teto do laco atingido (%s voltas) - segue para as demais atividades.\n" "$_lg_voltas"
    unset _lg_fim _lg_voltas _lg_falhas _lg_antes _lg_pg
    # Regra do dono: uma visita por dia. Sobrou luta que nao da para fazer
    # (mais fortes e sem pocao): sem o relogio da pagina (so vem com o
    # contador em zero), a volta e as 00:30 do relogio do aparelho.
    [ "$_lg_travada" = 1 ] && league_volta_0030
    unset _lg_travada

    # COLETA DA RECOMPENSA, fora do laco de lutas: so limpa o estado com a
    # confirmacao do servidor. Liberar cinco lutas novas NAO apaga o estado.
    if league_reward_pendente; then
        if league_collect_reward; then
            league_reward_limpar
        else
            printf "[LIGA] Recompensa ainda indisponivel. A instancia continuara outras atividades.\n"
        fi
    fi

    # Contador em zero (ultima leitura no LEAGUE_SRC): reabre as 00:30.
    if [ "${AVAILABLE_FIGHTS:-0}" -eq 0 ] && league_restauro_marcar "$TMP/LEAGUE_SRC"; then
        league_restauro_pendente && \
            printf "[LIGA] Lutas zeradas - a Liga reabre as 00:30 (em %s min).\n" "$LEAGUE_RESTAURO_MIN"
        unset LEAGUE_RESTAURO_MIN
    fi

    # Missoes da Liga so tem o que encerrar se houve luta nesta passagem.
    if [ "${fights_done:-0}" -gt 0 ]; then
        checkQuest 2 end
        checkQuest 1 end
    fi
    unset click ENEMY_NUMBER PLAYER_STRENGTH E_STRENGTH AVAILABLE_FIGHTS fights_done enemy_index j

    printf "League Routine Completed ok\n"
}
