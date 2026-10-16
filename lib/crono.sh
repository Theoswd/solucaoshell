# shellcheck disable=SC2154
# shellcheck disable=SC2317
# ============================================================
#  RELOGIO DA VOLTA: UM "date" POR VOLTA DO LACO
#
#  relogio_sync (inicio de cada volta, no sls_play) pergunta ao date uma vez
#  e anota o /proc/uptime daquele instante. Dai em diante a hora e o date da
#  volta mais o que o uptime andou, lido com "read", sem processo (erro de
#  no maximo 1s; os portoes contam minutos).
#  Sem relogio_sync (fora do laco, testes) ou sem /proc/uptime, cada funcao
#  chama o date. As lutas nao usam isto: golpe e esquiva seguem com o date.
# ============================================================
relogio_sync() {
    set -- `date '+%s %H %M %S %d'`
    _rl_ep="$1"; _HH="$2"; _MM="$3"; _DD="$5"
    _rl_tz=$(( ${2#0} * 3600 + ${3#0} * 60 + ${4#0} - $1 % 86400 ))
    _rl_up=""
    { read -r _rl_up _rl_x < /proc/uptime; } 2>/dev/null
    _rl_up=${_rl_up%%.*}
    case "$_rl_up" in ''|*[!0-9]*) _rl_up="" ;; esac
    unset _rl_x
}

# Epoch de agora em _AGORA.
agora_s() {
    _rl_u=""
    [ -n "$_rl_up" ] && { read -r _rl_u _rl_x < /proc/uptime; } 2>/dev/null
    _rl_u=${_rl_u%%.*}
    case "$_rl_u" in
        ''|*[!0-9]*) _AGORA=`date +%s` ;;
        *)           _AGORA=$(( _rl_ep + _rl_u - _rl_up )) ;;
    esac
    unset _rl_u _rl_x
}

# Minuto local de agora em _MIN, sem zero a esquerda.
minuto_atual() {
    if [ -n "$_rl_up" ]; then
        agora_s
        _MIN=$(( (_AGORA + _rl_tz + 86400) % 86400 / 60 % 60 ))
    else
        _MIN=`date +%M`; _MIN=${_MIN#0}
    fi
}

# Hora local de agora em _HOR, sem zero a esquerda.
hora_atual() {
    if [ -n "$_rl_up" ]; then
        agora_s
        _HOR=$(( (_AGORA + _rl_tz + 86400) % 86400 / 3600 ))
    else
        _HOR=`date +%H`; _HOR=${_HOR#0}
    fi
}

# Dia do mes da volta em _DIA.
dia_atual() {
    if [ -n "$_rl_up" ] && [ -n "$_DD" ]; then _DIA="$_DD"; else _DIA=`date +%d`; fi
}

func_crono() { # [-q]: so atualiza HOUR/MIN, sem escrever no log
    hora_atual; minuto_atual
    HOUR="$_HOR"; MIN="$_MIN"
    [ -z "$HOUR" ] && HOUR=0
    [ -z "$MIN" ] && MIN=0
    [ "$1" = -q ] && return 0
    if [ -n "$_rl_up" ]; then
        printf "%s %02d:%02d\n" "$URL" "$HOUR" "$MIN"
    else
        printf "%s %s\n" "$URL" "`date +%H:%M`"
    fi
}

# ============================================================
#  PAUSA ENTRE CICLOS E "AGORA" (varredura sob demanda)
#
#  O worker sobe com stdin em /dev/null (nohup+setsid): nao da para "dormir"
#  com read -t (voltaria na hora, busy-loop) nem esperar ENTER. Dorme de
#  verdade, em fatias, e atende ao arquivo-sinal por conta:
#
#     touch ~/.sls/BR_<usuario>/RUNNOW      ($TMP/RUNNOW)
#
#  O sinal e SEMPRE por conta: um global so seria apagado por um worker e os
#  demais o achariam para sempre. Cada worker apaga o seu.
# ============================================================

# Ha pedido de varredura imediata para esta conta?
runnow_pedido() {
    [ -f "$TMP/RUNNOW" ]
}

# Consome o pedido e apaga os marcadores das atividades, para que tudo que
# estiver disponivel no jogo rode na volta seguinte. Ficam de fora os portoes
# que espelham regra do jogo: masmorra, caverna e campanha (relogios do jogo)
# e a estatua (bonus de 48h).
runnow_consumir() {
    rm -f "$TMP/RUNNOW" 2>/dev/null
    rm -f "$TMP/last_arena"  "$TMP/last_carreira" "$TMP/last_campanha" \
          "$TMP/last_caverna" "$TMP/last_sabio"   "$TMP/last_liga" \
          "$TMP/last_troca"   "$TMP/last_clanquest" "$TMP/last_evento" \
          "$TMP/last_cq"      "$TMP/last_stats"    "$TMP/last_agenda" \
          "$TMP/last_elixir" 2>/dev/null
    printf "Varredura sob demanda: portoes liberados\n"
}

# Dorme $1 segundos em fatias de ate 15s, atendendo ao RUNNOW no meio.
# Um sleep por vez (limite de ~32 processos no Android); fatias de 15s para
# nao acordar a CPU a toa. A ultima fatia dorme so o que falta.
espera_interrompivel() {
    _ei_total="$1"
    case "$_ei_total" in ''|*[!0-9]*) _ei_total=60 ;; esac
    _ei_gasto=0
    while [ "$_ei_gasto" -lt "$_ei_total" ]; do
        if runnow_pedido; then
            runnow_consumir
            unset _ei_total _ei_gasto _ei_f
            return 0
        fi
        _ei_f=$(( _ei_total - _ei_gasto ))
        [ "$_ei_f" -gt 15 ] && _ei_f=15
        sleep "$_ei_f"
        _ei_gasto=$((_ei_gasto + _ei_f))
    done
    unset _ei_total _ei_gasto _ei_f
    return 0
}

func_cat() {
    func_crono
    [ -f "$TMP/msg_file" ] && cat "$TMP/msg_file"

    _i="${i:-60}"
    case "$_i" in ''|*[!0-9]*) _i=60 ;; esac

    # GET real em "/": a sessao no jogo descansa de fato na home (senao os
    # outros jogadores viam a conta em Perfil/Cla).
    descansar

    printf "Sem batalhas agora, aguardando %ss\n" "$_i"
    espera_interrompivel "$_i"
    return 0
}

# Sem "reset": o stty sane no TTY herdado do play.sh corrompia o monitor.
# O "clear" so com terminal.
func_sleep() {
    [ -t 1 ] && clear

    dia_atual
    if [ "$_DIA" -eq 01 ] 2>/dev/null; then
        if [ "${HOUR:-99}" -lt 9 ] 2>/dev/null; then
            # Missao 11 do dia 1: o coliseum_start pede /quest/ mesmo sem ela;
            # 15 min bastam.
            if ativ_liberada missao11 15; then
                coliseum_start
                ativ_marcar missao11
            fi
            i=60
            func_cat
            return 0
        fi
    fi

    # ESPERA CURTA (15s) NA APROXIMACAO DAS JANELAS DE EVENTO, senao uma
    # espera de 60s iniciada perto do fim da janela acorda com ela fechada.
    # Tem de cobrir TODA a janela de entrada:
    #   Bandeiras    :10-:14   (com :09 de folga)
    #   Rei/Especiais/Coliseu do Cla  :25-:29
    #   Torneio/Altares/Vale/Coliseu do Cla  :55-:59
    # O minuto e lido aqui, nao do $MIN: no ramo ocioso do run.sh o func_sleep
    # vem ANTES do func_crono, e o $MIN esta defasado (vazio na primeira volta).
    minuto_atual
    _fs_min="$_MIN"
    case "$_fs_min" in ''|*[!0-9]*) _fs_min=0 ;; esac
    case "$_fs_min" in
        9|1[0-4]|2[4-9]|30|5[4-9]) i=15 ;;
        *)                         i=60 ;;
    esac
    unset _fs_min
    func_cat
}

# Intervalo do checklist de missoes do cla.
cq_liberado()    { ativ_liberada cq    "${FUNC_cq_min:-15}"; }
cq_marcar() { ativ_marcar cq; }

# Numeros do painel (HP, energia, nivel, ouro, prata): /user a cada
# FUNC_stats_min minutos por conta.
stats_liberado() { ativ_liberada stats "${FUNC_stats_min:-5}"; }

atualiza_stats() {
    # O run_curl grava cada pagina em $TMP/pagina: a aba atual e restaurada
    # em TODOS os caminhos de saida.
    _aba_ant=`cat "${TMP}/pagina" 2>/dev/null`

    # Energia e HP maximo so aparecem em /train (e regeneram com o tempo).
    fetch_train_stats 2>/dev/null

    # A HOME DO DESCANSO NO LUGAR DO /user, SO DEPOIS DE CONFERIDA.
    #
    # A Home lida ha menos de 2 min, viva e com os cinco icones do cabecalho,
    # serve no lugar do /user, mas so depois de o worker ver uma vez que ela da
    # os mesmos numeros (nivel, ouro e prata iguais, HP e energia presentes).
    # Sem bater em 3 conferencias, ou sem os icones, segue pelo /user.
    # HOME_STATS: vazio = conferindo, 1 = Home serve, 0 = so /user. O nome da
    # conta (ACC) continua vindo do /user do login.
    _st_home=""
    if [ "${HOME_STATS:-}" != 0 ]; then
        _st_ok=0; { read -r _st_ok < "$TMP/.home_ok"; } 2>/dev/null
        case "$_st_ok" in ''|*[!0-9]*) _st_ok=0 ;; esac
        agora_s
        _st_ok=$(( _AGORA - _st_ok ))
        if [ "$_st_ok" -ge 0 ] && [ "$_st_ok" -lt 120 ]; then
            _st_home=`cat "$TMP/REST" 2>/dev/null`
            for _st_m in "health.png' alt='hp'/>" "mana.png' alt='mp'/>" "level.png' alt=" \
                         "gold.png' alt='g'/>" "silver.png' alt='s'/>"; do
                case "$_st_home" in *"$_st_m"*) ;; *) _st_home=""; break ;; esac
            done
        fi
        unset _st_ok _st_m
    fi
    if [ "$HOME_STATS" = 1 ] && [ -n "$_st_home" ]; then
        parse_status "$_st_home"
        messages_info
        ativ_marcar stats
        printf %s "$_aba_ant" > "${TMP}/pagina" 2>/dev/null
        unset _st_home _aba_ant
        return 0
    fi

    _pg=`run_curl "${URL}/user" 2>/dev/null`

    # SESSAO CAIDA NO OCIO: RECONECTA EM VEZ DE DESISTIR.
    #
    # Com a sessao morta o servidor ve um visitante anonimo e a conta NAO
    # aparece online, embora o painel a mostre rodando. So reconecta com a
    # pagina do jogo dizendo que a conta saiu; resposta vazia ou que nao e do
    # jogo e servidor mudo (ver sessao_estado).
    if ! is_logged_in "$_pg"; then
        if [ "`printf '%s' "$_pg" | sessao_estado -`" = deslogado ]; then
            printf "Sessao caiu no ocio - reconectando\n"
            if type login_logoff > /dev/null 2>&1 && login_logoff; then
                _pg=`run_curl "${URL}/user" 2>/dev/null`
            fi
        else
            servidor_mudo_marcar
        fi
    fi

    if [ -z "$_pg" ] || ! is_logged_in "$_pg"; then
        printf %s "$_aba_ant" > "${TMP}/pagina" 2>/dev/null
        unset _pg _aba_ant _st_home
        return 1
    fi
    _a=`extract_username "$_pg"`
    [ -n "$_a" ] && ACC="$_a"
    # Pagina logada: a sessao respondeu (libera a varredura, ver servidor_mudo).
    sessao_marcar
    # Conferencia da Home (acima): os numeros dela antes, os do /user depois.
    # O nivel de antes volta para o parse_status: e por ele que a subida de
    # nivel apaga o last_train (HP maximo e teto de energia novos).
    if [ -z "$HOME_STATS" ] && [ -n "$_st_home" ]; then
        _st_lvl="$ACC_LVL"
        status_ler "$_st_home"
        _st_h="$ACC_HP|$ACC_MP|$ACC_LVL|$ACC_GOLD|$ACC_SILVER"
        ACC_LVL="$_st_lvl"; unset _st_lvl
    fi
    parse_status "$_pg"
    if [ -n "$_st_h" ]; then
        case "$_st_h" in
            ?*'|'?*"|$ACC_LVL|$ACC_GOLD|$ACC_SILVER")
                if [ -n "$ACC_LVL" ] && [ -n "$ACC_GOLD" ] && [ -n "$ACC_SILVER" ]; then
                    HOME_STATS=1
                    printf "Painel: a Home traz os mesmos numeros do /user - o /user deixa de ser pedido\n"
                fi ;;
        esac
        if [ -z "$HOME_STATS" ]; then
            _st_n=$(( ${_st_n:-0} + 1 ))
            if [ "$_st_n" -ge 3 ]; then
                HOME_STATS=0
                printf "Painel: a Home nao bate com o /user - os numeros seguem pelo /user\n"
            fi
        fi
    fi
    messages_info
    ativ_marcar stats
    printf %s "$_aba_ant" > "${TMP}/pagina" 2>/dev/null
    unset _pg _a _aba_ant _st_home _st_h
}

# MASMORRA DO CLA: QUEM DECIDE E A PAGINA, NAO O RELOGIO.
#
# $TMP/next_masmorra guarda a PROXIMA TENTATIVA (epoch):
#   masmorra_marcar   golpe saiu -> volta quando o relogio da pagina zerar
#   masmorra_adiar    nao saiu   -> idem; sem relogio, FUNC_masmorra_min
#
# Gastos os 10 golpes, o jogo mostra quando voltam (28800000 ms = 8h):
#
#   Não há mais golpes<br/><span class='grey medium'>+10 golpes em
#   <span id='time_28800000'>08:00:00</span></span>
masmorra_liberada() {
    # Masmorra so com FUNC_masmorra=y (o padrao) no config.cfg.
    [ "${FUNC_masmorra:-y}" = "y" ] || return 1
    _u=; { read -r _u < "$TMP/next_masmorra"; } 2>/dev/null
    case "$_u" in ''|*[!0-9]*) _u=0 ;; esac
    # Mais de 2 dias adiante nao e relogio do jogo (ver relogio_liberado).
    agora_s
    _u=$(( _u - _AGORA ))
    [ "$_u" -le 0 ] || [ "$_u" -gt 172800 ]
}
# Segundos ate os golpes voltarem, lidos da pagina da masmorra ($1).
masmorra_relogio() {
    _mr=`grep -o -E "golpes em <span id='time_[0-9]+'>" "$1" 2>/dev/null | head -n 1 | grep -o -E '[0-9]+'`
    case "$_mr" in ''|*[!0-9]*) unset _mr; return 1 ;; esac
    echo $(( _mr / 1000 ))
    unset _mr
}
masmorra_anotar() { # segundos_sem_relogio
    _ms=`masmorra_relogio "$TMP/DUNGEON"`
    case "$_ms" in ''|*[!0-9]*) _ms="$1" ;; esac
    agora_s
    echo $(( _AGORA + _ms + 60 )) > "$TMP/next_masmorra" 2>/dev/null
    unset _ms
}
# Sem relogio na pagina depois dos golpes: as 8h do jogo.
masmorra_marcar() { masmorra_anotar 28800; }
masmorra_adiar() {
    _mm=${FUNC_masmorra_min:-45}
    case "$_mm" in ''|*[!0-9]*) _mm=45 ;; esac
    masmorra_anotar $(( _mm * 60 ))
    unset _mm
}

# ---------------------------------------------------------------------------
#  CAVERNA E CAMPANHA TAMBEM PELO RELOGIO DO JOGO
#
#  CAVERNA. O menu da pagina inicial (que o descansar() ja baixa) diz quanto
#  falta; nao ha tempo fixo:
#
#     <a href='/cave/'>... Caverna <span class='grey'>(21:04)</span></a>
#     <a href='/cave/'>... Caverna<span class='green'> (+)</span></a>
#
#  Entra quando o menu da (+) ou o relogio zera; sem leitura do menu, 20 min.
#
#  CAMPANHA. Feita, a pagina mostra "Nova campanha em 7 h 38 min" (uma a
#  cada 8h). Le esse relogio; sem ele, concluida a campanha, espera as 8h.
#
#     $TMP/next_caverna   $TMP/next_campanha   (epoch em que a atividade volta)
# ---------------------------------------------------------------------------

# "21:04" ou "1:02:03" -> segundos, sem processo.
relogio_seg_sh() {
    _rs_ifs=$IFS; IFS=:; set -- $1; IFS=$_rs_ifs; unset _rs_ifs
    _rs_a=${1#0}; _rs_b=${2#0}; _rs_c=${3#0}
    case $# in
        2) echo $(( ${_rs_a:-0} * 60 + ${_rs_b:-0} )) ;;
        3) echo $(( ${_rs_a:-0} * 3600 + ${_rs_b:-0} * 60 + ${_rs_c:-0} )) ;;
    esac
    unset _rs_a _rs_b _rs_c
}

relogio_liberado() { # nome -> 0 vencido, 1 ainda nao, 2 sem marca
    _rl=; { read -r _rl < "$TMP/next_$1"; } 2>/dev/null
    case "$_rl" in ''|*[!0-9]*) unset _rl; return 2 ;; esac
    # Nenhum relogio do jogo passa de 1 dia. Mais de 2 dias adiante e marca
    # gravada com o relogio do aparelho errado: vale como vencido.
    agora_s
    _rl=$(( _rl - _AGORA ))
    if [ "$_rl" -le 0 ] || [ "$_rl" -gt 172800 ]; then unset _rl; return 0; fi
    unset _rl
    return 1
}

relogio_anotar() { # nome segundos
    case "$2" in ''|*[!0-9]*) return 1 ;; esac
    agora_s
    echo $(( _AGORA + $2 )) > "$TMP/next_$1" 2>/dev/null
}

# Le o relogio da caverna no menu da pagina inicial ($1). Sem menu (pagina
# de luta, erro do servidor), nao mexe no que ja estava anotado. O padrao nao
# sai do link da caverna: o item seguinte do menu (Rei dos Imortais) tambem
# tem relogio entre parenteses.
caverna_ler_menu() {
    _cv=`grep -o -m 1 -E "href='/cave/'>(<img[^>]*>)?[^<()]*<span class='grey'>\\(([0-9]{1,2}:)?[0-9]{1,2}:[0-9]{2}\\)" "$1" 2>/dev/null`
    _cv=${_cv%%"
"*}; _cv=${_cv##*\(}; _cv=${_cv%\)}
    if [ -n "$_cv" ]; then
        relogio_anotar caverna $(( `relogio_seg_sh "$_cv"` + 30 ))
    elif grep -q -E "href='/cave/'>(<img[^>]*>)?[^<()]*<span class='green'> ?\\(\\+\\)" "$1" 2>/dev/null; then
        relogio_anotar caverna 0
    fi
    unset _cv
}

caverna_liberada() {
    relogio_liberado caverna
    case $? in
        0) return 0 ;;
        1) return 1 ;;
    esac
    ativ_liberada caverna 20
}

# Depois de mexer na caverna o relogio muda. Ate o proximo descanso reler o
# menu, vale o intervalo antigo: se a pagina inicial nao vier, a caverna nao
# e reaberta a cada minuto.
caverna_marcar() {
    ativ_marcar caverna
    relogio_anotar caverna 1200
}

# "Nova campanha em 7 h 38 min" -> segundos. Sem tags no meio do texto.
campanha_relogio() {
    sed 's/<[^>]*>//g' "$1" 2>/dev/null | grep -o -E 'campanha em[^0-9]{0,4}([0-9]+ ?h)?[^0-9]{0,3}([0-9]+ ?min)?' | head -n 1 | \
        awk '{
            s = 0
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^[0-9]+h$/)   s += $i * 3600
                if ($i ~ /^[0-9]+min$/) s += $i * 60
                if ($i ~ /^[0-9]+$/ && $(i+1) == "h")   s += $i * 3600
                if ($i ~ /^[0-9]+$/ && $(i+1) == "min") s += $i * 60
            }
            if (s > 0) print s
        }'
}

campanha_liberada() {
    relogio_liberado campanha
    [ $? -ne 1 ]
}

# Tarefas que NAO dependem da agenda de eventos (arena, checklist do cla,
# masmorra, carreira, caverna, liga...). Cada bloco tem portao proprio, entao
# rodar a cada volta do laco (~1 min) nao executa tudo a cada minuto.
#
# NAO e chamado durante os cinco eventos de prioridade: a conta aplicada num
# deles nao faz mais nada. Ao fim do evento o start() chama esta varredura.
tarefas_livres() {
    # Batalha pendente (sessao caiu no meio da luta): quem chegou aqui acabou
    # de tentar a retomada; nao tenta de novo nem roda a rotina.
    batalha_pendente && return 0
    # Disjuntor aberto (servidor fora do ar para varias contas): nada aqui.
    if disjuntor_segura; then
        printf "Servidor fora do ar (disjuntor) - atividades seguradas\n"
        return 0
    fi
    [ -n "$CLD" ] || clan_id 2>/dev/null

    # --- Numeros do painel, a cada 5 min
    if stats_liberado; then
        atualiza_stats 2>/dev/null
    fi

    # SERVIDOR MUDO: NENHUMA ATIVIDADE NESTA VOLTA. Cada pedido sem resposta
    # espera ate 17s e a volta ficaria minutos presa, inclusive perto das
    # inscricoes. O descanso confere a sessao de novo para a proxima volta.
    if servidor_mudo; then
        printf "Servidor sem resposta - atividades na proxima volta\n"
        return 0
    fi

    # --- Checklist das missoes do cla
    if [ -n "$CLD" ] && cq_liberado; then
        printf "Checklist do cla\n"
        cq_concluir    2>/dev/null
        cq_ajudar      2>/dev/null
        # Missoes 7 e 8 tem atividade propria: alquimia e mercador do
        # Coliseu. Sem missao ativa, cq_tomar falha e nada e produzido.
        cq_elixir      2>/dev/null
        cq_mercador    2>/dev/null
        cq_marcar
    fi

    # --- Masmorra do cla (a pagina diz se ha golpe)
    #
    # ENTRE OS BLOCOS PESADOS, O RELOGIO: masmorra, liga, caverna e campanha
    # somadas passam dos 5 min de inscricao. No minuto de inscricao, o resto
    # fica para a proxima volta.
    liga_fora_da_inscricao || return 0
    if [ -n "$CLD" ] && masmorra_liberada; then
        if clanDungeon; then masmorra_marcar; else masmorra_adiar; fi
    fi

    # --- Torneio de Equipe: o lider inscreve a equipe no proximo torneio.
    # A inscricao abre horas antes e so o lider tem o botao; o
    # clancommand_start ja tenta logo depois da batalha, aqui e a repescagem.
    liga_fora_da_inscricao || return 0
    if [ -n "$CLD" ] && ativ_liberada torneq 60; then
        clancommand_inscrever 2>/dev/null
        ativ_marcar torneq
    fi

    # --- Arena, sempre tomando antes a missao do cla que ela completa
    liga_fora_da_inscricao || return 0
    if arena_liberada; then
        cq_antes arena 2>/dev/null
        arena_duel
        arena_marcar
    fi

    # --- Carreira, campanha, caverna e cabana do sabio, cada uma no seu
    # intervalo (marcador em disco).
    if ativ_liberada carreira 15; then
        cq_antes carreira 2>/dev/null
        career_func
        ativ_marcar carreira
    fi

    liga_fora_da_inscricao || return 0
    if campanha_liberada; then
        campaign_func
    fi

    liga_fora_da_inscricao || return 0
    if caverna_liberada; then
        cq_antes caverna 2>/dev/null
        cave_routine
        caverna_marcar
    fi

    if ativ_liberada sabio 20; then
        check_missions
        check_rewards
        ativ_marcar sabio
    fi

    # --- Liga, Troca, Missoes do Cla e Eventos especiais.
    #
    # Liga: uma visita por dia, as 00:30 (liga_do_dia, em league.sh); aqui so
    # volta antes quando uma luta nao contou e ainda ha lutas no dia.
    liga_fora_da_inscricao || return 0
    if ativ_liberada liga 30; then
        liga_do_dia
    fi

    # O func_trade tem portao proprio de uma vez ao dia; o intervalo aqui e
    # so para nao reabrir a pagina da troca a cada minuto.
    if ativ_liberada troca 60; then
        func_trade 2>/dev/null
        ativ_marcar troca
    fi

    if [ -n "$CLD" ] && [ "${FUNC_clan_missions:-y}" = "y" ] && ativ_liberada clanquest 20; then
        clanQuests 2>/dev/null
        ativ_marcar clanquest
    fi

    if [ "${FUNC_auto_events:-y}" = "y" ] && ativ_liberada evento 30; then
        specialEvent 2>/dev/null
        ativ_marcar evento
    fi

    # --- Lista de aliados (amigos + cla, ver allies.sh), a cada 12h. Sem
    # isto as listas das batalhas de cla ficariam vazias: o worker nao tem
    # teclado. A chave "aliados2" faz quem atualizar refazer a lista ja.
    if ativ_liberada aliados2 720; then
        if allies_refresh 2>/dev/null; then
            ativ_marcar aliados2
        else
            # Pagina que nao respondeu: nova tentativa em 30 min, nao em 12h.
            echo $(( `date +%s` - 690 * 60 )) > "$TMP/last_aliados2" 2>/dev/null
        fi
    fi
}

# Arena a cada 30 minutos (marcador em disco, sobrevive a reinicios).
arena_liberada() { ativ_liberada arena "${FUNC_arena_min:-30}"; }
arena_marcar() { ativ_marcar arena; }

# Portao de atividade: ativ_liberada nome [minutos] -> 0 se o marcador
# $TMP/last_<nome> (epoch, gravado por ativ_marcar) tem mais que os minutos.
ativ_liberada() {
    _an="$1"; _am="${2:-15}"
    case "$_am" in ''|*[!0-9]*) _am=15 ;; esac
    # read (interno do shell) no lugar do cat: um processo a menos por
    # portao, conta no limite de 32 do Android.
    _au=; { read -r _au < "$TMP/last_$_an"; } 2>/dev/null
    case "$_au" in ''|*[!0-9]*) _au=0 ;; esac
    # Marcador no futuro (relogio do aparelho voltou, NTP no Android): vencido.
    agora_s
    _au=$(( _AGORA - _au ))
    if [ "$_au" -lt 0 ] || [ "$_au" -ge $((_am * 60)) ]; then
        unset _an _am _au; return 0
    fi
    unset _an _am _au; return 1
}
ativ_marcar() { agora_s; echo "$_AGORA" > "$TMP/last_$1" 2>/dev/null; }

# ============================================================
#  PERIODO DEDICADO AO EVENTO
#
#  Durante os cinco eventos de prioridade (Torneio dos Clas, Coliseu do Cla,
#  Altares, Rei dos Imortais e Vale dos Imortais), da inscricao ate o fim a
#  conta e so daquilo. Se o modulo devolve cedo (a conta caiu da luta), o
#  start() logo abaixo varreria tudo com o evento em andamento: por isso o
#  inicio e anotado antes ($TMP/em_evento) e o evento_espera segura a conta,
#  descansando na pagina inicial, ate o fim.
# ============================================================

# Anota em $TMP/em_evento o epoch do inicio do evento: o proximo :00 ou :30.
# Os ramos de prioridade entram em :55-:59 ou :25-:29.
evento_dedicar() {
    _ed_s=`date +%M%S`
    _ed_m=${_ed_s%??}; _ed_m=${_ed_m#0}; _ed_s=${_ed_s#??}; _ed_s=${_ed_s#0}
    case "$_ed_m" in ''|*[!0-9]*) _ed_m=0 ;; esac
    case "$_ed_s" in ''|*[!0-9]*) _ed_s=0 ;; esac
    if   [ "$_ed_m" -ge 50 ]; then _ed_f=$(( 60 - _ed_m ))
    elif [ "$_ed_m" -ge 20 ] && [ "$_ed_m" -lt 30 ]; then _ed_f=$(( 30 - _ed_m ))
    else _ed_f=0
    fi

    # ENTRADA ESCALONADA ENTRE AS CONTAS, MAS NUNCA A CUSTA DA JANELA.
    #
    # Sem isto todas as contas aplicam no mesmo segundo (rajada do mesmo IP).
    # O deslocamento ($$ % 10) e limitado pelo que AINDA RESTA de janela, com
    # 5s de folga: cada modulo re-verifica a janela por dentro (king_start so
    # age em :2[5-9]) e devolveria sem fazer nada se acordasse depois dela.
    _ed_resta=$(( _ed_f * 60 - _ed_s - 5 ))
    _ed_esp=$(( $$ % 10 ))
    [ "$_ed_esp" -gt "$_ed_resta" ] && _ed_esp=0
    [ "$_ed_esp" -gt 0 ] && sleep "$_ed_esp"

    # O "- _ed_esp" desconta a espera: o _ed_f foi medido antes de dormir.
    echo $(( `date +%s` + _ed_f * 60 - _ed_esp )) > "$TMP/em_evento" 2>/dev/null
    unset _ed_m _ed_s _ed_f _ed_resta _ed_esp
}

# Desiste da dedicacao ao evento: o modulo que decide NAO participar (Coliseu
# do Cla fora de temporada, por exemplo) chama isto, e a conta volta para a
# rotina em vez de ficar parada.
evento_cancelar() { # [SECAO]
    rm -f "$TMP/em_evento" 2>/dev/null
    # Sem inscricao nao ha batalha a retomar. Com a secao, so apaga a anotacao
    # dela: uma batalha de OUTRO evento ainda pendente (sessao caida) fica,
    # senao o descanso confirmaria a fuga dela.
    if [ -z "$1" ] || ! batalha_pendente || [ "$_bp_sec" = "$1" ]; then
        batalha_limpar 2>/dev/null
    fi
    return 0
}

# Segura a conta ate o evento acabar (volta na hora se o modulo ja consumiu o
# tempo lutando). Duracao: FUNC_evento_min (padrao 10) no config.cfg; o bot
# nao tem como descobri-la sozinho.
evento_espera() {
    _ee_ini=`cat "$TMP/em_evento" 2>/dev/null`
    rm -f "$TMP/em_evento" 2>/dev/null
    case "$_ee_ini" in ''|*[!0-9]*) unset _ee_ini; return 0 ;; esac

    _ee_dur=${FUNC_evento_min:-10}
    case "$_ee_dur" in ''|*[!0-9]*) _ee_dur=10 ;; esac
    _ee_fim=$(( _ee_ini + _ee_dur * 60 ))

    while [ "`date +%s`" -lt "$_ee_fim" ]; do
        # Falta mais que a inscricao (10 min) + o evento: o relogio voltou.
        [ $(( _ee_fim - `date +%s` )) -gt $(( (_ee_dur + 10) * 60 )) ] && break
        printf "Evento em andamento - atividades suspensas (%ss)\n" \
            $(( _ee_fim - `date +%s` ))
        descansar
        sleep 30
    done
    unset _ee_ini _ee_dur _ee_fim
    return 0
}

# Apaga os marcadores de combate ao vivo (HP/old_HP/FULL/USH) que os modulos
# de batalha gravam e o painel le; sem isto o painel mostraria combate
# fantasma com a conta ja parada.
limpar_combate() {
    # So chama o rm quando ha o que apagar (o [ -e ] e do proprio shell).
    [ -e "$TMP/HP" ] || [ -e "$TMP/old_HP" ] || [ -e "$TMP/FULL" ] || [ -e "$TMP/USH" ] || return 0
    rm -f "$TMP/HP" "$TMP/old_HP" "$TMP/FULL" "$TMP/USH" 2>/dev/null
}

# Volta para a batalha pendente desta conta, se houver (worker relancado,
# modulo que devolveu cedo): em vez de cair na rotina e no "Fuja da batalha",
# rele a pagina do evento e segue lutando.
#
# Devolve 0 se havia batalha (e ela foi retomada), 1 se nao havia.
batalha_retomar() {
    [ "${_BR_ATIVO:-0}" = 1 ] && return 1
    batalha_pendente || return 1
    _BR_ATIVO=1
    printf "Batalha em andamento (%s): voltando para a luta\n" "$_bp_sec"
    cd "$TMP" || { _BR_ATIVO=0; return 1; }

    # HP maximo: o limpar_combate apaga o FULL, e o worker relancado pode nao
    # te-lo. Sem ele o limiar de cura seria zero.
    case "$_bp_sec" in
        king|clanfight|clandmgfight|altars|clancommand) _br_full="$TMP/FULL" ;;
        clancoliseum) _br_full="$TMP/ccol_full" ;;
        flagfight)    _br_full="$TMP/flag_full" ;;
        *)            _br_full="" ;;
    esac
    if [ -n "$_br_full" ] && [ ! -s "$_br_full" ]; then
        full_atualizar "$_br_full"
    fi

    LUTA_SESSAO_CAIU=0
    case "$_bp_sec" in
        king)         fetch_page "/king" "$TMP/SRC";              king_fight ;;
        undying)      undying_fight ;;
        altars)       fetch_page "/altars" "$TMP/src.html";       altars_fight ;;
        clanfight)    fetch_page "/clanfight" "$TMP/SRC";         clanfight_fight ;;
        clandmgfight) fetch_page "/clandmgfight" "$TMP/SRC";      clandmgfight_fight ;;
        clancoliseum) fetch_page "/clancoliseum" "$TMP/ccol_src"; clancoliseum_fight ;;
        flagfight)    fetch_page "/flagfight" "$TMP/flag_src";    flagfight_fight ;;
        clancommand)  fetch_page "/clancommand" "$TMP/ccmd_src";  clancommand_fight ;;
        coliseum)
            # O coliseum_fight tambem INSCREVE: com a luta ja encerrada ele
            # entraria numa NOVA, ate fora da janela das 00:30-04:30. So roda
            # se a pagina mostrar luta em andamento.
            fetch_page "/coliseum" "$TMP/col_src"
            case "`estado_luta "$TMP/col_src" coliseum`" in
                luta)      coliseum_fight ;;
                # Sem sessao ou sem resposta nao da para saber: fica para
                # depois (apagar faria o descanso confirmar a fuga). A
                # anotacao ainda expira no teto (30 min).
                deslogado|invalida) LUTA_SESSAO_CAIU=1 ;;
            esac
            ;;
        *)            : ;;
    esac

    # UMA TENTATIVA POR BATALHA ANOTADA: senao cada volta e cada descanso
    # tentariam de novo por ate 30 min. So a queda de sessao mantem a
    # anotacao, para a luta continuar quando a sessao voltar.
    [ "${LUTA_SESSAO_CAIU:-0}" = 1 ] || batalha_limpar
    unset _br_full
    _BR_ATIVO=0
    return 0
}

# Volta para a pagina inicial. As contas devem descansar ali entre os
# ciclos, e nao numa pagina de combate ou de evento: o jogo mantem o
# personagem "em batalha" e a navegacao seguinte cai em "Fuja da batalha".
descansar() {
    # Com batalha pendente, a conta volta para ela em vez de ir para a Home.
    batalha_retomar

    # HOME REPETIDA NAO E PEDIDA DE NOVO.
    #
    # Se a ultima pagina pedida ja foi a Home e ESTE descanso a confirmou com
    # sessao viva ha menos de 50s, a leitura anterior ainda vale (voltas de
    # 15s perto das janelas). A prova e o $TMP/.home_ok, gravado so no fim
    # feliz do descanso; o last_ok nao serve, as lutas e o link_acao tambem o
    # carimbam.
    # ponytail: a queda de sessao pode levar ate 50s a mais para ser vista.
    _ds_req=; _ds_ok=0
    { read -r _ds_req < "$TMP/.ult_req"; read -r _ds_ok < "$TMP/.home_ok"; } 2>/dev/null
    case "$_ds_ok" in ''|*[!0-9]*) _ds_ok=0 ;; esac
    agora_s
    _ds_ok=$(( _AGORA - _ds_ok ))
    # Diferenca negativa = relogio voltou: nao prova nada, pede a Home.
    if [ "$_ds_req" = "/" ] && [ "$_ds_ok" -ge 0 ] && [ "$_ds_ok" -lt 50 ]; then
        unset _ds_req _ds_ok
        return 0
    fi
    unset _ds_req _ds_ok

    fetch_page "/" "$TMP/REST" 2>/dev/null

    # "FUJA DA BATALHA" SO DEPOIS DE O JOGO DECLARAR O FIM.
    #
    # A Home e pedida primeiro. So se o jogo ainda segurar o personagem (a
    # pagina oferece o out_gate_confirm) E nao houver batalha pendente (o jogo
    # ja declarou a morte ou o fim, ou a pagina do evento passou LUTA_FORA_MAX
    # segundos sem luta, LUTA_FORA_LUTOU se ja lutou) a saida e confirmada.
    if grep -q 'out_gate_confirm' "$TMP/REST" 2>/dev/null; then
        if batalha_pendente; then
            printf "Ainda em batalha (%s) - a conta nao foge\n" "$_bp_sec"
            return 0
        fi
        fetch_page "/?out_gate_confirm=true" "$TMP/REST" 2>/dev/null
        fetch_page "/" "$TMP/REST" 2>/dev/null
    fi
    # A conta voltou para casa: registra a pagina inicial e encerra o
    # "ao vivo" da luta que acabou.
    printf %s "/" > "$TMP/pagina" 2>/dev/null
    limpar_combate

    # O menu desta pagina traz o relogio da caverna: de graca, sem requisicao.
    caverna_ler_menu "$TMP/REST"

    # SESSAO CONFERIDA AQUI, DE GRACA: com cookie morto a conta nao aparece
    # online para os outros jogadores, embora o worker esteja vivo.
    #
    # SERVIDOR MUDO NAO E SESSAO CAIDA. Pagina vazia, cortada ou que nao e
    # do jogo nao prova que a conta saiu: tratar como queda apagava o cookie
    # e refazia o login no pior momento (ver sessao_estado, em info.sh).
    case "`sessao_estado "$TMP/REST"`" in
        viva)
            agora_s; _ds_ok="$_AGORA"
            echo "$_ds_ok" > "$TMP/last_ok" 2>/dev/null
            echo "$_ds_ok" > "$TMP/.home_ok" 2>/dev/null
            unset _ds_ok
            return 0
            ;;
        sem_resposta)
            servidor_mudo_marcar
            printf "Servidor sem resposta no descanso - sessao mantida\n"
            return 1
            ;;
    esac

    # NAO RECONECTA EM BLOCO. Com muitas contas no mesmo IP, se todas
    # reconectam juntas o servidor estrangula a rajada e derruba sessao de
    # quem estava bem. O portao (luta_pode_reconectar, em info.sh) tem
    # deslocamento por conta derivado do PID e e o mesmo da luta, entao as
    # duas nao somam tentativas.
    luta_pode_reconectar || return 1
    date +%s > "$TMP/last_reconn" 2>/dev/null

    printf "Sessao caiu no descanso - reconectando\n"
    if type login_logoff > /dev/null 2>&1 && login_logoff; then
        date +%s > "$TMP/last_ok" 2>/dev/null
        return 0
    fi
    return 1
}

start() {
    # UMA VARREDURA POR MINUTO: no :30 a espera e de 15s e o laco voltaria ao
    # ramo das :30. A segunda chamada no mesmo minuto so espera o minuto virar.
    _st_min=`date +%Y%m%d%H%M`
    if [ "`cat "$TMP/last_start" 2>/dev/null`" = "$_st_min" ]; then
        _st_s=`date +%S`; _st_s=${_st_s#0}
        case "$_st_s" in ''|*[!0-9]*) _st_s=0 ;; esac
        unset _st_min
        espera_interrompivel $(( 60 - _st_s ))
        unset _st_s
        return 0
    fi
    # Disjuntor aberto: sem varredura nem login. A marca do minuto fica para
    # depois, para a varredura sair neste minuto se ele fechar.
    if disjuntor_segura; then
        unset _st_min
        printf "Servidor fora do ar (disjuntor) - varredura segurada\n"
        func_crono
        func_sleep
        return 1
    fi
    printf '%s' "$_st_min" > "$TMP/last_start" 2>/dev/null
    unset _st_min

    load_config

    if type login_logoff > /dev/null 2>&1; then
        if ! login_logoff; then
            printf "Sessao invalida — pulando este ciclo\n"
            func_crono
            func_sleep
            return 1
        fi
    fi
    # Sessao de volta: a batalha que ficou pendente vem antes da varredura.
    batalha_retomar

    # O login_logoff ja executa o clan_id com a sessao viva; o `||` cobre
    # quando ele nao existe ou nao rodou.
    [ -n "$CLD" ] || clan_id 2>/dev/null

    # Lider do cla: mantem a estatua ativa (bonus de PRATA e de OURO do cla,
    # pagos pela tesouraria do cla; o Bonus Pessoal, que gasta o ouro da
    # conta, nunca e ativado). Portao proprio de 6h (estatua_liberada).
    clan_statue

    # Agenda oficial do jogo (painel) e elixir das batalhas: uma vez por
    # varredura das :00/:30 (25 min deixa passar as duas). A agenda e uma so
    # para o aparelho (~/.sls/agenda): baixada ha menos de 25 min ja serve.
    if ativ_liberada agenda 25; then
        [ -n "`find "$HOME/.sls/agenda" -mmin -25 2>/dev/null`" ] || atualiza_agenda 2>/dev/null
        ativ_marcar agenda
    fi
    if ativ_liberada elixir 25; then
        cq_antes elixir 2>/dev/null
        use_elixir
        ativ_marcar elixir
    fi

    # O resto e a varredura do ocioso, com os mesmos portoes (o RUNNOW libera
    # todos).
    tarefas_livres

    messages_info
    descansar
    func_crono -q
    func_sleep
}
