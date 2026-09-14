
# Valores padrao. Uma chave por linha.
config_defaults() {
    cat <<'EOF'
FUNC_check_rewards=y
FUNC_use_elixir=y
FUNC_trade=y
FUNC_trade_dias=365
FUNC_coliseum=y
FUNC_play_league=999
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
FUNC_stats_min=3
FUNC_clan_statue=y
ALLIES=
EOF
}

# Carrega a configuracao da conta.
#
# CORRECAO 1 (multi-contas): a versao anterior so gravava os defaults quando
# o arquivo NAO existia. Como o info.sh criava config.cfg com apenas
# "LANGUAGE=en" no momento do source, o ramo dos defaults nunca rodava e
# TODAS as FUNC_* ficavam vazias. Efeito pratico: use_elixir e check_rewards
# comparavam com "n", vazio != "n", e executavam mesmo desligados; e
# league.sh fazia [ "$N" -gt "" ] -> erro de operando a cada ciclo.
# Agora as chaves ausentes sao completadas SEMPRE, o que tambem repara
# configs ja gravados de forma incompleta.
#
# CORRECAO 2 (seguranca): antes era ". $CONFIG_FILE", ou seja, o arquivo de
# configuracao era EXECUTADO como shell script. Agora e lido como dado, com
# allowlist de chaves e validacao de valor. Configuracao e dado, nunca codigo.
load_config() {
    CONFIG_FILE="${TMP:-.}/config.cfg"
    [ -f "$CONFIG_FILE" ] || : > "$CONFIG_FILE"

    config_defaults | while IFS='=' read -r _dk _dv; do
        [ -n "$_dk" ] || continue
        grep -q "^${_dk}=" "$CONFIG_FILE" 2>/dev/null || \
            printf '%s=%s\n' "$_dk" "$_dv" >> "$CONFIG_FILE"
    done

    while IFS='=' read -r _ck _cv; do
        case "$_ck" in
            FUNC_*|ALLIES|CAVE_SILVER_LIMIT) ;;
            *) continue ;;
        esac
        case "$_cv" in
            *[!A-Za-z0-9_.:/-]*) continue ;;
        esac
        eval "${_ck}=\"\$_cv\""
    done < "$CONFIG_FILE"

    unset _ck _cv _dk _dv
}

get_config() {
    _gc_key="$1"
    load_config
    # Lê o valor diretamente do arquivo (compatível com sh, sem ${!var})
    grep -E "^${_gc_key}=" "$CONFIG_FILE" 2>/dev/null | cut -d'=' -f2-
}

