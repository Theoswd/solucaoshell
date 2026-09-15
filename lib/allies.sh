# shellcheck disable=SC2154
# ============================================================
#  ALIADOS: SO QUEM ESTA NA LISTA DE AMIGOS E QUEM E DO MESMO CLA
#
#  Regra do dono do bot. Antes a lista era montada de tres jeitos que nao
#  batiam com isso:
#    - conta COM amigos ficava so com os amigos, SEM os membros do cla (o
#      clan era lido apenas quando a lista de amigos vinha vazia). Em 12/09
#      uma conta matou outra no Rei — as duas do mesmo cla, e nenhuma na
#      lista da outra: uma tinha 4 amigos, a outra 3, e o cla ficou de fora;
#    - clas INTEIROS eram poupados nas batalhas de cla quando o LIDER era
#      amigo (uma requisicao por amigo para descobrir);
#    - a lista de amigos so crescia (tmp.txt nunca era zerado): quem saia
#      dos amigos continuava aliado para sempre.
#
#  Agora a lista e uma so — amigos + membros do cla, refeita do zero — e o
#  modo escolhido no menu so decide EM QUAIS batalhas ela vale:
#    1  todas as batalhas            allies.txt e callies.txt
#    2  Rei dos Imortais (herois)    allies.txt
#    3  batalhas de cla              callies.txt
#    4  nao mexer nas listas
#  Os dois arquivos guardam NOMES (espaco vira "_"), um por linha.
# ============================================================

# Nome no formato das listas: espacos viram "_".
_aliado_norm() { sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/[[:space:]][[:space:]]*/_/g'; }

# Le a pagina do jogo para um arquivo.   _aliado_pagina CAMINHO ARQUIVO
#
# NUNCA UM LINK DE EXCLUSAO. A lista de amigos traz, em cada amigo, o link
# "Exclui" (/mail/friends/delete/ID?r=N): pedir essa pagina desfaz a amizade.
# Nenhum caminho com "delete" sai daqui, venha de onde vier.
_aliado_pagina() {
    case "$1" in *delete*) : > "$2"; return 1 ;; esac
    (
        run_curl_exec "${URL}$1" > "$2"
    ) </dev/null > /dev/null 2>&1 &
    # Pagina que nao veio fica anotada: o aliados_montar nao troca a lista.
    if ! time_exit 17 || [ ! -s "$2" ]; then
        : > "$TMP/aliados.falha"
        return 1
    fi
}

# AMIGOS: nomes da lista de amigos (/mail/friends e paginas seguintes).
#
# Marcacao real ("Lista de amigos", 13/09):
#   <img .../race/1-off.png' alt=''/> <a href='/user/ID/'>Fulano</a>,
#     <img .../level.png' alt=''/> 61 nível <span class='medium'>(
#     <a href='/mail/ID/'>Escrever</a> / <a href='/mail/friends/delete/ID?r=N'>Exclui</a>
# O link de mensagem (/mail/) na mesma linha separa o amigo de qualquer outro
# link de perfil. A pagina abre sem o ?r= do link do jogo.
#
# PAGINAS: 10 amigos por pagina. Paginacao real (conta com 12 amigos):
#   &#60;&#60; &#60; 1 <a href='/mail/friends/2'>2</a> <a href='/mail/friends/2'>&#62;</a>
# O maior N dos links da pagina 1 diz quantas ha (ate 20). Conferido: 10 + 2
# amigos, os mesmos 12 da lista antiga, com dois pedidos.
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
# Marcacao real (pagina de membros do cla, 12/09):
#   <a href='/user/ID/'><img src='/images/icon/race/1.png' alt=''/>Fulano,
#       <span class='white'><span class='green'>Clã líder</span></span>
#   <a href='/user/ID/'><img src='/images/icon/race/1-off.png' alt=''/>Beltrano,
#       <span class='white'>General</span>
# A leitura antiga exigia nome com maiuscula e so letras (nome todo em minusculas,
# nomes com numero ficavam de fora). Ate 10 paginas, pelos links do proprio jogo.
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
# SERVIDOR MUDO NAO APAGA A LISTA: se QUALQUER pagina de amigos ou do cla nao
# vier, as listas anteriores ficam como estao. So com os amigos, a lista nova
# perderia o cla — o caso de 12/09 — e ficaria valendo por 12h. Sem lista
# anterior, a parcial vale (melhor que nenhuma) e a funcao devolve 1 para o
# worker tentar de novo mais cedo.
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
#  Os workers sobem com stdin em /dev/null (play.sh, nohup+setsid): nada
#  pode perguntar o modo pelo teclado. Sem esta funcao as listas ficavam
#  vazias para sempre e a protecao de aliados, lida a cada golpe, nunca
#  poupava ninguem.
#
#  O modo vem do config e o tarefas_livres chama esta funcao a cada 12h (ver
#  crono.sh). Custo: as paginas de amigos e as de membros do cla — ja nao
#  ha uma requisicao por amigo.
# ============================================================
allies_refresh() {
    [ "${FUNC_allies:-y}" = "y" ] || return 1

    _ar=`get_config "ALLIES"`
    case "$_ar" in
        1|2|3) ;;
        # 4 = "nao mexer", escolha explicita do usuario no menu.
        4) unset _ar; return 0 ;;
        # Sem escolha registrada: protege em todas as batalhas. E o padrao
        # seguro — errar para o lado de NAO bater em aliado.
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
# LISTA VAZIA NAO PODE SIGNIFICAR "TODO MUNDO E ALIADO": nome vazio devolve 1
# antes do grep, e a comparacao e literal e de linha inteira ("Ana" nao casa
# com "Anaxx"). Sem diferenca de maiusculas: o jogo escreve "Fulano Silva"
# na luta e "Fulano silva" pode estar noutro lugar.
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
