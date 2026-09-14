#!/bin/sh
# blessing.sh - Bencao
#
# A Bencao nao deve ser comprada automaticamente.
# Este modulo e carregado POR ULTIMO pelo run.sh e protege o ponto real de
# requisicao. Assim, mesmo que algum codigo legado volte a chamar
# /effshop/blessing/, a requisicao e bloqueada antes do curl sair.

blessing_url_bloqueada() {
    for _bl_arg in "$@"; do
        case "$_bl_arg" in
            *'/effshop/blessing/'*|*'/effshop/blessing?'*|*'/effshop/blessing')
                unset _bl_arg
                return 0
                ;;
        esac
    done
    unset _bl_arg
    return 1
}

blessing_registrar_bloqueio() {
    [ -n "${TMP:-}" ] || return 0
    printf '%s|Bencao|bloqueada|%s\n' "$(date +%s)" "$1" >> "$TMP/blessing_blocked.log" 2>/dev/null
}

# info.sh define _rc_run(), run_curl() e run_curl_exec(). Reutilizamos o
# mesmo motor HTTP e so acrescentamos a trava especifica da Bencao.
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
