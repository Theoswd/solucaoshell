# shellcheck disable=SC2154
# ============================================================
#  ALIADOS: SO QUEM ESTA NA LISTA DE AMIGOS E QUEM E DO MESMO CLA
#
#  Regra do dono do bot: a lista e uma so — amigos + membros do cla,
#  refeita do zero — e o modo escolhido no menu so decide EM QUAIS
#  batalhas ela vale:
#    1  todas as batalhas            allies.txt e callies.txt
#    2  Rei dos Imortais (herois)    allies.txt
#    3  batalhas de cla              callies.txt
#    4  nao mexer nas listas
#  Os dois arquivos guardam NOMES (espaco vira "_"), um por linha.
# ============================================================

# Nome no formato das listas: espacos viram "_".
_aliado_norm() { sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/[[:space:]][[:space:]]*/_/g'; }

# Le a pagina do jogo para um arquivo.   _aliado_pagina CAMINHO ARQUIVO
# NUNCA UM LINK DE EXCLUSAO: o "Exclui" da lista de amigos
# (/mail/friends/delete/ID?r=N) desfaz a amizade. Nenhum "delete" sai daqui.
_aliado_pagina() {
    case "$1" in *delete*) : > "$2"; return 1 ;; esac
    # Pagina que nao veio fica anotada: o aliados_montar nao troca a lista.
    # Pelo fetch_page, que devolve QUALQUER erro do curl.
    if ! fetch_page "$1" "$2" || [ ! -s "$2" ]; then
        : > "$TMP/aliados.falha"
        return 1
    fi
}

# AMIGOS: nomes da lista de amigos (/mail/friends e paginas seguintes).
#
# Marcacao real ("Lista de amigos"):
#   <img .../race/1-off.png' alt=''/> <a href='/user/ID/'>Fulano</a>,
#     <img .../level.png' alt=''/> 61 nível <span class='medium'>(
#     <a href='/mail/ID/'>Escrever</a> / <a href='/mail/friends/delete/ID?r=N'>Exclui</a>
# O link /mail/ na mesma linha separa o amigo de outro link de perfil.
# 10 amigos por pagina; o maior N dos links /mail/friends/N da pagina 1 diz
# quantas ha (ate 20).
aliados_amigos() {
    _aa_d="$TMP/aliados_pag"; mkdir -p "$_aa_d" 2>/dev/null
    rm -f "$_aa_d"/amigos_* 2>/dev/null
    _aliado_pagina "/mail/friends" "$_aa_d/amigos_1"
    _aa_n=`grep -o -E "/mail/friends/[0-9]+" "$_aa_d/amigos_1" 2>/dev/null \
        | sed 's,.*/,,' | sort -n | tail -n 1`
    case "$_aa_n" in ''|*[!0-9]*) _aa_n=1 ;; esac
    [ "$_aa_n" -gt 20 ] && _aa_n=20
    _aa_i=2
    while [ "$_aa_i" -le "$_aa_n" ]; do
        _aliado_pagina "/mail/friends/$_aa_i" "$_aa_d/amigos_$_aa_i"
        _aa_i=$((_aa_i + 1))
    done
    cat "$_aa_d"/amigos_* 2>/dev/null | awk -v q="'" '
        { t = t $0 "\n" }
        END {
            n = split(t, p, "/user/")
            for (i = 2; i <= n; i++) {
                s = p[i]
                if (!match(s, "^[0-9]+/" q ">")) continue
                nome = substr(s, RLENGTH + 1)
                j = index(nome, "<"); if (j) nome = substr(nome, 1, j - 1)
                if (index(s, "/mail/") && length(nome) > 0 && length(nome) <= 40) print nome
            }
        }' | _aliado_norm
    unset _aa_d _aa_n _aa_i
}

# MEMBROS DO CLA: nomes das paginas de membros (/clan/ID e /clan/ID//N).
#
# Marcacao real (pagina de membros do cla):
#   <a href='/user/ID/'><img src='/images/icon/race/1.png' alt=''/>Fulano,
#       <span class='white'><span class='green'>Clã líder</span></span>
#   <a href='/user/ID/'><img src='/images/icon/race/1-off.png' alt=''/>Beltrano,
#       <span class='white'>General</span>
# Qualquer nome (minusculas, numeros). Ate 10 paginas, pelos links do jogo.
aliados_cla() {
    [ -n "$CLD" ] || clan_id 2>/dev/null
    if [ -z "$CLD" ]; then
        # /clan sem resposta nao e o mesmo que estar sem cla.
        [ -s "$TMP/CLD" ] || : > "$TMP/aliados.falha"
        return 0
    fi
    _ac_d="$TMP/aliados_pag"; mkdir -p "$_ac_d" 2>/dev/null
    rm -f "$_ac_d"/cla_* 2>/dev/null
    _aliado_pagina "/clan/${CLD}" "$_ac_d/cla_1"
    _ac_n=`grep -o -E "/clan/${CLD}//?[0-9]+'" "$_ac_d/cla_1" 2>/dev/null \
        | sed "s,.*/,,; s,',," | sort -n | tail -n 1`
    case "$_ac_n" in ''|*[!0-9]*) _ac_n=1 ;; esac
    [ "$_ac_n" -gt 10 ] && _ac_n=10
    _ac_i=2
    while [ "$_ac_i" -le "$_ac_n" ]; do
        _aliado_pagina "/clan/${CLD}//${_ac_i}" "$_ac_d/cla_$_ac_i"
        _ac_i=$((_ac_i + 1))
    done
    # A propria conta e membro: pagina do cla sem nenhum nome nao carregou.
    _ac_nomes=`cat "$_ac_d"/cla_* 2>/dev/null | awk -v q="'" '
        { t = t $0 "\n" }
        END {
            n = split(t, p, "href=" q "/user/")
            for (i = 2; i <= n; i++) {
                s = p[i]
                if (!match(s, "^[0-9]+/" q "><img[^>]*>")) continue
                nome = substr(s, RLENGTH + 1)
                j = index(nome, ", <span class=" q "white" q ">")
                if (!j) continue
                nome = substr(nome, 1, j - 1)
                if (index(nome, "<") || length(nome) == 0 || length(nome) > 40) continue
                print nome
            }
        }' | _aliado_norm`
    if [ -n "$_ac_nomes" ]; then printf '%s\n' "$_ac_nomes"; else : > "$TMP/aliados.falha"; fi
    unset _ac_d _ac_n _ac_i _ac_nomes
}

# Monta as listas conforme o modo (1 a 4) — sem perguntar nada.
#
# Servidor mudo nao apaga a lista: se QUALQUER pagina nao vier, as listas
# anteriores ficam (so com os amigos, a nova perderia o cla). Sem lista
# anterior, a parcial vale e a funcao devolve 1 para tentar de novo mais cedo.
aliados_montar() {
    _am_modo="$1"
    case "$_am_modo" in 1|2|3) ;; 4) unset _am_modo; return 0 ;; *) _am_modo=1 ;; esac
    cd "$TMP" || return 1

    rm -f "$TMP/aliados.falha"
    { aliados_amigos; aliados_cla; } 2>/dev/null | grep -v '^$' | LC_ALL=C sort -u > "$TMP/aliados.novo"
    _am_rc=0
    [ -f "$TMP/aliados.falha" ] && _am_rc=1
    if [ ! -s "$TMP/aliados.novo" ] || { [ "$_am_rc" = 1 ] && [ -s "$TMP/aliados.txt" ]; }; then
        rm -f "$TMP/aliados.novo" "$TMP/aliados.falha"
        printf "Aliados: pagina de amigos ou do cla nao respondeu - listas mantidas\n"
        unset _am_modo _am_rc
        return 1
    fi
    rm -f "$TMP/aliados.falha"
    mv "$TMP/aliados.novo" "$TMP/aliados.txt"

    case "$_am_modo" in
        1) cp "$TMP/aliados.txt" "$TMP/allies.txt";  cp "$TMP/aliados.txt" "$TMP/callies.txt" ;;
        2) cp "$TMP/aliados.txt" "$TMP/allies.txt";  : > "$TMP/callies.txt" ;;
        3) : > "$TMP/allies.txt";                    cp "$TMP/aliados.txt" "$TMP/callies.txt" ;;
    esac
    printf "Aliados (amigos + cla): %s nome(s) - modo %s\n" \
        "`grep -c . "$TMP/aliados.txt" 2>/dev/null`" "$_am_modo"
    rm -rf "$TMP/aliados_pag" 2>/dev/null
    unset _am_modo
    return $_am_rc
}

# ============================================================
#  ATUALIZACAO AUTOMATICA DAS LISTAS DE ALIADOS
#
#  Os workers sobem com stdin em /dev/null: nada pode perguntar o modo pelo
#  teclado. O modo vem do config; o tarefas_livres chama a cada 12h.
# ============================================================
allies_refresh() {
    [ "${FUNC_allies:-y}" = "y" ] || return 1

    _ar=`get_config "ALLIES"`
    case "$_ar" in
        1|2|3) ;;
        # 4 = "nao mexer", escolha explicita do usuario no menu.
        4) unset _ar; return 0 ;;
        # Sem escolha registrada: protege em todas as batalhas (padrao seguro).
        *) _ar=1 ;;
    esac

    printf "Atualizando lista de aliados (modo %s)\n" "$_ar"
    aliados_montar "$_ar"
    _ar=$?
    return $_ar
}

# O alvo da vez e aliado?
#
#   $1 = arquivo com o nome do alvo   (USER, escrito pelo alvo_nome)
#   $2 = "cla" nas batalhas de cla    (usa callies.txt; senao allies.txt)
#
# Lista vazia nao pode significar "todo mundo e aliado": nome vazio devolve 1
# antes do grep; comparacao literal, de linha inteira, sem diferenca de
# maiusculas ("Ana" nao casa com "Anaxx").
alvo_aliado() {
    # O alvo_nome ja grava normalizado: um "read" embutido, nenhum processo.
    _aa_n=""
    [ -r "$1" ] && read -r _aa_n < "$1" 2>/dev/null
    if [ -n "$2" ]; then _aa_l="$TMP/callies.txt"; else _aa_l="$TMP/allies.txt"; fi
    if [ -n "$_aa_n" ] && [ -s "$_aa_l" ] && grep -qixF "$_aa_n" "$_aa_l" 2>/dev/null; then
        unset _aa_n _aa_l; return 0
    fi
    unset _aa_n _aa_l
    return 1
}

# ============================================================
#  TROCA DE ALVO POR ALIADO, SEM VIRAR LACO — E O FOGO AMIGO
#
#  Quando so ha aliados na frente, cada troca cai em outro aliado e o laco
#  nao termina. Regra do dono: depois de ALIADO_TROCAS_MAX trocas seguidas
#  caindo em aliado, fogo amigo por ALIADO_FOGO_SEG segundos; depois volta a
#  tentar trocar. Estado em variaveis; a lista so e consultada quando o NOME
#  do alvo muda.
# ============================================================
ALIADO_TROCAS_MAX=3
ALIADO_FOGO_SEG=30

# Zera o estado no inicio de cada luta (luta_inicio): a lista pode ter mudado.
aliado_zerar() { _al_nome="-"; _aliado=0; _al_seguidas=0; _al_trocou=0; _al_fogo_ate=0; }

# Na leitura de cada pagina da luta, depois do alvo_nome.   aliado_ler [cla]
#
# Define _aliado (1 = o alvo da pagina e aliado) e conta o resultado da troca
# anterior: caiu em aliado de novo soma, caiu em inimigo zera.
aliado_ler() {
    _al_n=""
    { read -r _al_n < USER; } 2>/dev/null
    if [ "$_al_n" != "$_al_nome" ]; then
        _al_nome="$_al_n"
        if alvo_aliado USER "$1"; then _aliado=1; else _aliado=0; fi
    fi
    unset _al_n
    if [ "$_aliado" = 0 ]; then
        _al_seguidas=0
    elif [ "$_al_trocou" = 1 ]; then
        _al_seguidas=$(( _al_seguidas + 1 ))
    fi
    _al_trocou=0
}

# Trocar de alvo agora?   troca_aliado AGORA   (0 = troca)
#
# Sempre o ULTIMO teste da condicao de troca: devolvendo 0, a troca sai, e
# ela fica anotada para o aliado_ler contar o resultado.
troca_aliado() {
    [ "$_aliado" = 1 ] || return 1
    [ "$1" -lt "$_al_fogo_ate" ] && return 1
    if [ "$_al_seguidas" -ge "$ALIADO_TROCAS_MAX" ]; then
        _al_seguidas=0
        _al_fogo_ate=$(( $1 + ALIADO_FOGO_SEG ))
        printf "So aliados na frente (%s trocas) - fogo amigo por %ss\n" \
               "$ALIADO_TROCAS_MAX" "$ALIADO_FOGO_SEG"
        return 1
    fi
    _al_trocou=1
    # No log de todos os eventos: o status.sh -batalhas conta as trocas por esta linha.
    printf "Alvo aliado — trocando de alvo\n"
    return 0
}
