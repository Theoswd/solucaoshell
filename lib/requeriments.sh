#!/bin/sh
# requeriments.sh - User-Agent da conta (servidor/URL/TMP vem do play.sh
# pelas variaveis SLS_SRV, SLS_URL, SLS_ACC_DIR).

# USER-AGENT DA CONTA — SORTEADO UMA VEZ, DEPOIS FIXO em $TMP/ua: a mesma
# sessao nao troca de navegador a cada reinicio. Para sortear outro, basta
# apagar esse arquivo. A semente leva o PID (srand() sem argumento e o
# relogio, e as contas sobem no mesmo segundo). "grep -c ''" conta tambem a
# ultima linha sem quebra, que o "wc -l" perde.
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
