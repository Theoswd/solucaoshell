# shellcheck disable=SC2154
# ============================================================
#  ALIADOS: OS MEMBROS DO CLA DA CONTA E A LISTA DE IDS DO SERVIDOR
#
#  Regra do dono do bot (29/10): aliado e
#    - quem e membro do cla da propria conta (pelo ID do cla, CLD);
#    - quem e membro de um cla aliado da lista (ID do cla);
#    - o jogador da lista (ID do jogador), cadastrado a mao no setup.sh.
#  A lista de amigos do jogo NAO conta mais. Quem sai do cla e nao esta na
#  lista individual vira inimigo na atualizacao seguinte: a lista e refeita
#  do zero ao subir a conta (play.sh) e a cada 12h.
#
#  Lista de IDs, uma por servidor e comum a todas as contas dele (o setup.sh
#  grava, opcao 7):  ~/.sls/aliados_<TAG>.conf   linhas "j|ID" ou "c|ID".
#  Na luta o alvo aparece so pelo NOME: os IDs viram nomes pela pagina de
#  perfil (/user/ID/) e pelas paginas de membros (/clan/ID), guardados em
#  ~/.sls/aliados_<TAG>.nomes ("j|ID|Nome", "c|ID|Nome"; "-" = nao achou).
#
#  O modo escolhido no menu so decide EM QUAIS batalhas a lista vale:
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

# MEMBROS DE UM CLA: nomes das paginas de membros (/clan/ID e /clan/ID//N).
#   _aliados_membros ID   (1 = alguma pagina nao veio)
#
# Marcacao real (pagina de membros do cla):
#   <a href='/user/ID/'><img src='/images/icon/race/1.png' alt=''/>Fulano,
#       <span class='white'><span class='green'>Clã líder</span></span>
#   <a href='/user/ID/'><img src='/images/icon/race/1-off.png' alt=''/>Beltrano,
#       <span class='white'>General</span>
# Qualquer nome (minusculas, numeros). Ate 10 paginas, pelos links do jogo.
_aliados_membros() {
    _ac_id="$1"
    _ac_d="$TMP/aliados_pag"; mkdir -p "$_ac_d" 2>/dev/null
    rm -f "$_ac_d"/cla_* 2>/dev/null
    _aliado_pagina "/clan/${_ac_id}" "$_ac_d/cla_1" || { unset _ac_id _ac_d; return 1; }
    _ac_n=`grep -o -E "/clan/${_ac_id}//?[0-9]+'" "$_ac_d/cla_1" 2>/dev/null \
        | sed "s,.*/,,; s,',," | sort -n | tail -n 1`
    case "$_ac_n" in ''|*[!0-9]*) _ac_n=1 ;; esac
    [ "$_ac_n" -gt 10 ] && _ac_n=10
    _ac_i=2
    while [ "$_ac_i" -le "$_ac_n" ]; do
        _aliado_pagina "/clan/${_ac_id}//${_ac_i}" "$_ac_d/cla_$_ac_i"
        _ac_i=$((_ac_i + 1))
    done
    cat "$_ac_d"/cla_* 2>/dev/null | awk -v q="'" '
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
        }'
    unset _ac_id _ac_d _ac_n _ac_i
    [ ! -f "$TMP/aliados.falha" ]
}

# MEMBROS DO CLA DA CONTA (CLD): o cla dela e sempre aliado.
aliados_cla() {
    [ -n "$CLD" ] || clan_id 2>/dev/null
    if [ -z "$CLD" ]; then
        # /clan sem resposta nao e o mesmo que estar sem cla.
        [ -f "$TMP/CLD" ] || : > "$TMP/aliados.falha"
        return 0
    fi
    # A propria conta e membro: pagina do cla sem nenhum nome nao carregou.
    _ac_nomes=`_aliados_membros "$CLD" | _aliado_norm`
    if [ -n "$_ac_nomes" ]; then printf '%s\n' "$_ac_nomes"; else : > "$TMP/aliados.falha"; fi
    unset _ac_nomes
}

# NOME DE UM JOGADOR PELO ID, da pagina de perfil.   _aliado_jogador ID
# Nada impresso = ID que nao existe; 1 = pagina nao veio ou sessao caida.
#
# Marcacao real (/user/3386065/, 29/10):
#   <title>Abyssal Draco ... <b>Abyssal Draco</b> ...
#   <a href='/clan/2092'>Abyssal Millennium</a> ...
#   <a href='/user/3386065?show=might'>Poder: ...
# ID que nao existe NAO da erro: o jogo mostra o perfil da PROPRIA conta, com
# os links dela. So vale a pagina cujos links "?show=" sao do ID pedido.
_aliado_jogador() {
    _aj_f="$TMP/aliados_pag/jog_$1"
    mkdir -p "$TMP/aliados_pag" 2>/dev/null
    _aliado_pagina "/user/$1/" "$_aj_f" || { unset _aj_f; return 1; }
    # Sessao caida (pagina de visitante, 404 para qualquer perfil) nao e "ID
    # que nao existe": conta como pagina que nao veio.
    if [ "`sessao_estado "$_aj_f"`" != viva ]; then
        : > "$TMP/aliados.falha"; unset _aj_f; return 1
    fi
    if grep -q -E "/user/$1/?[?]show=" "$_aj_f" 2>/dev/null; then
        grep -o '<title>[^<]*' "$_aj_f" | sed 's/<title>//' | tr -d '|' \
            | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | head -n 1
    fi
    unset _aj_f
}

# Arquivos da lista de IDs do servidor desta conta.
_aliados_arquivos() {
    _al_conf="$HOME/.sls/aliados_${SLS_TAG:-BR}.conf"
    _al_nomes="$HOME/.sls/aliados_${SLS_TAG:-BR}.nomes"
    _al_marca="$HOME/.sls/.aliados_${SLS_TAG:-BR}.feito"
    _al_trava="$HOME/.sls/.aliados_${SLS_TAG:-BR}.trava"
}

# Os IDs da lista viram nomes, no ~/.sls/aliados_<TAG>.nomes. As contas do
# servidor dividem o trabalho: a que pega a trava consulta todos os IDs; as
# outras esperam por ela e leem o resultado. Vale por ALIADOS_CACHE_MIN,
# ou ate o setup.sh mudar a lista (o .conf fica mais novo que a marca).
ALIADOS_CACHE_MIN=60
aliados_ids_resolver() {
    _aliados_arquivos
    [ -s "$_al_conf" ] || return 0
    if [ -f "$_al_marca" ] && [ ! "$_al_conf" -nt "$_al_marca" ] && \
       [ -n "`find "$_al_marca" -mmin -"$ALIADOS_CACHE_MIN" 2>/dev/null`" ]; then
        return 0
    fi
    _ar_n=0
    until mkdir "$_al_trava" 2>/dev/null; do
        _ar_d=""; { read -r _ar_d < "$_al_trava/pid"; } 2>/dev/null
        trava_dono_vivo "$_ar_d" "$_al_trava" || trava_tomar "$_al_trava"
        sleep 3
        _ar_n=$((_ar_n + 1))
        # Outra conta terminou neste meio tempo: o resultado dela vale.
        if [ -f "$_al_marca" ] && [ ! "$_al_conf" -nt "$_al_marca" ] && \
           [ -n "`find "$_al_marca" -mmin -"$ALIADOS_CACHE_MIN" 2>/dev/null`" ]; then
            unset _ar_n _ar_d; return 0
        fi
        # Ate 45 s: a espera nao pode segurar a conta na hora de inscrever
        # num evento. Depois segue com o que houver; sem nada ainda, conta
        # como pagina que nao veio (nova tentativa em 30 min, crono.sh).
        if [ "$_ar_n" -ge 15 ]; then
            [ -s "$_al_nomes" ] || : > "$TMP/aliados.falha"
            unset _ar_n _ar_d; return 0
        fi
    done
    echo $$ > "$_al_trava/pid" 2>/dev/null

    _ar_tmp="$_al_nomes.$$"; : > "$_ar_tmp"
    _ar_ok=1
    # Linhas "j|ID" e "c|ID"; o resto e ignorado.
    for _ar_l in `tr -d '\r ' < "$_al_conf" | grep -E '^[jc]\|[0-9]+$'`; do
        _ar_id=${_ar_l#?|}
        case "$_ar_l" in
            j*) _ar_nm=`_aliado_jogador "$_ar_id"` || { _ar_ok=0; break; }
                printf 'j|%s|%s\n' "$_ar_id" "${_ar_nm:--}" >> "$_ar_tmp" ;;
            c*) _ar_nm=`_aliados_membros "$_ar_id"` || { _ar_ok=0; break; }
                # ID de cla que nao existe: sem membros.
                if [ -n "$_ar_nm" ]; then
                    printf '%s\n' "$_ar_nm" | tr -d '|' | sed "s/^/c|$_ar_id|/" >> "$_ar_tmp"
                else
                    printf 'c|%s|-\n' "$_ar_id" >> "$_ar_tmp"
                fi ;;
        esac
    done
    # Pagina que nao veio: o resultado anterior fica, sem marca nova.
    if [ "$_ar_ok" = 1 ]; then
        mv "$_ar_tmp" "$_al_nomes" && : > "$_al_marca"
    else
        rm -f "$_ar_tmp"
    fi
    rm -rf "$_al_trava" 2>/dev/null
    unset _ar_n _ar_d _ar_tmp _ar_ok _ar_l _ar_id _ar_nm
    [ ! -f "$TMP/aliados.falha" ]
}

# Nomes dos IDs da lista (jogadores e membros dos clas aliados), so dos IDs
# que ainda estao no .conf: o que o setup tirou sai na hora.
aliados_ids() {
    _aliados_arquivos
    [ -s "$_al_conf" ] && [ -s "$_al_nomes" ] || return 0
    tr -d '\r ' < "$_al_conf" | awk -F'|' '
        NR == FNR { ok[$1 "|" $2] = 1; next }
        ($1 "|" $2) in ok && $3 != "-" && $3 != "" { print $3 }' - "$_al_nomes" | _aliado_norm
}

# Monta as listas conforme o modo (1 a 4) — sem perguntar nada.
#
# Servidor mudo nao apaga a lista: se QUALQUER pagina nao vier, as listas
# anteriores ficam (so com parte dos nomes, a nova perderia aliados). Sem
# lista anterior, a parcial vale e a funcao devolve 1 para tentar de novo
# mais cedo.
aliados_montar() {
    _am_modo="$1"
    case "$_am_modo" in 1|2|3) ;; 4) unset _am_modo; return 0 ;; *) _am_modo=1 ;; esac
    cd "$TMP" || return 1

    rm -f "$TMP/aliados.falha"
    aliados_ids_resolver > /dev/null 2>&1
    { aliados_cla; aliados_ids; } 2>/dev/null | grep -v '^$' | LC_ALL=C sort -u > "$TMP/aliados.novo"
    _am_rc=0
    [ -f "$TMP/aliados.falha" ] && _am_rc=1
    if [ ! -s "$TMP/aliados.novo" ] || { [ "$_am_rc" = 1 ] && [ -s "$TMP/aliados.txt" ]; }; then
        rm -f "$TMP/aliados.novo" "$TMP/aliados.falha"
        printf "Aliados: pagina do cla ou de um ID nao respondeu - listas mantidas\n"
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
    printf "Aliados (cla + lista de IDs): %s nome(s) - modo %s\n" \
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
