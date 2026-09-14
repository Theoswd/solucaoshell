#!/bin/sh
# requeriments.sh
# No modelo multi-conta, servidor/URL/TMP sao injetados pelo play.sh
# via variaveis de ambiente (SLS_SRV, SLS_URL, SLS_ACC_DIR, etc)
# Aqui fica so o User-Agent da conta.

# USER-AGENT DA CONTA — SORTEADO UMA VEZ, DEPOIS FIXO.
#
# CORRECAO 1 (a conta trocava de navegador a cada reinicio): o sorteio
# acontecia em TODO arranque do worker. Do outro lado, a mesma sessao —
# mesmo cookie, mesmo IP — aparecia ora como Chrome no Windows, ora como
# Safari no Mac. Um navegador de verdade nao faz isso. Agora o agente e
# sorteado na primeira vez e gravado em $TMP/ua: cada conta passa a ser um
# aparelho constante. Para sortear outro, basta apagar esse arquivo.
#
# CORRECAO 2 (todas as contas com o mesmo agente): "srand()" sem argumento
# e semeado pelo RELOGIO em varios awk (busybox, mawk antigo). Como as
# contas sobem no mesmo segundo, todas sorteavam o MESMO numero — a lista
# de 72 agentes virava um so. A semente agora leva o PID, o mesmo padrao
# que o cq_sorteia ja usava por este motivo.
#
# CORRECAO 3: "wc -l" nao conta a ultima linha quando o arquivo nao termina
# em quebra de linha, e o ultimo agente da lista nunca era sorteado. O
# "grep -c ''" conta linha por linha.
random_ua() {
    # Ja sorteado: reusa. Leitura embutida, sem nenhum processo.
    if [ -s "$TMP/ua" ]; then
        read -r vUserAgent < "$TMP/ua" 2>/dev/null
        if [ -n "$vUserAgent" ]; then
            export vUserAgent
            return 0
        fi
    fi

    [ -f "$TMP/userAgent.txt" ] || return 1

    _ua_total=`grep -c '' "$TMP/userAgent.txt" 2>/dev/null`
    case "$_ua_total" in ''|0|*[!0-9]*) unset _ua_total; return 1 ;; esac

    _ua_n=`awk -v max="$_ua_total" -v s=$$ \
        'BEGIN { srand(s * 7919 + systime()); printf "%d", int(rand() * max) + 1 }'`
    case "$_ua_n" in ''|0|*[!0-9]*) _ua_n=1 ;; esac

    vUserAgent=`sed -n "${_ua_n}p" "$TMP/userAgent.txt"`
    if [ -n "$vUserAgent" ]; then
        printf '%s\n' "$vUserAgent" > "$TMP/ua" 2>/dev/null
        export vUserAgent
    fi
    unset _ua_total _ua_n
}
