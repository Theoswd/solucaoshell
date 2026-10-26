# CRONOGRAMA DO SERVIDOR RUSSO (tiwar.ru), EM HORARIO DE MOSCOU.
#
# Tabela propria do russo: o worker da conta RU roda com TZ=Europe/Moscow
# (sls.sh), entao estes horarios sao os do servidor. Lidos do
# /fights/timetable/ em 26/10/2026 (inicio da batalha, em MSK):
#
#   1. Клановый колизей    Coliseu do Cla     10:30  15:00
#   2. Клановый турнир     Torneio dos Clas   11:00  19:00
#   3. Король бессмертных  Rei dos Imortais   12:30  16:30  22:30
#   4. Долина бессмертных  Vale dos Imortais  10:00  16:00  22:00
#   5. Древние алтари      Altares            14:00  21:00
#   6. Битва знамён        Bandeiras          10:15  16:15  (de temporada)
#
# Os outros eventos de temporada (Torneio de Equipe, Duelo do Cla e os
# especiais do banner) nao estavam no ar no dia do mapa: ficam nos mesmos
# horarios do BR ate aparecerem na tabela russa. Fora da temporada a pagina
# deles cai na inicial e o modulo volta sem lutar, como no BR.
#
# Mesma ordem de prioridade e mesmas regras do cronograma do BR (abaixo):
# inscricao cinco minutos antes e a conta dedicada ao evento ate o fim.
# Devolve 1 fora destes horarios: a volta segue o case do sls_play (coliseu
# da madrugada, varredura das :00/:30 e ocioso, que valem para os dois).
cronograma_ru() {
    case "$1" in
        (10:2[5-9]|14:5[5-9])
            if [ -n "$CLD" ]; then
                evento_dedicar
                clancoliseum_start
                evento_espera
            fi
            start
            ;;
        (11:2[5-9]|17:5[5-9])
            if [ -n "$CLD" ]; then
                evento_dedicar
                clancommand_start
                evento_espera
            fi
            start
            ;;
        (10:5[5-9]|18:5[5-9])
            if [ -n "$CLD" ]; then
                evento_dedicar
                clanfight_start
                evento_espera
            fi
            start
            ;;
        (12:2[5-9]|16:2[5-9]|22:2[5-9])
            evento_dedicar
            king_start
            evento_espera
            start
            ;;
        (09:5[5-9]|15:5[5-9]|21:5[5-9])
            evento_dedicar
            undying_start
            evento_espera
            start
            ;;
        (13:5[5-9]|20:5[5-9])
            if [ -n "$CLD" ]; then
                evento_dedicar
                altars_start
                evento_espera
            fi
            start
            ;;
        (10:1[0-4]|16:1[0-4])
            flagfight_start
            descansar
            ;;
        (09:2[5-9]|21:2[5-9])
            specialEvent
            ativ_marcar evento
            start
            ;;
        (*)
            return 1
            ;;
    esac
    return 0
}

sls_play() {
    echo "$RUN" > "$TMP/runmode_file" 2>/dev/null

    # Testa a VARIAVEL, nao so o arquivo: os eventos de cla so entram com
    # "$CLD" preenchido. O clan_id carrega do arquivo e so vai a rede no
    # intervalo dele (uma hora).
    [ -n "$CLD" ] || clan_id

    # BATALHA PENDENTE VEM ANTES DE TUDO: o Android mata worker com SIGKILL e
    # o painel relanca. A batalha fica anotada em disco desde a inscricao
    # (batalha_marcar), e aqui a conta volta para ela.
    batalha_retomar

    # UM "date" POR VOLTA, DEPOIS DA IDA A REDE (relogio_sync, em info.sh):
    # um /clan lento antes do case faria a agenda ver o minuto errado e
    # entrar num evento fora da janela. Cobre tambem a retomada.
    relogio_sync

    # Conta do servidor russo: a tabela dele, em horario de Moscou.
    if [ "${SLS_TAG:-BR}" = RU ] && cronograma_ru "$_HH:$_MM"; then
        return 0
    fi

    # CRONOGRAMA DE BATALHAS — ORDEM DE PRIORIDADE
    #
    # O "case" para no primeiro padrao que casa: a ordem dos ramos E a
    # prioridade. De cima para baixo:
    #
    #   1. Coliseu do Cla        10:25  14:55
    #   2. Torneio dos Clas      10:55  18:55
    #   3. Rei dos Imortais      12:25  16:25  22:25
    #   4. Vale dos Imortais     09:55  15:55  21:55
    #   5. Altares dos Deuses    13:55  20:55
    #
    # REGRA DAS BATALHAS DO CRONOGRAMA:
    #   - a inscricao sai CINCO MINUTOS antes do inicio (o modulo pede o
    #     enterGame/enterFight e segura a conta ate a hora cheia);
    #   - da inscricao ate o fim a conta NAO faz mais nada: o evento_espera
    #     suspende as atividades e so descansa na Home;
    #   - terminada a batalha, o start() faz a varredura completa.
    #
    # O evento_dedicar fica dentro do ramo que de fato entra na batalha (conta
    # sem cla nao fica parada); o modulo que desiste chama evento_cancelar.
    case "$_HH:$_MM" in

        # --- 1. Coliseu do Cla
        #
        # Cinco minutos de janela, como o clancoliseum_start aceita: a
        # inscricao acontece DENTRO do modulo, perder a janela e nao participar.
        (10:2[5-9]|14:5[5-9])
            if [ -n "$CLD" ]; then
                evento_dedicar
                clancoliseum_start
                evento_espera
            fi
            start
            ;;

        # --- 1b. Torneio de Equipe (11:30 e 18:00)
        #
        # A inscricao abre horas antes: o clancommand_start le o contador e,
        # se o inicio esta longe, inscreve e devolve a conta para a rotina.
        # Exige cla: a equipe e de 3 titas do MESMO cla.
        (11:2[5-9]|17:5[5-9])
            if [ -n "$CLD" ]; then
                evento_dedicar
                clancommand_start
                evento_espera
            fi
            start
            ;;

        # --- 2. Torneio dos Clas
        (10:5[5-9]|18:5[5-9])
            if [ -n "$CLD" ]; then
                evento_dedicar
                clanfight_start
                evento_espera
            fi
            start
            ;;

        # --- 3. Rei dos Imortais
        (12:2[5-9]|16:2[5-9]|22:2[5-9])
            evento_dedicar
            king_start
            evento_espera
            start
            ;;

        # --- 4. Vale dos Imortais
        (09:5[5-9]|15:5[5-9]|21:5[5-9])
            evento_dedicar
            undying_start
            evento_espera
            start
            ;;

        # --- 5. Altares dos Deuses
        (13:5[5-9]|20:5[5-9])
            if [ -n "$CLD" ]; then
                evento_dedicar
                altars_start
                evento_espera
            fi
            start
            ;;

        # --- Coliseu comum: 02:40 as 04:30, pulsado de 10 em 10 minutos
        #
        # Das 00:30 as 02:40 a madrugada e da caverna (pedido do dono: ver
        # caverna_noite, em cave.sh); o Coliseu vem depois, de 02:45 a 04:25.
        # Cada coliseum_fight faz tres requisicoes de preparo; pulsar nos
        # minutos terminados em 5 evita rajada. Os minutos que sobram caem no
        # ramo (*), que ja chama tarefas_livres.
        (02:[45]5|03:[0-5]5|04:[012]5)
            # UM PULSO POR MINUTO QUANDO NAO HA LUTA: achou o Coliseu sem luta
            # neste minuto, o resto dele e como o ramo (*). A marca leva o dia
            # (o worker vive dias). No modo -cl nao ha guarda.
            if [ "$_COL_PULSO" = "$_DD $_HH:$_MM" ]; then
                tarefas_livres
                func_sleep
                func_crono -q
            else
                coliseum_fight
                case "$RUN" in
                    *-cl*) ;;
                    *) [ "$COLISEU_SEM_LUTA" = 1 ] && _COL_PULSO="$_DD $_HH:$_MM" ;;
                esac
                  # Entre as lutas confere o checklist do cla e a arena.
                tarefas_livres
                # Este ramo nao passa pelo func_cat/start(): descansa na Home.
                descansar
                # Sem luta o coliseum_fight volta na hora: a pausa evita rajada
                # dentro do mesmo minuto.
                sleep 5
            fi
            ;;

        # --- Batalha de Bandeiras
        (10:1[0-4]|16:1[0-4])
            flagfight_start
            # Sai da pagina da batalha e descansa na Home no servidor: este
            # ramo tambem nao passa pelo func_cat/start().
            descansar
            ;;

        # --- Eventos especiais
        (09:2[5-9]|21:2[5-9])
            specialEvent
            # Marca o portao: sem isto o tarefas_livres do start() chamaria
            # o specialEvent de novo.
            ativ_marcar evento
            start
            ;;

        # --- Rotina comum: varredura completa a cada :00 e :30, sem colidir
        # com os ramos de evento acima (:10, :25, :55).
        (00:00|00:30|01:00|01:30|02:00|02:30|03:00|03:30|04:00|04:30|05:00|05:30|06:00|06:30|07:00|07:30|08:00|08:30|09:00|10:00|10:30|11:00|11:30|12:00|12:30|13:00|13:30|14:00|14:30|15:00|15:30|16:00|16:30|17:00|17:30|18:00|18:30|19:00|19:30|20:00|20:30|21:00|21:30|22:00|23:00|23:30)
            start
            ;;

        (*)
            case "$RUN" in *-cl*) _rn_cl=1 ;; *) _rn_cl=0 ;; esac
            if [ "$_rn_cl" = 1 ]; then
                printf "Running in coliseum mode: %s\n" "$RUN"
                sleep 5
                # A arena fica com o tarefas_livres, no portao dela
                # (arena_liberada).
                coliseum_start
                messages_info
            fi
            # Arena a cada 30 min, mesmo fora dos minutos da agenda.
            tarefas_livres
            func_sleep
            func_crono -q
            ;;
    esac
}

