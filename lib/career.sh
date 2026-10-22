career_func() {
    printf "Career\n"
    CARREIRA_LUTOU=0
    fetch_page "/career/"

    # Exige link de ATAQUE para entrar: sem ele o cq_antes tomaria a
    # missao do cla sem poder cumpri-la, ocupando um slot a toa.
    if grep -q -o -E '/career/attack/[?]r[=][0-9]+' "$TMP/SRC"; then
        cq_antes carreira 2>/dev/null

        fetch_page "/career/"

        if grep -q -o -E '/career/(attack|take)/[?]r[=][0-9]+' "$TMP/SRC"; then
            CAREER=`grep -o -E '/career/(attack|take)/[?]r[=][0-9]+' "$TMP/SRC" | sed -n 1p`
            BREAK=$(($(date +%s) + 60))

            while [ -n "$CAREER" ] && [ "$(date +%s)" -lt "$BREAK" ]; do
                case $CAREER in
                    *attack*|*take*)
                        fetch_page "$CAREER"
                        CARREIRA_LUTOU=1
                        RESULT=`echo "$CAREER" | cut -d'/' -f3`
                        printf "Career -> %s\n" "$RESULT"
                        sleep 0.5s
                        CAREER=`grep -o -E '/career/(attack|take)/[?]r[=][0-9]+' "$TMP/SRC" | sed -n '1p'`
                        ;;
                esac
            done
        fi

        checkQuest 6 end
    else
        # RECOMPENSA SEM TORNEIO: o torneio volta a cada 8h e a coleta da
        # recompensa e uma vez ao dia (regra do jogo, conferida pelo dono).
        # Sem ataque na pagina a recompensa ficava esperando o proximo
        # torneio; agora e recolhida na visita, sem tomar a missao do cla.
        CAREER=`grep -o -E '/career/take/[?]r[=][0-9]+' "$TMP/SRC" | sed -n 1p`
        if [ -n "$CAREER" ] && ! botao_pago "$TMP/SRC" "$CAREER"; then
            fetch_page "$CAREER"
            printf "Career -> recompensa recolhida\n"
        fi
    fi

    printf "Career ok\n"
    return 0
}
