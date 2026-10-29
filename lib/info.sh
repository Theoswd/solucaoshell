#!/bin/sh

# Versao global: o messages_info a imprime.
versionNum="3.9.123"
# Aguarda o ultimo job em background ($! direto: PID pode ter 7+ digitos).
# O argumento (segundos) e ignorado: quem corta e o --max-time do curl.
time_exit() {
    TEFPID=$!
    [ -z "$TEFPID" ] && return 0

    # Espacamento deliberado entre requisicoes (limitador de taxa).
    # SLS_PACING=0 (o play.sh liga no Termux acima de 3 contas) dispensa o
    # sleep: o tempo de ida e volta ja espaca, e cada processo conta no
    # limite de ~32 do Android.
    _te_pace="${SLS_PACING:-1}"
    case "$_te_pace" in ''|*[!0-9]*) _te_pace=1 ;; esac
    [ "$_te_pace" -gt 0 ] && sleep "$_te_pace"
    unset _te_pace

    # So "wait", sem laco de "sleep 1" (SIGKILL do Android 12+ acima de ~32
    # processos): o curl tem prazo (--max-time) e morre sozinho.
    wait "$TEFPID" 2>/dev/null
    _te_rc=$?
    # Codigo do curl: distingue pagina cortada (18, 56) de resposta completa.
    TE_RC=$_te_rc
    # Conectou? Sem telemetria nao se sabe: vale "conectou" (o de antes).
    TE_CONECTOU=1
    [ -s "${TMP:-.}/.req_meta" ] && tele_registrar "$_te_rc"

    # 28 = CURLE_OPERATION_TIMEDOUT.
    if [ "$_te_rc" = "28" ]; then
        printf "timeout: requisicao abortada\n" >> "${TMP:-.}/ERROR_DEBUG"
        unset _te_rc
        return 1
    fi
    unset _te_rc
    return 0
}

# O ULTIMO PEDIDO NEM CHEGOU AO SERVIDOR? (curl 6, 7 ou 35, ou 28 sem a
# conexao ter aberto — TE_CONECTOU=0 da telemetria —, depois de um
# time_exit.) So entao uma acao com recarga (cura, escudo, esquiva) pode sair
# de novo: com tempo esgotado depois de conectar ou pagina cortada o elixir
# pode ja ter sido usado. Tres seguidas contam como feita, senao a cura
# sairia a cada volta.
pedido_nao_saiu() {
    case "${TE_RC:-0}" in
        6|7|35) _pns_x=1 ;;
        28)     [ "${TE_CONECTOU:-1}" = 0 ] && _pns_x=1 ;;
    esac
    if [ "${_pns_x:-0}" = 1 ]; then
        unset _pns_x
        _pns_n=$(( ${_pns_n:-0} + 1 ))
        if [ "$_pns_n" -ge 3 ]; then _pns_n=0; return 1; fi
        return 0
    fi
    _pns_n=0
    return 1
}

# Funcao central de requisicao via curl.
#  --proto/--proto-redir : redirect nao leva o POST de login para fora de HTTPS.
#  --connect-timeout /
#  --max-time            : socket pendurado nao trava o worker; o prazo sai
#                          de $SLS_MAXTIME (45s por padrao).
#  -sS                   : sem progresso, mas mostra erros.
#
# Grava em $TMP/pagina o caminho da requisicao que sai: e aqui, e nao no
# fetch_page, porque o codigo de batalha chama run_curl direto.
_rc_track() {
    [ -n "$TMP" ] || return 0
    [ -n "$URL" ] || return 0
    # $TMP/.ult_req: a ULTIMA requisicao de verdade. O $TMP/pagina o
    # atualiza_stats restaura; este ninguem reescreve (o cq_pagina e o
    # full_relendo o comparam para saber se algo saiu depois de uma leitura).
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

    # PRAZO DAS PAGINAS DE BATALHA: 17s, NAO 45s. Resposta de luta depois de
    # 17s ja nao serve (a luta andou). Login, /train e o resto seguem com 45s.
    # So case e expansao, sem processo novo. SLS_MAXTIME vale por cima.
    _rc_mt="$SLS_MAXTIME"
    if [ -z "$_rc_mt" ]; then
        _rc_mt=45
        for _rc_a in "$@"; do
            case "$_rc_a" in
                "$URL"/*)
                    _rc_pp=${_rc_a#"$URL"/}
                    _rc_pp=${_rc_pp%%[/?]*}
                    case "$_rc_pp" in
                        king|undying|altars|clanfight|clandmgfight|clancoliseum|flagfight|coliseum|clancommand)
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

    # TELEMETRIA (lib/rede.sh): o curl escreve "M codigo tempo" em
    # $TMP/.req_meta; quem espera a requisicao (time_exit, fetch_page ou o
    # proprio run_curl) registra a linha em $TMP/req.stat (tele_registrar).
    # SLS_TELEMETRIA=0 desliga (o sls.sh desliga com curl antes da 7.63, que
    # nao tem o %{stderr} e o escreveria na pagina).
    _rc_tl=0
    if [ "${SLS_TELEMETRIA:-1}" = 1 ] && [ -n "$TMP" ] && [ -d "$TMP" ]; then
        set -- --stderr "$TMP/.req_meta" -w '%{stderr}M %{http_code} %{time_total} %{time_connect}\n' "$@"
        _rc_tl=1
    fi

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
    _rc_rc=$?
    [ "$_rc_tl" = 1 ] && tele_registrar "$_rc_rc"
    return "$_rc_rc"
}

# Uma linha por requisicao em $TMP/req.stat: "epoch codigo_http ms rc_curl"
# (lida pelo lib/rede.sh). So read, aritmetica e >>: nenhum processo, salvo o
# corte do arquivo a cada 300 linhas (fica com as 200 ultimas). Tambem diz
# se a conexao chegou a abrir: TE_CONECTOU=0 com %{time_connect} zero (o
# pedido nao saiu do aparelho; ver pedido_nao_saiu).
tele_registrar() {   # RC_DO_CURL
    [ -s "$TMP/.req_meta" ] || return 0
    _tl_c=""; _tl_t=""; _tl_k=""
    while read -r _tl_m _tl_a _tl_b _tl_e _tl_x; do
        [ "$_tl_m" = M ] && { _tl_c=$_tl_a; _tl_t=$_tl_b; _tl_k=$_tl_e; }
    done < "$TMP/.req_meta"
    : > "$TMP/.req_meta"
    case "$_tl_k" in
        0|0[.,]|0[.,]0*) case "${_tl_k#0}" in *[1-9]*) TE_CONECTOU=1 ;; *) TE_CONECTOU=0 ;; esac ;;
        '') ;;
        *) TE_CONECTOU=1 ;;
    esac
    unset _tl_k _tl_e
    case "$_tl_c" in [0-9][0-9][0-9]) ;; *) unset _tl_c _tl_t _tl_m _tl_a _tl_b _tl_x; return 0 ;; esac
    # "0.532113" (ou com virgula) em ms; zeros a esquerda fora (seriam octal).
    _tl_i=${_tl_t%%[.,]*}; _tl_d=${_tl_t#*[.,]}
    [ "$_tl_d" = "$_tl_t" ] && _tl_d=0
    _tl_d="${_tl_d}000"; _tl_d=${_tl_d%"${_tl_d#???}"}
    _tl_d=${_tl_d#0}; _tl_d=${_tl_d#0}
    case "$_tl_i" in ''|*[!0-9]*) _tl_i=0 ;; esac
    case "$_tl_d" in ''|*[!0-9]*) _tl_d=0 ;; esac
    if type agora_s > /dev/null 2>&1; then agora_s; else _AGORA=`date +%s`; fi
    printf '%s %s %s %s\n' "$_AGORA" "$_tl_c" $(( _tl_i * 1000 + _tl_d )) "${1:-0}" >> "$TMP/req.stat" 2>/dev/null
    _TL_N=$(( ${_TL_N:-0} + 1 ))
    if [ "$_TL_N" -ge 300 ]; then
        _TL_N=0
        tail -n 200 "$TMP/req.stat" > "$TMP/req.stat.t" 2>/dev/null && mv -f "$TMP/req.stat.t" "$TMP/req.stat"
    fi
    unset _tl_c _tl_t _tl_m _tl_a _tl_b _tl_x _tl_i _tl_d
    return 0
}

# Uso normal: roda o curl como filho e devolve a saida.
run_curl() { _rc_run "" "$@"; }

# Uso em segundo plano: o filho VIRA o curl (exec), sem shell parado
# esperando. O Android 12+ mata a sessao inteira acima de ~32 processos
# filhos, e cada processo por requisicao conta x6 contas.
run_curl_exec() { _rc_run "exec" "$@"; }

# Acessa qualquer pagina pelo caminho relativo (padrao: grava em $TMP/SRC).
# Falha: 1, codigo do curl em ERROR_DEBUG e $TMP/.curl_erro.
fetch_page() {
    relative_url="$1"
    output_file="${2:-$TMP/SRC}"

    # Link vazio: nao pede a Home (o chamador seguiria como se tivesse clicado).
    if [ -z "$relative_url" ]; then
        : > "$output_file"
        # A ultima pagina pedida aponta o modulo que chamou.
        printf "fetch_page sem link (depois de %s)\n" "`cat "${TMP:-.}/.ult_req" 2>/dev/null`" >> "${TMP:-.}/ERROR_DEBUG"
        return 1
    fi

    SLS_MAXTIME=17
    # -D: cabecalhos num arquivo, para registrar 429/5xx — o curl devolve 0
    # nesses casos. So registro: a pagina de erro nao e do jogo e o
    # sessao_estado ja a trata como "sem_resposta".
    : > "${TMP:-.}/.fp_hdr" 2>/dev/null
    run_curl_exec "${URL}${relative_url}" -D "${TMP:-.}/.fp_hdr" > "$output_file" 2>/dev/null &
    _fp_pid=$!
    unset SLS_MAXTIME

    # ESPACAMENTO: o "sleep 1" corre EM PARALELO com a requisicao, nao
    # depois (em serie somaria 1s a cada pagina). SLS_PACING=0 o dispensa
    # (ver time_exit).
    _fp_pace="${SLS_PACING:-1}"
    case "$_fp_pace" in ''|*[!0-9]*) _fp_pace=1 ;; esac
    [ "$_fp_pace" -gt 0 ] && sleep "$_fp_pace"

    wait "$_fp_pid" 2>/dev/null
    _fp_rc=$?
    unset _fp_pid _fp_pace
    [ -s "${TMP:-.}/.req_meta" ] && tele_registrar "$_fp_rc"

    if [ "$_fp_rc" != "0" ]; then
        printf "curl %s: %s\n" "$_fp_rc" "$relative_url" >> "${TMP:-.}/ERROR_DEBUG"
        # O painel mostra o codigo junto do "sem resposta" (60 = certificado).
        printf %s "$_fp_rc" > "${TMP:-.}/.curl_erro" 2>/dev/null
        unset _fp_rc
        return 1
    fi
    unset _fp_rc
    # Codigo HTTP da ultima resposta (depois dos redirects), sem processo:
    # so o read do shell. 4xx/5xx vai para o ERROR_DEBUG e para .http_erro.
    _fp_http=""
    while IFS=' ' read -r _fp_l1 _fp_l2 _fp_l3; do
        case "$_fp_l1" in HTTP/*) _fp_http="$_fp_l2" ;; esac
    done < "${TMP:-.}/.fp_hdr" 2>/dev/null
    case "$_fp_http" in
        [45][0-9][0-9])
            printf "http %s: %s\n" "$_fp_http" "$relative_url" >> "${TMP:-.}/ERROR_DEBUG"
            printf "%s %s\n" "$_fp_http" "`date +%s`" > "${TMP:-.}/.http_erro" 2>/dev/null ;;
    esac
    unset _fp_http _fp_l1 _fp_l2 _fp_l3
    return 0
}

# ============================================================
#  LEITURA DA PAGINA DE COMBATE — UMA PASSADA SO
#
#  Um unico awk (e nao grep/sed por campo): no evento todas as contas lutam
#  juntas e o Android 12 mata a sessao acima de ~32 processos.
#
#  Uso:  combate_ler SECAO HPER RPER ARQUIVO
#  Saida: imprime "1" se a pagina ainda e de luta, "0" se acabou.
#  Grava: ATK ATKRND DODGE HEAL STONE KINGATK GRASS HP HP2 RHP HLHP
#         no diretorio corrente.
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

# Link da erva so quando o botao nao cobra ouro — a mesma regra do
# combate_ler, para os modulos que nao o usam (Torneio e Duelo dos Clas).
erva_gratis() { # SECAO ARQUIVO
    awk -v sec="$1" '
        { t = t $0 " " }
        END {
            if (!match(t, "/" sec "/grass/[?]r[=][0-9]+")) exit
            l = substr(t, RSTART, RLENGTH)
            r = substr(t, RSTART + RLENGTH, 300)
            c = index(r, "</a>")
            if (c && tolower(substr(r, 1, c)) ~ /gold|ouro/) exit
            print l
        }' "$2" 2>/dev/null
}

# Erva e pedra de graca, num awk so: grava GRASS e STONE no diretorio
# corrente (vazio se nao ha ou se cobra ouro). Usado no Vale.
# O BOTAO COBRA OURO?   botao_pago ARQUIVO LINK
# Regra do dono: o bot nunca gasta ouro. Le o rotulo do botao, do link ate o
# </a> (o mesmo criterio do itens_gratis): com "gold" ou "ouro" ali, e pago.
# 0 = pago (nao clicar). Link ausente da pagina ou vazio: 1.
botao_pago() {
    [ -n "$2" ] || return 1
    awk -v l="$2" '{ t = t $0 " " } END {
        i = index(t, l); if (!i) exit 1
        r = substr(t, i + length(l), 300); c = index(r, "</a>")
        exit !(c && tolower(substr(r, 1, c)) ~ /gold|ouro/) }' "$1" 2>/dev/null
}

itens_gratis() { # SECAO ARQUIVO
    awk -v sec="$1" '
        function item(nome, arq,    l, r, c) {
            l = ""
            if (match(t, "/" sec "/" nome "/[?]r[=][0-9]+")) {
                l = substr(t, RSTART, RLENGTH)
                r = substr(t, RSTART + RLENGTH, 300)
                c = index(r, "</a>")
                if (c && tolower(substr(r, 1, c)) ~ /gold|ouro/) l = ""
            }
            if (l == "") printf "" > arq; else printf "%s\n", l > arq
            close(arq)
        }
        { t = t $0 " " }
        END { item("grass", "GRASS"); item("stone", "STONE") }' "$2" 2>/dev/null
}

# A sessao esta viva: carimba $TMP/last_ok. Usado dentro da luta, onde o
# descansar() nao pode rodar (voltaria a Home e abandonaria a batalha): o
# link de golpe so aparece para quem esta logado.
sessao_marcar() {
    date +%s > "$TMP/last_ok" 2>/dev/null
    # Pagina do jogo chegou: o servidor voltou (fecha o disjuntor, se aberto).
    [ -f "$HOME/.sls/net/${SLS_TAG:-BR}.aberto" ] && disjuntor_fechar resposta
    return 0
}


# SESSAO CAIDA OU SERVIDOR MUDO?   sessao_estado ARQUIVO   (ou "-" = stdin)
#
#   viva          pagina do jogo com a conta logada
#   deslogado     pagina do jogo SEM conta: a sessao caiu de verdade
#   sem_resposta  vazia, cortada ou nao e pagina do jogo: NAO DIZ NADA
#
# Servidor mudo nao e sessao caida: relogar a toa apaga o cookie e soma
# pedidos quando o servidor ja nao da conta.
#
# O SINAL E DO PROPRIO JOGO. Toda pagina do jogo termina com
#     jsInterface.event("user=12345;level=43")
# e a de quem nao esta logado com "user=0" (o /user anonimo e um "Error 404"
# sem formulario de login). Pagina cortada antes do rodape cai nos sinais do
# topo: formulario ou link de login = deslogado; icone de nivel = viva.
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
# de "sessao caida" quando a conta nao confirma a sessao ha minutos. Conta
# tambem para o disjuntor global.
servidor_mudo_marcar() {
    date +%s > "$TMP/last_rede" 2>/dev/null
    disjuntor_falha
    return 0
}

# DISJUNTOR GLOBAL DO SERVIDOR (um por servidor, comum as contas do aparelho)
#
# Com o servidor fora do ar, cada conta seguia tentando por conta propria —
# N contas pedindo justamente quando ele nao da conta. Quando
# SLS_DISJ_CONTAS (3) contas diferentes concluem "sem resposta" em
# SLS_DISJ_JANELA (30) s, o disjuntor abre: fora de batalha nenhuma conta
# pede nada (rotina, varredura e login seguram, ver disjuntor_segura) e so
# uma por vez sonda a Home a cada 20 s. Batalha continua (regra do dono):
# a luta tem hora. Fecha quando a sonda ou qualquer conta recebe uma pagina
# do jogo; as contas voltam escalonadas em 0-20 s ($$ % 21). Aberto ha mais
# de 30 min fecha sozinho (estado velho depois de um stop). SLS_DISJUNTOR=0
# desliga.
#
# Arquivos em ~/.sls/net/TAG.*: falha.CONTA (epoch da ultima falha daquela
# conta, um arquivo por conta), aberto e fechou (epoch), sonda (trava mkdir
# com o PID), sonda_ult (epoch da ultima sonda).
disjuntor_base() { _DJ="$HOME/.sls/net/${SLS_TAG:-BR}"; }

disjuntor_falha() {
    [ "${SLS_DISJUNTOR:-1}" = 0 ] && return 0
    disjuntor_base
    mkdir -p "$HOME/.sls/net" 2>/dev/null
    _dj_t=`date +%s`
    # UM ARQUIVO POR CONTA, cada uma escreve so o seu: antes as contas
    # anexavam num arquivo comum e cada uma o regravava (awk + mv); uma
    # falha anexada entre o awk e o mv de outra se perdia, e o disjuntor
    # abria tarde justamente com todas falhando juntas.
    _dj_c=${TMP:-$$}; _dj_c=${_dj_c##*/}
    echo "$_dj_t" > "$_DJ.falha.$_dj_c" 2>/dev/null
    if [ ! -f "$_DJ.aberto" ]; then
        # Contas com falha na janela, so com read (nenhum processo).
        _dj_n=0
        for _dj_f in "$_DJ".falha.*; do
            [ -f "$_dj_f" ] || continue
            _dj_x=""; { read -r _dj_x < "$_dj_f"; } 2>/dev/null
            case "$_dj_x" in ''|*[!0-9]*) continue ;; esac
            [ "$_dj_x" -ge $(( _dj_t - ${SLS_DISJ_JANELA:-30} )) ] && _dj_n=$(( _dj_n + 1 ))
        done
        unset _dj_f _dj_x
        if [ "$_dj_n" -ge "${SLS_DISJ_CONTAS:-3}" ]; then
            echo "$_dj_t" > "$_DJ.aberto" 2>/dev/null
            rm -f "$_DJ.fechou" 2>/dev/null
            printf "[disjuntor] %s fora do ar: %s contas sem resposta em %ss — fora de batalha, so a sonda pede\n" \
                "${SLS_TAG:-BR}" "$_dj_n" "${SLS_DISJ_JANELA:-30}"
        fi
    fi
    unset _dj_t _dj_n _dj_c
    return 0
}

disjuntor_fechar() {   # MOTIVO
    disjuntor_base
    [ -f "$_DJ.aberto" ] || return 0
    _dj_a=""; { read -r _dj_a < "$_DJ.aberto"; } 2>/dev/null
    _dj_t=`date +%s`
    rm -f "$_DJ.aberto" "$_DJ".falha.* 2>/dev/null
    echo "$_dj_t" > "$_DJ.fechou" 2>/dev/null
    case "$_dj_a" in ''|*[!0-9]*) _dj_a=$_dj_t ;; esac
    printf "[disjuntor] %s de volta (%s) depois de %ss — contas voltam em ate 20s\n" \
        "${SLS_TAG:-BR}" "$1" $(( _dj_t - _dj_a ))
    unset _dj_a _dj_t
    return 0
}

# TRAVAS mkdir (login no sls.sh, sonda do disjuntor): O DONO AINDA VALE?
#   trava_dono_vivo PID DIR   (0 = vale, espere)
# - PID vazio: so vale com a trava NOVA (ate 1 min). O dono grava o PID logo
#   depois do mkdir; morto entre os dois (SIGKILL do Android), a trava ficava
#   para sempre: o login esperava 180s a cada vez e a sonda nunca saia.
# - PID vivo mas de outro programa (o kernel recicla PIDs): nao vale. Sem
#   /proc legivel, vale o kill -0 (como antes).
trava_dono_vivo() {
    case "$1" in
        ''|*[!0-9]*) [ -z "`find "$2" -maxdepth 0 -mmin +1 2>/dev/null`" ]; return ;;
    esac
    kill -0 "$1" 2>/dev/null || return 1
    [ -r "/proc/$1/cmdline" ] || return 0
    case "`tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null`" in *sls.sh*) return 0 ;; esac
    return 1
}

# Tira uma trava velha sem derrubar a de quem acabou de criar outra: move
# (atomico), confere o dono do que foi movido e, se for uma trava viva
# criada entre a leitura e o mv, devolve.   trava_tomar DIR
trava_tomar() {
    mv "$1" "$1.velha.$$" 2>/dev/null || return 0
    _tt=""; { read -r _tt < "$1.velha.$$/pid"; } 2>/dev/null
    if trava_dono_vivo "$_tt" "$1.velha.$$"; then
        mv "$1.velha.$$" "$1" 2>/dev/null && { unset _tt; return 0; }
    fi
    rm -rf "$1.velha.$$" 2>/dev/null
    unset _tt
    return 0
}

# Uma sonda por vez no aparelho, no maximo a cada 20 s.
disjuntor_sondar() {   # AGORA
    _dj_u=0; { read -r _dj_u < "$_DJ.sonda_ult"; } 2>/dev/null
    case "$_dj_u" in ''|*[!0-9]*) _dj_u=0 ;; esac
    _dj_i=$(( $1 - _dj_u ))
    if [ "$_dj_i" -ge 0 ] && [ "$_dj_i" -lt 20 ]; then unset _dj_u _dj_i; return 0; fi
    if ! mkdir "$_DJ.sonda" 2>/dev/null; then
        _dj_p=""; { read -r _dj_p < "$_DJ.sonda/pid"; } 2>/dev/null
        if trava_dono_vivo "$_dj_p" "$_DJ.sonda"; then
            unset _dj_u _dj_i _dj_p; return 0
        fi
        trava_tomar "$_DJ.sonda"
        mkdir "$_DJ.sonda" 2>/dev/null || { unset _dj_u _dj_i _dj_p; return 0; }
    fi
    echo $$ > "$_DJ.sonda/pid" 2>/dev/null
    echo "$1" > "$_DJ.sonda_ult" 2>/dev/null
    SLS_MAXTIME=17
    run_curl "${URL}/" > "$TMP/.sonda" 2>/dev/null
    unset SLS_MAXTIME
    if [ "`sessao_estado "$TMP/.sonda"`" != sem_resposta ]; then
        disjuntor_fechar sonda
    fi
    rm -rf "$_DJ.sonda" "$TMP/.sonda" 2>/dev/null
    unset _dj_u _dj_i _dj_p
    return 0
}

# 0 = segure (sem pedir nada fora de batalha); 1 = siga.
disjuntor_segura() {
    [ "${SLS_DISJUNTOR:-1}" = 0 ] && return 1
    disjuntor_base
    if [ ! -f "$_DJ.aberto" ]; then
        # Volta escalonada: cada conta espera $$ % 21 s depois do fechamento.
        [ -f "$_DJ.fechou" ] || return 1
        _dj_f=""; { read -r _dj_f < "$_DJ.fechou"; } 2>/dev/null
        case "$_dj_f" in ''|*[!0-9]*) return 1 ;; esac
        [ "$_dj_f" = "${_DJ_LIBERADO:-}" ] && { unset _dj_f; return 1; }
        _dj_i=$(( `date +%s` - _dj_f ))
        if [ "$_dj_i" -lt 0 ] || [ "$_dj_i" -ge $(( $$ % 21 )) ]; then
            _DJ_LIBERADO=$_dj_f; unset _dj_f _dj_i; return 1
        fi
        unset _dj_f _dj_i
        return 0
    fi
    _dj_a=""; { read -r _dj_a < "$_DJ.aberto"; } 2>/dev/null
    case "$_dj_a" in ''|*[!0-9]*) _dj_a=0 ;; esac
    _dj_t=`date +%s`
    if [ $(( _dj_t - _dj_a )) -ge 1800 ] || [ "$_dj_t" -lt "$_dj_a" ]; then
        disjuntor_fechar "30 min aberto"
        unset _dj_a _dj_t
        return 1
    fi
    disjuntor_sondar "$_dj_t"
    unset _dj_a _dj_t
    # Quem sondou e achou o servidor de volta segue na hora.
    [ -f "$_DJ.aberto" ] && return 0
    disjuntor_base; _DJ_LIBERADO=""; { read -r _DJ_LIBERADO < "$_DJ.fechou"; } 2>/dev/null
    return 1
}

# INTERVALO MINIMO ENTRE LOGINS DE CONTAS DIFERENTES DO MESMO APARELHO.
# N logins do mesmo IP em poucos segundos recebem a resposta de senha errada.
# Chamada de dentro da trava (login_lock, em sls.sh), com carimbo comum a
# todas as contas. SLS_LOGIN_GAP=0 desliga.
LOGIN_STAMP="$HOME/.sls/.login.ultimo"
login_espacar() {
    _le_g=${SLS_LOGIN_GAP:-10}
    case "$_le_g" in ''|*[!0-9]*) _le_g=10 ;; esac
    [ "$_le_g" -gt 0 ] || { unset _le_g; return 0; }
    _le_u=0
    { read -r _le_u < "$LOGIN_STAMP"; } 2>/dev/null
    case "$_le_u" in ''|*[!0-9]*) _le_u=0 ;; esac
    # Carimbo no futuro (relogio voltou) nao segura ninguem.
    _le_u=$(( `date +%s` - _le_u ))
    [ "$_le_u" -ge 0 ] && [ "$_le_u" -lt "$_le_g" ] && sleep $(( _le_g - _le_u ))
    unset _le_g _le_u
    return 0
}
login_espacar_marcar() { date +%s > "$LOGIN_STAMP" 2>/dev/null; }

# O servidor esta mudo AGORA? A ultima conferencia de sessao (descanso, stats,
# login) nao teve resposta e nenhuma pagina respondeu depois dela.
#
# Carimbo com mais de 10 min (ou no futuro, relogio voltou) nao vale: enquanto
# o servidor seguir mudo, o descanso de cada volta carimba de novo.
servidor_mudo() {
    _sm_r=""; _sm_o=""
    { read -r _sm_r < "$TMP/last_rede"; } 2>/dev/null
    { read -r _sm_o < "$TMP/last_ok"; } 2>/dev/null
    case "$_sm_r" in ''|*[!0-9]*) unset _sm_r _sm_o; return 1 ;; esac
    case "$_sm_o" in ''|*[!0-9]*) _sm_o=0 ;; esac
    _sm_i=$(( `date +%s` - _sm_r ))
    [ "$_sm_r" -ge "$_sm_o" ] && [ "$_sm_i" -ge 0 ] && [ "$_sm_i" -lt 600 ]
    _sm_rc=$?
    unset _sm_r _sm_o _sm_i
    return $_sm_rc
}

# Primeiro link de ACAO de um evento (link_acao ARQUIVO SECAO). O link com
# nonce (?r=N) tem prioridade; o caminho nu "/SECAO/" so sai quando nao ha
# nenhuma acao (ele aparece em qualquer link da pagina).
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
#  O laco de luta so termina quando o JOGO declara:
#      morto   HP do cabecalho em 0, ou /<evento>/unrip/
#      fim     ?close=reward, ou o ?end_fight do coliseu
#  ou quando a propria pagina do evento, lida sem erro, passa LUTA_FORA_MAX
#  segundos seguidos sem nenhuma acao e sem o out_gate — a conta nao esta na
#  batalha. Se a conta JA LUTOU nesta batalha, bastam LUTA_FORA_LUTOU
#  segundos: sem botao de luta e sem ressurreicao na tela, a luta acabou para
#  ela. Leitura invalida nao conta para nada; sessao caida reconecta e
#  continua. A batalha fica gravada em $TMP/batalha desde a inscricao: o
#  worker relancado (SIGKILL do Android) volta para ela, e o descansar()
#  nunca confirma a fuga (/?out_gate_confirm=true) enquanto ela estiver
#  pendente.
# ============================================================

# Segundos seguidos sem sinal de luta, na pagina do evento, para aceitar que
# a conta nao esta na batalha. Cobre tambem o atraso do inicio.
LUTA_FORA_MAX="${LUTA_FORA_MAX:-90}"

# O MESMO "SEM LUTA", DEPOIS DE A CONTA TER LUTADO: 15s, NAO 90s.
# Nao na primeira pagina: a virada da morte do Rei troca a pagina por um
# instante, e o Imortal some com o golpe na troca de turno.
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
            # Pagina anonima pode vir sem formulario de login (ver
            # sessao_estado): o rodape user=0 ja prova a sessao caida.
            if (t ~ /jsInterface\.event\("user=0[^0-9]/) { print "deslogado"; exit }
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
    # A anotacao conta da INSCRICAO e o teto da luta (luta_teto) do inicio da
    # luta: no Rei, inscricao as :25 e luta podendo ir alem das :55. Com 10
    # min de folga a anotacao nao vence com a luta ainda permitida.
    _bp_min=$(( _bp_min + 10 ))
    _bp_t=$(( `date +%s` - _bp_t ))
    # Marca mais no futuro que o teto: o relogio voltou muito (data errada
    # corrigida) e ela nao vale. Um ajuste pequeno do NTP no meio da luta
    # continua valendo: sem a marca, o descansar confirmaria a fuga.
    [ "$_bp_t" -gt $(( -_bp_min * 60 )) ] && [ "$_bp_t" -lt $(( _bp_min * 60 )) ]
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
# Marcacao real, logo acima dos botoes (Rei e Torneio dos Clas):
#   <img .../race/1.png' alt=''/> Minha Conta <span class='nwr'>
#       <img src='/images/icon/health.png' alt='hp'/> 35656</span>      <- voce
#   <img .../race/0.png' alt=''/> Inimigo <span class='nwr'>
#       <img src='/images/icon/health.png' alt='hp'/>&nbsp;8092</span>  <- alvo
# O alvo e o do "&nbsp;" (o mesmo que o HP2 usa). "Rei" enquanto o rei vive.
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
# Procura 'txt smpl grey' fora do botao de trocar de alvo, que tambem a usa
# quando desativado e nao diz nada sobre o alvo:
#     <a class='nbtn b_grey' href='/clanfight/'><span class='lbl'>
#         <span class='txt smpl grey'>Troca o alvo</span>
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

# A CURA SAIU MESMO?   cura_relogio AGORA HP_ANTES HP_DEPOIS BOTAO(0|1) LA
#
# Pedido do dono (3.9.110). O relogio da cura (recarga de 90s) era gravado
# sempre que o pedido saia, mesmo quando o jogo recusava a cura (acao colada
# no ataque): a conta ficava 90s sem curar com o HP baixo. Devolve em
# CURA_RELOGIO o instante a gravar:
#   AGORA            a pagina confirma: o HP subiu, ou o botao da cura sumiu
#                    da resposta; tambem quando nao da para conferir (HP
#                    ilegivel), como antes;
#   AGORA - 90 + LA  sem confirmacao: uma nova tentativa LA segundos depois
#                    (so se a vida ainda estiver abaixo do limiar da luta).
# A segunda tentativa conta de qualquer jeito: no maximo dois pedidos por
# recarga. Se a primeira valeu (o HP so nao subiu pelo dano recebido), o
# proprio jogo recusa a segunda: o elixir tem recarga de 90s. Limiares e a
# recarga de 90s nao mudaram. So o primeiro numero do HP vale (o arquivo de
# HP de alguns modulos traz uma linha por ocorrencia).
#
# SO COM A RESPOSTA DA CURA COMPLETA (curl 0). Tempo esgotado depois de
# conectar, pagina cortada ou as tres tentativas sem conexao do
# pedido_nao_saiu: nao da para saber se o elixir foi usado, e a regra
# continua a de antes (a recarga conta, sem segundo elixir). O codigo e o
# TE_RC do pedido da cura; quem faz outro pedido depois dela (a erva do
# Torneio e do Duelo) o guarda antes em CURA_RC.
cura_relogio() {
    CURA_RELOGIO="$1"
    _cr_a=${2#"${2%%[0-9]*}"}; _cr_a=${_cr_a%%[!0-9]*}
    _cr_d=${3#"${3%%[0-9]*}"}; _cr_d=${_cr_d%%[!0-9]*}
    if [ "$4" = 1 ] && [ "${CURA_RC:-${TE_RC:-0}}" = 0 ] && \
       [ -n "$_cr_a" ] && [ -n "$_cr_d" ] && \
       [ "$_cr_d" -le "$_cr_a" ] && [ "${_CURA_TENTOU:-0}" = 0 ]; then
        _CURA_TENTOU=1
        CURA_RELOGIO=$(( $1 - 90 + ${5:-4} ))
        printf "Cura sem confirmacao (HP %s -> %s) - nova tentativa em %ss\n" "$_cr_a" "$_cr_d" "${5:-4}"
    else
        _CURA_TENTOU=0
    fi
    unset _cr_a _cr_d CURA_RC
}

# ESQUIVA NOS EVENTOS DE CLA (regra do dono, 3.9.112)
#
# Altares, Torneio dos Clas, Duelo, Coliseu do Cla e Torneio de Equipe. A
# esquiva so sai com as tres coisas juntas:
#   1. vida abaixo do limiar da cura (48% do HP maximo);
#   2. sem elixir para usar: sem o botao, ou o elixir na recarga de 90s.
#      Vem da ordem das acoes: a esquiva so e avaliada quando a cura nao
#      saiu, e com a vida abaixo do limiar a cura so nao sai sem o botao ou
#      na recarga;
#   3. dano muito alto: 20% ou mais do HP maximo perdidos nos ultimos 15s.
# A recarga da esquiva continua 20s. Antes ela saia com QUALQUER perda de
# vida desde a leitura anterior, com ou sem elixir.

# Vida perdida nos ultimos 15s.   dano_registrar HP   -> DANO_15S
# Cada leitura da pagina da luta entra em _DANO_HIST ("epoch:hp ..."), que
# fica so com os ultimos 15s; DANO_15S e o maior HP da janela menos o atual.
# So read e aritmetica, nenhum processo. So o primeiro numero do HP vale.
dano_registrar() {
    _dr_h=${1#"${1%%[0-9]*}"}; _dr_h=${_dr_h%%[!0-9]*}
    [ -n "$_dr_h" ] || return 0
    agora_s
    _dr_n=""; _dr_m=$_dr_h
    for _dr_e in $_DANO_HIST; do
        _dr_t=${_dr_e%%:*}; _dr_v=${_dr_e#*:}
        [ $(( _AGORA - _dr_t )) -le 15 ] || continue
        _dr_n="$_dr_n $_dr_e"
        [ "$_dr_v" -gt "$_dr_m" ] && _dr_m=$_dr_v
    done
    _DANO_HIST="$_dr_n $_AGORA:$_dr_h"
    DANO_15S=$(( _dr_m - _dr_h ))
    unset _dr_h _dr_n _dr_m _dr_e _dr_t _dr_v
}

# Esquivar agora?   esquiva_devida HP LIMIAR_DA_CURA HP_MAXIMO   (0 = sim)
# Itens 1 e 3 acima (o 2 e a ordem das acoes). Numero ilegivel: nao esquiva.
esquiva_devida() {
    _ev_h=${1#"${1%%[0-9]*}"}; _ev_h=${_ev_h%%[!0-9]*}
    case "$_ev_h$2$3" in ''|*[!0-9]*) unset _ev_h; return 1 ;; esac
    [ "$_ev_h" -lt "$2" ] && [ "${DANO_15S:-0}" -ge $(( $3 * 20 / 100 )) ]
    _ev_r=$?
    unset _ev_h
    return $_ev_r
}

# Zera a memoria da luta e anota a batalha. No INICIO de cada funcao de luta.
luta_inicio() {
    _CURA_TENTOU=0
    _DANO_HIST=""; DANO_15S=0
    _lt_fora_desde=""
    _lt_relogin=0
    _lt_invalidas=0
    _lt_teve_vida=0
    _lt_lutou=0
    _lt_hp0=0
    _reviveu=0
    _rs_falhas=0
    LUTA_MOTIVO=""
    LUTA_SESSAO_CAIU=0
    # Troca por aliado e fogo amigo (allies.sh).
    type aliado_zerar > /dev/null 2>&1 && aliado_zerar
    [ -n "$1" ] && batalha_marcar "$1"
    return 0
}

# MORTE COM A LUTA AINDA NA TELA.   luta_hp HP  ->  0 = morte confirmada
#
# Depois da morte a pagina pode CONTINUAR com botoes de acao e HP 0, e o
# estado_luta poe botao antes da morte. Chamada a cada leitura COM luta na
# tela. Um 0 isolado pode ser leitura falha, entao a morte so vale com TRES
# leituras seguidas em zero, e so depois de a conta ter tido vida na luta.
luta_hp() {
    # Chamada so com a luta na tela: a conta lutou (ver LUTA_FORA_LUTOU).
    _lt_lutou=1
    # A LUTA VOLTOU: a contagem do "fora" e das invalidas recomeca.
    _lt_fora_desde=""; _lt_invalidas=0
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
                # "luta": a reconexao da batalha nao espera o portao de
                # reconexao da rotina (relogin_liberado, em loginlogoff.sh).
                type login_logoff > /dev/null 2>&1 && login_logoff luta
                unset _lz_e; return 1
            fi
            # SEM SESSAO E SEM TENTATIVA AGORA: SAI DO LACO, NAO DA BATALHA.
            # A batalha continua em $TMP/batalha: o descansar reconecta no
            # ritmo dele e o batalha_retomar volta para a luta.
            LUTA_MOTIVO="sessao caiu e ainda nao reconectou (a batalha sera retomada)"
            LUTA_SESSAO_CAIU=1
            unset _lz_e; return 0
            ;;
        fora)
            # FIM ESCRITO PELO JOGO: Rei "Batalha finalizada!", Vale
            # "Vitoria!", Torneio "Luta acabou!". So depois de a conta ter
            # lutado: antes, o saguao do Rei mostra a batalha ANTERIOR.
            if [ "${_lt_lutou:-0}" = 1 ] && \
               grep -q -E 'Batalha finalizada!|Vit[^ <]{1,8}ria!|Luta acabou!' "$1" 2>/dev/null; then
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
            # invalida: nao conta para o "fora". Da terceira seguida em diante
            # (rede fora), respira 3s entre as releituras.
            _lt_invalidas=$(( ${_lt_invalidas:-0} + 1 ))
            [ "$_lt_invalidas" -ge 3 ] && sleep 3
            unset _lz_e; return 1
            ;;
    esac
}

# HP MAXIMO PARA A LUTA: grava o FIXHP no arquivo do evento (FULL, flag_full,
# ccol_full, col_full); o /train de reserva so sai sem FIXHP valido.
full_atualizar() { # arquivo_do_HP_maximo
    # Regra do dono: HP maximo conferido no INICIO DA BATALHA (o limiar de
    # cura sai dele). Lido ha menos de 10 min, vale o que esta. Na retomada
    # de uma luta em andamento nao rele. Prazo de 17s, como as paginas de luta.
    if [ "${_BR_ATIVO:-0}" != 1 ]; then
        SLS_MAXTIME=17
        fetch_train_stats 10 2>/dev/null
        unset SLS_MAXTIME
    fi
    case "$FIXHP" in
        ''|0|*[!0-9]*) ;;
        *) printf '%s\n' "$FIXHP" > "$1" 2>/dev/null; return 0 ;;
    esac
    # Num temporario: o /train sem resposta deixava o arquivo VAZIO, e com HP
    # maximo zero a conta nao cura na luta. Assim fica o que havia.
    (
        run_curl_exec "$URL/train" | grep -o -E '\(([0-9]+)\)' | head -n1 | sed 's/[()]//g' > "$1.tmp"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17
    if [ -s "$1.tmp" ]; then mv -f "$1.tmp" "$1"; else rm -f "$1.tmp"; fi
    return 0
}

# HP MAXIMO ANTES DE AGIR NUMA PAGINA JA LIDA.   full_relendo FULL CAMINHO ARQ
#
# O full_atualizar pode pedir o /train (leitura com mais de 10 min). Saindo
# esse pedido entre a leitura da pagina e o clique, o nonce (?r=) dela ja nao
# vale e o servidor recusa a acao (ver clanquest.sh). Quando algum pedido
# saiu (o .ult_req mudou), rele CAMINHO em ARQ.
#   0 = releu (quem chama tira os links de novo), 1 = nada saiu.
full_relendo() {
    _fr_ur=""; { read -r _fr_ur < "$TMP/.ult_req"; } 2>/dev/null
    full_atualizar "$1"
    _fr_ur2=""; { read -r _fr_ur2 < "$TMP/.ult_req"; } 2>/dev/null
    if [ "$_fr_ur2" = "$_fr_ur" ]; then
        unset _fr_ur _fr_ur2
        return 1
    fi
    unset _fr_ur _fr_ur2
    (
        run_curl_exec "${URL}$2" > "$3"
    ) </dev/null > /dev/null 2>&1 &
    time_exit 17
    return 0
}

# Alvo da inscricao, escalonado por conta: MMSS base mais 0 a VAO-1 segundos
# (VAO padrao 30), fixo por PID. N inscricoes do mesmo IP no mesmo segundo
# sao a rajada que o servidor estrangula. O Rei, os Altares, o Coliseu do Cla
# e o Vale usam VAO 10 a partir de :x9:50 (a espera deles rele a cada 2-3s).
janela_alvo() { # MMSS_base [VAO] -> MMSS
    printf '%s' $(( $1 + $$ % ${2:-30} ))
}

# ESPERA ATE UMA HORA DO RELOGIO — NUNCA A DA HORA SEGUINTE.
#
#   espera_janela DE ATE      (MMSS: espera_janela 5500 5930)
#
# Dorme enquanto o relogio estiver em [DE, ATE). Passou de ATE — ou o minuto
# ja virou e ficou abaixo de DE —, sai na hora (esperar o relogio MOSTRAR
# uma hora prenderia por uma hora quem chega atrasado).
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
# O "/SECAO/unrip/" so aparece na pagina de quem morreu: sem unrip, nao faz
# nada e nao pede nada (pode ser chamada sem medo antes de encerrar).
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
    # Grava a pagina do unrip em ARQUIVO: os nonces (?r=) da anterior morreram.
    (
        run_curl_exec "${URL}${_rs_l}" > "$2"
    ) </dev/null > /dev/null 2>&1 &
    # PEDIDO SEM RESPOSTA (ou cortado, curl 18/56) NAO GASTA A RESSURREICAO:
    # ate duas novas tentativas por luta.
    if ! time_exit 17 || [ "${TE_RC:-0}" != 0 ] || [ ! -s "$2" ]; then
        _rs_falhas=$(( ${_rs_falhas:-0} + 1 ))
        [ "$_rs_falhas" -le 2 ] && _reviveu=0
    fi
    unset _rs_l
    return 0
}

hpmp() {
    # INICIO DO VALE (-fix): HP e mana maximos relidos se a leitura tem mais
    # de 10 min (ver full_atualizar). O /train de baixo so sai se o
    # fetch_train_stats nao acabou de ler um com o HP maximo.
    _hp_fix=0; _hp_leu=0
    case " $* " in
        *" -fix "*)
            _hp_fix=1
            _hp_ur=""; { read -r _hp_ur < "$TMP/.ult_req"; } 2>/dev/null
            SLS_MAXTIME=17
            if fetch_train_stats 10 2>/dev/null; then
                _hp_ur2=""; { read -r _hp_ur2 < "$TMP/.ult_req"; } 2>/dev/null
                # Leu e achou o HP maximo: outro /train daria a mesma pagina.
                [ "$_hp_ur2" = "$_hp_ur" ] || [ -z "$FIXHP" ] || _hp_leu=1
            fi
            unset SLS_MAXTIME _hp_ur _hp_ur2 ;;
    esac
    # HP e mana maximos ja lidos neste processo: sem outro /train.
    if [ "$_hp_fix" = 1 ] && [ "$_hp_leu" = 0 ] && { [ -z "$FIXHP" ] || [ -z "$FIXMP" ]; }; then
        (
            run_curl_exec "$URL/train" > "$TMP/TRAIN"
        ) </dev/null > /dev/null 2>&1 &
        time_exit 20
        _fx=`grep -o -E '\(([0-9]+)\)' "$TMP/TRAIN" | head -n1 | sed 's/[()]//g'`
        [ -n "$_fx" ] && FIXHP=$_fx
        FIXMP=`grep -o -E ': [0-9]+' "$TMP/TRAIN" | sed -n '5s/: //p'`
    fi
    unset _hp_fix _hp_leu

    # Mesma leitura do parse_status (ate 40 nao-digitos entre icone e numero).
    NOWHP=`grep -o -E "health\.png' alt='hp'/>[^0-9]{0,40}[0-9]{1,9}" "$TMP/SRC" | grep -o -E '[0-9]{1,9}$' | head -n1`
    NOWMP=`grep -o -E "mana\.png' alt='mp'/>[^0-9]{0,40}[0-9]{1,9}" "$TMP/SRC" | grep -o -E '[0-9]{1,9}$' | head -n1`

    # FIXHP/FIXMP vazios (requisicao cortada): sem divisao por zero.
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

# Os cinco numeros do cabecalho (HP, energia, nivel, ouro, prata) de uma
# pagina em ACC_HP, ACC_MP, ACC_LVL, ACC_GOLD e ACC_SILVER, sem gravar nada.
# Padroes do HTML real:
#   health.png' alt='hp'/> <span class='white'>65312</span>
#   mana.png' alt='mp'/> 346
#   icon/level.png' alt='lvl'/> 90
#   icon/gold.png' alt='g'/> 396
#   icon/silver.png' alt='s'/> 408,1M
# Ate 40 nao-digitos entre icone e numero (o jogo intercala tags): o numero
# e sempre o PRIMEIRO depois do icone. Um grep para os cinco; vale o
# primeiro de cada icone. Ouro e prata ficam como o jogo mostra ("408,1M").
status_ler() {
    ACC_HP=""; ACC_MP=""; ACC_LVL=""; ACC_GOLD=""; ACC_SILVER=""
    _ps_l=`printf '%s' "$1" | grep -o -E \
        -e "health\.png' alt='hp'/>[^0-9]{0,40}[0-9]{1,9}" \
        -e "mana\.png' alt='mp'/>[^0-9]{0,40}[0-9]{1,9}" \
        -e "level\.png' alt='[^']*'/>[^0-9]{0,40}[0-9]{1,4}" \
        -e "gold\.png' alt='g'/>[^0-9]{0,40}[0-9][0-9.,']{0,14}[KMBkmb]?" \
        -e "silver\.png' alt='s'/>[^0-9]{0,40}[0-9][0-9.,']{0,14}[KMBkmb]?"`
    while IFS= read -r _ps_x; do
        case "$_ps_x" in
            health*) [ -n "$ACC_HP" ]     || ACC_HP=${_ps_x##*[!0-9]} ;;
            mana*)   [ -n "$ACC_MP" ]     || ACC_MP=${_ps_x##*[!0-9]} ;;
            level*)  [ -n "$ACC_LVL" ]    || ACC_LVL=${_ps_x##*[!0-9]} ;;
            gold*)   [ -n "$ACC_GOLD" ]   || ACC_GOLD=${_ps_x#"${_ps_x%%[0-9]*}"} ;;
            silver*) [ -n "$ACC_SILVER" ] || ACC_SILVER=${_ps_x#"${_ps_x%%[0-9]*}"} ;;
        esac
    done <<EOF
$_ps_l
EOF
    unset _ps_l _ps_x
}

parse_status() {
    _pg="$1"
    [ -n "$_pg" ] || return 1

    # Cabecalho de uma pagina ja baixada -> $TMP/stats (lido pelo painel do
    # play.sh), sem requisicao extra. Campo nao lido vira "-".
    _lvl_ant="$ACC_LVL"
    status_ler "$_pg"
    # Subiu de nivel: HP maximo e teto de energia mudaram (ver fetch_train_stats).
    [ -n "$_lvl_ant" ] && [ -n "$ACC_LVL" ] && [ "$_lvl_ant" != "$ACC_LVL" ] && \
        rm -f "$TMP/last_train" 2>/dev/null
    unset _lvl_ant

    NOWHP="$ACC_HP"; NOWMP="$ACC_MP"

    # MAXIMO DA CONTA: O QUE O BOT LE DELA, NUNCA ABAIXO DO VALOR ATUAL.
    # Regra do dono: vale o maior entre o teto do /train (FIXHP, ACC_ENE) e
    # o MAIOR VALOR JA VISTO no cabecalho (recomeca ao subir de nivel), em
    # $TMP/conta_max ("nivel hp energia"). So painel e log usam isto; as
    # batalhas seguem com o FIXHP.
    _mx_n=""; _mx_h=0; _mx_e=0
    { read -r _mx_n _mx_h _mx_e < "$TMP/conta_max"; } 2>/dev/null
    case "$_mx_h" in ''|*[!0-9]*) _mx_h=0 ;; esac
    case "$_mx_e" in ''|*[!0-9]*) _mx_e=0 ;; esac
    if [ -n "$ACC_LVL" ] && [ "$ACC_LVL" != "$_mx_n" ]; then
        _mx_n="$ACC_LVL"; _mx_h=0; _mx_e=0
    fi
    _mx_ant="$_mx_n $_mx_h $_mx_e"
    [ -n "$ACC_HP" ] && [ "$ACC_HP" -gt "$_mx_h" ] && _mx_h="$ACC_HP"
    [ -n "$ACC_MP" ] && [ "$ACC_MP" -gt "$_mx_e" ] && _mx_e="$ACC_MP"
    [ "$_mx_n $_mx_h $_mx_e" = "$_mx_ant" ] || \
        echo "$_mx_n $_mx_h $_mx_e" > "$TMP/conta_max" 2>/dev/null
    # O teto do /train, quando maior. A energia so vale como numero inteiro:
    # separador de milhar sai, valor com sufixo (K/M) fica de fora.
    case "$FIXHP" in ''|*[!0-9]*) ;; *) [ "$FIXHP" -gt "$_mx_h" ] && _mx_h="$FIXHP" ;; esac
    # Sem separador (o caso comum), sem tr.
    case "$ACC_ENE" in
        *[.,\']*) _mx_t=`printf '%s' "$ACC_ENE" | tr -d ".,'"` 2>/dev/null ;;
        *)        _mx_t="$ACC_ENE" ;;
    esac
    case "$_mx_t" in ''|*[!0-9]*) ;; *) [ "$_mx_t" -gt "$_mx_e" ] && _mx_e="$_mx_t" ;; esac

    if [ -n "$ACC_HP" ] && [ "$_mx_h" -gt 0 ]; then
        HPPER=`awk -v a="$ACC_HP" -v b="$_mx_h" 'BEGIN{printf "%.0f", a/b*100}'`
    else
        HPPER=""
    fi

    # ENERGIA: "atual/teto" (ex.: 809/2109). ACC_MP (cabecalho) e o valor que
    # muda; o teto e o maximo da conta, acima. Sem teto, so o atual.
    _ene_campo="-"
    if [ -n "$ACC_MP" ] && [ "$_mx_e" -gt 0 ]; then
        _ene_campo="${ACC_MP}/${_mx_e}"
    elif [ -n "$ACC_MP" ]; then
        _ene_campo="$ACC_MP"
    fi

    # O ultimo campo e o HP maximo da conta: o painel mostra o HP em
    # percentual dele. Ainda sem leitura, vazio (o painel mostra o numero).
    [ "$_mx_h" -gt 0 ] || _mx_h=""
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "${ACC:-$SLS_USER}" "${ACC_HP:--}" "${ACC_MP:--}" "$_ene_campo" \
        "${ACC_LVL:--}" "${ACC_GOLD:--}" "${ACC_SILVER:--}" "$(date +%s)" \
        "$_mx_h" > "$TMP/stats" 2>/dev/null
    unset _ene_campo _mx_n _mx_h _mx_e _mx_ant _mx_t

    unset _pg
}

# Dados que so existem na pagina /train: HP maximo e energia.
# Uma requisicao por ciclo de start(), nao por minuto.
fetch_train_stats() {
    # ACC_ENE e zerado antes de ler: leitura que falha vira "-" no painel, e
    # nao um numero congelado. O FIXHP (HP maximo) mantem o ultimo valor de
    # proposito: so muda ao subir de nivel, e as lutas dependem dele.
    #
    # INTERVALO: fetch_train_stats [MINUTOS], 60 por padrao (painel); no
    # inicio de cada batalha o full_atualizar pede 10. O parse_status apaga
    # o last_train quando o nivel muda. Sem HP maximo conhecido, le sempre.
    _ft_min="${1:-60}"
    case "$_ft_min" in ''|*[!0-9]*) _ft_min=60 ;; esac
    # Energia que a ultima leitura do /train nao achou (_FT_SEM_ENE) tambem
    # espera o intervalo: sem isso, um rotulo que o grep nao casa fazia todo
    # login_logoff e todo painel pedirem o /train de novo.
    if [ -n "$FIXHP" ] && { [ -n "$ACC_ENE" ] || [ "${_FT_SEM_ENE:-0}" = 1 ]; } && \
       ! ativ_liberada train "$_ft_min"; then
        unset _ft_min
        return 0
    fi
    unset _ft_min
    ACC_ENE=""

    _t=`run_curl "${URL}/train" 2>/dev/null`
    [ -n "$_t" ] || return 1
    # Pagina de erro ou de login nao traz o HP maximo: mantem o ultimo lido
    # (vazio zeraria o limiar de cura). So a leitura com o HP maximo carimba.
    _fx=`printf '%s' "$_t" | grep -o -E '\([0-9]{1,9}\)' | head -n1 | tr -d '()'`
    _ft_hp=0
    [ -n "$_fx" ] && FIXHP=$_fx && _ft_hp=1 && date +%s > "$TMP/last_train" 2>/dev/null
    _fx=`printf '%s' "$_t" | grep -o -E ': [0-9]+' | sed -n '5s/: //p'`
    [ -n "$_fx" ] && FIXMP=$_fx
    unset _fx
    # Teto de energia, com o sufixo K/M. Mesma regra do status_ler: entre o
    # rotulo e o numero vem "</span> <span class='white'>".
    ACC_ENE=`printf '%s' "$_t" | grep -o -E "Energia:?[^0-9]{0,40}[0-9][0-9.,']{0,14}[KMBkmb]?" | grep -o -E "[0-9][0-9.,']{0,14}[KMBkmb]?$" | head -n1`
    # Pagina com o HP maximo e sem a energia: a falta e da pagina, nao da rede.
    _FT_SEM_ENE=0
    [ -z "$ACC_ENE" ] && [ "$_ft_hp" = 1 ] && _FT_SEM_ENE=1
    unset _t _ft_hp
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
# O /fights/ lista, sob cada evento, o HORARIO ABSOLUTO e uma descricao
# livre (ignorada):
#
#   Vale dos Imortais
#   10:00 BRT - Tempo para o inicio 1 hora
#   16:00 BRT - Tempo para o inicio 7 horas
#   Coliseu do cla
#   10:30 BRT - Nova temporada comeca em 7 de Setembro
#
# Escreve uma linha por horario, ordenada: HHMM|Nome
# Uma requisicao por ciclo de start(), e o painel apenas le o arquivo.
atualiza_agenda() {
    _ag="$HOME/.sls/agenda"

    SLS_MAXTIME=17
    _pg=`run_curl "${URL}/fights/" 2>/dev/null`
    unset SLS_MAXTIME
    [ -n "$_pg" ] || return 1

    # Temporario com o PID: a agenda e comum a todas as contas (~/.sls).
    _tmpf="${_ag}.$$.tmp"
    _rawf="${_ag}.$$.raw"
    : > "$_tmpf"

    # Nome do evento OU um horario absoluto "HH:MM BRT". O nome do fuso e
    # aceito de forma generica (BRT/BRST/qualquer sigla) para o parser nao
    # quebrar no horario de verao.
    printf '%s' "$_pg" \
        | sed 's/<br[^>]*>/\n/g; s/<\/div>/\n/g; s/<[^>]*>//g' \
        | grep -oE "(Vale dos Imortais|Coliseu do clã|Torneio dos Clãs|Rei dos Imortais|Altares dos Deuses|Batalha de Bandeiras|Torneio de equipe)|[0-9]{1,2}:[0-9]{2} [A-Z]{2,5}" \
        > "$_rawf" 2>/dev/null

    # Um evento tem VARIOS horarios: o nome vale ate aparecer o proximo.
    # Horario sem nome antes e descartado. Le de ARQUIVO, nao de pipe (no
    # pipe o laco roda em subshell e o "$_nome" se perderia).
    _nome=""
    while IFS= read -r _ln; do
        case "$_ln" in
            [0-9]*:[0-9]*)
                [ -n "$_nome" ] || continue
                _h=${_ln%%:*}
                _m=${_ln#*:}; _m=${_m%% *}
                case "$_h$_m" in *[!0-9]*) continue ;; esac
                # Zeros a esquerda removidos na mao: "$((10#$_h))" e bashism
                # (o dash recusa) e "08" seria octal para varios printf.
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

    # Ordena: o proximo_evento do play.sh para no primeiro horario maior que
    # agora, e o /fights/ nao vem em ordem cronologica.
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
    # Sem sufixo o valor e inteiro: ponto ou virgula ali e milhar ("54.300").
    if [ "$_mu" = 1 ]; then
        _dg=`printf '%s' "$_v" | tr -cd '0-9'`
    else
        _dg=`printf '%s' "$_v" | tr -d "'" | tr ',' '.' | tr -cd '0-9.'`
    fi
    [ -z "$_dg" ] && { echo 0; return; }
    awk -v d="$_dg" -v m="$_mu" 'BEGIN{ printf "%.0f", d*m }'
    unset _v _mu _dg
}
