#!/bin/sh

# CORRECAO: versionNum era definido apenas DENTRO de script_slogan(),
# funcao que nunca e chamada no fluxo do worker. Resultado: o messages_info
# imprimia "solucaoshell v | ..." com a versao vazia.
versionNum="3.9.45"
# Aguarda o ultimo job em background terminar, ate N segundos.
#
# CORRECAO: a versao original rodava dentro de ( ... ) e extraia o PID com
#   TEFPID=`echo "$!" | grep -o -E '([0-9]{2,6})'`
# A regex trunca PIDs com 7+ digitos (pid_max pode chegar a 4194304), o que
# fazia o kill acertar um processo QUALQUER do usuario. Agora usa $! direto.
# O "sleep antes do teste" foi mantido de proposito: ele impoe ~1s de
# espacamento entre requisicoes, que e um limitador de taxa natural.
time_exit() {
    TEFPID=$!
    [ -z "$TEFPID" ] && return 0

    # Espacamento deliberado entre requisicoes: limitador de taxa natural,
    # herdado da versao original (que o obtinha do primeiro "sleep 1" do
    # laco de espera).
    #
    # CORRECAO: este "sleep" ignorava o SLS_PACING, a chave que o play.sh ja
    # liga sozinho no Termux acima de 3 contas justamente para nao deixar um
    # processo parado por requisicao. O fetch_page a respeitava; o time_exit,
    # nao — e e ele que serve TODO o codigo de batalha, que e onde o pico de
    # processos acontece. Com 6 contas em evento eram 6 "sleep" parados que a
    # configuracao mandava nao existir.
    #
    # Com SLS_PACING=0 quem espaca as requisicoes e o proprio tempo de ida e
    # volta ao servidor (meio segundo a dois), como o comentario do fetch_page
    # ja documentava. Fora do Termux o padrao continua 1.
    _te_pace="${SLS_PACING:-1}"
    case "$_te_pace" in ''|*[!0-9]*) _te_pace=1 ;; esac
    [ "$_te_pace" -gt 0 ] && sleep "$_te_pace"
    unset _te_pace

    # CORRECAO CRITICA (SIGKILL / "signal 9" no Android 12+):
    #
    # A versao anterior esperava com
    #     while [ n -lt 17 ]; do sleep 1; kill -0 PID; done
    # ou seja ate 17 forks de /bin/sleep POR REQUISICAO, mais o subshell e
    # o curl. Cada conta faz dezenas de requisicoes por ciclo; com 6 contas
    # em paralelo a arvore de processos do Termux passa facilmente dos 32
    # processos "fantasma" que o Android 12+ tolera — e o sistema responde
    # matando a sessao inteira com SIGKILL, sem aviso. E exatamente o
    # "[Process completed (signal 9)]" que aparece no meio do lancamento.
    #
    # O prazo agora e imposto pelo proprio curl (--max-time, em run_curl),
    # entao o processo em segundo plano TEM hora marcada para morrer e
    # basta um "wait" — que nao cria processo nenhum.
    #
    # O argumento continua sendo aceito por compatibilidade com os 100+
    # pontos de chamada, mas quem corta agora e o curl. Nos pontos que
    # chamam run_curl direto o prazo passa de 17s para os 45s padrao do
    # run_curl; o --connect-timeout de 15s ja cobre o caso comum (servidor
    # fora do ar) e o valor maior foi mantido de proposito para nao
    # apertar o login, que e a parte mais fragil do fluxo. Quem precisar
    # de prazo curto define SLS_MAXTIME antes da chamada, como o
    # fetch_page faz.
    wait "$TEFPID" 2>/dev/null
    _te_rc=$?

    # 28 = CURLE_OPERATION_TIMEDOUT.
    if [ "$_te_rc" = "28" ]; then
        printf "timeout: requisicao abortada\n" >> "${TMP:-.}/ERROR_DEBUG"
        unset _te_rc
        return 1
    fi
    unset _te_rc
    return 0
}

# Funcao central de requisicao via curl.
#
# CORRECOES:
#  --proto/--proto-redir : impede que um redirect leve a requisicao (e o
#                          corpo do POST de login) para fora de HTTPS.
#  --max-redirs          : limita cadeia de redirecionamento.
#  --connect-timeout /
#  --max-time            : sem isso, um socket pendurado travava o worker
#                          para sempre (as chamadas de login sao sincronas).
#                          O valor agora sai de $SLS_MAXTIME (45s por
#                          padrao): antes era fixo e o corte real de 17s
#                          vinha do laco de "sleep 1" do time_exit. Quem
#                          impoe o prazo passa a ser o curl; o time_exit so
#                          espera, sem gastar processo.
#  -sS em vez de -s      : mantem silencio de progresso MAS mostra erros,
#                          que antes eram engolidos ("parou e nao sei por que").
#
# Registra em $TMP/pagina o caminho da requisicao que esta saindo.
#
# CORRECAO (painel "ATIVIDADE EM CONJUNTO" congelado): esse registro ficava
# dentro do fetch_page, com o comentario "como todo acesso passa por aqui,
# basta uma linha para cobrir o jogo inteiro". Nao passa. allies.sh,
# altars.sh, arena.sh, clancoliseum.sh, clandmg.sh, clanfight.sh,
# coliseum.sh, flagfight.sh, king.sh, loginlogoff.sh e undying.sh — ou seja
# TODO o codigo de batalha, mais de 100 pontos de chamada — usam run_curl
# direto e nunca tocavam nesse arquivo.
#
# Como o unico fetch_page do fim do ciclo e o descansar(), que volta para
# "/", o painel lia "/" e mostrava "Pagina Principal" praticamente o tempo
# todo, sem nunca acompanhar a batalha em andamento. Registrando aqui, no
# unico ponto por onde TODA requisicao passa de verdade, a coluna passa a
# seguir a conta ao vivo.
_rc_track() {
    [ -n "$TMP" ] || return 0
    [ -n "$URL" ] || return 0
    # $TMP/.ult_req: a ULTIMA requisicao de verdade. Diferente do $TMP/pagina,
    # que o atualiza_stats restaura para o painel, este ninguem reescreve —
    # e o que o cq_pagina consulta para saber se algo saiu depois da leitura
    # guardada.
    for _rc_a in "$@"; do
        case "$_rc_a" in
            "$URL")
                printf %s "/" > "$TMP/pagina" 2>/dev/null
                printf %s "/" > "$TMP/.ult_req" 2>/dev/null
                unset _rc_a
                return 0
                ;;
            "$URL"/*|"$URL"\?*)
                _rc_pp=${_rc_a#"$URL"}
                printf %s "$_rc_pp" > "$TMP/pagina" 2>/dev/null
                printf %s "$_rc_pp" > "$TMP/.ult_req" 2>/dev/null
                unset _rc_a _rc_pp
                return 0
                ;;
        esac
    done
    unset _rc_a
    return 0
}

_rc_run() {
    _rc_mode="$1"
    shift

    case "$URL" in
        http://*) _rc_p="--proto =http,https --proto-redir =http,https" ;;
        *)        _rc_p="--proto =https --proto-redir =https" ;;
    esac

    # PRAZO DAS PAGINAS DE BATALHA: 17s, NAO 45s.
    #
    # Todo o codigo de luta chama "time_exit 17", mas desde que o prazo passou
    # para o curl esse 17 e ignorado e a luta esperava os 45s padrao. Nos
    # logs de 12/09 o Coliseu de tres contas enfileirou 107 requisicoes sem
    # resposta — a 45s cada, pulsos de 13 a 23 minutos. Resposta de acao de
    # luta que chega depois de 17s ja nao serve: a luta andou, e o laco rele
    # a pagina de qualquer jeito. Login, /train e o resto seguem com 45s.
    #
    # Sem processo novo: so case e expansao do shell (teto de 32 processos do
    # Android 12). SLS_MAXTIME, quando definido, continua valendo por cima.
    _rc_mt="$SLS_MAXTIME"
    if [ -z "$_rc_mt" ]; then
        _rc_mt=45
        for _rc_a in "$@"; do
            case "$_rc_a" in
                "$URL"/*)
                    _rc_pp=${_rc_a#"$URL"/}
                    _rc_pp=${_rc_pp%%[/?]*}
                    case "$_rc_pp" in
                        king|undying|altars|clanfight|clandmgfight|clancoliseum|flagfight|coliseum)
                            _rc_mt="${SLS_LUTA_MAXTIME:-17}" ;;
                    esac
                    break
                    ;;
            esac
        done
        unset _rc_a _rc_pp
    fi
    case "$_rc_mt" in ''|*[!0-9]*) _rc_mt=45 ;; esac

    _rc_track "$@"

    # shellcheck disable=SC2086
    if [ "$_rc_mode" = "exec" ]; then
        if [ -n "$TMP_COOKIE" ]; then
            exec curl -sS -L --compressed --max-redirs 5 \
                 --connect-timeout 15 --max-time "$_rc_mt" \
                 $_rc_p -A "$vUserAgent" \
                 -c "$TMP_COOKIE" -b "$TMP_COOKIE" "$@"
        else
            exec curl -sS -L --compressed --max-redirs 5 \
                 --connect-timeout 15 --max-time "$_rc_mt" \
                 $_rc_p -A "$vUserAgent" "$@"
        fi
    fi

    # shellcheck disable=SC2086
    if [ -n "$TMP_COOKIE" ]; then
        curl -sS -L --compressed --max-redirs 5 \
             --connect-timeout 15 --max-time "$_rc_mt" \
             $_rc_p -A "$vUserAgent" \
             -c "$TMP_COOKIE" -b "$TMP_COOKIE" "$@"
    else
        curl -sS -L --compressed --max-redirs 5 \
             --connect-timeout 15 --max-time "$_rc_mt" \
             $_rc_p -A "$vUserAgent" "$@"
    fi
}

# Uso normal: roda o curl como filho e devolve a saida.
run_curl() { _rc_run "" "$@"; }

# Uso em segundo plano: SUBSTITUI o processo pelo curl, em vez de deixar um
# shell parado esperando por ele.
#
# CORRECAO (SIGKILL / "signal 9"): "run_curl ... &" forka um shell que so
# serve para lancar o curl e esperar — dois processos onde um basta. Com o
# exec o filho VIRA o curl (comprovado: sem exec ficam dash+sleep, com exec
# fica so o sleep).
#
# Isso importa porque o Android 12+ mata a sessao inteira acima de 32
# processos filhos, e a conta estava justamente no limite:
#     13 persistentes (play.sh + 6 worker.sh + 6 sls.sh)
#   + 6 x 3 por requisicao (subshell + curl + sleep)  = 31
# Qualquer grep de parsing que nascesse junto estourava. Sem o subshell:
#     13 + 6 x 2 = 25, com folga para os processos transitorios.
run_curl_exec() { _rc_run "exec" "$@"; }

# Acessa qualquer pagina pelo caminho relativo.
#
# CORRECAO (SIGKILL / "signal 9"): a espera era feita com time_exit, que
# sondava com "sleep 1" — subshell + curl + ate 17 forks de sleep, ou seja
# ate 19 processos POR PAGINA. Com 6 contas e dezenas de paginas por ciclo,
# o limite de processos "fantasma" do Android 12+ era estourado e a sessao
# do Termux inteira morria com SIGKILL.
#
# Agora sao 3 processos fixos por pagina (subshell + curl + o sleep de
# espacamento) e o prazo e imposto pelo proprio curl. Medido em 10 paginas
# contra um servidor de 2,5s: 30 forks de sleep antes, 10 depois, no mesmo
# tempo total. De quebra o codigo passa a saber POR QUE a requisicao
# falhou, em vez de so "acabou o tempo".
fetch_page() {
    relative_url="$1"
    output_file="${2:-$TMP/SRC}"

    SLS_MAXTIME=17
    run_curl_exec "${URL}${relative_url}" > "$output_file" 2>/dev/null &
    _fp_pid=$!
    unset SLS_MAXTIME

    # ESPACAMENTO ENTRE REQUISICOES
    #
    # O "sleep 1" fica EM PARALELO com a requisicao, nao depois dela.
    #
    # E o mesmo espacamento minimo de 1s por requisicao que a versao
    # anterior tinha — nela a primeira volta do laco de espera corria
    # junto com o curl. Colocado depois do curl, ele viraria 1s de atraso
    # somado a CADA pagina: com ~90 paginas por ciclo, mais de um minuto
    # perdido por conta, por ciclo. Medido: 10 paginas em 30s (em paralelo)
    # contra 35s (em serie).
    # SLS_PACING=0 dispensa esse processo: o proprio tempo de ida e volta
    # da requisicao (meio segundo a dois no servidor do jogo) ja espaca as
    # chamadas. Vale no Android 12, onde CADA processo conta para o limite
    # de 32 — sao 6 "sleep" parados, um por conta, so para esperar.
    # O play.sh liga isso sozinho quando detecta que o limite aperta.
    _fp_pace="${SLS_PACING:-1}"
    case "$_fp_pace" in ''|*[!0-9]*) _fp_pace=1 ;; esac
    [ "$_fp_pace" -gt 0 ] && sleep "$_fp_pace"

    wait "$_fp_pid" 2>/dev/null
    _fp_rc=$?
    unset _fp_pid _fp_pace

    if [ "$_fp_rc" != "0" ]; then
        printf "curl %s: %s\n" "$_fp_rc" "$relative_url" >> "${TMP:-.}/ERROR_DEBUG"
        unset _fp_rc
        return 1
    fi
    unset _fp_rc
    return 0
}

# ============================================================
#  LEITURA DA PAGINA DE COMBATE — UMA PASSADA SO
#
#  Os modulos de batalha liam o MESMO arquivo 23 vezes por chamada: sete
#  grep, nove sed, dois awk e cinco "$(cat ...)" em substituicao de comando.
#  Como a leitura roda duas ou tres vezes por volta do laco, davam 50 a 70
#  processos por volta, POR CONTA.
#
#  Isso importa no Android 12, onde a sessao inteira e morta acima de 32
#  processos filhos. O pico acontece justamente no evento, quando todas as
#  contas entram no mesmo minuto:
#
#      1 play.sh + 6 workers                       =  7 permanentes
#      6 x (subshell->curl + sleep do time_exit)   = 12
#      6 x ~2 transitorios de parsing              = 12
#                                                    ----
#                                                     31
#
#  Um grep a mais estoura. Aqui um unico awk le a pagina uma vez e grava os
#  mesmos arquivos, com as mesmas expressoes: 23 processos viram 1.
#
#  Uso:  combate_ler SECAO HPER RPER ARQUIVO
#  Saida: imprime "1" se a pagina ainda e de luta, "0" se acabou.
#  Grava: ATK ATKRND DODGE HEAL STONE KINGATK GRASS HP HP2 RHP HLHP
#         no diretorio corrente, como antes.
#  Erva e pedra so sao gravadas quando o botao NAO cobra ouro.
combate_ler() {
    awk -v sec="$1" -v hper="$2" -v rper="$3" '
        function grava(nome, valor) {
            # Mesma saida do "grep | sed > ARQUIVO": vazio quando nao ha
            # match, com quebra de linha no fim quando ha. O "[ -s ARQUIVO ]"
            # dos modulos distingue os dois casos.
            if (valor == "") printf "" > nome
            else             printf "%s\n", valor > nome
            close(nome)
        }
        # RHP e HLHP saiam de "awk BEGIN{printf} > ARQUIVO", ou seja SEM
        # quebra de linha. Manter a diferenca evita mudar o que os modulos
        # que leem esses arquivos ja veem.
        function grava_num(nome, valor) {
            printf "%s", valor > nome
            close(nome)
        }
        { todo = todo $0 " " }
        END {
            # NADA DE {n,m} AQUI.
            #
            # O mawk (o awk do Debian/WSL) aceita intervalos mas nao volta
            # atras: em "/king/at[a-z]{0,3}k[a-z]{3,6}/" ele casa "ran" e
            # desiste em vez de tentar "random" e chegar na barra. Medido —
            # a extracao do ataque aleatorio vinha vazia. Por isso os links
            # sao pegos com uma expressao simples e o VERBO e classificado
            # por comparacao de texto, que funciona em qualquer awk.
            resto = todo
            while (match(resto, "/" sec "/[a-z]+/[?]r[=][0-9]+")) {
                link = substr(resto, RSTART, RLENGTH)
                resto = substr(resto, RSTART + RLENGTH)

                verbo = link
                sub("^/" sec "/", "", verbo)
                sub("/.*$", "", verbo)

                alvo = ""
                if      (verbo == "attack")  alvo = "ATK"
                else if (verbo == "kingatk") alvo = "KINGATK"
                else if (verbo == "dodge")   alvo = "DODGE"
                else if (verbo == "heal")    alvo = "HEAL"
                else if (verbo == "stone")   alvo = "STONE"
                else if (verbo == "grass")   alvo = "GRASS"
                else if (verbo ~ /^at.*k./)  alvo = "ATKRND"

                # ITEM PAGO EM OURO — DESCARTADO.
                #
                # A politica do bot e nao gastar ouro. Na
                # pagina de combate a erva e a pedra sao gratuitas enquanto o
                # jogador tem carga; quando ela acaba, o MESMO botao passa a
                # cobrar, e o preco/icone vem no proprio rotulo, entre o link
                # e o </a>. Nesse caso o link e jogado fora: o modulo le
                # "item indisponivel" e parte para a acao seguinte.
                #
                # A janela e so o rotulo do botao, de proposito. Se fosse a
                # pagina toda, o saldo de ouro do cabecalho apagaria tambem os
                # itens gratuitos. Sem o </a> por perto o item e mantido: na
                # duvida, perder um item de graca e pior que nao usa-lo.
                if (alvo == "GRASS" || alvo == "STONE") {
                    rotulo = substr(resto, 1, 300)
                    corte  = index(rotulo, "</a>")
                    if (corte > 0) {
                        rotulo = substr(rotulo, 1, corte)
                        if (tolower(rotulo) ~ /gold|ouro/) alvo = ""
                    }
                }

                # Primeira ocorrencia vence, como o "sed -n 1p" fazia.
                if (alvo != "" && !(alvo in achado)) achado[alvo] = link
            }

            n = split("ATK ATKRND DODGE HEAL STONE KINGATK GRASS", lista, " ")
            for (i = 1; i <= n; i++)
                grava(lista[i], (lista[i] in achado) ? achado[lista[i]] : "")

            # HP do jogador e HP do alvo. "[^A-Za-z0-9_][^A-Za-z0-9_]*" no
            # lugar de "{1,4}" pelo mesmo motivo: um ou mais separadores.
            hp = ""
            if (match(todo, "hp[^A-Za-z0-9_][^A-Za-z0-9_]*[0-9][0-9]*")) {
                hp = substr(todo, RSTART, RLENGTH)
                sub(/^hp[^0-9]*/, "", hp)
            }
            grava("HP", hp)

            hp2 = ""
            if (match(todo, "nbsp[^A-Za-z0-9_][^A-Za-z0-9_]*[0-9][0-9]*")) {
                hp2 = substr(todo, RSTART, RLENGTH)
                sub(/^nbsp[^0-9]*/, "", hp2)
            }
            grava("HP2", hp2)

            # Os dois limiares saiam de um awk cada, lendo arquivo com cat.
            full = ""
            getline full < "FULL"; close("FULL")
            rhp  = sprintf("%.0f", hp * rper / 100 + hp)
            hlhp = sprintf("%.0f", full * hper / 100)
            grava_num("RHP",  rhp)
            grava_num("HLHP", hlhp)

            # Os mesmos valores tambem saem na saida padrao, para quem os usa
            # como VARIAVEL (o king.sh) nao precisar de um "cat" por campo.
            # Campo vazio vira 0: sem isso a divisao em posicionais desalinha.
            printf "%s %s %s %s %s\n", \
                   (todo ~ /\/dodge\//) ? "1" : "0", \
                   (rhp  == "") ? "0" : rhp, \
                   (hlhp == "") ? "0" : hlhp, \
                   (hp   == "") ? "0" : hp, \
                   (hp2  == "") ? "0" : hp2
        }
    ' "$4" 2>/dev/null
}

# A sessao esta viva: carimba a hora da ultima confirmacao.
#
# POR QUE ISTO EXISTE
#
# Quem escrevia o last_ok era so o descansar(), no fim de cada ciclo. Dentro
# de um evento o ciclo nao termina: o modulo entra em 15:55, espera ate as
# 16:00 num laco de sleep e so entao luta, com teto de 600s. Sao dez, quinze
# minutos sem passar pelo descanso — e o painel, que cobra confirmacao a
# cada 4 minutos, anunciava "sessao caida" em praticamente todo evento, com
# a conta lutando normalmente.
#
# Nao da para chamar o descansar ali: ele volta para a Home e ABANDONARIA a
# batalha. Mas a confirmacao ja existe de graca dentro da luta: a pagina de
# combate so responde com o link de golpe para quem esta logado. Onde o
# modulo reconhece esse link, a sessao esta provada — e e so carimbar.
sessao_marcar() { date +%s > "$TMP/last_ok" 2>/dev/null; }

# SESSAO CAIDA OU SERVIDOR MUDO?   sessao_estado ARQUIVO   (ou "-" = stdin)
#
#   viva          pagina do jogo com a conta logada
#   deslogado     pagina do jogo SEM conta: a sessao caiu de verdade
#   sem_resposta  vazia, cortada ou nao e pagina do jogo: NAO DIZ NADA
#
# Nos logs de 12/09, das 922 vezes em que o descanso anunciou "Sessao caiu",
# 557 terminaram em "falha ao reconectar" com curl sem conexao, 40 sem
# desfecho, 126 relogaram depois de erro de curl e 92 nem estavam deslogadas:
# ~88% era o SERVIDOR sem responder. O bot apagava o cookie (sessao de 30
# dias), refazia o login inteiro — que tambem falhava — e somava requisicoes
# justamente na hora em que o servidor ja nao dava conta (00h-01h, Coliseu).
#
# O SINAL E DO PROPRIO JOGO. Toda pagina do jogo termina com
#     jsInterface.event("user=12345;level=43")
# e a de quem nao esta logado com "user=0" — conferido nas 117 paginas salvas
# das contas (todas user>0) e no /, /user e /king sem cookie (user=0; o /user
# anonimo e um "Error 404" sem formulario de login nem link de entrada, que
# os testes antigos davam por "sessao viva? nao" = caida).
# Pagina cortada antes do rodape cai nos sinais do topo: formulario ou link
# de login = deslogado; icone de nivel = viva. Um awk, nenhum outro processo.
sessao_estado() {
    if [ "$1" != "-" ] && [ ! -s "$1" ]; then
        echo sem_resposta
        return 0
    fi
    awk -v q="'" '
        { t = t $0 "\n" }
        END {
            if (match(t, /jsInterface\.event\("user=[0-9]+/)) {
                u = substr(t, RSTART + 24, RLENGTH - 24) + 0
                print (u > 0 ? "viva" : "deslogado"); exit
            }
            if (t ~ ("name=[" q "\"]?pass|action=[^>]*sign_in|[?&]sign_in=1")) {
                print "deslogado"; exit
            }
            if (index(t, "icon/level.png")) { print "viva"; exit }
            print "sem_resposta"
        }' "$1" 2>/dev/null || echo sem_resposta
}

# Servidor sem resposta: carimbo para o painel dizer "sem resposta" em vez
# de "sessao caida" quando a conta nao confirma a sessao ha minutos.
servidor_mudo_marcar() { date +%s > "$TMP/last_rede" 2>/dev/null; }

# Primeiro link de ACAO de um evento, preferindo o que tem nonce (?r=N).
#
# CORRECAO (conta abandonando o evento): os modulos extraiam o link com uma
# alternacao do tipo
#     /altars(/[A-Za-z]+/?r=[0-9]+|/)
# cujo segundo ramo casa o caminho NU "/altars/". Como "/altars/" aparece em
# qualquer link da pagina e o "sed -n 1p" pega a primeira ocorrencia, o
# ACCESS virava quase sempre o caminho nu — nunca o link de dodge/ataque.
#
# O laco de entrada espera justamente por "dodge" nesse arquivo, entao ele
# nunca era satisfeito: a conta queimava o tempo limite, entrava no laco de
# luta sem estar na luta, via "Battle over" na primeira volta e voltava para
# a rotina comum. No painel isso aparece como a conta trocando o evento por
# "Cla" no meio do horario — abandonando o evento.
#
# Aqui o link com nonce tem prioridade; o caminho nu so e devolvido quando
# nao existe nenhuma acao disponivel, que e a informacao verdadeira.
link_acao() {
    _la_f="$1"; _la_p="$2"
    [ -r "$_la_f" ] || { printf ''; unset _la_f _la_p; return 1; }
    _la=`grep -o -E "/${_la_p}/[A-Za-z]+/[^A-Za-z0-9]r[^A-Za-z0-9][0-9]+" "$_la_f" 2>/dev/null | sed -n 1p`
    # Link com nonce so aparece em pagina logada: serve de confirmacao.
    [ -n "$_la" ] && sessao_marcar
    [ -n "$_la" ] || _la=`grep -o -E "/${_la_p}/" "$_la_f" 2>/dev/null | sed -n 1p`
    printf '%s' "$_la"
    unset _la_f _la_p _la
    return 0
}

# ============================================================
#  ESTADO DA LUTA — O PERSONAGEM SO SAI QUANDO O JOGO DECLARA
#
#  POR QUE UMAS CONTAS ABANDONAVAM E OUTRAS NAO
#
#  Cada conta e um processo proprio, com rede, sessao e PID proprios. O que
#  tirava uma conta da batalha dependia do que acontecia com ELA:
#
#   1. Duas leituras seguidas sem o link de esquiva — curl cortado pelo
#      --max-time, pagina de erro, transicao, sessao derrubada pelo servidor
#      (o que com varias contas do mesmo IP e comum) — e o modulo gravava
#      BREAK_LOOP com o personagem vivo. Numa conta a rede tropeca, na outra
#      nao.
#   2. O teto fixo de 10 minutos, contado da entrada de cada conta.
#   3. O Android matando o worker (SIGKILL) e o painel relancando: o worker
#      novo nao sabia da batalha e caia na rotina.
#   4. E o que transformava tudo isso em FUGA de verdade: o descansar() pedia
#      /?out_gate_confirm=true — a confirmacao de "Fuja da batalha" — a cada
#      chamada. O evento_espera o chama de 30 em 30s logo depois do modulo de
#      luta; o start() e o func_cat, ao fim de cada ciclo. Toda conta que caia
#      por qualquer um dos motivos acima confirmava a fuga sozinha.
#
#  A REGRA AGORA
#
#  O laco de luta so termina quando o JOGO declara:
#      morto   HP do cabecalho em 0, ou /<evento>/unrip/
#      fim     ?close=reward, ou o ?end_fight do coliseu
#  ou quando a propria pagina do evento, lida sem erro, passa LUTA_FORA_MAX
#  segundos seguidos sem nenhuma acao e sem o out_gate — a conta nao esta na
#  batalha. Se a conta JA LUTOU nesta batalha, bastam LUTA_FORA_LUTOU
#  segundos: sem botao de luta e sem ressurreicao na tela, a luta acabou para
#  ela. Leitura invalida nao conta para nada; sessao caida reconecta e
#  continua. A batalha fica gravada em $TMP/batalha desde a inscricao: o
#  worker relancado volta para ela, e o descansar() nunca confirma a fuga
#  enquanto ela estiver pendente.
# ============================================================

# Segundos seguidos sem sinal de luta, na pagina do evento, para aceitar que
# a conta nao esta na batalha. Cobre tambem o atraso do inicio.
LUTA_FORA_MAX="${LUTA_FORA_MAX:-90}"

# O MESMO "SEM LUTA", DEPOIS DE A CONTA TER LUTADO: 15s, NAO 90s.
#
# Os 90s existem para o inicio (a luta demora a aparecer na pagina). Depois
# que a conta ja teve a luta na tela, uma pagina do evento valida, sem nenhum
# botao de acao (ataque, esquiva, cura, pedra, erva, golpe), sem o out_gate e
# sem o unrip, e a luta que acabou para ela — morta sem ressurreicao, ou a
# batalha terminou. Nos logs de 12/09, 140 de 184 saidas de batalha passaram
# pelos 90s relendo a pagina a toa.
#
# Por que ainda 15s, e nao na primeira pagina: a virada da morte do Rei troca
# a pagina por um instante, e o Imortal some com o golpe na troca de turno.
# 15s sao 3 a 6 releituras sem nenhum botao — transicao nao dura isso.
LUTA_FORA_LUTOU="${LUTA_FORA_LUTOU:-15}"

# Teto de seguranca, em minutos, do laco de luta e da batalha pendente. So e
# alcancado se a pagina nunca resolver (rede fora); os eventos duram menos.
LUTA_TETO_MIN="${LUTA_TETO_MIN:-30}"

luta_teto() {
    _lt_min="$LUTA_TETO_MIN"
    case "$_lt_min" in ''|*[!0-9]*) _lt_min=30 ;; esac
    echo $(( `date +%s` + _lt_min * 60 ))
    unset _lt_min
}

# Classifica a pagina de luta: estado_luta ARQUIVO SECAO
#
#   invalida   vazia, cortada, nao e pagina do jogo: NAO DIZ NADA
#   deslogado  formulario de login: a sessao caiu
#   luta       ha acao do evento na tela, ou o portao de saida (out_gate)
#   morto      o jogo declarou a morte (unrip, ou HP 0 no cabecalho)
#   fim        o jogo declarou o fim (?close=reward / ?end_fight)
#   fora       pagina valida sem nenhum sinal de luta
#
# Um awk so, sem {n,m} (o mawk nao volta atras nos intervalos — ver o
# combate_ler). A ORDEM IMPORTA: acao na tela vem antes da morte, para um HP
# 0 lido errado nunca tirar da luta quem ainda tem botao de ataque; o
# out_gate vem depois da morte, porque ele continua na pagina de quem morreu.
estado_luta() {
    [ -s "$1" ] || { echo invalida; return 0; }
    awk -v sec="$2" -v q="'" '
        { t = t $0 "\n" }
        END {
            if (t ~ ("name=[" q "\"]?pass|action=[^>]*sign_in")) { print "deslogado"; exit }

            hpic = "health.png" q " alt=" q "hp" q "/>"
            valida = (index(t, "icon/level.png") || index(t, hpic) || \
                      index(t, "/logout") || t ~ /[?&]exit/ || index(t, "out_gate"))

            acao = 0; nonce = 0; resto = t
            while (match(resto, "/" sec "/[A-Za-z]+/[?]r[=][0-9]+")) {
                lk = substr(resto, RSTART, RLENGTH)
                resto = substr(resto, RSTART + RLENGTH)
                nonce = 1
                v = lk; sub("^/" sec "/", "", v); sub("/.*$", "", v)
                if (v == "kingatk" || v == "dodge" || v == "heal" || v == "stone" || \
                    v == "grass" || v == "shield" || v == "hit" || v == "mana" || \
                    v ~ /^at.*k/) acao = 1
            }
            if (!valida && !nonce) { print "invalida"; exit }
            # O UNRIP VEM ANTES DA ACAO, E NAO DEPOIS.
            #
            # Estava depois do "if (acao)", e com isso era inalcancavel
            # sempre que a pagina ainda trouxesse um link de acao. O jogo so
            # oferece o unrip a quem morreu: isso vale mais que ter botao na
            # tela. (O luta_hp cobre o caso em que nem unrip ha; este cobre o
            # caso em que o jogo diz a morte de letra.)
            if (index(t, "/" sec "/unrip/")) { print "morto"; exit }

            if (acao) { print "luta"; exit }

            # MORTE ESCRITA NO LOG DA BATALHA (servidor BR, Torneio dos Clas
            # de 12/09, 14 paginas capturadas de quem saiu da luta):
            #     <img src=/images/icon/rip.png/> Fulano assassinou Voce
            #     Espere ate o fim da batalha
            # "assassinou Voce" apareceu em 13 das 14 e em nenhuma das 28
            # paginas com a luta ativa (la o log so traz a morte dos outros:
            # "Fulano assassinou Beltrano", "Voce assassinou Beltrano"); o
            # "Espere ate o fim da batalha" em todas as 14. Vem DEPOIS da
            # acao: com botao na tela (ressuscitou), linha velha do log nao
            # tira ninguem da luta. Sem acento no teste: bytes UTF-8 variam.
            if (index(t, "assassinou Voc") || \
                (index(t, "Espere at") && index(t, " o fim da batalha"))) {
                print "morto"; exit
            }
            i = index(t, hpic)
            if (i) {
                s = substr(t, i + length(hpic), 60)
                if (match(s, /[0-9]+/) && substr(s, RSTART, RLENGTH) + 0 == 0) {
                    print "morto"; exit
                }
            }

            if (index(t, "out_gate")) { print "luta"; exit }
            if (index(t, "/" sec "/?close=reward") || index(t, "?end_fight")) { print "fim"; exit }
            print "fora"
        }' "$1" 2>/dev/null
}

# Batalha em andamento DESTA conta, em disco: sobrevive ao SIGKILL do Android
# e ao relancamento pelo painel.  $TMP/batalha = "SECAO EPOCH_DA_INSCRICAO"
batalha_pendente() {
    _bp_sec=""; _bp_t=""
    [ -r "$TMP/batalha" ] || return 1
    read -r _bp_sec _bp_t < "$TMP/batalha" 2>/dev/null
    case "$_bp_t" in ''|*[!0-9]*) return 1 ;; esac
    [ -n "$_bp_sec" ] || return 1
    _bp_min="$LUTA_TETO_MIN"
    case "$_bp_min" in ''|*[!0-9]*) _bp_min=30 ;; esac
    [ $(( `date +%s` - _bp_t )) -lt $(( _bp_min * 60 )) ]
    _bp_rc=$?
    unset _bp_min
    return $_bp_rc
}

# Anota a batalha. Chamado ANTES do pedido de inscricao: a conta inscrita ja
# esta comprometida com o evento, lutando ou esperando o inicio.
batalha_marcar() {
    if batalha_pendente && [ "$_bp_sec" = "$1" ]; then
        return 0    # mesma batalha: preserva o instante da inscricao
    fi
    printf '%s %s\n' "$1" "`date +%s`" > "$TMP/batalha" 2>/dev/null
}

batalha_limpar() { rm -f "$TMP/batalha" 2>/dev/null; }

# Quem matou a conta, pelo log da batalha.   luta_assassino ARQUIVO -> nome
#     <img src='/images/icon/race/1.png' alt=''/> Fulano assassinou Você
# A linha mais recente e a primeira da pagina. So roda na saida da luta.
luta_assassino() {
    [ -s "$1" ] || return 0
    awk '
        { t = t $0 "\n" }
        END {
            i = index(t, " assassinou Voc")
            if (!i) exit
            s = substr(t, 1, i - 1)
            j = 0
            while ((k = index(substr(s, j + 1), ">")) > 0) j += k
            s = substr(s, j + 1)
            gsub(/^[ \t\n]+|[ \t\n]+$/, "", s)
            if (length(s) > 0 && length(s) <= 40) print s
        }' "$1" 2>/dev/null
}

# QUEM E O ALVO DA VEZ?   alvo_nome ARQUIVO -> nome (espacos viram "_")
#
# A leitura antiga — o 2o "Nome<espaco><simbolo>" da pagina — devolvia
# "Fulano_&" em TODAS as 48 paginas de luta do Rei capturadas em 12/09, de
# todas as contas: um nome qualquer do rodape, nunca o alvo. A protecao de
# aliados comparava esse nome e nunca poupava ninguem. Nas batalhas de cla o
# nome do alvo nem era lido (so o do cla, com o mesmo tipo de regex).
#
# Marcacao real, logo acima dos botoes (Rei e Torneio dos Clas):
#   <img .../race/1.png' alt=''/> Minha Conta <span class='nwr'>
#       <img src='/images/icon/health.png' alt='hp'/> 35656</span>      <- voce
#   <img .../race/0.png' alt=''/> Inimigo <span class='nwr'>
#       <img src='/images/icon/health.png' alt='hp'/>&nbsp;8092</span>  <- alvo
# O alvo e o do "&nbsp;" (o mesmo que o HP2 ja usa para o HP do inimigo).
# Conferido nas 76 paginas de Rei e Torneio: nome certo em todas ("Rei"
# enquanto o rei vive). Um awk: substitui grep+sed.
alvo_nome() {
    [ -s "$1" ] || return 0
    awk -v q="'" '
        { t = t $0 "\n" }
        END {
            m = "<span class=" q "nwr" q "><img src=" q "/images/icon/health.png" q " alt=" q "hp" q "/>&nbsp;"
            i = index(t, m)
            if (!i) exit
            s = substr(t, 1, i - 1)
            j = 0
            while ((k = index(substr(s, j + 1), ">")) > 0) j += k
            s = substr(s, j + 1)
            gsub(/^[ \t\n]+|[ \t\n]+$/, "", s)
            gsub(/[ \t]+/, "_", s)
            if (length(s) > 0 && length(s) <= 40) print s
        }' "$1" 2>/dev/null
}

# O ALVO ESTA INVULNERAVEL?   alvo_grey ARQUIVO   (0 = sim)
#
# Os modulos testavam 'txt smpl grey' na pagina INTEIRA. Nas 28 paginas de
# luta capturadas em 12/09 a marca so apareceu no botao "Troca o alvo"
# DESATIVADO (href sem acao, fim de batalha com poucos alvos):
#     <a class='nbtn b_grey' href='/clanfight/'><span class='lbl'>
#         <span class='txt smpl grey'>Troca o alvo</span>
# Nessas leituras a conta parava de atacar e so relia a pagina. O botao de
# trocar de alvo (desativado ou attackrandom/atkrnd) nao diz nada sobre o
# alvo: sai da busca. O resto da pagina — inclusive o botao de ataque —
# continua valendo. Um awk, o mesmo custo do grep que substitui.
alvo_grey() {
    [ -s "$1" ] || return 1
    awk -v q="'" '
        { t = t $0 "\n" }
        END {
            n = split(t, p, "<a class=" q "nbtn")
            s = p[1]
            for (i = 2; i <= n; i++) {
                j = index(p[i], "</a>")
                btn = j ? substr(p[i], 1, j + 3) : p[i]
                resto = j ? substr(p[i], j + 4) : ""
                if (btn ~ ("href=" q "/[a-z]+/(attackrandom|atkrnd)/") || \
                    btn ~ ("href=" q "/[a-z]+/" q ">"))
                    btn = ""
                s = s btn resto
            }
            exit !index(s, "txt smpl grey")
        }' "$1" 2>/dev/null
}

# Zera a memoria da luta e anota a batalha. No INICIO de cada funcao de luta.
luta_inicio() {
    _lt_fora_desde=""
    _lt_relogin=0
    _lt_invalidas=0
    _lt_teve_vida=0
    _lt_lutou=0
    _lt_hp0=0
    _reviveu=0
    LUTA_MOTIVO=""
    LUTA_SESSAO_CAIU=0
    [ -n "$1" ] && batalha_marcar "$1"
    return 0
}

# MORTE COM A LUTA AINDA NA TELA.   luta_hp HP  ->  0 = morte confirmada
#
# Medido nos logs (Rei, 11/09 16:25): depois da morte a pagina CONTINUA com
# botoes de acao e o HP lido e 0 — 321 leituras seguidas, 27 minutos, com a
# conta "lutando" morta ate o teto de seguranca. O estado_luta poe botao na
# tela antes da morte (para um HP mal lido nao tirar ninguem da luta), e o
# modulo nem chegava a consulta-lo com acao disponivel.
#
# Chamada a cada leitura COM luta na tela. Um 0 isolado pode ser leitura
# falha — o parser devolve 0 (ou vazio) quando nao acha o numero —, entao a
# morte so vale com TRES leituras seguidas em zero, e so depois de a conta ter
# tido vida nesta luta.
luta_hp() {
    # Chamada so com a luta na tela: a conta lutou (ver LUTA_FORA_LUTOU).
    _lt_lutou=1
    # So o primeiro numero: o arquivo de HP de alguns modulos traz uma linha
    # por ocorrencia na pagina, e espaco a esquerda sobra do sed.
    _lh="$1"
    while :; do case "$_lh" in ' '*) _lh=${_lh# } ;; *) break ;; esac; done
    _lh=${_lh%%[!0-9]*}
    case "$_lh" in
        ''|0|00|000) unset _lh ;;             # zero, ou numero ausente
        *)           unset _lh; _lt_teve_vida=1; _lt_hp0=0; _reviveu=0; return 1 ;;
    esac
    [ "${_lt_teve_vida:-0}" = 1 ] || return 1
    _lt_hp0=$(( ${_lt_hp0:-0} + 1 ))
    [ "$_lt_hp0" -ge 3 ]
}

# Pode tentar reconectar agora? Portao unico da luta e do descansar ($TMP/last_reconn,
# FUNC_reconn_min + deslocamento por PID): a luta e o descanso nao podem
# somar tentativas, senao a conta reconecta em rajada e o servidor passa a
# recusar ate a senha certa.
luta_pode_reconectar() {
    _lpr_min=${FUNC_reconn_min:-60}
    case "$_lpr_min" in ''|*[!0-9]*) _lpr_min=60 ;; esac
    _lpr_min=$(( _lpr_min + ($$ % 45) ))
    _lpr_ult=`cat "$TMP/last_reconn" 2>/dev/null`
    case "$_lpr_ult" in ''|*[!0-9]*) _lpr_ult=0 ;; esac
    # Marca no futuro (relogio voltou) nao pode travar a reconexao por horas.
    _lpr_ult=$(( `date +%s` - _lpr_ult ))
    [ "$_lpr_ult" -lt 0 ] || [ "$_lpr_ult" -ge "$_lpr_min" ]
    _lpr_rc=$?
    unset _lpr_min _lpr_ult
    return $_lpr_rc
}

# A luta acabou?  luta_acabou ARQUIVO SECAO
#   0 = pode sair (motivo em LUTA_MOTIVO)     1 = continua lutando
#
# E a UNICA porta de saida dos lacos de luta.
luta_acabou() {
    _lz_e=`estado_luta "$1" "$2"`
    [ "$_lz_e" = invalida ] || _lt_invalidas=0
    case "$_lz_e" in
        luta)
            _lt_fora_desde=""
            _lt_lutou=1
            unset _lz_e; return 1
            ;;
        morto)
            LUTA_MOTIVO="o jogo declarou o personagem morto"
            _lz_k=`luta_assassino "$1"`
            [ -n "$_lz_k" ] && LUTA_MOTIVO="assassinado por $_lz_k (log da batalha)"
            unset _lz_k
            batalha_limpar
            unset _lz_e; return 0
            ;;
        fim)
            LUTA_MOTIVO="o jogo declarou o fim da batalha"
            batalha_limpar
            unset _lz_e; return 0
            ;;
        deslogado)
            # A sessao caiu no meio da luta — com varias contas do mesmo IP o
            # servidor derruba sessoes com facilidade. Reconecta e o laco rele
            # a pagina do evento. Tres tentativas por luta, e so quando o
            # portao comum de reconexao deixa (luta_pode_reconectar).
            if [ "${_lt_relogin:-0}" -lt 3 ] && luta_pode_reconectar; then
                _lt_relogin=$(( ${_lt_relogin:-0} + 1 ))
                date +%s > "$TMP/last_reconn" 2>/dev/null
                printf "Sessao caiu na batalha - reconectando (a conta continua na luta)\n"
                type login_logoff > /dev/null 2>&1 && login_logoff
                unset _lz_e; return 1
            fi
            # SEM SESSAO E SEM TENTATIVA AGORA: SAI DO LACO, NAO DA BATALHA.
            #
            # Sem este ramo a luta seguia relendo a pagina de login a cada 1-2s
            # ate o teto de 30 minutos — a conta presa numa luta em que nao
            # pode agir. Agora o laco termina, mas a batalha continua anotada
            # em $TMP/batalha: o descansar reconecta no ritmo dele e o
            # batalha_retomar volta para a luta assim que a sessao voltar.
            LUTA_MOTIVO="sessao caiu e ainda nao reconectou (a batalha sera retomada)"
            LUTA_SESSAO_CAIU=1
            unset _lz_e; return 0
            ;;
        fora)
            # FIM ESCRITO PELO JOGO, DEPOIS DE TER LUTADO.
            #
            # Paginas reais de 12/09 (224 amostras, 104 com luta ativa):
            #   Rei    "Batalha finalizada!"  8 + 10 paginas de saida
            #   Vale   "Vitória!"             12 + 12
            #   Torneio "Luta acabou!"        2
            # Nenhum dos tres em pagina com luta ativa. So vale depois de a
            # conta ter lutado: antes da luta o saguao do Rei ainda mostra o
            # resultado da batalha ANTERIOR. Sem estes textos, a saida esperava
            # os 15s relendo a pagina.
            if [ "${_lt_lutou:-0}" = 1 ] && \
               grep -q -F -e 'Batalha finalizada!' -e 'Vitória!' -e 'Luta acabou!' "$1" 2>/dev/null; then
                LUTA_MOTIVO="o jogo declarou o fim da batalha"
                batalha_limpar
                unset _lz_e; return 0
            fi
            if [ "${_lt_lutou:-0}" = 1 ]; then
                _lz_max="$LUTA_FORA_LUTOU"
                case "$_lz_max" in ''|*[!0-9]*) _lz_max=15 ;; esac
                _lz_mot="sem botao de luta e sem ressurreicao por ${_lz_max}s: a luta acabou para a conta"
            else
                _lz_max="$LUTA_FORA_MAX"
                case "$_lz_max" in ''|*[!0-9]*) _lz_max=90 ;; esac
                _lz_mot="${_lz_max}s sem sinal de luta na pagina do evento"
            fi
            if [ -z "$_lt_fora_desde" ]; then
                _lt_fora_desde=`date +%s`
                [ "${_lt_lutou:-0}" = 1 ] && \
                    printf "Sem botao de luta na tela - confirmando o fim (%ss)\n" "$_lz_max"
            fi
            if [ $(( `date +%s` - _lt_fora_desde )) -ge "$_lz_max" ]; then
                LUTA_MOTIVO="$_lz_mot"
                batalha_limpar
                unset _lz_e _lz_max _lz_mot; return 0
            fi
            unset _lz_e _lz_max _lz_mot; return 1
            ;;
        *)
            # invalida: leitura que nao prova nada. Nao conta para o "fora".
            #
            # Mas com a rede fora TODA leitura e invalida, e o laco relia a
            # cada 1-2s ate o teto. A partir da terceira seguida, respira 3s
            # entre as releituras.
            _lt_invalidas=$(( ${_lt_invalidas:-0} + 1 ))
            [ "$_lt_invalidas" -ge 3 ] && sleep 3
            unset _lz_e; return 1
            ;;
    esac
}

# ESPERA ATE UMA HORA DO RELOGIO — NUNCA A DA HORA SEGUINTE.
#
#   espera_janela DE ATE      (MMSS: espera_janela 5500 5930)
#
# Dorme enquanto o relogio estiver em [DE, ATE). Passou de ATE — ou o minuto
# ja virou e ficou abaixo de DE —, sai na hora.
#
# Os modulos usavam `while (case M:S in (59:[3-5][0-9]) exit 1;; esac)`, ou
# seja "dorme ate o relogio MOSTRAR 59:30". Antes do laco saem tres
# requisicoes, ate 45s cada: chegando atrasado numa rede lenta, o relogio ja
# tinha passado de 59:59 e a proxima vez que mostraria 59:30 era UMA HORA
# depois. A conta ficava presa ate la, perdendo o evento e os da hora
# seguinte (das Bandeiras de 10:10, o Coliseu do Cla e o Torneio).
espera_janela() {
    while :; do
        _ej=`date +%M%S`
        while :; do case "$_ej" in 0?*) _ej=${_ej#0} ;; *) break ;; esac; done
        { [ "$_ej" -ge "$1" ] && [ "$_ej" -lt "$2" ]; } || break
        sleep 3
    done
    unset _ej
}

# MORREMOS? RESSUSCITA E VOLTA PARA A LUTA.   ressuscitar SECAO ARQUIVO
#
# Isto morava dentro do king.sh, em duas copias, e SO o Rei tratava a morte.
# Nos outros eventos a conta morria e a luta simplesmente acabava — no altar
# isso e sair do evento com tempo de sobra, que foi o relato ("varias contas
# abandonaram o altar").
#
# O GATILHO E SINAL DO JOGO, NAO DEDUCAO NOSSA. O "/SECAO/unrip/" so aparece
# na pagina de quem morreu. Por isso esta funcao pode ser chamada sem medo
# antes de encerrar: se nao ha unrip, ela nao faz nada e nao pede nada.
#
#   0 = ressuscitou, e ARQUIVO ja tem a pagina DEPOIS do unrip
#   1 = nao ha unrip na pagina, ou ja se ressuscitou e ainda nao houve vida
ressuscitar() {
    [ "${_reviveu:-0}" = 0 ] || return 1
    [ -s "$2" ] || return 1
    _rs_l=`grep -o -E "(/$1/unrip/[^A-Za-z0-9_]r[^A-Za-z0-9_][0-9]+)" "$2" 2>/dev/null | sed -n 1p`
    [ -n "$_rs_l" ] || { unset _rs_l; return 1; }
    # Trava contra laco de unrip. So volta a zero quando o luta_hp vir HP de
    # verdade na tela — isto e, quando a ressurreicao tiver funcionado.
    _reviveu=1
    printf "Morreu (%s) - ressuscitando e voltando para a luta\n" "$1"
    # RELE A PAGINA DO UNRIP, e nao so clica: seguir usando os links da
    # pagina anterior nao funciona, porque os nonces (?r=) dela ja morreram.
    (
        run_curl_exec "${URL}${_rs_l}" > "$2"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17
    unset _rs_l
    return 0
}

hpmp() {
    if echo "$@" | grep -q '\-fix'; then
        (
            run_curl_exec "$URL/train" > "$TMP/TRAIN"
        ) </dev/null > /dev/null 2>&1 &
        time_exit 20
        FIXHP=`grep -o -E '\(([0-9]+)\)' "$TMP/TRAIN" | sed 's/[()]//g'`
        FIXMP=`grep -o -E ': [0-9]+' "$TMP/TRAIN" | sed -n '5s/: //p'`
    fi

    NOWHP=`grep -o -E "<img src='/images/icon/health.png' alt='hp'/> <span class='(dred|white)'>[ ]?[0-9]{1,7}[ ]?</span> | <img src='/images/icon/mana.png' alt='mp'/>" "$TMP/SRC" | tr -c -d '[:digit:]'`
    NOWMP=`grep -o -E "</span> | <img src='/images/icon/mana.png' alt='mp'/>[ ]?[0-9]{1,7}[ ]?</span><div class='clr'></div></div>" "$TMP/SRC" | tr -c -d '[:digit:]'`

    # CORRECAO: se a requisicao foi cortada pelo time_exit, FIXHP/FIXMP ficam
    # vazios e o awk fazia divisao por zero -> "nan"/"inf" nas comparacoes.
    if [ -n "$NOWHP" ] && [ -n "$FIXHP" ] && [ "$FIXHP" -gt 0 ] 2>/dev/null; then
        HPPER=`awk -v nowhp="$NOWHP" -v fixhp="$FIXHP" 'BEGIN { printf "%.2f", nowhp / fixhp * 100 }'`
    else
        HPPER="0.00"
    fi

    if [ -n "$NOWMP" ] && [ -n "$FIXMP" ] && [ "$FIXMP" -gt 0 ] 2>/dev/null; then
        MPPER=`awk -v nowmp="$NOWMP" -v fixmp="$FIXMP" 'BEGIN { printf "%.2f", nowmp / fixmp * 100 }'`
    else
        MPPER="0.00"
    fi
}

# Extrai os dados da conta de uma pagina /user ja baixada e grava em
# $TMP/stats, que o painel do play.sh le. Nenhuma requisicao extra: o
# login_logoff() ja baixa essa pagina a cada ciclo.
#
# Campos nao encontrados viram "-" em vez de ficarem vazios, para o painel
# nao mentir sobre um valor que nao conseguiu ler.
#
# Padroes confirmados contra o HTML real do jogo:
#   <title>NomeDaConta</title>
#   health.png' alt='hp'/> <span class='white'>65312</span>
#   mana.png' alt='mp'/> 470</span>
#   icon/level.png' alt=''/> 40 nivel
#   mana.png' alt=''/> Energia: 2125

# Extrai os dados da conta de uma pagina /user ja baixada e grava em
# $TMP/stats, lido pelo painel do play.sh. Sem requisicao extra: o
# login_logoff() ja baixa essa pagina a cada ciclo.
#
# Padroes confirmados contra o HTML real:
#   <title>NomeDaConta</title>
#   health.png' alt='hp'/> <span class='white'>65312</span>
#   mana.png' alt='mp'/> 346
#   icon/level.png' alt='lvl'/> 90
#   icon/gold.png' alt='g'/> 396
#   icon/silver.png' alt='s'/> 408,1M
# Energia so aparece em /train: mana.png' alt=''/> Energia: 2125
parse_status() {
    _pg="$1"
    [ -n "$_pg" ] || return 1

    # DISTANCIA LIVRE ENTRE O ICONE E O NUMERO.
    #
    # CORRECAO (energia mostrando so o teto): entre o icone e o valor o jogo
    # intercala tags e espacos —
    #     <img src='/images/icon/mana.png' alt='mp'/> <span class='white'>809</span>
    # e o seletor do MP exigia o numero a no maximo 4 caracteres do icone e
    # PROIBIA "<" no meio. Qualquer <span> ali zerava a leitura. Com o ACC_MP
    # vazio, o campo de energia caia no unico valor que restava — o teto, do
    # /train —, e era esse que aparecia no painel. O do HP ja tolerava um
    # <span>, e por isso o HP funcionava e a energia nao.
    #
    # Agora todos usam a mesma regra: ate 40 caracteres entre o marcador e o
    # numero, contanto que nenhum deles seja digito. Como "[^0-9]" nao casa
    # digito, o numero capturado e sempre o PRIMEIRO depois do icone — a
    # folga nao deixa o seletor pular para um numero vizinho.
    ACC_HP=`printf '%s' "$_pg" | grep -o -E "health\.png' alt='hp'/>[^0-9]{0,40}[0-9]{1,9}" | grep -o -E '[0-9]{1,9}$' | head -n1`
    ACC_MP=`printf '%s' "$_pg" | grep -o -E "mana\.png' alt='mp'/>[^0-9]{0,40}[0-9]{1,9}" | grep -o -E '[0-9]{1,9}$' | head -n1`
    ACC_LVL=`printf '%s' "$_pg" | grep -o -E "level\.png' alt='[^']*'/>[^0-9]{0,40}[0-9]{1,4}" | grep -o -E '[0-9]{1,4}$' | head -n1`

    # Ouro e prata: guarda o texto como o jogo mostra (pode vir "408,1M").
    ACC_GOLD=`printf '%s' "$_pg" | grep -o -E "gold\.png' alt='g'/>[^0-9]{0,40}[0-9][0-9.,']{0,14}[KMBkmb]?" | grep -o -E "[0-9][0-9.,']{0,14}[KMBkmb]?$" | head -n1`
    ACC_SILVER=`printf '%s' "$_pg" | grep -o -E "silver\.png' alt='s'/>[^0-9]{0,40}[0-9][0-9.,']{0,14}[KMBkmb]?" | grep -o -E "[0-9][0-9.,']{0,14}[KMBkmb]?$" | head -n1`

    NOWHP="$ACC_HP"; NOWMP="$ACC_MP"

    if [ -n "$ACC_HP" ] && [ -n "$FIXHP" ] && [ "$FIXHP" -gt 0 ] 2>/dev/null; then
        HPPER=`awk -v a="$ACC_HP" -v b="$FIXHP" 'BEGIN{printf "%.0f", a/b*100}'`
    else
        HPPER=""
    fi

    # ENERGIA: ATUAL / TETO.
    #
    # CORRECAO (o painel mostrava sempre o teto). Havia dois numeros e o bot
    # exibia o errado:
    #
    #   ACC_ENE  vem de /train  ("Energia: 2109")  -> e o TETO, praticamente
    #                                                 fixo para a conta
    #   ACC_MP   vem do cabecalho da pagina        -> e o valor que MUDA:
    #            (mana.png alt='mp')                  cai quando a arena gasta
    #                                                 e sobe com a regeneracao
    #
    # O campo de energia do painel recebia o ACC_ENE, e o ACC_MP era lido e
    # descartado — o painel nem chegava a exibi-lo. Resultado: uma conta com
    # 231 de energia aparecia com 2109, que e o teto dela.
    #
    # Agora o campo traz os dois, no formato "atual/teto" (ex.: 809/2109),
    # que e como o proprio jogo apresenta. Quando so um dos dois e conhecido,
    # mostra o que houver, sem inventar o outro.
    _ene_campo="-"
    if [ -n "$ACC_MP" ] && [ -n "$ACC_ENE" ]; then
        _ene_campo="${ACC_MP}/${ACC_ENE}"
    elif [ -n "$ACC_MP" ]; then
        _ene_campo="$ACC_MP"
    elif [ -n "$ACC_ENE" ]; then
        _ene_campo="$ACC_ENE"
    fi

    printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "${ACC:-$SLS_USER}" "${ACC_HP:--}" "${ACC_MP:--}" "$_ene_campo" \
        "${ACC_LVL:--}" "${ACC_GOLD:--}" "${ACC_SILVER:--}" "$(date +%s)" \
        > "$TMP/stats" 2>/dev/null
    unset _ene_campo

    unset _pg
}

# Dados que so existem na pagina /train: HP maximo e energia.
# Uma requisicao por ciclo de start(), nao por minuto.
fetch_train_stats() {
    # ENERGIA ZERADA ANTES DE LER.
    #
    # CORRECAO (painel mostrando energia de horas atras): quando o /train nao
    # respondia — rede oscilando, timeout, sessao caida — a funcao devolvia 1
    # no "[ -n "$_t" ] || return 1" abaixo e o ACC_ENE CONTINUAVA com o valor
    # da ultima leitura boa. Como o worker e um unico processo que vive por
    # dias, essa variavel ficava presa: uma conta com 231 de energia aparecia
    # no painel com 2115, o valor lido no boot, indefinidamente.
    #
    # Zerando aqui, uma leitura que falha resulta em "-" no painel — que e
    # honesto (nao sabemos) em vez de errado (numero congelado). O aviso de
    # "numeros parados" do painel cobre o resto.
    #
    # O FIXHP recebe tratamento diferente de proposito: ele e o HP MAXIMO, que
    # so muda quando a conta sobe de nivel. O ultimo valor conhecido continua
    # valido, entao mante-lo nao mente — e evita perder o percentual de HP a
    # cada oscilacao de rede. Os dois usos dele ja sao protegidos por
    # [ -n "$FIXHP" ].
    ACC_ENE=""

    _t=`run_curl "${URL}/train" 2>/dev/null`
    [ -n "$_t" ] || return 1
    FIXHP=`printf '%s' "$_t" | grep -o -E '\([0-9]{1,9}\)' | head -n1 | tr -d '()'`
    # CORRECAO (energia sempre vazia): o sed era `s@.*:? ?@@`. Como `:?` e ` ?`
    # sao ambos opcionais, o `.*` guloso casava a string INTEIRA ("Energia:
    # 2125") e a substituicao apagava tudo, devolvendo vazio. Sobrava so o
    # fallback abaixo, que ainda perde o sufixo K/M ("2,1M" virava "2,1").
    # Agora a remocao e ancorada no proprio rotulo, preservando o numero e o
    # sufixo.
    # Mesma regra do parse_status: o rotulo e o numero quase nunca estao
    # colados no HTML cru — entre eles vem "</span> <span class='white'>".
    ACC_ENE=`printf '%s' "$_t" | grep -o -E "Energia:?[^0-9]{0,40}[0-9][0-9.,']{0,14}[KMBkmb]?" | grep -o -E "[0-9][0-9.,']{0,14}[KMBkmb]?$" | head -n1`
    unset _t
}

# Linha de status no log da conta. Imprime so o que existe.
messages_info() {
    _a="${ACC:-$SLS_USER}"
    printf "solucaoshell v%s | %s\n" "${versionNum:-?}" "$_a" > "$TMP/msg_file"
    if [ -n "$HPPER" ]; then
        printf "HP: %s (%s%%) | MP: %s | Energia: %s | Nivel: %s\n" \
            "${ACC_HP:--}" "$HPPER" "${ACC_MP:--}" "${ACC_ENE:--}" "${ACC_LVL:--}" >> "$TMP/msg_file"
    else
        printf "HP: %s | MP: %s | Energia: %s | Nivel: %s\n" \
            "${ACC_HP:--}" "${ACC_MP:--}" "${ACC_ENE:--}" "${ACC_LVL:--}" >> "$TMP/msg_file"
    fi
    unset _a
}

player_stats() {
    fetch_page "/train"
    STRENGTH=`grep -o -E ': [0-9]+' "$TMP/SRC" | sed -n '1s/: //p'`
    PLAYER_STRENGTH=`echo "$STRENGTH" | tr -cd '[:digit:]'`
    echo "$PLAYER_STRENGTH"
}

# Le a agenda oficial do jogo em /fights/ e grava em ~/.sls/agenda.
#
# CORRECAO (a agenda oficial nunca era lida): este parser procurava
# "Para iniciar: HH:MM:SS" e convertia a contagem regressiva para horario
# absoluto. Esse texto NAO existe na pagina. O /fights/ real ("Cronograma de
# batalhas") lista, sob cada evento, o HORARIO ABSOLUTO seguido de uma
# descricao livre:
#
#   Vale dos Imortais
#   10:00 BRT - Tempo para o inicio 1 hora
#   16:00 BRT - Tempo para o inicio 7 horas
#   Coliseu do cla
#   10:30 BRT - Nova temporada comeca em 7 de Setembro
#
# Como nada casava, o arquivo saia vazio e o painel caia sempre na lista
# fixa. A lista fixa esta correta, entao o defeito era silencioso — mas a
# agenda do jogo nunca era de fato consultada, e uma mudanca de horario
# passaria despercebida.
#
# Agora le o horario absoluto direto. Alem de ser o que a pagina mostra,
# dispensa toda a aritmetica de contagem regressiva (e o `date -d` do GNU,
# que o toybox do Android nao tem). A descricao apos o "-" e ignorada de
# proposito: varia com o estado do evento ("Tempo para o inicio", "Nova
# temporada comeca em...") e nao interessa para a agenda.
#
# Escreve uma linha por evento: HHMM|Nome
# Uma requisicao por ciclo de start(), e o painel apenas le o arquivo.
atualiza_agenda() {
    _ag="$HOME/.sls/agenda"

    SLS_MAXTIME=17
    _pg=`run_curl "${URL}/fights/" 2>/dev/null`
    unset SLS_MAXTIME
    [ -n "$_pg" ] || return 1

    # CORRECAO 1 (corrida entre as contas): o arquivo temporario era
    # "$_ag.tmp" — o MESMO para as 6 contas, porque a agenda mora em
    # ~/.sls e nao no diretorio da conta. Os workers escreviam nele ao
    # mesmo tempo e o "mv" de um publicava o arquivo pela metade do outro.
    # Agora o temporario leva o PID.
    _tmpf="${_ag}.$$.tmp"
    _rawf="${_ag}.$$.raw"
    : > "$_tmpf"

    # Nome do evento OU um horario absoluto "HH:MM BRT". O nome do fuso e
    # aceito de forma generica (BRT/BRST/qualquer sigla) para o parser nao
    # quebrar no horario de verao.
    printf '%s' "$_pg" \
        | sed 's/<br[^>]*>/\n/g; s/<\/div>/\n/g; s/<[^>]*>//g' \
        | grep -oE "(Vale dos Imortais|Coliseu do clã|Torneio dos Clãs|Rei dos Imortais|Altares dos Deuses|Batalha de Bandeiras)|[0-9]{1,2}:[0-9]{2} [A-Z]{2,5}" \
        > "$_rawf" 2>/dev/null

    # Um evento tem VARIOS horarios (o Vale tem tres), entao o nome vale ate
    # aparecer o proximo nome — nao e limpo a cada horario, como fazia a
    # versao de pares nome+contador. Horario sem nome antes e descartado.
    #
    # Le de ARQUIVO, nao de pipe: num pipe o laco roda em subshell e o
    # "$_nome" guardado de uma volta para a outra se perderia.
    _nome=""
    while IFS= read -r _ln; do
        case "$_ln" in
            [0-9]*:[0-9]*)
                [ -n "$_nome" ] || continue
                _h=${_ln%%:*}
                _m=${_ln#*:}; _m=${_m%% *}
                case "$_h$_m" in *[!0-9]*) continue ;; esac
                # Zeros a esquerda removidos na mao: "$((10#$_h))" e um
                # bashism — o dash recusa com "arithmetic expression" e o
                # toybox do Android tambem, o que zeraria a agenda inteira no
                # aparelho (mesma armadilha do `date -d` que ja quebrou este
                # parser antes). Sem isto, "08" ainda seria lido como octal
                # por varias implementacoes de printf.
                while :; do case "$_h" in 0?*) _h=${_h#0} ;; *) break ;; esac; done
                while :; do case "$_m" in 0?*) _m=${_m#0} ;; *) break ;; esac; done
                printf '%02d%02d|%s\n' "$_h" "$_m" "$_nome" >> "$_tmpf"
                ;;
            *)
                _nome="$_ln"
                ;;
        esac
    done < "$_rawf"
    rm -f "$_rawf"

    # CORRECAO 4 (ordem): o proximo_evento do play.sh percorre a lista de
    # cima para baixo e para no primeiro horario MAIOR que agora — ele
    # espera uma agenda diaria ordenada, como a lista fixa. A pagina
    # /fights/ nao vem em ordem cronologica, entao o painel apontava um
    # evento qualquer. Ordena antes de publicar.
    if [ -s "$_tmpf" ]; then
        sort -n "$_tmpf" > "${_tmpf}.s" 2>/dev/null && mv "${_tmpf}.s" "$_tmpf"
        mv "$_tmpf" "$_ag"
    else
        rm -f "$_tmpf"
    fi
    unset _ag _pg _tmpf _rawf _nome _ln _h _m
}

# Converte "408,7M" / "12K" / "1.234" em numero inteiro.
# O jogo abrevia valores grandes; sem isto "408,7M" viraria 4087.
valor_num() {
    _v=`printf '%s' "$1" | tr -d ' '`
    case "$_v" in
        *K|*k) _mu=1000 ;;
        *M|*m) _mu=1000000 ;;
        *B|*b) _mu=1000000000 ;;
        *)     _mu=1 ;;
    esac
    _dg=`printf '%s' "$_v" | tr -d "'" | tr ',' '.' | tr -cd '0-9.'`
    [ -z "$_dg" ] && { echo 0; return; }
    awk -v d="$_dg" -v m="$_mu" 'BEGIN{ printf "%.0f", d*m }'
    unset _v _mu _dg
}
