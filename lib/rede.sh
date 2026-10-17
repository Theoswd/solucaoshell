#!/bin/sh
# lib/rede.sh - Telemetria das requisicoes, SOMENTE LEITURA
#
# Le o req.stat de cada conta (uma linha por requisicao: epoch, codigo
# HTTP, tempo em ms, codigo do curl; gravado pelo tele_registrar do info.sh)
# e resume os ultimos MIN minutos por conta e por servidor: requisicoes por
# minuto, tempo medio e P95 das que responderam, sem resposta (curl != 0) e
# HTTP 429/5xx. O P95 sai de um histograma de 100 ms: sem ordenar, um awk so.
#
# Uso:
#   ./status.sh -rede [MIN]     tabela por conta (padrao: 10 min)
#   sh rede.sh -linha LARG      uma linha por servidor, para o rodape do painel

MODO=tabela
LARG=80
if [ "$1" = "-linha" ]; then MODO=linha; LARG="${2:-80}"; shift 2; fi
JAN="${1:-10}"
case "$JAN" in ''|*[!0-9]*|0) JAN=10 ;; esac
case "$LARG" in ''|*[!0-9]*) LARG=80 ;; esac
BASE="${SLS_HOME:-$HOME/.sls}"

set --
for _f in "$BASE"/*_*/req.stat; do
    [ -s "$_f" ] && set -- "$@" "$_f"
done
if [ "$#" -eq 0 ]; then
    [ "$MODO" = tabela ] && printf "Sem telemetria ainda (as contas gravam req.stat a cada requisicao).\n"
    exit 0
fi

awk -v agora="`date +%s`" -v jan="$JAN" -v modo="$MODO" -v larg="$LARG" '
    function num(x) { s = sprintf("%.1f", x); sub(/\./, ",", s); return s }
    # Taxa por minuto: uma casa abaixo de 10 (pouco trafego nao vira "0").
    function taxa(x) { return (x < 10 ? num(x) : sprintf("%d", x + 0.5)) }
    function p95(k,    b, c, alvo) {
        alvo = ok[k] * 0.95; c = 0
        for (b = 0; b <= 300; b++) { c += h[k, b]; if (c >= alvo) return (b + 1) / 10 }
        return 30
    }
    function soma(k, ms, rc, http) {
        n[k]++
        if (rc != 0) { sr[k]++; return }
        if (http == 429 || http >= 500) e5[k]++
        ok[k]++; t[k] += ms
        b = int(ms / 100); if (b > 300) b = 300
        h[k, b]++
    }
    FNR == 1 {
        conta = FILENAME; sub(/\/req\.stat$/, "", conta); sub(/.*\//, "", conta)
        tag = conta; sub(/_.*/, "", tag)
        if (!(conta in vista)) { vista[conta] = 1; contas[++nc] = conta; tagde[conta] = tag }
        if (!(tag in vtag)) { vtag[tag] = 1; tags[++nt] = tag }
    }
    $1 + 0 >= agora - jan * 60 { soma(conta, $3 + 0, $4 + 0, $2 + 0); soma("@" tag, $3 + 0, $4 + 0, $2 + 0) }
    END {
        if (modo == "linha") {
            for (i = 1; i <= nt; i++) {
                k = "@" tags[i]; if (!n[k]) continue
                med = ok[k] ? t[k] / ok[k] / 1000 : 0
                if (larg < 50)
                    printf "%s %s/min %ss p95 %ss%s\n", tags[i], taxa(n[k] / jan), num(med), (ok[k] ? num(p95(k)) : "-"), (sr[k] ? " " sr[k] " sem resp" : "")
                else
                    printf "rede %s (%d min): %s req/min · media %s s · P95 %s s · %d sem resposta · %d HTTP 5xx\n",
                           tags[i], jan, taxa(n[k] / jan), num(med), (ok[k] ? num(p95(k)) : "-"), sr[k], e5[k]
            }
            exit
        }
        printf "Requisicoes dos ultimos %d min\n\n", jan
        printf "%-24s %7s %7s %7s %8s %6s\n", "conta", "req/min", "media", "P95", "sem resp", "HTTP5x"
        for (i = 1; i <= nc; i++) {
            k = contas[i]
            printf "%-24s %7s %6ss %6ss %8d %6d\n", substr(k, 1, 24), taxa(n[k] / jan),
                   (ok[k] ? num(t[k] / ok[k] / 1000) : "-"), (ok[k] ? num(p95(k)) : "-"), sr[k], e5[k]
        }
        for (i = 1; i <= nt; i++) {
            k = "@" tags[i]
            printf "%-24s %7s %6ss %6ss %8d %6d\n", "TOTAL " tags[i], taxa(n[k] / jan),
                   (ok[k] ? num(t[k] / ok[k] / 1000) : "-"), (ok[k] ? num(p95(k)) : "-"), sr[k], e5[k]
        }
    }' "$@"
