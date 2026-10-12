#!/bin/sh
# lib/batalhas.sh - Resumo das ultimas batalhas de cada conta, SOMENTE LEITURA
#
# Le o sls.log de cada conta (e o sls.log.1, da rotacao) e mostra, por
# evento, a ultima batalha: a hora em que comecou, quantas paginas de luta
# leu (cada acao do laco relê a pagina: e quase o numero de acoes), o menor
# HP visto, as trocas por aliado, o fogo amigo e por que a luta acabou.
# Nao toca em processo nenhum.
#
# Uso (pelo status.sh):
#   ./status.sh -batalhas             todas as contas, todos os eventos
#   ./status.sh -batalhas Rei         so um evento (Rei, Vale, Altares, Torneio,
#                                     Duelo, ColiseuCla, Bandeiras, Equipe, Coliseu)
#   ./status.sh -batalhas Rei Gatuno  so um evento e as contas com "Gatuno" no nome

FILTRO_EV="$1"
FILTRO_CONTA="$2"
BASE="${SLS_HOME:-$HOME/.sls}"

for _d in "$BASE"/BR_*; do
    [ -d "$_d" ] || continue
    _c=${_d##*/BR_}
    if [ -n "$FILTRO_CONTA" ]; then
        case "$_c" in *"$FILTRO_CONTA"*) ;; *) continue ;; esac
    fi
    _logs=""
    [ -f "$_d/sls.log.1" ] && _logs="$_d/sls.log.1"
    [ -f "$_d/sls.log" ] && _logs="$_logs $_d/sls.log"
    [ -n "$_logs" ] || continue
    # shellcheck disable=SC2086
    cat $_logs 2>/dev/null | awk -v conta="$_c" -v filtro="$FILTRO_EV" '
        function inicio(ev) {
            if (v) fecha("sem fim no log")
            v = 1; e = ev; n = 0; tr = 0; fa = 0; hmin = ""; motivo = ""; extra = ""
            h0 = hora
        }
        function fecha(m) {
            if (!v) return
            if (m != "") motivo = m
            if (motivo == "") motivo = "-"
            linha[e] = sprintf("%-5s %4d acoes  HPmin %-6s trocas %-2d fogo %-2d %s%s",
                               (h0 == "" ? "--:--" : h0), n, (hmin == "" ? "-" : hmin), tr, fa, motivo, extra)
            v = 0
        }
        # Hora: a linha do relogio da volta ("https://... 21:55").
        /^https?:\/\/[^ ]+ [0-9][0-9]:[0-9][0-9]$/ { hora = $NF; next }
        /The clan tournament will be started/   { inicio("Torneio"); next }
        /The clan duel will be started/         { inicio("Duelo"); next }
        /Altars will be started/                { inicio("Altares"); next }
        /Clan coliseum will be started/         { inicio("ColiseuCla"); next }
        /Flagfight will be started/             { inicio("Bandeiras"); next }
        /King of the Immortals will be started/ { inicio("Rei"); next }
        /Valley of the Immortals will be started/ { inicio("Vale"); next }
        /Torneio de equipe: (entrando|.*aguardando a luta|em andamento)/ { inicio("Equipe"); next }
        # O inicio() fecha o evento que ficou aberto (sem a linha "ok").
        /^  Entering\.\.\.$/ || /Luta do coliseu em andamento/ { inicio("Coliseu"); next }
        !v { next }
        /Em batalha/ {
            n++
            if (match($0, /HP: [0-9]+/)) {
                x = substr($0, RSTART + 4, RLENGTH - 4) + 0
                if (hmin == "" || x < hmin) hmin = x
            }
            next
        }
        /trocando de alvo/ { tr++; next }
        /fogo amigo/       { fa++; next }
        /^Vale: /          { extra = "  >> " substr($0, 7); next }
        /Battle (is )?over|Undying: luta encerrada/ {
            m = $0; sub(/^[^(]*\(/, "", m); sub(/\)\.?$/, "", m); motivo = m; next
        }
        # Sem luta o evento termina aqui, sem a linha "ok": fecha, senao o
        # Coliseu seguinte entrava na conta dele.
        /nenhuma luta na pagina/ { fecha("nenhuma luta na pagina"); next }
        /It was not possible to start the battle/ { motivo = "nao conseguiu entrar"; next }
        /^(ClanFight|Clan duel|Altars|Clancoliseum|Flagfight|Clancommand|King|Undying) ok$/ { fecha(""); next }
        /^The battle is over!$/ { if (e == "Coliseu") fecha(""); next }
        END {
            if (v) fecha("em andamento (ou sem fim no log)")
            for (k in linha) if (filtro == "" || k == filtro) print k "|" conta "|" linha[k]
        }'
done | sort -t'|' -k1,1 -k2,2 | awk -F'|' '
    $1 != ultimo { if (NR > 1) print ""; print "== " $1; ultimo = $1 }
    { printf "  %-18s %s\n", $2, $3 }'
