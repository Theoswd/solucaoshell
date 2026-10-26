#!/bin/sh
# blessing.sh - Bencao
#
# A Bencao nao deve ser comprada automaticamente. Carregado POR ULTIMO, este
# modulo bloqueia /effshop/blessing/ no ponto real de requisicao.

blessing_url_bloqueada() {
    for _bl_arg in "$@"; do
        case "$_bl_arg" in
            *'/effshop/blessing/'*|*'/effshop/blessing?'*|*'/effshop/blessing')
                _BL_MOTIVO=Bencao
                unset _bl_arg
                return 0
                ;;
            *'/trade/exchange/gold/'*)
                # No russo (tiwar.ru) este link COMPRA prata gastando ouro;
                # no BR e a troca prata -> ouro de todo dia (trade.sh).
                if [ "${SLS_TAG:-BR}" = RU ]; then
                    _BL_MOTIVO="Cambio ouro->prata"
                    unset _bl_arg
                    return 0
                fi
                ;;
        esac
    done
    unset _bl_arg
    return 1
}

blessing_registrar_bloqueio() {
    [ -n "${TMP:-}" ] || return 0
    printf '%s|%s|bloqueada|%s\n' "$(date +%s)" "${_BL_MOTIVO:-Bencao}" "$1" >> "$TMP/blessing_blocked.log" 2>/dev/null
}

# info.sh define _rc_run(), run_curl() e run_curl_exec(): mesmo motor HTTP,
# so com a trava da Bencao.
run_curl() {
    if blessing_url_bloqueada "$@"; then
        blessing_registrar_bloqueio "$*"
        return 1
    fi
    _rc_run "" "$@"
}

run_curl_exec() {
    if blessing_url_bloqueada "$@"; then
        blessing_registrar_bloqueio "$*"
        return 1
    fi
    _rc_run "exec" "$@"
}
