#!/bin/sh
# panel.sh - Painel do solucaoshell (biblioteca, nao roda sozinho)
#
# Compartilhado pelo play.sh e pelo status.sh. Por padrao e SOMENTE LEITURA:
# desenha o que os workers escreveram em ~/.sls e nao toca em processo nenhum.
# PANEL_SUPERVISE=1 (play.sh) faz o laco relancar worker morto; o status.sh
# deixa em 0 e pode ser aberto e fechado sem derrubar conta nenhuma.
#
# Espera de quem sourceia: SLSDIR, STATUS_DIR, ACCOUNTS_FILE,
# server_tag(), clean_field() e — so quando PANEL_SUPERVISE=1 — launch_worker().

# ============================================================
#  PAINEL
#  So faz sentido com terminal; sem tty (systemd, saida redirecionada)
#  o laco segue supervisionando, em silencio.
# ============================================================
if [ -t 1 ]; then HAS_TTY=1; else HAS_TTY=0; fi

# Padrao para quem carrega sem LIBDIR: vazio, "$LIBDIR"/*.sh viraria "/*.sh".
: "${LIBDIR:=${SLSDIR:-.}/lib}"

# Cores
C_RESET='\033[0m';   C_DIM='\033[2m';      C_BOLD='\033[1m'
C_CYAN='\033[1;36m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'
C_RED='\033[1;31m';  C_WHITE='\033[1;37m'
# 256 cores (Termux, WSL e iSH desenham): nome das contas e nivel.
C_LARANJA='\033[1;38;5;166m'
C_LINHA='\033[38;5;240m'
# ESC de verdade: as constantes acima so viram cor no printf %b, e o awk
# do registro de combate imprime direto.
ESC=$(printf '\033')

# Emoji, simbolos simples ou texto:
#     1  emoji        🧡 🔋 ▲ 💰 🥈
#     2  simbolos     ♥ ◆ ▲ ¤ ○        (1 coluna, fonte comum)
#     0  texto        HP Eng LV Ouro PR
# O modo 1 precisa de fonte de emoji no terminal; o Termux de aparelho comum
# (Moto E22 e afins) nao tem e mostra caixa vazia (trocar um emoji por outro
# nao resolve). Por isso o padrao: Android/Termux -> 2, qualquer outro -> 1.
# A escolha manual sempre ganha: "echo N > ~/.sls/emoji" vale para play.sh e
# status.sh e sobrevive a reinicio; SLS_EMOJI=N tem prioridade, so naquele
# comando. "./status.sh -icones" desenha os tres para escolher olhando.

# E Android? getprop (so existe no Android), PREFIX do Termux ou "uname -o":
# qualquer pista basta. Em cache: o painel se redesenha a cada poucos segundos.
painel_e_android() {
    case "${_ANDROID_CACHE:-}" in
        1) return 0 ;;
        0) return 1 ;;
    esac
    _ANDROID_CACHE=0
    case "${PREFIX:-}" in
        *com.termux*) _ANDROID_CACHE=1 ;;
    esac
    [ "$_ANDROID_CACHE" = 0 ] && [ "`uname -o 2>/dev/null`" = "Android" ] \
        && _ANDROID_CACHE=1
    [ "$_ANDROID_CACHE" = 0 ] && command -v getprop > /dev/null 2>&1 \
        && _ANDROID_CACHE=1
    [ "$_ANDROID_CACHE" = 1 ]
}

# De onde veio o modo, para o "-icones" saber explicar.
SLS_EMOJI_FONTE=ambiente
if [ -z "$SLS_EMOJI" ] && [ -r "$HOME/.sls/emoji" ]; then
    SLS_EMOJI_FONTE=arquivo
    read -r SLS_EMOJI < "$HOME/.sls/emoji" 2>/dev/null || :
fi
# So 0, 1 e 2 valem; lixo cai no automatico. (Use "echo", que nao poe CR.)
case "$SLS_EMOJI" in
    0|1|2) ;;
    *)     SLS_EMOJI="" ;;
esac
if [ -z "$SLS_EMOJI" ]; then
    SLS_EMOJI_FONTE=automatico
    if painel_e_android; then SLS_EMOJI=2; else SLS_EMOJI=1; fi
fi

# Carrega um conjunto de icones. O modo vem por ARGUMENTO para o "-icones"
# desenhar os tres e depois devolver o que estava valendo.
painel_icones_carregar() {
    # HP, energia, nivel, ouro e prata sao TEXTO em todos os modos (pedido do
    # dono). Os simbolos de estado de um modo tem os mesmos bytes e colunas,
    # para o nome cair sempre na mesma coluna.
    if [ "$1" = "1" ]; then
        # Nenhum icone usa seletor de variacao (U+FE0F): o terminal que ignora
        # o seletor desenha o glifo de texto ou caixa. Todos sao codepoint
        # unico do bloco de pictogramas. Estados: 4 bytes e 2 colunas cada.
        S_COL=2
        I_ARROW="›"; I_LIVE="💥 "
        # Tabela: desenho de caixa, que toda fonte monoespacada cobre.
        T_V="│"; T_H="─"; T_X="┼"; T_B="┴"; T_D="╌"; T_RET="…"
        # COLUNAS (nao bytes) do prefixo "ao vivo": 2 do glifo + o espaco.
        LIVE_W=3
        S_ON="🟢"; S_WAIT="🟡"; S_ERR="🔴"; S_OFF="🌑"; S_UNK="🔘"; S_PAUSE="💤"
        A_CLANFIGHT="🏆  Torneio do Clã";   A_ALTARES="🔥  Altares dos Deuses"
        A_VALE="🌘  Vale dos Imortais";     A_REI="👑  Rei dos Imortais"
        A_CLANCOL="🏅  Coliseu do Clã"
        A_ARENA="💥  Arena"
        A_TORNEQ="⚔️  Torneio de Equipe"
    else
        # Em texto puro byte e coluna sao a mesma coisa.
        S_COL=5
        I_ARROW=">"; I_LIVE=""
        T_V="|"; T_H="-"; T_X="+"; T_B="+"; T_D="-"; T_RET="~"
        LIVE_W=0
        S_ON="[on]"; S_WAIT="[..]"; S_ERR="[off]"; S_OFF="[--]"; S_UNK="[??]"; S_PAUSE="[||]"
        A_CLANFIGHT="Torneio do Clã";   A_ALTARES="Altares dos Deuses"
        A_VALE="Vale dos Imortais";     A_REI="Rei dos Imortais"
        A_CLANCOL="Coliseu do Clã"
        A_ARENA="Arena"
        A_TORNEQ="Torneio de Equipe"

        # Modo 2: troca so os icones, mantendo os nomes de atividade em texto.
        if [ "$1" = "2" ]; then
            # Estados de 3 bytes e 1 coluna cada.
            S_COL=1
            I_ARROW="›"; I_LIVE="» "
            T_V="│"; T_H="─"; T_X="┼"; T_B="┴"; T_D="╌"; T_RET="…"
            LIVE_W=2
            S_ON="●"; S_WAIT="◐"; S_ERR="✕"; S_OFF="○"; S_UNK="◇"; S_PAUSE="‖"
        fi
    fi
}

painel_icones_carregar "$SLS_EMOJI"

# Densidade da tela (DPI). So serve de PALPITE quando nao da para medir a
# janela (arquivo, pipe, tmux sem tty); a medida do stty sempre ganha.
# getprop le propriedade do sistema, sem root; fora do Android nao existe.
#   persist.sys.lcd_density   densidade escolhida pelo usuario ("wm density")
#   ro.sf.lcd_density         densidade de fabrica
# Em cache: densidade nao muda com o painel aberto.
painel_dpi() {
    case "${_DPI_CACHE:-}" in
        ''|*[!0-9]*) ;;
        *) printf '%s' "$_DPI_CACHE"; return 0 ;;
    esac
    command -v getprop > /dev/null 2>&1 || return 1
    for _dp in persist.sys.lcd_density ro.sf.lcd_density; do
        _dv=$(getprop "$_dp" 2>/dev/null)
        case "$_dv" in ''|*[!0-9]*) continue ;; esac
        [ "$_dv" -ge 100 ] && [ "$_dv" -le 1000 ] || continue
        _DPI_CACHE="$_dv"
        printf '%s' "$_dv"
        unset _dp _dv
        return 0
    done
    unset _dp _dv
    return 1
}

# Colunas presumidas pela densidade (fonte padrao do Termux, tela de 1080 px):
#   >= 480 dpi   38   telas muito densas (1440p em 6")
#   >= 400 dpi   42   a maioria dos 1080p atuais
#   >= 340 dpi   48   Motorola e similares (346-360 dpi)
#   >= 280 dpi   56   720p e telas com densidade reduzida na mao
#    < 280 dpi   64   tablet ou densidade bem baixa
# Sem getprop (PC, WSL, iSH) devolve o padrao recebido em $1.
painel_cols_dpi() {
    _cd=$(painel_dpi) || { printf '%s' "$1"; return 0; }
    if   [ "$_cd" -ge 480 ]; then printf '38'
    elif [ "$_cd" -ge 400 ]; then printf '42'
    elif [ "$_cd" -ge 340 ]; then printf '48'
    elif [ "$_cd" -ge 280 ]; then printf '56'
    else                          printf '64'
    fi
    unset _cd
}

# Calcula a largura em PAINEL_LARG e a origem em PAINEL_LARG_FONTE.
# SEM subshell de proposito: em "$(...)" a origem e o cache do DPI morreriam
# no processo filho, e custaria um fork por redesenho.
painel_largura_calc() {
    # 1) Override do momento: SLS_COLS=50 ./status.sh
    PAINEL_LARG_FONTE=SLS_COLS
    case "${SLS_COLS:-}" in
        ''|*[!0-9]*) ;;
        *) PAINEL_LARG="$SLS_COLS"; return 0 ;;
    esac

    # 2) Largura fixada pelo usuario (echo 46 > ~/.sls/cols), para fonte
    #    grande no Termux. "./status.sh -cols" acha o numero certo.
    PAINEL_LARG_FONTE=arquivo
    if [ -r "$HOME/.sls/cols" ]; then
        read -r _pw < "$HOME/.sls/cols" 2>/dev/null || _pw=""
        case "$_pw" in
            ''|*[!0-9]*) ;;
            *) [ "$_pw" -ge 20 ] && { PAINEL_LARG="$_pw"; return 0; } ;;
        esac
    fi

    # 3) Medida de verdade: stty (le a janela REAL), tput (precisa do ncurses)
    #    e $COLUMNS (so em shell interativo, nao acompanha o giro da tela).
    PAINEL_LARG_FONTE=stty
    # "linhas colunas": o corte e do shell, sem cut.
    _pw=$(stty size 2>/dev/null); _pw=${_pw##* }
    case "$_pw" in ''|*[!0-9]*) _pw="" ;; esac
    if [ -z "$_pw" ] && command -v tput > /dev/null 2>&1; then
        PAINEL_LARG_FONTE=tput
        _pw=$(tput cols 2>/dev/null)
        case "$_pw" in ''|*[!0-9]*) _pw="" ;; esac
    fi
    if [ -z "$_pw" ]; then
        PAINEL_LARG_FONTE=COLUMNS
        _pw="$COLUMNS"
        case "$_pw" in ''|*[!0-9]*) _pw="" ;; esac
    fi

    # 4) Nada medido: palpite pela densidade (80, de monitor, quebraria cada
    #    linha no celular).
    if [ -z "$_pw" ]; then
        PAINEL_LARG_FONTE=dpi
        _pw=$(painel_cols_dpi 80)
    fi

    # 36 e a largura minima em que todo o painel cabe (verificado de 36 a 120).
    [ "$_pw" -lt 36 ] && _pw=36
    [ "$_pw" -gt 120 ] && _pw=120
    PAINEL_LARG="$_pw"
    return 0
}

# ./status.sh -cols — regua de calibracao: se a regua couber sem quebrar, o
# painel cabe; se quebrar, o numero certo e a coluna onde quebrou.
painel_calibrar() {
    painel_largura_calc
    _cl_w="$PAINEL_LARG"
    _cl_f="$PAINEL_LARG_FONTE"
    _cl_d=$(painel_dpi) || _cl_d="-"

    printf 'Densidade da tela (dpi): %s\n' "$_cl_d"
    printf 'Largura do painel:       %s colunas (fonte: %s)\n' "$_cl_w" "$_cl_f"
    printf 'Modo de icones:          %s (%s, fonte: %s)\n' \
        "$SLS_EMOJI" "`painel_icones_nome "$SLS_EMOJI"`" "$SLS_EMOJI_FONTE"
    printf 'Para ver os tres:        ./status.sh -icones\n'
    printf '\nA regua abaixo tem exatamente %s colunas.\n' "$_cl_w"
    printf 'Se ela couber numa linha so, o painel cabe.\n\n'

    # Regua numerada: "....5...10...15..." ate a largura.
    _cl_i=1
    _cl_r=""
    while [ "$_cl_i" -le "$_cl_w" ]; do
        if [ $((_cl_i % 10)) -eq 0 ]; then
            _cl_r="${_cl_r}|"
        elif [ $((_cl_i % 5)) -eq 0 ]; then
            _cl_r="${_cl_r}+"
        else
            _cl_r="${_cl_r}."
        fi
        _cl_i=$((_cl_i + 1))
    done
    printf '%s\n' "$_cl_r"
    printf '%s\n\n' "$(printf '%*s' "$_cl_w" '' | tr ' ' '#')"

    printf 'Para fixar a largura (vale para sempre):\n'
    printf '    echo %s > ~/.sls/cols\n' "$_cl_w"
    printf 'Para testar sem fixar:\n'
    printf '    SLS_COLS=%s ./status.sh\n' "$_cl_w"
    printf 'Para voltar a deteccao automatica:\n'
    printf '    rm ~/.sls/cols\n'
    unset _cl_w _cl_f _cl_d _cl_i _cl_r
}

painel_icones_nome() {
    case "$1" in
        1) printf 'emoji' ;;
        2) printf 'simbolos' ;;
        0) printf 'texto' ;;
        *) printf '?' ;;
    esac
}

# ./status.sh -icones — desenha os tres conjuntos com numeros de verdade para
# escolher OLHANDO: o certo e o que sair inteiro, sem caixa vazia.
painel_icones() {
    _ic_atual="$SLS_EMOJI"

    printf 'Modo de icones agora: %s (%s)\n' \
        "$_ic_atual" "`painel_icones_nome "$_ic_atual"`"
    case "$SLS_EMOJI_FONTE" in
        arquivo)    printf 'Escolhido por voce, em ~/.sls/emoji.\n' ;;
        ambiente)   printf 'Escolhido pela variavel SLS_EMOJI, so nesta janela.\n' ;;
        automatico)
            if painel_e_android; then
                printf 'Escolhido sozinho: e Android/Termux, onde a fonte\n'
                printf 'costuma nao ter emoji.\n'
            else
                printf 'Escolhido sozinho: nao e Android, entao emoji.\n'
            fi
            ;;
    esac

    printf '\nOs tres, desenhados agora nesta tela:\n\n'
    for _ic_m in 1 2 0; do
        painel_icones_carregar "$_ic_m"
        # No modo 1 os estados sao emoji: sem a fonte, viram caixas.
        printf '  %s  %-9s %s %s %s %s %s %s  %s\n' \
            "$_ic_m" "`painel_icones_nome "$_ic_m"`" \
            "$S_ON" "$S_WAIT" "$S_ERR" "$S_OFF" "$S_UNK" "$S_PAUSE" "$A_ARENA"
    done

    # Devolve o conjunto que estava valendo: esta funcao mostra, nao muda.
    painel_icones_carregar "$_ic_atual"

    printf '\nEscolha a linha que aparecer INTEIRA, sem caixa nem quadrado:\n\n'
    printf '    echo 1 > ~/.sls/emoji     emoji\n'
    printf '    echo 2 > ~/.sls/emoji     simbolos simples\n'
    printf '    echo 0 > ~/.sls/emoji     texto puro\n'
    printf '\nPara voltar a escolha automatica:\n'
    printf '    rm ~/.sls/emoji\n'
    unset _ic_atual _ic_m
}

# Linha separadora na largura da tela: cheia, ou tracejada com $2.
# Conta CARACTERES, nao bytes: o "─" tem 3 bytes e 1 coluna.
painel_regua() {
    _rn=$1
    _rc="$T_H"; [ -n "$2" ] && _rc="$T_D"
    _rs=""
    while [ "$_rn" -gt 0 ]; do _rs="$_rs$_rc"; _rn=$((_rn - 1)); done
    printf '%b%s%b\n' "$C_LINHA" "$_rs" "$C_RESET"
    unset _rn _rc _rs
}

# Separador dos campos que o painel_loop manda ao painel_render.
_US=$(printf '\037')

# Classes de bytes do UTF-8 para o painel_render contar colunas (uma vez so).
_PR_CONT=$(printf '[\200-\277]');  _PR_LEAD2=$(printf '[\300-\337]')
_PR_LEAD3=$(printf '[\340-\357]'); _PR_LEAD4=$(printf '[\360-\367]')

# DESENHO DA TABELA E DO RODAPE — UM AWK SO.
#
# O printf do shell alinha por BYTES ("Clã", "·", emoji); aqui a largura e
# contada em colunas e as colunas de numeros tem a largura do maior valor.
#
# Entrada, um registro por linha, campos separados por $_US:
#   R estado simbolo nome aba hp hp_max energia nivel ouro prata aviso cor
#   C online subindo paradas        contadores
#   L solida|tracejada              linha separadora
#   T cor texto                     texto cortado na largura da tela
# As linhas R sao desenhadas juntas, como tabela, no fim da entrada.
# Formatos, do mais largo ao mais estreito (vale o primeiro em que o nome
# ainda cabe com 10 colunas):
#   barras   "● Nome │ 92% │ 1790/1810 │ 87 │ 4.793 │ 699,7M"
#   espacos  "● Nome   92% 1790/1810 87 4.793 699,7M"
#   empilha  "● Nome › aba" e os numeros na linha de baixo
painel_render() {
    LC_ALL=C awk -v fs="$_US" -v larg="$LARG" -v scol="$S_COL" -v esc="$ESC" \
        -v son="$S_ON" -v sup="$S_WAIT" -v soff="$S_ERR" -v seta="$I_ARROW" \
        -v tv="$T_V" -v th="$T_H" -v tx="$T_X" -v tb="$T_B" -v td="$T_D" -v ret="$T_RET" \
        -v cont="$_PR_CONT" -v lead2="$_PR_LEAD2" \
        -v lead3="$_PR_LEAD3" -v lead4="$_PR_LEAD4" '
    BEGIN {
        FS = fs; nr = 0
        fim = esc "[0m"
        cor["verde"] = esc "[38;5;84m";  cor["amarelo"] = esc "[38;5;221m"
        cor["vermelho"] = esc "[38;5;210m"; cor["ciano"] = esc "[38;5;117m"
        cor["lilas"] = esc "[38;5;183m"; cor["prata"] = esc "[38;5;252m"
        cor["cinza"] = esc "[38;5;245m"; cor["linha"] = esc "[38;5;240m"
        cor["nome"] = esc "[97m";        cor["rotulo"] = esc "[38;5;250m"
        est["on"] = "verde"; est["pause"] = "ciano"; est["wait"] = "amarelo"
        est["err"] = "vermelho"; est["off"] = "cinza"; est["unk"] = "cinza"
        rot[1] = "HP"; rot[2] = "ENERGIA"; rot[3] = "NV"; rot[4] = "OURO"; rot[5] = "PRATA"
    }
    function cols(s,   t, n, e) {
        t = s; n = gsub(cont, "", t)
        t = s; e = gsub(lead4, "", t)
        return length(s) - n + e
    }
    function corta(s, w,   i, l, c, bl, cw, n, out) {
        if (w <= 0) return ""
        if (cols(s) <= w) return s
        out = ""; n = 0; i = 1; l = length(s)
        while (i <= l) {
            c = substr(s, i, 1)
            if (c ~ lead4)      { bl = 4; cw = 2 }
            else if (c ~ lead3) { bl = 3; cw = 1 }
            else if (c ~ lead2) { bl = 2; cw = 1 }
            else                { bl = 1; cw = 1 }
            if (n + cw > w - 1) break
            out = out substr(s, i, bl); n += cw; i += bl
        }
        return out ret
    }
    function rep(ch, n,   s) { s = ""; while (n-- > 0) s = s ch; return s }
    function esq(s, w) { s = corta(s, w); return s rep(" ", w - cols(s)) }
    function dir(s, w) { s = corta(s, w); return rep(" ", w - cols(s)) s }
    function cen(s, w,   l) { s = corta(s, w); l = int((w - cols(s)) / 2); return rep(" ", l) s rep(" ", w - cols(s) - l) }
    function pinta(c, s) { return cor[c] s fim }
    function barra() { return " " pinta("linha", tv) " " }

    $1 == "R" {
        nr++
        st[nr] = $2; sy[nr] = $3; nm[nr] = $4; ab[nr] = $5
        v[nr, 2] = $8; v[nr, 3] = $9; v[nr, 4] = $10; v[nr, 5] = $11
        av[nr] = $12; ak[nr] = $13
        # HP em percentual quando o maximo e conhecido; sem ele, o numero.
        if ($6 ~ /^[0-9]+$/ && $7 ~ /^[0-9]+$/ && $7 > 0) {
            p = int($6 * 100 / $7 + 0.5); if (p > 100) p = 100
            v[nr, 1] = p "%"
            vc[nr] = (p >= 70) ? "verde" : (p >= 30) ? "amarelo" : "vermelho"
        } else {
            v[nr, 1] = ($6 == "") ? "-" : $6; vc[nr] = "prata"
        }
        next
    }
    $1 == "L" { print pinta("linha", rep(($2 == "tracejada") ? td : th, larg)); next }
    $1 == "T" { print pinta($2, corta($3, larg)); next }
    $1 == "C" {
        a = son " " $2 " online"; b = sup " " $3 " subindo"; c = soff " " $4 " paradas"
        if (cols(a b c) + 6 > larg) { a = son " " $2; b = sup " " $3; c = soff " " $4 }
        print pinta("verde", a) barra() pinta(($3 > 0) ? "amarelo" : "cinza", b) \
              barra() pinta(($4 > 0) ? "vermelho" : "cinza", c)
        next
    }
    END { if (nr > 0) tabela() }

    function tabela(   i, k, D, nmax, nmin, ind, nw, fmt, x, xe, xd, ln, sep, bind, n2, r, sw, fd) {
        W[1] = 2; W[2] = 7; W[3] = 2; W[4] = 4; W[5] = 5
        nmax = 5
        for (i = 1; i <= nr; i++) {
            for (k = 1; k <= 5; k++) if (cols(v[i, k]) > W[k]) W[k] = cols(v[i, k])
            if (cols(nm[i]) > nmax) nmax = cols(nm[i])
        }
        D = W[1] + W[2] + W[3] + W[4] + W[5]
        nmin = (nmax < 10) ? nmax : 10
        ind = scol + 1
        x = 0
        # A barra da direita do cabecalho sai primeiro: com ela as barras
        # pedem 2 colunas a mais, e no celular isso decide se cabem.
        fd = 2
        nw = larg - ind - D - 15 - fd
        if (nw < nmin && nw + 2 >= nmin) { fd = 0; nw += 2 }
        if (nw >= nmin) {
            fmt = "barras"
            # A sobra alarga as colunas de numeros (ate 10 cada) e o resto
            # fica com o nome: a tabela ocupa a tela toda.
            if (nw > nmax) { x = int((nw - nmax) / 6); if (x > 10) x = 10 }
            nw -= 5 * x
        } else {
            nw = larg - ind - D - 5
            fmt = (nw >= nmin) ? "espacos" : "empilha"
        }
        xe = int(x / 2); xd = x - xe

        if (fmt == "barras") {
            ln = pinta("linha", tv) rep(" ", ind - 1) pinta("rotulo", esq("CONTA", nw))
            for (k = 1; k <= 5; k++) ln = ln barra() pinta("rotulo", cen(rot[k], W[k] + x))
            print ln ((fd) ? " " pinta("linha", tv) : "")
            ln = tb rep(th, ind - 1 + nw)
            for (k = 1; k <= 5; k++) ln = ln th tx rep(th, 1 + W[k] + x)
            print pinta("linha", ln ((fd) ? th tb : ""))
        } else if (fmt == "espacos") {
            ln = rep(" ", ind) pinta("rotulo", esq("CONTA", nw))
            for (k = 1; k <= 5; k++) ln = ln " " pinta("rotulo", dir(rot[k], W[k]))
            print ln
            print pinta("linha", rep(th, ind + nw + 5 + D))
        } else {
            # Empilhado: so os numeros tem cabecalho; o nome vai na linha
            # de cima. Barras se couberem, senao espacos.
            sep = (ind + D + 12 <= larg) ? barra() : " "
            sw = (sep == " ") ? 1 : 3
            bind = larg - D - 4 * sw; if (bind > ind) bind = ind; if (bind < 0) bind = 0
            ln = rep(" ", bind); r = rep(" ", bind)
            for (k = 1; k <= 5; k++) {
                if (k > 1) { ln = ln sep; r = r ((sw == 3) ? th tx th : th) }
                ln = ln pinta("rotulo", dir(rot[k], W[k])); r = r rep(th, W[k])
            }
            print ln
            print pinta("linha", r)
        }

        for (i = 1; i <= nr; i++) {
            ln = pinta(est[st[i]], sy[i] rep(" ", scol - cols(sy[i]))) " "
            if (fmt == "empilha") {
                n2 = larg - ind - cols(seta) - 2 - 6
                if (n2 < 4) n2 = larg - ind
                ln = ln pinta("nome", corta(nm[i], n2))
                n2 = larg - ind - cols(corta(nm[i], n2)) - cols(seta) - 2
                if (n2 >= 4) ln = ln " " pinta("linha", seta) " " pinta("cinza", corta(ab[i], n2))
                print ln
                ln = rep(" ", bind)
                for (k = 1; k <= 5; k++) {
                    if (k > 1) ln = ln sep
                    ln = ln pinta((k == 1) ? vc[i] : ck(k), dir(v[i, k], W[k]))
                }
                print ln
                if (av[i] != "") print rep(" ", ind) pinta(ak[i], corta(av[i], larg - ind))
                continue
            }
            ln = ln pinta("nome", esq(nm[i], nw))
            for (k = 1; k <= 5; k++) {
                if (fmt == "barras") ln = ln barra() rep(" ", xe)
                else                 ln = ln " "
                ln = ln pinta((k == 1) ? vc[i] : ck(k), dir(v[i, k], W[k]))
                if (fmt == "barras") ln = ln rep(" ", xd)
            }
            print ln
            # Atividade embaixo do nome; o aviso da conta vai no fim dela.
            n2 = larg - ind - 2 - cols(seta) - 1
            ln = rep(" ", ind + 2) pinta("linha", seta) " "
            if (av[i] != "" && n2 - cols(av[i]) - 2 >= 6) {
                print ln pinta("cinza", corta(ab[i], n2 - cols(av[i]) - 2)) "  " pinta(ak[i], av[i])
            } else {
                print ln pinta("cinza", corta(ab[i], n2))
                if (av[i] != "") print rep(" ", ind + 2) pinta(ak[i], corta(av[i], larg - ind - 2))
            }
        }
    }
    function ck(k) { return (k == 2) ? "ciano" : (k == 3) ? "lilas" : (k == 4) ? "amarelo" : "prata" }
    '
}

# Agenda de eventos, extraida do case de horarios do run.sh.
# Horarios em America/Bahia (BRT), que e o fuso usado pelos workers.
EVENTOS="0030|Coliseu
0925|Evento especial
0955|Imortais
1010|Batalha de Bandeiras
1025|Coliseu do Cla
1055|Batalha de Clas
1125|Torneio de Equipe
1225|Rei dos Imortais
1355|Altares
1455|Coliseu do Cla
1555|Imortais
1610|Batalha de Bandeiras
1625|Rei dos Imortais
1755|Torneio de Equipe
1855|Batalha de Clas
2055|Altares
2125|Evento especial
2155|Imortais
2225|Rei dos Imortais"

# A conta esta AGORA num evento? $1 e o caminho de $TMP/pagina; devolve o
# nome do evento em _EVP, ou vazio.
evento_da_pagina_v() {
    case "$1" in
        /altars*)       _EVP="$A_ALTARES" ;;
        /undying*)      _EVP="$A_VALE" ;;
        /king*)         _EVP="$A_REI" ;;
        /clanfight*)    _EVP="$A_CLANFIGHT" ;;
        /clancoliseum*) _EVP="$A_CLANCOL" ;;
        /clancommand*)  _EVP="$A_TORNEQ" ;;
        *)              _EVP='' ;;
    esac
}

# O codigo em disco e mais novo que ESTE processo de painel?
# O painel le o panel.sh so ao subir; depois de um git pull um painel aberto
# (no tmux, que sobrevive ao ./stop.sh) seguiria com o codigo velho sem aviso.
# A data de /proc/$$ e a hora em que o processo comecou; "-nt" e do shell.
painel_desatualizado() {
    # Raiz (comandos) e lib/ (motor): um pull pode tocar so no motor.
    for _pd_f in "$SLSDIR"/*.sh "$LIBDIR"/*.sh; do
        [ -f "$_pd_f" ] || continue
        if [ "$_pd_f" -nt "/proc/$$" ]; then unset _pd_f; return 0; fi
    done
    unset _pd_f
    return 1
}

# "HHMM" -> minutos desde a meia-noite, em $_HM. Sem criar processo.
# Zero a esquerda tirado na mao: "$((10#x))" e bashism e "08" viraria octal.
_hhmm_min() {
    _hm_t="$1"
    case "$_hm_t" in ????) ;; *) _HM=-1; return 1 ;; esac
    _hm_h=${_hm_t%??}
    _hm_m=${_hm_t#??}
    case "$_hm_h$_hm_m" in *[!0-9]*) _HM=-1; return 1 ;; esac
    while :; do case "$_hm_h" in 0?*) _hm_h=${_hm_h#0} ;; *) break ;; esac; done
    while :; do case "$_hm_m" in 0?*) _hm_m=${_hm_m#0} ;; *) break ;; esac; done
    [ -z "$_hm_h" ] && _hm_h=0
    [ -z "$_hm_m" ] && _hm_m=0
    _HM=$(( _hm_h * 60 + _hm_m ))
    unset _hm_t _hm_h _hm_m
    return 0
}

# Percorre UMA lista de eventos ($1 lista, $2 agora em minutos, $3 duracao
# da janela do evento) e devolve, em variaveis:
#   _SC_NOW  nome do evento acontecendo agora (vazio se nenhum)
#   _SC_NOW_T  minuto em que ele comecou
#   _SC_T    minuto do proximo evento
#   _SC_N    nome do proximo
#   _SC_HM   horario "HHMM" do proximo
# Procura o MENOR horario futuro: a agenda de /fights/ nao vem em ordem.
_scan_eventos() {
    _SC_NOW=""; _SC_NOW_T=0; _SC_T=""; _SC_N=""; _SC_HM=""
    _sc_1t=""; _sc_1n=""; _sc_1hm=""
    _sc_oifs=$IFS
    # IFS so de nova linha: "Coliseu do Cla" nao pode virar tres iteracoes.
    IFS='
'
    for _sc_e in $1; do
        [ -n "$_sc_e" ] || continue
        _sc_hm=${_sc_e%%|*}; _sc_n=${_sc_e#*|}
        [ -n "$_sc_n" ] || continue
        _hhmm_min "$_sc_hm" || continue
        _sc_v=$_HM
        [ -n "$_sc_1t" ] || { _sc_1t=$_sc_v; _sc_1n=$_sc_n; _sc_1hm=$_sc_hm; }
        # Acontecendo agora: comecou ha menos que a duracao da janela.
        if [ "$_sc_v" -le "$2" ] && [ $(( $2 - _sc_v )) -lt "$3" ]; then
            if [ -z "$_SC_NOW" ] || [ "$_sc_v" -gt "$_SC_NOW_T" ]; then
                _SC_NOW=$_sc_n; _SC_NOW_T=$_sc_v
            fi
        fi
        if [ "$_sc_v" -gt "$2" ]; then
            if [ -z "$_SC_T" ] || [ "$_sc_v" -lt "$_SC_T" ]; then
                _SC_T=$_sc_v; _SC_N=$_sc_n; _SC_HM=$_sc_hm
            fi
        fi
    done
    IFS=$_sc_oifs
    # Nao sobrou nada hoje: o proximo e o primeiro de amanha.
    if [ -z "$_SC_T" ] && [ -n "$_sc_1t" ]; then
        _SC_T=$(( _sc_1t + 1440 )); _SC_N=$_sc_1n; _SC_HM=$_sc_1hm
    fi
    unset _sc_e _sc_hm _sc_n _sc_v _sc_1t _sc_1n _sc_1hm _sc_oifs
}

# A linha de evento do rodape: "Proximo: Nome  HH:MM BRT  (em Xh Ym)" ou,
# enquanto um evento corre, "AGORA: Nome".
#
# Duas fontes, e a mais proxima vence: a agenda do jogo (~/.sls/agenda, lida
# de /fights/) pode vir sem um evento, e a lista fixa (o case do run.sh) e o
# que o bot realmente vai fazer. Quando as duas apontam o mesmo evento,
# prevalece a agenda: nome e horario que o jogador ve no jogo.
proximo_evento() {
    _pe_agenda=""
    _pe_ag="$HOME/.sls/agenda"
    # No painel_loop a agenda e a hora de Brasilia ja vem do painel_relogio
    # (sem stat, cat e date aqui); fora dele, le direto.
    if [ -n "$_PE_OK" ]; then
        if [ -n "$_PE_AG_MT" ]; then
            _pe_idade=$(( _agora_ep - _PE_AG_MT ))
            [ "$_pe_idade" -lt 7200 ] && _pe_agenda="$_PE_AG_TXT"
        fi
        _pe_ai=$(( (_agora_ep + _PE_BAHIA) % 86400 / 60 ))
    else
        if [ -s "$_pe_ag" ]; then
            _pe_idade=$(( $(date +%s) - $(stat -c %Y "$_pe_ag" 2>/dev/null || echo 0) ))
            [ "$_pe_idade" -lt 7200 ] && _pe_agenda=`cat "$_pe_ag"`
        fi
        _hhmm_min "`TZ=America/Bahia date +%H%M`"
        _pe_ai=$_HM
    fi
    [ "$_pe_ai" -lt 0 ] && _pe_ai=0

    # Duas janelas: a lista fixa marca a INSCRICAO (5 min antes), a agenda a
    # hora OFICIAL. A mesma janela faria o "ate" mudar quando a agenda assumisse.
    _pe_dur=${FUNC_evento_min:-10}
    case "$_pe_dur" in ''|*[!0-9]*) _pe_dur=10 ;; esac
    _pe_jan=$(( _pe_dur + 5 ))

    _scan_eventos "$EVENTOS" "$_pe_ai" "$_pe_jan"
    _pe_fnow=$_SC_NOW; _pe_fnow_t=$_SC_NOW_T
    _pe_ft=$_SC_T; _pe_fn=$_SC_N; _pe_fhm=$_SC_HM

    _pe_anow=""; _pe_anow_t=0; _pe_at=""; _pe_an=""; _pe_ahm=""
    if [ -n "$_pe_agenda" ]; then
        _scan_eventos "$_pe_agenda" "$_pe_ai" "$_pe_dur"
        _pe_anow=$_SC_NOW; _pe_anow_t=$_SC_NOW_T
        _pe_at=$_SC_T; _pe_an=$_SC_N; _pe_ahm=$_SC_HM
    fi

    # Conta vista numa pagina de evento tem prioridade sobre o relogio: a
    # duracao (FUNC_evento_min) e so palpite, e o painel nao le o config.cfg.
    if [ -n "$PANEL_EVENTO_ATIVO" ]; then
        printf "AGORA: %s" "$PANEL_EVENTO_ATIVO"
        unset _pe_agenda _pe_ag _pe_idade _pe_ai _pe_jan _pe_dur \
              _pe_fnow _pe_fnow_t _pe_ft _pe_fn _pe_fhm _pe_anow _pe_anow_t _pe_at _pe_an _pe_ahm
        return 0
    fi

    # ACONTECENDO AGORA — o painel so avanca depois que o evento termina.
    if [ -n "$_pe_anow" ] || [ -n "$_pe_fnow" ]; then
        # Ate quando: o inicio da janela mais a duracao.
        if [ -n "$_pe_anow" ]; then _pe_fim=$(( _pe_anow_t + _pe_dur ))
        else                         _pe_fim=$(( _pe_fnow_t + _pe_jan ))
        fi
        _pe_fim=$(( _pe_fim % 1440 ))
        printf "AGORA: %s · até %02d:%02d" "${_pe_anow:-$_pe_fnow}" \
               $(( _pe_fim / 60 )) $(( _pe_fim % 60 ))
        unset _pe_fim
        unset _pe_agenda _pe_ag _pe_idade _pe_ai _pe_jan _pe_dur \
              _pe_fnow _pe_fnow_t _pe_ft _pe_fn _pe_fhm _pe_anow _pe_anow_t _pe_at _pe_an _pe_ahm
        return 0
    fi

    # A mais proxima das duas listas.
    _pe_t=$_pe_ft; _pe_n=$_pe_fn; _pe_hm=$_pe_fhm
    if [ -n "$_pe_at" ]; then
        if [ -z "$_pe_t" ] || [ "$_pe_at" -lt "$_pe_t" ]; then
            _pe_t=$_pe_at; _pe_n=$_pe_an; _pe_hm=$_pe_ahm
        elif [ $(( _pe_at - _pe_t )) -le 10 ]; then
            # Mesmo evento visto pelas duas: fica o nome e a hora do jogo.
            _pe_t=$_pe_at; _pe_n=$_pe_an; _pe_hm=$_pe_ahm
        fi
    fi

    if [ -z "$_pe_t" ]; then
        printf "Próximo: --"
    else
        _pe_falta=$(( _pe_t - _pe_ai ))
        [ "$_pe_falta" -lt 0 ] && _pe_falta=0
        _pe_h=${_pe_hm%??}; _pe_m=${_pe_hm#??}
        if [ "$_pe_falta" -ge 60 ]; then
            printf "Próximo: %s · %s:%s BRT · em %dh%02dm" \
                   "$_pe_n" "$_pe_h" "$_pe_m" $((_pe_falta/60)) $((_pe_falta%60))
        else
            printf "Próximo: %s · %s:%s BRT · em %dm" \
                   "$_pe_n" "$_pe_h" "$_pe_m" "$_pe_falta"
        fi
        unset _pe_falta _pe_h _pe_m
    fi
    unset _pe_agenda _pe_ag _pe_idade _pe_ai _pe_jan _pe_dur \
          _pe_fnow _pe_fnow_t _pe_ft _pe_fn _pe_fhm _pe_anow _pe_anow_t _pe_at _pe_an _pe_ahm \
          _pe_t _pe_n _pe_hm
}

# Limpa os \r do fim de um campo do accounts.conf para $_CF, SEM criar
# processo (o clean_field usa subshell e dois tr, por conta, a cada desenho).
_CR=$(printf '\r')
limpa_campo() {
    _CF="$1"
    while :; do
        case "$_CF" in
            *"$_CR") _CF="${_CF%"$_CR"}" ;;
            *)       break ;;
        esac
    done
}

# Le a primeira linha de um arquivo para $_LIDO, SEM criar processo: um `cat`
# por arquivo, por conta, a cada desenho passava do limite de ~32 processos do
# Android. O "|| :" e porque o arquivo e gravado sem quebra de linha final, e
# o read devolve 1 mesmo preenchendo a variavel.
ler_arq() {
    _LIDO=""
    [ -r "$1" ] || return 0
    read -r _LIDO < "$1" 2>/dev/null || :
    return 0
}

# Espera antes de relancar um worker morto.   relanca_espera N DESDE
#   N = relancamentos seguidos (.relancado_n), DESDE = segundos desde o ultimo.
# Em _RL_N a contagem (zera apos 15 min sem relancar) e em _RL_E a espera:
# 1 min nos dois primeiros, depois 2, 5 e 10 min — um worker que cai ao
# subir nao fica gastando login e processos todo minuto. Sem processo: o
# painel chama isto a cada desenho para cada conta parada.
relanca_espera() {
    _RL_N=$1
    case "$_RL_N" in ''|*[!0-9]*) _RL_N=0 ;; esac
    case "$2" in ''|*[!0-9-]*) ;; *) [ "$2" -ge 900 ] && _RL_N=0 ;; esac
    case "$_RL_N" in 0|1) _RL_E=60 ;; 2) _RL_E=120 ;; 3) _RL_E=300 ;; *) _RL_E=600 ;; esac
}

# Nome da aba em que a conta esta agora, em _ABA, traduzido de $1/pagina
# (gravado pelo fetch_page); "/" vira "Pagina Principal". Sem $(...): o
# painel chama isto para cada conta a cada redesenho.
aba_de_v() {
    ler_arq "$1/pagina"; _abp="$_LIDO"
    case "$_abp" in
        ""|"/"|"/?out_gate_confirm=true") _ABA="Página Principal" ;;
        "/?sign_in=1")    _ABA="Entrando" ;;
        /fights*)         _ABA="Agenda de Batalhas" ;;
        /arena*)          _ABA="Arena" ;;
        /career*)         _ABA="Carreira" ;;
        /cave*)           _ABA="Caverna" ;;
        /campaign*)       _ABA="Campanha" ;;
        /coliseum*)       _ABA="Coliseu" ;;
        /clancoliseum*)   _ABA="Coliseu do Clã" ;;
        /clancommand*)   _ABA="Torneio de Equipe" ;;
        /clanfight*)      _ABA="Torneio dos Clãs" ;;
        /clandungeon*)    _ABA="Masmorra do Clã" ;;
        # /clandmgfight e o duelo do cla (09:25 e 21:25), nao a masmorra.
        /clandmgfight*)   _ABA="Duelo do Clã" ;;
        /clan/*quest*)    _ABA="Missões do Clã" ;;
        /clan/*built*)    _ABA="Estátua do Clã" ;;
        /clan*)           _ABA="Clã" ;;
        /altars*)         _ABA="Altares dos Deuses" ;;
        /undying*)        _ABA="Vale dos Imortais" ;;
        /king*)           _ABA="Rei dos Imortais" ;;
        /flagfight*)      _ABA="Batalha de Bandeiras" ;;
        /league*)         _ABA="Liga dos Favoritos" ;;
        /trade*)          _ABA="Troca" ;;
        /effshop*|/lab*)  _ABA="Aprimoramento" ;;
        # /questrnd antes de /quest*, que tambem o casaria.
        /questrnd*)       _ABA="Missão Aleatória" ;;
        /quest*)          _ABA="Missões" ;;
        /collector*)      _ABA="Coleções" ;;
        /relic*)          _ABA="Relíquias" ;;
        /sage*)           _ABA="Cabana do Sábio" ;;
        /inv*)            _ABA="Inventário" ;;
        /train*)          _ABA="Treino" ;;
        /fault*)          _ABA="Falha" ;;
        /collfight*)      _ABA="Batalha Coletiva" ;;
        /marathon*)       _ABA="Maratona" ;;
        /user*)           _ABA="Meu Herói" ;;
        /settings*)       _ABA="Configurações" ;;
        /mail*)           _ABA="Mensagens" ;;
        /logout*)         _ABA="Saindo" ;;
        *)                _ABA="$_abp" ;;
    esac
    unset _abp
}

# Relatorio de combate em _CBT: compara HP (ou USH) com old_HP, que os
# modulos de combate mantem no diretorio da conta durante a luta.
#   "VOCE ESTA MORTO"            HP zerado
#   "-142 de dano recebido"      perdeu vida desde a ultima leitura
#   "+380 recuperado"            curou
#   ""                           fora de combate
combate_de_v() {
    _cbd="$1"
    # Coliseu do Cla e Bandeiras gravam o HP em USH, nao em HP (o old_HP e o
    # mesmo): vale o mais recente dos dois.
    if [ -f "$_cbd/USH" ] && { [ ! -f "$_cbd/HP" ] || [ "$_cbd/USH" -nt "$_cbd/HP" ]; }; then
        ler_arq "$_cbd/USH"
    else
        ler_arq "$_cbd/HP"
    fi
    _cbh="$_LIDO"
    ler_arq "$_cbd/old_HP"; _cbo="$_LIDO"
    case "$_cbh"  in ''|*[!0-9]*) _cbh=""  ;; esac
    case "$_cbo" in ''|*[!0-9]*) _cbo="" ;; esac
    [ -n "$_cbh" ] || { _CBT=""; unset _cbd _cbh _cbo; return; }

    if [ "$_cbh" -eq 0 ] 2>/dev/null; then
        _CBT="VOCÊ ESTÁ MORTO"
        unset _cbd _cbh _cbo
        return
    fi

    if [ -n "$_cbo" ] && [ "$_cbo" -gt 0 ] 2>/dev/null; then
        _cbf=$((_cbh - _cbo))
        # No celular, forma curta: o registro da luta logo abaixo da o detalhe.
        if [ "${ESTREITO:-0}" = 1 ]; then
            case "$_cbf" in
                -*) _CBT="HP $_cbh ($_cbf)" ;;
                0)  _CBT="HP $_cbh" ;;
                *)  _CBT="HP $_cbh (+$_cbf)" ;;
            esac
        elif [ "$_cbf" -lt 0 ]; then
            _CBT="HP $_cbh  ($_cbf de dano recebido)"
        elif [ "$_cbf" -gt 0 ]; then
            _CBT="HP $_cbh  (+$_cbf recuperado)"
        else
            _CBT="HP $_cbh"
        fi
    else
        _CBT="HP $_cbh"
    fi
    unset _cbd _cbh _cbo _cbf
}

# ============================================================
#  REGISTRO DA BATALHA AO VIVO
#  Quem bate na conta, critico, habilidade, erva ou pedra. Le o HTML que o
#  modulo de batalha ja gravou no diretorio da conta: nenhuma requisicao nova.
# ============================================================

# Arquivo da pagina de luta mais recente desta conta: cada modulo usa um nome
# (SRC, src.html, ccol_src...), e o mais novo e o da luta em andamento.
pagina_batalha() {
    _pb_f=""
    for _pb_c in "$1/SRC" "$1/src.html" "$1/ccol_src" "$1/col_src" \
                 "$1/flag_src" "$1/ARENA"; do
        [ -s "$_pb_c" ] || continue
        if [ -z "$_pb_f" ] || [ "$_pb_c" -nt "$_pb_f" ]; then _pb_f="$_pb_c"; fi
    done
    printf '%s' "$_pb_f"
    unset _pb_c _pb_f
}

# As ultimas linhas do combate que dizem respeito A ESTA CONTA:
#   quem acertou a conta   "Bahamut acertar Voce por 2864 critico"
#   o que a conta usou     "Voce usou Posicao defensiva"
#   a habilidade de quem   "Bahamut usou Contra ataque"
#   esta batendo nela
# Golpe entre terceiros fica de fora (numa batalha de cla nao caberia na
# tela); por isso o "usou" so passa de quem ja apareceu acertando a conta.
# O log do jogo vem do mais novo para o mais antigo.
# $1 pasta da conta, $2 linhas (padrao 2), $3 largura (padrao 60, minimo 24).
combate_log() {
    _cl_f=`pagina_batalha "$1"`
    [ -n "$_cl_f" ] || return 0
    _cl_n="${2:-2}"
    _cl_w="${3:-60}"
    [ "$_cl_w" -lt 24 ] && _cl_w=24

    # ESC de verdade: quem imprime aqui e o awk, que nao expande "\033".
    awk -v lim="$_cl_n" -v larg="$_cl_w" -v pre="      " \
        -v cLevou="${ESC}[1;31m" -v cUsou="${ESC}[1;32m" \
        -v cDeles="${ESC}[0;37m" -v cFim="${ESC}[0m" '
        { todo = todo $0 " " }
        END {
            # Fim de bloco vira quebra de linha: e o que separa uma acao da
            # seguinte no log do jogo.
            gsub(/<\/div>|<\/p>|<\/li>|<\/tr>|<br[^>]*>/, "\n", todo)
            gsub(/<[^>]*>/, " ", todo)
            gsub(/&nbsp;|&#160;/, " ", todo)
            # O painel imprime tudo com printf %b: uma barra invertida vinda
            # da pagina viraria sequencia de escape no meio do texto.
            gsub(/\\/, " ", todo)
            n = split(todo, linha, "\n")

            # Passada 1: quem acertou esta conta.
            for (i = 1; i <= n; i++) {
                t = limpa(linha[i])
                if (t ~ /acert/ && t ~ /[Vv]oc/ && t !~ /^[Vv]oc/) {
                    quem = t
                    sub(/ +acert.*$/, "", quem)
                    if (length(quem) > 0 && length(quem) < 30) bate[quem] = 1
                }
            }

            # Passada 2: as ultimas acoes que interessam, do topo para baixo.
            achou = 0
            for (i = 1; i <= n && achou < lim; i++) {
                t = limpa(linha[i])
                if (length(t) < 6) continue

                cor = ""
                if (t ~ /^[Vv]oc/)          cor = cUsou      # a conta agiu
                else if (t ~ /[Vv]oc/)      cor = cLevou     # a conta levou
                else {
                    autor = t
                    sub(/ +usou.*$/, "", autor)
                    if (t ~ / usou / && autor in bate) cor = cDeles
                }
                if (cor == "") continue

                # Corta na ultima palavra que couber, e nao no meio de um
                # caractere: acentuado ocupa dois bytes, e um corte cego
                # deixaria meio caractere na tela.
                if (length(t) > larg) {
                    corte = substr(t, 1, larg - 1)
                    p = match(corte, / [^ ]*$/)
                    if (p > larg / 2) corte = substr(corte, 1, p - 1)
                    t = corte "…"
                }
                print pre cor t cFim
                achou++
            }
        }
        function limpa(x) {
            gsub(/[ \t\r]+/, " ", x)
            sub(/^ /, "", x); sub(/ $/, "", x)
            return x
        }
    ' "$_cl_f" 2>/dev/null

    unset _cl_f _cl_n _cl_w
}

# Quantas linhas do registro da luta aparecem por conta. 0 desliga.
#     PANEL_LOG_LINHAS=4 ./status.sh
PANEL_LOG_LINHAS="${PANEL_LOG_LINHAS:-2}"
case "$PANEL_LOG_LINHAS" in ''|*[!0-9]*) PANEL_LOG_LINHAS=2 ;; esac

# Relogio e agenda do rodape, preparados no redesenho (sem date/stat/cat no
# proximo_evento): a diferenca Brasilia-epoch e lida uma vez por hora; a
# agenda e relida quando o arquivo fica mais novo que a ultima leitura e, por
# garantia, a cada 30 redesenhos.
painel_relogio() {
    if [ -z "$_PE_BAHIA" ] || [ $(( _agora_ep - ${_PE_BAHIA_EM:-0} )) -ge 3600 ]; then
        set -- `TZ=America/Bahia date '+%s %H %M %S'`
        _PE_BAHIA=$(( ${2#0} * 3600 + ${3#0} * 60 + ${4#0} - $1 % 86400 + 86400 ))
        _PE_BAHIA_EM="$_agora_ep"
    fi
    _pr_ag="$HOME/.sls/agenda"; _pr_mk="$HOME/.sls/.painel_agenda"
    _PE_AG_N=$(( ${_PE_AG_N:-30} + 1 ))
    if [ ! -s "$_pr_ag" ]; then
        _PE_AG_MT=""; _PE_AG_TXT=""
    elif [ -z "$_PE_AG_MT" ] || [ "$_PE_AG_N" -gt 30 ] || [ "$_pr_ag" -nt "$_pr_mk" ]; then
        _PE_AG_MT=$(stat -c %Y "$_pr_ag" 2>/dev/null || echo 0)
        _PE_AG_TXT=$(cat "$_pr_ag")
        : > "$_pr_mk" 2>/dev/null
        _PE_AG_N=0
    fi
    _PE_OK=1
    unset _pr_ag _pr_mk
}

# Conta viva sem um "tr" por conta a cada redesenho: o worker_vivo confere o
# /proc/PID/cmdline uma vez; depois basta o kill -0. A checagem completa volta
# quando o PID muda e a cada 12 redesenhos (PID reaproveitado).
worker_vivo_painel() { # pid pasta (usa $idx, a posicao da conta)
    eval "_wvp=\${_WVP_$idx:-}"
    _wvp_n=99
    case "$_wvp" in "$1|$2|"*) _wvp_n=${_wvp##*|} ;; esac
    if [ "$_wvp_n" -lt 12 ] && kill -0 "$1" 2>/dev/null; then
        eval "_WVP_$idx=\"\$1|\$2|$(( _wvp_n + 1 ))\""
        unset _wvp _wvp_n; return 0
    fi
    unset _wvp _wvp_n
    if worker_vivo "$1" "$2"; then eval "_WVP_$idx=\"\$1|\$2|0\""; return 0; fi
    eval "_WVP_$idx="
    return 1
}

painel_loop() {
while true; do
    # O que o "clear" escreve num xterm (Termux e WSL), sem o processo.
    [ -t 1 ] && [ "${PANEL_ONCE:-0}" != "1" ] && printf '\033[H\033[2J\033[3J'
    # Um "date" por redesenho: hora da tela e epoch na mesma leitura.
    _pd=$(date '+%H:%M:%S %s'); agora=${_pd% *}; _agora_ep=${_pd#* }; unset _pd
    painel_relogio

    # Remede a cada volta: o celular pode ser girado com o painel aberto.
    painel_largura_calc; LARG="$PAINEL_LARG"
    # 86: largura que o layout de coluna unica ocupa (medido).
    if [ "$LARG" -lt 86 ]; then ESTREITO=1; else ESTREITO=0; fi

    n_on=0; n_up=0; n_off=0; n_fight=0; idx=0
    PANEL_EVENTO_ATIVO=''
    LISTA=""; BATALHAS=""

    # Le tambem a ultima linha sem quebra de linha final (ver play.sh).
    while IFS='|' read -r srv user _enc <&3 || [ -n "$srv" ]; do
        limpa_campo "$srv";  srv="$_CF"
        limpa_campo "$user"; user="$_CF"
        case "$srv" in ''|\#*|*[!0-9]*) continue ;; esac
        [ -z "$user" ] && continue
        case "$srv" in 1) tag="BR" ;; *) continue ;; esac

        acc_id="${tag}_${user}"
        acc_dir="$HOME/.sls/${acc_id}"
        status_file="$STATUS_DIR/${acc_id}.status"
        pid_file="$STATUS_DIR/${acc_id}.pid"
        ler_arq "$status_file"; status="${_LIDO:-?}"
        ler_arq "$pid_file";    pid="$_LIDO"

        # PID gravado mas processo sumiu: supervisionando (play.sh) relanca;
        # somente leitura (status.sh) so mostra "off" — abrir o painel NUNCA
        # mexe nos workers. worker_vivo confere que o PID e desta conta (o
        # kernel recicla PIDs). No maximo um relancamento por minuto por conta.
        _sobe=0
        if [ -n "$pid" ] && ! worker_vivo_painel "$pid" "$acc_dir"; then
            status="dead"
            _sobe=1
        elif [ -z "$pid" ] && [ "$status" != "stopped" ]; then
            # Conta nova, cadastrada com o bot no ar (sem .pid). "stopped" fica
            # de fora: ai foi o stop.sh.
            _sobe=1
        fi
        if [ "$_sobe" = 1 ] && [ "${PANEL_SUPERVISE:-0}" = "1" ]; then
            # O diretorio antes do marcador: sem ele a conta nova seria
            # relancada a cada desenho.
            mkdir -p "$acc_dir" 2>/dev/null
            # Espera crescente para quem morre seguido (relanca_espera).
            ler_arq "$acc_dir/.relancado_n"
            _rl_n=$_LIDO
            ler_arq "$acc_dir/.relancado"
            case "$_LIDO" in ''|*[!0-9]*) _LIDO=0 ;; esac
            _LIDO=$(( _agora_ep - _LIDO ))
            relanca_espera "$_rl_n" "$_LIDO"
            if [ "$_LIDO" -lt 0 ] || [ "$_LIDO" -ge "$_RL_E" ]; then
                echo "$_agora_ep" > "$acc_dir/.relancado" 2>/dev/null
                echo $(( _RL_N + 1 )) > "$acc_dir/.relancado_n" 2>/dev/null
                [ "$status" = "dead" ] && echo "dead" > "$status_file"
                printf "[monitor] subindo worker\n" >> "$acc_dir/sls.log" 2>/dev/null
                # A credencial do accounts.conf: conta nova nao tem cript_file.
                limpa_campo "$_enc"
                launch_worker "$srv" "$user" "$_CF" > /dev/null 2>&1
            fi
            unset _rl_n
        fi

        # loading/login_retry sao contas SUBINDO, nao paradas.
        case "$status" in
            running)                                 n_on=$((n_on + 1)) ;;
            starting|loading|login_retry|restarting) n_up=$((n_up + 1)) ;;
            *)                                       n_off=$((n_off + 1)) ;;
        esac
        idx=$((idx + 1))

        nome="$user"; hp="-"; mp="-"; ene="-"; lvl="-"; ouro="-"; prata="-"; _hpmax=""
        _velho=""
        if [ -s "$acc_dir/stats" ]; then
            IFS='|' read -r nome hp mp ene lvl ouro prata _ts _hpmax < "$acc_dir/stats"
            [ -z "$nome" ] && nome="$user"

            # Numeros parados: avisa em vez de mostrar valores velhos como
            # atuais. A atualizacao normal e a cada 3 min; passar de 10 e erro.
            case "$_ts" in
                ''|*[!0-9]*) ;;
                *) _idade=$(( (_agora_ep - _ts) / 60 ))
                   [ "$_idade" -gt 10 ] && _velho="$_idade min" ;;
            esac
        fi

        # Sessao no jogo, separada do estado do worker: com o cookie morto o
        # worker segue vivo e o servidor o ve como visitante. O worker carimba
        # $TMP/last_ok ao confirmar a sessao no descanso (~1 min); passando de
        # 4 min sem confirmacao, aviso "sessao caida".
        _sessao=""
        _cor_s="$C_RED"

        # Dentro de um evento o silencio e esperado: o modulo espera a hora
        # cheia sem pedir pagina. em_evento guarda o instante do inicio
        # (gravado na inscricao); a janela vai de 10 min antes a 15 depois.
        _em_ev=0
        ler_arq "$acc_dir/em_evento"; _eve="$_LIDO"
        case "$_eve" in
            ''|*[!0-9]*) ;;
            *) if [ "$_agora_ep" -gt $((_eve - 600)) ] && \
                  [ "$_agora_ep" -lt $((_eve + 900)) ]; then _em_ev=1; fi ;;
        esac

        ler_arq "$acc_dir/last_ok"; _ok="$_LIDO"
        if [ "$_em_ev" = 0 ]; then
            case "$_ok" in
                ''|*[!0-9]*) [ "$status" = "running" ] && _sessao="sessao ?" ;;
                *) if [ $(( (_agora_ep - _ok) / 60 )) -gt 4 ]; then
                       # Servidor mudo nao e sessao caida: falha de rede
                       # (last_rede) depois da ultima confirmacao. Mesma
                       # largura de "sessao caida" (12 colunas).
                       ler_arq "$acc_dir/last_rede"; _rd="$_LIDO"
                       case "$_rd" in
                           ''|*[!0-9]*) _sessao="sessao caida" ;;
                           *) if [ "$_rd" -ge "$_ok" ]; then
                                  _sessao="sem resposta"; _cor_s="$C_YELLOW"
                                  # O codigo do curl diz a causa (60 =
                                  # certificado ou relogio; 6/7/28 = rede).
                                  ler_arq "$acc_dir/.curl_erro"
                                  case "$_LIDO" in
                                      ''|*[!0-9]*) ;;
                                      *) [ "$acc_dir/.curl_erro" -nt "$acc_dir/last_ok" ] \
                                             && _sessao="sem resposta (curl $_LIDO)" ;;
                                  esac
                              else
                                  _sessao="sessao caida"
                              fi ;;
                       esac
                   fi ;;
            esac
        fi

        # Atribuicao direta: "cor=$(estado_cor ...)" forkaria.
        case "$status" in
            running)     _st=on;    sim="$S_ON" ;;
            paused)      _st=pause; sim="$S_PAUSE" ;;
            starting|loading|login_retry|restarting)
                         _st=wait;  sim="$S_WAIT" ;;
            dead)        _st=err;   sim="$S_ERR" ;;
            stopped)     _st=off;   sim="$S_OFF" ;;
            *)           _st=unk;   sim="$S_UNK" ;;
        esac

        # Aba atual + relatorio de combate (HP ao vivo, dano, morte)
        aba_de_v "$acc_dir"; _aba="$_ABA"
        # Alguma conta viva numa pagina de evento? O rodape usa isso no lugar
        # da janela estimada por FUNC_evento_min.
        if [ "$status" = "running" ] && [ -z "$PANEL_EVENTO_ATIVO" ]; then
            ler_arq "$acc_dir/pagina"
            evento_da_pagina_v "$_LIDO"; PANEL_EVENTO_ATIVO="$_EVP"
        fi
        # HP/old_HP ficam no disco depois que o worker morre: so com a conta no ar.
        if [ "$status" = "running" ] || [ "$status" = "paused" ]; then
            combate_de_v "$acc_dir"; _cbt="$_CBT"
        else
            _cbt=""
        fi
        case "$_cbt" in
            *MORTO*) _cor_c="$C_RED" ;;
            *dano*)  _cor_c="$C_YELLOW" ;;
            *)       _cor_c="$C_GREEN" ;;
        esac

        # Ao vivo das batalhas: so com combate de verdade (o combate_de_v so
        # devolve texto enquanto os modulos atualizam HP/old_HP).
        if [ -n "$_cbt" ]; then
            n_fight=$((n_fight + 1))

            # Larguras derivadas da tela no celular: o que sobra depois do HP
            # e repartido entre nome e atividade. A linha e
            #   2 espacos + I_LIVE + espaco + nome + espaco + aba + espaco + HP
            # e a reserva e medida: 5 colunas, mais LIVE_W, mais o texto de HP
            # (${#} conta bytes e superestima acentos: erra para o lado seguro).
            if [ "$ESTREITO" = 1 ]; then
                _lw=${LIVE_W:-0}
                _pre="$I_LIVE"
                _sobra=$((LARG - 5 - _lw - ${#_cbt}))
                # Tela apertada demais: sai o icone, entram 2 ou 3 colunas de nome.
                if [ "$_sobra" -lt 12 ] && [ "$_lw" -gt 0 ]; then
                    _pre=""; _lw=0
                    _sobra=$((LARG - 5 - ${#_cbt}))
                fi
                # Piso de legibilidade: 6 colunas de nome + 5 de atividade.
                [ "$_sobra" -lt 11 ] && _sobra=11
                _nw=$(( _sobra * 6 / 10 )); [ "$_nw" -gt 16 ] && _nw=16
                _bw=$(( _sobra - _nw ));    [ "$_bw" -gt 18 ] && _bw=18
                [ "$_bw" -lt 5 ] && _bw=5
            else
                _pre="$I_LIVE"
                _nw=14; _bw=16
            fi
            BATALHAS="${BATALHAS}$(printf "  %b%s %b%-*.*s %b%-*.*s %b%s%b" \
                "$_cor_c" "$_pre" "$C_LARANJA" "$_nw" "$_nw" "$nome" \
                "$C_CYAN" "$_bw" "$_bw" "$_aba" "$_cor_c" "$_cbt" "$C_RESET")
"
            # Registro da luta, logo abaixo do nome, a partir da margem esquerda.
            if [ "$PANEL_LOG_LINHAS" -gt 0 ]; then
                # 6 colunas de recuo + o texto tem de caber na tela.
                _log=$(combate_log "$acc_dir" "$PANEL_LOG_LINHAS" $((LARG - 7)))
                # %s, e nao %b: o texto vem da pagina do jogo.
                [ -n "$_log" ] && BATALHAS="${BATALHAS}$(printf '%s' "$_log")
"
            fi
        fi

        # Uma linha por conta para o painel_render, que desenha a tabela.
        # O aviso (sessao caida, numeros parados) vai ao lado da atividade.
        _av=""; _avk=""
        if [ -n "$_sessao" ]; then
            _av="$_sessao"; _avk=vermelho
            [ "$_cor_s" = "$C_YELLOW" ] && _avk=amarelo
        elif [ -n "$_velho" ]; then
            _av="numeros parados ha $_velho"; _avk=amarelo
        fi
        LISTA="${LISTA}R$_US$_st$_US$sim$_US$nome$_US$_aba$_US$hp$_US$_hpmax$_US$ene$_US$lvl$_US$ouro$_US$prata$_US$_av$_US$_avk
"
    done 3< "$ACCOUNTS_FILE"

    if [ "${PANEL_DRAW:-$HAS_TTY}" = 1 ]; then
        # Titulo centralizado. Largura em COLUNAS ("·" tem 2 bytes): parte fixa
        # "Painel SLS · BR · " = 18 colunas, mais o relogio.
        _pad=$(( (LARG - 18 - ${#agora}) / 2 ))
        [ "$_pad" -lt 0 ] && _pad=0
        printf "%*s%bPainel SLS%b %b·%b %bBR%b %b· %s%b\n" "$_pad" '' \
               "$C_CYAN$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET" \
               "$C_WHITE" "$C_RESET" "$C_DIM" "$agora" "$C_RESET"
        painel_regua "$LARG"
        printf '%s' "$LISTA" | painel_render
        painel_regua "$LARG" tracejada

        # Ao vivo das batalhas, logo abaixo das contas; some sem luta.
        if [ "$n_fight" -gt 0 ]; then
            printf "  %b%sAO VIVO — BATALHAS (%s)%b\n" \
                "$C_RED$C_BOLD" "$I_LIVE" "$n_fight" "$C_RESET"
            printf "%b" "$BATALHAS"
            painel_regua "$LARG" tracejada
        fi

        # RODAPE: contadores, proximo evento e avisos, cortados na largura
        # pelo painel_render (o texto tem acento e "·").
        {
            printf 'C%s%s%s%s%s%s\n' "$_US" "$n_on" "$_US" "$n_up" "$_US" "$n_off"
            printf 'L%stracejada\n' "$_US"
            printf 'T%samarelo%s%s\n' "$_US" "$_US" "$(proximo_evento)"

            # Aviso curto no celular; a frase longa seria cortada.
            if [ "${PANEL_SUPERVISE:-0}" != "1" ]; then
                if [ "$LARG" -lt 44 ]; then
                    _msg="somente leitura"
                elif [ "$ESTREITO" = 1 ]; then
                    _msg="somente leitura — ctrl+c nao para nada"
                else
                    _msg="somente leitura — nao interfere nas contas; ctrl+c sai sem parar nada"
                fi
                printf 'T%scinza%s%s\n' "$_US" "$_US" "$_msg"
            fi

            # Painel rodando codigo antigo (subiu antes do git pull).
            if painel_desatualizado; then
                if [ "${PANEL_SUPERVISE:-0}" = "1" ]; then
                    _msg="codigo atualizado — reinicie: ./stop.sh && ./play.sh"
                elif [ "$LARG" -lt 50 ]; then
                    _msg="codigo novo — ctrl+c e ./status.sh"
                else
                    _msg="codigo atualizado — feche e abra o painel: ctrl+c e ./status.sh"
                fi
                printf 'T%samarelo%s%s\n' "$_US" "$_US" "$_msg"
            fi

            # Disjuntor global aberto (info.sh): servidor fora do ar.
            for _dj_f in "$HOME/.sls/net/"*.aberto; do
                [ -f "$_dj_f" ] || continue
                ler_arq "$_dj_f"
                case "$_LIDO" in ''|*[!0-9]*) _LIDO=$_agora_ep ;; esac
                _dj_tag=${_dj_f##*/}; _dj_tag=${_dj_tag%.aberto}
                if [ "$LARG" -lt 50 ]; then
                    _msg="$_dj_tag fora do ar - so batalhas"
                else
                    _msg="servidor $_dj_tag fora do ar ha $(( (_agora_ep - _LIDO) / 60 )) min — so batalhas, o resto espera"
                fi
                printf 'T%svermelho%s%s\n' "$_US" "$_US" "$_msg"
            done
            unset _dj_f _dj_tag

            # Quantas contas precisam de atencao, e o que fazer.
            if [ "$n_off" -gt 0 ] && [ "${PANEL_SUPERVISE:-0}" != "1" ]; then
                if [ "$LARG" -lt 50 ]; then
                    _msg="$n_off fora do ar - rode ./play.sh"
                else
                    _msg="$n_off conta(s) fora do ar — suba com: ./play.sh"
                fi
                printf 'T%svermelho%s%s\n' "$_US" "$_US" "$_msg"
            fi
        } | painel_render
    fi

    # Uma volta so (status.sh -1): desenha e sai, sem dormir.
    [ "${PANEL_ONCE:-0}" = "1" ] && break

    # 10 s no Termux (painel sempre aberto, CPU fraca), 5 s no PC;
    # "status.sh -n SEGUNDOS" escolhe outro intervalo.
    if [ -n "$PANEL_INTERVAL" ]; then
        sleep "$PANEL_INTERVAL"
    elif [ -d /data/data/com.termux ]; then
        sleep 10
    else
        sleep 5
    fi
done
}
