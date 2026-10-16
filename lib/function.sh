
# Valores padrao. Uma chave por linha.
config_defaults() {
    cat <<'EOF'
FUNC_check_rewards=y
FUNC_use_elixir=y
FUNC_trade=y
FUNC_trade_dias=365
FUNC_coliseum=y
FUNC_clan_fight=y
FUNC_collect_mission_rewards=y
FUNC_auto_events=y
FUNC_clan_missions=y
FUNC_clan_quests=y
FUNC_clan_help=y
FUNC_allies=y
FUNC_arena_min=30
FUNC_evento_min=10
FUNC_cq_min=15
FUNC_masmorra=y
FUNC_masmorra_min=45
FUNC_masmorra_max=15
FUNC_estatua_horas=6
FUNC_stats_min=5
FUNC_clan_statue=y
ALLIES=
EOF
}

# Carrega a configuracao da conta.
#
# As chaves ausentes sao completadas SEMPRE (vazio != "n" ligaria o que esta
# desligado). Seguranca: o arquivo e lido como DADO, com allowlist de chaves
# e validacao de valor; configuracao nunca e executada.
load_config() {
    CONFIG_FILE="${TMP:-.}/config.cfg"
    [ -f "$CONFIG_FILE" ] || : > "$CONFIG_FILE"

    # Chaves que faltam, na ordem dos padroes: um awk le o arquivo uma vez.
    config_defaults | awk -v f="$CONFIG_FILE" '
        BEGIN { while ((getline l < f) > 0) if (index(l, "=")) tem[substr(l, 1, index(l, "=") - 1)] = 1 }
        { k = $0; sub(/=.*/, "", k); if (k != "" && !(k in tem)) print }' >> "$CONFIG_FILE"

    # Painel: quem estava no 3 (padrao antigo gravado no config.cfg) passa
    # para 5 uma unica vez; valor escolhido depois fica como esta.
    if [ ! -f "${TMP:-.}/.cfg_stats5" ]; then
        if grep -q '^FUNC_stats_min=3$' "$CONFIG_FILE" 2>/dev/null; then
            while IFS= read -r _cl; do
                case "$_cl" in FUNC_stats_min=3) _cl=FUNC_stats_min=5 ;; esac
                printf '%s\n' "$_cl"
            done < "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv -f "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        fi
        : > "${TMP:-.}/.cfg_stats5" 2>/dev/null
        unset _cl
    fi

    _cr=$(printf '\r')
    while IFS='=' read -r _ck _cv; do
        # Salvo no Windows (CRLF): o \r reprovava o valor e valia o padrao.
        _cv=${_cv%"$_cr"}
        # Chave vai para o eval: "FUNC_x;comando" nao pode passar.
        case "$_ck" in *[!A-Za-z0-9_]*) continue ;; esac
        case "$_ck" in
            FUNC_*|ALLIES|CAVE_SILVER_LIMIT) ;;
            *) continue ;;
        esac
        case "$_cv" in
            *[!A-Za-z0-9_.:/-]*) continue ;;
        esac
        # Zero a esquerda: no dash $((08 * 60)) e erro fatal e 010 vira 8.
        case "$_cv" in 0[0-9]*) case "$_cv" in *[!0-9]*) ;; *) _cv=${_cv#"${_cv%%[!0]*}"}; _cv=${_cv:-0} ;; esac ;; esac
        eval "${_ck}=\"\$_cv\""
    done < "$CONFIG_FILE"

    unset _ck _cv _dk _dv _cr
}

get_config() {
    _gc_key="$1"
    load_config
    # Lê o valor diretamente do arquivo (compatível com sh, sem ${!var})
    grep -E "^${_gc_key}=" "$CONFIG_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '\r'
}

