#!/bin/sh
specialEvent() {
    # A chave vale aqui: o horario das 09:25 e 21:25 (run.sh) chama direto.
    [ "${FUNC_auto_events:-y}" = "y" ] || return 0
    # O worker nao reinicia: sem isto, com a Home ja sem evento, o ramo e o
    # link do ultimo evento eram repetidos.
    unset EVENT event_link
    # A Home que o descanso gravou ha menos de 5 min (com a sessao viva) ja
    # traz o banner do evento: sem pedir de novo.
    _se_pg="$TMP/REST"
    _se_ok=0; { read -r _se_ok < "$TMP/.home_ok"; } 2>/dev/null
    case "$_se_ok" in ''|*[!0-9]*) _se_ok=0 ;; esac
    _se_ok=$(( `date +%s` - _se_ok ))
    if [ ! -s "$_se_pg" ] || [ "$_se_ok" -lt 0 ] || [ "$_se_ok" -ge 300 ]; then
        fetch_page "/"
        _se_pg="$TMP/SRC"
    fi

    if grep -q "shb_text" "$_se_pg"; then
        event_link=`grep -o -E "<div class='shb_text'><a href='[^']+'" "$_se_pg" | sed -E "s/^.*href='([^']+)'.*$/\1/" | sed -n '1p'`

        if [ -n "$event_link" ]; then
            EVENT=`echo "$event_link" | cut -d'/' -f2`
            printf "Current event: %s\n" "$EVENT"
        fi
    fi

    case $EVENT in
        questrnd)
            fetch_page "$event_link"
            printf "Event Adventure\n"
            click=`grep -o -E "/questrnd/take/[?]r=[0-9]+" "$TMP/SRC" | sed -n '1p'`
            if [ -n "$click" ]; then
                fetch_page "$click"
                printf "Claiming reward\n"
                return 0
            else
                return 1
            fi
            ;;
        fault)
            fetch_page "${event_link}"
            printf "Event fault\n"
            click=`grep -o -E "/fault/attack/\?r=[0-9]+" "$TMP/SRC" | sed -n '1p'`
            # Limite de tempo: se o link de ataque continuar presente,
            # o laco nao terminava sozinho.
            SE_BREAK=$(($(date +%s) + 90))
            while [ "$(date +%s)" -lt "$SE_BREAK" ]; do
                if [ -n "${click}" ]; then
                    fetch_page "${click}"
                    click=`grep -o -E "/fault/attack/\?r=[0-9]+" "$TMP/SRC" | sed -n '1p'`
                    printf "Attacking monster\n"
                else
                    printf "Event fault ok\n"
                    break
                fi
            done
            ;;
        clandmgfight)
            case `date +%H:%M` in
                09:2[5-9]|21:2[5-9])
                    clandmgfight_start
                    ;;
                *)
                    return 1
                    ;;
            esac
            ;;
        marathon)
            fetch_page "/marathon/"
            printf "Marathon event\n"
            click=`grep -o -E "/marathon/take/\?r=[0-9]+" "$TMP/SRC" | sed -n '1p'`
            if [ -n "$click" ]; then
                fetch_page "$click"
                printf "Claiming reward\n"
                return 0
            else
                return 1
            fi
            ;;
        *)
            return 1
            ;;
    esac
}
