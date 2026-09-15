# shellcheck disable=SC2154
# shellcheck disable=SC2317
func_crono() {
    HOUR=`date +%H | sed 's/^0//'`
    MIN=`date +%M | sed 's/^0//'`
    [ -z "$HOUR" ] && HOUR=0
    [ -z "$MIN" ] && MIN=0
    printf "%s %s\n" "$URL" "`date +%H:%M`"
}

# Pausa entre ciclos.
#
# CORRECAO CRITICA (multi-contas): a versao anterior fazia
#     read -r -t "$i" cmd
# para "dormir" $i segundos esperando um comando do usuario. Mas o worker e
# lancado com stdin em /dev/null (play.sh) — o read retorna EOF na hora, a
# pausa nunca acontecia, e o laco "while true; do sls_start; done" do sls.sh
# virava busy-loop de 100% de CPU POR CONTA, com o sls.log crescendo sem
# limite e o start() sendo reexecutado centenas de vezes dentro do mesmo
# minuto (rajada de requisicoes identicas).
#
# Agora dorme de verdade, em fatias (espera_interrompivel).
# ============================================================
#  "AGORA": varredura sob demanda, sem esperar o ciclo
#
#  No master bastava apertar ENTER: o func_cat lia o stdin com prazo e
#  qualquer tecla quebrava a espera, entao o laco voltava na hora e a
#  varredura rodava. Aqui isso nao funciona — os workers sobem com
#  "< /dev/null" (nohup+setsid), justamente para sobreviverem ao fechamento
#  do Termux, entao NENHUM ENTER chega neles. O terminal tambem esta ocupado
#  pelo painel, e com 15 contas nao ha um stdin para cada uma.
#
#  O equivalente multi-conta e um arquivo-sinal, como ja e feito com o
#  PAUSED: quem quer a varredura agora cria o arquivo, e o worker o encontra
#  durante a espera.
#
#     $TMP/RUNNOW    (um por conta)
#
#  Para pedir a varredura agora, crie o arquivo na conta desejada:
#
#     touch ~/.sls/BR_<usuario>/RUNNOW
#
#  O sinal e SEMPRE por conta, nunca global. Um arquivo global so poderia
#  ser apagado por um dos workers, e os demais continuariam a encontra-lo —
#  disparando varredura em laco para sempre. Cada worker apaga o seu.
# ============================================================

# Ha pedido de varredura imediata para esta conta?
runnow_pedido() {
    [ -f "$TMP/RUNNOW" ]
}

# Consome o pedido e abre os portoes das atividades.
#
# So quebrar a espera nao bastaria: cada atividade tem portao proprio
# (arena 30 min, carreira 15 min, liga 30 min...), entao a varredura
# encontraria tudo fechado e nao faria nada — que e justamente o oposto do
# que se espera ao pedir "agora". Apagando os marcadores, tudo que estiver
# DISPONIVEL no jogo roda na volta seguinte.
#
# Ficam de fora, de proposito, os portoes que espelham regra do jogo e nao
# preferencia nossa: a masmorra, a caverna e a campanha (relogios lidos do
# jogo) e a estatua (bonus de 48h).
runnow_consumir() {
    rm -f "$TMP/RUNNOW" 2>/dev/null
    rm -f "$TMP/last_arena"  "$TMP/last_carreira" "$TMP/last_campanha" \
          "$TMP/last_caverna" "$TMP/last_sabio"   "$TMP/last_liga" \
          "$TMP/last_troca"   "$TMP/last_clanquest" "$TMP/last_evento" \
          "$TMP/last_cq"      "$TMP/last_stats"    "$TMP/last_agenda" \
          "$TMP/last_elixir" 2>/dev/null
    printf "Varredura sob demanda: portoes liberados\n"
}

# Dorme em fatias, atendendo ao pedido de varredura no meio do caminho.
#
# Antes era um "sleep $i" unico: um pedido feito logo apos o inicio da
# espera so seria visto ate 60s depois. Em fatias de 5s a resposta e quase
# imediata, e continua sendo UM processo de sleep por vez — o que importa no
# Android, onde cada processo conta para o limite de 32.
espera_interrompivel() {
    _ei_total="$1"
    case "$_ei_total" in ''|*[!0-9]*) _ei_total=60 ;; esac
    _ei_gasto=0
    while [ "$_ei_gasto" -lt "$_ei_total" ]; do
        if runnow_pedido; then
            runnow_consumir
            unset _ei_total _ei_gasto
            return 0
        fi
        sleep 5
        _ei_gasto=$((_ei_gasto + 5))
    done
    unset _ei_total _ei_gasto
    return 0
}

func_cat() {
    func_crono
    [ -f "$TMP/msg_file" ] && cat "$TMP/msg_file"

    _i="${i:-60}"
    case "$_i" in ''|*[!0-9]*) _i=60 ;; esac

    # DESCANSO REAL NA HOME.
    #
    # Antes aqui so gravava pagina="/" (mentira): a SESSAO no jogo continuava
    # na ultima pagina de verdade — tipicamente /user (stats) ou /clan
    # (checklist), buscadas pelo tarefas_livres no ciclo ocioso. Por isso a
    # "atividade" que os outros jogadores viam era sempre Perfil/Cla, enquanto
    # o painel dizia "Pagina Principal". Agora faz um GET real em "/", entao a
    # conta descansa de fato na home e o pagina="/" passa a ser verdade.
    descansar

    # O worker sobe com stdin em /dev/null: nao ha terminal para ler comando.
    printf "Sem batalhas agora, aguardando %ss\n" "$_i"
    espera_interrompivel "$_i"
    return 0
}

# CORRECAO: "reset" foi removido. Ele executa "stty sane" no TTY que os
# workers herdam do play.sh, o que corrompia o monitor multi-contas na tela
# e enchia o sls.log de sequencias de escape. O "clear" so faz sentido com
# terminal, entao passou a ser condicional.
func_sleep() {
    [ -t 1 ] && clear

    if [ "`date +%d`" -eq 01 ] 2>/dev/null; then
        if [ "${HOUR:-99}" -lt 9 ] 2>/dev/null; then
            coliseum_start
            i=60
            func_cat
            return 0
        fi
    fi

    # ESPERA CURTA NA APROXIMACAO DAS JANELAS DE EVENTO.
    #
    # CORRECAO: com i=60 o worker so reavaliava o relogio uma vez por minuto,
    # e a volta do laco ainda gasta tempo em requisicoes. Janelas estreitas —
    # Coliseu do Cla (:28-:29), Bandeiras (:10-:14), Rei (:25-:29), Torneio e
    # Altares (:55-:59) — podiam ser puladas inteiras: o bot acordava com a
    # janela ja fechada e o evento passava em branco.
    #
    # Perto desses minutos a espera cai para 15s, o que da 4 chances por
    # minuto de entrar na janela. Fora deles segue 60s, sem custo extra.
    #
    # O minuto e lido AQUI, e nao do $MIN: no ramo ocioso do run.sh o
    # func_sleep e chamado ANTES do func_crono, entao o $MIN esta defasado de
    # um ciclo (e vazio na primeira volta) — justamente o erro que faria a
    # espera curta cair no minuto errado.
    _fs_min=`date +%M | sed 's/^0//'`
    case "$_fs_min" in ''|*[!0-9]*) _fs_min=0 ;; esac
    # A espera curta (15s) tem de cobrir TODA a janela de entrada de cada
    # evento, senao uma espera de 60s iniciada perto do fim da janela acorda
    # com ela ja fechada e o evento passa em branco:
    #   Bandeiras    :10-:14   (com :09 de folga)
    #   Rei/Especiais/Coliseu do Cla  :25-:29
    #   Torneio/Altares/Vale/Coliseu do Cla  :55-:59
    # CORRECAO: a lista anterior parava em 13, 30 e 57 — deixava de fora os
    # minutos 14, 58 e 59, justamente as bordas onde a espera longa engolia a
    # janela (ex.: dormir 60s em :58:10 acorda em :59:10, com a inscricao do
    # evento de :00 ja perdida).
    case "$_fs_min" in
        9|1[0-4]|2[4-9]|30|5[4-9]) i=15 ;;
        *)                         i=60 ;;
    esac
    unset _fs_min
    func_cat
}

# Intervalo do checklist de missoes do cla.
cq_liberado()    { ativ_liberada cq    "${FUNC_cq_min:-15}"; }
cq_marcar() { date +%s > "$TMP/last_cq" 2>/dev/null; }

# Atualizacao dos numeros do painel (HP, energia, nivel, ouro, prata).
#
# O stats so era gravado dentro do start(), que roda nos minutos da
# agenda — com vaos de mais de uma hora. O painel exibia valores
# velhos: ouro 128 quando ja era 28, HP 583 quando ja era 656.
# Uma requisicao a /user a cada 3 minutos por conta resolve sem peso.
stats_liberado() { ativ_liberada stats "${FUNC_stats_min:-3}"; }

atualiza_stats() {
    # Preserva a aba atual em TODOS os caminhos de saida. O run_curl
    # registra cada pagina acessada, entao a consulta a /user (e a /train,
    # para a energia) sobrescreve $TMP/pagina.
    #
    # CORRECAO (descanso preso em "Meu Heroi"): a versao anterior so
    # restaurava a aba no caminho de sucesso. Uma falha de rede ou de sessao
    # fazia o `return 1` sair deixando "/user" gravado — e o painel exibia
    # "Meu Heroi" durante o descanso, a cada 3 minutos, ate a proxima escrita.
    _aba_ant=`cat "${TMP}/pagina" 2>/dev/null`

    # CORRECAO (energia congelada): energia e HP maximo so aparecem em /train
    # e regeneram com o tempo. Sem esta chamada, o painel repetia a energia
    # da ultima entrada em start() — que tem vaos de mais de uma hora —,
    # entao ela parecia travada.
    fetch_train_stats 2>/dev/null

    _pg=`run_curl "${URL}/user" 2>/dev/null`

    # SESSAO CAIDA NO OCIO: RECONECTA EM VEZ DE DESISTIR.
    #
    # Este era o motivo de a conta "aparecer no painel mas nao no jogo". O
    # login_logoff — unica funcao que revalida a sessao — so era chamado
    # dentro do start(), que roda apenas nos minutos da agenda. No ocio, que
    # e a maior parte do tempo, ninguem checava nada: aqui a sessao morta era
    # detectada e a funcao apenas devolvia 1, em silencio.
    #
    # Com a sessao morta o bot continua pedindo paginas, mas o servidor ve um
    # visitante anonimo — a conta NAO aparece online para os outros jogadores.
    # Ela so voltava quando o start() rodava num minuto da agenda e
    # reconectava, o que dava exatamente o sintoma: a conta so aparecia
    # durante os eventos do cronograma.
    #
    # Com muitas contas isso e bem mais frequente, porque o servidor derruba
    # sessao com mais facilidade quando ha varias do mesmo IP.
    #
    # So reconecta com a pagina do jogo dizendo que a conta saiu. Resposta
    # vazia ou que nao e do jogo e servidor mudo (ver sessao_estado).
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
        unset _pg _aba_ant
        return 1
    fi
    _a=`extract_username "$_pg"`
    [ -n "$_a" ] && ACC="$_a"
    parse_status "$_pg"
    messages_info
    date +%s > "$TMP/last_stats" 2>/dev/null
    printf %s "$_aba_ant" > "${TMP}/pagina" 2>/dev/null
    unset _pg _a _aba_ant
}

# MASMORRA DO CLA: QUEM DECIDE E A PAGINA, NAO O RELOGIO.
#
# CORRECAO: a masmorra era a UNICA atividade presa a uma hora fixa do dia.
# O portao masmorra_na_janela so deixava passar nas horas 02, 10 e 18 e,
# junto com ele, a execucao era marcada como cumprida mesmo quando nenhum
# golpe saia. Bastava a conta estar ocupada, a pagina falhar ou o link nao
# ser reconhecido dentro daquela hora para a janela inteira de 8h ser
# perdida em silencio — no jogo os golpes seguiam disponiveis e o bot nao
# voltava la. E exatamente o sintoma relatado: a atividade disponivel, a
# conta passando por ali e nada sendo feito.
#
# Agora o marcador guarda a PROXIMA TENTATIVA, e ela depende do resultado:
#
#   masmorra_marcar   golpe saiu -> volta quando o relogio da pagina zerar
#   masmorra_adiar    nao saiu   -> idem; sem relogio, FUNC_masmorra_min
#
# O RELOGIO E O DA PAGINA. Gastos os 10 golpes, o jogo mostra quando voltam:
#
#   Não há mais golpes<br/><span class='grey medium'>+10 golpes em
#   <span id='time_28800000'>08:00:00</span></span>
#
# (as 17 contas em 13/09, logo depois dos golpes: 28800000 ms = 8h). Antes o
# bot voltava em 7h e, dali, a cada 45 min ate achar golpe — numa conta,
# 17:23 e 18:08 foram visitas a toa antes dos golpes das 18:54.
masmorra_liberada() {
    # A chave existia no config.cfg desde sempre e NINGUEM a lia: quem
    # desligasse a masmorra ali continuava com ela ligada.
    [ "${FUNC_masmorra:-y}" = "y" ] || return 1
    _u=`cat "$TMP/next_masmorra" 2>/dev/null`
    case "$_u" in ''|*[!0-9]*) _u=0 ;; esac
    # Mais de 2 dias adiante nao e relogio do jogo (ver relogio_liberado).
    _u=$(( _u - `date +%s` ))
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
    echo $(( `date +%s` + _ms + 60 )) > "$TMP/next_masmorra" 2>/dev/null
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
#  CAVERNA. O menu da pagina inicial — que o descansar() ja baixa ao fim de
#  cada ciclo — diz quanto falta:
#
#     <a href='/cave/'>... Caverna <span class='grey'>(21:04)</span></a>
#     <a href='/cave/'>... Caverna<span class='green'> (+)</span></a>
#
#  Em 13/09 as contas mostravam de (16:33) a (46:06): nao ha um tempo fixo.
#  O bot entrava a cada 20-30 min e quase sempre saia com "Cave limit
#  reached" (mineracao em andamento). Agora entra quando o menu da (+) ou o
#  relogio zera. Sem leitura do menu, volta ao intervalo de 20 min.
#
#  CAMPANHA. A pagina da campanha, feita, mostra "Nova campanha em 7 h 38
#  min" — uma a cada 8h. O bot olhava a cada 15 min. Agora le esse relogio;
#  sem ele, concluida a campanha, espera as 8h.
#
#     $TMP/next_caverna   $TMP/next_campanha   (epoch em que a atividade volta)
# ---------------------------------------------------------------------------

# "(21:04)" ou "(1:02:03)" -> segundos
relogio_segundos() {
    printf '%s\n' "$1" | awk -F: '
        NF == 2 { print $1 * 60 + $2; exit }
        NF == 3 { print $1 * 3600 + $2 * 60 + $3; exit }'
}

relogio_liberado() { # nome -> 0 se o relogio da atividade venceu
    _rl=`cat "$TMP/next_$1" 2>/dev/null`
    case "$_rl" in ''|*[!0-9]*) unset _rl; return 2 ;; esac
    # Nenhum relogio do jogo passa de 1 dia. Mais de 2 dias adiante e marca
    # gravada com o relogio do aparelho errado (o WSL ja pulou anos para a
    # frente): vale como vencido, senao a atividade fecharia ate aquela data.
    _rl=$(( _rl - `date +%s` ))
    if [ "$_rl" -le 0 ] || [ "$_rl" -gt 172800 ]; then unset _rl; return 0; fi
    unset _rl
    return 1
}

relogio_anotar() { # nome segundos
    case "$2" in ''|*[!0-9]*) return 1 ;; esac
    echo $(( `date +%s` + $2 )) > "$TMP/next_$1" 2>/dev/null
}

# Le o relogio da caverna no menu da pagina inicial ($1). Sem menu (pagina
# de luta, erro do servidor), nao mexe no que ja estava anotado. O padrao nao
# sai do link da caverna: o item seguinte do menu (Rei dos Imortais) tambem
# tem relogio entre parenteses.
caverna_ler_menu() {
    _cv=`grep -o -E "href='/cave/'>(<img[^>]*>)?[^<()]*<span class='grey'>\\(([0-9]{1,2}:)?[0-9]{1,2}:[0-9]{2}\\)" "$1" 2>/dev/null \
         | head -n 1 | grep -o -E '([0-9]{1,2}:)?[0-9]{1,2}:[0-9]{2}\)$' | tr -d ')'`
    if [ -n "$_cv" ]; then
        relogio_anotar caverna $(( `relogio_segundos "$_cv"` + 30 ))
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
# menu, vale o intervalo antigo — se a pagina inicial nao vier, a caverna nao
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

# Tarefas que NAO dependem da agenda de eventos.
#
# A arena deve sair a cada 30 minutos, mas o start() so era chamado nos
# minutos da agenda — que tem vaos de 60 a 120 minutos, e nenhum durante
# as 4 horas do Coliseu. Medido em producao: a arena saia a cada ~52
# minutos, e contas recem-cadastradas ficavam com 1 unica execucao
# enquanto as antigas tinham 9.
#
# Aqui tambem entra o CHECKLIST DE MISSOES DO CLA. Durante a janela do
# Coliseu o bot passa a pausar entre as lutas para conferir a lista:
# recolhe as concluidas, apoia as dos companheiros e conclui com ouro as
# que estao paradas. Antes, essas quatro horas passavam sem nada disso.
#
# Cada bloco tem temporizador proprio, entao rodar a cada volta do laco
# (~1 min) nao significa executar a cada minuto.
#
# NAO e chamado durante os cinco eventos de prioridade: enquanto a conta
# esta aplicada num deles nada mais deve competir. Ao terminar o evento,
# o start() chama esta mesma varredura (so o que venceu o proprio portao).
tarefas_livres() {
    [ -n "$CLD" ] || clan_id 2>/dev/null

    # --- Numeros do painel, a cada 3 min
    if stats_liberado; then
        atualiza_stats 2>/dev/null
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

    # --- Masmorra do cla
    #
    # Sem hora marcada: a pagina diz se ha golpe. Deu certo, so volta na
    # proxima leva de 8h; nao deu, volta em minutos.
    if [ -n "$CLD" ] && masmorra_liberada; then
        if clanDungeon; then masmorra_marcar; else masmorra_adiar; fi
    fi

    # --- Arena, sempre tomando antes a missao do cla que ela completa
    if arena_liberada; then
        cq_antes arena 2>/dev/null
        arena_duel
        arena_marcar
    fi

    # --- Carreira, campanha, caverna e cabana do sabio: executa o que
    # estiver disponivel sem esperar os minutos :00/:30 do start(). Cada
    # uma so refaz apos o proprio intervalo (marcador em disco), entao a
    # varredura e barata. As proprias funcoes ja saem rapido quando nao ha
    # nada disponivel (sem link = sem acao).
    if ativ_liberada carreira 15; then
        cq_antes carreira 2>/dev/null
        career_func
        ativ_marcar carreira
    fi

    if campanha_liberada; then
        campaign_func
    fi

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
    # CORRECAO: estas quatro so existiam dentro do start(), que roda apenas
    # nos minutos exatos da agenda. Quando um evento de prioridade vencia o
    # case, ou quando o minuto simplesmente nao estava na lista, elas ficavam
    # de fora — a Liga chegava a passar o dia sem lutar. Agora tambem entram
    # na varredura ociosa, cada uma no seu intervalo.
    #
    # UMA VISITA POR DIA, AS 00:30 (liga_do_dia, em league.sh). Aqui ela so
    # volta antes disso quando uma luta nao contou e ainda ha lutas no dia.
    if ativ_liberada liga 30; then
        liga_do_dia
    fi

    # O func_trade tem portao proprio de uma vez ao dia, entao esta chamada
    # sai barata nas demais voltas; o intervalo aqui e so para nao reabrir a
    # pagina da troca a cada minuto.
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

    # --- Lista de aliados, a cada 12h
    #
    # Sem isto as listas ficavam VAZIAS para sempre: o worker nao tem
    # teclado para perguntar o modo. As cinco batalhas de cla liam a lista
    # a cada golpe e ela nunca tinha ninguem dentro.
    #
    # 12h porque a lista muda de vez em quando: sao as paginas de amigos e as
    # de membros do cla (ver allies.sh).
    #
    # A chave e "aliados2": a lista mudou de regra (amigos + cla, sempre os
    # dois), e a conta que atualizar o bot refaz a sua no primeiro intervalo,
    # sem esperar as 12h da lista velha.
    if ativ_liberada aliados2 720; then
        if allies_refresh 2>/dev/null; then
            ativ_marcar aliados2
        else
            # Pagina que nao respondeu: nova tentativa em 30 min, nao em 12h.
            echo $(( `date +%s` - 690 * 60 )) > "$TMP/last_aliados2" 2>/dev/null
        fi
    fi
}

# Arena a cada 30 minutos, controlada por marcador em disco para
# sobreviver a reinicios do worker.
arena_liberada() { ativ_liberada arena "${FUNC_arena_min:-30}"; }
arena_marcar() { date +%s > "$TMP/last_arena" 2>/dev/null; }

# Varredura periodica de atividades no ciclo ocioso.
#
# O sweep completo (start) so roda em :00 e :30. Entre esses minutos o bot
# ficava esperando, mesmo com carreira/campanha/caverna/cabana disponiveis.
# Agora o tarefas_livres tambem verifica e executa essas atividades, cada
# uma no seu proprio intervalo (marcador last_<nome> em disco, por conta,
# como a arena) — assim executa o que estiver disponivel sem esperar o :00/
# :30 e sem refazer a cada minuto (o que pesaria no Android/E22). O start()
# chama o proprio tarefas_livres, entao ha um so conjunto de portoes.
ativ_liberada() {
    _an="$1"; _am="${2:-15}"
    case "$_am" in ''|*[!0-9]*) _am=15 ;; esac
    # read (interno do shell) no lugar do cat: um processo a menos por
    # portao, uns 12 por volta do laco — conta no limite de 32 do Android.
    _au=; { read -r _au < "$TMP/last_$_an"; } 2>/dev/null
    case "$_au" in ''|*[!0-9]*) _au=0 ;; esac
    # Marcador no futuro (relogio do aparelho voltou, NTP no Android): vencido.
    _au=$(( $(date +%s) - _au ))
    if [ "$_au" -lt 0 ] || [ "$_au" -ge $((_am * 60)) ]; then
        unset _an _am _au; return 0
    fi
    unset _an _am _au; return 1
}
ativ_marcar() { date +%s > "$TMP/last_$1" 2>/dev/null; }

# ============================================================
#  PERIODO DEDICADO AO EVENTO
#
#  Durante os cinco eventos de prioridade — Torneio dos Clas, Coliseu do
#  Cla, Altares, Rei dos Imortais e Vale dos Imortais — nenhuma atividade
#  comum deve rodar: da inscricao ate o fim do evento a conta e so daquilo.
#
#  A varredura (tarefas_livres) ja nao e chamada nesses ramos do run.sh, e
#  enquanto o modulo do evento esta lutando ele bloqueia, entao nada mais
#  acontece. O furo esta no RETORNO ANTECIPADO: quando a conta cai da luta
#  antes da hora — o que se via no painel como a conta trocando o evento por
#  "Cla" no meio do horario —, o modulo devolve o controle e o start() logo
#  abaixo dispara a varredura inteira COM O EVENTO AINDA EM ANDAMENTO.
#
#  Aqui o inicio do evento e anotado antes de entrar, e depois do modulo a
#  conta espera o evento terminar antes de voltar as atividades. Durante a
#  espera ela descansa na pagina inicial, o que ainda mantem a sessao viva.
# ============================================================

# Epoch do inicio do evento: o proximo :00 ou :30 a partir de agora.
# Os ramos de prioridade entram em :55-:59 (evento em :00) ou :25-:29
# (evento em :30), entao a conta e direta.
evento_dedicar() {
    _ed_m=`date +%M | sed 's/^0//'`
    case "$_ed_m" in ''|*[!0-9]*) _ed_m=0 ;; esac
    _ed_s=`date +%S | sed 's/^0//'`
    case "$_ed_s" in ''|*[!0-9]*) _ed_s=0 ;; esac
    if   [ "$_ed_m" -ge 50 ]; then _ed_f=$(( 60 - _ed_m ))
    elif [ "$_ed_m" -ge 20 ] && [ "$_ed_m" -lt 30 ]; then _ed_f=$(( 30 - _ed_m ))
    else _ed_f=0
    fi

    # ENTRADA ESCALONADA ENTRE AS CONTAS — MAS NUNCA A CUSTA DA JANELA.
    #
    # Todas as contas aplicam no MESMO segundo: o ramo do run.sh dispara no
    # mesmo minuto para todas, e o modulo pede /enterGame na hora. Do lado do
    # servidor sao N inscricoes simultaneas do mesmo IP — o mesmo padrao de
    # rajada que ja obrigou a serializar o login.
    #
    # CORRECAO (conta saindo do evento): a primeira versao dormia antes de
    # olhar o relogio. Cada modulo RE-VERIFICA a janela por dentro — o
    # king_start so age em 12:2[5-9] —, entao uma conta que entrasse em
    # 12:29:52 acordava em 12:30:01 e o modulo devolvia sem fazer nada. Em
    # seguida o evento_espera assumia e ficava chamando descansar por dez
    # minutos: no painel a conta aparecia na Pagina Principal bem no meio do
    # evento, como se tivesse abandonado.
    #
    # Agora o deslocamento e limitado pelo tempo que AINDA RESTA de janela,
    # com 5 segundos de folga. Perto do fim ele simplesmente nao acontece.
    _ed_resta=$(( _ed_f * 60 - _ed_s - 5 ))
    _ed_esp=$(( $$ % 10 ))
    [ "$_ed_esp" -gt "$_ed_resta" ] && _ed_esp=0
    [ "$_ed_esp" -gt 0 ] && sleep "$_ed_esp"

    # O "- _ed_esp" desconta a espera: o _ed_f foi medido antes de dormir.
    echo $(( `date +%s` + _ed_f * 60 - _ed_esp )) > "$TMP/em_evento" 2>/dev/null
    unset _ed_m _ed_s _ed_f _ed_resta _ed_esp
}

# Desiste da dedicacao ao evento.
#
# O modulo que decide NAO participar (Coliseu do Cla fora de temporada, por
# exemplo) chama isto: sem o marcador, o evento_espera devolve na hora e a
# conta volta para a rotina em vez de ficar dez minutos parada por um evento
# que nao vai acontecer.
evento_cancelar() {
    rm -f "$TMP/em_evento" 2>/dev/null
    # Sem inscricao nao ha batalha a retomar.
    batalha_limpar 2>/dev/null
    return 0
}

# Segura a conta ate o evento acabar. Volta na hora se o modulo ja tiver
# consumido o tempo todo lutando, que e o caso normal.
#
# A duracao vem de FUNC_evento_min (padrao 10). Se os eventos do seu
# servidor durarem mais ou menos que isso, e so ajustar essa chave no
# config.cfg da conta — nao ha como o bot descobrir a duracao sozinho.
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

# Apaga os marcadores de combate ao vivo deixados no disco.
#
# Os modulos de batalha (king, altares, torneio, masmorra, bandeiras,
# coliseu do cla) gravam HP/old_HP/FULL/USH no diretorio da conta durante a
# luta, e o painel os le para desenhar o "ao vivo das batalhas". Eles NAO
# eram apagados ao fim da luta, entao o painel continuava mostrando
# "-142 de dano recebido" com a conta ja parada na pagina inicial —
# combate fantasma. Apagados aqui (no descanso), o ao vivo passa a refletir
# apenas batalha de verdade em andamento.
limpar_combate() {
    rm -f "$TMP/HP" "$TMP/old_HP" "$TMP/FULL" "$TMP/USH" 2>/dev/null
}

# Volta para a batalha pendente desta conta, se houver.
#
# Cobre as contas que saem do laco de luta sem o jogo declarar o fim: o
# worker morto pelo Android e relancado pelo painel, ou um modulo que
# devolveu o controle cedo. Em vez de cair na rotina — e no "Fuja da
# batalha" —, a conta rele a pagina do evento e segue lutando.
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
        king|clanfight|clandmgfight|altars) _br_full="$TMP/FULL" ;;
        clancoliseum) _br_full="$TMP/ccol_full" ;;
        flagfight)    _br_full="$TMP/flag_full" ;;
        *)            _br_full="" ;;
    esac
    if [ -n "$_br_full" ] && [ ! -s "$_br_full" ]; then
        SLS_MAXTIME=17
        run_curl "$URL/train" 2>/dev/null | grep -o -E '\(([0-9]+)\)' \
            | head -n 1 | tr -d '()' > "$_br_full"
        unset SLS_MAXTIME
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
        coliseum)
            # O coliseum_fight tambem INSCREVE: chamado com a luta ja
            # encerrada, ele entraria numa luta NOVA — ate fora da janela
            # das 00:30-04:30. Na retomada ele so roda se a pagina mostrar
            # luta em andamento.
            fetch_page "/coliseum" "$TMP/col_src"
            case "`estado_luta "$TMP/col_src" coliseum`" in
                luta)      coliseum_fight ;;
                # Sem sessao nao da para saber: fica para depois de reconectar.
                deslogado) LUTA_SESSAO_CAIU=1 ;;
            esac
            ;;
        *)            : ;;
    esac

    # UMA TENTATIVA POR BATALHA ANOTADA.
    #
    # A funcao de luta que termina pelo jogo ja apaga a anotacao. Se ela voltou
    # sem isso — o coliseu sem luta para retomar, o teto de seguranca —, a
    # anotacao ficava, e CADA volta do laco (sls_play) e cada descanso tentavam
    # retomar de novo, por ate 30 minutos. So a queda de sessao mantem a
    # anotacao: e o caso em que a luta deve continuar quando a sessao voltar.
    [ "${LUTA_SESSAO_CAIU:-0}" = 1 ] || batalha_limpar
    unset _br_full
    _BR_ATIVO=0
    return 0
}

# Volta para a pagina inicial. As contas devem descansar ali entre os
# ciclos, e nao numa pagina de combate ou de evento — o jogo mantem o
# personagem "em batalha" e a navegacao seguinte cai em "Fuja da batalha".
descansar() {
    # ANTES DE IR PARA CASA: HA BATALHA PENDENTE?
    #
    # O evento_espera chama o descansar de 30 em 30s logo depois do modulo de
    # luta, e o start()/func_cat ao fim de cada ciclo. Com batalha pendente,
    # a conta volta para ela em vez de ir para a Home.
    batalha_retomar

    # HOME REPETIDA NAO E PEDIDA DE NOVO.
    #
    # Perto das janelas de evento o laco ocioso volta a cada 15s, e cada volta
    # pedia a Home: numa conta, em 13/09, foram 641 dessas voltas, quatro
    # Homes por minuto. Se a ultima pagina pedida ja foi a Home e ESTE descanso
    # a confirmou com sessao viva ha menos de 50s, a leitura anterior ainda
    # vale: a conta esta em casa e nada foi pedido desde entao. A volta de 60s
    # pede sempre.
    #
    # A prova e o $TMP/.home_ok, gravado so no fim feliz do descanso. O
    # last_ok nao serve: as lutas e o link_acao tambem o carimbam, e ai uma
    # Home que falhou (servidor mudo) ou que mostrou o personagem ainda preso
    # na batalha passaria por "em casa e tudo certo".
    # ponytail: a queda de sessao pode levar ate 50s a mais para ser vista.
    _ds_req=; _ds_ok=0
    { read -r _ds_req < "$TMP/.ult_req"; read -r _ds_ok < "$TMP/.home_ok"; } 2>/dev/null
    case "$_ds_ok" in ''|*[!0-9]*) _ds_ok=0 ;; esac
    _ds_ok=$(( `date +%s` - _ds_ok ))
    # Diferenca negativa = relogio voltou: nao prova nada, pede a Home.
    if [ "$_ds_req" = "/" ] && [ "$_ds_ok" -ge 0 ] && [ "$_ds_ok" -lt 50 ]; then
        unset _ds_req _ds_ok
        return 0
    fi
    unset _ds_req _ds_ok

    fetch_page "/" "$TMP/REST" 2>/dev/null

    # "FUJA DA BATALHA" SO DEPOIS DE O JOGO DECLARAR O FIM.
    #
    # Aqui havia um /?out_gate_confirm=true INCONDICIONAL, a cada descanso:
    # a confirmacao de fuga. Toda conta que saia do laco de luta antes da
    # hora — rede, sessao, SIGKILL — fugia da batalha na chamada seguinte.
    #
    # Agora a Home e pedida primeiro. So se o jogo ainda segurar o
    # personagem (a pagina oferece o out_gate_confirm) E nao houver batalha
    # pendente — ou seja, o jogo ja declarou a morte ou o fim, ou a pagina do
    # evento passou LUTA_FORA_MAX segundos sem luta (LUTA_FORA_LUTOU se a conta
    # ja tinha lutado) — a saida e confirmada.
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

    # SESSAO CONFERIDA AQUI, DE GRACA.
    #
    # Esta pagina ja foi baixada acima e era descartada sem ninguem olhar.
    # Ela diz na hora se a sessao esta viva, entao a checagem nao custa
    # nenhuma requisicao nova.
    #
    # Antes a sessao so era verificada pelo atualiza_stats, a cada 3 minutos
    # e ao preco de duas requisicoes extras (/train e /user). No intervalo, a
    # conta seguia pedindo paginas com cookie morto: o servidor a via como
    # visitante anonimo e ela NAO aparecia online para os outros jogadores,
    # embora o painel a mostrasse rodando — porque o worker estava vivo.
    #
    # Como o descansar() roda ao fim de cada ciclo, a janela em que a conta
    # fica invisivel cai de ~3 minutos para ~1, sem custo.
    #
    # SERVIDOR MUDO NAO E SESSAO CAIDA. Pagina vazia, cortada ou que nao e
    # do jogo nao prova que a conta saiu: tratar como queda apagava o cookie
    # e refazia o login no pior momento (ver sessao_estado, em info.sh). A
    # sessao fica como esta e o proximo descanso confere de novo.
    case "`sessao_estado "$TMP/REST"`" in
        viva)
            _ds_ok=`date +%s`
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

    # NAO RECONECTA EM BLOCO.
    #
    # Com muitas contas no mesmo IP, uma queda costuma atingir varias ao
    # mesmo tempo — e se todas reconectam juntas, o servidor estrangula a
    # rajada e ainda pode derrubar sessao de quem estava bem, criando um
    # ciclo em que as contas se expulsam uma a outra. E o padrao que aparece
    # como "algumas online, outras nao, alternando".
    #
    # O intervalo minimo entre tentativas leva um deslocamento fixo por
    # conta, derivado do PID: cada uma tenta num segundo diferente dentro da
    # janela, em vez de todas no mesmo instante. Sem isso o intervalo apenas
    # adia a rajada, nao a dispersa. O descanso e a luta usam o mesmo portao
    # (luta_pode_reconectar, em info.sh), entao as duas nao somam tentativas.
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
    # UMA VARREDURA POR MINUTO.
    #
    # No minuto :30 a espera do func_sleep e de 15s (janela do Coliseu do
    # Cla). Quando a varredura acabava antes de :30:45, o laco voltava ao
    # ramo das :30 e rodava tudo de novo — medido numa conta em 13/09:
    # carreira, caverna, liga e campanha duas vezes as 17:30 e as 18:30. A
    # segunda chamada no mesmo minuto so espera o minuto virar.
    _st_min=`date +%Y%m%d%H%M`
    if [ "`cat "$TMP/last_start" 2>/dev/null`" = "$_st_min" ]; then
        _st_s=`date +%S | sed 's/^0//'`
        case "$_st_s" in ''|*[!0-9]*) _st_s=0 ;; esac
        unset _st_min
        espera_interrompivel $(( 60 - _st_s ))
        unset _st_s
        return 0
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

    # CLAN_ID DUPLICADO.
    #
    # O login_logoff, chamado logo acima, ja executa o clan_id quando a
    # sessao esta viva — e o clan_id vai a rede sempre, sem guarda nenhuma.
    # O `||` mantem o caminho para quando o login_logoff nao existe ou nao
    # chegou a rodar.
    [ -n "$CLD" ] || clan_id 2>/dev/null

    # Lider do cla: mantem a estatua ativa (bonus de PRATA e de OURO do cla,
    # pagos pela tesouraria do cla; o Bonus Pessoal, que gasta o ouro da
    # conta, nunca e ativado). Portao proprio de 6h (estatua_liberada).
    clan_statue

    # Agenda oficial do jogo (painel) e elixir das batalhas: so aqui, uma vez
    # por varredura das :00/:30. 25 min deixa passar as duas.
    if ativ_liberada agenda 25; then
        atualiza_agenda 2>/dev/null
        ativ_marcar agenda
    fi
    if ativ_liberada elixir 25; then
        cq_antes elixir 2>/dev/null
        use_elixir
        ativ_marcar elixir
    fi

    # O RESTO E A VARREDURA DO OCIOSO, COM OS MESMOS PORTOES.
    #
    # Eram duas copias das mesmas atividades, e a do start() nao conferia
    # portao nenhum. Quando o Coliseu do Cla ou o Torneio nao tinha
    # inscricao, o ramo do evento chamava o start() a cada minuto da janela:
    # numa conta, 13/09 10:25 e 10:26, carreira, missoes, eventos e
    # missoes do cla refeitas em sequencia. Agora cada atividade so volta no
    # proprio intervalo (ou pelo relogio do jogo) e o RUNNOW libera todas.
    tarefas_livres

    messages_info
    descansar
    func_crono
    func_sleep
}
