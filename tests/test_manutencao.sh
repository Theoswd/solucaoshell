#!/bin/sh
# tests/test_manutencao.sh
#
# Testes da manutencao dos sistemas de batalha, HP, itens, Liga dos Favoritos
# e temporizacao. Nao acessa a rede: as requisicoes sao simuladas (stub de
# fetch_page). Roda em qualquer /bin/sh (dash, busybox, bash).
#
#   Uso:  sh tests/test_manutencao.sh
#
# Cobre:
#   1. HP atual x HP maximo (percentual, isolamento por conta, leitura falha)
#   2. Decisao de esquiva/ataque a partir da perda de HP
#   3. Invariante: a cura NAO sobrescreve o HP maximo (FULL)
#   4. Liga dos Favoritos: estado da recompensa separado das lutas, coleta
#      atrasada e confirmacao pelo servidor
#   5. Temporizacao: o sleep intermediario passou de 1s para 0,5s
#   6. Rei: a batalha continua depois que o rei morre (esquiva + elixir 67%)
#   7. Recargas das acoes e itens pagos em ouro descartados
#   8. Cronograma de batalhas: prioridade, dedicacao e volta a rotina
#   9. Nenhuma atividade gasta ouro (so a troca prata -> ouro, 1x ao dia)
#  10. Painel: cabe na tela do celular (DPI 346-360) em 36 a 60 colunas
#  11. Estrutura: raiz so com os comandos, motor em lib/, sem modulo orfao
#  12. User-Agent: um por conta, estavel entre reinicios

_dir=$(dirname "$0")
ROOT=$(cd "$_dir/.." 2>/dev/null && pwd -P) || ROOT="."
# O motor vive em lib/; a raiz so tem os comandos do usuario.
LIB="$ROOT/lib"

PASS=0
FAIL=0
# Disjuntor global (info.sh) desligado na suite: as falhas simuladas dos
# testes iriam para o ~/.sls/net de verdade e segurariam os testes seguintes.
# A secao 56 o liga num HOME proprio.
SLS_DISJUNTOR=0
export SLS_DISJUNTOR
ok()   { PASS=$((PASS + 1)); printf "  [PASS] %s\n" "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf "  [FALHA] %s\n" "$1"; }
check(){ # check "descricao" valor_esperado valor_obtido
    if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1 (esperado=$2 obtido=$3)"; fi
}

# ---- helpers que replicam EXATAMENTE as expressoes usadas nos modulos ------
hp_percent() { # HP_ATUAL HP_MAXIMO -> percentual inteiro (ou "-" se invalido)
    _a="$1"; _m="$2"
    case "$_a" in ''|*[!0-9]*) printf '%s' "-"; return ;; esac
    case "$_m" in ''|*[!0-9]*|0) printf '%s' "-"; return ;; esac   # sem divisao por zero/vazio
    printf '%s' "$(( _a * 100 / _m ))"
}
hlhp() {  # FULL HPER -> limiar de cura, como nos modulos (awk)
    awk -v ush="$1" -v hper="$2" 'BEGIN { printf "%.0f", ush * hper / 100 }'
}
perdeu_hp() { # HP_ATUAL HP_ANTERIOR -> 1 se perdeu vida
    awk -v ush="$1" -v oldhp="$2" 'BEGIN { exit !(ush < oldhp) }' && echo 1 || echo 0
}

printf "=== 1. HP ATUAL x HP MAXIMO ===\n"
check "HP 1000/1000 = 100%" 100 "$(hp_percent 1000 1000)"
check "HP 800/1000  = 80%"  80  "$(hp_percent 800 1000)"
check "HP 670/1000  = 67%"  67  "$(hp_percent 670 1000)"
check "HP 400/1000  = 40%"  40  "$(hp_percent 400 1000)"
# 67% ou menos dispara tentativa de esmalte
_p=$(hp_percent 670 1000)
if [ "$_p" -le 67 ]; then ok "HP 67% aciona esmalte (<=67)"; else bad "HP 67% deveria acionar esmalte"; fi
_p=$(hp_percent 800 1000)
if [ "$_p" -le 67 ]; then bad "HP 80% NAO deveria acionar esmalte"; else ok "HP 80% nao aciona esmalte"; fi

printf "\n=== 1b. Leitura de HP invalida (nao usar maximo como padrao) ===\n"
check "HP atual ausente -> '-' (mantem ultimo valido, nao vira maximo)" "-" "$(hp_percent '' 1000)"
check "HP maximo ausente -> '-' (sem divisao)" "-" "$(hp_percent 670 '')"
check "HP maximo zero   -> '-' (sem divisao por zero)" "-" "$(hp_percent 670 0)"

printf "\n=== 1c. Isolamento por conta ===\n"
# Cada conta tem seu proprio estado; uma nao herda o HP da outra.
HP_ATUAL_01=670; HP_MAX_01=1000
HP_ATUAL_02=250; HP_MAX_02=500
check "Conta 01 percentual" 67 "$(hp_percent $HP_ATUAL_01 $HP_MAX_01)"
check "Conta 02 percentual" 50 "$(hp_percent $HP_ATUAL_02 $HP_MAX_02)"
check "Conta 01 nao mudou apos ler a 02" 670 "$HP_ATUAL_01"

printf "\n=== 2. Perda de HP decide esquiva x ataque ===\n"
check "HP caiu (670<800) -> perdeu=1 -> ESQUIVA" 1 "$(perdeu_hp 670 800)"
check "HP estavel (800=800) -> perdeu=0 -> ATAQUE" 0 "$(perdeu_hp 800 800)"

printf "\n=== 3. Invariante: cura NAO sobrescreve o HP maximo (FULL) ===\n"
# Simula o branch de cura corrigido: apos curar, FULL permanece o maximo.
HP_MAXIMO=1000
HPER=48
HP_ATUAL=400
LIMIAR_ANTES=$(hlhp "$HP_MAXIMO" "$HPER")     # 480
# --- cura: HP sobe; no codigo CORRIGIDO FULL nao e tocado ---
HP_ATUAL=900                                   # curou
# (o bug antigo fazia: HP_MAXIMO=$HP_ATUAL  -> aqui NAO fazemos isso)
LIMIAR_DEPOIS=$(hlhp "$HP_MAXIMO" "$HPER")     # continua 480
check "HP maximo preservado apos cura" 1000 "$HP_MAXIMO"
check "Limiar de cura estavel (nao sobe/desce a cada golpe)" "$LIMIAR_ANTES" "$LIMIAR_DEPOIS"
# Prova de regressao: nenhum modulo reintroduz o overwrite no branch de cura.
# Os modulos ficam em lib/: com "$ROOT" o grep nao achava os arquivos (codigo
# 2) e o teste passava sem ter lido nada. Codigo 2 agora e falha.
grep -nE 'cat (HP|USH) > FULL|cat USH > "\$full_ram"|echo "\$USH" > "\$full_ram"|_fullat="\$_hpat"' \
        "$LIB"/king.sh "$LIB"/clanfight.sh "$LIB"/clandmg.sh "$LIB"/altars.sh \
        "$LIB"/coliseum.sh "$LIB"/flagfight.sh >/dev/null 2>&1
case $? in
    0) bad "algum modulo ainda sobrescreve o HP maximo com o HP atual" ;;
    1) ok "nenhum modulo sobrescreve o HP maximo com o HP atual" ;;
    *) bad "regressao do HP maximo: modulos de batalha nao encontrados em lib/" ;;
esac

printf "\n=== 4. Liga dos Favoritos: recompensa separada das lutas ===\n"
# Sourceia as funcoes REAIS da league.sh e simula o servidor via fetch_page.
TMP=$(mktemp -d)
export TMP
URL="http://exemplo"
# Estado da simulacao: qual "pagina" o servidor devolve
SIM_PAGE=""                 # conteudo escrito em $TMP/SRC pelo fetch_page
SIM_CLICKED=0               # o botao foi clicado?
SIM_REWARD_APPEARS_AT=99    # em qual chamada de "/league/" a recompensa surge
SIM_CALLS=0

fetch_page() {  # stub: simula o servidor
    _u="$1"
    case "$_u" in
        /league/)
            SIM_CALLS=$((SIM_CALLS + 1))
            if [ "$SIM_CLICKED" = 1 ]; then
                # apos coletar, o botao some (coleta confirmada)
                printf 'league page sem botao\n' > "${2:-$TMP/SRC}"
            elif [ "$SIM_CALLS" -ge "$SIM_REWARD_APPEARS_AT" ]; then
                printf '<a href="/league/takeReward/?r=12345">coletar</a>\n' > "${2:-$TMP/SRC}"
            else
                printf 'league page sem recompensa ainda\n' > "${2:-$TMP/SRC}"
            fi
            ;;
        /league/takeReward/*)
            SIM_CLICKED=1
            printf 'reward taken\n' > "$TMP/SRC"
            ;;
        *) printf '' > "$TMP/SRC" ;;
    esac
    unset _u
}

# Carrega as funcoes de recompensa reais (league.sh so define funcoes).
. "$LIB/league.sh" >/dev/null 2>&1

# 4a. Concluir 5 lutas apenas marca pendente (nunca "coletada")
league_reward_limpar
league_reward_marcar
if league_reward_pendente; then ok "5 lutas concluidas -> recompensa pendente=sim"; else bad "deveria ficar pendente"; fi

# 4b. Recompensa ATRASADA: 1a passagem nao ha botao -> permanece pendente
SIM_CLICKED=0; SIM_CALLS=0; SIM_REWARD_APPEARS_AT=99   # nunca aparece nesta passagem
if league_collect_reward; then bad "nao havia botao; nao deveria confirmar"; else ok "recompensa atrasada: coleta nao confirmada (retorno 1)"; fi
if league_reward_pendente; then ok "estado preservado como pendente apos passagem sem botao"; else bad "pendente foi apagado indevidamente"; fi

# 4c. Nova passagem: recompensa aparece -> coleta e confirma pelo servidor
SIM_CLICKED=0; SIM_CALLS=0; SIM_REWARD_APPEARS_AT=1    # aparece ja na 1a leitura
if league_collect_reward; then
    ok "recompensa atrasada coletada e confirmada pelo servidor"
    league_reward_limpar
else
    bad "recompensa presente deveria ser coletada"
fi
if league_reward_pendente; then bad "pendente deveria ter sido limpo apos confirmacao"; else ok "pendente limpo somente apos confirmacao real"; fi

# 4d. Coleta que o servidor NAO confirma (botao persiste) -> continua pendente
SIM_CLICKED=0; SIM_CALLS=0; SIM_REWARD_APPEARS_AT=1
# forca o botao a persistir mesmo apos o clique:
fetch_page() {
    case "$1" in
        /league/) printf '<a href="/league/takeReward/?r=999">coletar</a>\n' > "${2:-$TMP/SRC}" ;;
        /league/takeReward/*) printf 'sem efeito\n' > "$TMP/SRC" ;;
        *) printf '' > "$TMP/SRC" ;;
    esac
}
league_reward_marcar
if league_collect_reward; then bad "servidor nao confirmou; nao deveria dar sucesso"; else ok "coleta nao confirmada -> retorno 1 (sera reprogramada)"; fi
if league_reward_pendente; then ok "estado segue pendente para nova tentativa"; else bad "pendente nao deveria ser limpo sem confirmacao"; fi

# 4e. Liberar novas lutas NAO apaga o estado de recompensa pendente
AVAILABLE_FIGHTS=5   # cinco lutas novas liberadas
if league_reward_pendente; then ok "novas lutas nao apagam recompensa pendente"; else bad "novas lutas apagaram o estado pendente"; fi
league_reward_limpar
rm -rf "$TMP"

printf "\n=== 5. Prioridade da cura x esquiva (altars, torneio e duelo de cla) ===\n"
# Nesses modulos a cura deve ser avaliada ANTES da esquiva, para a conta nao
# morrer esperando a releitura de HP que so viria depois do dodge.
for f in altars.sh clanfight.sh clandmg.sh; do
    _heal_ln=$(grep -n 'read -r _l < HEAL; run_curl_exec "${URL}$_l"' "$LIB/$f" | head -n1 | cut -d: -f1)
    _dodge_ln=$(grep -n 'read -r _l < DODGE; run_curl_exec "${URL}$_l"' "$LIB/$f" | head -n1 | cut -d: -f1)
    if [ -n "$_heal_ln" ] && [ -n "$_dodge_ln" ] && [ "$_heal_ln" -lt "$_dodge_ln" ]; then
        ok "$f: cura (linha $_heal_ln) antes da esquiva (linha $_dodge_ln)"
    else
        bad "$f: cura deveria vir antes da esquiva (heal=$_heal_ln dodge=$_dodge_ln)"
    fi
done
# flagfight e clancoliseum ja eram cura-primeiro
for f in flagfight.sh clancoliseum.sh; do
    _heal_ln=$(grep -n '< HEAL;\|< SHIELD;' "$LIB/$f" | head -n1 | cut -d: -f1)
    _dodge_ln=$(grep -n '< DODGE;' "$LIB/$f" | head -n1 | cut -d: -f1)
    if [ -n "$_heal_ln" ] && [ -n "$_dodge_ln" ] && [ "$_heal_ln" -lt "$_dodge_ln" ]; then
        ok "$f: cura/escudo antes da esquiva"
    else
        bad "$f: cura deveria vir antes da esquiva (heal=$_heal_ln dodge=$_dodge_ln)"
    fi
done

printf "\n=== 6. Uma requisicao por ciclo: recarga espera sem requisitar ===\n"
# O ramo ocioso (else) so faz requisicao quando o alvo esta grey; fora disso
# espera o restante da recarga com 'sleep \$_resta', sem recarregar a pagina.
for f in clanfight.sh clandmg.sh altars.sh coliseum.sh clancoliseum.sh flagfight.sh clancommand.sh; do
    # O Coliseu (3.9.107) acorda no minimo da troca quando ela e a proxima
    # acao: _col_alvo e o LA ou o COL_TROCA_MIN.
    if grep -q 'LA - _latk\|LA - .*last_atk\|LA - time_since_last_atk\|_col_alvo - time_since_last_atk' "$LIB/$f"; then
        ok "$f: espera o restante da recarga (sleep do cooldown, sem request)"
    else
        bad "$f: nao encontrou a espera de recarga sem requisicao"
    fi
done
# E o topo do laco nao rele a pagina de novo (reparse redundante removido).
for f in clanfight.sh clandmg.sh altars.sh; do
    if grep -q 'SEM RELEITURA NO TOPO DO LACO' "$LIB/$f"; then
        ok "$f: reparse redundante do topo do laco removido"
    else
        bad "$f: ainda ha releitura redundante no topo do laco"
    fi
done

printf "\n=== 7. Temporizacao real: intervalo entre ataques ~ cooldown (sem inflar) ===\n"
# Simula o modelo NOVO (atacar -> esperar o restante da recarga -> atacar) e o
# ANTIGO (atacar -> recarregar pagina + pacing a cada volta). Usa LA reduzido
# para o teste rodar rapido. Mede o intervalo real entre "ataques".
# Modela FIELMENTE o codigo novo (marca last_atk no INICIO da volta):
#   _atk0 = agora ; request custa RTT ; age = RTT ; _resta = LA - age ;
#   espera _resta ; intervalo entre golpes = RTT + (LA - RTT) = LA.
# Ou seja: o tempo do request e ABSORVIDO pela recarga, e o intervalo fica
# em ~LA, nao LA+RTT. Compara com o modelo ANTIGO (last_atk no fim), cujo
# intervalo era RTT + LA.
_sim() {  # MODO LA RTTms -> imprime 3 intervalos em ms
    _mode="$1"; _la="$2"; _rttms="$3"; _prev=""
    _i=0
    while [ "$_i" -lt 4 ]; do
        _atk0=$(date +%s%N 2>/dev/null); [ -n "$_atk0" ] || _atk0=$(( $(date +%s) * 1000000000 ))
        # "request" do ataque: custa RTT
        _s=$(awk -v m="$_rttms" 'BEGIN{printf "%.3f", m/1000}')
        sleep "$_s"
        _t=$(date +%s%N 2>/dev/null); [ -n "$_t" ] || _t=$(( $(date +%s) * 1000000000 ))
        [ -n "$_prev" ] && printf '%s\n' "$(( (_t - _prev) / 1000000 ))"
        _prev="$_t"
        # recarga: NOVO subtrai o tempo ja gasto; ANTIGO espera LA cheio
        if [ "$_mode" = novo ]; then
            _gastoms=$(( (_t - _atk0) / 1000000 ))
            _restams=$(( _la * 1000 - _gastoms ))
        else
            _restams=$(( _la * 1000 ))
        fi
        [ "$_restams" -gt 0 ] && sleep "$(awk -v m="$_restams" 'BEGIN{printf "%.3f", m/1000}')"
        _i=$((_i + 1))
    done
}
# LA=1s, RTT=400ms.  novo -> ~1000ms (LA).  antigo -> ~1400ms (LA+RTT).
_okc=0; _n=0
for _ms in $(_sim novo 1 400); do
    _n=$((_n + 1))
    [ "$_ms" -ge 900 ] && [ "$_ms" -le 1300 ] && _okc=$((_okc + 1))
    printf "  [INFO] NOVO  intervalo medido: %s ms (alvo ~1000)\n" "$_ms"
done
for _ms in $(_sim antigo 1 400); do
    printf "  [INFO] ANTIGO intervalo medido: %s ms (inflado ~1400)\n" "$_ms"
done
if [ "$_n" -gt 0 ] && [ "$_okc" -eq "$_n" ]; then
    ok "tempo do request absorvido pela recarga: intervalo ~ LA (nao LA+RTT)"
else
    bad "intervalo do modelo novo fora de ~LA ($_okc/$_n na faixa)"
fi
printf "  [INFO] Em producao LA=4s -> intervalo ~4-5s (confirmar com log real).\n"

printf "\n=== 8. Encerramento: o worker realmente para (sem relance) ===\n"
# 8a. Estatico: no stop.sh o orquestrador (play.sh) e morto ANTES do laco que
# derruba os workers. Se fosse depois, o supervisor relancaria um worker ja
# morto no meio do encerramento e ele sobreviveria.
_orch_ln=$(grep -n 'orchestrator.pid' "$ROOT/stop.sh" | head -n1 | cut -d: -f1)
_loop_ln=$(grep -n 'for pid_file in' "$ROOT/stop.sh" | head -n1 | cut -d: -f1)
if [ -n "$_orch_ln" ] && [ -n "$_loop_ln" ] && [ "$_orch_ln" -lt "$_loop_ln" ]; then
    ok "stop.sh mata o orquestrador (linha $_orch_ln) antes do laco de workers (linha $_loop_ln)"
else
    bad "stop.sh deveria matar o orquestrador antes do laco (orch=$_orch_ln loop=$_loop_ln)"
fi

# 8b. Empirico: reproduz a corrida supervisor/worker com processos reais.
#     ANTIGO (mata worker antes do supervisor) -> um worker relancado sobrevive.
#     NOVO   (mata supervisor antes do worker) -> nada sobrevive.
_simdir=$(mktemp -d)
_pidf="$_simdir/worker.pid"
_allf="$_simdir/all"; : > "$_allf"
# 'exec sleep' faz o PID rastreado SER o sleep (sem shell-pai sobrando).
# Cada spawn e registrado em $_allf para a limpeza nao deixar orfaos.
_novo_worker() { sh -c 'exec sleep 30' & _wp=$!; echo "$_wp" > "$_pidf"; echo "$_wp" >> "$_allf"; }
_supervisor() {  # relanca o worker sempre que o PID do .pid estiver morto
    while [ -f "$_simdir/sup_on" ]; do
        _p=$(cat "$_pidf" 2>/dev/null)
        if [ -n "$_p" ] && ! kill -0 "$_p" 2>/dev/null; then _novo_worker; fi
        sleep 0.1
    done
}
_kill_tracked() {  # mata TODOS os workers ja criados (o .pid guarda so o ultimo)
    while read -r _ap; do [ -n "$_ap" ] && kill -KILL "$_ap" 2>/dev/null; done < "$_allf"
    : > "$_allf"
}

# --- Cenario ANTIGO: worker primeiro, supervisor depois ---
: > "$_simdir/sup_on"
_novo_worker; _w0=$(cat "$_pidf")
_supervisor & _SUP=$!
sleep 0.3
kill -KILL "$_w0" 2>/dev/null      # mata o worker (supervisor ainda vivo)
sleep 0.4                          # o supervisor relanca nesse intervalo
rm -f "$_simdir/sup_on"; kill -KILL "$_SUP" 2>/dev/null   # so agora para o supervisor
sleep 0.2
_wnow=$(cat "$_pidf" 2>/dev/null)
if [ -n "$_wnow" ] && kill -0 "$_wnow" 2>/dev/null && [ "$_wnow" != "$_w0" ]; then
    ok "ordem ANTIGA reproduz o bug: worker relancado ($_wnow) sobreviveu"
else
    bad "esperava um worker sobrevivente na ordem antiga (obtido='$_wnow' orig=$_w0)"
fi
_kill_tracked

# --- Cenario NOVO: supervisor primeiro, worker depois ---
: > "$_simdir/sup_on"
_novo_worker; _w0=$(cat "$_pidf")
_supervisor & _SUP=$!
sleep 0.3
rm -f "$_simdir/sup_on"; kill -KILL "$_SUP" 2>/dev/null   # supervisor PRIMEIRO
sleep 0.2
kill -KILL "$_w0" 2>/dev/null      # agora o worker, sem quem o relance
sleep 0.4
_wnow=$(cat "$_pidf" 2>/dev/null)
if [ -z "$_wnow" ] || ! kill -0 "$_wnow" 2>/dev/null; then
    ok "ordem NOVA: nenhum worker sobrevive apos o stop"
else
    bad "ordem nova deixou worker vivo ($_wnow)"
fi
_kill_tracked
rm -rf "$_simdir"

printf "\n=== 9. Dependencias: jq nao e usado; pacotes que ajudam ===\n"
# jq nao aparece na logica do bot (so em textos de README/uninstall).
if grep -rn '[^A-Za-z_]jq ' "$ROOT"/*.sh "$LIB"/*.sh | grep -vq 'pkg install\|apt \|command -v\|foram mantidos\|uninstall jq\|remove --purge'; then
    bad "jq apareceu na logica do bot (revisar)"
else
    ok "jq NAO e usado pela logica do bot (pode ser omitido do install)"
fi
# Comandos que os pacotes recomendados fornecem, realmente usados:
for _pair in "setsid:util-linux" "pgrep:procps" "pkill:procps" "readlink:coreutils" "stat:coreutils"; do
    _cmd=${_pair%%:*}; _pkg=${_pair##*:}
    if grep -rqn "[^A-Za-z_]$_cmd" "$ROOT"/*.sh "$LIB"/*.sh; then
        ok "usa '$_cmd' (pacote $_pkg) -> recomendado instalar"
    else
        bad "'$_cmd' nao encontrado (esperado em uso)"
    fi
done

printf "\n=== 10. Cronograma: espera curta cobre TODA janela de evento ===\n"
# Replica a decisao do func_sleep (crono.sh). i=15 tem de valer em todos os
# minutos de entrada de evento; senao uma espera de 60s engole a janela e o
# evento e abandonado (nem chega a inscrever).
_fs_i() { case "$1" in 9|1[0-4]|2[4-9]|30|5[4-9]) echo 15 ;; *) echo 60 ;; esac; }
# Minutos de entrada reais dos eventos:
#   Bandeiras 10-14 ; Rei/Especiais/ColiseuCla 25-29 ; Torneio/Altares/Vale/ColiseuCla 55-59
_ev_min="10 11 12 13 14 25 26 27 28 29 55 56 57 58 59"
_falhou=""
for _m in $_ev_min; do [ "$(_fs_i "$_m")" = 15 ] || _falhou="$_falhou $_m"; done
if [ -z "$_falhou" ]; then
    ok "todos os minutos de entrada de evento usam espera curta (15s)"
else
    bad "espera longa (60s) em minutos de evento:$_falhou"
fi
# Regressao: os minutos 14, 58 e 59 (bordas antes descobertas) agora sao 15s.
for _m in 14 58 59; do
    [ "$(_fs_i "$_m")" = 15 ] && ok "minuto $_m coberto (antes engolia o evento)" \
                              || bad "minuto $_m ainda em espera longa"
done
# Minuto fora de evento continua com espera longa (nao gasta a toa).
[ "$(_fs_i 45)" = 60 ] && ok "minuto sem evento (45) mantem espera de 60s" \
                       || bad "minuto 45 nao deveria usar espera curta"
# E o codigo real traz o padrao corrigido.
if grep -q '9|1\[0-4\]|2\[4-9\]|30|5\[4-9\])' "$LIB/crono.sh"; then
    ok "crono.sh contem o padrao de minutos corrigido"
else
    bad "crono.sh nao tem o padrao de janela corrigido"
fi

printf "\n=== 11. Encerramento limpo para atualizacao (git pull) ===\n"
# stop.sh remove a trava global de login, senao um restart pode travar ate 180s.
if grep -q 'rm -rf "\$HOME/.sls/.login.lock"' "$ROOT/stop.sh"; then
    ok "stop.sh libera a trava global de login (.login.lock) no encerramento"
else
    bad "stop.sh nao remove a trava de login (restart pode atrasar 180s)"
fi
# stop.sh tambem derruba painel (status.sh) e tem redes de seguranca finais.
grep -q 'pkill -f "\$LIBDIR/sls.sh"'    "$ROOT/stop.sh" && ok "stop.sh: rede de seguranca pkill sls.sh"    || bad "stop.sh sem pkill sls.sh"
grep -q 'pkill -f "\$LIBDIR/worker.sh"' "$ROOT/stop.sh" && ok "stop.sh: rede de seguranca pkill worker.sh" || bad "stop.sh sem pkill worker.sh"

printf "\n=== 12. Escala: isolamento por conta e serializacao do login ===\n"
# Cada modulo de batalha grava seu estado APOS 'cd \"\$TMP\"' (TMP e por conta).
# Sem esse cd, os arquivos bare (HP, BREAK_LOOP, ...) colidiriam entre contas.
for f in king.sh clanfight.sh clandmg.sh altars.sh clancoliseum.sh flagfight.sh clancommand.sh; do
    if grep -q 'cd "\$TMP"' "$LIB/$f"; then
        ok "$f: isola estado por conta (cd \$TMP)"
    else
        bad "$f: nao faz 'cd \$TMP' — risco de colisao entre contas"
    fi
done
# Login serializado por trava atomica (mkdir) com recuperacao de dono morto:
# e o que segura o rate-limit de login por IP com 15-30 contas subindo juntas.
if grep -q 'mkdir "\$LOCKDIR"' "$LIB/sls.sh" && grep -q 'trava_dono_vivo "\$_dono" "\$LOCKDIR" || trava_tomar' "$LIB/sls.sh"; then
    ok "sls.sh: login serializado (trava atomica) com recuperacao de dono morto"
else
    bad "sls.sh: serializacao de login ausente/fragil"
fi
# Sessao reaproveitada (cookie) evita re-autenticar a cada restart -> menos rajada.
if grep -q 'sessao reaproveitada' "$LIB/sls.sh"; then
    ok "sls.sh: reaproveita a sessao do cookie (menos logins em rajada)"
else
    bad "sls.sh: nao reaproveita sessao (rajada de login no restart)"
fi
# Entrada de evento escalonada por conta (nao todas no mesmo segundo).
if grep -q '\$\$ % 10' "$LIB/crono.sh"; then
    ok "crono.sh: entrada de evento escalonada por conta"
else
    bad "crono.sh: entrada de evento sem escalonamento"
fi

printf "\n=== 13. Batalha do Rei: relogio unico de 5s (ataque/erva/pedra/cura) ===\n"
K="$LIB/king.sh"
# Intervalo unico de 5s entre QUALQUER acao.
if grep -q '^  LA=5' "$K"; then
    ok "king.sh: intervalo unico LA=5s entre acoes"
else
    bad "king.sh: LA nao esta em 5s"
fi
# UM GOLPE POR JANELA DE 5s.
#
# O defeito nunca foi o ATKRND existir: era ele ser disparado E DEPOIS o ATK,
# na mesma passagem — dois golpes colados, e o jogo recusa o segundo. O teste
# antigo proibia o ATKRND por completo, que e um atalho para o invariante
# real e barra um uso legitimo.
#
# O ATKRND voltou com outra funcao: trocar de alvo quando o alvo e aliado
# (ver allies.sh). Agora ele esta num ramo ALTERNATIVO ao ATK, entao continua
# saindo um golpe por janela. E isso que passa a ser cobrado: entre os dois
# tem de haver um elif/else. Sem isso, viraram sequencia de novo.
# O `grep -v` descarta COMENTARIOS: o bloco que explica o defeito do link
# vazio cita "$(cat ATK)" no texto, e sem o filtro ele seria tomado pela
# chamada real — que aparece 130 linhas depois.
_kr=$(grep -n 'cat ATKRND' "$K" | grep -v '^[0-9]*:[[:space:]]*#' | head -n1 | cut -d: -f1)
_ka=$(grep -n 'cat ATK)'   "$K" | grep -v '^[0-9]*:[[:space:]]*#' | head -n1 | cut -d: -f1)
if [ -z "$_kr" ]; then
    ok "king.sh: um golpe por janela (sem ATKRND)"
elif [ -n "$_ka" ] && [ "$_kr" -lt "$_ka" ] && \
     sed -n "${_kr},${_ka}p" "$K" | grep -qE '^[[:space:]]*(elif|else)([[:space:]]|$)'; then
    ok "king.sh: ATKRND e ATK em ramos alternativos (um golpe por janela)"
else
    bad "king.sh: ATKRND e ATK na mesma passagem (golpe duplo <4s)"
fi
# Relogio UNICO: ataque, erva, pedra e cura marcam o MESMO _last_act.
_n=$(grep -c '_last_act="\$_agora"' "$K")
if [ "${_n:-0}" -ge 4 ]; then
    ok "king.sh: todas as acoes marcam o mesmo relogio _last_act ($_n pontos)"
else
    bad "king.sh: acoes nao compartilham o relogio unico (_last_act em $_n pontos)"
fi
# So age quando 5s ja passaram (>= LA).
grep -q '_agora - _last_act )) -ge "\$LA"' "$K" \
    && ok "king.sh: so age quando o intervalo de 5s ja venceu" \
    || bad "king.sh: nao respeita o intervalo unico antes de agir"
# Dentro do intervalo apenas espera, sem requisitar.
grep -q 'LA - ( _agora - _last_act )' "$K" \
    && ok "king.sh: dentro dos 5s so espera, sem recarregar a pagina" \
    || bad "king.sh: pode recarregar a pagina dentro do intervalo"
# Erva/pedra SO quando disponiveis (link presente = arquivo nao-vazio).
grep -q 'elif \[ -s GRASS \]' "$K" && ok "king.sh: erva so quando disponivel (-s GRASS)" || bad "king.sh: erva nao checa disponibilidade"
grep -q 'elif \[ -s STONE \]' "$K" && ok "king.sh: pedra so quando disponivel (-s STONE)" || bad "king.sh: pedra nao checa disponibilidade"
# Ordem de prioridade: CURA -> ERVA -> PEDRA -> ATAQUE.
_c=$(grep -n 'PRIORIDADE 1 — CURA'    "$K" | head -n1 | cut -d: -f1)
_s=$(grep -n 'PRIORIDADE 2 — ESQUIVA' "$K" | head -n1 | cut -d: -f1)
_e=$(grep -n 'PRIORIDADE 3 — ERVA'    "$K" | head -n1 | cut -d: -f1)
_p=$(grep -n 'PRIORIDADE 4 — PEDRA'   "$K" | head -n1 | cut -d: -f1)
_t=$(grep -n 'PRIORIDADE 5 — ATAQUE'  "$K" | head -n1 | cut -d: -f1)
if [ -n "$_c" ] && [ -n "$_s" ] && [ -n "$_e" ] && [ -n "$_p" ] && [ -n "$_t" ] && \
   [ "$_c" -lt "$_s" ] && [ "$_s" -lt "$_e" ] && [ "$_e" -lt "$_p" ] && [ "$_p" -lt "$_t" ]; then
    ok "king.sh: ordem cura -> esquiva -> erva -> pedra -> ataque"
else
    bad "king.sh: ordem de prioridade incorreta (cura=$_c esquiva=$_s erva=$_e pedra=$_p atk=$_t)"
fi
# Esquiva SO com o rei fora da arena: o ramo do dodge dentro do laco tem de
# estar preso ao _rei_morto. Enquanto o rei vive, cada janela de 5s vira dano.
_d1=$(grep -n '< DODGE; run_curl_exec' "$K" | head -n1 | cut -d: -f1)
if [ -n "$_d1" ] && sed -n "$((_d1 - 6)),${_d1}p" "$K" | grep -q '\[ "\$_rei_morto" = 1 \]'; then
    ok "king.sh: esquiva so depois da morte do rei (presa ao _rei_morto)"
else
    bad "king.sh: esquiva sem o portao _rei_morto (esquivaria com o rei vivo)"
fi
# Nao restou o spam do sniper.
if grep -q 'FINALIZACAO\|modo espera' "$K"; then
    bad "king.sh: ainda ha modo sniper com spam de ataques"
else
    ok "king.sh: sem spam do sniper (toda acao respeita o intervalo)"
fi

printf "\n=== 14. Vale dos Imortais: nao abandona a luta antes do fim ===\n"
U="$LIB/undying.sh"
# 1) NUNCA busca a home com link vazio: o ataque so dispara com HITMANA cheio.
if grep -q '\[ -s HITMANA \]' "$U"; then
    ok "undying.sh: golpe so com link disponivel (-s HITMANA) — nao baixa a home"
else
    bad "undying.sh: pode disparar golpe com link vazio (baixaria a home e abandonaria)"
fi
# 2) Confirma o fim antes de desistir (nao abandona numa leitura de transicao).
if grep -q 'luta_confirmada_fim' "$U"; then
    ok "undying.sh: confirma o fim da luta antes de encerrar"
else
    bad "undying.sh: encerra a luta numa unica leitura sem out_gate"
fi
# 3) Recupera a pagina no inicio (desvio da arena_fullmana).
_start_fetch=$(grep -n 'run_curl_exec "${URL}/undying" > "$TMP/SRC"' "$U" | head -n1 | cut -d: -f1)
_loop=$(grep -n 'until \[ -s "BREAK_LOOP" \]' "$U" | head -n1 | cut -d: -f1)
if [ -n "$_start_fetch" ] && [ -n "$_loop" ] && [ "$_start_fetch" -lt "$_loop" ]; then
    ok "undying.sh: re-busca /undying no inicio (recupera do desvio da arena)"
else
    bad "undying.sh: nao recupera a pagina de batalha antes do laco"
fi
# 4) Relogio de 5s (nao martela a pagina; nao ataca <4s).
grep -q '_agora - _last_act )) -ge "\$LA"' "$U" \
    && ok "undying.sh: golpe a cada 5s (relogio unico)" \
    || bad "undying.sh: sem intervalo de 5s entre golpes"
grep -q 'LA - ( _agora - _last_act )' "$U" \
    && ok "undying.sh: dentro dos 5s so espera, sem requisitar" \
    || bad "undying.sh: pode martelar a pagina dentro do intervalo"

printf "\n=== 15. Todas as batalhas: reconfirmam o fim antes de abandonar ===\n"
# Um unico read sem o link de luta (transicao, soluco de rede, ou link vazio
# que baixou a home) NAO pode encerrar a luta: cada modulo rele a pagina uma
# vez (trava _reconf contra recursao infinita) e so desiste se confirmar.
for f in clanfight.sh clandmg.sh altars.sh clancoliseum.sh flagfight.sh coliseum.sh king.sh clancommand.sh; do
    if grep -q '_reconf' "$LIB/$f" && grep -q '\[ "${_reconf:-0}" = 0 \]' "$LIB/$f"; then
        ok "$f: reconfirma o fim da luta antes de encerrar"
    else
        bad "$f: encerra a luta numa unica leitura (risco de abandono)"
    fi
done
# undying (Vale) usa a variante com funcao dedicada (luta_confirmada_fim).
grep -q 'luta_confirmada_fim' "$LIB/undying.sh" \
    && ok "undying.sh: reconfirma o fim (luta_confirmada_fim)" \
    || bad "undying.sh: nao reconfirma o fim"
# king (Rei) rele /king, ressuscita (unrip) se tiver morrido e so encerra
# depois da reconfirmacao — nesta ordem.
# (a ressurreicao saiu do king.sh para o ressuscitar(), em info.sh, e passou
# a valer para todo evento — o que se cobra e a CHAMADA, nao o link colado)
grep -q 'ressuscitar king' "$LIB/king.sh" \
    && ok "king.sh: reavalia /king (e ressuscita) antes de encerrar" \
    || bad "king.sh: encerra sem reavaliar"
# Toda gravacao de BREAK_LOOP tem de vir de uma CONFIRMACAO: depois da
# releitura (_reconf), ou da morte vista em tres leituras seguidas (luta_hp).
# A saida por morte com botao na tela (secao 32) fica antes da releitura no
# arquivo, mas ela mesma e confirmada — nenhuma sai numa leitura so.
_kr=$(grep -n '\[ "${_reconf:-0}" = 0 \]' "$LIB/king.sh" | head -n1 | cut -d: -f1)
_kh=$(grep -n 'if luta_hp ' "$LIB/king.sh" | head -n1 | cut -d: -f1)
_ksem=0
for _kb in $(grep -n 'echo 1 > BREAK_LOOP' "$LIB/king.sh" | cut -d: -f1); do
    if [ -n "$_kr" ] && [ "$_kr" -lt "$_kb" ]; then continue; fi
    if [ -n "$_kh" ] && [ "$_kh" -lt "$_kb" ] && [ $((_kb - _kh)) -le 20 ]; then continue; fi
    _ksem=$((_ksem + 1))
done
if [ -n "$_kr" ] && [ "$_ksem" -eq 0 ]; then
    ok "king.sh: so grava BREAK_LOOP depois de confirmar (releitura ou 3 leituras de HP 0)"
else
    bad "king.sh: encerra a luta sem confirmar ($_ksem gravacao(oes))"
fi
unset _kr _kh _kb _ksem

printf "\n=== 16. Atividades fora do cronograma de batalha nao sao ignoradas ===\n"
C="$LIB/crono.sh"
# Cada atividade tem de estar DEFINIDA (funcao existe) e DESPACHADA no crono.sh
# (tarefas_livres no ocioso e/ou start() nos :00/:30). Se qualquer uma sumir do
# despacho, a conta deixa de executa-la — e este teste quebra.
# formato: "funcao:arquivo_de_definicao:chamada_no_crono"
for _row in \
    "arena_duel:arena.sh:arena_duel" \
    "career_func:career.sh:career_func" \
    "campaign_func:campaign.sh:campaign_func" \
    "cave_routine:cave.sh:cave_routine" \
    "check_missions:check.sh:check_missions" \
    "check_rewards:check.sh:check_rewards" \
    "clanDungeon:clanid.sh:clanDungeon" \
    "clan_statue:clanid.sh:clan_statue"; do
    _fn=$(echo "$_row" | cut -d: -f1)
    _mod=$(echo "$_row" | cut -d: -f2)
    _call=$(echo "$_row" | cut -d: -f3)
    _def=0; grep -q "^${_fn}() \?{" "$LIB/$_mod" && _def=1
    _dsp=0; grep -q "[^a-zA-Z_]${_call}\b\|^${_call}\b" "$C" && _dsp=1
    if [ "$_def" = 1 ] && [ "$_dsp" = 1 ]; then
        ok "$_fn: definida em $_mod e despachada no crono.sh"
    else
        bad "$_fn: definida=$_def despachada=$_dsp (atividade pode ser ignorada)"
    fi
done
# Arena/carreira/campanha/caverna/sabio tambem rodam no ocioso (tarefas_livres),
# nao so nos :00/:30. Caverna e campanha pelo relogio do jogo (secao 40).
# Carreira pelo relogio de 8h do jogo (carreira_liberada, 3.9.96).
for _a in caverna sabio; do
    grep -q "ativ_liberada $_a" "$C" \
        && ok "tarefas_livres: $_a roda tambem no ocioso (nao so :00/:30)" \
        || bad "tarefas_livres: $_a nao roda no ocioso"
done
sed -n '/^tarefas_livres() {/,/^}/p' "$C" | grep -A1 'if carreira_liberada; then' | grep -q 'career_func' \
    && ok "tarefas_livres: carreira roda no ocioso, a cada 8h (relogio do jogo)" \
    || bad "tarefas_livres: carreira nao roda no ocioso"
sed -n '/^tarefas_livres() {/,/^}/p' "$C" | grep -A1 'if campanha_liberada; then' | grep -q 'campaign_func' \
    && ok "tarefas_livres: campanha roda tambem no ocioso, pelo relogio do jogo" \
    || bad "tarefas_livres: campanha nao roda no ocioso"
grep -q 'arena_liberada' "$C" && ok "tarefas_livres/start: arena com portao de 30 min" || bad "arena sem portao"
grep -q 'masmorra_liberada' "$C" && ok "tarefas_livres/start: masmorra do cla despachada" || bad "masmorra nao despachada"
# Estatua do cla: gated (config + lider + intervalo de 6h), roda no start().
if grep -q 'clan_statue' "$C" && grep -q 'estatua_liberada' "$LIB/clanid.sh" && grep -q 'clan_lider' "$LIB/clanid.sh"; then
    ok "estatua do cla: despachada no start() e gated (lider + intervalo)"
else
    bad "estatua do cla: despacho/portao ausente"
fi

printf "\n=== 17. Rei: a batalha NAO acaba quando o rei morre ===\n"
# O evento do Rei continua depois que o rei cai: a luta segue entre jogadores.
# Antes o modulo reconhecia a luta APENAS pelo link de esquiva; na virada da
# morte esse link some por um instante e o bot gravava BREAK_LOOP com ataque,
# cura e itens ainda na tela ("Battle over" no meio do evento).

# 17.1 — a luta e reconhecida por QUALQUER acao do rei, nao so pela esquiva.
if grep -q 'acao_disponivel()' "$K" && \
   grep -A3 'acao_disponivel()' "$K" | grep -q '\[ -s KINGATK \]' && \
   grep -A3 'acao_disponivel()' "$K" | grep -q '\[ -s ATK \]' && \
   grep -A3 'acao_disponivel()' "$K" | grep -q '\[ -s HEAL \]'; then
    ok "king.sh: em luta = qualquer acao na pagina (nao so a esquiva)"
else
    bad "king.sh: luta reconhecida so pela esquiva (encerra na morte do rei)"
fi

# 17.2 — nenhuma requisicao com link vazio: "${URL}$(cat X)" com X vazio baixa
# a pagina inicial, e a leitura seguinte daria a luta por encerrada.
_semguarda=0
for _lnk in HEAL DODGE KINGATK ATK; do
    grep -q "\[ -s $_lnk \]" "$K" || _semguarda=$((_semguarda + 1))
done
if [ "$_semguarda" -eq 0 ]; then
    ok "king.sh: nenhuma acao dispara com o link vazio (nao baixa a home)"
else
    bad "king.sh: $_semguarda acao(oes) podem requisitar com link vazio"
fi

# 17.3 — limiares por fase: 38% com o rei vivo, 67% depois que ele morre.
grep -q 'HPER_REI="38"' "$K" && ok "king.sh: rei vivo cura abaixo de 38%" || bad "king.sh: limiar do rei vivo mudou"
grep -q 'HPER_POS="67"' "$K" && ok "king.sh: rei morto usa elixir abaixo de 67%" || bad "king.sh: limiar pos-morte nao e 67%"
check "limiar pos-morte de 1000 de vida = 670" 670 "$(hlhp 1000 67)"

# 17.4 — a cura nao pode ter teto de tempo: o relogio da cura so anda quando a
# conta cura, entao um "-lt 300" proibia o elixir pelo resto da luta.
if grep -q 'last_heal )) -lt 300' "$K"; then
    bad "king.sh: cura ainda tem teto de 300s (proibe o elixir no fim da luta)"
else
    ok "king.sh: cura sem teto de 300s (so a recarga de 90s)"
fi

# 17.5 — a escolha da acao, na mesma ordem do modulo.
#   fase: rei = rei na arena | pos = rei morto
king_acao() { # FASE HP LIMIAR ELIXIR ELIXIR_PRONTO ESQUIVA ESQUIVA_PRONTA
    _kf="$1"; _khp="$2"; _klim="$3"; _kel="$4"; _kelp="$5"; _kes="$6"; _kesp="$7"
    _kbaixa=$(awk -v a="$_khp" -v b="$_klim" 'BEGIN { print (a < b) ? 1 : 0 }')
    if   [ "$_kel" = 1 ] && [ "$_kbaixa" = 1 ] && [ "$_kelp" = 1 ]; then printf 'cura'
    elif [ "$_kf" = pos ] && [ "$_kes" = 1 ] && [ "$_kbaixa" = 1 ] && [ "$_kesp" = 1 ]; then printf 'esquiva'
    else printf 'ataque'
    fi
}
_LIM=$(hlhp 1000 67)   # 670 = 67% de 1000
check "rei morto, vida 600 (<67%) e elixir na pagina -> ELIXIR" \
      cura    "$(king_acao pos 600 "$_LIM" 1 1 1 1)"
check "rei morto, vida 600 e SEM elixir -> ESQUIVA" \
      esquiva "$(king_acao pos 600 "$_LIM" 0 0 1 1)"
check "rei morto, vida 600 e elixir em recarga -> ESQUIVA" \
      esquiva "$(king_acao pos 600 "$_LIM" 1 0 1 1)"
check "rei morto, vida 600, sem elixir e sem esquiva -> ATAQUE" \
      ataque  "$(king_acao pos 600 "$_LIM" 0 0 0 0)"
check "rei morto, vida 900 (>67%) -> ATAQUE" \
      ataque  "$(king_acao pos 900 "$_LIM" 1 1 1 1)"
check "rei morto, vida 600 e esquiva em recarga -> ATAQUE" \
      ataque  "$(king_acao pos 600 "$_LIM" 0 0 1 0)"
_LIMV=$(hlhp 1000 38)  # 380 = 38% de 1000, fase do rei vivo
check "rei vivo, vida 600 -> ATAQUE (nao cura acima de 38%)" \
      ataque  "$(king_acao rei 600 "$_LIMV" 1 1 1 1)"
check "rei vivo, vida 300 e sem elixir -> ATAQUE (nunca esquiva com o rei vivo)" \
      ataque  "$(king_acao rei 300 "$_LIMV" 0 0 1 1)"
check "rei vivo, vida 300 e elixir na pagina -> CURA" \
      cura    "$(king_acao rei 300 "$_LIMV" 1 1 1 1)"

# 17.6 — a fase vira sozinha: sem kingatk na pagina o rei saiu da arena.
if grep -q 'fase_ler()' "$K" && grep -q '_rei_morto=1' "$K" && grep -q '_sem_rei' "$K"; then
    ok "king.sh: detecta a morte do rei pela ausencia do kingatk (com folga)"
else
    bad "king.sh: nao ha deteccao da morte do rei"
fi
# E volta a fase do rei se um novo for coroado.
if grep -q '_rei_morto=0' "$K"; then
    ok "king.sh: novo rei na arena volta a prioridade de dano"
else
    bad "king.sh: fase pos-morte nunca volta atras"
fi

printf "\n=== 18. Rei: recarga propria de cada acao e item pago em ouro ===\n"
# Cada acao tem, alem do intervalo unico de 5s, a sua propria recarga.
grep -q '^  LD=20' "$K" && ok "king.sh: esquiva com recarga de 20s"        || bad "king.sh: recarga da esquiva nao e 20s"
grep -q '^  LC=90' "$K" && ok "king.sh: esmalte/cura com recarga de 90s"   || bad "king.sh: recarga da cura nao e 90s (1min30)"
grep -q '^  LG=60' "$K" && ok "king.sh: erva com recarga de 60s"           || bad "king.sh: recarga da erva nao e 60s"
grep -q '^  LS=60' "$K" && ok "king.sh: pedra com recarga de 60s"          || bad "king.sh: recarga da pedra nao e 60s"
# E as recargas sao mesmo consultadas antes de agir.
grep -q '_agora - _last_grass )) -ge "\$LG"' "$K" \
    && ok "king.sh: erva so depois da recarga vencer"  || bad "king.sh: erva ignora a recarga"
grep -q '_agora - _last_stone )) -ge "\$LS"' "$K" \
    && ok "king.sh: pedra so depois da recarga vencer" || bad "king.sh: pedra ignora a recarga"
grep -q '_agora - _last_dodge )) -ge "\$LD"' "$K" \
    && ok "king.sh: esquiva so depois da recarga vencer" || bad "king.sh: esquiva ignora a recarga"
grep -q '_agora - _last_heal )) -ge "\$LC"' "$K" \
    && ok "king.sh: cura so depois da recarga vencer"  || bad "king.sh: cura ignora a recarga"

# ITEM PAGO EM OURO — teste de verdade, rodando o combate_ler do info.sh
# sobre uma pagina falsa. Erva com preco em ouro no rotulo do botao tem de
# sair de cena; pedra de graca continua; e o saldo de ouro do cabecalho da
# pagina NAO pode derrubar os demais links.
_td="${TMPDIR:-/tmp}/sls_cl_$$"
if mkdir -p "$_td" 2>/dev/null; then
    awk '/^combate_ler\(\)/,/^}$/' "$LIB/info.sh" > "$_td/cl.sh"
    echo 1000 > "$_td/FULL"
    cat > "$_td/pag.html" <<'PAGEOF'
<a href='/king/attack/?r=1'>Atacar</a>
<a href='/king/grass/?r=2'>Erva <img src='/images/icon/gold.png'/> 5</a>
<a href='/king/stone/?r=3'>Pedra</a>
<a href='/king/dodge/?r=4'>Esquiva</a>
<a href='/king/heal/?r=5'>Esmalte</a>
<img src='/images/icon/gold.png' alt='g'/> 3200 hp'/> 900 </span> &nbsp; 4000
PAGEOF
    _got=$(cd "$_td" && . ./cl.sh && combate_ler king 38 5 pag.html >/dev/null 2>&1 && \
           printf '%s|%s|%s|%s|%s' "$(cat GRASS)" "$(cat STONE)" "$(cat ATK)" "$(cat DODGE)" "$(cat HEAL)")
    check "erva paga em ouro sai; pedra, ataque, esquiva e cura ficam" \
          "|/king/stone/?r=3|/king/attack/?r=1|/king/dodge/?r=4|/king/heal/?r=5" "$_got"

    # Pagina com tudo de graca: nada pode ser descartado.
    cat > "$_td/pag2.html" <<'PAGEOF'
<a href='/king/grass/?r=2'>Erva</a>
<a href='/king/stone/?r=3'>Pedra</a>
<img src='/images/icon/gold.png' alt='g'/> 3200 hp'/> 900 </span> &nbsp; 4000
PAGEOF
    _got=$(cd "$_td" && . ./cl.sh && combate_ler king 38 5 pag2.html >/dev/null 2>&1 && \
           printf '%s|%s' "$(cat GRASS)" "$(cat STONE)")
    check "itens de graca sao mantidos (saldo de ouro da pagina nao conta)" \
          "/king/grass/?r=2|/king/stone/?r=3" "$_got"

    # Pedra paga tambem sai.
    cat > "$_td/pag3.html" <<'PAGEOF'
<a href='/king/grass/?r=2'>Erva</a>
<a href='/king/stone/?r=3'>Pedra por 2 ouro</a>
hp'/> 900 </span> &nbsp; 4000
PAGEOF
    _got=$(cd "$_td" && . ./cl.sh && combate_ler king 38 5 pag3.html >/dev/null 2>&1 && \
           printf '%s|%s' "$(cat GRASS)" "$(cat STONE)")
    check "pedra paga em ouro sai, erva de graca fica" "/king/grass/?r=2|" "$_got"
    rm -rf "$_td"
else
    bad "nao foi possivel criar diretorio temporario para testar o combate_ler"
fi

printf "\n=== 19. Cronograma de batalhas: prioridade e dedicacao ===\n"
R="$LIB/run.sh"
# A ordem dos ramos do "case" E a prioridade (o case para no primeiro que casa).
_p1=$(grep -n '^        (10:2\[5-9\]|14:5\[5-9\])'            "$R" | head -n1 | cut -d: -f1)  # Coliseu do Cla
_p2=$(grep -n '^        (10:5\[5-9\]|18:5\[5-9\])'            "$R" | head -n1 | cut -d: -f1)  # Torneio
_p3=$(grep -n '^        (12:2\[5-9\]|16:2\[5-9\]|22:2\[5-9\])' "$R" | head -n1 | cut -d: -f1) # Rei
_p4=$(grep -n '^        (09:5\[5-9\]|15:5\[5-9\]|21:5\[5-9\])' "$R" | head -n1 | cut -d: -f1) # Vale
if [ -n "$_p1" ] && [ -n "$_p2" ] && [ -n "$_p3" ] && [ -n "$_p4" ] && \
   [ "$_p1" -lt "$_p2" ] && [ "$_p2" -lt "$_p3" ] && [ "$_p3" -lt "$_p4" ]; then
    ok "run.sh: prioridade Coliseu do Cla > Torneio > Rei > Vale"
else
    bad "run.sh: prioridade fora de ordem (ccol=$_p1 torneio=$_p2 rei=$_p3 vale=$_p4)"
fi
# Todo evento do cronograma: dedica antes, espera o fim, e so entao varre as
# atividades com o start().
_falta=0
for _l in "$_p1" "$_p2" "$_p3" "$_p4"; do
    _bloco=$(sed -n "${_l},$((_l + 9))p" "$R")
    echo "$_bloco" | grep -q 'evento_dedicar' || _falta=$((_falta + 1))
    echo "$_bloco" | grep -q 'evento_espera'  || _falta=$((_falta + 1))
    echo "$_bloco" | grep -q '^            start$' || _falta=$((_falta + 1))
done
if [ "$_falta" -eq 0 ]; then
    ok "run.sh: aplica/dedica -> espera o fim -> volta ao checkup (start)"
else
    bad "run.sh: $_falta etapa(s) faltando nos ramos do cronograma"
fi
# Eventos de cla: nada de dedicar (e ficar 10 min parado) sem cla.
for _l in "$_p1" "$_p2"; do
    _bloco=$(sed -n "${_l},$((_l + 3))p" "$R")
    echo "$_bloco" | grep -q '\[ -n "\$CLD" \]' || _falta=$((_falta + 1))
done
if [ "$_falta" -eq 0 ]; then
    ok "run.sh: conta sem cla nao fica parada num evento de cla"
else
    bad "run.sh: evento de cla dedica a conta antes de saber se ela participa"
fi
# O modulo que desiste devolve a conta para a rotina.
grep -q 'evento_cancelar()' "$C" \
    && ok "crono.sh: evento_cancelar apaga a dedicacao" \
    || bad "crono.sh: sem evento_cancelar"
grep -q 'evento_cancelar' "$LIB/clancoliseum.sh" \
    && ok "clancoliseum.sh: fora de temporada devolve a conta para a rotina" \
    || bad "clancoliseum.sh: fora de temporada ainda prende a conta"
# A duracao da janela e configuravel e tem padrao documentado.
grep -q 'FUNC_evento_min=10' "$LIB/function.sh" \
    && ok "function.sh: FUNC_evento_min=10 nos padroes" \
    || bad "function.sh: FUNC_evento_min sem padrao"
# A ID do cla e carregada na variavel, nao so no arquivo (senao o primeiro
# ciclo de cada worker pula os eventos de cla).
if grep -q '\[ -n "\$CLD" \] || clan_id' "$R" && grep -q 'read -r CLD < "\$TMP/CLD"' "$LIB/clanid.sh"; then
    ok "run.sh: carrega o CLD do arquivo no inicio do ciclo"
else
    bad "run.sh: CLD pode ficar vazio e derrubar os eventos de cla"
fi

printf "\n=== 20. Nenhuma atividade gasta ouro ===\n"
# Impulso da caverna (custa ouro): removido do CODIGO, nao so barrado.
# Os comentarios podem (e devem) continuar explicando por que ele saiu, entao
# a busca ignora tudo depois do "#".
if sed 's/#.*//' "$LIB/cave.sh" | grep -q 'cave/chance/2'; then
    bad "cave.sh: ainda ha caminho para o impulso pago em ouro"
else
    ok "cave.sh: impulso pago em ouro removido"
fi
# Bencao (100 de ouro): sem compra em lugar nenhum.
if sed 's/#.*//' "$LIB/trade.sh" "$LIB/crono.sh" 2>/dev/null | grep -q 'effshop/blessing'; then
    bad "trade/crono: ainda compram a Bencao"
else
    ok "Bencao: nenhuma compra no fluxo (so a tranca do blessing.sh)"
fi
_r=`( TMP=; URL=https://x; . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/blessing.sh" > /dev/null 2>&1
      curl() { printf 'CURL '; }; run_curl "https://x/effshop/blessing/?r=1"; printf 'rc=%s' "$?" )`
check "blessing.sh: run_curl barra a URL da Bencao antes do curl" "rc=1" "$_r"
# Missao do cla concluida com ouro: removida.
if grep -rq 'cq_forcar_ouro' "$LIB/crono.sh"; then
    bad "crono.sh: ainda chama a conclusao de missao paga em ouro"
else
    ok "crono.sh: conclusao de missao paga em ouro removida"
fi
# Estatua do cla: so o bonus de prata.
# Estatua do cla: os dois bonus do CLA (prata e ouro saem da tesouraria do
# cla); o Bonus Pessoal (privateUpgrade) gasta o ouro da conta e nunca e pedido.
_td20=`mktemp -d`
_r=$(
    TMP="$_td20"; CLD=999; FUNC_clan_statue=y; export TMP CLD
    . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/clanid.sh" > /dev/null 2>&1
    clan_lider() { return 0; }
    _P="<a href='/clan/999/built/?privateUpgrade=true&r=1'>Ativar 48 ouro</a><a href='/clan/999/built/?goldUpgrade=true&r=2'>Ativar 8 ouro</a><a href='/clan/999/built/?silverUpgrade=true&r=3'>Ativar prata</a>"
    : > "$_td20/pedidos"
    fetch_page() { echo "$1" >> "$_td20/pedidos"
                   case "$1" in
                       *Upgrade=true*) : > "$_td20/ativou_$(echo "$1" | sed 's/.*?\([a-z]*\)Upgrade.*/\1/')" ;;
                   esac
                   _pg="$_P"
                   [ -e "$_td20/ativou_silver" ] && _pg=`printf '%s' "$_pg" | sed "s|<a href='/clan/999/built/?silverUpgrade[^<]*</a>||"`
                   [ -e "$_td20/ativou_gold" ]   && _pg=`printf '%s' "$_pg" | sed "s|<a href='/clan/999/built/?goldUpgrade[^<]*</a>||"`
                   printf '%s' "$_pg" > "$2"; }
    clan_statue > "$_td20/saida" 2>&1
    printf 'prata=%s ouro=%s pessoal=%s msg=%s' \
        "`grep -c 'silverUpgrade=true' "$_td20/pedidos"`" "`grep -c 'goldUpgrade=true' "$_td20/pedidos"`" \
        "`grep -c 'privateUpgrade' "$_td20/pedidos"`" "`grep -c 'ativado (tesouraria do cla)' "$_td20/saida"`"
)
check "estatua do cla: ativa prata e ouro da tesouraria, nunca o Bonus Pessoal" "prata=1 ouro=1 pessoal=0 msg=2" "$_r"
grep -q 'privateUpgrade' "$LIB/clanid.sh" && ! grep -q 'for _up in.*privateUpgrade' "$LIB/clanid.sh" \
    && ok "clanid.sh: Bonus Pessoal (ouro da conta) fora da lista de bonus" \
    || bad "clanid.sh: Bonus Pessoal pode ser ativado"
rm -rf "$_td20"; unset _td20 _r
# Chaves de configuracao de gasto de ouro: fora dos padroes.
_ck=0
for _k in FUNC_cave_boost FUNC_use_blessing FUNC_blessing_gold_min FUNC_quest_force_gold FUNC_quest_gold_min; do
    grep -q "^${_k}=" "$LIB/function.sh" && _ck=$((_ck + 1))
done
if [ "$_ck" -eq 0 ]; then
    ok "function.sh: nenhuma chave de gasto de ouro nos padroes"
else
    bad "function.sh: $_ck chave(s) de gasto de ouro ainda nos padroes"
fi
# A troca PRATA -> OURO continua, uma vez por dia.
if grep -q '/trade/exchange/gold/' "$LIB/trade.sh" && grep -q 'last_trade' "$LIB/trade.sh"; then
    ok "trade.sh: troca PRATA -> OURO, uma vez por dia (marcador last_trade)"
else
    bad "trade.sh: troca diaria prata->ouro ausente"
fi
if grep -q 'func_trade' "$C"; then
    ok "crono.sh: a troca diaria esta no ciclo"
else
    bad "crono.sh: a troca diaria nao e chamada"
fi

printf "\n=== 21. Painel na tela do celular (DPI 346-360) ===\n"
P="$LIB/panel.sh"
# LIVE_W: quantas COLUNAS o prefixo do bloco "ao vivo" ocupa em cada modo.
# Sem ele a linha era calculada como se o icone tivesse 1 coluna, e estourava
# 1 (simbolos) a 2 (emoji) colunas em TODA largura de celular.
_lw=$(grep -c '^ *LIVE_W=' "$P")
if [ "${_lw:-0}" -eq 3 ]; then
    ok "panel.sh: LIVE_W definido nos tres modos de icone"
else
    bad "panel.sh: LIVE_W ausente em algum modo ($_lw de 3)"
fi
grep -q 'LIVE_W=3' "$P" && ok "panel.sh: emoji reserva 3 colunas"     || bad "panel.sh: emoji sem reserva de 3 colunas"
grep -q 'LIVE_W=2' "$P" && ok "panel.sh: simbolos reservam 2 colunas" || bad "panel.sh: simbolos sem reserva de 2 colunas"
grep -q 'LIVE_W=0' "$P" && ok "panel.sh: texto reserva 0 coluna"      || bad "panel.sh: texto sem reserva"
# A reserva do HP e MEDIDA, nao chutada em 16 colunas.
grep -q '_sobra=$((LARG - 5 - _lw - ${#_cbt}))' "$P" \
    && ok "panel.sh: bloco ao vivo mede o texto de HP em vez de supor 16" \
    || bad "panel.sh: bloco ao vivo ainda supoe largura fixa de HP"

# Deteccao de densidade e largura fixavel.
grep -q 'painel_dpi()'      "$P" && ok "panel.sh: le a densidade da tela (getprop)" || bad "panel.sh: sem leitura de DPI"
grep -q 'painel_cols_dpi()' "$P" && ok "panel.sh: converte densidade em colunas"    || bad "panel.sh: sem tabela de DPI"
grep -q '.sls/cols'         "$P" && ok "panel.sh: largura fixavel em ~/.sls/cols"   || bad "panel.sh: sem largura fixavel"
grep -q 'painel_calibrar()' "$P" && ok "panel.sh: regua de calibracao"              || bad "panel.sh: sem regua de calibracao"
grep -q '\-cols' "$ROOT/status.sh" && ok "status.sh: aceita ./status.sh -cols"      || bad "status.sh: sem a opcao -cols"

# A TABELA DE DPI, rodando de verdade: 346-360 (Motorola) tem de dar 48.
_td="${TMPDIR:-/tmp}/sls_dpi_$$"
if mkdir -p "$_td/bin" 2>/dev/null; then
    printf '#!/bin/sh\ncase "$1" in *lcd_density) echo "$FAKE_DPI" ;; esac\n' > "$_td/bin/getprop"
    chmod +x "$_td/bin/getprop"
    _dpi_col() {
        FAKE_DPI="$1" PATH="$_td/bin:$PATH" sh -c '. "$1"/panel.sh >/dev/null 2>&1; painel_cols_dpi 80' _ "$LIB" 2>/dev/null
    }
    check "346 dpi (Motorola) -> 48 colunas" 48 "$(_dpi_col 346)"
    check "360 dpi (Motorola) -> 48 colunas" 48 "$(_dpi_col 360)"
    check "440 dpi            -> 42 colunas" 42 "$(_dpi_col 440)"
    check "560 dpi            -> 38 colunas" 38 "$(_dpi_col 560)"
    check "300 dpi            -> 56 colunas" 56 "$(_dpi_col 300)"
    check "240 dpi            -> 64 colunas" 64 "$(_dpi_col 240)"
    rm -rf "$_td"
else
    bad "nao foi possivel testar a tabela de DPI (sem diretorio temporario)"
fi

# O PAINEL DESENHADO DE VERDADE, MEDIDO COLUNA A COLUNA.
#
# Renderiza o painel com contas falsas (uma delas em combate, que e a linha
# mais larga) e confere que NENHUMA linha passa da largura da tela, de 36 a
# 60 colunas. No modo texto cada caractere ocupa uma coluna, entao a conta e
# exata: bytes menos os bytes de continuacao do UTF-8.
_td="${TMPDIR:-/tmp}/sls_pan_$$"
if mkdir -p "$_td/home/.sls/status" 2>/dev/null; then
    printf '1|ContaUma|x\n1|ContaDoisLonga|x\n1|Ze|x\n' > "$_td/accounts.conf"
    for _a in ContaUma ContaDoisLonga Ze; do
        mkdir -p "$_td/home/.sls/BR_$_a"
        echo running > "$_td/home/.sls/status/BR_$_a.status"
        echo "$$"    > "$_td/home/.sls/status/BR_$_a.pid"
        date +%s     > "$_td/home/.sls/BR_$_a/last_ok"
    done
    printf 'ContaUma|65312|470|120|40|3.2M|408,1M|%s\n' "$(date +%s)" > "$_td/home/.sls/BR_ContaUma/stats"
    printf 'ContaDoisLonga|41834|300|95|38|1,2M|22,7M|%s\n' "$(date +%s)" > "$_td/home/.sls/BR_ContaDoisLonga/stats"
    printf 'Ze|900|10|5|7|12|3,4K|%s\n' "$(date +%s)" > "$_td/home/.sls/BR_Ze/stats"
    echo '/king/kingatk/?r=1' > "$_td/home/.sls/BR_ContaUma/pagina"
    echo '/clancoliseum/'     > "$_td/home/.sls/BR_ContaDoisLonga/pagina"
    echo '/'                  > "$_td/home/.sls/BR_Ze/pagina"
    # Conta em combate: HP + old_HP ligam o bloco "ao vivo".
    echo 41834 > "$_td/home/.sls/BR_ContaUma/HP"
    echo 44698 > "$_td/home/.sls/BR_ContaUma/old_HP"
    echo 65312 > "$_td/home/.sls/BR_ContaUma/FULL"
    printf '<div>Bahamut acertar Voce por 2864 critico</div>\n<div>Voce usou Posicao defensiva</div>\n' \
        > "$_td/home/.sls/BR_ContaUma/SRC"

    _ESC=$(printf '\033')
    # NOS TRES MODOS DE ICONE, e nao so em texto.
    #
    # Este teste rodava so com SLS_EMOJI=0. Mas e justamente o modo com
    # icone que corre risco de estourar: emoji ocupa DUAS colunas e varios
    # bytes, entao a conta de largura e outra. Medir so o modo texto e
    # medir o caso que nao tem o problema.
    for _modo in 0 1 2; do
    _estouros=0
    for _c in 36 40 44 46 48 50 52 56 60 90 100; do
        (
            HOME="$_td/home"
            SLSDIR="$ROOT"
            STATUS_DIR="$_td/home/.sls/status"
            ACCOUNTS_FILE="$_td/accounts.conf"
            server_tag()  { case "$1" in 1) echo "BR" ;; esac; }
            clean_field() { printf '%s' "$1" | tr -d '\r'; }
            worker_vivo() { kill -0 "$1"; }
            PANEL_SUPERVISE=0; PANEL_ONCE=1; PANEL_DRAW=1
            SLS_EMOJI="$_modo"; SLS_COLS="$_c"
            export HOME SLSDIR STATUS_DIR ACCOUNTS_FILE PANEL_SUPERVISE PANEL_ONCE PANEL_DRAW SLS_EMOJI SLS_COLS
            . "$LIB/panel.sh"
            painel_loop
        ) > "$_td/saida.txt" 2>/dev/null
        # Tira as cores e mede cada linha em COLUNAS.
        #
        # Colunas, nao bytes: o tr apaga os bytes de continuacao do UTF-8,
        # o que da o numero de CARACTERES. Falta so o que ocupa duas
        # colunas — e neste painel isso e exatamente o emoji, que mora
        # fora do BMP e se escreve em 4 bytes (byte inicial \360-\367).
        # Os simbolos do modo 2 (▲ ♥ ◆ ○ ▸) sao do BMP e ocupam uma.
        # Entao: colunas = caracteres + quantidade de emoji.
        sed "s/${_ESC}\[[0-9;]*m//g" "$_td/saida.txt" > "$_td/limpa.txt"
        while IFS= read -r _ln; do
            _n=$(printf '%s' "$_ln" | LC_ALL=C tr -d '\200-\277' | wc -c)
            _n=$(printf '%s' "$_n" | tr -d ' ')
            _w=$(printf '%s' "$_ln" | LC_ALL=C tr -dc '\360-\367' | wc -c)
            _w=$(printf '%s' "$_w" | tr -d ' ')
            _n=$(( ${_n:-0} + ${_w:-0} ))
            [ "$_n" -gt "$_c" ] && _estouros=$((_estouros + 1))
        done < "$_td/limpa.txt"
        # Celular (56) e PC (100): titulo de uma linha, sem autor, e a conta
        # numa linha da tabela (HP, energia, nivel, ouro, prata) em qualquer modo.
        case "$_c" in 56|100)
            grep -q 'Painel SLS · BR · [0-9][0-9]:' "$_td/limpa.txt" \
                && ! grep -q 'Mod Author' "$_td/limpa.txt" \
                && grep -q 'CONTA .*HP .*ENERGIA .*NV .*OURO .*PRATA' "$_td/limpa.txt" \
                && grep -Eq 'Ze +(│|\|)? *900 +(│|\|)? *5 +(│|\|)? *7 +(│|\|)? *12 +(│|\|)? *3,4K' "$_td/limpa.txt" \
                || { _estouros=$((_estouros + 1)); printf '  [INFO] modo %s, %s colunas: titulo ou numeros fora do formato\n' "$_modo" "$_c"; }
        esac
    done
    if [ "$_estouros" -eq 0 ]; then
        ok "painel (modo $_modo) cabe de 36 a 100 colunas, titulo e numeros no formato"
    else
        bad "painel (modo $_modo) estourou a largura em $_estouros linha(s)"
    fi
    done
    unset _modo _w
    rm -rf "$_td"
else
    bad "nao foi possivel renderizar o painel para medir a largura"
fi

printf "\n=== 22. Estrutura do repositorio ===\n"
# A raiz tem SO os comandos do usuario; o motor mora em lib/.
_raiz=$(ls "$ROOT"/*.sh 2>/dev/null | wc -l)
if [ "$_raiz" -eq 5 ]; then
    ok "raiz com 5 comandos (play, setup, status, stop, uninstall)"
else
    bad "raiz com $_raiz scripts (esperado 5: play, setup, status, stop, uninstall)"
fi
for _c in play.sh setup.sh status.sh stop.sh uninstall.sh; do
    [ -f "$ROOT/$_c" ] || bad "comando ausente na raiz: $_c"
done
[ -f "$ROOT/play.sh" ] && [ -f "$ROOT/stop.sh" ] && ok "comandos principais no lugar" || bad "comandos principais fora do lugar"
[ -d "$LIB" ] && ok "lib/ existe" || bad "lib/ nao existe"

# Todo modulo do carregador do sls.sh tem de existir em lib/ — se um sumir,
# o bot sobe sem aquela atividade e ninguem percebe ate o evento passar.
_falta=0
for _m in $(sed -n '/^for _lib in/,/^do$/p' "$LIB/sls.sh" | tr ' ' '\n' | grep '\.sh$'); do
    [ -f "$LIB/$_m" ] || { _falta=$((_falta + 1)); bad "carregador aponta para modulo inexistente: $_m"; }
done
[ "$_falta" -eq 0 ] && ok "todos os modulos do carregador existem em lib/"

# E o contrario: modulo em lib/ que ninguem carrega e peso morto.
_orfao=0
_lista=$(sed -n '/^for _lib in/,/^do$/p' "$LIB/sls.sh" | tr ' ' '\n' | grep '\.sh$')
for _f in "$LIB"/*.sh; do
    _b=$(basename "$_f")
    # Estes sao carregados por caminho proprio, nao pelo laco (o batalhas.sh
    # e executado pelo status.sh -batalhas; o rede.sh pelo -rede e pelo painel).
    case "$_b" in worker.sh|sls.sh|panel.sh|info.sh|session_check.sh|contas.sh|batalhas.sh|rede.sh) continue ;; esac
    echo "$_lista" | grep -qx "$_b" || { _orfao=$((_orfao + 1)); bad "modulo em lib/ que ninguem carrega: $_b"; }
done
[ "$_orfao" -eq 0 ] && ok "nenhum modulo orfao em lib/"

# Os caminhos do motor passam pelo LIBDIR, nao mais pela raiz.
grep -q 'LIBDIR="$SLSDIR/lib"' "$ROOT/play.sh"   && ok "play.sh define LIBDIR"   || bad "play.sh sem LIBDIR"
grep -q 'LIBDIR="$SLSDIR/lib"' "$ROOT/status.sh" && ok "status.sh define LIBDIR" || bad "status.sh sem LIBDIR"
grep -q 'LIBDIR="$SLSDIR/lib"' "$ROOT/setup.sh"  && ok "setup.sh define LIBDIR"  || bad "setup.sh sem LIBDIR"
grep -q 'LIBDIR="$SLSDIR/lib"' "$ROOT/stop.sh"   && ok "stop.sh define LIBDIR"   || bad "stop.sh sem LIBDIR"
# worker.sh vive em lib/ e sobe um nivel para achar a raiz.
if grep -q 'SLSDIR=$(cd "$LIBDIR/.." && pwd)' "$LIB/worker.sh"; then
    ok "lib/worker.sh calcula a raiz a partir de lib/"
else
    bad "lib/worker.sh nao acha a raiz do bot"
fi
# Nenhum script procura modulo do motor na raiz.
# O "grep -vq" ignora COMENTARIOS: depois do grep -rn a linha comeca com
# "arquivo:numero:", entao o padrao tem de casar o # logo apos os dois pontos.
if grep -rn '\$SLSDIR/\(sls\|worker\|panel\|info\|crono\|run\|king\)\.sh' "$ROOT"/*.sh "$LIB"/*.sh 2>/dev/null | grep -vq ':[[:space:]]*#'; then
    bad "ainda ha caminho de motor apontando para a raiz"
else
    ok "nenhum caminho de motor aponta para a raiz"
fi

# NA RAIZ, SO O QUE PRECISA ESTAR NA RAIZ: os comandos do usuario, o que o
# GitHub so reconhece ali (README, LICENSE), o que o git so aplica aos
# arquivos da raiz estando nela (.gitattributes com o eol=lf dos scripts,
# .gitignore) e o CLAUDE.md, que o Claude Code so le na raiz. Qualquer outra
# coisa vai para lib/.
_sobra=""
for _e in "$ROOT"/* "$ROOT"/.[!.]*; do
    [ -e "$_e" ] || continue
    case "$(basename "$_e")" in
        .git|.gitattributes|.gitignore|LICENSE|README.md|CLAUDE.md|lib|tests) ;;
        play.sh|setup.sh|status.sh|stop.sh|uninstall.sh) ;;
        *) _sobra="$_sobra $(basename "$_e")" ;;
    esac
done
[ -z "$_sobra" ] && ok "raiz so com o necessario" \
                 || bad "sobra na raiz (mova para lib/):$_sobra"
unset _sobra _e

printf "\n=== 23. User-Agent: um por conta, estavel ===\n"
R="$LIB/requeriments.sh"
grep -q 'read -r vUserAgent < "\$TMP/ua"' "$R" \
    && ok "random_ua reusa o agente ja sorteado da conta" \
    || bad "random_ua sorteia de novo a cada arranque"
grep -q 'srand(s \* 7919' "$R" \
    && ok "semente com PID (awk que semeia so pelo relogio nao repete)" \
    || bad "semente sem PID: contas no mesmo segundo pegam o mesmo agente"
grep -q "grep -c ''" "$R" \
    && ok "conta as linhas com grep -c (pega a ultima sem quebra de linha)" \
    || bad "contagem de linhas pode ignorar o ultimo agente"

# Funcional: sorteia, grava, e repete o MESMO nas chamadas seguintes.
_td="${TMPDIR:-/tmp}/sls_ua_$$"
if mkdir -p "$_td" 2>/dev/null && cp "$LIB/userAgent.txt" "$_td/" 2>/dev/null; then
    _a=$(TMP="$_td" sh -c '. "$1"; random_ua; printf "%s" "$vUserAgent"' _ "$R" 2>/dev/null)
    _b=$(TMP="$_td" sh -c '. "$1"; random_ua; printf "%s" "$vUserAgent"' _ "$R" 2>/dev/null)
    check "o agente nao muda entre execucoes da conta" "$_a" "$_b"
    if [ -n "$_a" ] && grep -qxF "$_a" "$LIB/userAgent.txt"; then
        ok "o agente sorteado saiu da lista"
    else
        bad "agente sorteado nao esta na lista"
    fi
    [ -s "$_td/ua" ] && ok "o agente fica gravado na conta (\$TMP/ua)" || bad "o agente nao foi gravado"
    # Sem lista: nao inventa agente (o sls.sh tem o padrao de reserva).
    rm -f "$_td/ua" "$_td/userAgent.txt"
    _c=$(TMP="$_td" sh -c '. "$1"; random_ua; printf "%s" "${vUserAgent:-VAZIO}"' _ "$R" 2>/dev/null)
    check "sem lista, random_ua nao define agente" "VAZIO" "$_c"
    rm -rf "$_td"
else
    bad "nao foi possivel testar o sorteio de User-Agent"
fi

printf "\n=== 24. ALIADOS: A LISTA PRECISA SER PREENCHIDA E RESPEITADA ===\n"
# O conf_allies pergunta o modo pelo teclado, e o worker sobe com stdin em
# /dev/null: a funcao nunca rodava fora do menu. As listas ficavam vazias e as
# cinco batalhas de cla testavam uma lista sem ninguem dentro.
_al="$LIB/allies.sh"
if [ -f "$_al" ]; then
    grep -q '^allies_refresh() {' "$_al" \
        && ok "existe allies_refresh (monta a lista sem perguntar nada)" \
        || bad "sem allies_refresh: as listas continuam vazias"
    if awk '/^allies_refresh\(\) \{/,/^}/' "$_al" | grep -q 'read '; then
        bad "allies_refresh pede entrada — trava o worker sem terminal"
    else
        ok "allies_refresh nao pede entrada"
    fi
    grep -q 'ativ_liberada aliados' "$LIB/crono.sh" \
        && ok "a lista e atualizada pelo ciclo ocioso" \
        || bad "ninguem chama allies_refresh"

    # A verificacao antiga era `grep -q -o "$(cat CLAN)"` com o padrao SEM
    # aspas: alvo vazio virava padrao vazio, que casa QUALQUER linha.
    if grep -rn 'grep -q -o "\$(cat CLAN)"' "$LIB"/*.sh | grep -qv allies.sh; then
        bad "ainda ha teste de aliado com padrao sem aspas"
    else
        ok "nenhum modulo testa aliado com padrao sem aspas"
    fi
    # A consulta a lista mora no aliado_ler (allies.sh), com a lista de cla
    # nas batalhas de cla e a do Rei no Rei; a troca sai pelo troca_aliado.
    for _m in altars clancoliseum clandmg clanfight flagfight clancommand; do
        grep -q '^ *aliado_ler cla$' "$LIB/$_m.sh" && grep -q 'troca_aliado "\$_atk0"' "$LIB/$_m.sh" \
            && ok "$_m protege aliado (lista do cla)" || bad "$_m nao protege aliado"
    done
    grep -q '^ *aliado_ler$' "$LIB/king.sh" && grep -q 'troca_aliado "\$_agora"' "$LIB/king.sh" \
        && ok "king.sh troca de alvo quando o alvo e aliado" \
        || bad "king.sh bate em aliado"

    # Comportamento, nao so presenca.
    _td=$(mktemp -d)
    eval "$(sed -n '/^alvo_aliado() {/,/^}/p' "$_al")"
    TMP="$_td"
    printf 'Bahamut\n' > "$_td/allies.txt"; printf 'Guerreiros\n' > "$_td/callies.txt"
    printf 'Bahamut\n' > "$_td/U"
    alvo_aliado "$_td/U" && ok "aliado reconhecido" || bad "aliado nao reconhecido"
    printf 'Inimigo\n' > "$_td/U"
    alvo_aliado "$_td/U" && bad "estranho virou aliado" || ok "estranho nao e aliado"
    : > "$_td/U"
    alvo_aliado "$_td/U" && bad "alvo vazio virou aliado" || ok "alvo vazio nao e aliado"
    : > "$_td/allies.txt"; printf 'Qualquer\n' > "$_td/U"
    alvo_aliado "$_td/U" && bad "lista vazia poupou todo mundo" \
        || ok "lista vazia nao poupa ninguem"
    printf 'Anaxx\n' > "$_td/allies.txt"; printf 'Ana\n' > "$_td/U"
    alvo_aliado "$_td/U" && bad "casou nome parcial" || ok "compara linha inteira"
    rm -rf "$_td"; unset TMP
else
    bad "allies.sh nao encontrado"
fi

printf "\n=== 25. NENHUMA CONTA ABANDONA A BATALHA VIVA ===\n"
# Cada conta e um processo. O que tirava UMA conta da luta — leitura ruim,
# sessao caida, SIGKILL e relancamento — virava fuga de verdade porque o
# descansar() confirmava o "Fuja da batalha" a cada chamada. Aqui roda o
# codigo de verdade (info.sh + crono.sh) sobre paginas falsas, sem rede.
_bt=$(mktemp -d)
_CAB="<img src='/images/icon/health.png' alt='hp'/> <span class='white'>6531</span> <img src='/images/icon/level.png' alt=''/> 40"
_CAB0="<img src='/images/icon/health.png' alt='hp'/> <span class='dred'>0</span> <img src='/images/icon/level.png' alt=''/> 40"
pg() { printf '%s\n' "$2" > "$_bt/$1"; }
: > "$_bt/vazia"
pg cortada     "<html><head><title>Tit"
pg login       "<form action='/?sign_in=1'><input name='pass' type='password'/></form>"
pg luta        "$_CAB <a href='/clanfight/dodge/?r=11'>d</a> <a href='/clanfight/attack/?r=12'>a</a>"
pg semesquiva  "$_CAB <a href='/king/attack/?r=13'>a</a> <a href='/king/heal/?r=14'>h</a>"
pg morto       "$_CAB0 <a href='/'>home</a>"
pg morto_botao "$_CAB0 <a href='/altars/attack/?r=15'>a</a>"
pg unrip       "$_CAB <a href='/king/unrip/?r=16'>reviver</a>"
pg portao      "$_CAB <a href='/undying/?out_gate'>sair</a>"
pg morto_port  "$_CAB0 <a href='/undying/?out_gate'>sair</a>"
pg recompensa  "$_CAB <a href='/clanfight/?close=reward'>ok</a>"
pg endfight    "$_CAB <a href='/coliseum/?end_fight=true'>ok</a>"
pg fora        "$_CAB <a href='/arena/'>arena</a> <a href='/clanfight/'>torneio</a>"
pg fuja        "$_CAB Fuja da batalha? <a href='/?out_gate_confirm=true'>sim</a>"
pg home        "$_CAB <a href='/arena/'>arena</a>"

# --- 25.1 a pagina e classificada pelo que o JOGO diz ------------------------
(
    . "$LIB/info.sh"
    for _c in "vazia clanfight invalida" "cortada clanfight invalida" \
              "login clanfight deslogado" "luta clanfight luta" \
              "semesquiva king luta" "morto clanfight morto" \
              "morto_botao altars luta" "unrip king morto" \
              "portao undying luta" "morto_port undying morto" \
              "recompensa clanfight fim" "endfight coliseum fim" \
              "fora clanfight fora"; do
        set -- $_c
        _e=`estado_luta "$_bt/$1" "$2"`
        [ "$_e" = "$3" ] && echo "PASS estado: $1 -> $3" || echo "FALHA estado: $1 -> $_e (esperado $3)"
    done
) > "$_bt/r1" 2>&1
while read -r _st _msg; do
    case "$_st" in PASS) ok "$_msg" ;; *) bad "$_msg" ;; esac
done < "$_bt/r1"

# --- 25.2 so a declaracao do jogo encerra a luta -----------------------------
_r=$( TMP="$_bt/acc1"; mkdir -p "$TMP"; . "$LIB/info.sh"
      LUTA_FORA_MAX=0; luta_inicio clanfight
      luta_acabou "$_bt/vazia" clanfight   && printf 'SAIU-vazia '
      luta_acabou "$_bt/cortada" clanfight && printf 'SAIU-cortada '
      luta_acabou "$_bt/luta" clanfight    && printf 'SAIU-luta '
      batalha_pendente && printf 'pendente' )
check "leitura ruim e luta em curso nao encerram; a batalha segue pendente" "pendente" "$_r"

_r=$( TMP="$_bt/acc2"; mkdir -p "$TMP"; . "$LIB/info.sh"
      luta_inicio clanfight
      luta_acabou "$_bt/morto" clanfight && printf 'saiu '
      batalha_pendente || printf 'limpa' )
check "morte declarada encerra e limpa a batalha" "saiu limpa" "$_r"

_r=$( TMP="$_bt/acc3"; mkdir -p "$TMP"; . "$LIB/info.sh"
      luta_inicio clanfight
      luta_acabou "$_bt/recompensa" clanfight && printf '%s' "$LUTA_MOTIVO" )
case "$_r" in *fim*) ok "fim declarado (recompensa) encerra" ;;
              *)     bad "fim declarado nao encerrou ('$_r')" ;; esac

_r=$( TMP="$_bt/acc4"; mkdir -p "$TMP"; . "$LIB/info.sh"
      LUTA_FORA_MAX=90; luta_inicio clanfight
      luta_acabou "$_bt/fora" clanfight > /dev/null && printf 'SAIU'; printf 'ok' )
check "uma pagina sem luta nao basta (90s seguidos)" "ok" "$_r"
_r=$( TMP="$_bt/acc5"; mkdir -p "$TMP"; . "$LIB/info.sh"
      LUTA_FORA_MAX=90; luta_inicio clanfight; _lt_fora_desde=$(( `date +%s` - 100 ))
      luta_acabou "$_bt/luta" clanfight > /dev/null
      luta_acabou "$_bt/fora" clanfight > /dev/null && printf 'SAIU'; printf 'ok' )
check "luta na tela zera a contagem do 'sem luta'" "ok" "$_r"

# Sessao caida: reconecta respeitando o MESMO portao do descansar
# (last_reconn), e sem tentativa possivel sai do LACO — nunca da batalha, que
# fica anotada para a retomada. Antes: ate 30 min relendo a pagina de login.
_r=$( TMP="$_bt/acc6"; mkdir -p "$TMP"; . "$LIB/info.sh"
      login_logoff() { echo x >> "$_bt/relog"; }
      luta_inicio clanfight
      luta_acabou "$_bt/login" clanfight > /dev/null && printf 'SAIU1 '
      luta_acabou "$_bt/login" clanfight > /dev/null && printf 'SAIU2 '
      batalha_pendente && printf 'pendente '
      printf 'caiu=%s relog=%s' "$LUTA_SESSAO_CAIU" "`wc -l < "$_bt/relog" | tr -d ' '`" )
check "sessao caida: 1 reconexao, depois sai do laco com a batalha pendente" \
      "SAIU2 pendente caiu=1 relog=1" "$_r"
_r=$( TMP="$_bt/acc6b"; mkdir -p "$TMP"; . "$LIB/info.sh"
      login_logoff() { echo x >> "$_bt/relog2"; }
      date +%s > "$TMP/last_reconn"          # o descansar acabou de reconectar
      luta_inicio clanfight
      luta_acabou "$_bt/login" clanfight > /dev/null && printf 'SAIU '
      printf 'relog=%s' "`cat "$_bt/relog2" 2>/dev/null | wc -l | tr -d ' '`" )
check "sessao caida: nao reconecta em rajada com o descansar" "SAIU relog=0" "$_r"

# --- 25.3 a batalha fica em disco, por conta ---------------------------------
_r=$( TMP="$_bt/acc7"; mkdir -p "$TMP"; . "$LIB/info.sh"
      batalha_marcar king; read -r _s _t0 < "$TMP/batalha"
      sleep 1; batalha_marcar king; read -r _s _t1 < "$TMP/batalha"
      [ "$_t0" = "$_t1" ] && printf 'preserva '
      printf 'king %s\n' $(( `date +%s` - 41 * 60 )) > "$TMP/batalha"
      batalha_pendente || printf 'vence' )
check "mesma batalha preserva a inscricao; vence apos LUTA_TETO_MIN + 10 min" "preserva vence" "$_r"
_r=$( TMP="$_bt/acc8"; mkdir -p "$TMP" "$_bt/acc9"; . "$LIB/info.sh"
      batalha_marcar king
      TMP="$_bt/acc9"; batalha_pendente && printf 'vazou' || printf 'isolada' )
check "a batalha de uma conta nao aparece em outra" "isolada" "$_r"

# --- 25.4 o descansar nunca foge de batalha pendente -------------------------
# fetch_page falso: grava o pedido e devolve a pagina que o cenario manda.
descanso_cenario() {  # $1 conta  $2 pagina da Home  $3 = "limpa" se a luta termina
    (
        TMP="$_bt/$1"; mkdir -p "$TMP"; URL="http://jogo"
        . "$LIB/info.sh"; . "$LIB/crono.sh"
        : > "$TMP/pedidos"
        fetch_page() { echo "$1" >> "$TMP/pedidos"
                       case "$1" in /) cp "$_bt/$HOME_PG" "${2:-$TMP/SRC}" ;;
                                    *) cp "$_bt/home" "${2:-$TMP/SRC}" ;; esac; }
        run_curl() { :; }
        login_logoff() { return 0; }
        king_fight() { echo "LUTOU" >> "$TMP/pedidos"
                       case "$FIM_LUTA" in
                           limpa)  batalha_limpar ;;
                           sessao) LUTA_SESSAO_CAIU=1 ;;
                       esac; }
        HOME_PG="$2"; FIM_LUTA="$3"
        batalha_marcar king
        descansar > /dev/null 2>&1
        [ -n "$4" ] && descansar > /dev/null 2>&1
        batalha_pendente && echo "PENDENTE" >> "$TMP/pedidos"
        tr '\n' ' ' < "$TMP/pedidos"
    )
}
# A retomada rele a pagina do evento (/king) e so entao luta. Com a sessao
# caida na luta, a batalha continua pendente e a fuga NAO e confirmada.
_r=$(descanso_cenario acc10 fuja sessao)
case "$_r" in
    *out_gate_confirm*)       bad "descansar confirmou a fuga com a batalha pendente ($_r)" ;;
    "/king LUTOU "*PENDENTE*) ok "descansar volta para a luta e nao foge enquanto ela esta pendente" ;;
    *)                        bad "descansar nao retomou a batalha pendente ($_r)" ;;
esac
# Luta que volta sem o jogo declarar o fim e sem queda de sessao: UMA
# tentativa de retomada por batalha anotada, nao uma a cada descanso.
_r=$(descanso_cenario acc13 home "" dois)
case "$_r" in
    *LUTOU*LUTOU*) bad "descansar retoma a mesma batalha a cada chamada ($_r)" ;;
    "/king LUTOU "*) ok "retomada: uma tentativa por batalha anotada" ;;
    *)               bad "retomada nao aconteceu ($_r)" ;;
esac
_r=$(descanso_cenario acc11 fuja limpa)
case "$_r" in
    "/king LUTOU "*out_gate_confirm*) ok "com o fim declarado pelo jogo, a saida e confirmada" ;;
    *)                                bad "fim declarado e saida nao confirmada ($_r)" ;;
esac
_r=$(descanso_cenario acc12 home limpa)
case "$_r" in
    *out_gate_confirm*) bad "descansar confirmou fuga sem o jogo pedir ($_r)" ;;
    *)                  ok "sem 'Fuja da batalha' na Home, nada de out_gate_confirm" ;;
esac

# --- 25.5 todas as batalhas passam pela mesma porta --------------------------
for _p in "king.sh king" "undying.sh undying" "altars.sh altars" \
          "clanfight.sh clanfight" "clandmg.sh clandmgfight" \
          "clancoliseum.sh clancoliseum" "flagfight.sh flagfight" \
          "coliseum.sh coliseum" "clancommand.sh clancommand"; do
    set -- $_p
    if grep -q "luta_inicio $2" "$LIB/$1" && grep -q "luta_acabou " "$LIB/$1"; then
        ok "$1: sai da luta so pelo luta_acabou"
    else
        bad "$1: decide o fim da luta por conta propria"
    fi
    grep -q "batalha_marcar $2" "$LIB/$1" \
        && ok "$1: anota a batalha na inscricao" \
        || bad "$1: worker relancado nao sabe que estava na batalha"
    if grep -qE '(FIGHT|COL)_BREAK=\$\(\(.*\+ 600\)\)' "$LIB/$1"; then
        bad "$1: teto fixo de 10 minutos voltou"
    else
        ok "$1: sem teto fixo de 10 minutos"
    fi
done
for _p in "altars.sh HEAL DODGE ATKRND ATK" "clanfight.sh HEAL DODGE ATKRND ATK" \
          "clandmg.sh HEAL DODGE ATKRND ATK" "clancoliseum.sh HEAL DODGE ATKRND ATK" \
          "flagfight.sh SHIELD DODGE ATKRND ATK"; do
    set -- $_p; _m="$1"; shift; _sem=""
    for _l in "$@"; do grep -q "\[ -s $_l \]" "$LIB/$_m" || _sem="$_sem $_l"; done
    [ -z "$_sem" ] && ok "$_m: nenhuma acao com link vazio" \
                   || bad "$_m: pode pedir a pagina inicial com link vazio:$_sem"
done
# Com a luta continuando ate o jogo declarar o fim, o ramo "sem acao" tem de
# RELER a pagina quando nao ha link de ataque — senao o laco dormia sobre uma
# pagina sem acao ate o teto (achado na simulacao desta correcao).
for _m in altars.sh clanfight.sh clandmg.sh clancoliseum.sh flagfight.sh clancommand.sh; do
    grep -q '\[ "\$_grey" = 1 \] || \[ ! -s ATK \]' "$LIB/$_m" \
        && ok "$_m: sem link de ataque, rele a pagina do evento" \
        || bad "$_m: sem link de ataque o laco dorme sem reler"
done
grep -q '\[ "\$_grey" = 1 \] || \[ -z "\$ATK" \]' "$LIB/coliseum.sh" \
    && ok "coliseum.sh: sem link de ataque, rele a pagina do evento" \
    || bad "coliseum.sh: sem link de ataque o laco dorme sem reler"
_sem=""
for _l in HEAL DODGE ATKRND ATK; do
    grep -q "\[ -n \"\$$_l\" \]" "$LIB/coliseum.sh" || _sem="$_sem $_l"
done
[ -z "$_sem" ] && ok "coliseum.sh: nenhuma acao com link vazio" \
               || bad "coliseum.sh: pode pedir a pagina inicial com link vazio:$_sem"

# O out_gate_confirm (confirmacao de fuga) so e pedido num lugar: o descansar,
# depois de conferir que nao ha batalha pendente.
_ogc=$(grep -n 'out_gate_confirm=true' "$LIB"/*.sh | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
       | grep -E 'fetch_page|run_curl' | wc -l | tr -d ' ')
check "um unico pedido de out_gate_confirm no codigo" 1 "$_ogc"
_bp=$(awk '/^descansar\(\)/,/^}/' "$LIB/crono.sh" | grep -n 'batalha_pendente' | head -n1 | cut -d: -f1)
_og=$(awk '/^descansar\(\)/,/^}/' "$LIB/crono.sh" | grep -n 'fetch_page "/?out_gate_confirm=true"' | head -n1 | cut -d: -f1)
if [ -n "$_bp" ] && [ -n "$_og" ] && [ "$_bp" -lt "$_og" ]; then
    ok "descansar: confere a batalha pendente antes de confirmar a saida"
else
    bad "descansar: confirma a saida sem conferir a batalha pendente"
fi
# O worker relancado volta para a batalha antes de qualquer outra atividade.
_rt=$(grep -n '^    \(if \)\{0,1\}batalha_retomar' "$LIB/run.sh" | head -n1 | cut -d: -f1)
_cs=$(grep -n 'case "$_HH:$_MM" in' "$LIB/run.sh" | head -n1 | cut -d: -f1)
if [ -n "$_rt" ] && [ -n "$_cs" ] && [ "$_rt" -lt "$_cs" ]; then
    ok "run.sh: batalha pendente e retomada antes do cronograma"
else
    bad "run.sh: worker relancado cai na rotina com a batalha em andamento"
fi
# O horario do cronograma e o do relogio da volta: acertado antes dele.
_rs=$(grep -n '^ *relogio_sync$' "$LIB/run.sh" | head -n1 | cut -d: -f1)
[ -n "$_rs" ] && [ -n "$_cs" ] && [ "$_rs" -lt "$_cs" ] \
    && ok "run.sh: relogio da volta acertado antes do cronograma" \
    || bad "run.sh: cronograma sem o relogio da volta"
rm -rf "$_bt"
unset _bt _CAB _CAB0 _r _p _m _l _sem _ogc _bp _og _rt _cs _st _msg
unset -f pg descanso_cenario
# =============================================================================
printf "\n=== 26. pagina de missoes do cla: uma leitura, nao 23 ===\n"
# =============================================================================
#
# Tres caminhos consultam /clan/<CLD>/quest/ — as cq_* (clanquest.sh), o
# checkQuest e o clanQuests (clanid.sh) — e o cq_antes sozinho pedia duas
# vezes seguidas, porque cq_concluir e cq_tomar chamam cada um o cq_pagina.
# Medido num ciclo de tarefas_livres: 23 leituras da MESMA pagina, de 41
# requisicoes no total.
#
# A pagina so muda quando alguem clica nela. O cq_pagina guarda a leitura e
# todo clique chama cq_invalidar. Estes testes cobrem as duas metades: nao
# repetir sem motivo, e NUNCA servir pagina velha depois de um clique.

_cq=$(mktemp -d)
(
    export TMP="$_cq" URL=site CLD=777
    cd "$ROOT/lib" 2>/dev/null || exit 1
    curl() { return 0; }
    for _f in info.sh session_check.sh requeriments.sh clanid.sh crono.sh \
              clanquest.sh function.sh; do
        [ -f "./$_f" ] && . "./$_f" 2>/dev/null
    done
    clan_id() { :; }
    run_curl() { :; }; run_curl_exec() { :; }
    N=0; ESTADO=antes
    fetch_page() {
        case "$1" in
            */quest/)
                N=$((N + 1))
                if [ "$ESTADO" = antes ]; then
                    printf "<a href='/clan/777/quest/take/3/?r=1'>x</a>\n" > "${2:-$TMP/SRC}"
                else
                    printf "<html>sem links</html>\n" > "${2:-$TMP/SRC}"
                fi ;;
            */take/*) ESTADO=depois; printf 'ok\n' > "${2:-$TMP/SRC}" ;;
            *)        printf 'ok\n' > "${2:-$TMP/SRC}" ;;
        esac
        return 0
    }

    # 1) duas leituras seguidas, sem clique: uma so ida a rede
    N=0; _CQ_TS=0; rm -f "$TMP/CQUEST"
    cq_pagina >/dev/null 2>&1; cq_pagina >/dev/null 2>&1
    printf 'A%s\n' "$N" > "$TMP/r1"

    # 2) leitura, clique, leitura: duas idas, e a segunda traz pagina NOVA
    N=0; _CQ_TS=0; ESTADO=antes; rm -f "$TMP/CQUEST"
    cq_tomar arena >/dev/null 2>&1
    cq_pagina >/dev/null 2>&1
    printf 'B%s\n' "$N" > "$TMP/r2"
    grep -q 'sem links' "$TMP/CQUEST" && printf 'NOVA\n' > "$TMP/r3" \
                                      || printf 'VELHA\n' > "$TMP/r3"

    # 3) leitura antiga demais expira sozinha
    N=0; _CQ_TS=$(( `date +%s` - 100 )); ESTADO=antes
    printf "<a href='/clan/777/quest/take/3/?r=1'>x</a>\n" > "$TMP/CQUEST"
    cq_pagina >/dev/null 2>&1
    printf 'C%s\n' "$N" > "$TMP/r4"
) 2>/dev/null

[ "`cat "$_cq/r1" 2>/dev/null`" = "A1" ] \
    && ok "missoes do cla: leitura repetida e reaproveitada" \
    || bad "missoes do cla: pede a mesma pagina de novo sem motivo (`cat "$_cq/r1" 2>/dev/null`)"
[ "`cat "$_cq/r2" 2>/dev/null`" = "B2" ] \
    && ok "missoes do cla: o clique obriga nova leitura" \
    || bad "missoes do cla: o clique nao invalidou (`cat "$_cq/r2" 2>/dev/null`)"
[ "`cat "$_cq/r3" 2>/dev/null`" = "NOVA" ] \
    && ok "missoes do cla: apos o clique a pagina e a nova" \
    || bad "missoes do cla: serviu pagina VELHA depois do clique"
[ "`cat "$_cq/r4" 2>/dev/null`" = "C1" ] \
    && ok "missoes do cla: leitura velha expira sozinha" \
    || bad "missoes do cla: leitura antiga nao expira (`cat "$_cq/r4" 2>/dev/null`)"
rm -rf "$_cq"

# Os tres caminhos tem de ler o MESMO arquivo; um deles com fetch proprio
# traz de volta as 23 leituras.
grep -q 'TMP/SRC' "$ROOT/lib/clanid.sh" && \
  grep -n 'quest/take\|quest/end' "$ROOT/lib/clanid.sh" | grep -q 'TMP/SRC' \
    && bad "checkQuest/clanQuests voltaram a ler o \$TMP/SRC" \
    || ok "checkQuest e clanQuests leem a pagina compartilhada"

# =============================================================================
printf "\n=== 27. contadores de laco nao vazam ===\n"
# =============================================================================
#
# O check.sh usava um `i` solto. Sem escopo em sh, o valor sobrava no
# ambiente do worker (medido: check_missions deixava 17, check_rewards 12) e o
# func_cat usa ${i:-60} como tempo de espera do ciclo ocioso.
_lk=$(mktemp -d)
(
    export TMP="$_lk" URL=site CLD=1
    cd "$ROOT/lib" 2>/dev/null || exit 1
    curl() { return 0; }
    for _f in info.sh session_check.sh requeriments.sh crono.sh check.sh function.sh; do
        [ -f "./$_f" ] && . "./$_f" 2>/dev/null
    done
    fetch_page() { : > "${2:-$TMP/SRC}"; return 0; }
    run_curl() { :; }; run_curl_exec() { :; }
    unset i
    check_missions >/dev/null 2>&1
    check_rewards  >/dev/null 2>&1
    printf '%s\n' "${i:-limpo}" > "$TMP/i"
) 2>/dev/null
[ "`cat "$_lk/i" 2>/dev/null`" = "limpo" ] \
    && ok "check.sh nao deixa contador no ambiente" \
    || bad "check.sh deixou i=`cat "$_lk/i" 2>/dev/null` — a espera ociosa herda esse valor"
rm -rf "$_lk"

# =============================================================================
printf "\n=== 28. pagina do cla e ID do cla: uma leitura por passagem ===\n"
# =============================================================================
#
# Dois pontos liam /clan/<CLD>/ no MESMO arquivo $TMP/CLANPG — o clan_lider
# (dentro do clan_statue) e o clanDungeon, quando procura a porta da masmorra
# pelo proprio cla. E o clan_id era chamado duas vezes por start(): uma pelo
# login_logoff e outra pelo proprio start(), sempre indo a rede.

_cp=$(mktemp -d)
(
    export TMP="$_cp" URL=site CLD=777
    cd "$ROOT/lib" 2>/dev/null || exit 1
    curl() { return 0; }
    for _f in info.sh session_check.sh requeriments.sh clanid.sh crono.sh \
              clanquest.sh function.sh; do
        [ -f "./$_f" ] && . "./$_f" 2>/dev/null
    done
    N=0
    fetch_page() {
        case "$1" in
            */clan/777/) N=$((N + 1))
                printf "<a href='/clan/777/12/adm/'>a</a><a href='/clandungeon2/'>p</a>\n" \
                    > "${2:-$TMP/SRC}" ;;
            *) printf 'x\n' > "${2:-$TMP/SRC}" ;;
        esac
        return 0
    }
    run_curl() { printf 'x\n'; }; run_curl_exec() { printf 'x\n'; }

    # lider reconhecido, e a segunda leitura seguida nao vai a rede
    N=0; _CLAN_TS=0; rm -f "$TMP/CLANPG"
    clan_lider >/dev/null 2>&1 && printf 'LIDER\n' > "$TMP/a" || printf 'NAO\n' > "$TMP/a"
    clan_lider >/dev/null 2>&1
    printf '%s\n' "$N" > "$TMP/b"

    # a porta da masmorra continua sendo achada na pagina guardada
    grep -o -E "/[a-z0-9/]{0,20}dungeon[a-z0-9/]{0,20}" "$TMP/CLANPG" 2>/dev/null \
        | grep -v -E "image|/js/|/css/" | sed -n 1p > "$TMP/c"

    # leitura antiga expira sozinha
    N=0; _CLAN_TS=$(( `date +%s` - 100 ))
    clan_pagina >/dev/null 2>&1
    printf '%s\n' "$N" > "$TMP/d"
) 2>/dev/null

[ "`cat "$_cp/a" 2>/dev/null`" = "LIDER" ] \
    && ok "cla: o lider continua sendo reconhecido" \
    || bad "cla: deixou de reconhecer o lider"
[ "`cat "$_cp/b" 2>/dev/null`" = "1" ] \
    && ok "cla: leitura repetida da pagina e reaproveitada" \
    || bad "cla: pede a pagina do cla de novo sem motivo (`cat "$_cp/b" 2>/dev/null`)"
[ "`cat "$_cp/c" 2>/dev/null`" = "/clandungeon2/" ] \
    && ok "cla: a porta da masmorra ainda e encontrada" \
    || bad "cla: a porta da masmorra sumiu da pagina guardada"
[ "`cat "$_cp/d" 2>/dev/null`" = "1" ] \
    && ok "cla: leitura velha da pagina expira" \
    || bad "cla: leitura antiga nao expira"
rm -rf "$_cp"

# O start() nao pode chamar o clan_id sem guarda: o login_logoff, logo acima,
# ja o executa, e o clan_id vai a rede sempre.
# So DENTRO do start(): o tarefas_livres ja tinha a guarda, entao procurar no
# arquivo inteiro passaria mesmo com o start() errado.
if sed -n '/^start() {/,/^}/p' "$ROOT/lib/crono.sh" \
     | grep -qE '\[ -n "\$CLD" \] \|\| clan_id'; then
    ok "start: clan_id so quando o ID ainda nao e conhecido"
else
    bad "start: clan_id chamado sem guarda — leitura de /clan duplicada"
fi



# =============================================================================
printf "\n=== 29. icones do painel sem seletor de variacao ===\n"
# =============================================================================
#
# Um emoji pode ser escrito de duas formas: codepoint unico do bloco de
# pictogramas (🧡 = U+1F9E1), ou simbolo antigo mais o seletor U+FE0F
# (❤️ = U+2764 U+FE0F). A segunda depende de o terminal entender o seletor —
# e na tela do usuario ela NAO funciona: o "⚔️" do cabecalho aparecia como
# caixa enquanto 🧡 🔷 🪙 🥈, todos de codepoint unico, desenhavam certo.
#
# Dai a regra: nenhum icone do painel usa seletor de variacao.
#
# Os bytes do seletor (EF B8 8F) saem do printf em OCTAL: o $'\xef...' e do
# bash, e no dash virava outro texto — o teste passava sem testar nada, e o
# "⚔️" do Torneio de Equipe chegou a main assim (3.9.67 a 3.9.100).
_fe0f=`printf '\357\270\217'`
# A busca acha o seletor NESTE shell? Sem isso o teste volta a passar vazio.
if printf 'x%sy\n' "$_fe0f" | LC_ALL=C grep -q "$_fe0f"; then
    ok "painel: a busca do seletor funciona neste shell"
else
    bad "painel: a busca do seletor nao acha nem o proprio seletor"
fi
if LC_ALL=C grep -q "$_fe0f" "$ROOT/lib/panel.sh"; then
    _vs=`LC_ALL=C grep -n "$_fe0f" "$ROOT/lib/panel.sh" | grep -vE '^[0-9]+:[[:space:]]*#' | head -n3`
    if [ -n "$_vs" ]; then
        bad "painel: ha icone com seletor de variacao ($_vs)"
    else
        ok "painel: seletor so aparece em comentario"
    fi
    unset _vs
else
    ok "painel: nenhum seletor de variacao"
fi
unset _fe0f

# Os simbolos de estado de cada modo tem os mesmos bytes: e o que deixa o
# nome da conta na mesma coluna em qualquer estado.
for _modo in 1 2; do
    _r=$(
        SLS_EMOJI="$_modo" HOME=/nao/existe
        export SLS_EMOJI HOME
        . "$ROOT/lib/panel.sh" > /dev/null 2>&1
        for _s in "$S_ON" "$S_WAIT" "$S_ERR" "$S_OFF" "$S_UNK" "$S_PAUSE"; do
            printf '%s ' "`printf '%s' "$_s" | wc -c | tr -d ' '`"
        done
    )
    case "$_modo" in 1) _esp="4 4 4 4 4 4 " ;; 2) _esp="3 3 3 3 3 3 " ;; esac
    check "painel (modo $_modo): simbolos de estado com a mesma largura" "$_esp" "$_r"
done
unset _modo _r _esp

# =============================================================================
printf "\n=== 30. modo de icone escolhido pelo aparelho ===\n"
# =============================================================================
#
# O relato: no WSL os emoji aparecem; no Moto E22 e na faixa de aparelhos em
# volta dele, NAO aparece nenhum. Falta a fonte de emoji, e quando ela falta
# nao adianta trocar um emoji por outro — faltam todos.
#
# Como o alvo deste bot e o Termux, o padrao passa a seguir o aparelho:
# Android cai em simbolo (♥ ◆ ▲ ¤ ○, que toda fonte monoespacada tem), o
# resto continua em emoji. A escolha manual sempre ganha do padrao.
_modo_em() {
    (
        HOME="$1"; PREFIX="$2"; unset SLS_EMOJI
        export HOME PREFIX
        . "$ROOT/lib/panel.sh" > /dev/null 2>&1
        printf '%s:%s' "$SLS_EMOJI" "$SLS_EMOJI_FONTE"
    )
}
_td2=`mktemp -d`
mkdir -p "$_td2/.sls"

[ "`_modo_em "$_td2" ''`" = "1:automatico" ] \
    && ok "sem Android e sem escolha: emoji" \
    || bad "sem Android deveria dar emoji (deu `_modo_em "$_td2" ''`)"

[ "`_modo_em "$_td2" /data/data/com.termux/files/usr`" = "2:automatico" ] \
    && ok "Termux sem escolha: simbolos, nao emoji" \
    || bad "Termux deveria cair em simbolos (deu `_modo_em "$_td2" /data/data/com.termux/files/usr`)"

# A escolha gravada ganha do aparelho: quem instalou fonte de emoji no
# Termux pede emoji e recebe emoji.
echo 1 > "$_td2/.sls/emoji"
[ "`_modo_em "$_td2" /data/data/com.termux/files/usr`" = "1:arquivo" ] \
    && ok "escolha gravada ganha do padrao do aparelho" \
    || bad "~/.sls/emoji deveria vencer o padrao (deu `_modo_em "$_td2" /data/data/com.termux/files/usr`)"

# Lixo no arquivo nao vira um modo qualquer no chute.
printf 'talvez\n' > "$_td2/.sls/emoji"
[ "`_modo_em "$_td2" /data/data/com.termux/files/usr`" = "2:automatico" ] \
    && ok "arquivo com lixo cai no automatico, nao num modo qualquer" \
    || bad "lixo em ~/.sls/emoji deveria cair no automatico (deu `_modo_em "$_td2" /data/data/com.termux/files/usr`)"

rm -rf "$_td2"
unset _td2

# O -icones tem de desenhar os TRES conjuntos e devolver o que estava valendo.
_ico=`HOME=/nao/existe "$ROOT/status.sh" -icones 2>/dev/null`
_l=`printf '%s\n' "$_ico" | grep -c '^  [012]  '`
[ "$_l" = 3 ] \
    && ok "status.sh -icones desenha os tres conjuntos" \
    || bad "status.sh -icones desenhou $_l conjunto(s), esperado 3"
printf '%s\n' "$_ico" | grep -q 'echo 2 > ~/.sls/emoji' \
    && ok "status.sh -icones ensina como fixar a escolha" \
    || bad "status.sh -icones nao diz como fixar a escolha"
unset _ico _l

printf "\n=== 31. NENHUMA FUNCAO PRENDE A CONTA ===\n"
# Lacos que so terminavam quando o jogo cooperasse. Cada um aqui prendia o
# worker: a conta parava de jogar e perdia os eventos seguintes.
_pz=$(mktemp -d)

# --- 31.1 espera de inicio: nunca a do relogio da HORA SEGUINTE --------------
# Relogio falso: date +%M%S devolve o valor do arquivo; cada sleep avanca 3s.
espera_sim() {  # $1 relogio MMSS inicial  $2 DE  $3 ATE  -> sonos dados
    (
        . "$LIB/info.sh"
        echo "$1" > "$_pz/rel"; echo 0 > "$_pz/sonos"
        date() { case "$1" in +%M%S) cat "$_pz/rel" ;; *) command date "$@" ;; esac; }
        sleep() { _s=`cat "$_pz/sonos"`; echo $((_s + 1)) > "$_pz/sonos"
                  _r=`cat "$_pz/rel"`
                  while :; do case "$_r" in 0?*) _r=${_r#0} ;; *) break ;; esac; done
                  printf '%04d\n' $((_r + 3)) > "$_pz/rel"
                  [ "`cat "$_pz/sonos"`" -gt 1500 ] && exit 9; }
        espera_janela "$2" "$3"
        cat "$_pz/sonos"
    ) 2>/dev/null
}
_s=$(espera_sim 5920 5500 5930)
[ "${_s:-99}" -le 4 ] && ok "espera_janela: dentro da janela espera ate :59:30 ($_s sonos)" \
                      || bad "espera_janela: espera errada dentro da janela ($_s)"
_s=$(espera_sim 0005 5500 5930)
check "espera_janela: chegou depois de :59:59 -> segue na hora (antes: ~1h)" 0 "$_s"
_s=$(espera_sim 1502 1000 1430)
check "espera_janela: Bandeiras chegando em :15:02 -> segue na hora" 0 "$_s"
for _p in "flagfight.sh 1000 1400" "clanfight.sh 5500 5900" "clandmg.sh 2500 2900"; do
    set -- $_p
    if grep -q "espera_janela $2 .janela_alvo $3." "$LIB/$1" && \
       ! grep -q 'while (case `date +%M:%S`' "$LIB/$1"; then
        ok "$1: espera de inicio limitada a janela"
    else
        bad "$1: espera de inicio ainda pode prender ate a hora seguinte"
    fi
done

# --- 31.2 Liga e missao do Coliseu: lacos com teto ---------------------------
if sed -n '/^league_play()/,/^}/p' "$LIB/league.sh" | grep -q '_lg_voltas" -lt 40' && \
   sed -n '/^league_play()/,/^}/p' "$LIB/league.sh" | grep -q '_lg_fim'; then
    ok "league.sh: laco das lutas com teto (40 voltas / 5 min)"
else
    bad "league.sh: laco das lutas pode girar para sempre"
fi
if grep -q '_q11_n" -lt 6' "$LIB/coliseum.sh" && grep -q '_q11_fim' "$LIB/coliseum.sh"; then
    ok "coliseum.sh: laco da missao 11 com teto (6 tentativas / 20 min)"
else
    bad "coliseum.sh: laco da missao 11 pode girar para sempre"
fi

# --- 31.3 rede fora: a luta respira entre releituras -------------------------
_r=$( TMP="$_pz"; . "$LIB/info.sh"; : > "$_pz/vazia"; N=0
      sleep() { N=$((N + 1)); }
      luta_inicio clanfight
      for _n in 1 2 3 4 5; do luta_acabou "$_pz/vazia" clanfight; done
      printf 'sonos=%s' "$N" )
check "luta_acabou: 3a leitura invalida seguida em diante espera" "sonos=3" "$_r"

# --- 31.4 retomada do coliseu nao abre luta nova -----------------------------
_r=$( TMP="$_pz/col"; mkdir -p "$TMP"; URL=http://jogo
      . "$LIB/info.sh"; . "$LIB/crono.sh"
      printf '%s\n' "<img src='/images/icon/level.png'/> <a href='/coliseum/enterFight/?r=9'>entrar</a>" > "$_pz/saguao"
      fetch_page() { cp "$_pz/saguao" "${2:-$TMP/SRC}"; }
      run_curl() { :; }
      coliseum_fight() { echo ENTROU; }
      batalha_marcar coliseum
      batalha_retomar > /dev/null
      coliseum_fight() { :; }
      batalha_pendente && printf 'pendente' || printf 'limpa' )
check "retomada do coliseu sem luta na tela: nao inscreve, apaga a anotacao" "limpa" "$_r"

# --- 31.5 missoes do cla: pagina guardada so sem requisicao no meio ----------
_r=$( TMP="$_pz/cq"; mkdir -p "$TMP"; export TMP URL=site CLD=777
      . "$LIB/info.sh"; . "$LIB/clanquest.sh"
      clan_id() { :; }; N=0
      fetch_page() { N=$((N + 1)); printf "<a href='/clan/777/quest/take/3/?r=$N'>x</a>\n" > "${2:-$TMP/SRC}"; }
      _CQ_TS=0; cq_pagina; cq_pagina                 # seguidas: 1 leitura
      printf '%s' "/arena/attack/1/?r=5" > "$TMP/.ult_req"   # a arena saiu no meio
      cq_pagina                                      # tem de ler de novo
      printf 'N=%s' "$N" )
check "missoes do cla: le de novo se outra requisicao saiu no meio" "N=2" "$_r"
grep -q '/\.ult_req"' "$LIB/info.sh" \
    && ok "motor: grava a ultima requisicao em \$TMP/.ult_req" \
    || bad "motor: sem registro da ultima requisicao"

rm -rf "$_pz"; unset _pz _s _r _p
unset -f espera_sim

printf "\n=== 32. MORTE COM A LUTA AINDA NA TELA ===\n"
# Medido nos logs (Rei, 11/09 16:25): depois da morte a pagina manteve os
# botoes e o HP lido foi 0 em 321 leituras seguidas — 27 minutos "lutando"
# morto ate o teto de 30 min. O HP 0 com botao passa a valer como morte com
# tres leituras seguidas, e so depois de a conta ter tido vida na luta.
_r=$( . "$LIB/info.sh"; luta_inicio
      for _v in 0 0 0 0; do luta_hp "$_v" && printf 'M'; done; printf '|'
      luta_hp 4738; luta_hp 4363
      luta_hp 0 && printf 'M1'; luta_hp "" && printf 'M2'; luta_hp 0 && printf 'M3'
      printf '|'; luta_inicio; luta_hp 900; luta_hp 0; luta_hp 0; luta_hp 12
      luta_hp 0 && printf 'X'; luta_hp 0 && printf 'X'; printf 'ok' )
check "luta_hp: sem vida antes nao mata; 3 zeros seguidos matam; vida volta zera" "|M3|ok" "$_r"
_r=$( . "$LIB/info.sh"; luta_inicio; luta_hp "4363
500"; luta_hp " 0"; luta_hp "0
9"; luta_hp 0 && printf 'morto' )
check "luta_hp: le so o primeiro numero (linha dupla, espaco)" "morto" "$_r"

for _p in "king.sh _hpat" "altars.sh _hp" "clanfight.sh _hp" "clandmg.sh _hp" \
          "clancoliseum.sh _hp" "flagfight.sh _hp" "coliseum.sh USH" \
          "clancommand.sh _hpat"; do
    set -- $_p
    grep -q "luta_hp \"[^\"]*$2" "$LIB/$1" \
        && ok "$1: reconhece a morte com botao na tela" \
        || bad "$1: HP 0 com botao na tela segue ate o teto"
done
# No Rei a trava da ressurreicao so solta com vida na tela: se soltasse a
# cada leitura com botao, HP 0 + botao viraria um unrip a cada tres leituras.
# O destravamento passou para dentro do luta_hp — o unico ponto que ja
# distingue vida de zero — e com isso vale para todo evento, nao so o Rei.
# Aqui se cobra o EFEITO, rodando: zero na tela nao destrava, vida destrava.
_r=$(
    . "$LIB/info.sh" > /dev/null 2>&1
    luta_inicio king > /dev/null 2>&1
    _lt_teve_vida=1; _reviveu=1          # como se tivesse acabado de ressuscitar
    luta_hp 0 > /dev/null 2>&1
    [ "${_reviveu:-0}" = 1 ] || { printf 'zero-destravou'; exit; }
    luta_hp 4210 > /dev/null 2>&1
    [ "${_reviveu:-0}" = 0 ] || { printf 'vida-nao-destravou'; exit; }
    printf 'ok'
)
[ "$_r" = ok ] \
    && ok "king.sh: unrip no maximo uma vez por morte" \
    || bad "trava do unrip: $_r"
unset _r
# Coliseu: o USH aceita 1 a 9 digitos (3.9.108; eram 6), a primeira
# ocorrencia (HP entre 1 e 9 e vida, nao morte; 123456 nao vira 12345).
grep -q '\[0-9\]{1,9}. "\$src_ram" | head -n 1' "$LIB/coliseum.sh" \
    && ok "coliseum.sh: HP de 1 digito nao passa por morte" \
    || bad "coliseum.sh: HP entre 1 e 9 seria lido como morte"
# Espera sem luta nas Bandeiras / Coliseu do Cla: sem batalha a retomar.
for _m in flagfight.sh clancoliseum.sh; do
    sed -n '/_start()/,/^}/p' "$LIB/$_m" | grep -q 'batalha_limpar' \
        && ok "$_m: espera sem luta apaga a anotacao (sem retomada a toa)" \
        || bad "$_m: espera sem luta deixa retomada de 90s a toa"
done
unset _r _p _m

# =============================================================================
printf "\n=== 33. morrer nao e sair do evento ===\n"
# =============================================================================
#
# Relato: "varias contas abandonaram o altar". O luta_hp (secao 32) passou a
# reconhecer a morte com a luta na tela — mas reconhecer a morte e ENCERRAR a
# luta ainda deixa a conta fora do evento. O unrip existia so no king.sh, em
# duas copias; virou ressuscitar() no info.sh e agora todo evento tenta
# voltar antes de encerrar.
for _m in altars:altars flagfight:flagfight clanfight:clanfight \
          clandmg:clandmgfight clancoliseum:clancoliseum coliseum:coliseum \
          king:king; do
    _arq="${_m%%:*}"; _sec="${_m##*:}"
    grep -q "ressuscitar $_sec" "$LIB/$_arq.sh" \
        && ok "$_arq.sh: tenta voltar antes de encerrar (ressuscitar $_sec)" \
        || bad "$_arq.sh: morre e sai do evento sem tentar o unrip"
done
# O Vale nao ressuscita (regra do dono do bot, 16/09).
grep -q "ressuscitar" "$LIB/undying.sh" \
    && bad "undying.sh: o Vale nao deve ressuscitar" \
    || ok "undying.sh: sem ressurreicao no Vale"

# Uma implementacao, nao duas: o king.sh nao pode ter a copia colada de volta.
[ "`grep -c '/king/unrip/' "$LIB/king.sh"`" = 0 ] \
    && ok "king.sh: sem copia local do unrip" \
    || bad "king.sh: voltou a ter o unrip colado (duas implementacoes)"

_td3=`mktemp -d`
# A ressurreicao rodando: pede a URL certa, rele a pagina e trava contra laco.
_r=$(
    TMP="$_td3"; URL="http://jogo"; export TMP URL
    . "$LIB/info.sh" > /dev/null 2>&1
    run_curl_exec() { printf '%s\n' "$1" >> "$_td3/pedidos"; cat "$_td3/resposta"; }
    time_exit() { wait "$!" 2>/dev/null; }  # como o real: espera a requisicao
    printf '%s' "<img src='icon/level.png'><a href=/altars/dodge/?r=8>esq</a>" > "$_td3/resposta"
    printf '%s' "<img src='icon/level.png'><a href=/altars/unrip/?r=777>rev</a>" > "$_td3/pag"
    : > "$_td3/pedidos"
    luta_inicio altars > /dev/null 2>&1
    ressuscitar altars "$_td3/pag" > /dev/null 2>&1 || { printf 'nao-ressuscitou'; exit; }
    grep -q '/altars/unrip/?r=777' "$_td3/pedidos" || { printf 'url-errada'; exit; }
    grep -q '/dodge/' "$_td3/pag" || { printf 'nao-releu-a-pagina'; exit; }
    printf '%s' "<a href=/altars/unrip/?r=778>rev</a>" > "$_td3/pag"
    ressuscitar altars "$_td3/pag" > /dev/null 2>&1 && { printf 'laco-de-unrip'; exit; }
    printf 'ok'
)
[ "$_r" = ok ] \
    && ok "ressuscitar: pede o unrip, rele a pagina e trava contra laco" \
    || bad "ressuscitar: $_r"

# CONTROLE: luta viva nao pode custar requisicao nenhuma nem virar morte.
_r=$(
    TMP="$_td3"; URL="http://jogo"; export TMP URL
    . "$LIB/info.sh" > /dev/null 2>&1
    run_curl_exec() { printf '%s\n' "$1" >> "$_td3/pedidos"; }
    time_exit() { wait "$!" 2>/dev/null; }
    printf '%s' "<a href=/altars/dodge/?r=8>esq</a><a href=/altars/atack/?r=9>b</a>" > "$_td3/pag"
    : > "$_td3/pedidos"
    luta_inicio altars > /dev/null 2>&1
    ressuscitar altars "$_td3/pag" > /dev/null 2>&1 && { printf 'ressuscitou-vivo'; exit; }
    printf '%s' "`wc -l < "$_td3/pedidos" | tr -d ' '`"
)
[ "$_r" = 0 ] \
    && ok "ressuscitar: luta viva nao gera requisicao" \
    || bad "ressuscitar: luta viva custou $_r"

rm -rf "$_td3"; unset _td3 _r _m _arq _sec

# flagfight julgava o alvo pela pagina do ALTARS (src.html) em dois dos
# quatro testes de invulnerabilidade; os outros dois liam o proprio arquivo.
grep -q 'src\.html' "$LIB/flagfight.sh" \
    && bad "flagfight.sh: le src.html (arquivo do altars) em vez do proprio" \
    || ok "flagfight.sh: le a propria pagina, nao a do altars"

printf "\n=== 34. prazo de 17s nas paginas de luta ===\n"
# =============================================================================
#
# Coliseu de 12/09: tres contas com 107 requisicoes seguidas sem resposta,
# esperando 45s cada (o "time_exit 17" dos modulos nao corta desde que o prazo
# passou para o curl). Pagina de evento de luta agora corta em 17s; login,
# /train e o resto seguem em 45s.
_td4=`mktemp -d`
_prazo() { # argumentos do run_curl -> valor do --max-time que o curl recebeu
    (
        TMP="$_td4"; URL="https://jogo.net"; export TMP URL
        [ -n "$_TM" ] && SLS_MAXTIME="$_TM"
        [ -n "$_TLM" ] && SLS_LUTA_MAXTIME="$_TLM"
        . "$LIB/info.sh" > /dev/null 2>&1
        curl() {
            while [ $# -gt 0 ]; do
                [ "$1" = "--max-time" ] && { printf '%s' "$2"; return 0; }
                shift
            done
        }
        run_curl "$@"
    )
}
check "prazo: /king/attack (acao do Rei)"        17 "`_prazo 'https://jogo.net/king/attack/?r=1'`"
check "prazo: /coliseum (releitura da luta)"     17 "`_prazo 'https://jogo.net/coliseum'`"
check "prazo: /clandmgfight/dodge"               17 "`_prazo 'https://jogo.net/clandmgfight/dodge/?r=2'`"
check "prazo: /undying/hit"                      17 "`_prazo 'https://jogo.net/undying/hit/?r=3'`"
check "prazo: /altars/?close=reward"             17 "`_prazo 'https://jogo.net/altars/?close=reward'`"
check "prazo: POST com a URL depois do -d"       17 "`_prazo -d 'x=1' 'https://jogo.net/flagfight/'`"
check "prazo: /train continua 45s"               45 "`_prazo 'https://jogo.net/train'`"
check "prazo: login continua 45s"                45 "`_prazo 'https://jogo.net/?sign_in=1'`"
check "prazo: pagina inicial continua 45s"       45 "`_prazo 'https://jogo.net'`"
check "prazo: /kingdom nao e o Rei"              45 "`_prazo 'https://jogo.net/kingdom/'`"
check "prazo: outro host com /king"              45 "`_prazo 'https://outro.net/king/'`"
check "prazo: SLS_MAXTIME explicito vale por cima" 30 "`_TM=30 _prazo 'https://jogo.net/king/'`"
check "prazo: SLS_LUTA_MAXTIME ajusta a luta"    12 "`_TLM=12 _prazo 'https://jogo.net/king/'`"
check "prazo: SLS_LUTA_MAXTIME invalido cai em 45" 45 "`_TLM=abc _prazo 'https://jogo.net/king/'`"
unset -f _prazo

# O luta_acabou nao encerra na primeira pagina sem luta; encerra aos 90s.
_r=$(
    TMP="$_td4/b"; URL="https://jogo.net"; export TMP URL
    mkdir -p "$TMP"
    . "$LIB/info.sh" > /dev/null 2>&1
    _T=5000
    date() { printf '%s\n' "$_T"; }
    printf "%s" "<img src='/images/icon/level.png'>Batalha finalizada! primeira" > "$TMP/p"
    luta_inicio altars > /dev/null 2>&1
    luta_acabou "$TMP/p" altars && { printf 'saiu-na-hora'; exit; }
    _T=5095
    printf "%s" "<img src='/images/icon/level.png'>ultima" > "$TMP/p"
    luta_acabou "$TMP/p" altars || { printf 'nao-saiu-aos-90s'; exit; }
    printf 'ok'
)
[ "$_r" = ok ] \
    && ok "luta_acabou: espera os 90s antes de dar a luta por encerrada" \
    || bad "luta_acabou: $_r"

rm -rf "$_td4"; unset _td4 _r _m _arq _sec

printf "\n=== 35. sem botao de luta e sem ressurreicao: a luta acabou ===\n"
# =============================================================================
#
# Regra do dono: "se nao tem mais o botao de atacar ou nao ressuscitou, a luta
# pode ser dada como encerrada". Os 90s sem sinal ficam so para o inicio (a
# luta demora a aparecer); depois de a conta ter lutado, 15s sem nenhum botao
# de acao, sem out_gate e sem unrip encerram. 140 de 184 saidas nos logs de
# 12/09 esperaram os 90s inteiros.
_td5=`mktemp -d`
printf '%s' "<img src='/images/icon/level.png'>pagina do evento sem nada" > "$_td5/fora"
printf '%s' "<img src='/images/icon/level.png'><a href='/clanfight/dodge/?r=1'>e</a>" > "$_td5/luta"
: > "$_td5/vazia"
_fim() { # roteiro de leituras "estado@segundo ..." -> SAIU@segundo:motivo, ou FICOU
    (
        TMP="$_td5/c"; mkdir -p "$TMP"; export TMP
        . "$LIB/info.sh" > /dev/null 2>&1
        [ -n "$_FL" ] && LUTA_FORA_LUTOU="$_FL"
        _T=1000
        date() { printf '%s\n' "$_T"; }
        luta_inicio clanfight
        for _p in "$@"; do
            case "$_p" in
                hp=*) _T=${_p#*@}; _v=${_p%@*}; luta_hp "${_v#hp=}" > /dev/null; continue ;;
                inicio@*) _T=${_p#*@}; luta_inicio clanfight; continue ;;
            esac
            _T=${_p#*@}
            if luta_acabou "$_td5/${_p%@*}" clanfight > /dev/null; then
                printf 'SAIU@%s:%s' "$_T" "$LUTA_MOTIVO"; exit
            fi
        done
        printf 'FICOU'
    )
}
_r=`_fim hp=5000@1000 fora@1001 fora@1010 fora@1016`
case "$_r" in "SAIU@1016:sem botao"*) ok "lutou: 15s sem botao (contados da 1a pagina sem botao) encerram" ;;
              *) bad "lutou: 15s sem botao deviam encerrar ($_r)" ;; esac
check "lutou: 14s sem botao ainda nao encerram" FICOU "`_fim hp=5000@1000 fora@1001 fora@1015`"
_r=`_fim luta@1000 fora@1001 fora@1016`
case "$_r" in "SAIU@1016:sem botao"*) ok "luta vista pelo luta_acabou tambem conta como ter lutado" ;;
              *) bad "luta vista pelo luta_acabou nao contou ($_r)" ;; esac
check "nao lutou: 15s nao bastam (atraso do inicio)" FICOU "`_fim fora@1000 fora@1020 fora@1089`"
_r=`_fim fora@1000 fora@1090`
case "$_r" in "SAIU@1090:90s"*) ok "nao lutou: continua valendo os 90s" ;;
              *) bad "nao lutou: os 90s mudaram ($_r)" ;; esac
check "luta na tela no meio zera a contagem" FICOU "`_fim hp=5000@1000 fora@1001 fora@1010 luta@1012 fora@1013 fora@1027`"
check "leitura vazia no meio nao encerra antes da hora" FICOU "`_fim hp=5000@1000 fora@1001 vazia@1016 vazia@1020`"
check "luta_inicio de outra batalha esquece que lutou" FICOU "`_fim hp=5000@1000 inicio@1001 fora@1002 fora@1030`"
_r=`_FL=abc _fim hp=5000@1000 fora@1001 fora@1016`
case "$_r" in "SAIU@1016:"*) ok "LUTA_FORA_LUTOU invalido cai em 15s" ;;
              *) bad "LUTA_FORA_LUTOU invalido ($_r)" ;; esac
unset -f _fim

# O Vale nao le HP: marca que lutou na leitura com out_gate.
grep -q '_lt_lutou=1' "$LIB/undying.sh" \
    && ok "undying.sh: marca que a conta lutou" \
    || bad "undying.sh: sem _lt_lutou (o fim ficaria nos 90s)"

rm -rf "$_td5"; unset _td5 _r

printf "\n=== 36. servidor sem resposta nao e sessao caida ===\n"
# =============================================================================
#
# Logs de 12/09: das 922 "Sessao caiu no descanso", ~88% eram o servidor sem
# responder (557 "falha ao reconectar" com curl sem conexao). O bot apagava o
# cookie e refazia o login contra um servidor mudo. O sinal de sessao agora e
# o do jogo: jsInterface.event("user=N") no rodape de toda pagina, user=0 sem
# conta. Paginas reais conferidas: 117 logadas (user>0); /, /user e /king sem
# cookie (user=0 — o /user anonimo e um "Error 404" sem formulario de login).
_td6=`mktemp -d`
_ROD_OK='<!-- if (typeof jsInterface != '"'"'undefined'"'"') { jsInterface.event("user=12345;level=43"); } //-->'
_ROD_ANON='<!-- if (typeof jsInterface != '"'"'undefined'"'"') { jsInterface.event("user=0;level=0"); } //-->'
printf '%s' "<div><img src='/images/icon/level.png' alt=''/> 43</div>...$_ROD_OK" > "$_td6/logada"
printf '%s' "<title>Error 404: Page not found</title><a href='/common/?PHPSESSID=ab'>x</a>$_ROD_ANON" > "$_td6/anon_user"
printf '%s' "<form action='/?sign_in=1' method='post'><input name='pass' type='password'/>" > "$_td6/form_cortado"
printf '%s' "<p>Entrar</p><a href='/?sign_in=1&PHPSESSID=ab'>Entrar</a>" > "$_td6/home_anon_cortada"
printf '%s' "<div><img src='/images/icon/level.png' alt=''/> 43</div><div class='block_zero'>" > "$_td6/logada_cortada"
printf '%s' "<html><head><title>502 Bad Gateway</title></head><body>nginx</body></html>" > "$_td6/erro502"
printf '%s' "<a href='/user/12345'>perfil</a><a href='/king/'>rei</a>" > "$_td6/sem_marcador"
: > "$_td6/vazia"
_se() { ( TMP="$_td6"; . "$LIB/info.sh" > /dev/null 2>&1; sessao_estado "$1" ); }
_se_txt() { ( TMP="$_td6"; . "$LIB/info.sh" > /dev/null 2>&1; cat "$1" | sessao_estado - ); }
check "sessao_estado: pagina logada (user>0)"                 viva         "`_se "$_td6/logada"`"
check "sessao_estado: /user sem conta (404 com user=0)"       deslogado    "`_se "$_td6/anon_user"`"
check "sessao_estado: formulario de login cortado"            deslogado    "`_se "$_td6/form_cortado"`"
check "sessao_estado: Home sem conta cortada (link entrar)"   deslogado    "`_se "$_td6/home_anon_cortada"`"
check "sessao_estado: pagina logada cortada (icone de nivel)" viva         "`_se "$_td6/logada_cortada"`"
check "sessao_estado: erro 502 do servidor"                   sem_resposta "`_se "$_td6/erro502"`"
check "sessao_estado: pagina sem sinal nenhum"                sem_resposta "`_se "$_td6/sem_marcador"`"
check "sessao_estado: resposta vazia"                         sem_resposta "`_se "$_td6/vazia"`"
check "sessao_estado: arquivo inexistente"                    sem_resposta "`_se "$_td6/nao_existe"`"
check "sessao_estado -: texto logado pela entrada padrao"     viva         "`_se_txt "$_td6/logada"`"
check "sessao_estado -: texto vazio pela entrada padrao"      sem_resposta "`_se_txt "$_td6/vazia"`"
check "sessao_estado -: 404 sem conta pela entrada padrao"    deslogado    "`_se_txt "$_td6/anon_user"`"
unset -f _se _se_txt

# descansar: servidor mudo nao reconecta; pagina sem conta reconecta.
_desc() { # pagina da Home -> "relogin=N ok=S rede=S" + mensagem
    (
        TMP="$_td6/d_$1"; rm -rf "$TMP"; mkdir -p "$TMP"; URL="http://jogo"
        . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1
        _PG="$_td6/$1"
        fetch_page() { cp "$_PG" "${2:-$TMP/SRC}" 2>/dev/null || : > "${2:-$TMP/SRC}"; }
        run_curl() { :; }
        login_logoff() { echo x >> "$TMP/relog"; return 0; }
        batalha_retomar() { return 1; }
        _saida=`descansar 2>&1`
        printf 'relogin=%s ok=%s rede=%s' "`cat "$TMP/relog" 2>/dev/null | wc -l | tr -d ' '`" \
            "`[ -s "$TMP/last_ok" ] && echo S || echo N`" "`[ -s "$TMP/last_rede" ] && echo S || echo N`"
        case "$_saida" in *"Servidor sem resposta"*) printf ' msg=mudo' ;;
                          *"Sessao caiu"*)           printf ' msg=caiu' ;; esac
    )
}
check "descansar: Home vazia nao reconecta, marca servidor mudo" "relogin=0 ok=N rede=S msg=mudo" "`_desc vazia`"
check "descansar: erro 502 nao reconecta"                        "relogin=0 ok=N rede=S msg=mudo" "`_desc erro502`"
check "descansar: pagina logada confirma a sessao"               "relogin=0 ok=S rede=N"          "`_desc logada`"
check "descansar: pagina sem conta reconecta"                    "relogin=1 ok=S rede=N msg=caiu" "`_desc anon_user`"
unset -f _desc

# login_logoff: /user vazio ou quebrado NAO apaga o cookie nem faz POST.
_llo() { # pagina devolvida pelo /user -> "rc=N pedidos=N cookie=S|N" + msg
    (
        TMP="$_td6/l_$1"; rm -rf "$TMP"; mkdir -p "$TMP"; URL="http://jogo"
        TMP_COOKIE="$TMP/cookie.txt"; echo "cookie-valido" > "$TMP_COOKIE"
        printf 'login=a&pass=b' | base64 > "$TMP/cript_file"
        . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/session_check.sh" > /dev/null 2>&1
        . "$LIB/loginlogoff.sh" > /dev/null 2>&1
        _PG="$_td6/$1"
        run_curl() { echo x >> "$TMP/pedidos"; cat "$_PG" 2>/dev/null; }
        login_lock() { :; }; login_unlock() { :; }
        sleep() { :; }
        _saida=`login_logoff 2>&1`; _rc=$?
        printf 'rc=%s pedidos=%s cookie=%s' "$_rc" "`wc -l < "$TMP/pedidos" | tr -d ' '`" \
            "`[ -s "$TMP_COOKIE" ] && echo S || echo N`"
        case "$_saida" in *"servidor sem resposta"*) printf ' msg=mudo' ;;
                          *"sessao expirada"*)       printf ' msg=expirada' ;; esac
    )
}
check "login_logoff: /user vazio mantem cookie, sem POST"   "rc=1 pedidos=1 cookie=S msg=mudo" "`_llo vazia`"
# Sessao confirmada no login libera a varredura (servidor_mudo) na hora.
_r=$( TMP="$_td6/l_ok"; rm -rf "$TMP"; mkdir -p "$TMP"; URL="http://jogo"; TMP_COOKIE="$TMP/c"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/session_check.sh" > /dev/null 2>&1
      . "$LIB/loginlogoff.sh" > /dev/null 2>&1
      run_curl() { cat "$_td6/logada"; }; fetch_train_stats() { :; }; clan_id() { :; }; messages_info() { :; }
      echo $(( `date +%s` - 5 )) > "$TMP/last_rede"
      login_logoff > /dev/null 2>&1
      servidor_mudo && printf 'mudo' || printf 'liberado' )
check "login_logoff: sessao confirmada libera a varredura" "liberado" "$_r"
check "login_logoff: /user com erro 502 mantem cookie"      "rc=1 pedidos=1 cookie=S msg=mudo" "`_llo erro502`"
_r=`_llo anon_user`
case "$_r" in "rc=1 pedidos="[2-9]*" cookie=N msg=expirada") ok "login_logoff: /user sem conta refaz o login ($_r)" ;;
              *) bad "login_logoff: /user sem conta devia refazer o login ($_r)" ;; esac
unset -f _llo

# atualiza_stats: no ocio, so a pagina sem conta reconecta.
_ocio() {
    (
        TMP="$_td6/o_$1"; rm -rf "$TMP"; mkdir -p "$TMP"; URL="http://jogo"
        . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/session_check.sh" > /dev/null 2>&1
        . "$LIB/crono.sh" > /dev/null 2>&1
        _PG="$_td6/$1"
        fetch_train_stats() { :; }
        run_curl() { cat "$_PG" 2>/dev/null; }
        login_logoff() { echo x >> "$TMP/relog"; return 1; }
        atualiza_stats > /dev/null 2>&1
        printf 'relogin=%s rede=%s' "`cat "$TMP/relog" 2>/dev/null | wc -l | tr -d ' '`" \
            "`[ -s "$TMP/last_rede" ] && echo S || echo N`"
    )
}
check "atualiza_stats: /user vazio nao reconecta"     "relogin=0 rede=S" "`_ocio vazia`"
check "atualiza_stats: /user com erro 502 nao reconecta" "relogin=0 rede=S" "`_ocio erro502`"
check "atualiza_stats: /user sem conta reconecta"     "relogin=1 rede=N" "`_ocio anon_user`"
unset -f _ocio

# sls.sh (roda o laco de login ao ser carregado; conferido pelo texto):
# o ramo de falha de rede nao apaga mais o cookie.
_bloco=`awk '/LOGIN_ERRO:-credencial}" = "rede"/ {f=1} f {print} f && /continue/ {exit}' "$LIB/sls.sh"`
case "$_bloco" in
    *'rm -f "$TMP_COOKIE"'*) bad "sls.sh: falha de rede ainda apaga o cookie (login completo a cada soluco)" ;;
    *continue*)              ok  "sls.sh: falha de rede mantem o cookie para reaproveitar a sessao" ;;
    *)                       bad "sls.sh: ramo de falha de rede nao encontrado" ;;
esac
[ "`grep -c 'sessao_estado -' "$LIB/sls.sh"`" -ge 2 ] \
    && ok "sls.sh: pagina que nao e do jogo conta como rede, antes e depois do POST" \
    || bad "sls.sh: pagina de erro do servidor ainda conta como credencial recusada"
grep -q 'sem resposta' "$LIB/panel.sh" && grep -q 'last_rede' "$LIB/panel.sh" \
    && ok "panel.sh: distingue 'sem resposta' de 'sessao caida'" \
    || bad "panel.sh: continua dizendo 'sessao caida' com o servidor mudo"

rm -rf "$_td6"; unset _td6 _r _bloco _ROD_OK _ROD_ANON

printf "\n=== 37. morte escrita no log da batalha e botao 'Troca o alvo' ===\n"
# =============================================================================
#
# Paginas reais do Torneio dos Clas (12/09, servidor BR), capturadas pela
# coleta de amostras. As fixtures abaixo reproduzem a MARCACAO delas, com nomes
# inventados:
#   - quem morreu: "Fulano assassinou Voce" (13 de 14) e "Espere ate o fim
#     da batalha" (14 de 14); nenhuma das 28 paginas com luta ativa tinha
#     "assassinou Voce" — o log delas so traz a morte dos outros;
#   - 'txt smpl grey' so apareceu no botao "Troca o alvo" desativado, e o bot
#     parava de atacar nessas leituras (2 de 28).
_td7=`mktemp -d`
_BTN_OK="<div class='fight_buttons'><a class='nbtn b_green' href='/clanfight/dodge/?r=11'><span class='lbl'><span class='txt smpl'>Esquivar</span></span></a><a class='nbtn b_red btn-attack-inst' href='/clanfight/attack/?r=12'><span class='lbl'><span class='txt smpl'>Atacar</span></span></a>"
_TROCA_OFF="<a class='nbtn b_grey' href='/clanfight/'><span class='lbl'><span class='txt smpl grey'>Troca o alvo</span></span></a></div>"
_TROCA_RND="<a class='nbtn b_grey' href='/clanfight/attackrandom/?r=13'><span class='lbl'><span class='txt smpl grey'>Troca o alvo</span></span></a></div>"
_NIVEL="<img src='/images/icon/level.png' alt=''/> 90"
printf '%s' "$_NIVEL<div class='block_zero'><span class='grey'>Espere até o fim da batalha </span></div><div class='block_zero'><img src='/images/icon/rip.png' alt=''/> <span class='dred'><img src='/images/icon/race/1.png' alt=''/> Beltrano Silva assassinou Você</span><br/>Você perdeu<br/>" > "$_td7/morto_log"
printf '%s' "$_NIVEL<div class='block_zero'><span class='grey'>Espere até o fim da batalha </span><br/>5 clãs na batalha</div>" > "$_td7/espere"
printf '%s' "$_NIVEL$_BTN_OK$_TROCA_OFF<div><img src='/images/icon/rip.png' alt=''/> Ciclano assassinou <span>Fulano</span><br/>Você assassinou <span>Outro</span><br/>Você perdeu</div>" > "$_td7/luta_log_outros"
printf '%s' "$_NIVEL$_BTN_OK$_TROCA_OFF<div><span class='dred'>Beltrano assassinou Você</span></div>" > "$_td7/luta_depois_de_reviver"
printf '%s' "$_NIVEL$_BTN_OK$_TROCA_OFF" > "$_td7/troca_off"
printf '%s' "$_NIVEL$_BTN_OK$_TROCA_RND" > "$_td7/troca_rnd"
printf '%s' "$_NIVEL<div class='target'><span class='txt smpl grey'>Alvo</span></div>$_BTN_OK</div>" > "$_td7/alvo_grey_fora_botao"
printf '%s' "$_NIVEL<div class='fight_buttons'><a class='nbtn b_grey' href='/clanfight/attack/?r=12'><span class='lbl'><span class='txt smpl grey'>Atacar</span></span></a></div>" > "$_td7/ataque_grey"
_f37() { ( TMP="$_td7"; . "$LIB/info.sh" > /dev/null 2>&1; "$@" ); }
check "estado_luta: 'assassinou Você' sem botao = morto"          morto "`_f37 estado_luta "$_td7/morto_log" clanfight`"
check "estado_luta: 'Espere até o fim da batalha' = morto"         morto "`_f37 estado_luta "$_td7/espere" clanfight`"
check "estado_luta: log com a morte dos OUTROS continua luta"      luta  "`_f37 estado_luta "$_td7/luta_log_outros" clanfight`"
printf '%s' "$_NIVEL<div><img src='/images/icon/rip.png' alt=''/> Ciclano assassinou <span>Fulano</span><br/>Você assassinou <span>Outro</span></div>" > "$_td7/sem_botao_log_outros"
check "estado_luta: sem botao, so morte dos OUTROS, nao e morte"   fora  "`_f37 estado_luta "$_td7/sem_botao_log_outros" clanfight`"
check "estado_luta: linha velha 'assassinou Você' com botao = luta" luta "`_f37 estado_luta "$_td7/luta_depois_de_reviver" clanfight`"
check "luta_assassino: nome de quem matou"      "Beltrano Silva" "`_f37 luta_assassino "$_td7/morto_log"`"
check "luta_assassino: sem assassino no log"    ""               "`_f37 luta_assassino "$_td7/espere"`"
_r=$( TMP="$_td7/m"; mkdir -p "$TMP"; . "$LIB/info.sh" > /dev/null 2>&1
      luta_inicio clanfight > /dev/null 2>&1
      luta_acabou "$_td7/morto_log" clanfight > /dev/null && printf '%s|' "$LUTA_MOTIVO"
      batalha_pendente || printf 'limpa' )
check "luta_acabou: morto pelo log encerra na hora, com o nome" \
      "assassinado por Beltrano Silva (log da batalha)|limpa" "$_r"
# Fim escrito pelo jogo (Rei "Batalha finalizada!", Vale "Vitória!", Torneio
# "Luta acabou!"): sai na hora SO depois de ter lutado — antes, o saguao do Rei
# ainda mostra o resultado da batalha anterior.
printf '%s' "$_NIVEL<div class='block_zero'>Rei dos Imortais 3 nível<br/>Batalha finalizada! <br/>Vitória!</div><a class='btn' href='/king/enterGame/?r=5'>Aplicar</a>" > "$_td7/rei_fim"
printf '%s' "$_NIVEL<div class='block_zero'>Vitória!<br/>Troféu: 100 prata</div>" > "$_td7/vale_fim"
_fim37() { # pagina secao lutou? -> "SAIU:motivo" ou "FICOU"
    ( TMP="$_td7/f_$1"; rm -rf "$TMP"; mkdir -p "$TMP"; . "$LIB/info.sh" > /dev/null 2>&1
      luta_inicio "$2" > /dev/null 2>&1
      [ "$3" = lutou ] && luta_hp 5000 > /dev/null
      if luta_acabou "$_td7/$1" "$2" > /dev/null; then printf 'SAIU:%s' "$LUTA_MOTIVO"; else printf 'FICOU'; fi )
}
check "Rei: 'Batalha finalizada!' depois de lutar encerra na hora" "SAIU:o jogo declarou o fim da batalha" "`_fim37 rei_fim king lutou`"
check "Rei: 'Batalha finalizada!' ANTES de lutar nao encerra"      "FICOU"                                "`_fim37 rei_fim king nao`"
check "Vale: 'Vitória!' depois de lutar encerra na hora"          "SAIU:o jogo declarou o fim da batalha" "`_fim37 vale_fim undying lutou`"
unset -f _fim37

_g() { _f37 alvo_grey "$1" && echo sim || echo nao; }
check "alvo_grey: 'Troca o alvo' desativado nao e alvo grey"   nao "`_g "$_td7/troca_off"`"
check "alvo_grey: 'Troca o alvo' attackrandom nao e alvo grey" nao "`_g "$_td7/troca_rnd"`"
check "alvo_grey: marca grey fora dos botoes vale"             sim "`_g "$_td7/alvo_grey_fora_botao"`"
check "alvo_grey: botao de ATAQUE grey vale"                   sim "`_g "$_td7/ataque_grey"`"
check "alvo_grey: pagina vazia nao e grey"                     nao "`_g "$_td7/nao_existe"`"
unset -f _g _f37

# Nenhum modulo volta a testar a marca na pagina inteira.
_mods=""
for _m in altars clancoliseum clandmg clanfight coliseum flagfight king; do
    grep -q "grep -q -o 'txt smpl grey'" "$LIB/$_m.sh" && _mods="$_mods $_m"
done
[ -z "$_mods" ] && ok "modulos de luta: alvo invulneravel so pelo alvo_grey" \
                || bad "modulos ainda leem 'txt smpl grey' na pagina inteira:$_mods"

rm -rf "$_td7"; unset _td7 _r _mods _m _BTN_OK _TROCA_OFF _TROCA_RND _NIVEL

printf "\n=== 38. aliados: membros do mesmo cla, e o nome certo do alvo ===\n"
# =============================================================================
#
# Regra do dono: aliado e SO quem esta na lista de amigos e quem e do mesmo
# cla. Em 12/09 uma conta matou outra no Rei (as duas do mesmo cla):
#   - conta com amigos ficava so com os amigos, sem o cla;
#   - o nome do alvo lido na luta era "Fulano_&" em todas as 48 paginas do
#     Rei capturadas — nunca o alvo — e nas batalhas de cla nem era lido;
#   - clas inteiros eram poupados quando o lider era amigo.
# Fixtures com a marcacao das paginas reais e nomes inventados.
_td8=`mktemp -d`
_f38() { ( TMP="$_td8"; URL="http://jogo"; export TMP URL
           SLS_PACING=0; . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/allies.sh" > /dev/null 2>&1; "$@" ); }
_FICHA="<div class='fl left w50'><img src='/images/icon/race/1.png' alt=''/> Minha Conta <span class='nwr'><img src='/images/icon/health.png' alt='hp'/> 35656</span><img src='/images/icon/race/0.png' alt=''/> Fulano Silva <span class='nwr'><img src='/images/icon/health.png' alt='hp'/>&nbsp;8092</span></div>"
printf '%s' "<a href='/footer'>Fulano &amp; Cia</a>$_FICHA<div class='fight_buttons'></div>" > "$_td8/luta"
printf '%s' "<div>Rei dos Imortais</div><img src='/images/icon/race/1.png' alt=''/> Minha Conta <span class='nwr'><img src='/images/icon/health.png' alt='hp'/> 100</span>" > "$_td8/sem_alvo"
check "alvo_nome: o nome do ALVO (do &nbsp;), nao o proprio nem o rodape" "Fulano_Silva" "`_f38 alvo_nome "$_td8/luta"`"
check "alvo_nome: pagina sem alvo nao inventa nome"                        ""           "`_f38 alvo_nome "$_td8/sem_alvo"`"

# Membros do cla: pagina 1 + paginas pelos links do jogo (/clan/ID//N).
printf '%s' "<a href='/user/111/'><img src='/images/icon/race/1.png' alt=''/>Chefe Grande, <span class='white'><span class='green'>Clã líder</span></span><br/><a href='/user/222/'><img src='/images/icon/race/1-off.png' alt=''/>beltrano souza, <span class='white'>General</span><br/><a href='/user/333/'>Visitante Sem Cargo</a> <a href='/clan/999//2'>2</a>" > "$_td8/cla_p1"
printf '%s' "<a href='/user/444/'><img src='/images/icon/race/0.png' alt=''/>Fulano Silva, <span class='white'>Soldado</span>" > "$_td8/cla_p2"
# Marcacao da "Lista de amigos" real (13/09), com o link "Exclui" de cada amigo.
printf '%s' "<a href='/mail/'><img src='/images/icon/mail.png' alt=''/></a><div class='block_zero'><img src='/images/icon/race/1-off.png' alt=''/> <a href='/user/555/'>Amigo Um</a>, <img src='/images/icon/level.png' alt=''/> 61 nível <span class='medium'>( <a href='/mail/555/'>Escrever</a> / <a href='/mail/friends/delete/555?r=91'>Exclui</a> )</span><br/><img src='/images/icon/race/0.png' alt=''/> <a href='/user/666/'>Amigo Dois</a>, <img src='/images/icon/level.png' alt=''/> 95 nível <span class='medium'>( <a href='/mail/666/'>Escrever</a> / <a href='/mail/friends/delete/666?r=92'>Exclui</a> )</span></div><a href='/user/777/'>Nao Amigo</a>" > "$_td8/amigos"
_montar38() { # modo -> "allies|callies" (nomes separados por espaco)
    ( TMP="$_td8/m$1"; URL="http://jogo"; CLD=999; HOME="$_td8/h$1"; export TMP URL CLD HOME; rm -rf "$TMP"; mkdir -p "$TMP"
      SLS_PACING=0; . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/allies.sh" > /dev/null 2>&1
      echo "Velho_Amigo" > "$TMP/allies.txt"
      run_curl_exec() { case "$1" in
          */mail/friends)   cat "$_td8/amigos" ;;
          */clan/999)       cat "$_td8/cla_p1" ;;
          */clan/999//2)    cat "$_td8/cla_p2" ;;
          *) : ;; esac; }
      time_exit() { wait "$!" 2>/dev/null; }
      aliados_montar "$1" > /dev/null 2>&1
      printf '%s|%s' "`tr '\n' ' ' < "$TMP/allies.txt" | sed 's/ $//'`" "`tr '\n' ' ' < "$TMP/callies.txt" 2>/dev/null | sed 's/ $//'`" )
}
# Regra do dono (29/10): a lista de amigos do jogo nao conta mais; o cla sim.
_todos="Chefe_Grande Fulano_Silva beltrano_souza"
check "aliados modo 1: cla em todas as batalhas, sem os amigos" "$_todos|$_todos" "`_montar38 1`"
check "aliados modo 2: so Rei (allies)"                    "$_todos|"       "`_montar38 2`"
check "aliados modo 3: so batalhas de cla (callies)"        "|$_todos"       "`_montar38 3`"

# A lista de amigos traz o link "Exclui": nenhum pedido pode desfazer amizade.
_r=$( TMP="$_td8/del"; URL="http://jogo"; CLD=999; HOME="$_td8/hdel"; export TMP URL CLD HOME; mkdir -p "$TMP"
      SLS_PACING=0; . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/allies.sh" > /dev/null 2>&1
      run_curl_exec() { echo "$1" >> "$TMP/pedidos"; case "$1" in
          */mail/friends) cat "$_td8/amigos" ;; */clan/999) cat "$_td8/cla_p1" ;; */clan/999//2) cat "$_td8/cla_p2" ;; esac; }
      time_exit() { wait "$!" 2>/dev/null; }
      : > "$TMP/pedidos"
      aliados_montar 1 > /dev/null 2>&1
      _aliado_pagina "/mail/friends/delete/555?r=91" "$TMP/x" > /dev/null 2>&1
      grep -c delete "$TMP/pedidos" )
check "aliados: nunca pede o link 'Exclui' da lista de amigos" "0" "$_r"

# A lista de amigos nem e pedida.
_r=$( TMP="$_td8/sem_amigos"; URL="http://jogo"; CLD=999; HOME="$_td8/hsa"; export TMP URL CLD HOME; mkdir -p "$TMP"
      SLS_PACING=0; . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/allies.sh" > /dev/null 2>&1
      run_curl_exec() { echo "$1" >> "$TMP/pedidos"; case "$1" in
          */clan/999) cat "$_td8/cla_p1" ;; */clan/999//2) cat "$_td8/cla_p2" ;; esac; }
      time_exit() { wait "$!" 2>/dev/null; }
      : > "$TMP/pedidos"; aliados_montar 1 > /dev/null 2>&1
      grep -c 'mail/friends' "$TMP/pedidos" )
check "aliados: a lista de amigos nao e mais pedida" 0 "$_r"

# Servidor mudo nao apaga a lista.
_r=$( TMP="$_td8/mudo"; URL="http://jogo"; CLD=999; HOME="$_td8/hmudo"; export TMP URL CLD HOME; mkdir -p "$TMP"
      SLS_PACING=0; . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/allies.sh" > /dev/null 2>&1
      echo "Amigo_Antigo" > "$TMP/allies.txt"
      run_curl_exec() { :; }; time_exit() { wait "$!" 2>/dev/null; }
      aliados_montar 1 > /dev/null 2>&1; cat "$TMP/allies.txt" )
check "aliados: pagina que nao respondeu mantem a lista anterior" "Amigo_Antigo" "$_r"

# alvo_aliado: Rei usa allies.txt; cla usa callies.txt; sem maiusculas.
_r=$( TMP="$_td8/aa"; mkdir -p "$TMP"; SLS_PACING=0; . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/allies.sh" > /dev/null 2>&1
      printf 'Fulano_silva\n' > "$TMP/allies.txt"; : > "$TMP/callies.txt"
      printf 'Fulano_Silva\n' > "$TMP/U"
      alvo_aliado "$TMP/U" && printf 'rei=sim ' || printf 'rei=nao '
      alvo_aliado "$TMP/U" cla && printf 'cla=sim' || printf 'cla=nao' )
check "alvo_aliado: lista do Rei sem diferenca de maiusculas; cla usa a propria lista" "rei=sim cla=nao" "$_r"

# Os modulos leem o alvo pelo alvo_nome e nao comparam mais o cla do alvo.
_mods=""
for _m in king altars clancoliseum clandmg clanfight flagfight; do
    grep -q 'alvo_nome ' "$LIB/$_m.sh" || _mods="$_mods $_m"
done
[ -z "$_mods" ] && ok "modulos de luta: nome do alvo pelo alvo_nome" \
                || bad "modulos sem alvo_nome:$_mods"
grep -q -E 'alvo_aliado USER CLAN|> CLAN 2' "$LIB"/altars.sh "$LIB"/clancoliseum.sh "$LIB"/clandmg.sh "$LIB"/clanfight.sh "$LIB"/flagfight.sh \
    && bad "batalhas de cla ainda poupam o CLA inteiro do alvo" \
    || ok "batalhas de cla poupam por nome (amigos + cla), nao o cla inteiro do alvo"
grep -q 'clan_allies\|LEADPU' "$LIB/allies.sh" \
    && bad "allies.sh ainda poupa clas cujo lider e amigo" \
    || ok "allies.sh nao poupa mais clas inteiros pelo lider"

unset -f _f38 _montar38
rm -rf "$_td8"; unset _td8 _r _mods _m _FICHA _todos

printf "\n=== 39. Liga: luta que nao conta e Liga do dia as 00:30 ===\n"
# =============================================================================
#
# Logs de 13/09: uma conta clicou 17 vezes no mesmo adversario com o contador
# parado em 3 (outra, 9 vezes) ate o teto de 5 minutos. E a Liga era
# aberta a cada 30 min com o contador zerado: 12.917 leituras "recompensa
# ainda indisponivel", enquanto 193 das 195 coletas vieram com as lutas ja
# restauradas. A pagina real diz quanto falta para o restauro.
_td9=`mktemp -d`
_liga39() { # lutas_iniciais conta(sim|nao) [marcador_restauro] -> "lutas=N alvos=A,B restauro=S|N" + saida
    ( TMP="$_td9/c"; URL="http://jogo"; export TMP URL; mkdir -p "$TMP"
      echo "$1" > "$TMP/sim_lutas"; echo "$2" > "$TMP/sim_conta"; : > "$TMP/sim_req"
      rm -f "$TMP/POTION" "$TMP/league_reward_pending" "$TMP/liga_luta_nao_contou.html"
      if [ -n "$3" ]; then echo "$3" > "$TMP/league_restauro"; else rm -f "$TMP/league_restauro"; fi
      . "$LIB/league.sh" > /dev/null 2>&1
      load_config() { :; }; checkQuest() { return 1; }; get_config() { echo 5; }
      player_stats() { echo 3165; }; sleep() { :; }
      fetch_page() { # servidor simulado: marcacao da pagina real da Liga
          _d="${2:-$TMP/SRC}"; echo "$1" >> "$TMP/sim_req"; _n=`cat "$TMP/sim_lutas"`
          case "$1" in
              /league/)
                  _t=""; [ "$_n" -eq 0 ] && _t="Tempo restante para restauro: 05:29:02"
                  _p="<div class='block_zero'><img src='/images/icon/2hit.png' alt=''/> Lutas disponiveis: <b>$_n</b><br/>$_t<div class='mb10'></div></div>"
                  for _e in 302 312 322 332; do
                      _p="$_p<a href='/league/fight/$_e/?r=77'></a><b>$_e. Nome</b><br/>Força: 50<br/>Saúde: 50<br/>Agilidade: 50<br/>Proteção: 50<br/><a class='btn' href='/league/fight/$_e/?r=77'>Atacar</a>"
                  done
                  printf '%s\n' "$_p" > "$_d" ;;
              /league/fight/*)
                  if [ "`cat "$TMP/sim_conta"`" = sim ] && [ "$_n" -gt 0 ]; then echo $((_n - 1)) > "$TMP/sim_lutas"; fi
                  printf 'resultado da luta %s\n' "$1" > "$_d" ;;
              *) : > "$_d" ;;
          esac
      }
      league_play > "$TMP/saida" 2>&1
      _alvos=`grep '^/league/fight/' "$TMP/sim_req" | cut -d/ -f4 | tr '\n' ',' | sed 's/,$//'`
      [ -f "$TMP/league_restauro" ] && _r=S || _r=N
      printf 'lutas=%s alvos=%s restauro=%s' "`grep -c '^/league/fight/' "$TMP/sim_req"`" "$_alvos" "$_r" )
}

check "restauro lido da pagina: 05:29:02 = 19742 s" 19742 \
    "`printf '%s' "Lutas disponiveis: <b>0</b><br/>Tempo restante para restauro: 05:29:02<div>" > "$_td9/p0"; . "$LIB/league.sh" > /dev/null 2>&1; league_restauro_segundos "$_td9/p0"`"
check "com lutas no contador nao ha restauro a anotar" "" \
    "`printf '%s' "Lutas disponiveis: <b>3</b><br/><div> rodape 16:15:28" > "$_td9/p3"; . "$LIB/league.sh" > /dev/null 2>&1; league_restauro_segundos "$_td9/p3"`"

# Luta que nao conta: uma tentativa em outro adversario e sai (antes: 20 lutas).
_r=`_liga39 3 nao`
check "luta que nao conta: dois adversarios diferentes e sai" "lutas=2 alvos=302,312 restauro=N" "$_r"
grep -q 'Duas lutas seguidas sem contar' "$_td9/c/saida" \
    && ok "luta que nao conta: avisa e deixa para a proxima passagem" \
    || bad "luta que nao conta: sem o aviso de saida"
grep -q 'Teto do laco' "$_td9/c/saida" \
    && bad "luta que nao conta: ainda gasta o teto de 5 minutos" \
    || ok "luta que nao conta: nao chega ao teto"
[ -s "$_td9/c/liga_luta_nao_contou.html" ] \
    && ok "luta que nao conta: resposta do jogo guardada" \
    || bad "luta que nao conta: resposta do jogo nao foi guardada"

# Dia normal: cinco lutas, contador zerado, Liga fechada ate as 00:30.
_r=`_liga39 5 sim`
check "dia normal: cinco lutas e reabertura anotada" "lutas=5 alvos=302,302,302,302,302 restauro=S" "$_r"
_ep=`cat "$_td9/c/league_restauro" 2>/dev/null`; _ag=`date +%s`
if [ -n "$_ep" ] && [ $((_ep - _ag)) -ge 21530 ] && [ $((_ep - _ag)) -le 21545 ]; then
    ok "reabre as 00:30: restauro (05:29:02) + 30 min"
else
    bad "reabertura anotada errada (${_ep:-vazio} - $_ag)"
fi
_r=`_liga39 0 sim "$_ep"`
check "Liga do dia feita: nem abre" "lutas=0 alvos= restauro=S" "$_r"
[ -s "$_td9/c/sim_req" ] && bad "Liga do dia feita: ainda pede paginas" \
    || ok "Liga do dia feita: nenhuma pagina e pedida"
grep -q 'Liga do dia ja feita - reabre as 00:30' "$_td9/c/saida" \
    && ok "Liga do dia feita: avisa quando reabre" \
    || bad "Liga do dia feita: sem aviso"
_r=`_liga39 5 sim "$((_ag - 10))"`
check "passou das 00:30: a Liga volta a lutar" "lutas=5 alvos=302,302,302,302,302 restauro=S" "$_r"
_r=`_liga39 3 sim "lixo"`
check "marcador ilegivel nao fecha a Liga" "lutas=3 alvos=302,302,302 restauro=S" "$_r"

# liga_do_dia: a visita inteira (missao do cla, Liga, intervalo) ou nada.
_r=`( TMP="$_td9/d"; mkdir -p "$TMP"; . "$LIB/league.sh" > /dev/null 2>&1
      cq_antes() { printf 'cq:%s,' "$1"; }; league_play() { printf 'liga,'; }; ativ_marcar() { printf 'marca:%s' "$1"; }
      echo $(( \`date +%s\` + 600 )) > "$TMP/league_restauro"; liga_do_dia; printf '|rc=%s|' "$?"
      rm -f "$TMP/league_restauro"; liga_do_dia )`
check "liga_do_dia: fechada nao faz nada; aberta faz a visita inteira" "|rc=1|liga,marca:liga" "$_r"
_r=`( . "$LIB/league.sh" > /dev/null 2>&1; for _m in 12:05 10:12 12:27 12:40 21:57; do
      date() { echo "$_m"; }; liga_fora_da_inscricao && printf '%s=livre ' "$_m" || printf '%s=evento ' "$_m"; done )`
check "entrada: minutos de inscricao de evento deixam a Liga para depois" "12:05=livre 10:12=evento 12:27=evento 12:40=livre 21:57=evento " "$_r"

# Cronograma e entrada do bot passam pela liga_do_dia; nada chama a Liga solta.
_r=`grep -c 'liga_do_dia$' "$LIB/crono.sh"`
check "cronograma: a varredura ociosa (que o start() chama) usa a liga_do_dia" 1 "$_r"
grep -q -E '^[^#]*(cq_antes liga|league_play)' "$LIB/crono.sh" "$LIB/run.sh" "$LIB/sls.sh" \
    && bad "cronograma: Liga chamada fora da liga_do_dia" \
    || ok "cronograma: a Liga so entra pela liga_do_dia"
_l=`grep -n 'liga_do_dia' "$LIB/sls.sh" | head -n 1 | cut -d: -f1`
_w=`grep -n '^while true; do' "$LIB/sls.sh" | tail -n 1 | cut -d: -f1`
_d=`grep -n '^    if do_login; then' "$LIB/sls.sh" | head -n 1 | cut -d: -f1`
if [ -n "$_l" ] && [ -n "$_w" ] && [ -n "$_d" ] && [ "$_d" -lt "$_l" ] && [ "$_l" -lt "$_w" ] && \
   grep -q 'if ! batalha_pendente && liga_fora_da_inscricao; then' "$LIB/sls.sh"; then
    ok "entrada: Liga do dia depois do login, antes do laco, sem atropelar batalha"
else
    bad "entrada: Liga do dia fora do lugar (login=$_d liga=$_l laco=$_w)"
fi
unset _l _w _d

unset -f _liga39
rm -rf "$_td9"; unset _td9 _r _ep _ag

printf "\n=== 40. Masmorra, caverna, campanha e troca pelo relogio do jogo ===\n"
# =============================================================================
#
# Regras do jogo lidas das paginas (13/09): masmorra "+10 golpes em
# <span id='time_28800000'>08:00:00</span>" depois dos golpes; caverna com o
# relogio no menu da pagina inicial, "(21:04)" ou "(+)"; campanha "Nova
# campanha em 7 h 38 min"; troca uma olhada por dia. Marcacao das paginas
# reais, sem dados de conta.
_td10=`mktemp -d`
_perto() { # descricao esperado_seg arquivo_next
    _v=`cat "$3" 2>/dev/null`; _a=`date +%s`
    if [ -n "$_v" ] && [ $((_v - _a)) -ge $(($2 - 10)) ] && [ $((_v - _a)) -le "$2" ]; then
        ok "$1 (~$2 s)"
    else
        bad "$1 (esperado ~$2 s, obtido $(( ${_v:-0} - _a )))"
    fi
    unset _v _a
}
_agora_mais() { echo $(( `date +%s` + $1 )); }

# --- masmorra
_rm() { ( TMP="$_td10/m"; rm -rf "$TMP"; mkdir -p "$TMP"; . "$LIB/crono.sh" > /dev/null 2>&1
          printf '%s' "$1" > "$TMP/DUNGEON"; FUNC_masmorra_min=45; "$2" ) ; }
_MD="<div class='block_zero center'>Não há mais golpes<br/><span class='grey medium'>+10 golpes em <span id='time_28800000'>08:00:00</span></span><div class='mb5'></div>"
_MD3="<div class='block_zero center'>Não há mais golpes<br/><span class='grey medium'>+10 golpes em <span id='time_10800000'>03:00:00</span></span>"
printf '%s' "$_MD" > "$_td10/d"
check "masmorra: relogio da pagina (time_28800000 = 8h)" 28800 \
    "`( . "$LIB/crono.sh" > /dev/null 2>&1; masmorra_relogio "$_td10/d" )`"
_rm "$_MD" masmorra_marcar;  _perto "masmorra: golpes dados, volta quando a pagina manda" 28860 "$_td10/m/next_masmorra"
_rm "$_MD3" masmorra_adiar;  _perto "masmorra: sem golpe agora, volta no relogio (3h), nao em 45 min" 10860 "$_td10/m/next_masmorra"
_rm "<div>sem relogio</div>" masmorra_marcar; _perto "masmorra: golpes dados sem relogio, as 8h do jogo" 28860 "$_td10/m/next_masmorra"
_rm "<div>sem relogio</div>" masmorra_adiar;  _perto "masmorra: sem golpe e sem relogio, FUNC_masmorra_min" 2760 "$_td10/m/next_masmorra"

# --- caverna
_MENU_T="<li><a href='/cave/'><img src='/images/icon/cave.png' alt=''/>Caverna <span class='grey'>(21:04)</span></a></li><li><a href='/sage/'>Cabana</a></li>"
_MENU_H="<li><a href='/cave/'><img src='/images/icon/cave.png' alt=''/>Caverna <span class='grey'>(1:02:03)</span></a></li>"
_MENU_P="<li><a href='/cave/'><img src='/images/icon/cave.png' alt=''/>Caverna<span class='green'> (+)</span></a></li>"
_MENU_0="<li><a href='/cave/'><img src='/images/icon/cave.png' alt=''/>Caverna</a></li><li><a href='/king/'><img src='/images/icon/king.png' alt=''/>Rei dos Imortais <span class='grey'>(14:32)</span></a></li>"
_cv() { ( TMP="$_td10/c"; rm -rf "$TMP"; mkdir -p "$TMP"; . "$LIB/crono.sh" > /dev/null 2>&1
          [ -n "$2" ] && echo "$2" > "$TMP/next_caverna"
          printf '%s' "$1" > "$TMP/REST"; caverna_ler_menu "$TMP/REST" ) ; }
_cv "$_MENU_T"; _perto "caverna: menu (21:04) + 30 s" 1294 "$_td10/c/next_caverna"
_cv "$_MENU_H"; _perto "caverna: menu (1:02:03) + 30 s" 3753 "$_td10/c/next_caverna"
_cv "$_MENU_P"; _perto "caverna: menu (+) libera agora" 0 "$_td10/c/next_caverna"
_cv "$_MENU_0" 999
check "caverna: relogio do Rei no item seguinte do menu nao vira relogio da caverna" 999 "`cat "$_td10/c/next_caverna"`"
_cv "<html>pagina de luta</html>" 555
check "caverna: pagina sem menu nao mexe no relogio anotado" 555 "`cat "$_td10/c/next_caverna"`"
_r=`( TMP="$_td10/l"; rm -rf "$TMP"; mkdir -p "$TMP"; . "$LIB/crono.sh" > /dev/null 2>&1
      ativ_liberada() { printf 'intervalo:%s ' "$2"; return 0; }
      _agora_mais 600 > "$TMP/next_caverna"; caverna_liberada && printf 'futuro=sim ' || printf 'futuro=nao '
      _agora_mais -5 > "$TMP/next_caverna";  caverna_liberada && printf 'vencido=sim ' || printf 'vencido=nao '
      rm -f "$TMP/next_caverna"; caverna_liberada && printf 'sem_leitura=sim' || printf 'sem_leitura=nao' )`
check "caverna: relogio no futuro fecha, vencido abre, sem leitura usa os 20 min" "futuro=nao vencido=sim intervalo:20 sem_leitura=sim" "$_r"
_r=`( TMP="$_td10/k"; rm -rf "$TMP"; mkdir -p "$TMP"; . "$LIB/crono.sh" > /dev/null 2>&1
      ativ_marcar() { :; }; caverna_marcar )`
_perto "caverna: depois de mexer, 20 min ate o menu ser relido" 1200 "$_td10/k/next_caverna"

# --- campanha
_camp() { # cenario -> "req=N"
    ( TMP="$_td10/p"; rm -rf "$TMP"; mkdir -p "$TMP"; . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1; . "$LIB/campaign.sh" > /dev/null 2>&1
      : > "$TMP/req"; CENA="$1"; VIVA="<script>jsInterface.event(\"user=5;level=40\")</script>"
      fetch_page() {
          echo "$1" >> "$TMP/req"; _n=`grep -c '^/campaign/$' "$TMP/req"`
          case "$1:$CENA" in
              /campaign/:feita)
                  if [ "$_n" = 1 ]; then echo "<a href='/campaign/go/?r=1'>Ir</a>" > "$TMP/SRC"
                  else echo "<div>Nova campanha em 7 h 59 min</div>" > "$TMP/SRC"; fi ;;
              /campaign/:fim)         echo "<a href='/campaign/go/?r=1'>Ir</a>" > "$TMP/SRC" ;;
              /campaign/go/*)         echo "<a href='/campaign/fight/?r=2'>x</a>" > "$TMP/SRC" ;;
              /campaign/fight/*)      echo "<a href='/campaign/end/?r=3'>x</a>" > "$TMP/SRC" ;;
              /campaign/end/*:feita)  echo "<div>Recompensa recebida</div>" > "$TMP/SRC" ;;
              /campaign/end/*:fim)    echo "<img src='/images/icon/2hit.png' alt=''/> Nova campanha em 7 h 59 min<br/>" > "$TMP/SRC" ;;
              /campaign/:espera)      echo "<div class='center'><img src='/images/icon/2hit.png' alt=''/> Nova campanha em 7 h 38 min<br/><a class='btn'>Atualizar</a></div>" > "$TMP/SRC" ;;
              /campaign/:mudo)        echo "<div>nada</div>$VIVA" > "$TMP/SRC" ;;
              /campaign/:caiu)
                  if [ "$_n" = 1 ]; then echo "<a href='/campaign/end/?r=1'>x</a>" > "$TMP/SRC"
                  else echo "<form action='/?sign_in=1'><input name='pass'/></form>" > "$TMP/SRC"; fi ;;
              /campaign/end/*:caiu)   echo "<div>ok</div>" > "$TMP/SRC" ;;
              /campaign/:semrel)
                  if [ "$_n" = 1 ]; then echo "<a href='/campaign/end/?r=1'>x</a>" > "$TMP/SRC"
                  else echo "<div>outra coisa</div>$VIVA" > "$TMP/SRC"; fi ;;
              /campaign/end/*:semrel) echo "<div>ok</div>" > "$TMP/SRC" ;;
          esac
      }
      campaign_func > "$TMP/saida" 2>&1
      printf 'req=%s' "`wc -l < "$TMP/req" | tr -d ' '`" )
}
check "campanha: em espera le 'Nova campanha em 7 h 38 min' com uma requisicao" "req=1" "`_camp espera`"
_perto "campanha: espera = 7 h 38 min + 1 min" 27540 "$_td10/p/next_campanha"
check "campanha: feita agora, relogio na propria resposta" "req=4" "`_camp fim`"
_perto "campanha: feita agora, volta em 7 h 59 min + 1 min" 28800 "$_td10/p/next_campanha"
check "campanha: feita agora, resposta sem relogio rele a pagina uma vez" "req=5" "`_camp feita`"
_perto "campanha: relida, volta no relogio" 28800 "$_td10/p/next_campanha"
_camp semrel > /dev/null; _perto "campanha: feita sem relogio legivel, as 8h do jogo" 28800 "$_td10/p/next_campanha"
_camp mudo > /dev/null;   _perto "campanha: pagina sem nada volta em 1h" 3600 "$_td10/p/next_campanha"
[ -f "$_td10/p/campanha_sem_relogio.html" ] && ok "campanha: pagina sem relogio guardada" \
                                              || bad "campanha: pagina sem relogio nao foi guardada"
_camp caiu > /dev/null;   _perto "campanha: sessao caiu na releitura volta em 15 min, nao 8h" 900 "$_td10/p/next_campanha"
_r=`( TMP="$_td10/q"; rm -rf "$TMP"; mkdir -p "$TMP"; . "$LIB/crono.sh" > /dev/null 2>&1
      _agora_mais 600 > "$TMP/next_campanha"; campanha_liberada && printf 'futuro=sim ' || printf 'futuro=nao '
      rm -f "$TMP/next_campanha"; campanha_liberada && printf 'sem_leitura=sim' || printf 'sem_leitura=nao' )`
check "campanha: relogio no futuro fecha; sem leitura abre" "futuro=nao sem_leitura=sim" "$_r"

# --- troca
_tr() { ( TMP="$_td10/t"; rm -rf "$TMP"; mkdir -p "$TMP"; . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/trade.sh" > /dev/null 2>&1
          PAGINA_TROCA="$1"
          fetch_page() { printf '%s' "$PAGINA_TROCA" > "$TMP/SRC"; }
          func_trade > /dev/null 2>&1
          [ "`cat "$TMP/last_trade" 2>/dev/null`" = "`date +%Y%m%d`" ] && printf 'marcou' || printf 'aberto' ) ; }
check "troca: prata abaixo da reserva marca o dia (uma olhada por dia)" marcou \
    "`_tr "<img src='/images/icon/silver.png' alt='s'/> 5000"`"
check "troca: pagina que nao veio deixa o dia em aberto" aberto "`_tr ''`"

# --- agenda
_r=`sed -n '/^tarefas_livres() {/,/^}/p' "$LIB/crono.sh" | grep -c 'if caverna_liberada; then\|if campanha_liberada; then'`
check "varredura ociosa: caverna e campanha pelo relogio do jogo" 2 "$_r"
_r=`sed -n '/^start() {/,/^}/p' "$LIB/crono.sh" | grep -c '^    tarefas_livres$'`
check "start(): usa a varredura do ocioso, com os mesmos portoes" 1 "$_r"
# Desde a 3.9.111 a Home e lida uma vez (descanso_ler) e o relogio sai dela.
sed -n '/^descansar() {/,/^}/p' "$LIB/crono.sh" | grep -q 'descanso_ler "$TMP/REST"' && \
sed -n '/^descansar() {/,/^}/p' "$LIB/crono.sh" | grep -q '^ *caverna_aplicar$' \
    && ok "descansar: le o relogio da caverna na pagina inicial que ja baixou" \
    || bad "descansar: nao le o relogio da caverna"

# --- uma varredura completa por minuto
_r=`( TMP="$_td10/s"; rm -rf "$TMP"; mkdir -p "$TMP"; . "$LIB/crono.sh" > /dev/null 2>&1
      load_config() { printf 'VARREDURA'; exit 0; }; espera_interrompivel() { printf 'espera '; }
      # Relogio parado: com o date de verdade o minuto podia virar entre
      # gravar o last_start e o start() ler (falhou assim as 01:3x de 23/10).
      date() { case "$1" in +%Y%m%d%H%M) echo 202610230130 ;; +%S) echo 30 ;; *) command date "$@" ;; esac; }
      date +%Y%m%d%H%M > "$TMP/last_start"; start; printf '| '
      echo 190001010000 > "$TMP/last_start"; start )`
check "start(): segunda chamada no mesmo minuto so espera; minuto novo varre" "espera | VARREDURA" "$_r"

unset -f _perto _agora_mais _rm _cv _camp _tr
rm -rf "$_td10"; unset _td10 _r _MD _MD3 _MENU_T _MENU_H _MENU_P _MENU_0


printf "\n=== 41. Auditoria: coliseu, cura/esquiva, caverna -cv e senha ===\n"
# =============================================================================
#
# Achados da auditoria (13/09), reproduzidos antes de corrigir.

# --- coliseum_start em minuto de evento: o exit 1 do case nao pode matar o worker
_r=`( FUNC_coliseum=y; RUN=-cl; . "$LIB/coliseum.sh" > /dev/null 2>&1
      date() { echo 09:24; }; sleep() { :; }
      coliseum_start > /dev/null 2>&1; printf vivo )`
check "coliseum_start as 09:24 (-cl): o worker continua vivo" vivo "$_r"

# --- cura e esquiva sem teto de 300s (o relogio so anda quando a conta usa)
_r=`grep -c -- '-lt 300' "$LIB/altars.sh" "$LIB/clanfight.sh" "$LIB/clandmg.sh" \
    "$LIB/clancoliseum.sh" "$LIB/flagfight.sh" "$LIB/coliseum.sh" | grep -vc ':0$'`
check "cura/esquiva: nenhum laco de batalha com teto de 300s" 0 "$_r"

# --- modo -cv sem acao na caverna espera antes de voltar ao laco principal
_r=`( RUN=-cv; TMP=\`mktemp -d\`; . "$LIB/cave.sh" > /dev/null 2>&1
      clan_id() { :; }; set_cave_limits() { :; }
      fetch_page() { : > "$TMP/SRC"; }; espera_interrompivel() { printf 'espera %s' "$1"; }
      cave_start 2>/dev/null | tail -n 1; rm -rf "$TMP" )`
check "cave_start sem acao: espera 60s antes de sair" "espera 60" "$_r"

# --- senha fora do argv do curl (lpass=${creds...} e so a leitura do cript_file)
_r=`grep -c '[^l]pass=\${' "$LIB/sls.sh" "$LIB/loginlogoff.sh" "$LIB/session_check.sh" | grep -vc ':0$'`
check "login: senha nunca na linha de comando do curl" 0 "$_r"
# Dois POSTs: o login_autenticar (login e reconexao, desde a 3.9.87) e o
# test_login do setup.
_r=`cat "$LIB/sls.sh" "$LIB/loginlogoff.sh" "$LIB/session_check.sh" | grep -c '"pass@-"'`
check "login: senha pelo stdin nos dois POSTs" 2 "$_r"

# --- codigo morto removido: nada chama o que saiu, e todo modulo listado existe
_r=`sed -n '/^for _lib in/,/^do$/p' "$LIB/sls.sh" | tr ' \\' '\n\n' | grep '\.sh$' \
    | while read -r _m; do [ -f "$LIB/$_m" ] || printf '%s ' "$_m"; done`
check "sls.sh: todo modulo da lista existe" "" "$_r"
_r=`grep -rn -w 'TOYBOX\|server_scheme\|resource_allow\|update_check\|fetch_max_hp\|requer_func\|use_blessing\|conf_allies\|request_update\|script_slogan\|sessao_viva_arquivo\|painel_largura\|estado_cor\|estado_simbolo\|arena_fault\|arena_collFight\|clan_money\|restart_script\|pause_missions_weekend' \
    "$ROOT"/*.sh "$LIB"/*.sh | grep -vc ':[[:space:]]*#'`
check "codigo morto: nenhuma chamada ao que foi removido" 0 "$_r"

# --- start() repetido na janela de um evento sem inscricao so refaz o que venceu
_r=`( TMP=\`mktemp -d\`; CLD=1; . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1
      for _f in load_config clan_id clan_statue cq_antes messages_info \
                descansar func_crono func_sleep cq_ajudar cq_elixir cq_mercador; do eval "$_f() { :; }"; done
      login_logoff() { return 0; }
      for _f in atualiza_agenda use_elixir cq_concluir career_func check_missions specialEvent \
                clanQuests func_trade allies_refresh liga_do_dia; do eval "$_f() { printf '%s ' $_f; }"; done
      stats_liberado() { return 1; }; masmorra_liberada() { return 1; }; arena_liberada() { return 1; }
      liga_fora_da_inscricao() { return 0; }
      campanha_liberada() { return 1; }; caverna_liberada() { return 1; }; check_rewards() { :; }
      echo 190001010000 > "$TMP/last_start"; start; printf '| '
      echo 190001010000 > "$TMP/last_start"; start; rm -rf "$TMP" ) | sed 's/Checklist do cla//' | tr -d '\n'`
check "start() duas vezes seguidas: a segunda so passa pela liga (portao do jogo)" \
    "atualiza_agenda use_elixir cq_concluir career_func check_missions liga_do_dia func_trade specialEvent allies_refresh | liga_do_dia " "$_r"
unset _r


printf "\n=== 42. Menos requisicoes: Home repetida, portoes sem cat, limpezas ===\n"
# =============================================================================
#
# Medido em 13/09 (numa conta): 1.155 voltas ociosas, 641 delas de 15s perto
# das janelas de evento, cada uma pedindo a Home.

# --- descansar: so pula a Home que ELE confirmou viva ha menos de 50s
#
# Casos de "achar que e uma coisa e ser outra": uma luta carimbou o last_ok,
# a Home veio vazia (servidor mudo) ou mostrou o personagem preso na batalha.
# Em todos, a volta seguinte tem de pedir a Home de novo.
_r=`( TMP=\`mktemp -d\`; . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1
      batalha_retomar() { return 1; }; limpar_combate() { :; }; servidor_mudo_marcar() { :; }
      VIVA='<script>jsInterface.event("user=5")</script>'
      fetch_page() { printf 'GET'; printf '%s' "$PAG" > "$TMP/REST"; }
      g() { descansar 2>/dev/null | grep -o GET | tr -d '\n'; }
      m() { printf %s "$1" > "$TMP/.ult_req"; echo $(( \`date +%s\` - $2 )) > "$TMP/.home_ok"; echo $(( \`date +%s\` - $3 )) > "$TMP/last_ok"; }
      PAG="$VIVA"
      m / 10 10;      printf '[home10:%s] '      "\`g\`"
      m / 120 120;    printf '[home120:%s] '     "\`g\`"
      m /arena/ 10 10; printf '[arena10:%s] '    "\`g\`"
      m / 120 5;      printf '[luta_marcou:%s] ' "\`g\`"
      m / -3600 -3600; printf '[relogio_voltou:%s] ' "\`g\`"
      PAG='';                   m / 120 5; printf '[mudo:%s|%s] '  "\`g\`" "\`g\`"
      PAG="$VIVA out_gate_confirm"; batalha_pendente() { return 0; }
                                m / 120 5; printf '[preso:%s|%s] ' "\`g\`" "\`g\`"
      rm -rf "$TMP" )`
check "descansar: pula so a Home confirmada por ele; luta, servidor mudo e batalha presa pedem de novo" \
    "[home10:] [home120:GET] [arena10:GET] [luta_marcou:GET] [relogio_voltou:GET] [mudo:GET|GET] [preso:GET|GET] " "$_r"

# --- ativ_liberada lendo o marcador com read (com e sem quebra de linha)
_r=`( TMP=\`mktemp -d\`; . "$LIB/crono.sh" > /dev/null 2>&1
      ativ_liberada teste 15 && printf 'sem_marcador=liberada ' || printf 'sem_marcador=fechada '
      printf %s "\`date +%s\`" > "$TMP/last_teste"
      ativ_liberada teste 15 && printf 'agora=liberada ' || printf 'agora=fechada '
      echo $(( \`date +%s\` - 901 )) > "$TMP/last_teste"
      ativ_liberada teste 15 && printf 'velho=liberada' || printf 'velho=fechada'; rm -rf "$TMP" )`
check "ativ_liberada: marcador ausente, recente e vencido" "sem_marcador=liberada agora=fechada velho=liberada" "$_r"
grep -q 'cat "\$TMP/last_\$_an"' "$LIB/crono.sh" && bad "ativ_liberada ainda abre um cat por portao" \
    || ok "ativ_liberada: sem processo para ler o marcador"

# --- relogio do aparelho voltou 1h (NTP no Android): marca no futuro nao trava
_r=`( TMP=\`mktemp -d\`; . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1
      . "$LIB/clanid.sh" > /dev/null 2>&1
      f=$(( \`date +%s\` + 3600 ))
      echo $f > "$TMP/last_teste";   ativ_liberada teste 15 && printf 'ativ=abre ' || printf 'ativ=fechada '
      echo $f > "$TMP/last_reconn";  luta_pode_reconectar   && printf 'reconn=abre ' || printf 'reconn=fechada '
      echo $f > "$TMP/last_estatua"; estatua_liberada       && printf 'estatua=abre' || printf 'estatua=fechada'
      rm -rf "$TMP" )`
check "relogio voltou: portoes com marca no futuro abrem" "ativ=abre reconn=abre estatua=abre" "$_r"

# --- relogio do WSL pulou anos para a frente e foi corrigido: os relogios do
# jogo anotados naquela data nao podem fechar caverna/campanha/masmorra/Liga.
_r=`( TMP=\`mktemp -d\`; . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1
      . "$LIB/league.sh" > /dev/null 2>&1
      f=$(( \`date +%s\` + 110000000 )); p=$(( \`date +%s\` + 3600 ))
      echo $f > "$TMP/next_campanha";   campanha_liberada        && printf 'campanha=abre ' || printf 'campanha=fechada '
      echo $f > "$TMP/next_masmorra";   masmorra_liberada        && printf 'masmorra=abre ' || printf 'masmorra=fechada '
      echo $f > "$TMP/league_restauro"; league_restauro_pendente && printf 'liga=espera ' || printf 'liga=livre '
      echo $p > "$TMP/next_masmorra";   masmorra_liberada        && printf 'masmorra1h=abre ' || printf 'masmorra1h=fechada '
      echo $p > "$TMP/league_restauro"; league_restauro_pendente && printf 'liga1h=espera' || printf 'liga1h=livre'
      rm -rf "$TMP" )`
check "relogio adiantado anos: marca de anos adiante abre; relogio de 1h continua valendo" \
    "campanha=abre masmorra=abre liga=livre masmorra1h=fechada liga1h=espera" "$_r"

# --- trava de reconexao: uma so
_r=`grep -c 'FUNC_reconn_min' "$LIB/crono.sh" "$LIB/info.sh" | grep -v ':0$' | wc -l`
check "reconexao: um portao so (luta_pode_reconectar)" 1 "$_r"
sed -n '/^descansar() {/,/^}/p' "$LIB/crono.sh" | grep -q 'luta_pode_reconectar || return 1' \
    && ok "descansar usa o luta_pode_reconectar" || bad "descansar com trava de reconexao propria"

# --- limpezas: nada chama o que saiu
_r=`grep -rn -w 'colors\|check_cave_keypress\|set_config\|SCRIPT_PAUSED\|FUNC_AUTO_UPDATE' \
    "$ROOT"/*.sh "$LIB"/*.sh | grep -vc ':[[:space:]]*#'`
check "limpezas: colors, teclado da caverna e chaves sem leitor fora" 0 "$_r"
_r=`grep -c '^server_url()\|^server_tag()\|^clean_field()' "$ROOT/status.sh"`
check "status.sh: sem as funcoes que ele nao usava" 0 "$_r"
unset _r

printf "\n=== 37. evento especial, relogio voltando, painel, sessao e mana ===\n"
_td7=`mktemp -d`

# Evento especial: sem link de ataque nao pede caminho vazio (= Home), e o
# evento que sumiu da Home nao e repetido na chamada seguinte.
( TMP="$_td7"; . "$LIB/specialevent.sh"
  fetch_page() { printf '%s ' "${1:-VAZIO}" >> "$TMP/req"
      case "$1" in /) printf '%s' "$_home" > "$TMP/SRC" ;; *) : > "$TMP/SRC" ;; esac; }
  _home="<div class='shb_text'><a href='/fault/?x=1'>ev</a></div>"
  specialEvent
  _home="<div>sem evento</div>"
  specialEvent ) > /dev/null 2>&1
check "evento especial: sem link vazio e sem repetir evento que acabou" "/ /fault/?x=1 / " "`cat "$_td7/req"`"

# evento_espera: inicio de evento 2h adiante (relogio voltou) nao prende.
# O descansar falso encerra o teste na 3a volta em vez de esperar.
( TMP="$_td7"; . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1
  sleep() { :; }
  descansar() { _n=$(( ${_n:-0} + 1 )); [ "$_n" -ge 3 ] && { printf 'espera' >> "$TMP/marca"; exit 0; }; }
  echo $(( `date +%s` + 7200 )) > "$TMP/em_evento"
  evento_espera; printf 'livre ' >> "$TMP/marca"
  date +%s > "$TMP/em_evento"
  evento_espera; printf 'nao_esperou' >> "$TMP/marca" ) > /dev/null 2>&1
check "relogio voltou: evento_espera libera; evento de agora ainda espera" "livre espera" "`cat "$_td7/marca"`"

# Cache da pagina do cla e das missoes com carimbo no futuro: le de novo.
_r=`( TMP="$_td7"; CLD=999; . "$LIB/info.sh" > /dev/null 2>&1
      . "$LIB/clanid.sh" > /dev/null 2>&1; . "$LIB/clanquest.sh" > /dev/null 2>&1
      fetch_page() { echo "$1" >> "$TMP/req2"; echo pagina > "${2:-$TMP/SRC}"; }
      echo x > "$TMP/CLANPG"; _CLAN_TS=$(( \`date +%s\` + 3600 )); clan_pagina
      echo x > "$TMP/CQUEST"; _CQ_TS=$(( \`date +%s\` + 3600 ))
      printf %s "/clan/999/quest/" > "$TMP/.ult_req"; cq_pagina
      wc -l < "$TMP/req2" | tr -d ' ' ) 2>/dev/null`
check "relogio voltou: cache do cla e das missoes nao vale" 2 "$_r"

# worker_vivo: PID vivo de outro programa nao e worker.
if [ -r "/proc/$$/cmdline" ]; then
    _r=`( SLSDIR="$ROOT"; . "$LIB/contas.sh"; worker_vivo $$ && echo vivo || echo outro )`
    check "worker_vivo: PID de outro processo nao conta como conta viva" outro "$_r"
fi

# Painel supervisionando: worker morto e relancado uma vez, nao a cada volta.
# Com /proc, o PID gravado e o deste teste: vivo, mas nao e worker.
mkdir -p "$_td7/h/.sls/status" "$_td7/h/.sls/BR_Ze"
printf '1|Ze|x\n' > "$_td7/acc.conf"
_v=999999999; [ -r "/proc/$$/cmdline" ] && _v=$$
echo "$_v" > "$_td7/h/.sls/status/BR_Ze.pid"
echo running   > "$_td7/h/.sls/status/BR_Ze.status"
for _v in 1 2; do
    ( HOME="$_td7/h"; SLSDIR="$ROOT"; STATUS_DIR="$_td7/h/.sls/status"
      ACCOUNTS_FILE="$_td7/acc.conf"; . "$LIB/contas.sh"
      clean_field() { printf '%s' "$1"; }
      launch_worker() { echo L >> "$_td7/lancou"; }
      PANEL_SUPERVISE=1; PANEL_ONCE=1; PANEL_DRAW=0; SLS_EMOJI=0; SLS_COLS=60
      export HOME SLSDIR STATUS_DIR ACCOUNTS_FILE PANEL_SUPERVISE PANEL_ONCE PANEL_DRAW SLS_EMOJI SLS_COLS
      . "$LIB/panel.sh"; painel_loop ) > /dev/null 2>&1
done
check "painel: worker morto relancado no maximo 1x por minuto" 1 "`wc -l < "$_td7/lancou" | tr -d ' '`"

# is_logged_in: o rodape do jogo decide; link para /user nao prova sessao.
_ROD0='jsInterface.event("user=0;level=0");'
_ROD1='jsInterface.event("user=12345;level=43");'
_r=`( . "$LIB/session_check.sh"
      is_logged_in "<title>Error 404</title><a href='/user/1'>x</a>$_ROD0" && printf 'anon=sim ' || printf 'anon=nao '
      is_logged_in "<div>ok</div>$_ROD1" && printf 'logada=sim ' || printf 'logada=nao '
      is_logged_in "<a href='/user/12345'>perfil</a>" && printf 'so_link=sim' || printf 'so_link=nao' )`
check "is_logged_in: 404 anonimo e link solto nao sao sessao" "anon=nao logada=sim so_link=nao" "$_r"

# hpmp: mana dentro de <span> (como o HP).
printf '%s' "<img src='/images/icon/health.png' alt='hp'/> <span class='white'>6531</span> | <img src='/images/icon/mana.png' alt='mp'/> <span class='dred'>809</span><div class='clr'></div>" > "$_td7/SRC"
_r=`( TMP="$_td7"; . "$LIB/info.sh" > /dev/null 2>&1; hpmp -now; echo "$NOWHP/$NOWMP" )`
check "hpmp: le HP e mana com <span>" "6531/809" "$_r"

_r=`( . "$LIB/info.sh" > /dev/null 2>&1
      for _x in 54.300 "1,234" 396 408,1M 3,4K; do printf '%s ' "$(valor_num "$_x")"; done )`
check "valor_num: milhar sem sufixo e decimal com sufixo" "54300 1234 396 408100000 3400 " "$_r"

rm -rf "$_td7"; unset _td7 _ROD0 _ROD1 _v

printf "\n=== 43. escolha de conta, senha, identidade do PID, logs e painel unico ===\n"
_td8=`mktemp -d`

# setup.sh: comentario com "|" e linha sem nome nao deslocam a numeracao.
printf '# srv|usuario|cred\n1|Ana|YQ==\n1||x\n1|Bia|Yg==\n' > "$_td8/acc.conf"
_r=`( SLSDIR="$ROOT"; ACCOUNTS_FILE="$_td8/acc.conf"; . "$LIB/contas.sh"
      eval "$(sed -n '/^escolher_conta() {/,/^}/p' "$ROOT/setup.sh")"
      sleep() { :; }
      echo 2 | { escolher_conta > /dev/null; printf '%s ' "$user|$encoded"; }
      echo 3 | { escolher_conta > /dev/null || printf 'invalido '; }
      printf '' | { escolher_conta > /dev/null || printf 'cancelou'; } )`
check "setup: numero da tela e a conta certa" "Bia|Yg== invalido cancelou" "$_r"

# Credencial: "\", espacos e "&pass=" dentro da senha chegam intactos.
_cr='login=Ze&pass= a\nb\c&pass=%+ '
for _f in lib/loginlogoff.sh setup.sh; do
    _r=`( creds="$_cr"; _la_creds="$_cr"; eval "$(grep -E '^ *(luser|lpass)=' "$ROOT/$_f")"; printf '[%s][%s]' "$luser" "$lpass" )`
    check "senha com barra invertida e espacos: $_f" '[Ze][ a\nb\c&pass=%+ ]' "$_r"
done

if [ -r "/proc/$$/cmdline" ]; then
    # worker_vivo com a pasta: so a conta dona do PID; sls.sh antigo sem pasta vale.
    sh -c 'sleep 30; :' "$_td8/lib/sls.sh" -boot "$_td8/h/.sls/BR_Ana" & _p1=$!
    sh -c 'sleep 30; :' "$_td8/lib/sls.sh" -boot & _p2=$!
    sh -c 'sleep 30; :' "$_td8/play.sh" & _p3=$!
    sleep 1
    _r=`( SLSDIR="$ROOT"; . "$LIB/contas.sh"
          worker_vivo $_p1 "$_td8/h/.sls/BR_Ana" && printf 'dona ' || printf 'nao '
          worker_vivo $_p1 "$_td8/h/.sls/BR_An" && printf 'outra ' || printf 'nao '
          worker_vivo $_p2 "$_td8/h/.sls/BR_Ana" && printf 'antigo' || printf 'nao' )`
    check "worker_vivo: PID de outra conta nao conta" "dona nao antigo" "$_r"

    # setup: remover a conta derruba o worker dela.
    mkdir -p "$_td8/h/.sls/status"
    sh -c 'sleep 30; :' "$_td8/lib/sls.sh" -boot "$_td8/h/.sls/BR_Ana" & _p4=$!
    sleep 1
    echo $_p4 > "$_td8/h/.sls/status/BR_Ana.pid"
    printf '1|Ana|YQ==\n1|Bia|Yg==\n' > "$_td8/acc2.conf"
    ( HOME="$_td8/h"; SLSDIR="$ROOT"; ACCOUNTS_FILE="$_td8/acc2.conf"; . "$LIB/contas.sh"
      eval "$(sed -n '/^escolher_conta() {/,/^}/p;/^remove_account() {/,/^}/p' "$ROOT/setup.sh")"
      sleep() { :; }; clear() { :; }
      printf '1\ny\nn\n' | remove_account ) > /dev/null 2>&1
    sleep 1
    case "`cut -d' ' -f3 /proc/$_p4/stat 2>/dev/null`" in ''|Z) _r=morto ;; *) _r=vivo ;; esac
    [ -f "$_td8/h/.sls/status/BR_Ana.pid" ] && _r="$_r pid" || _r="$_r sem_pid"
    _r="$_r `cut -d'|' -f2 "$_td8/acc2.conf"`"
    kill $_p4 2>/dev/null; wait $_p4 2>/dev/null
    check "setup: remover conta derruba o worker dela" "morto sem_pid Bia" "$_r"

    # play.sh novo encerra o painel anterior, e so se o PID for de um play.sh.
    _bloco=$(sed -n '/^_orq=\$(cat/,/^unset _orq/p' "$ROOT/play.sh")
    ( STATUS_DIR="$_td8"; echo $_p3 > "$_td8/orchestrator.pid"; eval "$_bloco"
      echo $_p1 > "$_td8/orchestrator.pid"; eval "$_bloco" )
    sleep 1
    _r=""
    for _v in $_p3 $_p1; do
        case "`cut -d' ' -f3 /proc/$_v/stat 2>/dev/null`" in ''|Z) _r="$_r morto" ;; *) _r="$_r vivo" ;; esac
    done
    kill $_p1 $_p2 $_p3 2>/dev/null; wait $_p1 $_p2 $_p3 2>/dev/null
    check "play.sh: encerra o painel anterior, nao outro processo" " morto vivo" "$_r"
fi

# Logs: copia e esvazia no lugar; quem escreve com ">>" continua no sls.log.
_r=`( TMP="$_td8"; eval "$(sed -n '/^rotate_log() {/,/^}/p' "$LIB/sls.sh")"
      head -c 5242881 /dev/zero > "$TMP/sls.log"; echo erro > "$TMP/ERROR_DEBUG"
      exec 9>> "$TMP/sls.log"
      rotate_log; printf 'x' >&9
      printf '%s %s ' "$(cat "$TMP/sls.log")" "$(wc -c < "$TMP/sls.log.1" | tr -d ' ')"
      [ -f "$TMP/ERROR_DEBUG.1" ] && printf 'rodou' || printf 'ficou' )`
check "rotate_log: sls.log segue recebendo apos a rotacao" "x 1048576 ficou" "$_r"

# stop.sh sem nada para parar, fora do Termux: sai com 0 (o README encadeia com &&).
mkdir -p "$_td8/vazio"
( HOME="$_td8/vazio" sh "$ROOT/stop.sh" ) > /dev/null 2>&1
check "stop.sh: sai com 0 fora do Termux" 0 "$?"

rm -rf "$_td8"; unset _td8 _cr _f _p1 _p2 _p3 _bloco _p4

printf "\n=== 44. stop.sh com PID reciclado, painel por conta e marca de batalha ===\n"
_td9=`mktemp -d`

# Marca de batalha: muito no futuro (relogio voltou) nao vale; ajuste pequeno vale.
_r=`( TMP="$_td9"; LUTA_TETO_MIN=30; . "$LIB/info.sh" > /dev/null 2>&1
      _ag=\`date +%s\`
      for _d in 7200 60 -60 -3600; do
          echo "king $(( _ag + _d ))" > "$TMP/batalha"
          batalha_pendente && printf 'sim ' || printf 'nao '
      done )`
check "batalha_pendente: marca no futuro alem do teto nao vale" "nao sim sim nao " "$_r"

if [ -r "/proc/$$/cmdline" ]; then
    # stop.sh: orchestrator.pid reciclado para outro processo nao morre.
    sh -c 'sleep 30; :' "$_td9/outro.sh" & _p1=$!
    mkdir -p "$_td9/vazio/.sls/status"
    echo $_p1 > "$_td9/vazio/.sls/status/orchestrator.pid"
    ( HOME="$_td9/vazio" sh "$ROOT/stop.sh" ) > /dev/null 2>&1
    case "`cut -d' ' -f3 /proc/$_p1/stat 2>/dev/null`" in ''|Z) _r=morto ;; *) _r=vivo ;; esac
    check "stop.sh: PID do orchestrator reciclado nao e morto" vivo "$_r"

    # Painel: PID gravado e o worker de OUTRA conta -> relanca esta.
    sh -c 'sleep 30; :' "$_td9/lib/sls.sh" -boot "$_td9/h/.sls/BR_Ana" & _p2=$!
    sleep 1
    mkdir -p "$_td9/h/.sls/status" "$_td9/h/.sls/BR_Ze"
    printf '1|Ze|x\n' > "$_td9/acc.conf"
    echo $_p2 > "$_td9/h/.sls/status/BR_Ze.pid"
    echo running > "$_td9/h/.sls/status/BR_Ze.status"
    ( HOME="$_td9/h"; SLSDIR="$ROOT"; STATUS_DIR="$_td9/h/.sls/status"
      ACCOUNTS_FILE="$_td9/acc.conf"; . "$LIB/contas.sh"
      launch_worker() { echo L >> "$_td9/lancou"; }
      PANEL_SUPERVISE=1; PANEL_ONCE=1; PANEL_DRAW=0; SLS_EMOJI=0; SLS_COLS=60
      export HOME SLSDIR STATUS_DIR ACCOUNTS_FILE PANEL_SUPERVISE PANEL_ONCE PANEL_DRAW SLS_EMOJI SLS_COLS
      . "$LIB/panel.sh"; painel_loop ) > /dev/null 2>&1
    check "painel: PID que virou worker de outra conta e relancado" 1 "`cat "$_td9/lancou" 2>/dev/null | wc -l | tr -d ' '`"
    kill $_p1 $_p2 2>/dev/null; wait $_p1 $_p2 2>/dev/null
fi

rm -rf "$_td9"; unset _td9 _p1 _p2

printf "\n=== 45. Liga sem pocao, link vazio ou repetido, uninstall por atalho e config CRLF ===\n"
# =============================================================================
_td10=`mktemp -d`

# Liga com todos os adversarios mais fortes: ataca o ultimo e busca a pocao.
_liga45() { # pocao(sim|nao) -> "lutas=N alvos=A,B pocao=N POTION=S|N"
    ( TMP="$_td10/c$1"; URL="http://jogo"; export TMP URL; mkdir -p "$TMP"
      echo 3 > "$TMP/sim_lutas"; echo "$1" > "$TMP/sim_pocao"; : > "$TMP/sim_req"
      . "$LIB/league.sh" > /dev/null 2>&1
      load_config() { :; }; checkQuest() { return 1; }; get_config() { echo 5; }
      player_stats() { echo 3165; }; sleep() { :; }
      fetch_page() {
          _d="${2:-$TMP/SRC}"; echo "$1" >> "$TMP/sim_req"; _n=`cat "$TMP/sim_lutas"`
          case "$1" in
              /league/)
                  _p="Lutas disponiveis: <b>$_n</b><br/>"
                  for _e in 302 312 322 332; do
                      _p="$_p<a href='/league/fight/$_e/?r=77'></a><b>$_e. Nome</b><br/>Força: 9999<br/>Saúde: 50<br/>Agilidade: 50<br/>Proteção: 50<br/><a class='btn' href='/league/fight/$_e/?r=77'>Atacar</a>"
                  done
                  printf '%s\n' "$_p" > "$_d" ;;
              /league/fight/*)
                  [ "$_n" -gt 0 ] && echo $((_n - 1)) > "$TMP/sim_lutas"
                  _p="resultado"
                  [ "`cat "$TMP/sim_pocao"`" != nao ] && _p="$_p <a href='/league/potion/?r=5'>pocao</a>"
                  printf '%s\n' "$_p" > "$_d" ;;
              /league/potion/*) : > "$_d"; [ "`cat "$TMP/sim_pocao"`" != rede ] ;;
              *) : > "$_d" ;;
          esac
      }
      league_play > "$TMP/saida" 2>&1
      _alvos=`grep '^/league/fight/' "$TMP/sim_req" | cut -d/ -f4 | tr '\n' ',' | sed 's/,$//'`
      [ -f "$TMP/POTION" ] && _pt=S || _pt=N
      printf 'lutas=%s alvos=%s pocao=%s POTION=%s' "`grep -c '^/league/fight/' "$TMP/sim_req"`" \
          "$_alvos" "`grep -c '^/league/potion/' "$TMP/sim_req"`" "$_pt" )
}
check "Liga sem pocao: ataca o ultimo e sai, sem luta forcada" "lutas=1 alvos=332 pocao=0 POTION=N" "`_liga45 nao`"
check "Liga com pocao: usa e ataca o 1o" "lutas=2 alvos=332,302 pocao=1 POTION=N" "`_liga45 sim`"
check "Liga: pocao sem resposta avisa rede e sai" "lutas=1 alvos=332 pocao=1 POTION=N rede" \
    "`_liga45 rede; grep -q 'A pocao nao respondeu' "$_td10/crede/saida" && printf ' rede'`"
unset -f _liga45

_r=$( TMP="$_td10/fp"; mkdir -p "$TMP"; . "$LIB/info.sh" > /dev/null 2>&1
      run_curl_exec() { echo "$1" >> "$TMP/curl"; echo home; }
      SLS_PACING=0; echo velho > "$TMP/SRC"; echo /arena/ > "$TMP/.ult_req"; echo / > "$TMP/pagina"
      fetch_page "" && printf 'ok ' || printf 'falhou '
      [ -s "$TMP/SRC" ] && printf 'sujo ' || printf 'vazio '
      [ -f "$TMP/curl" ] && printf 'pediu' || printf 'nao_pediu'
      grep -q 'sem link (depois de /arena/)' "$TMP/ERROR_DEBUG" && printf ' origem' )
check "fetch_page sem link: nao pede a Home, esvazia a pagina e diz a origem" "falhou vazio nao_pediu origem" "$_r"

# Nenhum "grep -o" de link (?r=) ou de HP maximo ("(N)") sem escolher UMA
# linha, em qualquer forma: `...`, $(...), "> ARQUIVO", "if grep -o",
# com ou sem outros comandos no pipe e com continuacao de linha.
# Contar (wc -l, grep -c) e testar (grep -q) nao pedem uma linha so.
# A lista do check.sh (_ck_l=) tambem nao: o _ck_link tira dela um link so.
_soltos=$(awk '
    FNR == 1 { buf = "" }
    /^[ \t]*#/ { next }
    {
        l = $0
        if (buf != "") l = buf " " l
        if (l ~ /\\$/) { buf = substr(l, 1, length(l) - 1); next }
        buf = ""
    }
    l ~ /grep -o/ && (l ~ /r\[=\]|r=/ || l ~ /\(\[0-9\]\+\)/) {
        if (l ~ /head -n ?1|tail -n ?1|sed -n .?1p|sed -n "\$[{]?[a-z_]+[}]?p|wc -l|grep -c|grep -q|_ck_l=/) next
        f = FILENAME; sub(/.*\//, "", f); printf "%s:%s ", f, FNR
    }' "$LIB"/*.sh)
check "grep -o de link ou HP maximo sempre com uma linha so" "" "$_soltos"
grep -q 'access_link:-/coliseum/' "$LIB/coliseum.sh" \
    && ok "coliseu: espera com link vazio pede o coliseu, nao a Home" \
    || bad "coliseu: espera com link vazio ainda pede a Home"

# Link repetido na pagina: um clique com uma URL so; apply_event sem eco.
_r=$( TMP="$_td10/ck"; mkdir -p "$TMP"; . "$LIB/check.sh" > /dev/null 2>&1
      FUNC_check_rewards=y
      fetch_page() { echo "[$1]" >> "$TMP/pedidos"
          case "$1" in
              /relic/reward/) echo "<a href='/relic/reward/1/?r=9'>x</a> <a href='/relic/reward/1/?r=9'>y</a>" > "$TMP/SRC" ;;
              /king/) echo "<a href='/king/enterGame/?r=4'>a</a> <a href='/king/enterGame/?r=4'>b</a>" > "$TMP/SRC" ;;
          esac; }
      check_rewards > /dev/null; apply_event king > "$TMP/saida"
      printf '%s|%s' "`tr '\n' ' ' < "$TMP/pedidos"`" "`cat "$TMP/saida"`" )
check "link repetido: relíquia e evento clicam uma URL so" \
    "[/relic/reward/] [/relic/reward/1/?r=9] [/relic/reward/] [/king/] [/king/enterGame/?r=4] |Applied for battle" "$_r"

# uninstall.sh por atalho: rm/pkill falsos registram o que seria apagado.
mkdir -p "$_td10/bin" "$_td10/fake" "$_td10/home/.sls"
ln -s "$ROOT/uninstall.sh" "$_td10/bin/sls-remover"
for _b in rm pkill sleep du termux-wake-unlock; do
    printf '#!/bin/sh\necho "%s $*" >> "%s"\n' "$_b" "$_td10/apagou" > "$_td10/fake/$_b"
    chmod +x "$_td10/fake/$_b"
done
echo REMOVER | ( HOME="$_td10/home" PATH="$_td10/fake:$PATH" sh "$_td10/bin/sls-remover" ) > /dev/null 2>&1
grep -q "rm -rf $_td10/bin" "$_td10/apagou" 2>/dev/null && _r=apagaria || _r=recusou
check "uninstall.sh por atalho: nao apaga a pasta do atalho" recusou "$_r"

_r=$( TMP="$_td10/cfg"; mkdir -p "$TMP"; . "$LIB/function.sh" > /dev/null 2>&1
      printf 'FUNC_trade=n\r\nALLIES=4\r\n' > "$TMP/config.cfg"
      load_config; printf '%s %s' "$FUNC_trade" "`get_config ALLIES`" )
check "config.cfg salvo no Windows: valores valem" "n 4" "$_r"

rm -rf "$_td10"; unset _td10 _b

printf "\n=== 46. painel em tabela: HP em percentual e barras alinhadas ===\n"
# =============================================================================
_td11=`mktemp -d`
mkdir -p "$_td11/.sls/status"
_ag=`date +%s`
for _c in "u1|Alfa|65312|71000" "u2|Beta Clã|12000|57000" "u3|Gama|900|"; do
    IFS='|' read -r _u _n _h _m <<EOF
$_c
EOF
    printf '1|%s|x\n' "$_u" >> "$_td11/acc.conf"
    mkdir -p "$_td11/.sls/BR_$_u"
    printf '%s|%s|10|320/980|42|1.564|95,8M|%s|%s\n' "$_n" "$_h" "$_ag" "$_m" > "$_td11/.sls/BR_$_u/stats"
    echo running > "$_td11/.sls/status/BR_$_u.status"; echo $$ > "$_td11/.sls/status/BR_$_u.pid"
    echo "$_ag" > "$_td11/.sls/BR_$_u/last_ok"
done
_ESC=$(printf '\033')
for _modo in 1 2; do
    for _c in 56 100; do
        ( HOME="$_td11"; SLSDIR="$ROOT"; STATUS_DIR="$_td11/.sls/status"; ACCOUNTS_FILE="$_td11/acc.conf"
          worker_vivo() { kill -0 "$1"; }
          PANEL_SUPERVISE=1; PANEL_ONCE=1; PANEL_DRAW=1; SLS_EMOJI="$_modo"; SLS_COLS="$_c"
          export HOME SLSDIR STATUS_DIR ACCOUNTS_FILE PANEL_SUPERVISE PANEL_ONCE PANEL_DRAW SLS_EMOJI SLS_COLS
          . "$LIB/panel.sh"; painel_loop ) 2>/dev/null | sed "s/${_ESC}\[[0-9;]*m//g" > "$_td11/p.txt"
        # Coluna (nao byte) de cada barra nas linhas das contas: uma so
        # posicao para todas, com acento e emoji no nome.
        _pos=`grep -E 'Alfa|Beta|Gama' "$_td11/p.txt" | LC_ALL=C awk '{
            s = ""; col = 0; n = length($0)
            for (i = 1; i <= n; i++) {
                c = substr($0, i, 1)
                if (substr($0, i, 3) == "\342\224\202") s = s col ","
                if (c >= "\200" && c < "\300") continue
                col += (c >= "\360" && c < "\370") ? 2 : 1
            }
            if (s != "") print s }' | sort -u | wc -l | tr -d ' '`
        _hp=`grep -E 'Alfa|Beta|Gama' "$_td11/p.txt" | grep -oE '(92%|21%|900)' | tr '\n' ' '`
        check "painel (modo $_modo, $_c col): barras na mesma coluna e HP em %" "1 92% 21% 900 " "$_pos $_hp"
    done
done
rm -rf "$_td11"; unset _td11 _ag _c _u _n _h _m _modo _pos _hp

printf "\n=== 47. pagina que nao respondeu nao conta como feito ===\n"
# =============================================================================
_td12=`mktemp -d`

# Aliados: a pagina do cla nao responde, ou a do perfil de um ID e cortada.
_al47() { # com_lista_antiga(sim|nao|cortada) -> "lista|rc"
    ( TMP="$_td12/al$1"; URL="http://jogo"; CLD=999; HOME="$_td12/h$1"; export TMP URL CLD HOME; rm -rf "$TMP" "$HOME"; mkdir -p "$TMP" "$HOME/.sls"
      SLS_PACING=0; . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/allies.sh" > /dev/null 2>&1
      [ "$1" = sim ] && printf 'Amigo_Um\nMembro_Cla\n' > "$TMP/aliados.txt" && cp "$TMP/aliados.txt" "$TMP/allies.txt"
      [ "$1" = cortada ] && printf 'Amigo_Velho\nMembro_Cla\n' > "$TMP/aliados.txt" && cp "$TMP/aliados.txt" "$TMP/allies.txt"
      [ "$1" = cortada ] && echo 'j|5' > "$HOME/.sls/aliados_BR.conf"
      MODO="$1"
      run_curl_exec() { case "$1" in
          */user/5/) echo "<title>Amigo Um</title><a href='/user/5?show=might'>Poder</a>"
                     [ "$MODO" = cortada ] && return 56 ;;
          */clan/999) [ "$MODO" = cortada ] && echo "<a href='/user/9/'><img src='/r.png' alt=''/>Membro Cla, <span class='white'>Soldado</span>" ;;
          *) : ;; esac; return 0; }
      # Como o time_exit real: so o curl 28 conta como falha.
      time_exit() { wait "$!" 2>/dev/null; [ $? = 28 ] && return 1; return 0; }
      aliados_montar 1 > /dev/null 2>&1; _rc=$?
      printf '%s|%s' "`tr '\n' ' ' < "$TMP/allies.txt" | sed 's/ $//'`" "$_rc" )
}
check "aliados: cla sem resposta mantem a lista com o cla" "Amigo_Um Membro_Cla|1" "`_al47 sim`"
check "aliados: sem lista anterior e sem resposta, nova tentativa" "|1" "`_al47 nao 2>/dev/null`"
check "aliados: perfil de um ID cortado (curl 56) mantem a lista" "Amigo_Velho Membro_Cla|1" "`_al47 cortada`"

# Masmorra: um golpe e depois a rede cai -> nao conta como feita.
_r=$( TMP="$_td12/ms"; CLD=999; export TMP CLD; mkdir -p "$TMP"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/clanid.sh" > /dev/null 2>&1
      sleep() { :; }
      fetch_page() { case "$1" in
          /clandungeon/?close) echo "<a href='/clandungeon/attack/?r=1'>Golpe</a>" > "$2" ;;
          /clandungeon/attack/*)
              if [ -f "$TMP/deu" ]; then : > "$2"; return 1; fi
              : > "$TMP/deu"; echo "<a href='/clandungeon/attack/?r=2'>Golpe</a>" > "$2" ;;
          esac; }
      clanDungeon > /dev/null 2>&1 && printf 'feita' || printf 'adiada' )
check "masmorra: rede caiu com golpe disponivel -> adiada, nao 8h" "adiada" "$_r"

# Liga: releitura sem resposta nao confirma a coleta.
_r=$( TMP="$_td12/lg"; export TMP; mkdir -p "$TMP"; . "$LIB/league.sh" > /dev/null 2>&1
      fetch_page() { case "$1" in
          /league/) if [ -f "$TMP/clicou" ]; then : > "${2:-$TMP/SRC}"; return 1; fi
                    echo "<a href='/league/takeReward/?r=7'>Pegar</a>" > "${2:-$TMP/SRC}" ;;
          *) : > "$TMP/clicou"; echo ok > "$TMP/SRC" ;;
          esac; }
      league_collect_reward > /dev/null 2>&1 && printf 'confirmada' || printf 'pendente' )
check "liga: releitura sem resposta deixa a recompensa pendente" "pendente" "$_r"

# Liga: sem a forca do personagem, nenhuma luta (nem pocao).
_r=$( TMP="$_td12/lf"; URL="http://jogo"; export TMP URL; mkdir -p "$TMP"; : > "$TMP/req"
      . "$LIB/league.sh" > /dev/null 2>&1
      load_config() { :; }; checkQuest() { return 1; }; player_stats() { :; }; sleep() { :; }
      fetch_page() { echo "$1" >> "$TMP/req"
          printf '%s\n' "Lutas disponiveis: <b>3</b><a href='/league/fight/302/?r=1'></a>Força: 50<br/>" > "${2:-$TMP/SRC}"; }
      league_play > "$TMP/saida" 2>&1
      printf 'lutas=%s aviso=%s' "`grep -c '/league/fight/\|/league/potion/' "$TMP/req"`" "`grep -c 'Forca do personagem nao lida' "$TMP/saida"`" )
check "liga: forca nao lida -> nenhuma luta nesta passagem" "lutas=0 aviso=1" "$_r"

# Missoes do cla: releitura entre cliques (nonce novo) e confirmacao.
_cq47() { # take(ok|falha) -> "pedidos|rc"
    ( TMP="$_td12/cq$1"; CLD=777; export TMP CLD; rm -rf "$TMP"; mkdir -p "$TMP"; : > "$TMP/req"
      . "$LIB/clanquest.sh" > /dev/null 2>&1
      clan_id() { :; }; MODO="$1"
      fetch_page() { echo "$1" >> "$TMP/req"; _d="${2:-$TMP/SRC}"
          case "$1" in
              */quest/) _p=""
                  [ -f "$TMP/t1" ] || _p="$_p<a href='/clan/777/quest/take/1/?r=1'>x</a>"
                  [ -f "$TMP/t2" ] || _p="$_p<a href='/clan/777/quest/take/2/?r=$(( $(wc -l < "$TMP/req") ))'>x</a>"
                  echo "<html>$_p</html>" > "$_d" ;;
              */take/1/*) [ "$MODO" = ok ] || { : > "$_d"; return 1; }; : > "$TMP/t1"; echo ok > "$_d" ;;
              */take/2/*) [ "$MODO" = ok ] || { : > "$_d"; return 1; }; : > "$TMP/t2"; echo ok > "$_d" ;;
          esac; }
      cq_tomar liga > /dev/null 2>&1; _rc=$?
      printf '%s|%s' "`sed 's,^/clan/777/quest/$,Q,; s,/clan/777/quest/,,' "$TMP/req" | tr '\n' ' ' | sed 's/ $//'`" "$_rc" )
}
check "missao do cla: rele entre as duas tomadas e usa o nonce novo" \
    "Q take/1/?r=1 Q take/2/?r=3 Q|0" "`_cq47 ok`"
check "missao do cla: pedido que falhou nao conta como tomada" \
    "Q take/1/?r=1 Q take/2/?r=3 Q|1" "`_cq47 falha`"

# Sabio: o bau 2 e procurado na lista de missoes relida, nao na resposta do bau 1.
_r=$( TMP="$_td12/sb"; export TMP; mkdir -p "$TMP"; : > "$TMP/req"; . "$LIB/check.sh" > /dev/null 2>&1
      FUNC_collect_mission_rewards=y
      fetch_page() { echo "$1" >> "$TMP/req"; case "$1" in
          /quest/) echo "<a href='/quest/openChest/1/?r=1'>a</a><a href='/quest/openChest/2/?r=1'>b</a><a href='/quest/end/3?r=1'>c</a>" > "$TMP/SRC" ;;
          *) echo "resultado" > "$TMP/SRC" ;; esac; }
      check_missions > /dev/null 2>&1
      grep -c 'openChest/2\|/quest/end/3' "$TMP/req" )
check "sabio: os dois baus e a missao na mesma passagem" "2" "$_r"

# Troca: clique sem resposta nao marca o dia.
_r=$( TMP="$_td12/tr"; export TMP; mkdir -p "$TMP"; . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/trade.sh" > /dev/null 2>&1
      fetch_page() { case "$1" in
          /trade/exchange) echo "<img src='/images/icon/silver.png' alt='s'/> 999,9M <a href='/trade/exchange/gold/100?r=4'>x</a>" > "$TMP/SRC" ;;
          *) : > "$TMP/SRC"; return 1 ;; esac; }
      func_trade > /dev/null 2>&1
      [ -f "$TMP/last_trade" ] && printf 'marcou' || printf 'em_aberto' )
check "troca: clique sem resposta deixa o dia em aberto" "em_aberto" "$_r"

# Estatua: releitura sem resposta nao diz "ativado".
_r=$( TMP="$_td12/es"; CLD=999; FUNC_clan_statue=y; export TMP CLD; mkdir -p "$TMP"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/clanid.sh" > /dev/null 2>&1
      clan_lider() { return 0; }
      fetch_page() { echo "$1" >> "$TMP/req"; case "$1" in
          */built/) if [ -f "$TMP/clicou" ]; then : > "$2"; return 1; fi
                    echo "<a href='/clan/999/built/?silverUpgrade=true&r=3'>p</a><a href='/clan/999/built/?goldUpgrade=true&r=2'>o</a>" > "$2" ;;
          *) : > "$TMP/clicou"; echo ok > "$2" ;; esac; }
      clan_statue > "$TMP/saida" 2>&1
      printf 'ativado=%s marcou=%s' "`grep -c 'ativado' "$TMP/saida"`" "`[ -f "$TMP/last_estatua" ] && echo sim || echo nao`" )
check "estatua: releitura sem resposta nao anuncia bonus nem espera 6h" "ativado=0 marcou=nao" "$_r"

# Campanha: clique e releitura sem resposta voltam em 15 min, nao em 8h.
_r=$( TMP="$_td12/cp"; export TMP; mkdir -p "$TMP"; : > "$TMP/req"
      . "$LIB/crono.sh" > /dev/null 2>&1; . "$LIB/campaign.sh" > /dev/null 2>&1
      fetch_page() { echo "$1" >> "$TMP/req"
          if [ "`grep -c . "$TMP/req"`" = 1 ]; then echo "<a href='/campaign/go/?r=1'>Ir</a>" > "$TMP/SRC"
          else : > "$TMP/SRC"; return 1; fi; }
      campaign_func > /dev/null 2>&1
      echo $(( `cat "$TMP/next_campanha"` - `date +%s` )) )
case "$_r" in 89[0-9]|900) ok "campanha: duas falhas voltam em 15 min ($_r s)" ;;
              *) bad "campanha: duas falhas agendaram $_r s (esperado ~900)" ;; esac

rm -rf "$_td12"; unset _td12 _r
unset -f _al47 _cq47

printf "\n=== 48. servidor mudo: varredura em espera, codigo do erro no painel ===\n"
# =============================================================================
_td13=`mktemp -d`

_tl48() { # last_rede last_ok -> atividades chamadas
    ( TMP="$_td13/tl"; CLD=1; export TMP CLD; rm -rf "$TMP"; mkdir -p "$TMP"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1
      [ -n "$1" ] && echo "$1" > "$TMP/last_rede"
      [ -n "$2" ] && echo "$2" > "$TMP/last_ok"
      stats_liberado() { return 1; }; liga_fora_da_inscricao() { return ${_TL_JANELA:-0}; }
      for _f in cq_liberado masmorra_liberada arena_liberada campanha_liberada caverna_liberada; do eval "$_f() { return 0; }"; done
      for _f in cq_concluir cq_ajudar cq_elixir cq_mercador cq_marcar clanDungeon masmorra_marcar masmorra_adiar \
                cq_antes arena_duel career_func campaign_func cave_routine check_missions check_rewards \
                liga_do_dia func_trade clanQuests specialEvent allies_refresh; do eval "$_f() { printf '%s ' $_f; }"; done
      tarefas_livres 2>/dev/null | grep -o 'arena_duel\|Servidor sem resposta' | tr '\n' ' ' | sed 's/ $//' )
}
_ag=`date +%s`
check "servidor mudo agora: nenhuma atividade na volta" "Servidor sem resposta" "`_tl48 "$_ag" $((_ag - 100))`"
check "servidor respondeu depois da falha: varredura normal" "arena_duel" "`_tl48 $((_ag - 100)) "$_ag"`"
check "minuto de inscricao de evento: a varredura para antes da arena" "" "`_TL_JANELA=1 _tl48 $((_ag - 100)) "$_ag"`"
check "falha de mais de 10 min nao trava a varredura" "arena_duel" "`_tl48 $((_ag - 900)) $((_ag - 1000))`"

# Painel: "sem resposta" com o codigo do curl.
mkdir -p "$_td13/h/.sls/status" "$_td13/h/.sls/BR_Ze"
printf '1|Ze|x\n' > "$_td13/acc.conf"
echo running > "$_td13/h/.sls/status/BR_Ze.status"; echo $$ > "$_td13/h/.sls/status/BR_Ze.pid"
echo $((_ag - 900)) > "$_td13/h/.sls/BR_Ze/last_ok"
sleep 1
echo "$_ag" > "$_td13/h/.sls/BR_Ze/last_rede"; printf 60 > "$_td13/h/.sls/BR_Ze/.curl_erro"
_r=$( ( HOME="$_td13/h"; SLSDIR="$ROOT"; STATUS_DIR="$_td13/h/.sls/status"; ACCOUNTS_FILE="$_td13/acc.conf"
        worker_vivo() { kill -0 "$1"; }
        PANEL_SUPERVISE=1; PANEL_ONCE=1; PANEL_DRAW=1; SLS_EMOJI=0; SLS_COLS=80
        export HOME SLSDIR STATUS_DIR ACCOUNTS_FILE PANEL_SUPERVISE PANEL_ONCE PANEL_DRAW SLS_EMOJI SLS_COLS
        . "$LIB/panel.sh"; painel_loop ) 2>/dev/null | grep -o 'sem resposta[^ ]* *(curl [0-9]*)' )
check "painel: sem resposta mostra o codigo do curl" "sem resposta (curl 60)" "$_r"

# Liga: pagina sem a forca do adversario -> nenhuma luta.
_r=$( TMP="$_td13/lg"; URL="http://jogo"; export TMP URL; mkdir -p "$TMP"; : > "$TMP/req"
      . "$LIB/league.sh" > /dev/null 2>&1
      load_config() { :; }; checkQuest() { return 1; }; player_stats() { echo 3165; }; sleep() { :; }
      fetch_page() { echo "$1" >> "$TMP/req"
          printf '%s\n' "Lutas disponiveis: <b>3</b><a href='/league/fight/302/?r=1'></a><a href='/league/fight/312/?r=1'></a>" > "${2:-$TMP/SRC}"; }
      league_play > /dev/null 2>&1
      grep -c '/league/fight/\|/league/potion/' "$TMP/req" )
check "liga: forca do adversario ilegivel -> nenhuma luta nem pocao" "0" "$_r"

rm -rf "$_td13"; unset _td13 _r _ag
unset -f _tl48

printf "\n=== 49. conta nova sobe com o bot no ar ===\n"
# =============================================================================
_td14=`mktemp -d`
_pan49() { # estado(nova|parada|morta) supervisao -> "lancou=N enc=S|N"
    ( _h="$_td14/$1$2"; rm -rf "$_h"; mkdir -p "$_h/.sls/status"
      printf '1|Ze|Y3JlZGVuY2lhbA==\n' > "$_h/acc.conf"
      case "$1" in
          parada) echo stopped > "$_h/.sls/status/BR_Ze.status" ;;
          morta)  mkdir -p "$_h/.sls/BR_Ze"; echo 999999 > "$_h/.sls/status/BR_Ze.pid"
                  echo running > "$_h/.sls/status/BR_Ze.status" ;;
      esac
      HOME="$_h"; SLSDIR="$ROOT"; STATUS_DIR="$_h/.sls/status"; ACCOUNTS_FILE="$_h/acc.conf"
      ACC_TEST_OUT="$_h/lancou"
      export HOME SLSDIR STATUS_DIR ACCOUNTS_FILE ACC_TEST_OUT
      . "$LIB/contas.sh" > /dev/null 2>&1
      launch_worker() { printf '%s\n' "$3" >> "$ACC_TEST_OUT"; }
      PANEL_SUPERVISE="$2"; PANEL_ONCE=1; PANEL_DRAW=0; SLS_EMOJI=0; SLS_COLS=60
      export PANEL_SUPERVISE PANEL_ONCE PANEL_DRAW SLS_EMOJI SLS_COLS
      . "$LIB/panel.sh" > /dev/null 2>&1; painel_loop > /dev/null 2>&1
      printf 'lancou=%s enc=%s' "`cat "$_h/lancou" 2>/dev/null | wc -l | tr -d ' '`" \
          "`grep -q 'Y3JlZGVuY2lhbA==' "$_h/lancou" 2>/dev/null && echo S || echo N`" )
}
check "conta nova (sem .pid) sobe com o play.sh no ar, com a credencial" "lancou=1 enc=S" "`_pan49 nova 1`"
check "conta nova nao sobe pelo status.sh (somente leitura)"             "lancou=0 enc=N" "`_pan49 nova 0`"
check "conta parada pelo stop.sh continua parada"                        "lancou=0 enc=N" "`_pan49 parada 1`"
check "worker morto continua sendo relancado"                            "lancou=1 enc=S" "`_pan49 morta 1`"
# Duas voltas seguidas nao sobem a mesma conta duas vezes (carimbo de 1 min).
_r=$( _h="$_td14/duas"; rm -rf "$_h"; mkdir -p "$_h/.sls/status"
      printf '1|Ze|Y3JlZGVuY2lhbA==\n' > "$_h/acc.conf"
      HOME="$_h"; SLSDIR="$ROOT"; STATUS_DIR="$_h/.sls/status"; ACCOUNTS_FILE="$_h/acc.conf"
      export HOME SLSDIR STATUS_DIR ACCOUNTS_FILE
      . "$LIB/contas.sh" > /dev/null 2>&1
      launch_worker() { echo L >> "$_h/lancou"; }
      PANEL_SUPERVISE=1; PANEL_ONCE=1; PANEL_DRAW=0; SLS_EMOJI=0; SLS_COLS=60
      export PANEL_SUPERVISE PANEL_ONCE PANEL_DRAW SLS_EMOJI SLS_COLS
      . "$LIB/panel.sh" > /dev/null 2>&1
      painel_loop > /dev/null 2>&1; painel_loop > /dev/null 2>&1
      cat "$_h/lancou" 2>/dev/null | wc -l | tr -d ' ' )
check "duas voltas do painel nao sobem a conta duas vezes" 1 "$_r"
grep -q 'aviso_subir' "$ROOT/setup.sh" && grep -q './play.sh' "$ROOT/setup.sh" \
    && ok "setup.sh: diz como a conta nova comeca a jogar" \
    || bad "setup.sh: nao diz que falta subir o bot"
rm -rf "$_td14"; unset _td14 _r
unset -f _pan49

printf "\n=== 50. rajada do mesmo IP: logins espacados e inscricao escalonada ===\n"
# =============================================================================
# Varias contas do mesmo IP autenticando ou se inscrevendo no mesmo segundo e
# o padrao que o servidor estrangula (a resposta e a mesma de senha errada).
_td15=`mktemp -d`
_esp50() { # segundos_desde_o_ultimo_login [gap] -> segundos dormidos
    ( HOME="$_td15/h$1$2"; mkdir -p "$HOME/.sls"
      . "$LIB/info.sh" > /dev/null 2>&1
      # Relogio parado: com o date de verdade, o segundo podia virar entre
      # gravar o carimbo e o login_espacar ler (dava 9, nao 10, as vezes).
      date() { echo 1000000; }
      [ "$1" != nunca ] && echo $(( 1000000 - $1 )) > "$HOME/.sls/.login.ultimo"
      [ -n "$2" ] && SLS_LOGIN_GAP="$2"
      sleep() { printf '%s' "$1"; }
      login_espacar )
}
check "login colado no anterior espera o intervalo"        "10" "`_esp50 0`"
check "login 4s depois espera so o que falta"              "6"  "`_esp50 4`"
check "login depois do intervalo nao espera"               ""   "`_esp50 30`"
check "sem login anterior nao espera"                      ""   "`_esp50 nunca`"
check "carimbo no futuro (relogio voltou) nao segura"      ""   "`_esp50 -60`"
check "SLS_LOGIN_GAP=0 desliga o espacamento"              ""   "`_esp50 0 0`"
grep -q 'login_espacar$' "$LIB/sls.sh" && grep -q 'login_espacar_marcar' "$LIB/sls.sh" \
    && ok "sls.sh: a trava de login espaca e carimba" \
    || bad "sls.sh: trava de login sem espacamento"

# Inscricao escalonada: alvo dentro do minuto, nunca depois do :30 de antes.
_r=$( . "$LIB/info.sh" > /dev/null 2>&1
      _a=`janela_alvo 5900`
      [ "$_a" -ge 5900 ] && [ "$_a" -le 5929 ] && printf 'ok' || printf '%s' "$_a" )
check "janela_alvo: alvo entre :59:00 e :59:29" "ok" "$_r"
_r=$(grep -cF 'espera_janela ' "$LIB/clanfight.sh" "$LIB/clandmg.sh" "$LIB/flagfight.sh" | grep -cv ':0$')
check "os tres eventos ainda esperam a janela" 3 "$_r"
_r=$(grep -cF 'janela_alvo' "$LIB/clanfight.sh" "$LIB/clandmg.sh" "$LIB/flagfight.sh" | grep -cv ':0$')
check "os tres eventos com inscricao escalonada" 3 "$_r"
_r=$(grep -cF 'BREAK=$(($(date +%s) + 95))' "$LIB/clanfight.sh" "$LIB/clandmg.sh" "$LIB/flagfight.sh" | grep -c ':1$')
check "espera da luta cobre a entrada adiantada (95s)" 3 "$_r"
rm -rf "$_td15"; unset _td15 _r
unset -f _esp50

printf "\n=== 51. HP maximo do FIXHP e leitura unica do last_atk ===\n"
# =============================================================================
_td16=`mktemp -d`
_full51() { # FIXHP -> "pediu|sem_pedido conteudo_gravado"
    ( TMP="$_td16/f$1"; URL="http://jogo"; export TMP URL; rm -rf "$TMP"; mkdir -p "$TMP"
      . "$LIB/info.sh" > /dev/null 2>&1
      FIXHP="$1"
      # Arquivo antigo de outro evento (antes de subir de nivel).
      echo 1800 > "$TMP/flag_full"
      run_curl_exec() { echo pediu >> "$TMP/req"; echo "(65312)"; }
      time_exit() { wait "$!" 2>/dev/null; }
      full_atualizar "$TMP/flag_full" > /dev/null 2>&1
      [ -f "$TMP/req" ] && printf 'pediu ' || printf 'sem_pedido '
      cat "$TMP/flag_full" )
}
check "HP maximo ja lido: grava o atual sem pedir /train" "sem_pedido 2500" "`_full51 2500`"
check "HP maximo ainda nao lido: pede /train"             "pediu 65312"     "`_full51 ''`"
check "HP maximo ilegivel: pede /train"                   "pediu 65312"     "`_full51 abc`"
_r=$(grep -c 'URL/train' "$LIB/altars.sh" "$LIB/clanfight.sh" "$LIB/clandmg.sh" "$LIB/clancoliseum.sh" \
     "$LIB/flagfight.sh" "$LIB/king.sh" "$LIB/coliseum.sh" | grep -c ':0$')
check "nenhum modulo de batalha pede /train direto" 7 "$_r"

# last_atk lido uma vez por volta (duas leituras podiam dar segundos diferentes).
_r=$(grep -c 'read -r _latk < last_atk' "$LIB/altars.sh" "$LIB/clanfight.sh" "$LIB/clandmg.sh" \
     "$LIB/clancoliseum.sh" "$LIB/flagfight.sh" | grep -c ':1$')
check "last_atk lido uma vez por volta nos cinco modulos" 5 "$_r"
rm -rf "$_td16"; unset _td16 _r
unset -f _full51

printf "\n=== 52. trava de login: so o dono apaga ===\n"
# =============================================================================
_td18=`mktemp -d`
sed -n '/^login_lock() {/,/^}/p;/^login_unlock() {/,/^}/p' "$LIB/sls.sh" > "$_td18/trava.sh"
# Dono "de verdade": um processo vivo com sls.sh no cmdline (3.9.106: so o
# kill -0 aceitava qualquer processo com o PID, inclusive um reciclado).
mkdir -p "$_td18/lib"; printf 'sleep 60\n' > "$_td18/lib/sls.sh"
sh "$_td18/lib/sls.sh" & _dono52=$!
_trava52() { # cenario -> "trava_ficou|trava_saiu espacou?"
    #   n  sem trava de outra conta
    #   s  trava de um sls.sh vivo
    #   r  trava com o PID reciclado (vivo, mas nao e sls.sh)
    #   v  trava sem PID, velha (dono morto entre o mkdir e o pid)
    #   f  trava sem PID, nova (dono a caminho de gravar)
    ( HOME="$_td18/h$1"; mkdir -p "$HOME/.sls"; LOCKDIR="$HOME/.sls/.login.lock"
      . "$LIB/info.sh" > /dev/null 2>&1
      . "$_td18/trava.sh"
      sleep() { :; }
      login_espacar() { printf 'espacou ' >> "$HOME/log"; }
      login_espacar_marcar() { :; }
      case "$1" in
          s) mkdir "$LOCKDIR"; echo "$_dono52" > "$LOCKDIR/pid" ;;
          r) mkdir "$LOCKDIR"; echo $$ > "$LOCKDIR/pid" ;;
          v) mkdir "$LOCKDIR"; touch -t 200001010000 "$LOCKDIR" ;;
          f) mkdir "$LOCKDIR" ;;
      esac
      login_lock
      # Sem login_unlock: o que interessa e de quem a trava ficou.
      if [ "${_lk_meu:-0}" = 1 ]; then printf 'pegou '; else printf 'esperou '; fi
      cat "$HOME/log" 2>/dev/null )
}
check "sem trava de outra conta: pega"                            "pegou espacou " "`_trava52 n`"
check "trava de um sls.sh vivo: espera e nao a apaga"             "esperou espacou " "`_trava52 s`"
check "trava com PID reciclado (nao e sls.sh): pega"              "pegou espacou " "`_trava52 r`"
check "trava sem PID ha mais de 1 min (dono morreu antes): pega"  "pegou espacou " "`_trava52 v`"
check "trava sem PID recem-criada: espera o dono gravar"          "esperou espacou " "`_trava52 f`"
kill "$_dono52" 2>/dev/null; wait "$_dono52" 2>/dev/null
rm -rf "$_td18"; unset _td18 _dono52
unset -f _trava52

printf "\n=== 53. sessao anonima na luta, chaves desligadas, FIXHP, config, inscricao ===\n"
# =============================================================================
_td19=`mktemp -d`

# Pagina anonima sem formulario de login: o rodape user=0 e sessao caida.
printf '%s' "<div>Error 404</div><script>jsInterface.event(\"user=0;level=0\")</script>" > "$_td19/anonima"
printf '%s' "<a href='/clanfight/attack/?r=1'>x</a><script>jsInterface.event(\"user=10;level=9\")</script>" > "$_td19/logada"
_r=$( TMP="$_td19"; . "$LIB/info.sh" > /dev/null 2>&1
      printf '%s %s' "`estado_luta "$_td19/anonima" clanfight`" "`estado_luta "$_td19/logada" clanfight`" )
check "estado_luta: pagina anonima (user=0) = deslogado; user=10 segue na luta" "deslogado luta" "$_r"

# Chave desligada: nenhum pedido, e o Torneio devolve a conta para a rotina.
_r=$( TMP="$_td19/ch"; mkdir -p "$TMP"; export TMP
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1
      . "$LIB/coliseum.sh"; . "$LIB/clanfight.sh"; . "$LIB/specialevent.sh"
      run_curl_exec() { printf 'pediu '; }; fetch_page() { printf 'pediu '; }; full_atualizar() { printf 'pediu '; }
      FUNC_coliseum=n; FUNC_clan_fight=n; FUNC_auto_events=n
      date +%s > "$TMP/em_evento"
      coliseum_fight; specialEvent; clanfight_start
      [ -f "$TMP/em_evento" ] && printf 'parada' || printf 'livre' )
check "chaves desligadas: Coliseu e evento especial nao pedem nada; Torneio cancela a dedicacao" "livre" "$_r"

# Retomada do Coliseu sem resposta: a anotacao fica para depois.
_r=$( TMP="$_td19/col"; mkdir -p "$TMP"; URL=http://jogo
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1
      fetch_page() { : > "${2:-$TMP/SRC}"; }; run_curl() { :; }; coliseum_fight() { echo ENTROU; }
      batalha_marcar coliseum; batalha_retomar > /dev/null
      batalha_pendente && printf 'pendente' || printf 'limpa' )
check "retomada do coliseu sem resposta: mantem a anotacao" "pendente" "$_r"

# /train com pagina de erro nao apaga o HP maximo.
_r=$( TMP="$_td19"; URL=http://jogo; . "$LIB/info.sh" > /dev/null 2>&1
      FIXHP=5000; run_curl() { echo "<html>Error 502</html>"; }; fetch_train_stats; printf '%s ' "$FIXHP"
      run_curl() { echo "HP (6100)"; }; fetch_train_stats; printf '%s' "$FIXHP" )
check "fetch_train_stats: pagina de erro mantem o FIXHP, pagina boa atualiza" "5000 6100" "$_r"

# Config: zero a esquerda vira numero; chave com ";" nao executa.
_r=$( TMP="$_td19/cfg"; mkdir -p "$TMP"; . "$LIB/function.sh" > /dev/null 2>&1
      printf 'FUNC_masmorra_min=08\nFUNC_cq_min=00\nFUNC_arena_min=010\nFUNC_x;printf PWNED=1\n' > "$TMP/config.cfg"
      load_config
      printf '%s %s %s' "$(( FUNC_masmorra_min * 60 ))" "$FUNC_cq_min" "$FUNC_arena_min" )
check "config: 08/00/010 viram 8/0/10 e chave com ';' nao executa" "480 0 10" "$_r"

# Minuto de inscricao: a varredura para antes de cada atividade (a parte em
# execucao esta na secao 48). Onze desde a 3.9.96 (carreira, sabio, troca,
# evento e aliados tambem: as atividades cabem no intervalo entre eventos).
_r=`sed -n '/^tarefas_livres() {/,/^}/p' "$LIB/crono.sh" | grep -c 'liga_fora_da_inscricao || return 0'`
check "varredura: relogio conferido antes de cada atividade" 11 "$_r"

# Erva paga em ouro fica de fora no Torneio e no Duelo.
printf '%s' "<a href='/clanfight/grass/?r=3'><span>Erva</span></a>" > "$_td19/erva"
printf '%s' "<a href='/clanfight/grass/?r=3'><span>Erva <img src='/images/icon/gold.png'/> 5</span></a>" > "$_td19/erva_ouro"
_r=$( TMP="$_td19"; . "$LIB/info.sh" > /dev/null 2>&1
      printf '%s|%s' "`erva_gratis clanfight "$_td19/erva"`" "`erva_gratis clanfight "$_td19/erva_ouro"`" )
check "erva_gratis: gratis passa, paga em ouro fica de fora" "/clanfight/grass/?r=3|" "$_r"
_r=`grep -c 'erva_gratis' "$LIB/clanfight.sh" "$LIB/clandmg.sh" | grep -c ':[1-9]$'`
check "Torneio e Duelo usam a erva_gratis" 2 "$_r"
rm -rf "$_td19"; unset _td19

printf "\n=== 54. pedidos a toa e acoes perdidas (revisao de 16/09) ===\n"
# =============================================================================
_td20=`mktemp -d`
VIVA53="<script>jsInterface.event(\"user=5;level=40\")</script>"
LOGIN53="<form action='/?sign_in=1'><input name='pass'/></form>"

# ID do cla: uma consulta por hora, com ou sem cla; rede fora nao apaga o ID.
_cld53() { # semcla|rede -> "pedidos=N CLD=variavel/arquivo rc=N"
    ( TMP="$_td20/cld$1"; export TMP; rm -rf "$TMP"; mkdir -p "$TMP"; : > "$TMP/req"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1; . "$LIB/clanid.sh" > /dev/null 2>&1
      CENA="$1"; CLD=""
      fetch_page() { echo "$1" >> "$TMP/req"
          if [ "$CENA" = rede ]; then : > "$2"; return 1; fi
          echo "<a href='/clan/create/'>Criar</a>$VIVA53" > "$2"; }
      if [ "$CENA" = rede ]; then
          echo 4242 > "$TMP/CLD"
          clan_id > /dev/null; _rc=$?; clan_id > /dev/null
      else
          clan_id > /dev/null; clan_id > /dev/null; _rc=$?
          CLD=""; clan_id > /dev/null
      fi
      printf 'pedidos=%s CLD=%s/%s rc=%s' "$(wc -l < "$TMP/req" | tr -d ' ')" "$CLD" "$(cat "$TMP/CLD")" "$_rc" )
}
check "sem cla: tres chamadas, um pedido de /clan" "pedidos=1 CLD=/ rc=1" "`_cld53 semcla`"
check "rede fora: o ID conhecido fica e a nova tentativa espera" "pedidos=1 CLD=4242/4242 rc=0" "`_cld53 rede`"

# Missao ja ativa. Estrutura da pagina real (16/09), nomes e ids trocados.
_cqpg53() {
    cat > "$1" <<'EOF'
<div>Use 150K de energia <span>Progresso: 23'700 de 150K</span> <a href='/arena/'>Para a arena</a></div>
<div><b>Gladiador Lendário</b> Vença 15 vezes na Liga<br/>Progresso: 12 de 15<br/>Troféu: 1 516<br/>Interpretada por: <a href='/user/1/'>Outro</a> Ajudante: <a href='/user/2/'>Mais</a><br/><a href='/clan/777/quest/delete/2/?r=9'>Cancelar missão</a></div>
<div><b>Alquimista</b> Faça 2 Elixires<br/>Progresso: <span>0</span> de 2<br/>Troféu: 1 645<br/>Interpretada por: <a href='/user/3/'>Eu</a><br/><a class='btn' href='/lab/alchemy/'>Vá lá</a><a href='/clan/777/quest/delete/7/?r=9'>Cancelar missão</a><a href='/clan/777/quest/deleteHelp/7/?r=9'>Cancelar ajudando</a></div>
<div><b>Velho Lojista</b> Obtenha 3 pedras<br/>Progresso: concluída!<br/>Troféu: 1 645<br/><a class='btn' href='/clan/777/quest/end/8/?r=9'>Concluir</a><a href='/clan/777/quest/delete/8/?r=9'>Cancelar missão</a></div>
<div><b>Procura por Recursos</b> Faça 8 pesquisas<br/>Progresso: 3 de 8<br/>Troféu: 1 344<br/>Ajudante: <a href='/user/3/'>Eu</a><br/><a class='btn' href='/cave/'>Vá lá</a><a href='/clan/777/quest/delete/5/?r=9'>Cancelar missão</a></div>
EOF
}
_r=$( TMP="$_td20/cq"; CLD=777; export TMP CLD; mkdir -p "$TMP"; . "$LIB/clanquest.sh" > /dev/null 2>&1
      _cqpg53 "$TMP/CQUEST"; cq_pagina() { :; }
      for _m in 2 7 8 5 3; do printf '%s=%s ' "$_m" "$(cq_falta $_m || echo nao)"; done )
check "cq_falta: so a missao com 'Va la' e por concluir" "2=nao 7=2 8=nao 5=5 3=nao " "$_r"
grep -q 'checkQuest 5 apply || cq_ativa 5' "$LIB/cave.sh" \
    && ok "caverna: missao 5 ja ativa tambem acelera" \
    || bad "caverna: missao 5 tomada antes nunca acelera"
_r=$( TMP="$_td20/el"; CLD=777; export TMP CLD; mkdir -p "$TMP"
      . "$LIB/crono.sh" > /dev/null 2>&1; . "$LIB/clanquest.sh" > /dev/null 2>&1
      _cqpg53 "$TMP/CQUEST"; cq_pagina() { :; }; cq_tomar() { return 1; }; cq_concluir() { :; }; cq_sorteia() { echo 2; }
      fetch_page() { echo "$1" >> "$TMP/req"; echo "<a href='/lab/alchemy/2/makePotion?r=5'>Fazer</a>" > "$TMP/SRC"; }
      cq_elixir > /dev/null 2>&1; cq_elixir > /dev/null 2>&1
      grep -c makePotion "$TMP/req" )
check "elixir: missao ja ativa produz o que falta (2), uma leva por hora" 2 "$_r"

# Sessao caida no meio da masmorra nao vale como golpes gastos (8h).
_r=$( TMP="$_td20/ms"; CLD=999; export TMP CLD; mkdir -p "$TMP"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/clanid.sh" > /dev/null 2>&1; sleep() { :; }
      fetch_page() { case "$1" in
          /clandungeon/?close) echo "<a href='/clandungeon/attack/?r=1'>Golpe</a>$VIVA53" > "$2" ;;
          /clandungeon/attack/*) echo "$LOGIN53" > "$2" ;;
          esac; }
      clanDungeon > /dev/null 2>&1 && printf 'feita' || printf 'adiada' )
check "masmorra: sessao caiu depois do golpe -> adiada" "adiada" "$_r"

check "login_logoff: os dois caminhos felizes marcam os numeros do painel" 2 \
    "$(grep -c 'last_stats' "$LIB/loginlogoff.sh")"

# Dia 1: a missao 11 do coliseu no maximo a cada 15 min.
_r=$( TMP="$_td20/d1"; export TMP; mkdir -p "$TMP"; . "$LIB/crono.sh" > /dev/null 2>&1
      date() { case "$1" in +%d) echo 01 ;; *) command date "$@" ;; esac; }
      HOUR=3; coliseum_start() { echo x >> "$TMP/col"; }; func_cat() { :; }
      func_sleep; func_sleep; func_sleep; wc -l < "$TMP/col" | tr -d ' ' )
check "dia 1 de madrugada: coliseum_start uma vez em tres voltas" 1 "$_r"

# Liga: sem luta, uma leitura so; com luta, missao e /train antes de lutar.
_liga53() { # lutas -> pedidos
    ( TMP="$_td20/lg$1"; URL="http://jogo"; export TMP URL; rm -rf "$TMP"; mkdir -p "$TMP"; : > "$TMP/req"
      . "$LIB/league.sh" > /dev/null 2>&1
      load_config() { :; }; sleep() { :; }
      checkQuest() { echo "cq$1$2" >> "$TMP/req"; return 1; }
      cq_antes() { echo cq_antes >> "$TMP/req"; }
      player_stats() { echo /train >> "$TMP/req"; printf /train > "$TMP/.ult_req"; echo 9999; }
      N="$1"
      fetch_page() { echo "$1" >> "$TMP/req"; printf '%s' "$1" > "$TMP/.ult_req"; _d="${2:-$TMP/SRC}"
          case "$1" in
              /league/) _p="Lutas disponiveis: <b>$N</b><br/>"
                  [ "$N" -eq 0 ] && _p="$_p Tempo restante para restauro: 05:29:02"
                  for _e in 302 312; do _p="$_p<a href='/league/fight/$_e/?r=7'></a>Força: 50<br/>Saúde: 50<br/>Agilidade: 50<br/>Proteção: 50<br/>"; done
                  echo "$_p" > "$_d" ;;
              /league/fight/*) N=$((N - 1)); echo "resultado" > "$_d" ;;
              *) : > "$_d" ;;
          esac; }
      league_play > /dev/null 2>&1
      tr '\n' ' ' < "$TMP/req" )
}
check "liga sem luta: uma leitura, sem missao do cla e sem /train" "/league/ " "`_liga53 0`"
check "liga com uma luta: a leitura da contagem serve para escolher e coletar" \
    "/league/ cq_antes /train /league/ /league/fight/302/?r=7 /league/ cq2end cq1end " "`_liga53 1`"

grep -q 'find "$HOME/.sls/agenda" -mmin -25' "$LIB/crono.sh" \
    && ok "agenda: baixada por uma conta vale para as outras" \
    || bad "agenda: cada conta pede a sua"

# Caverna -cv: preco do botao, nao o saldo do cabecalho.
_r=$( TMP="$_td20/cv"; export TMP; mkdir -p "$TMP"; . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/cave.sh" > /dev/null 2>&1
      echo "<img src='/images/icon/silver.png' alt='s'/> 98'765 <a class='btn' href='/cave/speedUp/?r=4'>Acelerar <img src='/images/icon/silver.png' alt=''/> 250</a>" > "$TMP/SRC"
      read_speedup_silver_cost; printf '%s' "$SPEEDUP_SILVER_COST" )
check "caverna -cv: custo do speedUp e o do botao" 250 "$_r"

# Esperas escalonadas (vao de 10s a partir de :x9:50), sem inscricao apos a luta.
_r=$( . "$LIB/info.sh" > /dev/null 2>&1; _a=`janela_alvo 2950 10`
      [ "$_a" -ge 2950 ] && [ "$_a" -le 2959 ] && printf ok || printf '%s' "$_a" )
check "janela_alvo com vao: alvo entre :29:50 e :29:59" ok "$_r"
check "Rei, Altares, Coliseu do Cla (2) e Vale: espera escalonada" 5 \
    "$(cat "$LIB/king.sh" "$LIB/altars.sh" "$LIB/clancoliseum.sh" "$LIB/undying.sh" | grep -c 'janela_alvo [25]950 10')"
check "Rei: a espera nao clica no primeiro link /king/" 0 "$(grep -c "sed 's/href=/" "$LIB/king.sh")"
check "sem apply_event depois das lutas (so a inscricao do Vale)" 1 \
    "$(cat "$LIB/king.sh" "$LIB/altars.sh" "$LIB/flagfight.sh" "$LIB/clandmg.sh" "$LIB/undying.sh" | grep -c '^[^#]*apply_event')"
check "Duelo: rodadas em laco, sem se chamar de novo" 0 "$(grep -c '^ *clandmgfight_start$' "$LIB/clandmg.sh")"

# Vale: HP e mana maximos conhecidos dispensam o /train; um arena_fullmana.
_r=$( TMP="$_td20/hm"; URL=http://jogo; export TMP URL; mkdir -p "$TMP"; : > "$TMP/req"; : > "$TMP/SRC"
      . "$LIB/info.sh" > /dev/null 2>&1
      run_curl_exec() { echo x >> "$TMP/req"; }; time_exit() { wait "$!" 2>/dev/null; }
      FIXHP=5000; FIXMP=900; hpmp -fix; wc -l < "$TMP/req" | tr -d ' ' )
check "Vale: hpmp -fix sem /train com os maximos ja lidos" 0 "$_r"
check "Vale: um arena_fullmana so, antes da hora cheia" 1 "$(grep -c '^ *arena_fullmana$' "$LIB/undying.sh")"

check "fim da luta: 'Vitoria!' sem depender do byte do acento" 1 "$(grep -c 'Vit\[^ <\]{1,8}ria!' "$LIB/info.sh")"

# Arena: sem ataque nao abre a mochila; energy arena sem nonce para.
_r=$( TMP="$_td20/ar"; export TMP; mkdir -p "$TMP"; . "$LIB/arena.sh" > /dev/null 2>&1
      checkQuest() { return 1; }; sleep() { :; }
      fetch_page() { echo "$1" >> "$TMP/req"; echo "<a href='/lab/wizard/'>x</a>" > "$TMP/SRC"; }
      arena_duel > /dev/null 2>&1; tr '\n' ' ' < "$TMP/req" )
check "arena sem ataque: nao abre a mochila" "/arena/ " "$_r"
_r=$( TMP="$_td20/fm"; URL=http://jogo; export TMP URL; mkdir -p "$TMP"; : > "$TMP/req"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/arena.sh" > /dev/null 2>&1
      run_curl_exec() { echo "$1" >> "$TMP/req"; echo "sem link"; }; time_exit() { wait "$!" 2>/dev/null; }
      arena_fullmana > /dev/null 2>&1; printf 'rc=%s pedidos=%s' "$?" "$(wc -l < "$TMP/req" | tr -d ' ')" )
check "energy arena sem nonce: para no primeiro pedido" "rc=1 pedidos=1" "$_r"

# Evento especial: a Home do descanso ainda fresca serve.
_r=$( TMP="$_td20/se"; export TMP; mkdir -p "$TMP"; : > "$TMP/req"; . "$LIB/specialevent.sh" > /dev/null 2>&1
      fetch_page() { echo "$1" >> "$TMP/req"; : > "$TMP/SRC"; }
      echo "<div class='shb_text'><a href='/marathon/'>Maratona</a></div>" > "$TMP/REST"; date +%s > "$TMP/.home_ok"
      specialEvent > /dev/null 2>&1; tr '\n' ' ' < "$TMP/req" )
check "evento especial: usa a Home do descanso, sem pedir /" "/marathon/ " "$_r"

check "releitura com alvo cinza: pausa sempre (seis modulos)" 0 \
    "$(cat "$LIB/altars.sh" "$LIB/clancoliseum.sh" "$LIB/clandmg.sh" "$LIB/clanfight.sh" "$LIB/flagfight.sh" "$LIB/coliseum.sh" | grep -c '|| sleep 1$')"

# HP maximo: /train sem resposta mantem o que havia.
_r=$( TMP="$_td20/fa"; URL=http://jogo; export TMP URL; mkdir -p "$TMP"; . "$LIB/info.sh" > /dev/null 2>&1
      FIXHP=""; echo 4000 > "$TMP/FULL"
      run_curl_exec() { :; }; time_exit() { wait "$!" 2>/dev/null; }
      full_atualizar "$TMP/FULL"; printf '%s %s' "$(cat "$TMP/FULL")" "$(ls "$TMP" | grep -c tmp)" )
check "/train sem resposta nao zera o HP maximo" "4000 0" "$_r"
grep -q 'full_atualizar "\$_br_full"' "$LIB/crono.sh" \
    && ok "retomada de batalha: mesmo HP maximo protegido" \
    || bad "retomada de batalha: /train sem resposta zera o HP maximo"

# /train a cada 15 min, e de novo quando o nivel muda.
_r=$( TMP="$_td20/tr"; URL=http://jogo; export TMP URL; mkdir -p "$TMP"; : > "$TMP/req"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1
      run_curl() { echo x >> "$TMP/req"; echo "(5000) Energia: 2100"; }
      FIXHP=""; ACC_ENE=""
      fetch_train_stats; fetch_train_stats; printf '%s ' "$(wc -l < "$TMP/req" | tr -d ' ')"
      ACC_LVL=40; parse_status "icon/level.png' alt=''/> 41"; fetch_train_stats
      printf '%s %s' "$(wc -l < "$TMP/req" | tr -d ' ')" "$FIXHP" )
check "/train: uma leitura por hora fora das lutas, e outra ao subir de nivel" "1 2 5000" "$_r"

# Troca: resposta de login nao gasta o dia.
_r=$( TMP="$_td20/td"; export TMP; mkdir -p "$TMP"; . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/trade.sh" > /dev/null 2>&1
      FUNC_trade_dias=1
      fetch_page() { case "$1" in
          /trade/exchange) echo "<img src='/images/icon/silver.png' alt='s'/> 2'000'000 <a href='/trade/exchange/gold/100?r=3'>x</a>$VIVA53" > "$TMP/SRC" ;;
          *) echo "$LOGIN53" > "$TMP/SRC" ;;
          esac; }
      func_trade > /dev/null 2>&1; [ -f "$TMP/last_trade" ] && printf 'marcou' || printf 'em_aberto' )
check "troca com resposta de login: o dia fica em aberto" "em_aberto" "$_r"

# Torneio de Equipe: so o lider tem o botao "Aplicar". O membro (pagina da
# captura de 09/10: contador, "Lider nao se inscreveu", sem botao) espera a
# luta e luta, em vez de voltar para a rotina.
#   _cc69 PAGINA_INICIAL -> pedidos feitos + o que o modulo decidiu
#   PAGINA_INICIAL: membro | membro_longe | membro_chat | lider | nada
_cc69() {
    ( TMP="$_td20/cc_$1"; URL=http://jogo; export TMP URL; mkdir -p "$TMP"; : > "$TMP/req"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/clancommand.sh" > /dev/null 2>&1
      PG="$1"
      # Roda em subshell (run_curl_exec ... &): a contagem vai pelo arquivo.
      run_curl_exec() {
          echo "$1" | sed 's|^http://jogo||' >> "$TMP/req"; echo x >> "$TMP/n"
          N=`wc -l < "$TMP/n"`
          _p="<img src='/images/icon/level.png'/> <a href='/clancommand/myteam/'>Equipe</a>"
          if [ "$N" -ge 3 ]; then
              echo "$_p <a href='/clancommand/attack/?r=1'>Atacar</a>"; return
          fi
          case "$PG" in
              membro)       echo "$_p <span id='time_240000'>4 min</span> Líder não se inscreveu para a batalha <a href='/clancommand/'>Atualizar</a>" ;;
              membro_longe) echo "$_p <span id='time_15808000'>4 h 23 min</span>" ;;
              membro_chat)  echo "$_p <a href='/chat/changeRoom/?r=98418211'>Chat</a>" ;;
              lider)        echo "$_p <a href='/clancommand/?enterFight=98418211'>Aplicar</a> <span id='time_240000'>4 min</span>" ;;
              nada)         echo "$_p" ;;
          esac; }
      time_exit() { wait "$!" 2>/dev/null; }; sleep() { :; }
      full_atualizar() { :; }; batalha_marcar() { echo marcou >> "$TMP/req"; }; batalha_limpar() { :; }
      evento_cancelar() { echo liberou >> "$TMP/req"; }; clancommand_fight() { echo lutou >> "$TMP/req"; }
      clancommand_start > /dev/null 2>&1
      grep -v '^/clancommand/$' "$TMP/req" | grep -v '^/clancommand/?close=reward$' | tr '\n' ' ' )
}
check "torneio: membro sem botao espera a luta e luta" "marcou lutou " "`_cc69 membro`"
check "torneio: membro so com a sala da equipe tambem luta" "marcou lutou " "`_cc69 membro_chat`"
check "torneio: membro com inicio longe e liberado sem inscrever" "liberou " "`_cc69 membro_longe`"
check "torneio: lider inscreve e luta" "marcou /clancommand/?enterFight=98418211 lutou " "`_cc69 lider`"
check "torneio: sem nada do torneio na pagina, pula" "liberou " "`_cc69 nada`"
_r=$( . "$LIB/clancommand.sh" > /dev/null 2>&1; _f="$_td20/cc_sit"
      echo "Líder não se inscreveu para a batalha" > "$_f"; printf '%s|' "`_cc_situacao "$_f"`"
      echo "Participantes: 10 equipes" > "$_f"; printf '%s' "`_cc_situacao "$_f"`" )
check "torneio: o log do membro diz se o lider ja inscreveu" \
    "lider ainda nao inscreveu a equipe|membro da equipe, sem botao de inscricao" "$_r"

# Inscricao antecipada (clancommand_inscrever): o lider inscreve longe do
# inicio; inscrito ou membro, a pagina nao e pedida de novo ate o torneio.
#   _cc70 PAGINA -> pedidos da 1a chamada | rc | anotou? | pedidos da 2a
#   PAGINA: lider | recusa | membro | perto | fechado
_cc70() {
    ( TMP="$_td20/ci_$1"; URL=http://jogo; CLD=77; export TMP URL CLD; mkdir -p "$TMP"; : > "$TMP/req"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/clancommand.sh" > /dev/null 2>&1
      PG="$1"
      run_curl_exec() {
          _u=`echo "$1" | sed 's|^http://jogo||'`; echo "$_u" >> "$TMP/req"
          _p="<img src='/images/icon/level.png'/> <a href='/clancommand/myteam/'>Equipe</a>"
          _t="<span id='time_15808000'>4 h 23 min</span>"
          _a="<a href='/clancommand/?enterFight=34500465'>Aplicar</a>"
          case "$PG:$_u" in
              lider:*enterFight*|resultado:*enterFight*) echo "$_p $_t" ;;
              # Resultado da batalha aberto: so o ?close=reward mostra o torneio.
              resultado:*close=reward*) echo "$_p $_a $_t" ;;
              resultado:*)        echo "$_p Resultado da batalha" ;;
              lider:*|recusa:*)   echo "$_p $_a $_t" ;;
              membro:*)           echo "$_p $_t Líder não se inscreveu para a batalha" ;;
              perto:*)            echo "$_p $_a <span id='time_300000'>5 min</span>" ;;
              fechado:*)          echo "$_p" ;;
          esac; }
      time_exit() { wait "$!" 2>/dev/null; }
      clancommand_inscrever > /dev/null 2>&1; _rc=$?
      printf '%s|%s|' "$(tr '\n' ' ' < "$TMP/req")" "$_rc"
      [ -s "$TMP/torneq_ate" ] && printf 'anotou|' || printf 'nao|'
      : > "$TMP/req"; clancommand_inscrever > /dev/null 2>&1; tr '\n' ' ' < "$TMP/req" )
}
check "inscricao antecipada: lider inscreve e para ate o inicio" \
    "/clancommand/?close=reward /clancommand/?enterFight=34500465 |0|anotou|" "`_cc70 lider`"
check "inscricao antecipada: resultado da batalha aberto e fechado antes (11/10)" \
    "/clancommand/?close=reward /clancommand/?enterFight=34500465 |0|anotou|" "`_cc70 resultado`"
check "inscricao antecipada: recusada, tenta de novo depois" \
    "/clancommand/?close=reward /clancommand/?enterFight=34500465 |1|nao|/clancommand/?close=reward /clancommand/?enterFight=34500465 " "`_cc70 recusa`"
check "inscricao antecipada: membro le uma vez e para ate o inicio" \
    "/clancommand/?close=reward |0|anotou|" "`_cc70 membro`"
check "inscricao antecipada: perto do inicio fica com a janela do run.sh" \
    "/clancommand/?close=reward |1|nao|/clancommand/?close=reward " "`_cc70 perto`"
check "inscricao antecipada: sem torneio aberto, sem inscricao" \
    "/clancommand/?close=reward |1|nao|/clancommand/?close=reward " "`_cc70 fechado`"
check "torneio: inscreve o proximo depois da batalha (dois caminhos)" 2 \
    "$(grep -A1 '^ *clancommand_fight$' "$LIB/clancommand.sh" | grep -c '^ *clancommand_inscrever$')"
grep -q '^ *clancommand_inscrever 2>/dev/null$' "$LIB/crono.sh" \
    && ok "torneio: repescagem da inscricao na rotina" \
    || bad "torneio: a rotina nao tenta a inscricao antecipada"
grep -q '^ *clancommand) *fetch_page "/clancommand" "\$TMP/ccmd_src"; *clancommand_fight ;;' "$LIB/crono.sh" \
    && ok "torneio: worker relancado volta para a luta" \
    || bad "torneio: batalha_retomar sem o clancommand"

# Ao vivo do painel no Coliseu do Cla e nas Bandeiras: o HP da conta vem em
# USH. Com HP velho de outra luta no disco, vale o mais recente.
_r=$( _d="$_td20/aovivo"; mkdir -p "$_d"; . "$LIB/panel.sh" > /dev/null 2>&1
      echo 4200 > "$_d/USH"; echo 5000 > "$_d/old_HP"; ESTREITO=1
      combate_de_v "$_d"; printf '%s|' "$_CBT"
      echo 9999 > "$_d/HP"; sleep 1; echo 4100 > "$_d/USH"
      combate_de_v "$_d"; printf '%s' "$_CBT" )
check "painel ao vivo: HP do Coliseu do Cla e das Bandeiras (USH)" "HP 4200 (-800)|HP 4100 (-900)" "$_r"

# Painel: HP e energia maximos sao os da propria conta (maior valor lido no
# cabecalho), nao os do /train. Capturas de 10/10: nivel 45 com 731 | 1555.
_r=$( TMP="$_td20/mx"; mkdir -p "$TMP"; . "$LIB/info.sh" > /dev/null 2>&1
      FIXHP=""; ACC_ENE=""; ACC=Draco
      _pg() { printf "<img src='/images/icon/level.png' alt=''/> %s <img src='/images/icon/health.png' alt='hp'/> %s <img src='/images/icon/mana.png' alt='mp'/> <span class='white'>%s</span>" "$1" "$2" "$3"; }
      _st() { cut -d'|' -f2,4,9 "$TMP/stats"; }
      parse_status "`_pg 45 731 1555`";  printf '%s ' "`_st`"
      parse_status "`_pg 45 9922 1400`"; printf '%s ' "`_st`"
      parse_status "`_pg 45 8000 1555`"; printf '%s ' "`_st`"
      ACC_LVL=""; parse_status "`_pg 45 7000 900`"; printf '%s ' "`_st`"
      parse_status "`_pg 46 9000 1600`"; printf '%s' "`_st`" )
check "painel: maximo de HP e energia e o da conta, recomeca ao subir de nivel" \
    "731|1555/1555|731 9922|1400/1555|9922 8000|1555/1555|9922 7000|900/1555|9922 9000|1600/1600|9000" "$_r"
# Com o /train lido, o teto dele vale desde a primeira leitura; abaixo do
# valor ja visto, vale o visto (nunca mais de 100%).
_r=$( TMP="$_td20/mx2"; mkdir -p "$TMP"; . "$LIB/info.sh" > /dev/null 2>&1
      ACC=Draco
      _pg() { printf "<img src='/images/icon/level.png' alt=''/> %s <img src='/images/icon/health.png' alt='hp'/> %s <img src='/images/icon/mana.png' alt='mp'/> <span class='white'>%s</span>" "$1" "$2" "$3"; }
      _st() { cut -d'|' -f2,4,9 "$TMP/stats"; }
      FIXHP=4061; ACC_ENE=1555; parse_status "`_pg 45 731 900`"; printf '%s ' "`_st`"
      FIXHP=4000; ACC_ENE="1'500"; parse_status "`_pg 45 4061 1555`"; printf '%s ' "`_st`"
      ACC_ENE="2,1M"; parse_status "`_pg 45 3000 1000`"; printf '%s' "`_st`" )
check "painel: teto do /train desde a primeira leitura, nunca abaixo do visto" \
    "731|900/1555|4061 4061|1555/1555|4061 3000|1000/1555|4061" "$_r"

# HP da pagina lido uma vez: o _hp dos modulos de cla e o arquivo do HP da
# conta (HP ou USH), e as comparacoes de cura/esquiva sao marcas da pagina.
check "_hp vem do HP da conta (cinco modulos de cla)" "HP HP HP USH USH" \
    "$(for _m in clanfight clandmg altars clancoliseum flagfight; do sed -n 's/^ *_hp=`cat \([A-Z]*\)`$/\1/p' "$LIB/$_m.sh"; done | tr '\n' ' ' | sed 's/ $//')"
check "cura e esquiva sem cat por volta (sete modulos)" 0 \
    "$(cat "$LIB/clanfight.sh" "$LIB/clandmg.sh" "$LIB/altars.sh" "$LIB/clancoliseum.sh" "$LIB/flagfight.sh" \
           "$LIB/clancommand.sh" "$LIB/coliseum.sh" | grep -v '^ *_hlhp=' | grep -c 'cat HLHP\|cat old_HP')"
check "HP e limiar do inimigo nao calculados a toa (cinco modulos)" 0 \
    "$(cat "$LIB/clanfight.sh" "$LIB/clandmg.sh" "$LIB/altars.sh" "$LIB/clancoliseum.sh" "$LIB/flagfight.sh" | grep -c '> HP2\|> ENH\|> RHP')"

# HP maximo lido no inicio da batalha: o full_atualizar rele o /train se a
# leitura tem mais de 10 min; nao rele se e recente nem na retomada da luta.
# Fora das lutas, o /train sai uma vez por hora.
#   _tr77 MIN_DESDE_A_ULTIMA_LEITURA [retomada] -> pedidos de /train | FULL
_tr77() {
    ( TMP="$_td20/tr77_$1$2"; URL=http://jogo; export TMP URL; mkdir -p "$TMP"; : > "$TMP/req"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1
      run_curl() { echo x >> "$TMP/req"; echo "Saude: 2304 (4608) Energia: 1555"; }
      FIXHP=4000; ACC_ENE=1555
      echo $(( `date +%s` - $1 * 60 )) > "$TMP/last_train"
      [ -n "$2" ] && _BR_ATIVO=1
      full_atualizar "$TMP/FULL"
      printf '%s|%s' "`wc -l < "$TMP/req" | tr -d ' '`" "`cat "$TMP/FULL"`" )
}
check "inicio da batalha: /train lido ha 11 min e relido (HP maximo novo)" "1|4608" "`_tr77 11`"
check "inicio da batalha: /train lido ha 5 min vale o que esta" "0|4000" "`_tr77 5`"
check "retomada da luta: nao rele o /train" "0|4000" "`_tr77 30 retomada`"
_r=$( TMP="$_td20/tr77h"; URL=http://jogo; export TMP URL; mkdir -p "$TMP"; : > "$TMP/req"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1
      run_curl() { echo x >> "$TMP/req"; echo "Saude: 2304 (4608) Energia: 1555"; }
      FIXHP=4000; ACC_ENE=1555
      echo $(( `date +%s` - 30 * 60 )) > "$TMP/last_train"; fetch_train_stats
      printf '%s ' "`wc -l < "$TMP/req" | tr -d ' '`"
      echo $(( `date +%s` - 61 * 60 )) > "$TMP/last_train"; fetch_train_stats
      printf '%s' "`wc -l < "$TMP/req" | tr -d ' '`" )
check "fora das lutas: /train de hora em hora (30 min nao, 61 min sim)" "0 1" "$_r"
sed -n '/^hpmp() {/,/^}/p' "$LIB/info.sh" | grep -q 'if fetch_train_stats 10 2>/dev/null; then' \
    && ok "Vale: HP e mana maximos conferidos no inicio, como nas outras lutas" \
    || bad "Vale: entra com o HP maximo de horas atras"

# Numeros do painel a cada 5 min: padrao novo e migracao unica de quem
# estava no padrao antigo (3). Um valor escolhido depois fica como esta.
_r=$( TMP="$_td20/cfg77"; mkdir -p "$TMP"; . "$LIB/function.sh" > /dev/null 2>&1
      printf 'FUNC_stats_min=3\nFUNC_arena_min=30\n' > "$TMP/config.cfg"
      load_config; printf '%s ' "$FUNC_stats_min"
      sed -i 's/^FUNC_stats_min=.*/FUNC_stats_min=3/' "$TMP/config.cfg"
      load_config; printf '%s ' "$FUNC_stats_min"
      TMP="$_td20/cfg77b"; mkdir -p "$TMP"; : > "$TMP/config.cfg"
      load_config; printf '%s' "$FUNC_stats_min" )
check "painel a cada 5 min: o 3 antigo vira 5 uma vez; conta nova ja nasce com 5" "5 3 5" "$_r"

# Relogio da volta: um date, o resto pelo /proc/uptime. Mesmo epoch, minuto,
# hora e dia do date (tolerancia de 1s); fora do laco, o date de antes.
_r=$( TMP="$_td20/rv"; mkdir -p "$TMP"; . "$LIB/crono.sh" > /dev/null 2>&1
      relogio_sync; _a1=`date '+%s %M %H %d'`
      agora_s; minuto_atual; hora_atual; dia_atual
      _a2=`date '+%s %M %H %d'`
      # Vale o date de antes ou o de depois (virada de minuto no meio).
      _ok() { set -- $1; [ $(( _AGORA - $1 )) -ge -1 ] && [ $(( _AGORA - $1 )) -le 1 ] && \
              [ "$_MIN" = "${2#0}" ] && [ "$_HOR" = "${3#0}" ] && [ "$_DIA" = "$4" ]; }
      if _ok "$_a1" || _ok "$_a2"; then printf ok; else printf '%s|%s|%s %s %s %s' "$_a1" "$_a2" "$_AGORA" "$_MIN" "$_HOR" "$_DIA"; fi )
check "relogio da volta: epoch, minuto, hora e dia batem com o date" ok "$_r"
_r=$( TMP="$_td20/rv2"; mkdir -p "$TMP"; . "$LIB/crono.sh" > /dev/null 2>&1
      date() { case "$1" in +%M) echo 07 ;; +%H) echo 09 ;; +%d) echo 01 ;; +%s) echo 1000 ;; *) command date "$@" ;; esac; }
      agora_s; minuto_atual; hora_atual; dia_atual; printf '%s %s %s %s' "$_AGORA" "$_MIN" "$_HOR" "$_DIA" )
check "relogio da volta: fora do laco usa o date (testes e entrada do bot)" "1000 7 9 01" "$_r"
check "rotina: os portoes de atividade nao chamam o date" 0 \
    "$(sed -n '/^ativ_liberada() {/,/^}/p;/^relogio_liberado() {/,/^}/p;/^masmorra_liberada() {/,/^}/p' "$LIB/crono.sh" | grep -c 'date')"

# Laco de luta sem giro: relogio virtual (date le, so o sleep faz o tempo
# andar). Um laco que gira sem dormir nunca avanca o relogio: passado o teto
# de voltas o teste o encerra, e os golpes nao chegam a seis.
#   _giro71 MODULO SECAO FUNCAO [aliado] -> "golpes=N relogio_lido=M trocas=T"
_giro71() {
    ( TMP="$_td20/giro_$1"; URL=http://jogo; SLS_PACING=0; export TMP URL SLS_PACING; mkdir -p "$TMP"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/allies.sh" > /dev/null 2>&1; . "$LIB/$1.sh" > /dev/null 2>&1
      _pg="$TMP/pagina.html"
      { printf "<img src='/images/icon/level.png'/> <img src='/images/race/1.png' alt=''/> Eu <span class='nwr'><img src='/images/icon/health.png' alt='hp'/> 8000</span>"
        _alvo=Ele; [ -n "$4" ] && _alvo=Amigo
        printf "<img src='/images/race/0.png' alt=''/> %s <span class='nwr'>" "$_alvo"
        printf "<img src='/images/icon/health.png' alt='hp'/>&nbsp;5000</span>"
        for _v in attack attackrandom dodge heal; do printf "<a class='nbtn' href='/%s/%s/?r=1'>x</a>" "$2" "$_v"; done
        printf '<script>jsInterface.event("user=5")</script>\n'; } > "$_pg"
      for _f in SRC src.html x_src; do cp "$_pg" "$TMP/$_f"; done
      echo 10000 > "$TMP/FULL"; echo 10000 > "$TMP/x_full"; src_ram="$TMP/x_src"; full_ram="$TMP/x_full"
      echo Amigo > "$TMP/callies.txt"; echo Amigo > "$TMP/allies.txt"
      echo 100000 > "$TMP/relogio"; : > "$TMP/nrel"; : > "$TMP/req"
      date() { echo x >> "$TMP/nrel"
               [ "`wc -l < "$TMP/nrel"`" -gt 600 ] && echo 1 > "$TMP/BREAK_LOOP"
               cat "$TMP/relogio"; }
      sleep() { _s=${1%s}; _s=${_s%%.*}; read -r _c < "$TMP/relogio"; echo $(( _c + ${_s:-0} )) > "$TMP/relogio"; }
      run_curl_exec() { echo "$1" >> "$TMP/req"; cat "$_pg"; }
      time_exit() { wait "$!" 2>/dev/null; }
      luta_teto() { echo $(( `cat "$TMP/relogio"` + 30 )); }
      func_unset() { :; }
      cd "$TMP" && $3 > /dev/null 2>&1
      printf 'golpes=%s relogio_lido=%s trocas=%s' "`grep -c '/attack/' "$TMP/req"`" \
             "`wc -l < "$TMP/nrel" | tr -d ' '`" "`grep -c '/attackrandom/' "$TMP/req"`" )
}
for _m in "clanfight clanfight clanfight_fight" "clandmg clandmgfight clandmgfight_fight" \
          "altars altars altars_fight" "clancoliseum clancoliseum clancoliseum_fight" \
          "flagfight flagfight flagfight_fight" "clancommand clancommand clancommand_fight"; do
    set -- $_m
    _r=`_giro71 "$1" "$2" "$3"`
    _g=${_r#golpes=}; _g=${_g%% *}; _n=${_r#*relogio_lido=}; _n=${_n%% *}
    if [ "$_g" -ge 5 ] && [ "$_n" -lt 120 ]; then ok "$1: laco sem giro em 30s ($_r)"
    else bad "$1: laco girando sem dormir ($_r)"; fi
done

# Troca por aliado: so aliados na frente nao vira laco de trocas; depois de
# tres trocas que so deram aliado, fogo amigo por 30s. Antes: 181 a 447
# trocas e nenhum golpe em 100s.
for _m in "clanfight clanfight clanfight_fight" "clancommand clancommand clancommand_fight"; do
    set -- $_m
    _r=`_giro71 "$1" "$2" "$3" aliado`
    _g=${_r#golpes=}; _g=${_g%% *}; _t=${_r##*trocas=}
    if [ "$_t" -ge 1 ] && [ "$_t" -le 4 ] && [ "$_g" -ge 3 ]; then ok "$1: so aliados - 3 trocas e fogo amigo ($_r)"
    else bad "$1: so aliados vira laco de trocas ($_r)"; fi
done
_r=$( TMP="$_td20/al72"; mkdir -p "$TMP"; cd "$TMP" || exit
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/allies.sh" > /dev/null 2>&1
      echo Amigo_1 > callies.txt; aliado_zerar
      _v() { echo "$1" > USER; aliado_ler cla; if troca_aliado "$2" > /dev/null; then printf T; else printf A; fi; }
      _v Amigo_1 100; _v Amigo_1 101; _v Amigo_1 102; _v Amigo_1 103
      _v Amigo_1 110; _v Amigo_1 134; _v Inimigo 135; _v Amigo_1 136 )
check "troca por aliado: 3 trocas, fogo amigo 30s, inimigo zera a conta" "TTTAATAT" "$_r"
check "lista de aliados consultada so no aliado_ler" "0 0 0 0 0 0 0" \
    "$(for _m in clanfight clandmg altars clancoliseum flagfight clancommand king; do grep -c 'alvo_aliado' "$LIB/$_m.sh"; done | tr '\n' ' ' | sed 's/ $//')"
check "aliado_ler em cada leitura de pagina (sete modulos)" "1 1 1 1 1 1 1" \
    "$(for _m in clanfight clandmg altars clancoliseum flagfight clancommand king; do grep -c '^ *aliado_ler' "$LIB/$_m.sh"; done | tr '\n' ' ' | sed 's/ $//')"
check "fim do giro: espera nunca zero (sete modulos)" 7 \
    "$(cat "$LIB/clanfight.sh" "$LIB/clandmg.sh" "$LIB/altars.sh" "$LIB/clancoliseum.sh" \
           "$LIB/flagfight.sh" "$LIB/clancommand.sh" "$LIB/coliseum.sh" | grep -c '\[ "\$_resta" -gt 0 \] || _resta=1$')"
check "alvo cinza calculado uma vez por pagina (sete modulos)" "1 1 1 1 1 1 1" \
    "$(for _m in clanfight clandmg altars clancoliseum flagfight clancommand coliseum; do grep -c 'alvo_grey' "$LIB/$_m.sh"; done | tr '\n' ' ' | sed 's/ $//')"

# Painel (3.9.78): menos processos por redesenho, a mesma tela.
# Hora de Brasilia do rodape: diferenca para o epoch lida uma vez por hora.
_r=$( HOME="$_td20/pr78"; mkdir -p "$HOME/.sls"; export HOME
      . "$LIB/panel.sh" > /dev/null 2>&1
      _a=`TZ=America/Bahia date '+%H %M'`; _agora_ep=`date +%s`; painel_relogio
      _b=`TZ=America/Bahia date '+%H %M'`
      _m=$(( (_agora_ep + _PE_BAHIA) % 86400 / 60 ))
      for _x in "$_a" "$_b"; do set -- $_x
          [ $(( ${1#0} * 60 + ${2#0} )) = "$_m" ] && { echo igual; exit; }; done
      echo "diferente ($_m x $_a/$_b)" )
check "painel: minuto de Brasilia sem date por redesenho = TZ=America/Bahia date" igual "$_r"
# Agenda: lida uma vez e relida quando o arquivo muda.
_r=$( HOME="$_td20/pr78"; export HOME
      . "$LIB/panel.sh" > /dev/null 2>&1
      _agora_ep=`date +%s`
      echo '1130|Torneio de equipe' > "$HOME/.sls/agenda"; painel_relogio; printf '%s ' "${_PE_AG_TXT%%|*}"
      painel_relogio; printf '%s ' "${_PE_AG_TXT%%|*}"
      echo '2225|Rei dos Imortais' > "$HOME/.sls/agenda"; touch -d "@$(( _agora_ep + 5 ))" "$HOME/.sls/agenda"
      painel_relogio; printf '%s ' "${_PE_AG_TXT%%|*}"
      : > "$HOME/.sls/agenda"; painel_relogio; printf '[%s]' "$_PE_AG_TXT" )
check "painel: agenda em cache, relida quando muda" "1130 1130 2225 []" "$_r"
# Conta viva: checagem completa (cmdline) na 1a vez e a cada 12 redesenhos.
_r=$( . "$LIB/panel.sh" > /dev/null 2>&1
      worker_vivo() { _wv=$((_wv + 1)); kill -0 "$1" 2>/dev/null; }
      _wv=0; idx=1; _i=0
      while [ $_i -lt 14 ]; do worker_vivo_painel $$ /x/BR_A || printf M; _i=$((_i + 1)); done
      printf '%s ' "$_wv"
      worker_vivo_painel 999999999 /x/BR_A && printf vivo || printf morto; printf ' %s ' "$_wv"
      worker_vivo_painel $$ /x/BR_A && printf vivo; printf ' %s' "$_wv" )
check "painel: kill -0 entre as checagens completas, morto e PID novo conferidos" "2 morto 3 vivo 4" "$_r"
check "painel: classes UTF-8 montadas uma vez, nao a cada desenho" 0 \
    "`sed -n '/^painel_render()/,/^}/p' "$LIB/panel.sh" | grep -c '\$(printf'`"
grep -q '/data/data/com.termux' "$LIB/panel.sh" && grep -q '^        sleep 10$' "$LIB/panel.sh" \
    && ok "painel: a cada 10s no Termux (5s no PC, -n escolhe)" \
    || bad "painel: intervalo do Termux ausente"
# Espera da rotina em fatias de 15s, somando exatamente o pedido.
_r=$( . "$LIB/crono.sh" > /dev/null 2>&1
      runnow_pedido() { return 1; }
      sleep() { printf '%s ' "$1"; }
      espera_interrompivel 40; printf '| '; espera_interrompivel 7; printf '| '; espera_interrompivel 60 )
check "espera: fatias de 15s, total exato" "15 15 10 | 7 | 15 15 15 15 " "$_r"

# Vale (3.9.80): monstro do jogo, regra do dono e fazer dano com golpe, erva
# e pedra. Uma acao a cada 5s: erva e pedra de graca a cada 1 min, golpe no
# resto; erva que cobra ouro fica de fora. Relogio virtual de 70s.
#   _vl80 [ouro] -> sequencia de acoes (e=erva p=pedra h=golpe m=mana)
_vl80() {
    ( TMP="$_td20/vale_$1"; URL=http://jogo; SLS_PACING=0; export TMP URL SLS_PACING; mkdir -p "$TMP"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/undying.sh" > /dev/null 2>&1
      _pg="$TMP/pagina.html"
      _er="<a href='/undying/grass/?r=7'>Erva (844)</a>"
      [ "$1" = ouro ] && _er="<a href='/undying/grass/?r=7'>Erva <img src='/images/icon/gold.png' alt='g'/> 5</a>"
      printf "%s" "<img src='/images/icon/level.png'/> <a href='/undying/hit/?r=1'>Bater</a> $_er <a href='/undying/stone/?r=8'>Pedra (208)</a> <a href='/undying/?out_gate'>sair</a>" > "$_pg"
      cp "$_pg" "$TMP/SRC"; echo 100000 > "$TMP/relogio"; : > "$TMP/req"
      date() { case "$1" in +%s) cat "$TMP/relogio" ;; *) command date "$@" ;; esac; }
      sleep() { _s=${1%s}; _s=${_s%%.*}; read -r _c < "$TMP/relogio"; echo $(( _c + ${_s:-0} )) > "$TMP/relogio"; }
      run_curl_exec() { echo "$1" >> "$TMP/req"; cat "$_pg"; }
      time_exit() { wait "$!" 2>/dev/null; }
      luta_teto() { echo $(( `cat "$TMP/relogio"` + 70 )); }
      cd "$TMP" && undying_fight > "$TMP/out" 2>&1
      sed -n 's|.*/undying/\([a-z]*\)/.*|\1|p' "$TMP/req" | sed 's/grass/e/; s/stone/p/; s/hit/h/; s/mana/m/' | tr -d '\n'
      printf '|%s' "$(grep -o 'Vale: .*;' "$TMP/out")"; [ -s "$TMP/vale_luta.html" ] && printf 'pagina' )
}
check "Vale: erva e pedra a cada 1 min, golpe no resto (uma acao a cada 5s)" \
    "ephhhhhhhhhheph|Vale: 11 golpes (hit 11, mana 0), erva 2, pedra 2;pagina" "`_vl80 gratis`"
check "Vale: erva que cobra ouro nao e usada" \
    "phhhhhhhhhhhphh|Vale: 13 golpes (hit 13, mana 0), erva 0, pedra 2;pagina" "`_vl80 ouro`"
_r=`( cd "$_td20" && . "$LIB/info.sh" > /dev/null 2>&1
      printf '%s' "<a href='/undying/grass/?r=7'>Erva <img src='/images/icon/gold.png'/> 5</a><a href='/undying/stone/?r=8'>Pedra (2)</a>" > it.html
      itens_gratis undying it.html; printf '[%s][%s]' "\`cat GRASS\`" "\`cat STONE\`" )`
check "itens_gratis: erva com preco em ouro fora, pedra gratis dentro" "[][/undying/stone/?r=8]" "$_r"

# Coliseu (3.9.81): o preparo so quando ha luta. Modo grafico uma vez por
# worker; /train so antes de entrar. Antes, cada tentativa sem luta da
# madrugada fazia os dois.
#   _col81 luta|nada -> pedidos de tres tentativas
_col81() {
    ( TMP="$_td20/col81_$1"; URL=http://jogo; SLS_PACING=0; export TMP URL SLS_PACING; mkdir -p "$TMP"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/coliseum.sh" > /dev/null 2>&1
      unset COLISEU_GRAFICO; FUNC_coliseum=y; : > "$TMP/req"
      run_curl_exec() { _u=${1#http://jogo}; _u=${_u%%\?*}; echo "$_u" >> "$TMP/req"; printf %s "$_u" > "$TMP/.ult_req"
          if [ "$PG" = luta ]; then echo "<img src='/images/icon/level.png'/> <a href='/coliseum/enterFight/?r=`wc -l < "$TMP/req"`'>Entrar</a>"
          else echo "<img src='/images/icon/level.png'/> <a href='/coliseum/'>Coliseu</a>"; fi; }
      # TREINO=sai: o full_atualizar pede o /train (leitura vencida).
      full_atualizar() { [ "$TREINO" = sai ] && { echo /train >> "$TMP/req"; printf /train > "$TMP/.ult_req"; }; echo 4608 > "$1"; }
      batalha_marcar() { :; }; time_exit() { wait "$!" 2>/dev/null; }; sleep() { :; }
      coliseum_luta() { :; }
      PG="$1"; cd "$TMP"
      if [ "$PG" = luta ]; then
          # Para na inscricao (batalha_marcar sai do subshell): basta ver a
          # ordem do preparo.
          ( batalha_marcar() { echo "entra=$go_stop" >> "$TMP/req"; exit 0; }; coliseum_fight > /dev/null 2>&1 )
      else
          coliseum_fight > /dev/null 2>&1; coliseum_fight > /dev/null 2>&1; coliseum_fight > /dev/null 2>&1
      fi
      tr '\n' ' ' < "$TMP/req" )
}
check "coliseu sem luta: 1 pedido por tentativa (grafico uma vez, sem /train)" \
    "/settings/graphics/0 /coliseum /coliseum /coliseum " "`_col81 nada`"
# O clique sai sempre da ultima pagina: depois do /train o /coliseum e
# relido e o nonce e o dele (r=4, nao o r=2 da pagina de antes do /train).
check "coliseu com luta: /train e o /coliseum relido antes de entrar" \
    "/settings/graphics/0 /coliseum /train /coliseum entra=/coliseum/enterFight/?r=4 " "`TREINO=sai _col81 luta`"
check "coliseu com luta, HP maximo em dia: entra com a pagina lida" \
    "/settings/graphics/0 /coliseum entra=/coliseum/enterFight/?r=2 " "`TREINO=fica _col81 luta`"
check "painel: /questrnd aparece como Missao Aleatoria, /quest como Missoes" "Missão Aleatória|Missões" \
    "`cd "$_td20" && . "$LIB/panel.sh" > /dev/null 2>&1; mkdir -p ab81; printf '/questrnd/take/' > ab81/pagina; aba_de_v ab81; printf '%s|' "$_ABA"; printf '/quest/' > ab81/pagina; aba_de_v ab81; printf '%s' "$_ABA"`"

# status.sh -batalhas (lib/batalhas.sh): resumo da ultima batalha de cada evento, por conta, lendo o
# sls.log (e o .1 da rotacao). Somente leitura.
mkdir -p "$_td20/bt/BR_Ana" "$_td20/bt/BR_Bia"
printf '%s\n' "https://jogo 12:25" "King of the Immortals will be started..." "Em batalha - HP: 900" \
    "Alvo aliado — trocando de alvo" "Em batalha - HP: 300" "Battle over. (o jogo declarou o fim da batalha)" "King ok" \
    > "$_td20/bt/BR_Ana/sls.log.1"
printf '%s\n' "https://jogo 22:25" "King of the Immortals will be started..." "Em batalha - HP: 800" \
    "Battle over. (assassinado por Zé (log da batalha))" "King ok" \
    "https://jogo 21:55" "Valley of the Immortals will be started... 21h:55m" "Em batalha undying" \
    "Vale: 1 golpes (hit 1, mana 0), erva 1, pedra 0; primeiro golpe 22:00:04, ultimo 0s depois" "Undying ok" \
    > "$_td20/bt/BR_Ana/sls.log"
printf '%s\n' "https://jogo 16:25" "King of the Immortals will be started..." "Em batalha - HP: 50" > "$_td20/bt/BR_Bia/sls.log"
_r=`SLS_HOME="$_td20/bt" sh "$ROOT/status.sh" -batalhas | sed 's/  */ /g'`
check "batalhas.sh: ultima batalha de cada evento, por conta" "== Rei
 Ana 22:25 1 acoes HPmin 800 trocas 0 fogo 0 assassinado por Zé (log da batalha)
 Bia 16:25 1 acoes HPmin 50 trocas 0 fogo 0 em andamento (ou sem fim no log)

== Vale
 Ana 21:55 1 acoes HPmin - trocas 0 fogo 0 - >> 1 golpes (hit 1, mana 0), erva 1, pedra 0; primeiro golpe 22:00:04, ultimo 0s depois" "$_r"
check "batalhas.sh: filtro por evento e por conta" "== Rei
 Bia 16:25 1 acoes HPmin 50 trocas 0 fogo 0 em andamento (ou sem fim no log)" \
    "`SLS_HOME="$_td20/bt" sh "$ROOT/status.sh" -batalhas Rei Bia | sed 's/  */ /g'`"

# ---- 3.9.83: defeitos das batalhas (revisao de 12/10), sem mudar estrategia
# Luta de volta zera a contagem do "fora": a 2a transicao da luta nao encerra
# na hora (antes: a marca da 1a valia para sempre).
_r=`( TMP="$_td20/f83a"; mkdir -p "$TMP"; export TMP; . "$LIB/info.sh" > /dev/null 2>&1
      printf '%s' "<img src='/images/icon/level.png'/> <a href='/logout'>sair</a> Saguao" > "$TMP/fora.html"
      luta_inicio; _lt_lutou=1; _lt_fora_desde=$(( \`date +%s\` - 300 )); _lt_invalidas=2
      luta_hp 5000; luta_hp 4800
      if luta_acabou "$TMP/fora.html" clanfight > /dev/null; then printf 'saiu'; else printf 'ficou'; fi
      printf ' inval=%s' "$_lt_invalidas" )`
check "luta de volta: a 2a transicao nao encerra na hora (fora zerado)" "ficou inval=0" "$_r"
# Ressurreicao sem resposta nao gasta a trava: ate duas novas tentativas.
_r=`( TMP="$_td20/f83b"; URL=http://jogo; SLS_PACING=0; mkdir -p "$TMP"; export TMP URL SLS_PACING
      . "$LIB/info.sh" > /dev/null 2>&1
      run_curl_exec() { :; }; time_exit() { wait "$!" 2>/dev/null; return 1; }
      luta_inicio
      for _i in 1 2 3 4; do
          printf '%s' "<a href='/king/unrip/?r=5'>Reviver</a>" > "$TMP/SRC"
          if ressuscitar king "$TMP/SRC" > /dev/null; then printf 'T'; else printf 'n'; fi
      done )`
check "ressuscitar: pedido sem resposta tenta de novo (2x), depois trava" "TTTn" "$_r"
# A hora da agenda e lida depois da ida a rede (clan_id e retomada): um
# /clan lento ou uma luta retomada que cruzam o 12:30 nao caem no Rei fora
# da janela (3.9.87; antes, so a retomada relia a hora).
#   _hr87 clan|retomada -> ramos que rodaram
_hr87() {
    ( TMP="$_td20/hr87_$1"; mkdir -p "$TMP"; export TMP
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1; . "$LIB/run.sh" > /dev/null 2>&1
      _M=29; relogio_sync() { _HH=12; _MM=$_M; }; RUN=-boot
      if [ "$1" = clan ]; then CLD=""; clan_id() { _M=30; CLD=1; }; batalha_retomar() { return 1; }
      else CLD=1; batalha_retomar() { _M=30; return 0; }; fi
      evento_dedicar() { :; }; evento_espera() { :; }; king_start() { printf 'REI '; }; start() { printf 'ROTINA'; }
      sls_play 2>/dev/null )
}
check "cronograma: hora lida depois do clan_id lento" ROTINA "`_hr87 clan`"
check "cronograma: hora lida depois de uma retomada" ROTINA "`_hr87 retomada`"
unset -f _hr87
# Releitura dupla: com a pagina sem luta, uma leitura por volta (eram duas).
#   _rl83 MODULO SECAO FUNCAO -> pedidos de pagina em 12s de relogio virtual
_rl83() {
    ( TMP="$_td20/rl83_$1"; URL=http://jogo; SLS_PACING=0; export TMP URL SLS_PACING; mkdir -p "$TMP"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/allies.sh" > /dev/null 2>&1; . "$LIB/$1.sh" > /dev/null 2>&1
      _pg="$TMP/pagina.html"
      printf "%s" "<img src='/images/icon/level.png'/> <img src='/images/icon/health.png' alt='hp'/> 8000 <a href='/logout'>sair</a> Saguao" > "$_pg"
      for _f in SRC src.html x_src; do cp "$_pg" "$TMP/$_f"; done
      echo 10000 > "$TMP/FULL"; echo 10000 > "$TMP/x_full"; src_ram="$TMP/x_src"; full_ram="$TMP/x_full"
      echo 100000 > "$TMP/relogio"; : > "$TMP/req"; LUTA_FORA_MAX=600
      date() { case "$1" in +%s) cat "$TMP/relogio" ;; *) command date "$@" ;; esac; }
      sleep() { _s=${1%s}; _s=${_s%%.*}; read -r _c < "$TMP/relogio"; echo $(( _c + ${_s:-0} )) > "$TMP/relogio"; }
      run_curl_exec() { echo "$1" >> "$TMP/req"; cat "$_pg"; }
      fetch_page() { echo "$1" >> "$TMP/req"; cp "$_pg" "${2:-$TMP/SRC}"; }
      time_exit() { wait "$!" 2>/dev/null; }
      luta_teto() { echo $(( $(cat "$TMP/relogio") + 12 )); }
      func_unset() { :; }
      cd "$TMP" && $3 > /dev/null 2>&1
      wc -l < "$TMP/req" | tr -d ' ' )
}
for _m in "clanfight clanfight clanfight_fight" "altars altars altars_fight" "flagfight flagfight flagfight_fight"; do
    set -- $_m
    _r=`_rl83 "$1" "$2" "$3"`
    if [ "$_r" -ge 5 ] && [ "$_r" -le 16 ]; then ok "$1: sem luta na tela, uma leitura por volta ($_r em 12s)"
    else bad "$1: releitura dupla sem luta na tela ($_r em 12s)"; fi
done
# A releitura de /king fica DENTRO do "if _reconf = 0" (antes vinha antes dele).
_r=`sed -n '/^  cl_access() {/,/^  }/p' "$LIB/king.sh" | awk -v a='_reconf:-0}" = 0 ]; then' -v b='run_curl_exec "${URL}/king"' 'index($0, a) && !i { i = NR } index($0, b) && !r { r = NR } END { print (i && r && i < r) ? "dentro" : "fora" }'`
check "Rei: a reconfirmacao rele /king uma vez so" dentro "$_r"
check "BREAK_LOOP zerado antes da 1a leitura (cinco modulos)" "5" \
    "$(for _m in clanfight clandmg altars clancoliseum flagfight; do sed -n '/^  luta_inicio/,/^  cf_access$/p' "$LIB/$_m.sh" | grep -c '^  : > BREAK_LOOP$'; done | awk '{ s += $1 } END { print s }')"
check "espera da recarga nunca passa de LA (relogio voltando)" "6" \
    "`cat "$LIB/clanfight.sh" "$LIB/clandmg.sh" "$LIB/altars.sh" "$LIB/clancoliseum.sh" "$LIB/flagfight.sh" "$LIB/clancommand.sh" | grep -c '\[ "\$_resta" -le "\$LA" \] || _resta=\$LA'`"
# Erva depois da cura: link (nonce) da pagina nova.
_r=`( TMP="$_td20/f83e"; URL=http://jogo; SLS_PACING=0; export TMP URL SLS_PACING; mkdir -p "$TMP"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/allies.sh" > /dev/null 2>&1; . "$LIB/clanfight.sh" > /dev/null 2>&1
      _cab="<img src='/images/icon/level.png'/> <img src='/images/icon/health.png' alt='hp'/> 1000 "
      printf '%s' "$_cab<a href='/clanfight/attack/?r=1'>a</a><a href='/clanfight/dodge/?r=2'>d</a><a href='/clanfight/heal/?r=3'>c</a><a href='/clanfight/grass/?r=7'>Erva (5)</a>" > "$TMP/SRC"
      printf '%s' "$_cab<a href='/clanfight/attack/?r=11'>a</a><a href='/clanfight/dodge/?r=12'>d</a><a href='/clanfight/grass/?r=9'>Erva (4)</a>" > "$TMP/pos"
      echo 10000 > "$TMP/FULL"; echo 100000 > "$TMP/relogio"; : > "$TMP/req"
      date() { case "$1" in +%s) cat "$TMP/relogio" ;; *) command date "$@" ;; esac; }
      sleep() { _s=${1%s}; _s=${_s%%.*}; read -r _c < "$TMP/relogio"; echo $(( _c + ${_s:-0} )) > "$TMP/relogio"; }
      run_curl_exec() { echo "$1" >> "$TMP/req"; cat "$TMP/pos"; }
      time_exit() { wait "$!" 2>/dev/null; }
      luta_teto() { echo $(( \`cat "$TMP/relogio"\` + 2 )); }
      func_unset() { :; }
      cd "$TMP" && clanfight_fight > /dev/null 2>&1
      grep -o 'grass/?r=[0-9]*' "$TMP/req" | head -n 1 )`
check "Torneio: a erva depois da cura usa o link da pagina nova" "grass/?r=9" "$_r"
# Rotina: com batalha pendente (sessao caida na luta) nao roda as atividades,
# e nao tenta outra retomada: quem chama acabou de tentar (3.9.86).
_r=`( TMP="$_td20/f83f"; mkdir -p "$TMP"; export TMP; . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1
      batalha_marcar king
      batalha_retomar() { printf 'retomou '; return 0; }
      servidor_mudo() { printf 'ATIVIDADES '; return 0; }
      tarefas_livres; printf '| '
      batalha_limpar
      tarefas_livres )`
check "rotina: batalha pendente segura as atividades, sem nova retomada" \
    "| ATIVIDADES Servidor sem resposta - atividades na proxima volta" "$_r"
check "start: retomada logo depois do login" 1 \
    "`sed -n '/^start() {/,/^}/p' "$LIB/crono.sh" | grep -c '^    batalha_retomar$'`"
# evento_cancelar so apaga a batalha do proprio evento; anotacao vale ate o
# teto da luta + 10 min.
_r=`( TMP="$_td20/f83g"; mkdir -p "$TMP"; export TMP; . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1
      batalha_marcar flagfight; evento_cancelar clancoliseum; batalha_pendente && printf 'fica '
      evento_cancelar flagfight; batalha_pendente || printf 'sai '
      printf 'king %s\n' $(( \`date +%s\` - 35 * 60 )) > "$TMP/batalha"; batalha_pendente && printf 'vale35 '
      printf 'king %s\n' $(( \`date +%s\` - 45 * 60 )) > "$TMP/batalha"; batalha_pendente || printf 'vence45' )`
check "evento_cancelar: so a propria batalha; anotacao ate teto+10min" "fica sai vale35 vence45" "$_r"

# ---- 3.9.84: rotina e login (revisao de 12/10)
# Versao do log: nunca atras do ultimo commit (estava parada em 3.9.64).
_vn=`sed -n 's/^versionNum="\(.*\)"$/\1/p' "$LIB/info.sh" | head -n 1`
_vg=`git -C "$ROOT" log --format=%s 2>/dev/null | grep -o '(3\.[0-9]*\.[0-9]*)' | tr -d '()' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1`
if [ -z "$_vg" ]; then ok "versionNum: sem git aqui, nada a comparar ($_vn)"
elif [ "`printf '%s\n%s\n' "$_vg" "$_vn" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1`" = "$_vn" ]; then ok "versionNum ($_vn) nao fica atras do ultimo commit ($_vg)"
else bad "versionNum ($_vn) atras do ultimo commit ($_vg)"; fi
unset _vn _vg
# Nas duas tabelas: a do BR (sls_play) e a do russo (cronograma_ru).
check "evento especial: a chamada direta marca o portao (sem repetir no start), BR e RU" "1 1" \
    "`sed -n '/^sls_play() {/,/^}/p' "$LIB/run.sh" | sed -n '/(09:2\[5-9\]|21:2\[5-9\])/,/;;/p' | grep -c '^ *ativ_marcar evento$'` `sed -n '/^cronograma_ru() {/,/^}/p' "$LIB/run.sh" | sed -n '/(09:2\[5-9\]|21:2\[5-9\])/,/;;/p' | grep -c '^ *ativ_marcar evento$'`"
check "modo -cl: arena so pelo portao (tarefas_livres), sem echo|grep" "0 0" \
    "`sed -n '/^        (\*)/,/;;/p' "$LIB/run.sh" | grep -c '^ *arena_duel$'` `sed -n '/^        (\*)/,/;;/p' "$LIB/run.sh" | grep -c 'echo "\$RUN" | grep'`"
_r=`( . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1; URL=http://jogo
      HOUR=""; _o=\`func_crono -q\`; func_crono -q; printf '[%s] %s' "$_o" "${HOUR:+hora}" )`
check "func_crono -q: so atualiza a hora, sem escrever no log" "[] hora" "$_r"
check "reconexao: um /user depois do login, sem sleep 1 (eram dois)" "2 0" \
    "`sed -n '/^login_autenticar() {/,/^}/p;/^login_logoff() {/,/^}/p' "$LIB/loginlogoff.sh" | grep -c '"\${URL}/user"'` `sed -n '/^login_autenticar() {/,/^}/p;/^login_logoff() {/,/^}/p' "$LIB/loginlogoff.sh" | grep -c '^ *sleep 1$'`"
_r=`( TMP="$_td20/f84c"; mkdir -p "$TMP"; export TMP; URL=http://jogo; TMP_COOKIE="$TMP/ck"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/session_check.sh" > /dev/null 2>&1; . "$LIB/loginlogoff.sh" > /dev/null 2>&1
      printf '%s' '@@@' > "$TMP/cript_file"; : > "$TMP/req"
      run_curl() { case "$*" in *sign_in*data*|*data*sign_in*) echo POST >> "$TMP/req" ;; *) echo GET >> "$TMP/req" ;; esac
                   printf '%s' "<form><input name='pass'></form>"; }
      login_lock() { echo LOCK >> "$TMP/req"; }; login_unlock() { echo UNLOCK >> "$TMP/req"; }
      login_logoff > /dev/null 2>&1; printf 'rc=%s ' $?; grep -c POST "$TMP/req"; grep -c LOCK "$TMP/req" )`
# Desde a 3.9.87 a credencial e lida antes da trava: ilegivel, nem trava.
check "reconexao: credencial ilegivel nao vira POST nem pega a trava" "rc=1 0
0" "$_r"
check "trava de login: espera de 3 em 3s, PID lido sem cat" "1 1 0" \
    "`sed -n '/^login_lock() {/,/^}/p' "$LIB/sls.sh" | grep -c '^ *sleep 3$'` `sed -n '/^login_lock() {/,/^}/p' "$LIB/sls.sh" | grep -c '_n" -lt 60'` `sed -n '/^login_lock() {/,/^}/p' "$LIB/sls.sh" | grep -c 'cat "\$LOCKDIR/pid"'`"
check "fim de luta sem pausa morta (fora o Duelo, entre as rodadas)" 0 \
    "`cat "$LIB/flagfight.sh" "$LIB/king.sh" "$LIB/altars.sh" "$LIB/clanfight.sh" "$LIB/clancoliseum.sh" "$LIB/clancommand.sh" "$LIB/undying.sh" | grep -c '^  sleep 1[05]s$'`"
check "play.sh: espera o worker sair em vez de 2s fixos por conta" 0 \
    "`sed -n '/^kill_worker_tree() {/,/^}/p' "$ROOT/play.sh" | grep -c '^    sleep 2$'`"

# ---- 3.9.85: menos processos na rotina, o mesmo resultado ----
# Os comandos externos viram funcoes que anotam a chamada e repassam.
_cnt85() { for _c in grep sed head tr awk cat date; do eval "$_c() { echo $_c >> \"\$TMP/cmd\"; command $_c \"\$@\"; }"; done; }
_r=`( TMP="$_td20/f85a"; mkdir -p "$TMP"; . "$LIB/info.sh" > /dev/null 2>&1; _cnt85; : > "$TMP/cmd"
      FIXHP=""; ACC_ENE=1555; ACC_LVL=""
      parse_status "<title>X</title><img src='/images/icon/health.png' alt='hp'/>
<img src='/images/icon/health.png' alt='hp'/> <span class='white'>65312</span> | <img src='/images/icon/mana.png' alt='mp'/> <span class='white'>809</span>
<img src='/images/icon/level.png' alt='lvl'/> 90 <img src='/images/icon/gold.png' alt='g'/> 1.234 <img src='/images/icon/silver.png' alt='s'/> 408,1M
<img src='/images/icon/gold.png' alt='g'/> 7"
      unset -f grep sed head tr awk cat date
      printf '%s/%s/%s/%s/%s ' "$ACC_HP" "$ACC_MP" "$ACC_LVL" "$ACC_GOLD" "$ACC_SILVER"; grep -c '^grep$' "$TMP/cmd"; grep -c '^tr$' "$TMP/cmd" )`
check "parse_status: os cinco numeros num grep so, energia sem tr" "65312/809/90/1.234/408,1M 1
0" "$_r"
_r=`( TMP="$_td20/f85b"; mkdir -p "$TMP"; . "$LIB/session_check.sh" > /dev/null 2>&1; _cnt85; : > "$TMP/cmd"
      _cr=\`printf '\\r'\`; printf '[%s]' "\`extract_username "<head><title>  gatuno $_cr</title>"\`"; command wc -l < "$TMP/cmd"
      printf '[%s]' "\`extract_username "<title></title><title>Outra</title>"\`"
      printf '[%s]' "\`extract_username "<title>NNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN</title>"\`" )`
check "extract_username: titulo comum sem processo; vazio e comprido pelo grep" "[gatuno]0
[Outra][NNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN]" "$_r"
_r=`( TMP="$_td20/f85c"; mkdir -p "$TMP"; . "$LIB/function.sh" > /dev/null 2>&1; _cnt85
      printf 'FUNC_trade=n\r\nFUNC_trade_dias\nALLIES=a:b\n' > "$TMP/config.cfg"; : > "$TMP/cmd"
      load_config; unset -f grep sed head tr awk cat date; printf '%s %s %s ' "$FUNC_trade" "$FUNC_trade_dias" "$ALLIES"; grep -c '^grep$' "$TMP/cmd"
      grep -c '^FUNC_trade_dias=365$' "$TMP/config.cfg"; grep -c '=' "$TMP/config.cfg" )`
check "load_config: chaves que faltam num awk so (era um grep por chave)" "n 365 a:b 1
1
22" "$_r"
_r=`( TMP="$_td20/f85d"; mkdir -p "$TMP/p"; . "$LIB/check.sh" > /dev/null 2>&1; _cnt85
      FUNC_collect_mission_rewards=y; FUNC_check_rewards=y
      fetch_page() { echo "$1" >> "$TMP/req"; case "$1" in
          /quest/) [ -f "$TMP/q1" ] && echo "<a href='/quest/end/10?r=5'>" > "$TMP/SRC" || echo "<a href='/quest/end/012?r=9'><a href='/quest/end/1?r=3'> <a href='/quest/end/1?r=4'>
<a href='/quest/openChest/2/?r=8'>" > "$TMP/SRC" ;;
          /quest/end/1*) : > "$TMP/q1"; : > "$TMP/SRC" ;;
          /relic/reward/) echo "<a href='/relic/reward/3?r=1'><a href='/relic/reward/11/?r=2'>" > "$TMP/SRC"; : > "$TMP/r" ;;
          *) : > "$TMP/SRC" ;; esac; }
      : > "$TMP/cmd"; check_missions > /dev/null; check_rewards > /dev/null; unset -f grep sed head tr awk cat date; tr '\n' ' ' < "$TMP/req"; grep -c '^grep$' "$TMP/cmd" )`
check "missoes e reliquias: um grep por pagina, os mesmos cliques" "/quest/ /quest/openChest/2/?r=8 /quest/ /quest/end/1?r=3 /quest/ /quest/end/10?r=5 /quest/ /collector/ /relic/reward/ /relic/reward/11/?r=2 /relic/reward/ 8" "$_r"
_r=`( TMP="$_td20/f85e"; mkdir -p "$TMP"; . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1
      date() { echo "$1" >> "$TMP/d"; case "$1" in +%M%S) echo 5602 ;; +%M) echo 56 ;; +%S) echo 02 ;; +%s) echo 1000 ;; esac; }
      sleep() { :; }; evento_dedicar
      [ "\`cat "$TMP/em_evento"\`" = $(( 1000 + 240 - $$ % 10 )) ] && printf 'hora_certa '; wc -l < "$TMP/d" )`
check "evento_dedicar: minuto e segundo de um date so" "hora_certa 2" "$_r"
_r=`( TMP="$_td20/f85f"; mkdir -p "$TMP"; . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1
      batalha_pendente() { return 0; }; batalha_retomar() { echo RETOMOU >> "$TMP/r"; }
      clan_id() { echo ROTINA >> "$TMP/r"; }; stats_liberado() { echo ROTINA >> "$TMP/r"; return 1; }
      tarefas_livres > /dev/null 2>&1; printf 'rc=%s ' $?; cat "$TMP/r" 2>/dev/null | tr '\n' ' ' )`
check "tarefas_livres: com batalha pendente nao roda a rotina nem tenta a 3a retomada" "rc=0 " "$_r"
_r=`( TMP="$_td20/f85g"; URL=http://jogo; export TMP URL; mkdir -p "$TMP"; . "$LIB/info.sh" > /dev/null 2>&1
      run_curl_exec() { printf '%s' "<a href=/altars/dod"; return 18; }
      printf '%s' "<a href=/altars/unrip/?r=777>rev</a>" > "$TMP/pag"; luta_inicio altars > /dev/null 2>&1
      ressuscitar altars "$TMP/pag" > /dev/null 2>&1; printf 'rc=%s reviveu=%s falhas=%s' $? "$_reviveu" "$_rs_falhas" )`
check "ressuscitar: pagina cortada (curl 18) nao gasta a ressurreicao" "rc=0 reviveu=0 falhas=1" "$_r"
check "Vale: o primeiro golpe so dispensa a releitura quando respondeu inteiro" "1 1" \
    "`grep -c 'time_exit 17 && \[ "\${TE_RC:-0}" = 0 \] && \[ -s "\$TMP/SRC" \] && _VL_PAGINA0=1' "$LIB/undying.sh"` `grep -c 'if \[ "\${_VL_PAGINA0:-0}" != 1 \]; then' "$LIB/undying.sh"`"
_r=`( TMP="$_td20/f85h"; mkdir -p "$TMP"; export TMP; URL=http://jogo; TMP_COOKIE="$TMP/ck"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/session_check.sh" > /dev/null 2>&1; . "$LIB/loginlogoff.sh" > /dev/null 2>&1
      printf '%s' 'login=a&pass=b' | base64 > "$TMP/cript_file"
      # Primeiro /user: o jogo diz que a conta saiu; dai em diante, sem rede.
      run_curl() { [ -f "$TMP/n" ] && return 7; : > "$TMP/n"; printf '%s' 'x jsInterface.event("user=0;") y'; }
      login_lock() { :; }; login_unlock() { :; }
      login_logoff 2>&1 | grep -c 'falha ao reconectar (sem resposta do servidor)' )`
check "reconexao: o log diz quando foi rede, e nao senha recusada" 1 "$_r"
unset -f _cnt85

# ---- 3.9.87: itens aprovados pelo dono ----
# Coliseu da madrugada: sem luta, um pulso por minuto (o resto do minuto e
# como um minuto comum); com luta, como antes.
#   _cp87 nada|luta -> chamadas em tres voltas no 03:15 e uma no 03:25
_cp87() {
    ( TMP="$_td20/cp87_$1"; mkdir -p "$TMP"; export TMP; : > "$TMP/r"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1; . "$LIB/run.sh" > /dev/null 2>&1
      _HORA=03:15; relogio_sync() { _HH=${_HORA%:*}; _MM=${_HORA#*:}; }
      batalha_retomar() { return 1; }; CLD=1; RUN=-boot
      coliseum_fight() { echo COL >> "$TMP/r"; if [ "$ACHA" = nada ]; then COLISEU_SEM_LUTA=1; else COLISEU_SEM_LUTA=0; fi; }
      tarefas_livres() { :; }; descansar() { :; }; sleep() { :; }; func_crono() { :; }
      func_sleep() { echo ESPERA >> "$TMP/r"; }
      ACHA=$1; sls_play; sls_play; sls_play; _HORA=03:25; sls_play
      tr '\n' ' ' < "$TMP/r" )
}
check "Coliseu sem luta: um pulso por minuto, o resto do minuto e comum" "COL ESPERA ESPERA COL " "`_cp87 nada`"
check "Coliseu com luta: pulso de novo no mesmo minuto, como antes" "COL COL COL COL " "`_cp87 luta`"
# Rei: pagina vazia (rede) antes da releitura nao adianta a morte do rei; a
# virada de pagina de verdade (pagina do jogo sem acao) adianta.
#   _rei87 vazia|virada -> quantas vezes a fase "Rei morto" apareceu
_rei87() {
    ( TMP="$_td20/rei87_$1"; URL=http://jogo; SLS_PACING=0; export TMP URL SLS_PACING; mkdir -p "$TMP"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/allies.sh" > /dev/null 2>&1; . "$LIB/king.sh" > /dev/null 2>&1
      _f="<img src='/images/icon/level.png'/> <img src='/images/icon/health.png' alt='hp'/> 9000 <a href='/logout'>sair</a>"
      _comrei="$_f <a href='/king/attack/?r=1'>a</a><a href='/king/kingatk/?r=2'>k</a><a href='/king/dodge/?r=3'>d</a>"
      _semrei="$_f <a href='/king/attack/?r=4'>a</a><a href='/king/dodge/?r=5'>d</a>"
      printf '%s' "$_comrei" > "$TMP/SRC"; echo 10000 > "$TMP/FULL"; echo 100000 > "$TMP/relogio"; : > "$TMP/req"
      date() { case "$1" in +%s) cat "$TMP/relogio" ;; *) command date "$@" ;; esac; }
      sleep() { _s=${1%s}; _s=${_s%%.*}; read -r _c < "$TMP/relogio"; echo $(( _c + ${_s:-0} )) > "$TMP/relogio"; }
      PRIM=$1
      run_curl_exec() { echo "$1" >> "$TMP/req"; case `wc -l < "$TMP/req"` in
          *[!0-9]1|1) [ "$PRIM" = vazia ] || printf '%s' "$_f" ;;
          *[!0-9]2|2) printf '%s' "$_semrei" ;;
          *)          printf '%s' "$_comrei" ;; esac; }
      luta_teto() { echo $(( $(cat "$TMP/relogio") + 20 )); }; func_unset() { :; }
      cd "$TMP" && king_fight 2>&1 | grep -c 'Rei morto' )
}
check "Rei: pagina vazia antes da releitura nao troca a fase" 0 "`_rei87 vazia`"
check "Rei: virada de pagina do jogo adianta a morte do rei, como antes" 1 "`_rei87 virada`"
# Cura: pedido que nem chegou ao servidor (curl 7) nao gasta a recarga de
# 90s; tempo esgotado (28) gasta, porque o elixir pode ter sido usado.
#   _rec87 CODIGO_DO_CURL -> pedidos de cura em 12s de relogio virtual
_rec87() {
    ( TMP="$_td20/rec87_$1"; URL=http://jogo; SLS_PACING=0; export TMP URL SLS_PACING; mkdir -p "$TMP"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/allies.sh" > /dev/null 2>&1; . "$LIB/clanfight.sh" > /dev/null 2>&1
      _cab="<img src='/images/icon/level.png'/> <img src='/images/icon/health.png' alt='hp'/> 1000 <a href='/logout'>sair</a>"
      printf '%s' "$_cab<a href='/clanfight/attack/?r=1'>a</a><a href='/clanfight/heal/?r=3'>c</a>" > "$TMP/pag"
      cp "$TMP/pag" "$TMP/SRC"; echo 10000 > "$TMP/FULL"; echo 100000 > "$TMP/relogio"; : > "$TMP/req"
      date() { case "$1" in +%s) cat "$TMP/relogio" ;; *) command date "$@" ;; esac; }
      sleep() { _s=${1%s}; _s=${_s%%.*}; read -r _c < "$TMP/relogio"; echo $(( _c + ${_s:-0} )) > "$TMP/relogio"; }
      RC=$1
      # A cura que chega ao servidor sobe o HP (desde a 3.9.110 a recarga so
      # conta com a pagina confirmando; com o HP igual sairia uma nova
      # tentativa, que nao e o que este teste mede).
      printf '%s' "$_cab<a href='/clanfight/attack/?r=1'>a</a><a href='/clanfight/heal/?r=3'>c</a>" | sed 's/> 1000 /> 9000 /' > "$TMP/curada"
      run_curl_exec() { echo "$1" >> "$TMP/req"
          case "$1" in */heal/*) [ -f "$TMP/falhou" ] || { : > "$TMP/falhou"; return "$RC"; }; cp "$TMP/curada" "$TMP/pag" ;; esac
          cat "$TMP/pag"; }
      luta_teto() { echo $(( $(cat "$TMP/relogio") + 12 )); }; func_unset() { :; }
      cd "$TMP" && clanfight_fight > /dev/null 2>&1
      grep -c '/heal/' "$TMP/req" )
}
check "cura sem conexao (curl 7): tenta de novo, a recarga nao foi gasta" 2 "`_rec87 7`"
check "cura com tempo esgotado (curl 28): recarga gasta, sem segundo elixir" 1 "`_rec87 28`"
check "recarga so com o pedido no servidor: 7 modulos de cla e eventos, Rei e Coliseu" "12 2 2" \
    "`cat "$LIB/clanfight.sh" "$LIB/clandmg.sh" "$LIB/altars.sh" "$LIB/clancoliseum.sh" "$LIB/flagfight.sh" "$LIB/clancommand.sh" | grep -c 'if \[ "\$_saiu" = 1 \]; then'` `grep -c 'pedido_nao_saiu && _saiu=0' "$LIB/king.sh"` `grep -c 'pedido_nao_saiu && _saiu=0' "$LIB/coliseum.sh"`"
# Vale: o /train do hpmp sai uma vez so quando o fetch_train_stats acabou de
# ler um (sem a mana na pagina, o segundo dava a mesma); sem resposta, sai
# o segundo como antes.
#   _hp87 responde|mudo -> pedidos de /train
_hp87() {
    ( TMP="$_td20/hp87_$1"; URL=http://jogo; export TMP URL; mkdir -p "$TMP"; : > "$TMP/req"; : > "$TMP/SRC"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1
      MODO=$1
      run_curl() { echo "$1" >> "$TMP/req"; printf %s /train > "$TMP/.ult_req"; [ "$MODO" = mudo ] || echo "Saude: 100 (4608) Energia: 1555"; }
      run_curl_exec() { echo "$1" >> "$TMP/req"; printf %s /train > "$TMP/.ult_req"; }
      time_exit() { wait "$!" 2>/dev/null; }
      FIXHP=""; FIXMP=""; ACC_ENE=""
      hpmp -fix; grep -c '/train' "$TMP/req" )
}
check "Vale: hpmp sem o segundo /train quando o primeiro respondeu" 1 "`_hp87 responde`"
check "Vale: hpmp com o primeiro /train mudo pede o segundo, como antes" 2 "`_hp87 mudo`"
# Painel: a Home do descanso no lugar do /user, so depois de conferida.
#   _st87 CASO -> pedidos de /user em quatro leituras | HOME_STATS
_st87() {
    ( TMP="$_td20/st87_$1"; URL=http://jogo; export TMP URL; mkdir -p "$TMP"; : > "$TMP/req"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/session_check.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1
      _cab() { printf "<img src='/images/icon/health.png' alt='hp'/> 900 <img src='/images/icon/mana.png' alt='mp'/> 80 <img src='/images/icon/level.png' alt='lvl'/> 90 <img src='/images/icon/gold.png' alt='g'/> %s <img src='/images/icon/silver.png' alt='s'/> 408,1M" "$1"; }
      printf '%s' "<title>Grimlock</title>`_cab 396` <script>jsInterface.event(\"user=5\")</script>" > "$TMP/user"
      case "$1" in
          igual)   _cab 396 > "$TMP/REST" ;;
          difere)  _cab 397 > "$TMP/REST" ;;
          sem)     printf '%s' "<img src='/images/icon/level.png'/> Home" > "$TMP/REST" ;;
      esac
      run_curl() { echo "$1" >> "$TMP/req"; cat "$TMP/user"; }
      fetch_train_stats() { :; }; messages_info() { :; }
      _v=$1
      for _i in 1 2 3 4; do
          if [ "$_v" = velha ] || { [ "$_v" = igual ] && [ "$_i" = 4 ]; }; then
              echo $(( `date +%s` - 200 )) > "$TMP/.home_ok"; [ "$_v" = velha ] && _cab 396 > "$TMP/REST"
          else echo "`date +%s`" > "$TMP/.home_ok"; fi
          atualiza_stats > /dev/null 2>&1
      done
      printf '%s|%s' "`grep -c '/user' "$TMP/req"`" "${HOME_STATS:--}" )
}
check "painel: Home conferida uma vez, depois sem /user (velha de novo: /user)" "2|1" "`_st87 igual`"
check "painel: Home com outro numero, 3 conferencias e fica no /user" "4|0" "`_st87 difere`"
check "painel: Home sem os icones do cabecalho, sempre /user" "4|-" "`_st87 sem`"
check "painel: Home de mais de 2 min, sempre /user" "4|-" "`_st87 velha`"
check "login: uma autenticacao so (login_autenticar) no login e na reconexao" "1 1 0" \
    "`sed -n '/^do_login() {/,/^}/p' "$LIB/sls.sh" | grep -c '^ *login_autenticar || return 1$'` `sed -n '/^login_logoff() {/,/^}/p' "$LIB/loginlogoff.sh" | grep -c '^ *login_autenticar || { relogin_falhou credencial; return 1; }$'` `sed -n '/^do_login() {/,/^}/p;/^login_logoff() {/,/^}/p' "$LIB/sls.sh" "$LIB/loginlogoff.sh" | grep -c 'pass@-'`"
_r=`( TMP="$_td20/la87"; mkdir -p "$TMP"; export TMP; URL=http://jogo
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/session_check.sh" > /dev/null 2>&1; . "$LIB/loginlogoff.sh" > /dev/null 2>&1
      printf '%s' 'login=Ze&pass=a b' | base64 > "$TMP/cript_file"
      login_lock() { echo LOCK >> "$TMP/req"; }; login_unlock() { echo UNLOCK >> "$TMP/req"; }
      run_curl() { case "$*" in *data-urlencode*) _in=\`cat\`; echo "POST $_in" >> "$TMP/req"; return "${POSTRC:-0}" ;; esac
                   echo "GET ${1#http://jogo}" >> "$TMP/req"; [ "$1" = http://jogo/user ] && printf ok; }
      login_autenticar; printf '%s ' "$LOGIN_ERRO"; POSTRC=7 login_autenticar; printf '%s|' "$LOGIN_ERRO"
      tr '\n' ',' < "$TMP/req" )`
check "login_autenticar: trava, pagina de login, POST pelo stdin, /user, solta; rede no POST" \
    "credencial rede|LOCK,GET /?sign_in=1,POST a b,GET /user,UNLOCK,LOCK,GET /?sign_in=1,POST a b,GET /user,UNLOCK," "$_r"
# Rei, ramo "sem link de ataque" do laco: a releitura com o unrip ressuscita
# (desde a 3.9.83 encerrava a luta como morto).
_r=`( TMP="$_td20/rei87u"; URL=http://jogo; SLS_PACING=0; export TMP URL SLS_PACING; mkdir -p "$TMP"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/allies.sh" > /dev/null 2>&1; . "$LIB/king.sh" > /dev/null 2>&1
      _f="<img src='/images/icon/level.png'/> <img src='/images/icon/health.png' alt='hp'/> 9000 <a href='/logout'>sair</a>"
      printf '%s' "$_f <a href='/king/heal/?r=1'>c</a>" > "$TMP/SRC"; echo 10000 > "$TMP/FULL"; echo 100000 > "$TMP/relogio"; : > "$TMP/req"
      date() { case "$1" in +%s) cat "$TMP/relogio" ;; *) command date "$@" ;; esac; }
      sleep() { _s=${1%s}; _s=${_s%%.*}; read -r _c < "$TMP/relogio"; echo $(( _c + ${_s:-0} )) > "$TMP/relogio"; }
      run_curl_exec() { echo "$1" >> "$TMP/req"; case "$1" in
          */unrip/*) printf '%s' "$_f <a href='/king/attack/?r=9'>a</a><a href='/king/kingatk/?r=8'>k</a>" ;;
          *) [ -f "$TMP/morreu" ] && printf '%s' "$_f <a href='/king/attack/?r=9'>a</a>" || { : > "$TMP/morreu"; printf '%s' "$_f <a href='/king/unrip/?r=77'>rev</a>"; } ;; esac; }
      luta_teto() { echo $(( $(cat "$TMP/relogio") + 12 )); }; func_unset() { :; }
      cd "$TMP" && king_fight > "$TMP/out" 2>&1
      printf '%s %s' "\`grep -c '/king/unrip/?r=77' "$TMP/req"\`" "\`grep -c 'declarou o personagem morto' "$TMP/out"\`" )`
check "Rei: releitura do laco com unrip ressuscita (nao encerra como morto)" "1 0" "$_r"
# HP maximo antes de agir numa pagina lida: o /train saiu, a pagina e relida.
#   _fr87 sai|fica -> pedidos
_fr87() {
    ( TMP="$_td20/fr87_$1"; URL=http://jogo; export TMP URL; mkdir -p "$TMP"; : > "$TMP/req"
      . "$LIB/info.sh" > /dev/null 2>&1
      printf %s /clancommand/ > "$TMP/.ult_req"; M=$1
      full_atualizar() { [ "$M" = sai ] && { echo /train >> "$TMP/req"; printf %s /train > "$TMP/.ult_req"; }; :; }
      run_curl_exec() { echo "${1#http://jogo}" >> "$TMP/req"; }
      time_exit() { wait "$!" 2>/dev/null; }
      full_relendo "$TMP/FULL" /clancommand/ "$TMP/pg"; printf 'rc=%s ' $?; tr '\n' ' ' < "$TMP/req" )
}
check "full_relendo: com o /train no meio, rele a pagina" "rc=0 /train /clancommand/ " "`_fr87 sai`"
check "full_relendo: sem pedido no meio, nada" "rc=1 " "`_fr87 fica`"
# Na luta em andamento os links tem nonce (?r=): rele. Na inscricao o link
# leva o id do torneio: sem releitura, que falhando apagava o link (3.9.88).
check "Torneio de Equipe: HP maximo sem nonce velho na luta, inscricao sem releitura" "1 1" \
    "`grep -c 'full_relendo "\$TMP/FULL" /clancommand/ "\$src_ram"' "$LIB/clancommand.sh"` `grep -c '^ *full_atualizar ' "$LIB/clancommand.sh"`"
# -batalhas: evento que termina sem a linha "ok" nao engole o Coliseu
# seguinte; a troca por aliado aparece em todos os eventos.
mkdir -p "$_td20/bt87/BR_Ana"
printf '%s\n' "https://jogo 11:25" "Torneio de equipe: lider sem inscrever - aguardando a luta" \
    "Torneio de equipe: nenhuma luta na pagina (guardada em x)" \
    "https://jogo 11:45" "Coliseum" "  Entering..." "Em batalha - HP: 700" "The battle is over!" \
    > "$_td20/bt87/BR_Ana/sls.log"
check "batalhas.sh: evento sem 'ok' fecha e o Coliseu seguinte aparece" "== Coliseu
 Ana 11:45 1 acoes HPmin 700 trocas 0 fogo 0 -

== Equipe
 Ana 11:25 0 acoes HPmin - trocas 0 fogo 0 nenhuma luta na pagina" \
    "`SLS_HOME="$_td20/bt87" sh "$ROOT/status.sh" -batalhas | sed 's/  */ /g'`"
_r=`( . "$LIB/allies.sh" > /dev/null 2>&1; _aliado=1; _al_fogo_ate=0; _al_seguidas=0; ALIADO_TROCAS_MAX=3
      troca_aliado 100 )`
check "troca por aliado escreve no log (o resumo conta em todos os eventos)" "Alvo aliado — trocando de alvo" "$_r"
unset -f _cp87 _rei87 _rec87 _hp87 _st87 _fr87

# ---- 3.9.88: correcoes da revisao da 3.9.87 ----
# Pulso do Coliseu: a marca do "sem luta" leva o dia. So com HH:MM, a noite
# seguinte com luta em todos os pulsos anteriores pulava o mesmo minuto.
#   _cp88 -> chamadas: 04:25 sem luta (dia 12), cinco pulsos com luta e o
#            04:25 do dia 13 com luta
_cp88() {
    ( TMP="$_td20/cp88"; mkdir -p "$TMP"; export TMP; : > "$TMP/r"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1; . "$LIB/run.sh" > /dev/null 2>&1
      relogio_sync() { _DD=${_DIAH%% *}; _h=${_DIAH#* }; _HH=${_h%:*}; _MM=${_h#*:}; }
      batalha_retomar() { return 1; }; CLD=1; RUN=-boot
      coliseum_fight() { echo "COL$_HH:$_MM" >> "$TMP/r"; if [ "$ACHA" = nada ]; then COLISEU_SEM_LUTA=1; else COLISEU_SEM_LUTA=0; fi; }
      tarefas_livres() { :; }; descansar() { :; }; sleep() { :; }; func_crono() { :; }
      func_sleep() { echo ESPERA >> "$TMP/r"; }
      ACHA=nada; _DIAH="12 04:25"; sls_play
      ACHA=luta
      for _DIAH in "13 02:45" "13 02:55" "13 03:15" "13 03:45" "13 04:15" "13 04:25"; do sls_play; done
      tr '\n' ' ' < "$TMP/r" )
}
check "Coliseu: a marca do pulso sem luta nao vale na noite seguinte" \
    "COL04:25 COL02:45 COL02:55 COL03:15 COL03:45 COL04:15 COL04:25 " "`_cp88`"
# Conferencia da Home no atualiza_stats: a subida de nivel no meio dela
# ainda apaga o last_train (o nivel de antes nao pode ser o da Home).
_r=`( TMP="$_td20/st88"; URL=http://jogo; export TMP URL; mkdir -p "$TMP"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/session_check.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1
      _cab="<img src='/images/icon/health.png' alt='hp'/> 900 <img src='/images/icon/mana.png' alt='mp'/> 80 <img src='/images/icon/level.png' alt='lvl'/> 91 <img src='/images/icon/gold.png' alt='g'/> 396 <img src='/images/icon/silver.png' alt='s'/> 408,1M"
      printf '%s' "$_cab" > "$TMP/REST"; date +%s > "$TMP/.home_ok"; date +%s > "$TMP/last_train"
      run_curl() { printf '%s' "<title>Grimlock</title>$_cab <script>jsInterface.event(\"user=5\")</script>"; }
      fetch_train_stats() { :; }; messages_info() { :; }
      ACC_LVL=90; atualiza_stats > /dev/null 2>&1
      [ -f "$TMP/last_train" ] && printf 'ficou' || printf 'apagado'; printf ' %s|%s' "$ACC_LVL" "${HOME_STATS:--}" )`
check "painel: subida de nivel durante a conferencia da Home apaga o last_train" "apagado 91|1" "$_r"
unset -f _cp88
# ---- 3.9.89: revisao da 3.9.87 (o que faltava na 3.9.88) ----
# Guarda do Coliseu: a marca leva o dia (o worker vive dias) e nao vale no
# modo -cl.
#   _cp88 MODO -> chamadas: 03:15 duas vezes no dia 1, 03:15 no dia 2
_cp88() {
    ( TMP="$_td20/cp88_$1"; mkdir -p "$TMP"; export TMP; : > "$TMP/r"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1; . "$LIB/run.sh" > /dev/null 2>&1
      _D=01; relogio_sync() { _HH=03; _MM=15; _DD=$_D; }
      batalha_retomar() { return 1; }; CLD=1; RUN=$1
      coliseum_fight() { echo COL >> "$TMP/r"; COLISEU_SEM_LUTA=1; }
      coliseum_start() { :; }; messages_info() { :; }
      tarefas_livres() { :; }; descansar() { :; }; sleep() { :; }; func_crono() { :; }
      func_sleep() { echo ESPERA >> "$TMP/r"; }
      sls_play; sls_play; _D=02; sls_play
      tr '\n' ' ' < "$TMP/r" )
}
check "Coliseu: a guarda de uma noite nao pula o mesmo minuto na seguinte" "COL ESPERA COL " "`_cp88 -boot`"
check "Coliseu: no modo -cl nao ha guarda" "COL COL COL " "`_cp88 -cl`"
# Sem resposta nao e "sem luta": o pulso tenta de novo no mesmo minuto.
#   _cs88 vazia|sem_luta -> COLISEU_SEM_LUTA
_cs88() {
    ( TMP="$_td20/cs88_$1"; URL=http://jogo; SLS_PACING=0; export TMP URL SLS_PACING; mkdir -p "$TMP"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/coliseum.sh" > /dev/null 2>&1
      FUNC_coliseum=y; COLISEU_GRAFICO=1; P=$1
      run_curl_exec() { [ "$P" = vazia ] || echo "<img src='/images/icon/level.png'/> <a href='/coliseum/'>Coliseu</a> <a href='/logout'>sair</a>"; }
      time_exit() { wait "$!" 2>/dev/null; }; cd "$TMP"
      coliseum_fight > /dev/null 2>&1; printf '%s' "$COLISEU_SEM_LUTA" )
}
check "Coliseu: pagina sem resposta nao trava o minuto do pulso" 0 "`_cs88 vazia`"
check "Coliseu: pagina do jogo sem luta trava o minuto, como na 3.9.87" 1 "`_cs88 sem_luta`"
# Conferencia da Home: a subida de nivel continua apagando o last_train.
_r=`( TMP="$_td20/lv88"; URL=http://jogo; export TMP URL; mkdir -p "$TMP"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/session_check.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1
      _cab="<img src='/images/icon/health.png' alt='hp'/> 900 <img src='/images/icon/mana.png' alt='mp'/> 80 <img src='/images/icon/level.png' alt='lvl'/> 91 <img src='/images/icon/gold.png' alt='g'/> 396 <img src='/images/icon/silver.png' alt='s'/> 408,1M"
      printf '%s' "<title>Grimlock</title>$_cab <script>jsInterface.event(\"user=5\")</script>" > "$TMP/user"
      printf '%s' "$_cab" > "$TMP/REST"; date +%s > "$TMP/.home_ok"; date +%s > "$TMP/last_train"
      run_curl() { cat "$TMP/user"; }; fetch_train_stats() { :; }; messages_info() { :; }
      ACC_LVL=90; atualiza_stats > /dev/null 2>&1
      [ -f "$TMP/last_train" ] && printf 'ficou ' || printf 'apagado '; printf '%s' "$HOME_STATS" )`
check "painel: subida de nivel na conferencia da Home apaga o last_train" "apagado 1" "$_r"
# hpmp: /train que respondeu com pagina de erro (sem o HP maximo) ainda
# pede o segundo, como antes da 3.9.87.
_r=`( TMP="$_td20/hp88"; URL=http://jogo; export TMP URL; mkdir -p "$TMP"; : > "$TMP/req"; : > "$TMP/SRC"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1
      run_curl() { echo "$1" >> "$TMP/req"; printf %s /train > "$TMP/.ult_req"; echo "Erro interno"; }
      run_curl_exec() { echo "$1" >> "$TMP/req"; printf %s /train > "$TMP/.ult_req"; }
      time_exit() { wait "$!" 2>/dev/null; }
      FIXHP=""; FIXMP=""; ACC_ENE=""; hpmp -fix; grep -c '/train' "$TMP/req" )`
check "Vale: hpmp com o primeiro /train sem o HP maximo pede o segundo" 2 "$_r"
# Cura que nao sai: tenta de novo ate duas vezes; a terceira conta como feita
# (com so a cura falhando, ela sairia a cada volta sem pausa).
_r=`( . "$LIB/info.sh" > /dev/null 2>&1; _o=""
      for _rc in 7 7 7 7 0 7; do TE_RC=$_rc; if pedido_nao_saiu; then _o="$_o n"; else _o="$_o s"; fi; done
      printf '%s' "$_o" )`
check "pedido_nao_saiu: tres seguidas sem sair contam como feita" " n n s n s n" "$_r"
_r=$( ( TMP="$_td20/rec88"; URL=http://jogo; SLS_PACING=0; export TMP URL SLS_PACING; mkdir -p "$TMP"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/allies.sh" > /dev/null 2>&1; . "$LIB/clanfight.sh" > /dev/null 2>&1
      _cab="<img src='/images/icon/level.png'/> <img src='/images/icon/health.png' alt='hp'/> 1000 <a href='/logout'>sair</a>"
      printf '%s' "$_cab<a href='/clanfight/attack/?r=1'>a</a><a href='/clanfight/heal/?r=3'>c</a>" > "$TMP/pag"
      cp "$TMP/pag" "$TMP/SRC"; echo 10000 > "$TMP/FULL"; echo 100000 > "$TMP/relogio"; : > "$TMP/req"
      date() { case "$1" in +%s) cat "$TMP/relogio" ;; *) command date "$@" ;; esac; }
      sleep() { _s=${1%s}; _s=${_s%%.*}; read -r _c < "$TMP/relogio"; echo $(( _c + ${_s:-0} )) > "$TMP/relogio"; }
      run_curl_exec() { echo "$1" >> "$TMP/req"; case "$1" in */heal/*) return 7 ;; esac; cat "$TMP/pag"; }
      luta_teto() { echo $(( $(cat "$TMP/relogio") + 20 )); }; func_unset() { :; }
      cd "$TMP" && clanfight_fight > /dev/null 2>&1
      printf '%s %s' "$(grep -c '/heal/' "$TMP/req")" "$(grep -c '/attack/' "$TMP/req")" ) )
check "cura sempre sem conexao: 3 tentativas e a recarga de 90s vale, o ataque segue" "3 4" "$_r"
unset -f _cp88 _cs88

# ---- 3.9.96: regras do dono nas missoes do cla, ouro e Liga ----
# Missao da atividade: ajudar o companheiro que ja a tomou vem antes de tomar.
#   _cq96 ajuda|livre -> pedidos
_cq96() {
    ( TMP="$_td20/cq96_$1"; CLD=777; export TMP CLD; mkdir -p "$TMP"; : > "$TMP/req"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/clanquest.sh" > /dev/null 2>&1
      case "$1" in
          ajuda) echo "<a href='/clan/777/quest/help/3/?r=1'>Ajudar</a> <a href='/clan/777/quest/take/4/?r=2'>Tomar</a>" > "$TMP/pg" ;;
          livre) echo "<a href='/clan/777/quest/take/3/?r=2'>Tomar</a>" > "$TMP/pg" ;;
      esac
      cq_pagina() { cp "$TMP/pg" "$TMP/CQUEST"; }
      fetch_page() { echo "${1%%\?*}" >> "$TMP/req"; sed -i "s#<a href='${1%%\?*}?[^']*'>[^<]*</a>##" "$TMP/pg"; }
      cq_antes arena > /dev/null 2>&1; printf 'rc=%s ' $?; tr '\n' ' ' < "$TMP/req" )
}
check "missao do cla: com companheiro na missao da atividade, ajuda (nao toma)" \
    "rc=0 /clan/777/quest/help/3/ " "`_cq96 ajuda`"
check "missao do cla: sem ninguem nela, toma a da atividade" "rc=0 /clan/777/quest/take/3/ " "`_cq96 livre`"
check "missao do cla: a varredura nao toma mais QUALQUER missao (clanQuests saiu)" 0 \
    "`grep -c 'clanQuests' "$LIB/crono.sh" "$LIB/clanid.sh" | awk -F: '{ s += $2 } END { print s }'`"
# Nunca gastar ouro: o rotulo do botao decide.
_r=`( . "$LIB/info.sh" > /dev/null 2>&1; _f="$_td20/bp96"
      echo "<a href='/lab/alchemy/2/makePotion?r=5'>Fazer por <img src='/images/icon/gold.png'/> 5</a> <a href='/x/?r=1'>Gratis</a>" > "$_f"
      botao_pago "$_f" "/lab/alchemy/2/makePotion?r=5" && printf 'pago ' || printf 'gratis '
      botao_pago "$_f" "/x/?r=1" && printf 'pago ' || printf 'gratis '
      botao_pago "$_f" "" && printf 'pago' || printf 'vazio' )`
check "botao_pago: ouro no rotulo e pago; sem ouro e gratis; link vazio nao e pago" "pago gratis vazio" "$_r"
_r=$( TMP="$_td20/el96"; CLD=777; export TMP CLD; mkdir -p "$TMP"; : > "$TMP/req"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1; . "$LIB/clanquest.sh" > /dev/null 2>&1
      cq_assumir() { return 0; }; cq_falta() { echo 2; }; cq_concluir() { :; }; cq_sorteia() { echo 2; }
      fetch_page() { echo "$1" >> "$TMP/req"; echo "<a href='/lab/alchemy/2/makePotion?r=5'>Fazer <img src='/images/icon/gold.png'/> 3</a>" > "$TMP/SRC"; }
      cq_elixir > /dev/null 2>&1; grep -c makePotion "$TMP/req" )
check "elixir que cobra ouro nao e produzido" 0 "$_r"
_r=$( TMP="$_td20/mg96"; export TMP; mkdir -p "$TMP"; . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/clanid.sh" > /dev/null 2>&1
      echo "<a href='/clandungeon/attack/?r=1'>Golpe <img src='/images/icon/gold.png'/> 2</a>" > "$TMP/D1"
      echo "<a href='/clandungeon/attack/?r=1'>Golpe</a>" > "$TMP/D2"
      printf '[%s][%s]' "`masmorra_golpe "$TMP/D1"`" "`masmorra_golpe "$TMP/D2"`" )
check "masmorra: golpe que cobra ouro nao e golpe" "[][/clandungeon/attack/?r=1]" "$_r"
# Liga: uma visita por dia. Travada (mais fortes, sem pocao), volta as 00:30.
_r=$( TMP="$_td20/lg96"; export TMP; mkdir -p "$TMP"; . "$LIB/league.sh" > /dev/null 2>&1
      date() { case "$1" in +%H:%M:%S) echo 13:00:00 ;; +%s) echo 100000 ;; *) command date "$@" ;; esac; }
      league_volta_0030; cat "$TMP/league_restauro" )
check "Liga travada as 13:00: volta as 00:30 (11h30 depois)" "$(( 100000 + 41400 ))" "$_r"
_r=$( TMP="$_td20/lg96b"; export TMP; mkdir -p "$TMP"; . "$LIB/league.sh" > /dev/null 2>&1
      date() { case "$1" in +%H:%M:%S) echo 00:10:00 ;; +%s) echo 100000 ;; *) command date "$@" ;; esac; }
      league_volta_0030; cat "$TMP/league_restauro" )
check "Liga travada as 00:10: volta as 00:30 do mesmo dia" "$(( 100000 + 1200 ))" "$_r"
check "Liga: sem pocao e mais fortes, anota a volta (uma visita por dia)" 1 \
    "`sed -n '/^league_play() {/,/^}/p' "$LIB/league.sh" | grep -c '\[ "\$_lg_travada" = 1 \] && league_volta_0030'`"
# Aliados em conta sem cla: CLD vazio e "sem cla", nao falha (lista atualiza).
_r=$( TMP="$_td20/al96"; export TMP; mkdir -p "$TMP"; : > "$TMP/CLD"; CLD=""
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/allies.sh" > /dev/null 2>&1; clan_id() { :; }
      aliados_cla > /dev/null 2>&1; [ -f "$TMP/aliados.falha" ] && printf falha || printf ok )
check "aliados: conta sem cla nao marca falha" ok "$_r"
# Arena: missao do cla so com ataque na tela (regra do dono).
#   _ar96 com|sem -> pedidos
_ar96() {
    ( TMP="$_td20/ar96_$1"; CLD=777; export TMP CLD; mkdir -p "$TMP"; : > "$TMP/req"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/arena.sh" > /dev/null 2>&1
      A=$1; sleep() { :; }
      cq_antes() { echo "missao:$1" >> "$TMP/req"; }; checkQuest() { echo "checkQuest:$1:$2" >> "$TMP/req"; }
      fetch_page() { echo "$1" >> "$TMP/req"
          case "$1" in
              /arena/) if [ "$A" = com ] && [ ! -f "$TMP/lutou" ]; then echo "<a href='/arena/attack/1/?r=7'>Atacar</a>" > "$TMP/SRC"; else echo "Arena" > "$TMP/SRC"; fi ;;
              /arena/attack/*) : > "$TMP/lutou"; echo "fim" > "$TMP/SRC" ;;
              *) : > "$TMP/SRC" ;;
          esac; }
      arena_duel > /dev/null 2>&1; tr '\n' ' ' < "$TMP/req" )
}
check "arena sem ataque: so a arena, sem pagina de missao" "/arena/ " "`_ar96 sem`"
check "arena com ataque: missao (ajuda ou toma), arena relida e luta" \
    "/arena/ missao:arena /arena/ /arena/attack/1/?r=7 /inv/bag/ checkQuest:3:end checkQuest:4:end " "`_ar96 com`"
check "elixir usado (bau) nao pega a missao de fazer elixir" 0 \
    "`sed -n '/^start() {/,/^}/p' "$LIB/crono.sh" | grep -c 'cq_antes elixir'`"
# Atividades so no intervalo entre os eventos (regra do dono): todo minuto de
# janela do cronograma (ramos de evento do sls_play) fica de fora, e os 5 min
# antes de cada uma tambem; fora disso a rotina roda (antes: :10-:14, :25-:29
# e :55-:59 de TODA hora, com ou sem evento).
_r=`( . "$LIB/league.sh" > /dev/null 2>&1
      _pats=\`grep -E '^        \\([0-9]{2}:[0-9]' "$LIB/run.sh" | grep -v '00:\\[345\\]5\\|00:00|00:30' | sed 's/^ *(//; s/)$//' | tr '\\n' '|' | sed 's/|$//'\`
      _falha=0; _livres=0
      for _h in 00 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22 23; do
        for _m in 00 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59; do
          date() { echo "$_h:$_m"; }
          eval "case $_h:$_m in $_pats) _ev=1 ;; *) _ev=0 ;; esac"
          if liga_fora_da_inscricao; then _livre=1; else _livre=0; fi
          [ "$_ev" = 1 ] && [ "$_livre" = 1 ] && _falha=$((_falha + 1))
          [ "$_livre" = 1 ] && _livres=$((_livres + 1))
        done
      done
      printf '%s %s' "$_falha" "$_livres" )`
check "rotina: nenhum minuto de evento do cronograma livre; minutos livres por dia" "0 1260" "$_r"
_r=`( . "$LIB/league.sh" > /dev/null 2>&1
      for _t in 12:19 12:20 12:29 12:30 03:25 03:55 10:12 23:58; do date() { echo "$_t"; }
          liga_fora_da_inscricao && printf '%s=livre ' "$_t" || printf '%s=evento ' "$_t"; done )`
check "rotina: para 5 min antes do Rei (12:25) e roda as 03:25" \
    "12:19=livre 12:20=evento 12:29=evento 12:30=livre 03:25=livre 03:55=livre 10:12=evento 23:58=livre " "$_r"
# Carreira a cada 8h (regra do jogo): lutou, 8h; sem ataque, de hora em hora.
_r=$( TMP="$_td20/cr96"; export TMP; mkdir -p "$TMP"; . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1
      agora_s() { _AGORA=100000; }
      CARREIRA_LUTOU=1; carreira_marcar; printf '%s ' $(( $(cat "$TMP/next_carreira") - 100000 ))
      CARREIRA_LUTOU=0; carreira_marcar; printf '%s ' $(( $(cat "$TMP/next_carreira") - 100000 ))
      carreira_liberada && printf 'liberada' || printf 'espera' )
check "carreira: lutou volta em 8h, sem ataque em 1h" "28800 3600 espera" "$_r"
check "missoes: o checklist nao ajuda mais em qualquer missao (so antes da atividade)" 0 \
    "`sed -n '/^tarefas_livres() {/,/^}/p' "$LIB/crono.sh" | grep -c 'cq_ajudar'`"
unset -f _cq96 _ar96

rm -rf "$_td20"; unset _td20 _r VIVA53 LOGIN53
unset -f _cld53 _cqpg53 _liga53 _cc69 _cc70 _giro71 _tr77 _vl80 _col81 _rl83

printf "\n=== 55. codigo HTTP, wake-lock unico, relancamento crescente ===\n"
_td55=`mktemp -d`
# fetch_page registra 4xx/5xx (curl devolve 0 nesses casos) sem mudar o retorno.
_r=`( TMP="$_td55"; URL=http://jogo; SLS_PACING=0; export TMP URL SLS_PACING
      . "$LIB/info.sh" > /dev/null 2>&1
      run_curl_exec() { printf 'HTTP/1.1 302 Found\r\n\r\nHTTP/1.1 502 Bad Gateway\r\n\r\n' > "$3"; printf 'erro'; }
      fetch_page /king/ "$TMP/p"; printf 'rc=%s ' "$?"
      grep -c 'http 502: /king/' "$TMP/ERROR_DEBUG" 2>/dev/null || printf 0 )`
check "fetch_page: HTTP 502 vai para o ERROR_DEBUG e o retorno continua 0" "rc=0 1" "$_r"
_r=`( TMP="$_td55/ok"; mkdir -p "$TMP"; URL=http://jogo; SLS_PACING=0; export TMP URL SLS_PACING
      . "$LIB/info.sh" > /dev/null 2>&1
      run_curl_exec() { printf 'HTTP/2 200 \r\n\r\n' > "$3"; printf 'pagina'; }
      fetch_page /user/ "$TMP/p"; printf 'rc=%s %s' "$?" "$(cat "$TMP/p")"
      [ -f "$TMP/.http_erro" ] && printf ' marcado' )`
check "fetch_page: HTTP 200 nao marca erro e a pagina sai inteira" "rc=0 pagina" "$_r"
# Wake-lock pedido uma vez pelo play.sh; worker.sh e sls.sh so pedem rodados a mao.
grep -q '^export SLS_WAKELOCK' "$ROOT/play.sh" \
    && grep -q '^\[ -n "\$SLS_WAKELOCK" \] || termux-wake-lock' "$LIB/worker.sh" \
    && grep -q 'if \[ -z "\$SLS_WAKELOCK" \] && \[ -d /data/data/com.termux' "$LIB/sls.sh" \
    && ok "wake-lock: so o play.sh pede; worker e sls.sh pedem apenas sem ele" \
    || bad "wake-lock pedido de novo por worker/sls sob o play.sh"
# Espera antes de relancar: 1, 1, 2, 5, 10, 10 min; 15 min sem relancar zera.
_r=`( eval "$(sed -n '/^relanca_espera() {/,/^}/p' "$LIB/panel.sh")"; _o=""
      for _a in "0 30" "1 30" "2 30" "3 30" "4 30" "9 30" "5 900" "" "x 10"; do
          relanca_espera ${_a% *} ${_a#* }; _o="$_o $_RL_N:$_RL_E"; done; printf '%s' "$_o" )`
check "relancamento: espera crescente e zerada apos 15 min" " 0:60 1:60 2:120 3:300 4:600 9:600 0:60 0:60 0:60" "$_r"
rm -rf "$_td55"; unset _td55 _r

printf "\n=== 56. disjuntor global do servidor ===\n"
_td56=`mktemp -d`
# Ambiente comum: HOME e TMP proprios, relogio controlado em $_td56/t, a Home
# da sonda em $_td56/home (vazio = servidor mudo) e os pedidos em $_td56/req.
_dj56() {
    ( HOME="$_td56/h"; TMP="$_td56/tmp"; URL=http://jogo; SLS_TAG=BR; SLS_PACING=0; SLS_DISJUNTOR=1
      export HOME TMP URL SLS_TAG SLS_PACING SLS_DISJUNTOR; mkdir -p "$HOME/.sls" "$TMP"
      . "$LIB/info.sh" > /dev/null 2>&1
      date() { case "$1" in +%s) cat "$_td56/t" ;; *) command date "$@" ;; esac; }
      run_curl() { echo "$1" >> "$_td56/req"; cat "$_td56/home" 2>/dev/null; }
      eval "$1" )
}
_pg56="<html>x jsInterface.event(\"user=7;level=9\")</html>"
_nova56() { rm -rf "$_td56/h" "$_td56/tmp"; : > "$_td56/req"; : > "$_td56/home"; echo 1000 > "$_td56/t"; }
_nova56
_r=`_dj56 'disjuntor_falha; disjuntor_falha; [ -f "$HOME/.sls/net/BR.aberto" ] && printf aberto || printf fechado'`
check "disjuntor: a mesma conta duas vezes nao abre" "fechado" "$_r"
# Tres contas distintas (a conta e a pasta dela, $TMP).
_nova56
for _p in a b; do _dj56 "TMP=\$TMP/$_p; disjuntor_falha" > /dev/null; done
_r=`_dj56 'TMP=$TMP/c; disjuntor_falha; [ -f "$HOME/.sls/net/BR.aberto" ] && printf aberto || printf fechado'`
case "$_r" in *aberto) ok "disjuntor: tres contas sem resposta em 30s abrem" ;; *) bad "disjuntor: tres contas nao abriram ($_r)" ;; esac
case "$_r" in *"[disjuntor] BR fora do ar: 3 contas"*) ok "disjuntor: o log diz quantas contas" ;; *) bad "disjuntor: log da abertura ($_r)" ;; esac
_nova56
for _p in "a te" b; do _dj56 "TMP='\$TMP/$_p'; disjuntor_falha" > /dev/null; done; echo 1031 > "$_td56/t"
_r=`_dj56 'TMP=$TMP/c; disjuntor_falha > /dev/null; [ -f "$HOME/.sls/net/BR.aberto" ] && printf aberto || printf fechado'`
check "disjuntor: falhas fora da janela de 30s nao contam (nome com espaco)" "fechado" "$_r"
# Aberto: segura e sonda; Home muda continua aberto; um so pedido a cada 20 s.
_nova56; mkdir -p "$_td56/h/.sls/net"; echo 1000 > "$_td56/h/.sls/net/BR.aberto"
_r=`_dj56 'disjuntor_segura && printf S || printf L; disjuntor_segura && printf S || printf L'`
check "disjuntor aberto, servidor mudo: segura e sonda uma vez so" "SS 1" "$_r `grep -c . "$_td56/req"`"
echo 1021 > "$_td56/t"; printf '%s' "$_pg56" > "$_td56/home"
_r=`_dj56 'disjuntor_segura > /dev/null 2>&1 && printf S || printf L; [ -f "$HOME/.sls/net/BR.aberto" ] && printf A || printf F'`
check "disjuntor: sonda que recebe a pagina do jogo fecha e libera quem sondou" "LF" "$_r"
check "disjuntor: segunda sonda so depois de 20s" 2 "`grep -c . "$_td56/req"`"
# Volta escalonada: espera $$ % 21 s depois do fechamento (aqui o PID do sh do teste).
_nova56; mkdir -p "$_td56/h/.sls/net"; echo 1000 > "$_td56/h/.sls/net/BR.fechou"
_r=`_dj56 'e=$(( $$ % 21 )); echo $(( 1000 + e - 1 )) > "$_td56/t"; a=L; [ "$e" -gt 0 ] && { disjuntor_segura && a=S; }
           echo $(( 1000 + e )) > "$_td56/t"; disjuntor_segura && b=S || b=L; printf "%s%s" "$a" "$b"'`
case "$_r" in SL|LL) ok "disjuntor: volta escalonada (segura ate \$\$ % 21 s, depois segue) ($_r)" ;; *) bad "disjuntor: volta escalonada ($_r)" ;; esac
# Qualquer pagina logada fecha; 30 min aberto fecha sozinho; SLS_DISJUNTOR=0 desliga.
_nova56; mkdir -p "$_td56/h/.sls/net"; echo 1000 > "$_td56/h/.sls/net/BR.aberto"
_r=`_dj56 'sessao_marcar > /dev/null; [ -f "$HOME/.sls/net/BR.aberto" ] && printf A || printf F'`
check "disjuntor: pagina logada de qualquer conta (sessao_marcar) fecha" "F" "$_r"
_nova56; mkdir -p "$_td56/h/.sls/net"; echo 1000 > "$_td56/h/.sls/net/BR.aberto"; echo 2800 > "$_td56/t"
_r=`_dj56 'disjuntor_segura > /dev/null && printf S || printf L'`
check "disjuntor: aberto ha 30 min fecha sozinho" "L" "$_r"
_nova56; mkdir -p "$_td56/h/.sls/net"; echo 1000 > "$_td56/h/.sls/net/BR.aberto"
_r=`_dj56 'SLS_DISJUNTOR=0; disjuntor_segura && printf S || printf L; disjuntor_falha; printf " %s" "$(ls "$HOME/.sls/net" | grep -c falha)"'`
check "disjuntor: SLS_DISJUNTOR=0 nao segura nem registra" "L 0" "$_r"
# Os portoes: com o disjuntor aberto, tarefas_livres e start nao pedem nada.
_nova56; mkdir -p "$_td56/h/.sls/net"; echo 1000 > "$_td56/h/.sls/net/BR.aberto"
_r=`_dj56 '. "$LIB/crono.sh" > /dev/null 2>&1; echo 1000 > "$_td56/h/.sls/net/BR.sonda_ult"
           batalha_pendente() { return 1; }; clan_id() { echo clan_id >> "$_td56/req"; }
           atualiza_stats() { echo stats >> "$_td56/req"; }; stats_liberado() { return 0; }; CLD=""
           tarefas_livres > /dev/null 2>&1
           login_logoff() { echo login >> "$_td56/req"; }; func_crono() { :; }; func_sleep() { :; }
           start > /dev/null 2>&1; printf "%s" "$?"'`
check "disjuntor: tarefas_livres e start nao pedem nada com o disjuntor aberto" "1 0" "$_r `grep -c . "$_td56/req"`"
grep -q 'rm -rf "\$HOME/.sls/net"' "$ROOT/stop.sh" && ok "stop.sh limpa o estado do disjuntor" || bad "stop.sh sem limpar ~/.sls/net"
grep -q 'if disjuntor_segura; then' "$LIB/sls.sh" && ok "login de entrada espera o disjuntor" || bad "login de entrada ignora o disjuntor"
rm -rf "$_td56"; unset _td56 _r _pg56 _p; unset -f _dj56 _nova56

printf "\n=== 57. telemetria das requisicoes ===\n"
_td57=`mktemp -d`
# curl falso: grava os argumentos e, com --stderr, a linha do -w como o real.
_tl57() {
    ( TMP="$_td57/tmp"; URL=http://jogo; SLS_PACING=0; export TMP URL SLS_PACING; mkdir -p "$TMP"
      . "$LIB/info.sh" > /dev/null 2>&1
      curl() { printf '%s\n' "$*" > "$_td57/args"; _o=""
               while [ "$#" -gt 0 ]; do [ "$1" = --stderr ] && _o="$2"; shift; done
               [ -n "$_o" ] && printf 'M %s %s\n' "${_C57:-200}" "${_T57:-0.532113}" > "$_o"
               printf 'pagina'; return "${_R57:-0}"; }
      eval "$1" )
}
_r=`_tl57 'run_curl "$URL/user/" > /dev/null; grep -c -- "--stderr" "$_td57/args"; cat "$TMP/req.stat"'`
check "telemetria: run_curl grava codigo, ms e rc" "1 200 532 0" "`printf '%s' "$_r" | tr '\n' ' ' | sed 's/^\([0-9]*\) [0-9]* /\1 /; s/ $//'`"
rm -rf "$_td57/tmp"
_r=`_tl57 'SLS_TELEMETRIA=0; run_curl "$URL/user/" > /dev/null; grep -c -- "--stderr" "$_td57/args"; [ -f "$TMP/req.stat" ] && printf sim || printf nao'`
check "telemetria: SLS_TELEMETRIA=0 nao muda o curl nem grava" "0 nao" "`printf '%s' "$_r" | tr '\n' ' '`"
rm -rf "$_td57/tmp"
_r=`_tl57 'for t in 0,08 12.5 0.089 3; do _T57=$t; run_curl "$URL/x" > /dev/null; done; awk "{ printf \"%s \", \\$3 }" "$TMP/req.stat"'`
check "telemetria: tempo com virgula, segundos, zero a esquerda (nao octal) e inteiro" "80 12500 89 3000 " "$_r"
rm -rf "$_td57/tmp"
# (o exec do run_curl_exec rodaria o curl de verdade: aqui ele e o falso)
_r=`_tl57 'run_curl_exec() { printf "M 000 17.000001\n" > "$TMP/.req_meta"; return 28; }
           ( run_curl_exec "$URL/king/" > "$TMP/SRC" ) </dev/null >/dev/null 2>&1 & time_exit 17
           sleep 0 & time_exit 17; awk "{ print \\$2, \\$3, \\$4 }" "$TMP/req.stat"; [ -s "$TMP/.req_meta" ] && printf resto'`
check "telemetria: time_exit registra timeout (000, 17000 ms, rc 28) e ignora job sem curl" "000 17000 28" "$_r"
rm -rf "$_td57/tmp"
_r=`_tl57 '_TL_N=299; i=0; while [ $i -lt 350 ]; do echo "1 200 1 0" >> "$TMP/req.stat"; i=$((i+1)); done
           printf "M 200 0.1\n" > "$TMP/.req_meta"; tele_registrar 0; grep -c . "$TMP/req.stat"'`
check "telemetria: o req.stat e cortado para 200 linhas a cada 300 registros" 200 "$_r"
# rede.sh: duas contas, uma linha fora da janela, P95 por histograma, 5xx e sem resposta.
mkdir -p "$_td57/h/BR_Ana" "$_td57/h/BR_Bia"
_ag=`date +%s`
{ i=0; while [ $i -lt 19 ]; do echo "$_ag 200 300 0"; i=$((i+1)); done; echo "$_ag 200 2950 0"; echo "$(( _ag - 3600 )) 200 9000 0"; } > "$_td57/h/BR_Ana/req.stat"
{ echo "$_ag 502 100 0"; echo "$_ag 000 17000 28"; } > "$_td57/h/BR_Bia/req.stat"
_r=`SLS_HOME="$_td57/h" sh "$LIB/rede.sh" | awk '$1 == "BR_Ana" || $1 == "BR_Bia" || $1 == "TOTAL" { $1 = $1; print }' | tr '\n' '|'`
check "rede.sh: tabela por conta e total (janela, media, P95, sem resposta, 5xx)" \
      "BR_Ana 2,0 0,4s 0,4s 0 0|BR_Bia 0,2 0,1s 0,2s 1 1|TOTAL BR 2,2 0,4s 0,4s 1 1|" "$_r"
_r=`SLS_HOME="$_td57/h" sh "$LIB/rede.sh" -linha 80`
check "rede.sh -linha: uma linha por servidor para o painel" \
      "rede BR (10 min): 2,2 req/min · media 0,4 s · P95 0,4 s · 1 sem resposta · 1 HTTP 5xx" "$_r"
_r=`SLS_HOME="$_td57/vazio" sh "$LIB/rede.sh" -linha 80; printf '[%s]' "$?"`
check "rede.sh -linha sem dados: nada no rodape" "[0]" "$_r"
grep -q -- '-rede|--rede) shift; exec sh "$LIBDIR/rede.sh"' "$ROOT/status.sh" && ok "status.sh -rede chama o rede.sh" || bad "status.sh sem -rede"
# Curl sem %{stderr} (antes da 7.63) desliga a telemetria na subida.
_tlv57() { ( _v57=$1; curl() { printf 'curl %s (x) libcurl\n' "$_v57"; }; SLS_TAG=BR; SLS_USER=t; SLS_TELEMETRIA=1
             eval "$(sed -n '/^# Telemetria (info.sh\/tele_registrar)/,/^fi$/p' "$LIB/sls.sh")"; printf '%s' "$SLS_TELEMETRIA" ) 2>/dev/null | tail -c 1; }
check "sls.sh: curl 7.58 desliga, 7.63 e 8.x ligam" "0 1 1" "`_tlv57 7.58.0` `_tlv57 7.63.0` `_tlv57 8.21.0`"
rm -rf "$_td57"; unset _td57 _r _ag; unset -f _tl57 _tlv57

printf "\n=== 58. acao cuja conexao nem abriu sai de novo ===\n"
_td58=`mktemp -d`
# tele_registrar le o %{time_connect}: zero = a conexao nunca abriu.
_r=`( TMP="$_td58"; export TMP; . "$LIB/info.sh" > /dev/null 2>&1; _o=""
      for _k in 0.000000 0,000000 0 0.138869 0.000120 1.5; do
          TE_CONECTOU=x; printf 'M 000 15.002 %s\n' "$_k" > "$TMP/.req_meta"; tele_registrar 28; _o="$_o$TE_CONECTOU"; done
      printf '%s' "$_o" )`
check "telemetria: conexao que nao abriu (time_connect zero) da TE_CONECTOU=0" "000111" "$_r"
_r=`( . "$LIB/info.sh" > /dev/null 2>&1; _o=""
      for _p in 28:0 28:1 28:0 28:0 28:0 7:1 0:1; do TE_RC=${_p%:*}; TE_CONECTOU=${_p#*:}
          if pedido_nao_saiu; then _o="$_o n"; else _o="$_o s"; fi; done; printf '%s' "$_o" )`
check "pedido_nao_saiu: 28 sem conexao nao saiu; 28 conectado saiu; tres seguidas contam como feita" " n s n n s n s" "$_r"
# Batalha (Torneio): a cura cuja conexao pendura (28, connect 0) sai de novo,
# como a recusada (7); a que estourou o tempo DEPOIS de conectar vale.
_cura58() {
    ( TMP="$_td58/$1"; URL=http://jogo; SLS_PACING=0; export TMP URL SLS_PACING; mkdir -p "$TMP"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/allies.sh" > /dev/null 2>&1; . "$LIB/clanfight.sh" > /dev/null 2>&1
      _cab="<img src='/images/icon/level.png'/> <img src='/images/icon/health.png' alt='hp'/> 1000 <a href='/logout'>sair</a>"
      printf '%s' "$_cab<a href='/clanfight/attack/?r=1'>a</a><a href='/clanfight/heal/?r=3'>c</a>" > "$TMP/pag"
      cp "$TMP/pag" "$TMP/SRC"; echo 10000 > "$TMP/FULL"; echo 100000 > "$TMP/relogio"; : > "$TMP/req"
      date() { case "$1" in +%s) cat "$TMP/relogio" ;; *) command date "$@" ;; esac; }
      sleep() { _s=${1%s}; _s=${_s%%.*}; read -r _c < "$TMP/relogio"; echo $(( _c + ${_s:-0} )) > "$TMP/relogio"; }
      run_curl_exec() { echo "$1" >> "$TMP/req"
          # (o curl so escreve a linha com a telemetria ligada)
          case "$1" in */heal/*) [ "${SLS_TELEMETRIA:-1}" = 0 ] || printf 'M 000 15.002 %s\n' "$_K58" > "$TMP/.req_meta"; return 28 ;; esac
          cat "$TMP/pag"; }
      luta_teto() { echo $(( $(cat "$TMP/relogio") + 20 )); }; func_unset() { :; }
      cd "$TMP" && clanfight_fight > /dev/null 2>&1
      printf '%s %s' "$(grep -c '/heal/' "$TMP/req")" "$(grep -c '/attack/' "$TMP/req")" )
}
check "batalha: cura com a conexao pendurada sai de novo (3 tentativas, como a recusada)" "3 4" "`_K58=0.000000 _cura58 a`"
check "batalha: cura que estourou o tempo depois de conectar conta como feita (como antes)" "1 4" "`_K58=0.120000 _cura58 b`"
_r=`( SLS_TELEMETRIA=0 _K58=0.000000 _cura58 c )`
check "batalha: sem telemetria, curl 28 conta como feita (comportamento de antes)" "1 4" "$_r"
rm -rf "$_td58"; unset _td58 _r _k _p; unset -f _cura58

printf "\n=== 59. MADRUGADA: CAVERNA 00:30-02:40, COLISEU 02:45-04:25 (3.9.100) ===\n"
_td62=`mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/sls_t62_$$"`; mkdir -p "$_td62"
# Janela da caverna: 00:30 <= hora < 02:40.
_r=$( TMP="$_td62/j"; mkdir -p "$TMP"; . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1; . "$LIB/cave.sh" > /dev/null 2>&1
      for _h in 00:29 00:30 01:15 02:39 02:40 03:00; do
          hora_atual() { _HOR=${_h%:*}; _HOR=${_HOR#0}; }; minuto_atual() { _MIN=${_h#*:}; _MIN=${_MIN#0}; }
          caverna_noite_janela && printf 's' || printf 'n'
      done )
check "caverna da madrugada: janela 00:30 ate 02:40 (00:29 00:30 01:15 02:39 02:40 03:00)" "nsssnn" "$_r"
# Cronograma: 01:15 e da caverna (ramo comum), 02:45 e pulso do Coliseu.
_r=$( TMP="$_td62/c"; mkdir -p "$TMP"; export TMP; : > "$TMP/r"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1; . "$LIB/run.sh" > /dev/null 2>&1
      relogio_sync() { _HH=${_HORA%:*}; _MM=${_HORA#*:}; _DD=22; }
      batalha_retomar() { return 1; }; CLD=1; RUN=-boot
      coliseum_fight() { echo "COL$_HH:$_MM" >> "$TMP/r"; COLISEU_SEM_LUTA=1; }
      tarefas_livres() { echo "ROT$_HH:$_MM" >> "$TMP/r"; }; descansar() { :; }; sleep() { :; }; func_crono() { :; }
      func_sleep() { :; }; start() { echo "START$_HH:$_MM" >> "$TMP/r"; }
      for _HORA in 00:35 01:15 02:35 02:45 03:55 04:25 04:35; do sls_play; done
      tr '\n' ' ' < "$TMP/r" )
check "madrugada: Coliseu so de 02:45 a 04:25; antes, a rotina (com a caverna)" \
    "ROT00:35 ROT01:15 ROT02:35 COL02:45 ROT02:45 COL03:55 ROT03:55 COL04:25 ROT04:25 ROT04:35 " "$_r"
# Caverna da madrugada contra um roteiro de paginas: pesquisa, monstro (foge),
# pesquisa, acelera, minera, acelera... com o limite de 15% da prata.
#   _cn100 preco|cabecalho|ouro -> acoes pedidas | estado gravado | segunda chamada
#   preco:     o botao de acelerar mostra 40 de prata, a prata cai 40 por clique
#   cabecalho: o botao nao mostra o preco; so a prata do cabecalho cai (60)
#   ouro:      o acelerar cobra ouro
_cn100() {
    ( TMP="$_td62/n$1"; export TMP; rm -rf "$TMP"; mkdir -p "$TMP"; : > "$TMP/req"; echo 0 > "$TMP/passo"; echo 1000 > "$TMP/prata"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1; . "$LIB/cave.sh" > /dev/null 2>&1
      _M=$1
      _pg() { read -r _p < "$TMP/passo"; read -r _s < "$TMP/prata"
          # Como a pagina real: HP no topo, a dica da aceleracao com o preco
          # por minuto (icone alt='s') e a prata da conta no rodape.
          _top="<span class='bl rght nwr'><img src='/images/icon/health.png' alt='hp'/> <span class='white'>99171</span></span>"
          _dica="<ul class='hint'><li>Minutos <span class='bold'>1</span> de aceleração preço <img src='/images/icon/silver.png' alt='s'/> <span class='bold'>3</span> pratas</li></ul>"
          _rod="<div class='center'><img src='/images/icon/level.png' alt='lvl'/> 105 | <img src='/images/icon/gold.png' alt='g'/> 132 | <img src='/images/icon/silver.png' alt='s'/> $_s</div>"
          case "$_M" in preco) _rot="<span class='end'><span class='label'>Acelerar para <img src='/images/icon/silver.png' alt=''/> 40</span></span>" ;;
                        ouro)  _rot="<span class='label'>Acelerar para <img src='/images/icon/gold.png' alt=''/> 5</span>" ;;
                        *)     _rot="<span class='label'>Acelerar</span>" ;; esac
          case $_p in
              0|2|6|10|14) _m="<a class='btn' href='/cave/down/?r=$_p'>Nova pesquisa</a>" ;;
              1)           _m="Monstro! <a class='btn' href='/cave/runaway/?r=$_p'>Escapar</a>" ;;
              3|5|7|9|11|13|15) _m="<a class='btn' href='/cave/speedUp/?r=$_p'>$_rot</a>$_dica" ;;
              4|8|12)      _m="<a class='btn' href='/cave/gather/?r=$_p'>Iniciar mineracao</a>" ;;
              *)           _m="espera" ;;
          esac
          echo "$_top $_m $_rod" > "$TMP/SRC"; }
      fetch_page() {
          case "$1" in
              /cave/) : ;;
              *) echo "$1" >> "$TMP/req"; read -r _p < "$TMP/passo"
                 case "$1" in */speedUp/*) read -r _s < "$TMP/prata"
                     [ "$_M" = preco ] && _s=$((_s - 40)); [ "$_M" = cabecalho ] && _s=$((_s - 60)); echo "$_s" > "$TMP/prata" ;; esac
                 echo $((_p + 1)) > "$TMP/passo" ;;
          esac
          _pg; }
      caverna_noite > /dev/null 2>&1
      _a=`sed 's,^/cave/,,; s,/.*,,' "$TMP/req" | tr '\n' ' '`
      read -r _d _b _g _f < "$TMP/cave_noite"
      : > "$TMP/req"; caverna_noite > /dev/null 2>&1; _seg="$?:`wc -l < "$TMP/req" | tr -d ' '`"
      printf '%s|%s %s %s|%s' "$_a" "$_b" "$_g" "$_f" "$_seg" )
}
check "caverna da madrugada: pesquisa, foge do monstro, acelera e minera ate 15% (preco do botao)" \
    "down runaway down speedUp gather speedUp down speedUp gather |1000 120 1|1:0" "`_cn100 preco`"
check "caverna da madrugada: sem preco no botao, o limite vem da queda da prata no cabecalho" \
    "down runaway down speedUp gather speedUp down speedUp gather |1000 0 1|1:0" "`_cn100 cabecalho`"
check "caverna da madrugada: acelerar pago em ouro nao e clicado" \
    "down runaway down |1000 0 0|1:0" "`_cn100 ouro`"
_r=$( . "$LIB/cave.sh" > /dev/null 2>&1
      printf '%s' "<img src='/images/icon/silver.png' alt='s'/> 408,1M" > "$_td62/p1"; printf '%s ' "`prata_pagina "$_td62/p1"`"
      printf '%s' "<img src='/images/icon/silver.png' alt='s'/> <span>96'629</span>" > "$_td62/p2"; printf '%s ' "`prata_pagina "$_td62/p2"`"
      printf '%s' "sem icone" > "$_td62/p3"; printf '[%s]' "`prata_pagina "$_td62/p3"`" )
check "prata_pagina: 408,1M, 96'629 e pagina sem icone" "408100000 96629 []" "$_r"
# Pagina real da caverna (22/10, nome e id da conta trocados): o preco do
# botao e 41580; a prata da conta e a do RODAPE (1819,8M), nao o 1260 da dica
# que vem antes dela com o mesmo icone.
cat > "$_td62/cave_real.html" <<'HTML'
<html><head><title>Caverna</title></head><body><div class='head  cntr' style='position:relative;' onclick="location.href='/';"><span class='ttl fl'>Caverna</span><span class='bl rght nwr'><img src='/images/icon/health.png' alt='hp'/> <span class='white'>99171</span> | <img src='/images/icon/mana.png' alt='mp'/> 242</span><div class='clr'></div></div><div class='center'><div class='block_zero'><span class='blue'>Você está tentando obter os recursos...</span><br/>Tempo de sobra: 32:23</div><div class='mini-line'></div><div class='block_zero center'><a class='btn' href='/cave/speedUp/?r=53383440'><span class='end'><span class='label'>Acelerar para <img src='/images/icon/silver.png' alt=''/> 41580</span></span></a></div></div><div class='mini-line'></div><ul class='hint'><li>Minutos <span class='bold'>1</span> de aceleração preço <img src='/images/icon/silver.png' alt='s'/> <span class='bold'>1260</span> pratas</li></ul><div class='foot'><div><img src='/images/icon/race/1.png' alt='Bóreas'/> Conta Teste</div><div class='center'><img src='/images/icon/level.png' alt='lvl'/> 105 | <img src='/images/icon/gold.png' alt='g'/> 132 | <img src='/images/icon/silver.png' alt='s'/> 1819,8M</div></div><script>jsInterface.event("user=5;level=105");</script></body></html>
HTML
_r=$( TMP="$_td62"; . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/cave.sh" > /dev/null 2>&1
      cp "$_td62/cave_real.html" "$TMP/SRC"; read_speedup_silver_cost
      _c=`grep -o -E '/cave/(gather|down|runaway|speedUp)/[?]r[=][0-9]+' "$TMP/SRC" | sed -n 1p`
      botao_pago "$TMP/SRC" "$_c" && _o=pago || _o=prata
      _pr=`prata_pagina "$TMP/SRC"`
      printf '%s %s %s %s' "$SPEEDUP_SILVER_COST" "$_pr" "$_o" "$(( ${_pr:-0} * 15 / 100 ))" )
check "caverna, pagina real: preco 41580, prata da conta 1819,8M (rodape), botao em prata, limite 15%" \
    "41580 1819800000 prata 272970000" "$_r"
# Espera entre as voltas: 15s na janela da caverna (limite livre) e no :x4
# antes dos pulsos do Coliseu (02:44-04:24); 60s no resto da madrugada.
#   _fs100 HORA MIN ATIVA -> i
_fs100() { ( TMP="$_td62/fs"; mkdir -p "$TMP"; . "$LIB/crono.sh" > /dev/null 2>&1
             _M=$2; _A=$3; dia_atual() { _DIA=15; }; minuto_atual() { _MIN=$_M; }; func_cat() { printf '%s' "$i"; }
             caverna_noite_ativa() { [ "$_A" = 1 ]; }
             HOUR=$1; func_sleep 2>/dev/null ) ; }
check "func_sleep: caverna 15s; :x4 antes dos pulsos (02:44-04:24) 15s; resto 60s" "15 15 15 15 60 60 60 60" \
    "`_fs100 1 17 1` `_fs100 2 44 0` `_fs100 3 34 0` `_fs100 4 4 0` `_fs100 2 34 0` `_fs100 1 17 0` `_fs100 0 44 0` `_fs100 13 34 0`"
rm -rf "$_td62"; unset _td62 _r; unset -f _cn100 _fs100

# =============================================================================
printf "\n=== 60. sem ouro nos lacos de clique, estatua e descanso sob o disjuntor ===\n"
# =============================================================================
_td60=`mktemp -d`
_ok60="<html>x jsInterface.event(\"user=7;level=9\")</html>"

# --- botao_pago nos lacos de clique (carreira, campanha, arena, elixir,
# evento "fault" e caverna -cv). Pagina com UM link de acao; o rotulo diz se
# cobra ouro. Clicar devolve a pagina sem link (fim). Saida: quantos cliques
# (pedidos com ?r=) sairam.
#   _clk60 FUNCAO LINK pago|gratis
_clk60() {
    ( TMP="$_td60/c"; rm -rf "$TMP"; mkdir -p "$TMP"; URL=http://jogo; RUN=-cv
      export TMP URL RUN
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1
      for _m in career campaign arena check specialevent cave; do . "$LIB/$_m.sh" > /dev/null 2>&1; done
      cq_antes() { :; }; checkQuest() { :; }; clan_id() { :; }; get_config() { :; }
      espera_interrompivel() { :; }; sleep() { :; }; CLD=""
      case "$3" in pago) _rot="Atacar <img src='/images/icon/gold.png' alt=''/> 5" ;; *) _rot="Atacar" ;; esac
      printf "%s <a class='btn' href='%s'>%s</a> %s" "$_ok60" "$2" "$_rot" "$_ok60" > "$TMP/acao"
      # Home com o banner do evento (specialEvent), pagina do evento e o resto.
      printf "%s<div class='shb_text'><a href='/fault/'>Evento</a></div>" "$_ok60" > "$TMP/home"
      fetch_page() {
          case "$1" in *'?r='*) echo "$1" >> "$TMP/cliques"; : > "$TMP/clicou"; echo "fim" > "${2:-$TMP/SRC}"; return 0 ;; esac
          [ -f "$TMP/clicou" ] && { echo "fim" > "${2:-$TMP/SRC}"; return 0; }
          case "$1" in /) cp "$TMP/home" "${2:-$TMP/SRC}" ;; *) cp "$TMP/acao" "${2:-$TMP/SRC}" ;; esac
          return 0; }
      "$1" > /dev/null 2>&1
      [ -s "$TMP/cliques" ] && wc -l < "$TMP/cliques" | tr -d ' ' || printf 0 )
}
for _c60 in "career_func /career/attack/?r=11" "campaign_func /campaign/fight/?r=12" \
            "arena_duel /arena/attack/1/?r=13" "use_elixir /inv/chest/use/4/1/?r=14" \
            "specialEvent /fault/attack/?r=15" "cave_start /cave/speedUp/?r=16"; do
    set -- $_c60
    check "sem ouro: $1 nao clica botao pago" 0 "`_clk60 "$1" "$2" pago`"
    # O mesmo botao de graca: o laco segue clicando (o portao novo nao trava o normal).
    _r=`_clk60 "$1" "$2" gratis`
    case "$_r" in [1-9]*) ok "sem ouro: $1 ainda clica o botao gratis ($_r)" ;; *) bad "sem ouro: $1 parou de clicar o botao gratis ($_r)" ;; esac
done
set --

# --- Estatua: portao de 6h ANTES do cargo; conta sem cargo nao pede a pagina
# do cla a cada varredura.  _est60 CENARIO -> "pedidos marca"
_est60() {
    ( TMP="$_td60/e"; rm -rf "$TMP"; mkdir -p "$TMP"; URL=http://jogo; CLD=999; FUNC_clan_statue=y
      export TMP URL CLD
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/clanid.sh" > /dev/null 2>&1
      case "$1" in
          recente)   date +%s > "$TMP/last_estatua"; _pg="$_ok60" ;;
          sem_cargo) _pg="$_ok60" ;;
          mudo)      _pg="" ;;
      esac
      fetch_page() { echo "$1" >> "$TMP/req"; printf '%s' "$_pg" > "${2:-$TMP/SRC}"; return 0; }
      clan_statue > /dev/null 2>&1
      # Segunda varredura, ja sem o cache de 45s da pagina do cla.
      _CLAN_TS=0; clan_statue > /dev/null 2>&1
      _n=0; [ -s "$TMP/req" ] && _n=`wc -l < "$TMP/req" | tr -d ' '`
      printf '%s %s' "$_n" "`[ -f "$TMP/last_estatua" ] && echo marcou || echo sem_marca`" )
}
check "estatua: portao de 6h fechado nao pede a pagina do cla" "0 marcou" "`_est60 recente`"
check "estatua: conta sem cargo pede a pagina uma vez e espera o intervalo" "1 marcou" "`_est60 sem_cargo`"
check "estatua: pagina do cla sem resposta nao marca (tenta na proxima)" "2 sem_marca" "`_est60 mudo`"

# --- Descanso com o disjuntor aberto: so a sonda pede (no maximo 1 a cada
# 20s por aparelho); a Home nao sai. Fechado, o descanso pede a Home.
#   _ds60 aberto|fechado -> "home=N sonda=N"
_ds60() {
    ( HOME="$_td60/h"; TMP="$_td60/d"; rm -rf "$HOME" "$TMP"; mkdir -p "$HOME/.sls/net" "$TMP"
      URL=http://jogo; SLS_TAG=BR; SLS_DISJUNTOR=1; export HOME TMP URL SLS_TAG SLS_DISJUNTOR
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1
      [ "$1" = aberto ] && date +%s > "$HOME/.sls/net/BR.aberto"
      batalha_retomar() { return 1; }; caverna_ler_menu() { :; }
      run_curl() { echo sonda >> "$TMP/req"; }
      fetch_page() { echo "$1" >> "$TMP/req"; printf %s "$1" > "$TMP/.ult_req"
                     printf '%s' "$_ok60" > "${2:-$TMP/SRC}"; return 0; }
      descansar > /dev/null 2>&1; descansar > /dev/null 2>&1
      printf 'home=%s sonda=%s' "`grep -c '^/$' "$TMP/req"`" "`grep -c '^sonda$' "$TMP/req"`" )
}
check "disjuntor aberto: o descanso nao pede a Home (so a sonda, uma vez)" "home=0 sonda=1" "`_ds60 aberto`"
check "disjuntor fechado: o descanso pede a Home (a segunda volta reaproveita)" "home=1 sonda=0" "`_ds60 fechado`"
rm -rf "$_td60"; unset _td60 _r _c60 _ok60; unset -f _clk60 _est60 _ds60

# =============================================================================
printf "\n=== 61. reconexao com espera crescente (portao unico) ===\n"
# =============================================================================
# Senha recusada na reconexao: 60s, 120s, 300s, 900s (+ PID % 10); sem
# resposta: 30s sem escalar; sucesso zera. Relogio em $_td61/t.
_td61=`mktemp -d`
_anon61="<html><title>Error 404</title> jsInterface.event(\"user=0;level=0\")</html>"
_logada61="<html><title>Conta</title> jsInterface.event(\"user=7;level=9\")</html>"
#   _rl61 'COMANDOS' -> o que os comandos imprimem; pedidos em $_td61/req
#   O /user devolve $_td61/user; o POST devolve nada se $_td61/post_mudo existe.
_rl61() {
    ( TMP="$_td61/c"; mkdir -p "$TMP"; URL=http://jogo; TMP_COOKIE="$TMP/ck"
      export TMP URL TMP_COOKIE
      printf 'login=a&pass=b' | base64 > "$TMP/cript_file"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/session_check.sh" > /dev/null 2>&1
      . "$LIB/loginlogoff.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1
      date() { case "$1" in +%s) cat "$_td61/t" ;; *) command date "$@" ;; esac; }
      run_curl() {
          case "$*" in
              *data-urlencode*) echo POST >> "$_td61/req"; [ -f "$_td61/post_mudo" ] && return 28; cat /dev/null ;;
              *sign_in*)        echo SIGNIN >> "$_td61/req" ;;
              */user*)          echo USER >> "$_td61/req"; [ -f "$_td61/post_mudo" ] && [ -f "$_td61/ja_postou" ] && return 28
                                cat "$_td61/user" ;;
          esac
          case "$*" in *data-urlencode*) : > "$_td61/ja_postou" ;; esac; }
      fetch_train_stats() { :; }; clan_id() { :; }; messages_info() { :; }; parse_status() { :; }
      eval "$1" )
}
_nova61() { rm -rf "$_td61/c" "$_td61/post_mudo" "$_td61/ja_postou"; : > "$_td61/req"
            printf '%s' "$_anon61" > "$_td61/user"; echo 100000 > "$_td61/t"; }
_posts61() { grep -c '^POST$' "$_td61/req"; }

# Recusa em serie: so sai POST quando o degrau vence.
_nova61
_r=""
for _t61 in 100000 100000 100030 100070 100100 100200 100400 100510 100600 101500 101600 100000; do
    echo "$_t61" > "$_td61/t"; _rl61 'login_logoff > /dev/null 2>&1'
    _r="$_r`_posts61` "
done
# (j = PID % 10, de 0 a 9)
# 100000 POST 1 (proxima 100060+j) | 100000 e 100030 seguram
# 100070 POST 2 (100190+j)        | 100100 segura
# 100200 POST 3 (100500+j)        | 100400 segura
# 100510 POST 4 (101410+j)        | 100600 segura
# 101500 POST 5 (102400+j)        | 101600 segura
# 100000 relogio voltou: a marca ficou mais de 30 min no futuro, POST 6
check "reconexao: senha recusada espera 60s, 120s, 300s e 900s; relogio voltando nao prende" \
    "1 1 1 2 2 3 3 4 4 5 5 6 " "$_r"
check "reconexao: a marca guarda as recusas" 6 "`cut -d' ' -f2 "$_td61/c/relogin" 2>/dev/null`"
# A segurada nao apaga o cookie (a sessao ja caiu, mas nada novo saiu) e diz quando volta.
_nova61; mkdir -p "$_td61/c"; echo "100500 2" > "$_td61/c/relogin"
echo ck > "$_td61/c/ck"
_r=`_rl61 'login_logoff 2>&1; printf " rc=%s" $?'`
case "$_r" in *"nova tentativa de login em 500s"*" rc=1") ok "reconexao segurada: rc=1 e diz quando volta" ;; *) bad "reconexao segurada ($_r)" ;; esac
check "reconexao segurada: so o /user, cookie mantido" "0 1 S" \
    "`_posts61` `grep -c '^USER$' "$_td61/req"` `[ -s "$_td61/c/ck" ] && echo S || echo N`"
# Sem resposta no POST: 30s, sem escalar.
_nova61; : > "$_td61/post_mudo"
_rl61 'login_logoff > /dev/null 2>&1'
check "reconexao sem resposta: espera 30s e nao conta como recusa" "100030 0" "`cat "$_td61/c/relogin" 2>/dev/null`"
# Sessao de volta zera a marca.
_nova61; mkdir -p "$_td61/c"; echo "99000 3" > "$_td61/c/relogin"; printf '%s' "$_logada61" > "$_td61/user"
_rl61 'login_logoff > /dev/null 2>&1'
check "reconexao: sessao viva zera a marca" "zerou" "`[ -f "$_td61/c/relogin" ] && echo ficou || echo zerou`"
# A luta nao espera o portao (tem o proprio limite), mas a recusa conta.
_nova61; mkdir -p "$_td61/c"; echo "100500 1" > "$_td61/c/relogin"
_rl61 'login_logoff luta > /dev/null 2>&1'
check "reconexao na luta: nao espera o portao e a recusa conta" "1 2" "`_posts61` `cut -d' ' -f2 "$_td61/c/relogin"`"
check "luta_acabou: a reconexao da batalha passa 'luta'" 1 "`grep -c 'login_logoff luta$' "$LIB/info.sh"`"
# Descanso e painel com o portao fechado: nenhum login, nem o /user do login.
_nova61; mkdir -p "$_td61/c"; echo "100500 2" > "$_td61/c/relogin"
_rl61 'batalha_retomar() { return 1; }; disjuntor_segura() { return 1; }; caverna_ler_menu() { :; }
       fetch_page() { echo HOME >> "$_td61/req"; cat "$_td61/user" > "${2:-$TMP/SRC}"; return 0; }
       descansar > /dev/null 2>&1'
check "descanso com login recusado ha pouco: so a Home, sem /user nem POST" "1 0 0" \
    "`grep -c '^HOME$' "$_td61/req"` `grep -c '^USER$' "$_td61/req"` `_posts61`"
_nova61; mkdir -p "$_td61/c"; echo "100500 2" > "$_td61/c/relogin"
# Duas voltas do tarefas_livres: o painel so roda com o intervalo dele vencido.
_rl61 'for _v in 1 2; do stats_liberado && atualiza_stats > /dev/null 2>&1; done'
check "painel com login recusado ha pouco: um /user, sem POST, e espera o intervalo" "1 0" \
    "`grep -c '^USER$' "$_td61/req"` `_posts61`"
grep -q '^relogin_zerar$' "$LIB/sls.sh" && ok "login de entrada zera o portao da reconexao" || bad "sls.sh nao zera o portao"
rm -rf "$_td61"; unset _td61 _r _t61 _anon61 _logada61; unset -f _rl61 _nova61 _posts61

# =============================================================================
printf "\n=== 62. troca prata -> ouro: clique sem resposta nao vira segunda troca ===\n"
# =============================================================================
# Passagens seguidas do func_trade na mesma conta. O clique de cada passagem
# segue a lista _CLIQUES ("ok", "corta" = o servidor trocou mas a resposta
# nao veio, "mudo" = nao trocou e nao respondeu). O ouro da conta fica em
# $TMP/ouro (o clique que troca soma 100). Saida: "cliques=N dia=feito|aberto
# pendente=sim|nao ouro=N".
_td62t=`mktemp -d`
_tr62() { # _tr62 "CLIQUES" [PASSAGENS] [ouro_inicial] [pagina_viva=1]
    ( TMP="$_td62t/c"; rm -rf "$TMP"; mkdir -p "$TMP"; export TMP; URL=http://jogo
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/trade.sh" > /dev/null 2>&1
      FUNC_trade_dias=1; echo "${3:-50}" > "$TMP/ouro"; echo "$1" > "$TMP/cliques_roteiro"; : > "$TMP/cliques"
      _viva="<script>jsInterface.event(\"user=5;level=40\")</script>"
      fetch_page() { case "$1" in
          /trade/exchange)
              read -r _o < "$TMP/ouro"
              [ -f "$TMP/sem_pagina" ] && { : > "$TMP/SRC"; return 1; }
              echo "<img src='/images/icon/gold.png' alt='g'/> $_o <img src='/images/icon/silver.png' alt='s'/> 999,9M <a href='/trade/exchange/gold/100?r=4'>x</a>$_viva" > "$TMP/SRC" ;;
          /trade/exchange/gold/*)
              # A marca ja tem de estar em disco quando o pedido sai.
              cat "$TMP/trade_pendente" >> "$TMP/marca_no_clique" 2>/dev/null
              read -r _r < "$TMP/cliques_roteiro"; set -- $_r; _c=$1; shift; echo "$*" > "$TMP/cliques_roteiro"
              echo x >> "$TMP/cliques"
              case "$_c" in ok|corta) read -r _o < "$TMP/ouro"; echo $(( _o + 100 )) > "$TMP/ouro" ;; esac
              case "$_c" in ok) echo "trocou $_viva" > "$TMP/SRC"; return 0 ;; *) : > "$TMP/SRC"; return 1 ;; esac ;;
          esac; }
      _p=0; while [ "$_p" -lt "${2:-3}" ]; do func_trade > /dev/null 2>&1; _p=$((_p + 1)); done
      printf 'cliques=%s dia=%s pendente=%s ouro=%s' "`wc -l < "$TMP/cliques" | tr -d ' '`" \
          "`[ "\`cat "$TMP/last_trade" 2>/dev/null\`" = "\`date +%Y%m%d\`" ] && echo feito || echo aberto`" \
          "`[ -f "$TMP/trade_pendente" ] && echo sim || echo nao`" "`cat "$TMP/ouro"`" )
}
check "troca: resposta normal, uma troca e o dia feito" "cliques=1 dia=feito pendente=nao ouro=150" "`_tr62 ok`"
check "troca: o servidor trocou mas a resposta nao veio -> o ouro confirma, sem segunda troca" \
    "cliques=1 dia=feito pendente=nao ouro=150" "`_tr62 corta`"
check "troca: nao trocou e nao respondeu -> tenta de novo e a segunda sai" \
    "cliques=2 dia=feito pendente=nao ouro=150" "`_tr62 'mudo ok'`"
check "troca: duas tentativas sem confirmacao -> nao tenta a terceira no dia" \
    "cliques=2 dia=feito pendente=nao ouro=50" "`_tr62 'mudo mudo mudo' 4`"
check "troca: ouro abreviado (1,2K) nao enxerga o lote -> nao repete" \
    "cliques=1 dia=feito pendente=nao ouro=1,2K" "`_tr62 mudo 3 1,2K`"
_r=$( TMP="$_td62t/m"; rm -rf "$TMP"; mkdir -p "$TMP"; export TMP
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/trade.sh" > /dev/null 2>&1; FUNC_trade_dias=1
      fetch_page() { case "$1" in
          /trade/exchange) echo "<img src='/images/icon/gold.png' alt='g'/> 77 <img src='/images/icon/silver.png' alt='s'/> 999,9M <a href='/trade/exchange/gold/100?r=4'>x</a><script>jsInterface.event(\"user=5;level=40\")</script>" > "$TMP/SRC" ;;
          *) cat "$TMP/trade_pendente" > "$TMP/marca"; : > "$TMP/SRC"; return 1 ;; esac; }
      func_trade > /dev/null 2>&1; cat "$TMP/marca" )
check "troca: a marca pendente vai para o disco ANTES do clique (worker morto no meio)" \
    "`date +%Y%m%d` 77 100 1" "$_r"
# Pendente de outro dia nao vale; pagina de conferencia que nao veio nao decide.
_r=$( TMP="$_td62t/o"; rm -rf "$TMP"; mkdir -p "$TMP"; export TMP
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/trade.sh" > /dev/null 2>&1; FUNC_trade_dias=1
      echo "19990101 10 100 2" > "$TMP/trade_pendente"; : > "$TMP/cl"
      fetch_page() { case "$1" in
          /trade/exchange) echo "<img src='/images/icon/gold.png' alt='g'/> 10 <img src='/images/icon/silver.png' alt='s'/> 999,9M <a href='/trade/exchange/gold/100?r=4'>x</a><script>jsInterface.event(\"user=5;level=40\")</script>" > "$TMP/SRC" ;;
          *) echo x >> "$TMP/cl"; echo "<script>jsInterface.event(\"user=5;level=40\")</script>" > "$TMP/SRC" ;; esac; }
      func_trade > /dev/null 2>&1; printf '%s ' "`wc -l < "$TMP/cl" | tr -d ' '`"
      echo "`date +%Y%m%d` 10 100 1" > "$TMP/trade_pendente"; rm -f "$TMP/last_trade"; : > "$TMP/cl"
      fetch_page() { : > "$TMP/SRC"; return 1; }
      func_trade > /dev/null 2>&1
      printf '%s %s' "`[ -f "$TMP/last_trade" ] && echo feito || echo aberto`" "`cat "$TMP/trade_pendente"`" )
check "troca: pendente de ontem nao conta; conferencia sem resposta nao decide" \
    "1 aberto `date +%Y%m%d` 10 100 1" "$_r"
rm -rf "$_td62t"; unset _td62t _r; unset -f _tr62

# =============================================================================
printf "\n=== 63. processos: subshell de worker vivo, fd das credenciais, conta removida ===\n"
# =============================================================================
_td63=`mktemp -d`
# --- limpa_orfaos (play.sh): o subshell de um worker conhecido fica; o
# worker que nenhum .pid conhece (e o subshell dele) morre. Workers falsos
# com o mesmo caminho lib/sls.sh; o subshell anota o proprio PID (o $PPID do
# sh -c que ele roda).
if [ -r "/proc/$$/stat" ] && [ -r "/proc/$$/cmdline" ]; then
    mkdir -p "$_td63/lib" "$_td63/st" "$_td63/a" "$_td63/b"
    printf '%s\n' '( sh -c "echo \$PPID" > "$1/sub"; sleep 30; : ) &' 'sleep 30' > "$_td63/lib/sls.sh"
    sh "$_td63/lib/sls.sh" "$_td63/a" & _w63a=$!
    sh "$_td63/lib/sls.sh" "$_td63/b" & _w63b=$!
    echo "$_w63a" > "$_td63/st/BR_a.pid"
    _n63=0; while { [ ! -s "$_td63/a/sub" ] || [ ! -s "$_td63/b/sub" ]; } && [ "$_n63" -lt 50 ]; do sleep 0.1; _n63=$((_n63 + 1)); done
    read -r _s63a < "$_td63/a/sub"; read -r _s63b < "$_td63/b/sub"
    _r=$( LIBDIR="$_td63/lib"; STATUS_DIR="$_td63/st"; GOLD=""; RESET=""
          eval "`sed -n '/^limpa_orfaos() {/,/^}/p' "$ROOT/play.sh"`"
          limpa_orfaos )
    sleep 1
    # Zumbi conta como morto: o orfao morto fica "Z" ate o PID 1 recolhe-lo,
    # e o kill -0 ainda responde por ele.
    _vivo63() { case "`cut -d' ' -f3 /proc/$1/stat 2>/dev/null`" in ''|Z) printf M ;; *) printf V ;; esac; }
    check "limpa_orfaos: worker e subshell conhecidos ficam; orfao e o subshell dele morrem" \
        "VV MM 2" "`_vivo63 $_w63a``_vivo63 $_s63a` `_vivo63 $_w63b``_vivo63 $_s63b` `printf '%s' "$_r" | grep -o '[0-9][0-9]*' | head -n1`"
    kill "$_w63a" "$_s63a" "$_w63b" "$_s63b" 2>/dev/null
    unset _w63a _w63b _s63a _s63b _n63; unset -f _vivo63
else
    ok "limpa_orfaos: sem /proc legivel neste aparelho (teste pulado)"
fi
check "launch_worker: o worker nao herda o fd 3 (accounts.conf)" 1 \
    "`sed -n '/^launch_worker() {/,/^}/p' "$ROOT/play.sh" | grep -c '2>&1 3<&- &$'`"

# --- Conta removida com o painel no ar: o painel que ainda le o accounts.conf
# antigo NAO a relanca (status "stopped" antes de apagar o .pid).
_r=$( _h="$_td63/rm"; mkdir -p "$_h/.sls/status" "$_h/.sls/BR_Ze"
      printf '1|Ze|Y3JlZGVuY2lhbA==\n' > "$_h/acc.conf"; cp "$_h/acc.conf" "$_h/acc.antigo"
      echo 999999 > "$_h/.sls/status/BR_Ze.pid"; echo running > "$_h/.sls/status/BR_Ze.status"
      HOME="$_h"; SLSDIR="$ROOT"; STATUS_DIR="$_h/.sls/status"; ACCOUNTS_FILE="$_h/acc.conf"
      export HOME SLSDIR STATUS_DIR ACCOUNTS_FILE
      . "$LIB/contas.sh" > /dev/null 2>&1
      eval "`sed -n '/^remove_account() {/,/^}/p' "$ROOT/setup.sh"`"
      clear() { :; }; sleep() { :; }; escolher_conta() { srv=1; user=Ze; return 0; }
      printf 'y\nn\n' | remove_account > /dev/null 2>&1
      # O painel desta volta abriu o arquivo ANTES da remocao.
      ACCOUNTS_FILE="$_h/acc.antigo"
      launch_worker() { echo L >> "$_h/lancou"; }
      PANEL_SUPERVISE=1; PANEL_ONCE=1; PANEL_DRAW=0; SLS_EMOJI=0; SLS_COLS=60
      export PANEL_SUPERVISE PANEL_ONCE PANEL_DRAW SLS_EMOJI SLS_COLS ACCOUNTS_FILE
      . "$LIB/panel.sh" > /dev/null 2>&1; painel_loop > /dev/null 2>&1
      printf 'lancou=%s conf=%s' "`cat "$_h/lancou" 2>/dev/null | wc -l | tr -d ' '`" "`grep -c Ze "$_h/acc.conf"`" )
check "conta removida com o painel no ar: o painel nao a relanca" "lancou=0 conf=0" "$_r"
check "setup: cadastrar conta apaga o 'stopped' que sobrou dela" 1 \
    "`sed -n '/^add_account() {/,/^}/p' "$ROOT/setup.sh" | grep -c 'rm -f "\$HOME/.sls/status/\${tag}_\${user}.status"'`"
rm -rf "$_td63"; unset _td63 _r

# =============================================================================
printf "\n=== 64. menos pedidos: duelo, torneio de equipe, caverna -cv, /train, dia 1 ===\n"
# =============================================================================
_td64=`mktemp -d`

# --- Duelo do Cla: rodadas com o relogio andando um minuto por rodada.
#   _dm64 CLD LUTA HORA_INICIAL -> "rodadas=N" (LUTA 1 = toda rodada tem luta)
_dm64() {
    ( TMP="$_td64/dm"; rm -rf "$TMP"; mkdir -p "$TMP"; URL=http://jogo; export TMP URL
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/clandmg.sh" > /dev/null 2>&1
      CLD="$1"; _LUTA="$2"; echo "$3" > "$TMP/min"
      date() { case "$1" in
          +%H:%M) read -r _m < "$TMP/min"; echo $(( _m + 1 )) > "$TMP/min"; printf '09:%02d' "$_m" ;;
          +%s) echo 100000 ;; *) command date "$@" ;; esac; }
      run_curl_exec() { :; }; time_exit() { wait "$!" 2>/dev/null; }; sleep() { :; }
      batalha_marcar() { :; }; link_acao() { :; }; estado_luta() { echo luta; }; full_atualizar() { :; }
      clandmgfight_fight() { echo r >> "$TMP/rodadas"; _lt_lutou="$_LUTA"; }
      clandmgfight_start > /dev/null 2>&1
      printf 'rodadas=%s' "`cat "$TMP/rodadas" 2>/dev/null | wc -l | tr -d ' '`" )
}
check "duelo do cla: conta sem cla nao entra" "rodadas=0" "`_dm64 '' 1 30`"
check "duelo do cla: duas rodadas seguidas sem luta encerram (antes: ate :49)" "rodadas=2" "`_dm64 999 0 30`"
check "duelo do cla: com luta, nenhuma rodada nova a partir de :45" "rodadas=5" "`_dm64 999 1 40`"

# --- Torneio de Equipe: contador de 300s na pagina (membro). Relogio em
# $TMP/t, que o sleep anda. A luta abre aos 300s.
#   -> "leituras=N luta_aos=S"
_cc64() {
    ( TMP="$_td64/cc"; rm -rf "$TMP"; mkdir -p "$TMP"; URL=http://jogo; export TMP URL
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/clancommand.sh" > /dev/null 2>&1
      echo 100000 > "$TMP/t"; : > "$TMP/req"
      date() { case "$1" in +%s) cat "$TMP/t" ;; *) command date "$@" ;; esac; }
      sleep() { _s=${1%%[!0-9]*}; read -r _t < "$TMP/t"; echo $(( _t + ${_s:-0} )) > "$TMP/t"; }
      time_exit() { wait "$!" 2>/dev/null; }
      run_curl_exec() {
          echo "$1" >> "$TMP/req"; read -r _t < "$TMP/t"
          _p="<img src='/images/icon/level.png'/> <a href='/clancommand/myteam/'>Equipe</a>"
          if [ "$_t" -ge 100300 ]; then echo "$_p <a href='/clancommand/attack/?r=1'>Atacar</a>"
          else echo "$_p <span id='time_$(( (100300 - _t) * 1000 ))'>min</span> Lider nao se inscreveu <a href='/clancommand/'>Atualizar</a>"; fi; }
      full_atualizar() { :; }; batalha_marcar() { :; }; batalha_limpar() { :; }; evento_cancelar() { :; }
      clancommand_fight() { read -r _t < "$TMP/t"; echo "$(( _t - 100000 ))" > "$TMP/luta"; }; clancommand_inscrever() { :; }
      clancommand_start > /dev/null 2>&1
      printf 'leituras=%s luta_aos=%s' "`grep -c '/clancommand/$' "$TMP/req"`" "`cat "$TMP/luta" 2>/dev/null`" )
}
_r=`_cc64`
case "$_r" in
    "leituras="[1-8]" luta_aos=30"[0-5]) ok "torneio de equipe: dorme ate perto do inicio e entra na hora ($_r)" ;;
    *) bad "torneio de equipe: espera antes da luta ($_r)" ;;
esac

# --- Caverna -cv: depois da fuga do monstro o link vem da pagina NOVA; o
# preco do acelerar so conta quando a acao foi acelerar.
_r=$( TMP="$_td64/cv"; rm -rf "$TMP"; mkdir -p "$TMP"; URL=http://jogo; RUN=-cv; export TMP URL RUN
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/cave.sh" > /dev/null 2>&1
      clan_id() { :; }; get_config() { :; }; espera_interrompivel() { :; }; sleep() { :; }; bottom_info() { :; }
      _viva="<script>jsInterface.event(\"user=5;level=40\")</script>"
      echo 0 > "$TMP/passo"
      fetch_page() {
          case "$1" in /cave/) : ;; *) echo "$1" >> "$TMP/req" ;; esac
          read -r _p < "$TMP/passo"; echo $(( _p + 1 )) > "$TMP/passo"
          case "$_p" in
              0) echo "Monstro! <a href='/cave/runaway/?r=1'>Fugir</a> <a href='/cave/gather/?r=1'>Minerar</a> $_viva" ;;
              1) echo "<a href='/cave/gather/?r=2'>Minerar</a> <a href='/cave/speedUp/?r=2'>Acelerar <img src='/images/icon/silver.png' alt=''/> 500</a> $_viva" ;;
              *) echo "espera $_viva" ;;
          esac > "$TMP/SRC"; }
      cave_start > /dev/null 2>&1
      printf '%s| gasto=%s' "`tr '\n' ' ' < "$TMP/req"`" "$SILVER_SPENT_TOTAL" )
check "caverna -cv: link relido depois da fuga e preco so no acelerar" \
    "/cave/runaway/?r=1 /cave/gather/?r=2 | gasto=0" "$_r"

# --- /train sem energia na pagina: a segunda chamada espera o intervalo.
_r=$( TMP="$_td64/tr"; rm -rf "$TMP"; mkdir -p "$TMP"; URL=http://jogo; export TMP URL
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1
      run_curl() { echo x >> "$TMP/req"; echo "Vida (5000) : 1 : 2 : 3 : 4 : 5"; }
      FIXHP=5000; ACC_ENE=""
      fetch_train_stats; fetch_train_stats; fetch_train_stats
      printf '%s %s' "`wc -l < "$TMP/req" | tr -d ' '`" "$FIXHP" )
check "/train sem a energia na pagina: um pedido, nao um por chamada" "1 5000" "$_r"

# --- Dia 1 antes das 9h: a missao 11 nao tira a espera curta da madrugada.
_d164() { ( TMP="$_td64/d1"; rm -rf "$TMP"; mkdir -p "$TMP"; . "$LIB/crono.sh" > /dev/null 2>&1
            _M=$2; _A=$3; dia_atual() { _DIA=01; }; minuto_atual() { _MIN=$_M; }; func_cat() { printf '%s' "$i"; }
            caverna_noite_ativa() { [ "$_A" = 1 ]; }; coliseum_start() { :; }
            HOUR=$1; func_sleep 2>/dev/null ) ; }
check "dia 1 de madrugada: caverna e pulsos do Coliseu com 15s; resto 60s" "15 15 60" \
    "`_d164 1 17 1` `_d164 3 44 0` `_d164 6 17 0`"
rm -rf "$_td64"; unset _td64 _r; unset -f _dm64 _cc64 _d164

# =============================================================================
printf "\n=== 65. travas, um play.sh por vez, stop.sh e uninstall ===\n"
# =============================================================================
_td65=`mktemp -d`

# --- Sonda do disjuntor: trava sem PID e velha nao segura a sonda para sempre.
_r=$( HOME="$_td65/h"; TMP="$_td65/t"; URL=http://jogo; SLS_TAG=BR; SLS_DISJUNTOR=1
      export HOME TMP URL SLS_TAG SLS_DISJUNTOR; mkdir -p "$HOME/.sls/net" "$TMP"
      . "$LIB/info.sh" > /dev/null 2>&1
      run_curl() { echo sonda >> "$_td65/req"; }
      date +%s > "$HOME/.sls/net/BR.aberto"
      mkdir "$HOME/.sls/net/BR.sonda"; touch -t 200001010000 "$HOME/.sls/net/BR.sonda"
      disjuntor_segura > /dev/null 2>&1
      printf '%s' "`cat "$_td65/req" 2>/dev/null | wc -l | tr -d ' '`" )
check "sonda: trava sem PID ha mais de 1 min nao segura a sonda" 1 "$_r"
check "sls.sh: encerrado no meio do login, a trava sai junto (trap EXIT)" 1 \
    "`grep -c '^trap .*_lk_meu.*rm -rf .*LOCKDIR.* EXIT$' "$LIB/sls.sh"`"

# --- play.sh: um por vez no le/encerra/grava do orchestrator.pid; trava
# presa de um play.sh morto nao segura o proximo.
_bl65=`sed -n '/^_orq_lk=/,/^unset _orq_lk/p' "$ROOT/play.sh"`
_r=$( STATUS_DIR="$_td65/st"; mkdir -p "$STATUS_DIR/.orq.lock"
      sleep() { :; }
      eval "$_bl65"
      printf '%s %s' "`cat "$STATUS_DIR/orchestrator.pid"`" "`[ -d "$STATUS_DIR/.orq.lock" ] && echo trava_ficou || echo trava_saiu`" )
check "play.sh: trava presa nao segura; grava o pid e solta a trava" "$$ trava_saiu" "$_r"
_l1=`printf '%s\n' "$_bl65" | grep -n 'until mkdir' | cut -d: -f1`
_l2=`printf '%s\n' "$_bl65" | grep -n '^_orq=\$(cat' | cut -d: -f1`
_l3=`printf '%s\n' "$_bl65" | grep -n 'orchestrator.pid"$' | tail -n1 | cut -d: -f1`
_l4=`printf '%s\n' "$_bl65" | grep -n '^rm -rf "\$_orq_lk"' | cut -d: -f1`
if [ -n "$_l1" ] && [ -n "$_l4" ] && [ "$_l1" -lt "$_l2" ] && [ "$_l3" -lt "$_l4" ]; then
    ok "play.sh: a trava cobre ler o .pid, encerrar o anterior e gravar o novo"
else
    bad "play.sh: ordem da trava do orchestrator ($_l1 $_l2 $_l3 $_l4)"
fi
unset _bl65 _l1 _l2 _l3 _l4

# --- stop.sh: script_do_bot reconhece o shell rodando o play.sh desta pasta,
# de dentro dela ou de outra; nao um editor/visualizador nem o de outra pasta.
mkdir -p "$_td65/bot" "$_td65/outro"
printf 'sleep 30\n' > "$_td65/bot/play.sh"; printf 'sleep 30\n' > "$_td65/outro/play.sh"
( cd "$_td65/bot" && exec sh ./play.sh ) & _p65a=$!
( cd "$_td65" && exec sh "$_td65/bot/play.sh" ) & _p65b=$!
( cd "$_td65/bot" && exec tail -f play.sh ) > /dev/null 2>&1 & _p65c=$!
( cd "$_td65/outro" && exec sh ./play.sh ) & _p65d=$!
sleep 1
_r=$( SLSDIR=`cd "$_td65/bot" && pwd -P`
      eval "`sed -n '/^script_do_bot() {/,/^}/p' "$ROOT/stop.sh"`"
      for _p in $_p65a $_p65b $_p65c $_p65d; do script_do_bot "$_p" play.sh && printf S || printf N; done )
if [ -r "/proc/$_p65a/cmdline" ]; then
    check "stop.sh: play.sh do bot (de dentro e de fora) sim; tail -f play.sh e outro bot nao" "SSNN" "$_r"
else
    ok "stop.sh: sem /proc legivel neste aparelho (teste pulado)"
fi
kill $_p65a $_p65b $_p65c $_p65d 2>/dev/null; wait $_p65a $_p65b $_p65c $_p65d 2>/dev/null
unset _p65a _p65b _p65c _p65d

# --- stop.sh com 3 contas: TERM em todas e UMA espera (eram 2s por conta).
mkdir -p "$_td65/sh/.sls/status" "$_td65/w/lib"; printf 'sleep 60\n' > "$_td65/w/lib/sls.sh"
_ws65=""
for _c in A B C; do
    sh "$_td65/w/lib/sls.sh" & echo $! > "$_td65/sh/.sls/status/BR_$_c.pid"; _ws65="$_ws65 $!"
done
sleep 1
_t0=`date +%s`; ( HOME="$_td65/sh" sh "$ROOT/stop.sh" ) > /dev/null 2>&1; _t1=`date +%s`
_r=""; for _p in $_ws65; do kill -0 "$_p" 2>/dev/null && _r="${_r}V" || _r="${_r}M"; done
check "stop.sh: tres contas paradas" "MMM" "$_r"
[ $(( _t1 - _t0 )) -le 4 ] && ok "stop.sh: uma espera so ($(( _t1 - _t0 ))s para 3 contas; eram 1+2x3)" \
                           || bad "stop.sh: lento ($(( _t1 - _t0 ))s para 3 contas)"
kill $_ws65 2>/dev/null; wait $_ws65 2>/dev/null; unset _ws65 _t0 _t1 _c _p

# --- uninstall.sh: bot clonado direto no HOME nao apaga o HOME.
mkdir -p "$_td65/casa/lib" "$_td65/fake"
for _f in uninstall.sh play.sh stop.sh setup.sh; do cp "$ROOT/$_f" "$_td65/casa/"; done
cp "$LIB/sls.sh" "$LIB/info.sh" "$_td65/casa/lib/"
for _b in rm pkill sleep du termux-wake-unlock; do
    printf '#!/bin/sh\necho "%s $*" >> "%s"\n' "$_b" "$_td65/apagou" > "$_td65/fake/$_b"
    chmod +x "$_td65/fake/$_b"
done
echo REMOVER | ( HOME="$_td65/casa" PATH="$_td65/fake:$PATH" sh "$_td65/casa/uninstall.sh" ) > /dev/null 2>&1
grep -q "rm -rf" "$_td65/apagou" 2>/dev/null && _r=apagaria || _r=recusou
check "uninstall.sh: bot no proprio HOME nao apaga o HOME" recusou "$_r"
check "uninstall.sh: so apaga em /tmp o que o bot cria" 0 \
    "`grep -v '^ *#' "$ROOT/uninstall.sh" | grep -c '/tmp/sls_\*\|/tmp/diag_\*'`"
rm -rf "$_td65"; unset _td65 _r _f _b

# =============================================================================
printf "\n=== 66. Coliseu: troca por inimigo forte com 4s e no maximo 2 seguidas ===\n"
# =============================================================================
# Pedido do dono (3.9.107). Mesmo roteiro de paginas para o codigo ANTIGO
# (o coliseum.sh atual com as tres linhas da troca devolvidas ao que eram) e o
# NOVO: sala so com inimigo mais forte (HP 9000 x 5000 meu), sem cura nem
# esquiva devidas; relogio simulado, 1s por pedido; aos 40s o jogo encerra.
_td66=`mktemp -d`
sed -e 's/\[ "\$time_since_last_atk" -ge "\$COL_TROCA_MIN" \]/[ "$time_since_last_atk" -ne "$LA" ]/' \
    -e 's/\[ "\$_col_trocas" -lt "\$COL_TROCAS_MAX" \] && \\$/[ 1 = 1 ] \&\& \\/' \
    -e 's/_col_alvo=\$COL_TROCA_MIN$/_col_alvo=$LA/' \
    "$LIB/coliseum.sh" > "$_td66/coliseum_antigo.sh"
#   _col66 ARQUIVO_DO_MODULO [HP_DO_INIMIGO] -> "segundo:acao ..." das acoes de luta
_col66() {
    _en66="${2:-9000}"
    ( TMP="$_td66/c"; rm -rf "$TMP"; mkdir -p "$TMP"; URL=http://jogo; SLS_PACING=0
      export TMP URL SLS_PACING
      . "$LIB/info.sh" > /dev/null 2>&1; . "$1" > /dev/null 2>&1
      echo 1000 > "$TMP/t"; echo 10000 > "$TMP/col_full"; : > "$TMP/req"; COLISEU_GRAFICO=1
      date() { case "$1" in +%s) cat "$TMP/t" ;; *) command date "$@" ;; esac; }
      sleep() { _s=${1%%[!0-9]*}; read -r _t < "$TMP/t"; echo $(( _t + ${_s:-0} )) > "$TMP/t"; }
      run_curl_exec() {
          read -r _t < "$TMP/t"; echo $(( _t + 1 )) > "$TMP/t"
          case "$1" in */coliseum/atk/*|*/coliseum/atkrnd/*) _v=${1#*/coliseum/}; echo "$(( _t - 1000 )):${_v%%/*}" >> "$TMP/req" ;; esac
          if [ "$_t" -ge 1040 ]; then
              echo "<img src='/images/icon/level.png'/> <a href='/coliseum/?end_fight=true'>Fim</a>"
          else
              echo "<img src='/images/icon/level.png'/> <img src='/images/icon/health.png' alt='hp'/> 5000 Inimigo <span class='nwr'>&nbsp;$_en66</span>
                    <a href='/coliseum/atk/?r=$_t'>a</a> <a href='/coliseum/atkrnd/?r=$_t'>t</a> <a href='/coliseum/dodge/?r=$_t'>d</a> <a href='/coliseum/heal/?r=$_t'>h</a>"
          fi; }
      coliseum_fight > /dev/null 2>&1
      tr '\n' ' ' < "$TMP/req" )
}
_v66=`_col66 "$LIB/coliseum.sh"`
_a66=`_col66 "$_td66/coliseum_antigo.sh"`
printf "  [INFO] antigo: %s\n  [INFO] novo:   %s\n" "$_a66" "$_v66"
# Resumo: ataques, trocas, maior sequencia de trocas e menor intervalo entre acoes.
_res66() { printf '%s\n' $1 | awk -F: '
    { if ($2 == "atk") { a++; s = 0 } else { r++; s++; if (s > m) m = s }
      if (NR > 1 && (min == "" || $1 - u < min)) min = $1 - u; u = $1 }
    END { printf "atk=%d trocas=%d seguidas=%d intervalo_min=%d", a, r, m, min }'; }
_rv66=`_res66 "$_v66"`; _ra66=`_res66 "$_a66"`
printf "  [INFO] antigo: %s | novo: %s\n" "$_ra66" "$_rv66"
case "$_ra66" in "atk=0 "*) ok "Coliseu ANTIGO no roteiro: so trocava, nenhum ataque ($_ra66)" ;;
                 *) bad "Coliseu antigo nao reproduz o defeito ($_ra66)" ;; esac
case "$_rv66" in
    "atk="[1-9]*" seguidas=2 intervalo_min="[4-9]*) ok "Coliseu NOVO: ataca, no maximo 2 trocas seguidas, acoes com 4s ou mais ($_rv66)" ;;
    *) bad "Coliseu novo ($_rv66)" ;;
esac
# A ordem do novo: troca, troca, ataque, de novo.
case "$_v66" in
    *":atkrnd "*":atkrnd "*":atk "*":atkrnd "*":atkrnd "*":atk "*) ok "Coliseu NOVO: troca, troca, ataque (e repete)" ;;
    *) bad "Coliseu novo fora da ordem troca, troca, ataque ($_v66)" ;;
esac
# Inimigo mais fraco (3000 x 5000 meu): a troca nao entra, e o antigo e o
# novo fazem exatamente os mesmos pedidos (so ataques, a cada 6s).
_v66f=`_col66 "$LIB/coliseum.sh" 3000`; _a66f=`_col66 "$_td66/coliseum_antigo.sh" 3000`
case "$_v66f" in
    *atk*) check "Coliseu com inimigo fraco: antigo e novo iguais" "$_a66f" "$_v66f" ;;
    *)     bad "Coliseu com inimigo fraco: nenhum ataque no roteiro ($_v66f)" ;;
esac
rm -rf "$_td66"; unset _td66 _v66 _a66 _rv66 _ra66 _v66f _a66f _en66; unset -f _col66 _res66

# =============================================================================
printf "\n=== 67. HP de 7 digitos, disjuntor sem perda, logs, -cl, credencial e cookie ===\n"
# =============================================================================
_td67=`mktemp -d`

# --- HP: a mesma expressao de cada modulo, tirada do arquivo, numa pagina
# com 1.234.567 de HP (eram 6 digitos: 123456) e numa com 123456 (igual).
printf "%s\n" "<img src='/images/icon/health.png' alt='hp'/> 1234567 x" > "$_td67/hp7"
printf "%s\n" "<img src='/images/icon/health.png' alt='hp'/> 123456 x" > "$_td67/hp6"
_r=""
for _m in altars clanfight clandmg clancoliseum flagfight coliseum; do
    _re=`sed -n 's/.*\((hp)\[^A-Za-z0-9\]{1,4}\[0-9\]{1,[0-9]}\).*/\1/p' "$LIB/$_m.sh" | head -n1`
    _a=`grep -o -E "$_re" "$_td67/hp7" | grep -o -E '[0-9]+$'`
    _b=`grep -o -E "$_re" "$_td67/hp6" | grep -o -E '[0-9]+$'`
    _r="$_r$_m=$_a/$_b "
done
check "HP das lutas: 1234567 inteiro (e 123456 como antes) nos seis modulos" \
    "altars=1234567/123456 clanfight=1234567/123456 clandmg=1234567/123456 clancoliseum=1234567/123456 flagfight=1234567/123456 coliseum=1234567/123456 " "$_r"
_r=`sed -n 's/.*\((nbsp)\[^A-Za-z0-9\]{1,2}\[0-9\]{1,[0-9]}\).*/\1/p' "$LIB/coliseum.sh" | head -n1`
check "Coliseu: HP do inimigo com ate 9 digitos" "1234567" \
    "`printf '%s\n' '<span>&nbsp;1234567</span>' | grep -o -E "$_r" | grep -o -E '[0-9]+$'`"

# --- Disjuntor: tres contas falhando AO MESMO TEMPO abrem (cada uma grava o
# seu arquivo; antes o awk+mv de uma podia apagar a linha de outra).
_r=$( HOME="$_td67/h"; URL=http://jogo; SLS_TAG=BR; SLS_DISJUNTOR=1; export HOME URL SLS_TAG SLS_DISJUNTOR
      mkdir -p "$HOME/.sls"; . "$LIB/info.sh" > /dev/null 2>&1
      for _c in BR_A BR_B BR_C; do ( TMP="$_td67/$_c"; disjuntor_falha > /dev/null 2>&1 ) & done; wait
      printf '%s %s' "`[ -f "$HOME/.sls/net/BR.aberto" ] && echo aberto || echo fechado`" \
          "`ls "$HOME/.sls/net" | grep -c '^BR\.falha\.BR_'`" )
check "disjuntor: tres contas ao mesmo tempo abrem; um arquivo de falha por conta" "aberto 3" "$_r"
check "disjuntor: sem regravar arquivo comum (awk + mv)" 0 "`grep -c 'mv -f "\$_DJ.falhas' "$LIB/info.sh"`"

# --- Logs: req.stat grande (worker que morre antes dos 300 registros) e o
# blessing_blocked.log entram no rotate_log; o modo -cv passa por ele.
_r=$( TMP="$_td67/lg"; mkdir -p "$TMP"; eval "$(sed -n '/^_rl_voltas=0/,/^}/p' "$LIB/sls.sh")"
      _i=0; while [ "$_i" -lt 4000 ]; do echo "1700000000 200 300 0"; _i=$((_i + 1)); done > "$TMP/req.stat"
      head -c 5242881 /dev/zero > "$TMP/blessing_blocked.log"
      rotate_log
      printf '%s %s %s' "`grep -c . "$TMP/req.stat"`" "`wc -c < "$TMP/blessing_blocked.log" | tr -d ' '`" \
          "`wc -c < "$TMP/blessing_blocked.log.1" | tr -d ' '`" )
check "rotate_log: req.stat grande vira 200 linhas; blessing_blocked.log roda" "200 0 1048576" "$_r"
check "caverna -cv: o laco confere os logs" 1 "`sed -n '/^cave_start() {/,/^}/p' "$LIB/cave.sh" | grep -c 'rotate_log'`"
# Sem blessing_blocked.log, ERROR_DEBUG e req.stat (o normal numa conta nova):
# nenhuma linha de erro. Na 3.9.108 a 3.9.112 o "<" de um arquivo que nao
# existe escrevia "cannot open" no sls.log a cada 10 voltas (visto no WSL).
_r=$( TMP="$_td67/lg0"; mkdir -p "$TMP"; echo x > "$TMP/sls.log"
      eval "$(sed -n '/^_rl_voltas=0/,/^}/p' "$LIB/sls.sh")"
      rotate_log 2>&1 )
check "rotate_log: arquivos que nao existem nao viram erro no log" "" "$_r"

# --- Modo -cl: o Coliseu nao comeca nos minutos antes do Torneio de Equipe.
_pt67=`sed -n 's/^ *(\(09:2\[4-9\]|.*\))$/\1/p' "$LIB/coliseum.sh" | head -n1`
_r=""
for _h in 11:24 11:29 17:54 17:59 11:20 17:50; do
    eval "case $_h in $_pt67) _r=\"\${_r}B\" ;; *) _r=\"\${_r}L\" ;; esac"
done
check "modo -cl: bloqueia 11:24-11:29 e 17:54-17:59 (Torneio de Equipe), libera 11:20 e 17:50" "BBBBLL" "$_r"

# --- Conta removida respondendo "n" para os dados: credencial e cookie saem.
_r=$( _h="$_td67/rm"; mkdir -p "$_h/.sls/status" "$_h/.sls/BR_Ze"
      printf '1|Ze|Y3JlZGVuY2lhbA==\n' > "$_h/acc.conf"
      echo cred > "$_h/.sls/BR_Ze/cript_file"; echo ck > "$_h/.sls/BR_Ze/cookie.txt"; echo log > "$_h/.sls/BR_Ze/sls.log"
      HOME="$_h"; SLSDIR="$ROOT"; STATUS_DIR="$_h/.sls/status"; ACCOUNTS_FILE="$_h/acc.conf"
      export HOME SLSDIR STATUS_DIR ACCOUNTS_FILE
      . "$LIB/contas.sh" > /dev/null 2>&1
      eval "`sed -n '/^remove_account() {/,/^}/p' "$ROOT/setup.sh"`"
      clear() { :; }; sleep() { :; }; escolher_conta() { srv=1; user=Ze; return 0; }
      printf 'y\nn\n' | remove_account > /dev/null 2>&1
      ls "$_h/.sls/BR_Ze" | tr '\n' ' ' )
check "conta removida (dados mantidos): cript_file e cookie saem, o log fica" "sls.log " "$_r"

# --- test_login: cookie num arquivo do mktemp, apagado no fim; o trap de
# quem chama fica como estava (uma versao com trap proprio o apagava).
_r=$( TMPDIR="$_td67/tmp"; mkdir -p "$TMPDIR"; export TMPDIR
      . "$LIB/session_check.sh" > /dev/null 2>&1
      curl() { while [ "$#" -gt 0 ]; do [ "$1" = -c ] && { echo "$2" >> "$TMPDIR/../ck"; shift; }; shift; done
               [ -f "$TMPDIR/../ck" ] && cat > /dev/null; echo "<title>x</title>"; }
      test_login https://jogo a b > /dev/null 2>&1
      _c=`head -n1 "$TMPDIR/../ck"`
      case "${_c##*/}" in sls_test_$$.txt) printf 'nome_fixo ' ;; sls_test_*) printf 'mktemp ' ;; *) printf '%s ' "$_c" ;; esac
      [ -e "$_c" ] && printf 'ficou ' || printf 'apagado '
      grep -q 'test_login() {' "$LIB/session_check.sh" && \
          sed -n '/^test_login() {/,/^}/p' "$LIB/session_check.sh" | grep -q '^ *trap' && printf 1 || printf 0 )
case "$_r" in
    "mktemp apagado 0") ok "test_login: cookie do mktemp, apagado no fim, sem trap sobrando" ;;
    "nome_fixo apagado 0") ok "test_login: sem mktemp neste aparelho, nome com o PID (apagado no fim)" ;;
    *) bad "test_login: cookie ($_r)" ;;
esac
rm -rf "$_td67"; unset _td67 _r _m _re _a _b _c _pt67 _h

# =============================================================================
printf "\n=== 68. troca por aliado com 4s ou mais nos cinco modulos de cla ===\n"
# =============================================================================
# Pedido do dono (3.9.109). Mesmo roteiro de paginas para o codigo ANTIGO (o
# modulo atual com a condicao da troca devolvida a "-ne") e o NOVO, nos cinco
# modulos: alvo sempre aliado (na lista do cla) ou sempre inimigo; HP cheio
# (sem cura nem esquiva); relogio simulado, 1s por pedido; aos 40s o jogo
# encerra. Saida: "segundo:acao" dos golpes (attack e attackrandom).
_td68=`mktemp -d`
#   _al68 MODULO FUNCAO SECAO ARQUIVO_DO_MODULO NOME_DO_ALVO
_al68() {
    ( TMP="$_td68/c"; rm -rf "$TMP"; mkdir -p "$TMP"; URL=http://jogo; SLS_PACING=0
      export TMP URL SLS_PACING
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/allies.sh" > /dev/null 2>&1; . "$4" > /dev/null 2>&1
      echo 1000 > "$TMP/t"; : > "$TMP/req"; echo Amigo > "$TMP/callies.txt"
      for _f in FULL ccol_full flag_full; do echo 100000 > "$TMP/$_f"; done
      _S="$3"; _N="$5"
      date() { case "$1" in +%s) cat "$TMP/t" ;; *) command date "$@" ;; esac; }
      sleep() { _s=${1%%[!0-9]*}; read -r _t < "$TMP/t"; echo $(( _t + ${_s:-0} )) > "$TMP/t"; }
      _pg68() {
          if [ "$1" -ge 1040 ]; then
              echo "<img src='/images/icon/level.png'/> <a href='/$_S/?close=reward'>Fim</a>"
          else
              echo "<img src='/images/icon/level.png'/> <img src='/images/icon/race/1.png' alt=''/> Minha <span class='nwr'><img src='/images/icon/health.png' alt='hp'/> 50000</span> <img src='/images/icon/race/0.png' alt=''/> $_N <span class='nwr'><img src='/images/icon/health.png' alt='hp'/>&nbsp;8000</span> <a href='/$_S/attack/?r=$1'>a</a> <a href='/$_S/attackrandom/?r=$1'>t</a> <a href='/$_S/dodge/?r=$1'>d</a>"
          fi; }
      run_curl_exec() {
          read -r _t < "$TMP/t"; echo $(( _t + 1 )) > "$TMP/t"
          case "$1" in */attack/*|*/attackrandom/*) _v=${1#*/"$_S"/}; echo "$(( _t - 1000 )):${_v%%/*}" >> "$TMP/req" ;; esac
          _pg68 "$_t"; }
      for _f in src.html SRC ccol_src flag_src; do _pg68 1000 > "$TMP/$_f"; done
      "$2" > /dev/null 2>&1
      tr '\n' ' ' < "$TMP/req" )
}
# Resumo: golpes, trocas e menor intervalo entre duas acoes.
_res68() { printf '%s\n' $1 | awk -F: '
    { if ($2 == "attack") a++; else r++
      if (NR > 1 && (min == "" || $1 - u < min)) min = $1 - u; u = $1 }
    END { printf "atk=%d trocas=%d intervalo_min=%d", a, r, min }'; }
for _m68 in "altars altars_fight altars" "clanfight clanfight_fight clanfight" \
            "clandmg clandmgfight_fight clandmgfight" "clancoliseum clancoliseum_fight clancoliseum" \
            "flagfight flagfight_fight flagfight"; do
    set -- $_m68
    sed 's/\[ "\$_latk" -ge "\$LA" \] && \[ "\$_grey" = 0 \]/[ "$_latk" -ne "$LA" ] \&\& [ "$_grey" = 0 ]/' \
        "$LIB/$1.sh" > "$_td68/antigo_$1.sh"
    _v=`_al68 "$1" "$2" "$3" "$LIB/$1.sh" Amigo`;            _rv=`_res68 "$_v"`
    _a=`_al68 "$1" "$2" "$3" "$_td68/antigo_$1.sh" Amigo`;   _ra=`_res68 "$_a"`
    printf "  [INFO] %s aliado: antigo %s | novo %s\n" "$1" "$_ra" "$_rv"
    case "$_rv" in
        *"trocas="[1-9]*" intervalo_min="[4-9]*) ok "$1: troca por aliado so com 4s ou mais ($_rv)" ;;
        *) bad "$1: troca por aliado ($_rv; antigo $_ra)" ;;
    esac
    case "$_ra" in *" intervalo_min="[0-3]) ok "$1: o antigo trocava antes de 4s (roteiro reproduz o defeito)" ;;
                   *) bad "$1: o antigo nao reproduz a troca colada ($_ra)" ;; esac
    # Alvo inimigo: nenhuma troca, e antigo e novo fazem os mesmos pedidos.
    _v=`_al68 "$1" "$2" "$3" "$LIB/$1.sh" Inimigo`
    _a=`_al68 "$1" "$2" "$3" "$_td68/antigo_$1.sh" Inimigo`
    case "$_v" in
        *attack*) check "$1: alvo inimigo, antigo e novo iguais" "$_a" "$_v" ;;
        *) bad "$1: alvo inimigo sem golpe no roteiro ($_v)" ;;
    esac
done
set --
rm -rf "$_td68"; unset _td68 _m68 _v _a _rv _ra; unset -f _al68 _res68

# =============================================================================
printf "\n=== 69. cura so conta a recarga quando a pagina confirma ===\n"
# =============================================================================
# Pedido do dono (3.9.110). Mesmo roteiro de paginas para o codigo ANTIGO (o
# modulo atual com o cura_relogio de antes: grava sempre a hora do pedido) e
# o NOVO, em seis modulos: HP 30000 de 100000 (abaixo do limiar), botao da
# cura sempre na tela, alvo inimigo fraco; relogio simulado, 1s por pedido,
# 40s de luta. Cada clique na cura segue o roteiro: "ok" sobe o HP para
# 70000, "recusa" deixa como esta (o jogo recusou). Saida: "segundos das
# curas | HP no fim".
_td69=`mktemp -d`
#   _cu69 FUNCAO SECAO ARQUIVO_DO_MODULO ROTEIRO [antigo]
_cu69() {
    ( TMP="$_td69/c"; rm -rf "$TMP"; mkdir -p "$TMP"; URL=http://jogo; SLS_PACING=0
      export TMP URL SLS_PACING
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/allies.sh" > /dev/null 2>&1; . "$3" > /dev/null 2>&1
      [ "$5" = antigo ] && cura_relogio() { CURA_RELOGIO="$1"; _CURA_TENTOU=0; }
      echo 1000 > "$TMP/t"; : > "$TMP/req"; echo 30000 > "$TMP/hpv"; echo "$4" > "$TMP/rot"
      for _f in FULL ccol_full flag_full col_full; do echo 100000 > "$TMP/$_f"; done
      _S="$2"; COLISEU_GRAFICO=1
      date() { case "$1" in +%s) cat "$TMP/t" ;; *) command date "$@" ;; esac; }
      sleep() { _s=${1%%[!0-9]*}; read -r _t < "$TMP/t"; echo $(( _t + ${_s:-0} )) > "$TMP/t"; }
      _pg69() {
          read -r _h < "$TMP/hpv"
          if [ "$1" -ge 1040 ]; then
              echo "<img src='/images/icon/level.png'/> <a href='/$_S/?close=reward'>Fim</a> <a href='/coliseum/?end_fight=true'>x</a>"
          elif [ "$_S" = coliseum ]; then
              echo "<img src='/images/icon/level.png'/> <img src='/images/icon/health.png' alt='hp'/> $_h Inimigo <span class='nwr'>&nbsp;3000</span> <a href='/coliseum/atk/?r=$1'>a</a> <a href='/coliseum/atkrnd/?r=$1'>t</a> <a href='/coliseum/dodge/?r=$1'>d</a> <a href='/coliseum/heal/?r=$1'>h</a>"
          else
              echo "<img src='/images/icon/level.png'/> <img src='/images/icon/race/1.png' alt=''/> Minha <span class='nwr'><img src='/images/icon/health.png' alt='hp'/> $_h</span> <img src='/images/icon/race/0.png' alt=''/> Inimigo <span class='nwr'><img src='/images/icon/health.png' alt='hp'/>&nbsp;8000</span> <a href='/$_S/attack/?r=$1'>a</a> <a href='/$_S/attackrandom/?r=$1'>t</a> <a href='/$_S/dodge/?r=$1'>d</a> <a href='/$_S/heal/?r=$1'>h</a>"
          fi; }
      run_curl_exec() {
          read -r _t < "$TMP/t"; echo $(( _t + 1 )) > "$TMP/t"
          case "$1" in
              */heal/*)
                  echo "$(( _t - 1000 ))" >> "$TMP/req"
                  read -r _r < "$TMP/rot"; set -- $_r; _c=$1; shift; echo "$*" > "$TMP/rot"
                  [ "$_c" = ok ] && echo 70000 > "$TMP/hpv" ;;
          esac
          _pg69 "$_t"; }
      for _f in src.html SRC ccol_src ccmd_src col_src; do _pg69 1000 > "$TMP/$_f"; done
      "$1" > /dev/null 2>&1
      printf '%s| %s' "`tr '\n' ' ' < "$TMP/req"`" "`cat "$TMP/hpv"`" )
}
for _m69 in "altars altars_fight altars" "clanfight clanfight_fight clanfight" \
            "clandmg clandmgfight_fight clandmgfight" "clancoliseum clancoliseum_fight clancoliseum" \
            "clancommand clancommand_fight clancommand" "coliseum coliseum_fight coliseum"; do
    set -- $_m69
    # Recusada a primeira: o antigo espera 90s com o HP baixo; o novo tenta
    # de novo LA segundos depois e a conta cura.
    _a=`_cu69 "$2" "$3" "$LIB/$1.sh" "recusa ok" antigo`; _v=`_cu69 "$2" "$3" "$LIB/$1.sh" "recusa ok"`
    printf "  [INFO] %s, primeira recusada: antigo %s | novo %s\n" "$1" "$_a" "$_v"
    case "$_a" in *"| 30000") ;; *) bad "$1: o antigo nao reproduz os 90s sem cura ($_a)" ;; esac
    case "$_v" in
        [0-9]*" "[0-9]*" | 70000") ok "$1: cura recusada sai de novo e a conta cura ($_v)" ;;
        *) bad "$1: cura recusada ($_v)" ;;
    esac
    # Cura que sobe o HP: antigo e novo iguais.
    _a=`_cu69 "$2" "$3" "$LIB/$1.sh" "ok" antigo`; _v=`_cu69 "$2" "$3" "$LIB/$1.sh" "ok"`
    check "$1: cura confirmada, antigo e novo iguais" "$_a" "$_v"
    # Nunca confirma: no maximo dois pedidos de cura por recarga (90s); se o
    # primeiro valeu, o jogo recusa o segundo (o elixir tem recarga de 90s).
    _v=`_cu69 "$2" "$3" "$LIB/$1.sh" "recusa recusa recusa recusa"`
    case "$_v" in
        [0-9]*" "[0-9]*" | 30000") ok "$1: sem confirmacao, so dois pedidos de cura por recarga ($_v)" ;;
        *) bad "$1: sem confirmacao ($_v)" ;;
    esac
done
set --
rm -rf "$_td69"; unset _td69 _m69 _a _v; unset -f _cu69

# =============================================================================
printf "\n=== 70. descanso numa leitura so e log de combate guardado no painel ===\n"
# =============================================================================
_td70=`mktemp -d`

# --- descanso_ler x a leitura de antes (o grep do out_gate, o grep do menu da
# caverna com o relogio_seg_sh e o sessao_estado), pagina a pagina.
_ant70() { # ARQUIVO -> "GATE CAVE SESSAO" do jeito da 3.9.110
    if grep -q 'out_gate_confirm' "$1" 2>/dev/null; then _g=1; else _g=0; fi
    _cv=`grep -o -m 1 -E "href='/cave/'>(<img[^>]*>)?[^<()]*<span class='grey'>\\(([0-9]{1,2}:)?[0-9]{1,2}:[0-9]{2}\\)" "$1" 2>/dev/null`
    _cv=${_cv%%"
"*}; _cv=${_cv##*\(}; _cv=${_cv%\)}
    if [ -n "$_cv" ]; then _cv=`relogio_seg_sh "$_cv"`
    elif grep -q -E "href='/cave/'>(<img[^>]*>)?[^<()]*<span class='green'> ?\\(\\+\\)" "$1" 2>/dev/null; then _cv=+
    else _cv=-; fi
    printf '%s %s %s' "$_g" "$_cv" "`sessao_estado "$1"`"
}
_v70="jsInterface.event(\"user=5;level=40\")"
_menu70="<a href='/king/'>Rei <span class='grey'>(0:10:00)</span></a>"
_i70=0
for _p70 in \
    "<a href='/cave/'><img src='/images/c.png'/>Caverna <span class='grey'>(1:02:03)</span></a> $_menu70 $_v70" \
    "<a href='/cave/'>Caverna <span class='grey'>(07:09)</span></a> $_menu70 $_v70" \
    "<a href='/cave/'>Caverna <span class='green'> (+)</span></a> $_menu70 $_v70" \
    "$_menu70 jsInterface.event(\"user=0;level=0\")" \
    "<form action='/?sign_in=1'><input name='pass'/></form>" \
    "<img src='/images/icon/level.png'/> 40 pagina cortada" \
    "Fuja da batalha? <a href='/?out_gate_confirm=true'>sim</a> $_v70" \
    "<html>502 Bad Gateway</html>" \
    ""; do
    _i70=$((_i70 + 1))
    printf '%s\n' "$_p70" > "$_td70/p$_i70"; [ -n "$_p70" ] || : > "$_td70/p$_i70"
    _r=$( TMP="$_td70"; . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1
          descanso_ler "$_td70/p$_i70"; printf '%s %s %s|' "$_DL_GATE" "$_DL_CAVE" "$_DL_SESSAO"
          _ant70 "$_td70/p$_i70" )
    check "descanso_ler = leitura de antes (pagina $_i70)" "${_r#*|}" "${_r%%|*}"
done
_r=$( TMP="$_td70"; . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1
      descanso_ler "$_td70/nao_existe"; printf '%s %s %s' "$_DL_GATE" "$_DL_CAVE" "$_DL_SESSAO" )
check "descanso_ler: arquivo que nao existe = sem resposta, sem caverna" "0 - sem_resposta" "$_r"
_r=`sed -n '/^descansar() {/,/^}/p' "$LIB/crono.sh" | grep -v '^ *#' | grep -c 'grep \|sessao_estado'`
check "descansar: nenhum grep nem sessao_estado (uma leitura so da Home)" 0 "$_r"

# --- Painel: o log guardado sai igual ao do combate_log, e o awk so roda de
# novo com a pagina nova ou a largura nova.
mkdir -p "$_td70/conta"
printf '%s\n' "<div>Bahamut acertou Voce por 2864</div><div>Voce usou Posicao defensiva</div><div>Fulano usou Pocao</div>" > "$_td70/conta/SRC"
touch -t 202601010000 "$_td70/conta/SRC"
_r=$( HOME=/nao/existe; SLS_EMOJI=0; export HOME SLS_EMOJI
      . "$LIB/panel.sh" > /dev/null 2>&1
      _ref=`combate_log "$_td70/conta" 2 60`
      combate_log_cache "$_td70/conta" 2 60 "$_td70/cache"; _a="$_LOG"
      [ "$_a" = "$_ref" ] && printf 'igual ' || printf 'diferente '
      combate_log() { echo RECALCULOU; }
      combate_log_cache "$_td70/conta" 2 60 "$_td70/cache"
      [ "$_LOG" = "$_ref" ] && printf 'guardado ' || printf '[%s] ' "$_LOG"
      combate_log_cache "$_td70/conta" 2 50 "$_td70/cache"; printf '%s ' "$_LOG"
      touch -t 203001010000 "$_td70/conta/SRC"
      combate_log_cache "$_td70/conta" 2 50 "$_td70/cache"; printf '%s' "$_LOG" )
check "painel: log guardado igual ao combate_log; recalcula so com largura ou pagina nova" \
    "igual guardado RECALCULOU RECALCULOU" "$_r"
check "painel: o log de combate passa pelo cache" 1 "`grep -c 'combate_log_cache \"\$acc_dir\"' "$LIB/panel.sh"`"
rm -rf "$_td70"; unset _td70 _r _v70 _menu70 _i70 _p70; unset -f _ant70

# =============================================================================
printf "\n=== 71. esquiva nos eventos de cla: vida baixa, sem elixir, 20%% em 15s ===\n"
# =============================================================================
# Regra do dono (3.9.112), nos cinco eventos de cla. Mesmo roteiro de
# paginas para o codigo ANTIGO (o modulo atual com a esquiva de antes: saia
# com QUALQUER perda de vida desde a leitura anterior) e o NOVO; relogio
# simulado, 1s por pedido, 40s de luta, HP maximo 100000 (limiar da cura
# 48000, dano alto 20000 em 15s). Cada pedido tira DANO de vida, ate o piso.
# Saida: "esquivas=N curas=N primeira=acao".
_td71=`mktemp -d`
_ant71() { # MODULO -> o modulo atual com a esquiva de antes
    sed -e 's/^    dano_registrar "\$_hp"$/    _caiu=0; [ -s DODGE ] \&\& awk -v ush="$_hp" -v oldhp="$_old_hp" '"'"'BEGIN { exit !(ush < oldhp) }'"'"' \&\& _caiu=1/' \
        -e 's/^         esquiva_devida "\$_hp" "[^"]*" "\$_full_hp"; then$/         [ "$_caiu" = 1 ]; then/' \
        "$LIB/$1.sh" > "$_td71/antigo_$1.sh"
}
#   _es71 FUNCAO SECAO ARQUIVO HP_INICIAL DANO PISO CURA(com|sem)
_es71() {
    ( TMP="$_td71/c"; rm -rf "$TMP"; mkdir -p "$TMP"; URL=http://jogo; SLS_PACING=0
      export TMP URL SLS_PACING
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/allies.sh" > /dev/null 2>&1; . "$3" > /dev/null 2>&1
      echo 1000 > "$TMP/t"; : > "$TMP/req"; echo "$4" > "$TMP/hpv"
      for _f in FULL ccol_full; do echo 100000 > "$TMP/$_f"; done
      _S="$2"; _D="$5"; _P="$6"; _C="$7"
      date() { case "$1" in +%s) cat "$TMP/t" ;; *) command date "$@" ;; esac; }
      sleep() { _s=${1%%[!0-9]*}; read -r _t < "$TMP/t"; echo $(( _t + ${_s:-0} )) > "$TMP/t"; }
      _pg71() {
          read -r _h < "$TMP/hpv"
          if [ "$1" -ge 1040 ]; then
              echo "<img src='/images/icon/level.png'/> <a href='/$_S/?close=reward'>Fim</a>"
              return
          fi
          _cl=""; [ "$_C" = com ] && _cl="<a href='/$_S/heal/?r=$1'>h</a>"
          echo "<img src='/images/icon/level.png'/> <img src='/images/icon/race/1.png' alt=''/> Minha <span class='nwr'><img src='/images/icon/health.png' alt='hp'/> $_h</span> <img src='/images/icon/race/0.png' alt=''/> Inimigo <span class='nwr'><img src='/images/icon/health.png' alt='hp'/>&nbsp;8000</span> <a href='/$_S/attack/?r=$1'>a</a> <a href='/$_S/dodge/?r=$1'>d</a> $_cl"; }
      run_curl_exec() {
          read -r _t < "$TMP/t"; echo $(( _t + 1 )) > "$TMP/t"
          read -r _h < "$TMP/hpv"
          case "$1" in
              */heal/*)  echo cura >> "$TMP/req"; _h=90000 ;;
              */dodge/*) echo esquiva >> "$TMP/req" ;;
              *)         [ "$_t" -gt 1000 ] && _h=$(( _h - _D )) ;;
          esac
          [ "$_h" -lt "$_P" ] && _h=$_P
          echo "$_h" > "$TMP/hpv"
          _pg71 "$_t"; }
      for _f in src.html SRC ccol_src ccmd_src; do _pg71 1000 > "$TMP/$_f"; done
      "$1" > /dev/null 2>&1
      printf 'esquivas=%s curas=%s primeira=%s' "`grep -c esquiva "$TMP/req"`" "`grep -c cura "$TMP/req"`" \
          "`sed -n 1p "$TMP/req"`" )
}
for _m71 in "altars altars_fight altars" "clanfight clanfight_fight clanfight" \
            "clandmg clandmgfight_fight clandmgfight" "clancoliseum clancoliseum_fight clancoliseum" \
            "clancommand clancommand_fight clancommand"; do
    set -- $_m71
    _ant71 "$1"
    # Vida baixa (45000), sem elixir, dano pequeno (500 por pedido): o antigo
    # esquivava a toa; o novo so ataca.
    _a=`_es71 "$2" "$3" "$_td71/antigo_$1.sh" 45000 500 1000 sem`; _v=`_es71 "$2" "$3" "$LIB/$1.sh" 45000 500 1000 sem`
    printf "  [INFO] %s vida baixa, dano pequeno: antigo %s | novo %s\n" "$1" "$_a" "$_v"
    case "$_a/$_v" in "esquivas="[1-9]*"/esquivas=0 "*) ok "$1: dano pequeno nao esquiva (antes esquivava)" ;;
                      *) bad "$1: dano pequeno ($_a | $_v)" ;; esac
    # Vida alta (100000 caindo ate 60000, sempre acima de 48%), dano alto:
    # o antigo esquivava; o novo nao (a vida nao esta baixa).
    _a=`_es71 "$2" "$3" "$_td71/antigo_$1.sh" 100000 8000 60000 sem`; _v=`_es71 "$2" "$3" "$LIB/$1.sh" 100000 8000 60000 sem`
    printf "  [INFO] %s vida alta, dano alto: antigo %s | novo %s\n" "$1" "$_a" "$_v"
    case "$_a/$_v" in "esquivas="[1-9]*"/esquivas=0 "*) ok "$1: vida acima de 48% nao esquiva (antes esquivava)" ;;
                      *) bad "$1: vida alta ($_a | $_v)" ;; esac
    # Vida baixa, sem elixir, dano alto (7000 por pedido): o novo esquiva.
    _v=`_es71 "$2" "$3" "$LIB/$1.sh" 47000 7000 5000 sem`
    case "$_v" in "esquivas="[1-9]*) ok "$1: vida baixa, sem elixir e dano alto esquiva ($_v)" ;;
                  *) bad "$1: vida baixa, sem elixir, dano alto ($_v)" ;; esac
    # Vida baixa e dano alto COM elixir: a primeira acao e a cura, nao a esquiva.
    _v=`_es71 "$2" "$3" "$LIB/$1.sh" 47000 7000 5000 com`
    case "$_v" in *" primeira=cura") ok "$1: com elixir, cura antes de esquivar ($_v)" ;;
                  *) bad "$1: com elixir ($_v)" ;; esac
done
set --
# dano_registrar: so a janela de 15s conta.
_r=$( TMP="$_td71"; . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1
      _DANO_HIST=""; date() { cat "$_td71/t0"; }
      echo 100 > "$_td71/t0"; dano_registrar 90000
      echo 105 > "$_td71/t0"; dano_registrar 80000; printf '%s ' "$DANO_15S"
      echo 114 > "$_td71/t0"; dano_registrar 60000; printf '%s ' "$DANO_15S"
      echo 121 > "$_td71/t0"; dano_registrar 55000; printf '%s' "$DANO_15S" )
# (aos 121s as leituras de 100s e 105s ja sairam da janela: so a de 114s)
check "dano_registrar: vida perdida so nos ultimos 15s" "10000 30000 5000" "$_r"
rm -rf "$_td71"; unset _td71 _m71 _a _v _r; unset -f _ant71 _es71

printf "\n=== 72. servidor russo: cadastro, setup e painel ===\n"
_r=`( . "$LIB/contas.sh"; printf '%s %s %s %s [%s][%s]' "$(server_url 1)" "$(server_tag 1)" \
      "$(server_url 2)" "$(server_tag 2)" "$(server_url 3)" "$(server_tag 3)" )`
check "contas: 1 = BR, 2 = RU (tiwar.ru), 3 = nenhum" "furiadetitas.net BR tiwar.ru RU [][]" "$_r"

# setup.sh: a escolha do servidor (ENTER fica no BR).
_td72=`mktemp -d`
sed -n '/^escolher_servidor() {/,/^}/p' "$ROOT/setup.sh" > "$_td72/esc.sh"
_r=""
for _e72 in "" 1 2 " 2 " 9 x; do
    _v=`( . "$LIB/contas.sh"; . "$_td72/esc.sh"; RED=; RESET=; sleep() { :; }
          printf '%s\n' "$_e72" | { escolher_servidor > /dev/null && printf '%s' "$srv" || printf 'recusa'; } )`
    _r="$_r$_v "
done
check "setup: ENTER=1, 1, 2, ' 2 ', 9 e x" "1 1 2 2 recusa recusa " "$_r"
grep -q 'escolher_servidor || return' "$ROOT/setup.sh" && ok "setup: adicionar conta pergunta o servidor" \
    || bad "setup: adicionar conta nao pergunta o servidor"

# Painel: a conta RU aparece na lista, com a pasta RU_.
mkdir -p "$_td72/home/.sls/status" "$_td72/home/.sls/BR_Ze" "$_td72/home/.sls/RU_Ivan"
printf '1|Ze|x\n2|Ivan|x\n3|Fora|x\n' > "$_td72/accounts.conf"
for _a72 in BR_Ze RU_Ivan; do
    echo running > "$_td72/home/.sls/status/$_a72.status"
    echo "$$"    > "$_td72/home/.sls/status/$_a72.pid"
    date +%s     > "$_td72/home/.sls/$_a72/last_ok"
done
printf 'Ze|900|10|5|7|12|3,4K|%s\n' "`date +%s`" > "$_td72/home/.sls/BR_Ze/stats"
printf 'Ivan|11182|1520|5|41|2548|71217|%s\n' "`date +%s`" > "$_td72/home/.sls/RU_Ivan/stats"
( HOME="$_td72/home"; SLSDIR="$ROOT"; STATUS_DIR="$_td72/home/.sls/status"; ACCOUNTS_FILE="$_td72/accounts.conf"
  clean_field() { printf '%s' "$1" | tr -d '\r'; }; worker_vivo() { kill -0 "$1"; }
  PANEL_SUPERVISE=0; PANEL_ONCE=1; PANEL_DRAW=1; SLS_EMOJI=0; SLS_COLS=100
  export HOME SLSDIR STATUS_DIR ACCOUNTS_FILE PANEL_SUPERVISE PANEL_ONCE PANEL_DRAW SLS_EMOJI SLS_COLS
  . "$LIB/panel.sh"; painel_loop ) > "$_td72/saida.txt" 2>/dev/null
_r=`grep -c -E '(Ze|Ivan) ' "$_td72/saida.txt"`; _f=`grep -c 'Fora' "$_td72/saida.txt"`
check "painel: lista a conta BR e a RU, e pula o servidor desconhecido" "2 0" "$_r $_f"
# A sigla antes do nome so na conta russa (pedido do dono); a BR como estava.
_r=`grep -c '\[RU\] Ivan' "$_td72/saida.txt"`; _f=`grep -c -E '\[BR\]|\[RU\] Ze' "$_td72/saida.txt"`
check "painel: '[RU] Ivan' na conta russa, BR sem sigla" "1 0" "$_r $_f"
rm -rf "$_td72"; unset _td72 _e72 _a72 _v _f
printf "\n=== 73. servidor russo: cambio prata -> ouro pelo link certo ===\n"
# Pagina real do cambio russo (tiwar.ru, 26/10/2026, conta nivel 41): os
# botoes silver/N trocam prata por ouro; os gold/N COMPRAM prata com ouro.
_td73=`mktemp -d`
_cambio73() { # PRATA_DA_CONTA -> pagina em $1/SRC
    {
    printf "%s" "<div class='block_zero center blue'>Обмен: <img src='/images/icon/silver.png' alt=''/> Серебро -&#62; <img src='/images/icon/gold.png' alt=''/> Золото<br/></div>"
    printf "%s" "<div class='block_zero center'><span class='small grey'>Доступное золото к обмену: 41 из 41</span></div><div class='menuList'>"
    printf "%s" "<li><a href='/trade/exchange/silver/41?r=71'><img src='/images/icon/arrow.png' alt=''/>Обменять <span class='white'><img src='/images/icon/silver.png' alt=''/>6'724 <span class='blue'>-&#62;</span> <img src='/images/icon/gold.png' alt=''/>41</span></a></li>"
    printf "%s" "<li><a href='/trade/exchange/silver/1?r=72'><img src='/images/icon/arrow.png' alt=''/>Обменять <span class='white'><img src='/images/icon/silver.png' alt=''/>164 <span class='blue'>-&#62;</span> <img src='/images/icon/gold.png' alt=''/>1</span></a></li>"
    printf "%s" "<li><a href='/trade/exchange/silver/10?r=73'><img src='/images/icon/arrow.png' alt=''/>Обменять <span class='white'><img src='/images/icon/silver.png' alt=''/>1'640 <span class='blue'>-&#62;</span> <img src='/images/icon/gold.png' alt=''/>10</span></a></li></div>"
    printf "%s" "<div class='block_zero center blue'>Купить <img src='/images/icon/silver.png' alt=''/> Cеребро</div><div class='menuList'>"
    printf "%s" "<li><a href='/trade/exchange/gold/1?r=74'><img src='/images/icon/arrow.png' alt=''/>Купить <span class='white'><img src='/images/icon/silver.png' alt=''/>410 за <img src='/images/icon/gold.png' alt=''/>1</span></a></li>"
    printf "%s" "<li><a href='/trade/exchange/gold/100?r=75'><img src='/images/icon/arrow.png' alt=''/>Купить <span class='white'><img src='/images/icon/silver.png' alt=''/>41000 за <img src='/images/icon/gold.png' alt=''/>100</span></a></li></div>"
    printf "%s\n" "<div class='center'><img src='/images/icon/level.png' alt='lvl'/> 41 | <img src='/images/icon/gold.png' alt='g'/> 2'548 | <img src='/images/icon/silver.png' alt='s'/> $2</div><script>jsInterface.event(\"user=5;level=41\")</script>"
    } > "$1/SRC"
}
# trade_lote_ru: o maior lote que aguenta FUNC_trade_dias trocas iguais.
_r=""
for _c73 in "71'217 365" "999,9M 365" "6'724 1" "6'723 1" "1'000 365"; do
    set -- $_c73
    _v=`( TMP="$_td73"; . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/trade.sh" > /dev/null 2>&1
          _cambio73 "$TMP" "$1"; trade_lote_ru "$(valor_num "$1")" "$2"; printf '%s=%s' "${_lote:--}" "${_cl:--}" )`
    _r="$_r$_v "
done
check "cambio RU: lote por prata e dias (71217/365, 999,9M/365, 6724/1, 6723/1, 1000/365)" \
    "1=/trade/exchange/silver/1?r=72 41=/trade/exchange/silver/41?r=71 41=/trade/exchange/silver/41?r=71 10=/trade/exchange/silver/10?r=73 -=- " "$_r"

# func_trade inteiro: conta RU troca pelo silver/ e nunca pede o gold/; a
# conta BR, com a pagina do BR, continua no gold/ de sempre.
_tr73() { # TAG PAGINA(ru|br) PRATA
    ( TMP="$_td73/$1"; rm -rf "$TMP"; mkdir -p "$TMP"; export TMP; URL=http://jogo; SLS_TAG="$1"
      . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/trade.sh" > /dev/null 2>&1; FUNC_trade_dias=365
      : > "$TMP/pedidos"
      fetch_page() { echo "$1" >> "$TMP/pedidos"; case "$1" in
          /trade/exchange)
              if [ "$_PG73" = ru ]; then _cambio73 "$TMP" "$_PR73"
              else echo "<img src='/images/icon/gold.png' alt='g'/> 50 <img src='/images/icon/silver.png' alt='s'/> $_PR73 <a href='/trade/exchange/gold/100?r=4'>x</a><a href='/trade/exchange/gold/1?r=5'>y</a><script>jsInterface.event(\"user=5;level=40\")</script>" > "$TMP/SRC"; fi ;;
          *) echo "<script>jsInterface.event(\"user=5;level=40\")</script>" > "$TMP/SRC" ;;
          esac; }
      _PG73="$2"; _PR73="$3"; func_trade > /dev/null 2>&1
      tr '\n' ' ' < "$TMP/pedidos" )
}
check "cambio RU: troca prata -> ouro pelo silver/ (nunca o gold/)" \
    "/trade/exchange /trade/exchange/silver/41?r=71 " "`_tr73 RU ru 999,9M`"
check "cambio RU: prata curta, so olha a pagina" "/trade/exchange " "$(_tr73 RU ru "1'000")"
check "cambio BR: igual a antes (gold/100 com prata alta)" "/trade/exchange /trade/exchange/gold/100?r=4 " "`_tr73 BR br 999,9M`"
check "cambio BR: igual a antes (gold/1 com prata media)" "/trade/exchange /trade/exchange/gold/1?r=5 " "`_tr73 BR br 700000`"

# Trava no HTTP: conta russa nao pede o gold/ nem por engano.
_r=`( . "$LIB/blessing.sh" > /dev/null 2>&1
      for _t in RU BR; do SLS_TAG=$_t
          for _u in https://tiwar.ru/trade/exchange/gold/100?r=1 https://tiwar.ru/trade/exchange/silver/41?r=1 https://x/effshop/blessing/; do
              blessing_url_bloqueada -s "$_u" && printf 'B' || printf '.'
          done; printf ' '
      done )`
check "trava HTTP: RU barra gold/ e bencao, BR so a bencao" "B.B ..B " "$_r"
_r=`( TMP="$_td73"; SLS_TAG=RU; . "$LIB/blessing.sh" > /dev/null 2>&1; _rc_run() { echo PEDIU; }
      run_curl -s "https://tiwar.ru/trade/exchange/gold/1?r=2"; echo "rc=$?"; cut -d'|' -f2 "$TMP/blessing_blocked.log" )`
check "trava HTTP: o pedido nao sai e o log diz o motivo" "rc=1 Cambio ouro->prata" "`echo $_r`"
rm -rf "$_td73"; unset _td73 _c73 _v _r; unset -f _cambio73 _tr73

printf "\n=== 74. servidor russo: cronograma proprio em horario de Moscou ===\n"
# O sls_play com cada funcao que ele chama trocada por um eco do nome, nos
# 1440 minutos do dia. _dia74 TAG -> arquivo com "HH:MM chamadas" por minuto.
_td74=`mktemp -d`
_dia74() {
    ( SLS_TAG="$1"; RUN=-boot; CLD=889; TMP="$_td74"
      for _f74 in clan_id batalha_retomar evento_dedicar evento_espera start clancoliseum_start \
                  clancommand_start clanfight_start king_start undying_start altars_start \
                  flagfight_start descansar specialEvent coliseum_fight tarefas_livres func_sleep \
                  func_crono coliseum_start messages_info sleep; do
          eval "$_f74() { printf ' %s' $_f74; }"
      done
      ativ_marcar() { printf ' marcar:%s' "$1"; }
      . "$LIB/run.sh"
      _h74=0
      while [ "$_h74" -lt 24 ]; do
          _m74=0
          while [ "$_m74" -lt 60 ]; do
              _hh74=`printf '%02d' "$_h74"`; _mm74=`printf '%02d' "$_m74"`
              relogio_sync() { _HH=$_hh74; _MM=$_mm74; _DD=26; }
              _COL_PULSO=""
              printf '%s:%s' "$_hh74" "$_mm74"; sls_play; printf '\n'
              _m74=$((_m74 + 1))
          done
          _h74=$((_h74 + 1))
      done ) > "$_td74/$1.txt" 2>/dev/null
}
_dia74 BR; _dia74 RU
check "cronograma: o dia inteiro tem 1440 minutos nos dois" "1440 1440" \
    "`wc -l < "$_td74/BR.txt" | tr -d ' '` `wc -l < "$_td74/RU.txt" | tr -d ' '`"
# Em 26/10/2026 a tabela russa em MSK e a do BR em horario de Brasilia sao
# iguais minuto a minuto. Se um dia o russo mudar um horario, este teste
# avisa: atualize a tabela russa (cronograma_ru) e o esperado aqui.
cmp -s "$_td74/BR.txt" "$_td74/RU.txt" && ok "cronograma RU (MSK) = cronograma BR (BRT) nos 1440 minutos" \
    || bad "cronograma RU difere do BR: `diff "$_td74/BR.txt" "$_td74/RU.txt" | head -n 3 | tr '\n' ' '`"

# A tabela russa responde pelos horarios dela e so por eles.
_r=`( for _f74 in evento_dedicar evento_espera start clancoliseum_start clancommand_start clanfight_start \
                  king_start undying_start altars_start flagfight_start descansar specialEvent; do
          eval "$_f74() { :; }"
      done
      king_start() { printf 'rei'; }; undying_start() { printf 'vale'; }; altars_start() { printf 'altares'; }
      clanfight_start() { printf 'torneio'; }; clancoliseum_start() { printf 'ccol'; }; flagfight_start() { printf 'band'; }
      ativ_marcar() { :; }; CLD=889; . "$LIB/run.sh"
      for _t74 in 10:25 14:59 10:55 18:59 12:25 16:29 22:25 09:55 15:55 21:59 13:55 20:59 10:10 16:14 10:30 23:59 02:45; do
          cronograma_ru "$_t74" && printf ' ' || printf '%s' '- '
      done )`
check "cronograma_ru: ccol 10:25/14:55, torneio 10:55/18:55, rei 12:25/16:25/22:25, vale 09:55/15:55/21:55, altares 13:55/20:55, bandeiras 10:10/16:10" \
    "ccol ccol torneio torneio rei rei rei vale vale vale altares altares band band - - - " "$_r"
_r=`sed -n '/^sls_play() {/,/^}/p' "$LIB/run.sh" | grep -c 'SLS_TAG:-BR}" = RU ] && cronograma_ru'`
check "sls_play: conta RU passa pela tabela russa antes da do BR" 1 "$_r"
_r=`grep -c 'SLS_TAG:-BR}" != RU ] && ativ_liberada agenda' "$LIB/crono.sh"`
check "agenda do painel (BR): a conta russa nao a sobrescreve" 1 "$_r"
rm -rf "$_td74"; unset _td74 _r; unset -f _dia74

printf "\n=== 75. servidor russo: relogio de Moscou no worker ===\n"
# O trecho do sls.sh que escolhe o fuso, rodado para cada sigla.
_td75=`mktemp -d`
sed -n '/^case "\$SLS_TAG" in$/,/^esac$/p' "$LIB/sls.sh" > "$_td75/tz.sh"
_r=`for _t75 in BR RU ""; do ( SLS_TAG="$_t75"; unset TZ; . "$_td75/tz.sh"; printf '%s ' "$TZ" ); done`
check "fuso: BR e sem sigla em America/Bahia, RU em Europe/Moscow" "America/Bahia Europe/Moscow America/Bahia " "$_r"
# O relogio do worker russo e UTC+3 (o rodape do tiwar.ru, 18:36 com 15:36 UTC).
_r=`( SLS_TAG=RU; . "$_td75/tz.sh"; _u=\`date -u +%s\`; _l=\`date -d "@$_u" +%H 2>/dev/null\`
      [ -n "$_l" ] || { echo sem_date_d; exit 0; }
      _e=$(( ( _u / 3600 + 3 ) % 24 )); [ "${_l#0}" = "$_e" ] && echo 3 || echo "$_l x $_e" )`
case "$_r" in
    3)          ok "fuso: o relogio da conta russa e UTC+3" ;;
    sem_date_d) ok "fuso: date -d indisponivel aqui, nada a medir" ;;
    *)          bad "fuso: o relogio da conta russa nao e UTC+3 ($_r)" ;;
esac
grep -q '^export TZ="America/Bahia"$' "$LIB/sls.sh" && bad "sls.sh: fuso fixo do BR ainda vale para todo servidor" \
    || ok "sls.sh: o fuso vem da sigla do servidor"
rm -rf "$_td75"; unset _td75 _t75 _r

printf "\n=== 76. servidor russo: relogios da campanha e da masmorra ===\n"
# Trechos reais do tiwar.ru (26/10/2026), com as campanhas e os golpes acabados.
_td76=`mktemp -d`
printf '%s\n' "<div class='block_zero center'><img src='/images/icon/2hit.png' alt=''/> Новый поход через: <span id='time_28772000'>7 ч 59 мин</span></div><div class='block_zero center'><a class='btn' href='/campaign/'><span class='end'><span class='label'>Обновить</span></span></a></div><script>jsInterface.event(\"user=5;level=41\")</script>" > "$_td76/camp_fim"
printf '%s\n' "<div class='block_zero center'><img src='/images/icon/2hit.png' alt=''/> Осталось походов: 1</div><a class='btn' href='/campaign/go/?r=9'>go</a>" > "$_td76/camp_resta"
printf '%s\n' "<div class='block_zero center'>Удары закончились<br/><span class='grey medium'>+10 ударов через <span id='time_28765000'>07:59:25</span></span><div class='mb5'></div><a class='btn' href='/clandungeon/buy/?r=9'><span class='end'><span class='label'>Купить 10 ударов за <img src='/images/icon/gold.png' alt=''/>20</span></span></a></div><div class='block_zero center'><span class='grey'>До конца боя: <span id='time_245885000'>2 дня</span></span></div>" > "$_td76/masm_fim"
printf '%s\n' "<a class='btn' href='/clandungeon/attack/?r=9'><span class='end'><span class='label'>Атаковать монстра</span></span></a><div class='mb5'></div>Осталось ударов: <img src='/images/icon/hit.png' alt=''/> 5</div><div class='block_zero center'><span class='grey'>До конца боя: <span id='time_245941000'>2 дня</span></span></div>" > "$_td76/masm_resta"
printf '%s\n' "<img src='/images/icon/2hit.png' alt=''/> Nova campanha em 7 h 59 min<br/>" > "$_td76/camp_br"
printf '%s\n' "<div>Mais golpes em <span id='time_28800000'>08:00:00</span></div>" > "$_td76/masm_br"

_r=`( . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1
      for _t76 in RU BR; do SLS_TAG=$_t76
          printf '%s=[%s][%s][%s] ' "$_t76" "\`campanha_relogio "$_td76/camp_fim"\`" "\`campanha_relogio "$_td76/camp_resta"\`" "\`campanha_relogio "$_td76/camp_br"\`"
      done )`
check "campanha: RU le o time_ (28772 s), sem relogio com campanha restando; BR so a frase dele" \
    "RU=[28772][][] BR=[][][28740] " "$_r"
_r=`( . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/crono.sh" > /dev/null 2>&1
      printf '[%s][%s][%s]' "\`masmorra_relogio "$_td76/masm_fim"\`" "\`masmorra_relogio "$_td76/masm_resta"\`" "\`masmorra_relogio "$_td76/masm_br"\`" )`
check "masmorra: RU '+10 ударов через' (28765 s, nao o fim do monstro), RU com golpe sem relogio, BR igual" \
    "[28765][][28800]" "$_r"
_r=`( . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/clanid.sh" > /dev/null 2>&1
      printf '[%s][%s]' "\`masmorra_golpe "$_td76/masm_resta"\`" "\`masmorra_golpe "$_td76/masm_fim"\`" )`
check "masmorra: golpe pelo attack/; com os golpes acabados o 'comprar' nao vira golpe" "[/clandungeon/attack/?r=9][]" "$_r"
rm -rf "$_td76"; unset _td76 _t76 _r

printf "\n=== 77. setup: menu novo, senha com *, modo de batalha e atualizar ===\n"
_td77=`mktemp -d`
# Funcoes do setup.sh sem o comeco (que acha a pasta pelo $0) e sem o laco
# do menu; o contas.sh e o session_check.sh vem da lib/.
{ printf '. "%s/contas.sh"\n. "%s/session_check.sh"\n' "$LIB" "$LIB"
  sed -n '/^show_menu() {/,/^# Loop principal/p' "$ROOT/setup.sh"; } > "$_td77/setup_fn.sh"
# Sem cor e sem terminal: largura fixa de 40 colunas.
_fn77() { . "$_td77/setup_fn.sh"; clear() { :; }; sleep() { :; }; stty() { echo "24 40"; }
          A1=; A2=; DIM=; WHITE=; GOLD=; RED=; GREEN=; CYAN=; RESET=; SLSDIR="$ROOT"
          SLS_EMOJI=0; carregar_icones; }

# Menu principal: as linhas do modelo do dono, sem o "BR" fixo no titulo.
_r=`( HOME="$_td77/h"; ACCOUNTS_FILE="$_td77/nada"; _fn77; show_menu )`
_n=0
for _l77 in "SLS - Gerenciador de Contas" "1 - Listar Contas" "2 - Adicionar Conta" \
            "3 - Remover Contas" "4 - Testar Login" "5 - Atualizar Repositorio" \
            "6 - Modo de Batalha" "0 - Sair"; do
    printf '%s\n' "$_r" | grep -qF -- "$_l77" && _n=$((_n + 1))
done
check "setup: menu com as 8 linhas do modelo" 8 "$_n"
check "setup: titulo do menu sem o 'BR' fixo" 0 "`printf '%s\n' "$_r" | grep -c 'Contas -'`"
# Pedido do dono: o 5, 6 e 7 seguem logo depois do 4, sem linha em branco.
check "setup: opcoes 1 a 7 em sequencia, sem linha em branco no meio" "4 - Testar Login|5 - Atualizar Repositorio" \
    "`printf '%s\n' "$_r" | grep -A1 '4 - Testar Login' | sed 's/^ *//' | tr '\n' '|' | sed 's/|$//'`"
check "setup: menu le as opcoes 5 e 6" 2 \
    "`grep -c -E '^        (5\) atualizar_menu|6\) modo_menu) ;;$' "$ROOT/setup.sh"`"

# Titulo de tela centralizado: 40 colunas, 15 letras -> 12 espacos antes.
_r=`( _fn77; titulo "Modo de Batalha" | sed -n 2p )`
check "setup: titulo centralizado" "            Modo de Batalha" "$_r"
_r=`( _fn77; printf '0\n' | atualizar_menu; printf '0\n' | modo_menu ) | grep -c -E '^ +(Atualizar Repositorio|Modo de Batalha)$'`
check "setup: submenus Atualizar e Modo de Batalha com titulo centralizado" 2 "$_r"

# Adicionar conta: servidores por extenso.
_r=`( _fn77; show_servers )`
printf '%s\n' "$_r" | grep -qF -- "1 - Servidor Brasileiro" && printf '%s\n' "$_r" | grep -qF -- "2 - Servidor Russo" \
    && ok "setup: servidores 1 - Servidor Brasileiro, 2 - Servidor Russo" \
    || bad "setup: nomes dos servidores ($_r)"

# Senha: um * por tecla, backspace apaga, espaco fica, ENTER encerra.
_bs77=`printf '\177'`
_r=`( _fn77; stty() { [ "$1" = -g ] && echo modo; return 0; }
      printf 'ab%sc d\n' "$_bs77" | { ler_senha > "$_td77/eco"; printf '[%s]' "$pass"; } )`
check "senha: backspace apaga e o espaco fica" "[ac d]" "$_r"
check "senha: aparece um * por tecla e o backspace limpa" "**`printf '\b \b'`***" "`cat "$_td77/eco"`"
# Sem terminal (stty falha): a linha inteira, com os espacos das pontas.
_r=`( _fn77; stty() { return 1; }
      printf '%s\n' ' a\b ' | { ler_senha > /dev/null; printf '[%s]' "$pass"; } )`
check "senha sem terminal: le a linha inteira" '[ a\b ]' "$_r"
_r=`sed -n '/^add_account() {/,/^}/p' "$ROOT/setup.sh"`
printf '%s\n' "$_r" | grep -q '^    ler_senha "Senha: "$' && ! printf '%s\n' "$_r" | grep -q 'IFS= read -r pass' \
    && ok "setup: adicionar conta le a senha com *" || bad "setup: adicionar conta sem o ler_senha"

# Testar login: mostra o nome com que o jogo recebeu a conta.
_r=`( _fn77; _page="<div><a href='/user/123'>Ana</a></div>"; mostra_logado )`
check "setup: login mostra o nome que o jogo devolveu" "Logado no jogo como: Ana" "$_r"
check "setup: adicionar e testar mostram o nome logado" 2 "`grep -c '^ *mostra_logado$' "$ROOT/setup.sh"`"

# play.sh: cada conta sobe no modo salvo; o modo da linha de comando vence.
_lw77() { # $1=conteudo do modo_batalha (vazio = sem arquivo)  $2=RUN  $3=RUN_FLAG
    ( _h="$_td77/lw"; rm -rf "$_h"; mkdir -p "$_h/.sls/BR_Ana" "$_h/.sls/status"
      [ -n "$1" ] && printf '%s\n' "$1" > "$_h/.sls/BR_Ana/modo_batalha"
      echo cred > "$_h/.sls/BR_Ana/cript_file"
      HOME="$_h"; SLSDIR="$ROOT"; LIBDIR="$LIB"; STATUS_DIR="$_h/.sls/status"
      RUN="$2"; RUN_FLAG="$3"; FORCE_RESTART=0; SETSID=""
      . "$LIB/contas.sh"
      eval "`sed -n '/^launch_worker() {/,/^}/p' "$ROOT/play.sh"`"
      nohup() { for _a; do _u="$_a"; done; printf '%s' "$_u" > "$_h/modo"; }
      launch_worker 1 Ana > /dev/null 2>&1; wait; cat "$_h/modo" )
}
check "play.sh: conta sem modo salvo sobe no normal"      "-boot" "`_lw77 '' -boot 0`"
check "play.sh: conta em Caverna sobe com -cv"            "-cv"   "`_lw77 -cv -boot 0`"
check "play.sh: conta em Coliseu sobe com -cl"            "-cl"   "`_lw77 -cl -boot 0`"
check "play.sh: ./play.sh -cl vence o modo salvo"         "-cl"   "`_lw77 -cv -cl 1`"
check "play.sh: arquivo de modo estranho e ignorado"      "-boot" "`_lw77 'rm -rf' -boot 0`"
grep -q '^if \[ -n "\$RUN" \]; then RUN_FLAG=1; else RUN_FLAG=0; fi$' "$ROOT/play.sh" \
    && ok "play.sh: marca quando o modo veio da linha de comando" || bad "play.sh: sem RUN_FLAG"

# Modo de batalha: escolher contas (varios numeros) ou definir para todas.
# $1 = entrada digitada no menu do modo  $2 = modo  -> modo de cada conta
_md77() {
    ( _h="$_td77/md"; rm -rf "$_h"; mkdir -p "$_h/.sls/status" "$_h/.sls/BR_Ana"
      echo -cl > "$_h/.sls/BR_Ana/modo_batalha"
      printf '# srv|usuario|cred\n1|Ana|YQ==\n1|Bia|Yg==\n2|Ivan|aQ==\n' > "$_h/acc.conf"
      HOME="$_h"; ACCOUNTS_FILE="$_h/acc.conf"; _fn77; bot_no_ar() { return 1; }
      printf "$1" | aplicar_modo "$2" > /dev/null 2>&1
      for _a in BR_Ana BR_Bia RU_Ivan; do
          printf '%s=%s ' "$_a" "`modo_nome "\`modo_da_conta "$_h/.sls/$_a"\`"`"
      done )
}
check "modo: Caverna nas contas 1 e 3"            "BR_Ana=Caverna BR_Bia=Normal RU_Ivan=Caverna " "`_md77 '1\n1 3\n\n' -cv`"
check "modo: numeros com virgula e repetidos"     "BR_Ana=Caverna BR_Bia=Caverna RU_Ivan=Normal " "`_md77 '1\n2,1,2\n\n' -cv`"
check "modo: Coliseu definido para todas"         "BR_Ana=Coliseu BR_Bia=Coliseu RU_Ivan=Coliseu " "`_md77 '2\n\n' -cl`"
check "modo: Normal para todas apaga os arquivos" "BR_Ana=Normal BR_Bia=Normal RU_Ivan=Normal " "`_md77 '2\n\n' ''`"
check "modo: numero que nao existe nao muda nada" "BR_Ana=Coliseu BR_Bia=Normal RU_Ivan=Normal " "`_md77 '1\n1 9\n0\n' -cv`"
check "modo: 0 cancela"                           "BR_Ana=Coliseu BR_Bia=Normal RU_Ivan=Normal " "`_md77 '1\n0\n0\n' -cv`"
check "modo: Voltar no submenu nao muda nada"     "BR_Ana=Coliseu BR_Bia=Normal RU_Ivan=Normal " "`_md77 '0\n' -cv`"
_r=`( _h="$_td77/ls"; mkdir -p "$_h/.sls/BR_Ana"; echo -cv > "$_h/.sls/BR_Ana/modo_batalha"
      printf '1|Ana|YQ==\n1|Bia|Yg==\n' > "$_h/acc.conf"
      HOME="$_h"; ACCOUNTS_FILE="$_h/acc.conf"; _fn77
      printf '\n' | list_accounts | grep -c -E 'Ana .*\(Caverna\)|Bia .*\(' )`
check "lista: mostra o modo so da conta fora do normal" 1 "$_r"
check "remover conta apaga o modo de batalha dela" 1 \
    "`sed -n '/^remove_account() {/,/^}/p' "$ROOT/setup.sh" | grep -c 'modo_batalha'`"

# Com o painel no ar, o "y" derruba so os workers das contas escolhidas; o
# .pid fica para o painel relancar no modo novo, sem a espera de quem cai
# seguido.
if [ -r "/proc/$$/cmdline" ]; then
    _h77="$_td77/rs"; mkdir -p "$_h77/.sls/status" "$_h77/.sls/BR_Ana" "$_h77/.sls/BR_Bia"
    printf '1|Ana|YQ==\n1|Bia|Yg==\n' > "$_h77/acc.conf"
    sh -c 'sleep 30; :' "$_td77/lib/sls.sh" -boot "$_h77/.sls/BR_Ana" & _p77a=$!
    sh -c 'sleep 30; :' "$_td77/lib/sls.sh" -boot "$_h77/.sls/BR_Bia" & _p77b=$!
    sleep 1
    echo $_p77a > "$_h77/.sls/status/BR_Ana.pid"; echo $_p77b > "$_h77/.sls/status/BR_Bia.pid"
    echo 3 > "$_h77/.sls/BR_Ana/.relancado_n"; date +%s > "$_h77/.sls/BR_Ana/.relancado"
    ( HOME="$_h77"; ACCOUNTS_FILE="$_h77/acc.conf"; _fn77; bot_no_ar() { return 0; }
      printf '1\n1\ny\n\n' | aplicar_modo -cv ) > /dev/null 2>&1
    sleep 1
    _r=""
    for _p in $_p77a $_p77b; do
        case "`cut -d' ' -f3 /proc/$_p/stat 2>/dev/null`" in ''|Z) _r="$_r morto" ;; *) _r="$_r vivo" ;; esac
    done
    [ -f "$_h77/.sls/status/BR_Ana.pid" ] && _r="$_r pid" || _r="$_r sem_pid"
    [ -f "$_h77/.sls/BR_Ana/.relancado_n" ] && _r="$_r espera" || _r="$_r sem_espera"
    kill $_p77a $_p77b 2>/dev/null; wait $_p77a $_p77b 2>/dev/null
    check "modo: reiniciar derruba so a conta escolhida e o painel a relanca" " morto vivo pid sem_espera" "$_r"
    unset _h77 _p77a _p77b _p
fi

# Atualizar: sem novidade nao para o bot; com novidade para, puxa e sobe.
if command -v git > /dev/null 2>&1; then
    _g77="$_td77/git"; mkdir -p "$_g77"
    ( cd "$_g77" && git init -q --bare origem.git && git clone -q origem.git trab
      cd trab && git config user.email t@t && git config user.name t
      printf 'echo PAROU >> "%s/log"\n' "$_g77" > stop.sh
      printf 'echo SUBIU >> "%s/log"\n' "$_g77" > play.sh
      git add . && git commit -qm um && git push -q origin HEAD
      git clone -q "$_g77/origem.git" "$_g77/bot" ) > /dev/null 2>&1
    _gp77() {
        ( HOME="$_g77/h"; _fn77; SLSDIR="$_g77/bot"; git_pull_setup ) > /dev/null 2>&1 < /dev/null
        tr '\n' ' ' < "$_g77/log" 2>/dev/null; rm -f "$_g77/log"
    }
    check "atualizar: sem nada novo, o bot nao para" "" "`_gp77`"
    ( cd "$_g77/trab" && echo novo > novo.txt && git add novo.txt && git commit -qm dois \
      && git push -q origin HEAD ) > /dev/null 2>&1
    check "atualizar: para o bot, puxa e sobe de novo" "PAROU SUBIU " "`_gp77`"
    [ -f "$_g77/bot/novo.txt" ] && ok "atualizar: o git pull trouxe o arquivo novo" \
        || bad "atualizar: o arquivo novo nao chegou"
    unset _g77
fi

# Emoji: a mesma regra do painel (so no modo 1), sem exagero.
# $1 = SLS_EMOJI  $2 = conteudo de ~/.sls/emoji (vazio = sem arquivo)  $3 = PREFIX
_em77() {
    _h="$_td77/em"; rm -rf "$_h"; mkdir -p "$_h/.sls"
    [ -n "$2" ] && echo "$2" > "$_h/.sls/emoji"
    _s=`( HOME="$_h"; SLS_EMOJI="$1"; PREFIX="$3"; . "$_td77/setup_fn.sh"; setup_emoji && echo 1 || echo 0 )`
    _p=`( HOME="$_h"; SLS_EMOJI="$1"; PREFIX="$3"; export HOME SLS_EMOJI PREFIX
          . "$LIB/panel.sh" > /dev/null 2>&1; [ "$SLS_EMOJI" = 1 ] && echo 1 || echo 0 )`
    printf '%s%s ' "$_s" "$_p"
}
_r=""
for _e in "||" "0||" "1||" "2||" "|1|" "|2|" "||/data/data/com.termux/files/usr" \
          "|1|/data/data/com.termux/files/usr" "1|2|/data/data/com.termux/files/usr" "|talvez|"; do
    _a=${_e%%|*}; _b=${_e#*|}; _b=${_b%%|*}; _c=${_e##*|}
    _r="$_r`_em77 "$_a" "$_b" "$_c"`"
done
check "emoji: setup e painel decidem igual (o painel e a regra)" \
    "11 00 11 00 11 00 00 11 11 11 " "$_r"

_r=`( _fn77; SLS_EMOJI=1; carregar_icones; HOME="$_td77/h"; ACCOUNTS_FILE="$_td77/nada"; show_menu )`
printf '%s\n' "$_r" | grep -qF -- "🔱 SLS - Gerenciador de Contas" \
    && ok "emoji: titulo do menu com 🔱" || bad "emoji: titulo do menu sem 🔱"
_r=`( _fn77; SLS_EMOJI=2; carregar_icones; HOME="$_td77/h"; ACCOUNTS_FILE="$_td77/nada"; show_menu; titulo "Testar Login" "🎯" ) | LC_ALL=C tr -dc '\360-\367' | wc -c | tr -d ' '`
check "emoji: no modo de simbolos o setup nao mostra emoji" 0 "$_r"
# 40 colunas, "Modo de Batalha" (15) + emoji e espaco (3) -> 11 espacos antes.
_r=`( _fn77; SLS_EMOJI=1; carregar_icones; titulo "Modo de Batalha" "🎮" | sed -n 2p )`
check "emoji: titulo com emoji continua centralizado" "           🎮 Modo de Batalha" "$_r"
_r=`( _fn77; SLS_EMOJI=1; carregar_icones; printf '%s %s|' "$T_OK" "$T_FALHA"
      SLS_EMOJI=0; carregar_icones; printf '%s %s' "$T_OK" "$T_FALHA" )`
check "emoji: ✅/❌ com emoji, [OK]/[FALHOU] sem" "✅ ❌|[OK] [FALHOU]" "$_r"
# Nenhum emoji com seletor de variacao (U+FE0F, bytes EF B8 8F): o terminal
# que o ignora desenha caixa.
_fe0f=`printf '\357\270\217'`
check "emoji: setup.sh e panel.sh sem seletor de variacao" "0 0" \
    "`grep -c "$_fe0f" "$ROOT/setup.sh"` `grep -c "$_fe0f" "$LIB/panel.sh"`"
# Painel: 🔱 no titulo so no modo 1.
_r=""
for _m in 0 1 2; do
    _r="$_r`( HOME="$_td77/h"; SLS_EMOJI=$_m; export HOME SLS_EMOJI
              . "$LIB/panel.sh" > /dev/null 2>&1; printf '[%s%s]' "$I_TITULO" "$TITULO_W" )`"
done
check "painel: 🔱 no titulo so no modo emoji" "[0][🔱 3][0]" "$_r"
unset _em77 _e _a _b _c _fe0f _m _h _s _p

# Primeira abertura no Termux: pergunta uma vez se aparecem os emoji.
# $1 = resposta  $2 = PREFIX  $3 = conteudo previo de ~/.sls/emoji  $4 = terminal (1/0)
# $5 = SLS_EMOJI  -> "perguntou?:arquivo"
_ep77() {
    _h="$_td77/ep"; rm -rf "$_h"; mkdir -p "$_h"
    [ -n "$3" ] && { mkdir -p "$_h/.sls"; echo "$3" > "$_h/.sls/emoji"; }
    _t="$4"
    _o=`( HOME="$_h"; PREFIX="$2"; SLS_EMOJI="$5"; . "$LIB/contas.sh"
          tem_terminal() { [ "$_t" = 1 ]; }; sleep() { :; }
          printf '%s\n' "$1" | emoji_perguntar )`
    case "$_o" in *"Teste de emoji"*) _o=sim ;; *) _o=nao ;; esac
    printf '%s:%s' "$_o" "`cat "$_h/.sls/emoji" 2>/dev/null`"
}
_tx77=/data/data/com.termux/files/usr
check "emoji: Termux sem escolha, 's' liga o emoji"        "sim:1"   "`_ep77 s "$_tx77" '' 1 ''`"
check "emoji: Termux sem escolha, 'n' fica nos simbolos"   "sim:2"   "`_ep77 n "$_tx77" '' 1 ''`"
check "emoji: ENTER sem resposta fica nos simbolos"        "sim:2"   "`_ep77 '' "$_tx77" '' 1 ''`"
check "emoji: escolha ja gravada, nao pergunta de novo"    "nao:1"   "`_ep77 n "$_tx77" 1 1 ''`"
check "emoji: arquivo com lixo, pergunta de novo"          "sim:1"   "`_ep77 s "$_tx77" talvez 1 ''`"
check "emoji: sem terminal (Termux:Boot) nao pergunta"     "nao:"    "`_ep77 s "$_tx77" '' 0 ''`"
check "emoji: SLS_EMOJI no comando, nao pergunta"          "nao:"    "`_ep77 s "$_tx77" '' 1 2`"
_r=`( PREFIX=; . "$LIB/contas.sh"; command -v getprop > /dev/null 2>&1 && echo pula || _ep77 s '' '' 1 '' )`
case "$_r" in pula) ok "emoji: fora do Android nao pergunta (aqui tem getprop, pulado)" ;;
    *) check "emoji: fora do Android nao pergunta" "nao:" "$_r" ;; esac
# Depois da resposta, setup e painel seguem a escolha gravada.
_h="$_td77/ep2"; mkdir -p "$_h/.sls"; echo 1 > "$_h/.sls/emoji"
_r=`( HOME="$_h"; PREFIX="$_tx77"; SLS_EMOJI=; . "$_td77/setup_fn.sh"; setup_emoji && echo 1 || echo 0 )``( HOME="$_h"; PREFIX="$_tx77"; SLS_EMOJI=; export HOME PREFIX SLS_EMOJI; . "$LIB/panel.sh" > /dev/null 2>&1; echo "$SLS_EMOJI" )`
check "emoji: com 's' gravado no Termux, setup e painel usam emoji" "11" "$_r"
# O setup e o play.sh perguntam antes de carregar os icones e o painel.
_r=`sed -n '/^emoji_perguntar$/=;/^carregar_icones$/=' "$ROOT/setup.sh" | tr '\n' ' '`
case "$_r" in [0-9]*" "[0-9]*" ") set -- $_r; [ "$1" -lt "$2" ] && _r=ok ;; esac
check "setup: pergunta do emoji antes de carregar os icones" ok "$_r"
_a=`grep -n '^emoji_perguntar$' "$ROOT/play.sh" | cut -d: -f1`; _b=`grep -n '^\. "\$LIBDIR/panel.sh"$' "$ROOT/play.sh" | cut -d: -f1`
[ -n "$_a" ] && [ -n "$_b" ] && [ "$_a" -lt "$_b" ] && ok "play.sh: pergunta do emoji antes do painel" \
    || bad "play.sh: pergunta do emoji fora do lugar ($_a $_b)"
unset _ep77 _tx77 _h _o _a _b _t

rm -rf "$_td77"; unset _td77 _r _n _l77 _bs77

printf "\n=== 78. aliados por ID: jogadores, clas aliados e o menu do setup ===\n"
# Regra do dono (29/10): aliado = membro do cla da conta + jogador da lista
# (ID) + membro de cla da lista (ID). Lista por servidor, comum as contas.
# Marcacao real do perfil (/user/ID/, 29/10): <title> com o nome do DONO do
# perfil, links "/user/ID?show=" do proprio ID e o cla em "/clan/ID'>".
# ID que nao existe mostra o perfil da conta logada (links com o ID dela).
_td78=`mktemp -d`
_perfil78() { # ID NOME -> pagina de perfil logada
    printf '%s' "<title>$2</title><img src='/images/icon/race/1.png' alt=''/> <b>$2</b> <img src='/images/icon/level.png' alt=''/> 91 nível<a href='/clan/2092'>Abyssal Millennium</a><a href='/user/$1?show=might'>Poder:</a><img src='/user/$1/?show=avatar&h=x'/><a href='/user/$1/?show=faith'>fe</a>"
}
_perfil78 3386065 "Abyssal Draco" > "$_td78/p_draco"
# ID que nao existe: o jogo devolve o perfil da conta logada (473431).
_perfil78 473431 "Grimlock" > "$_td78/p_proprio"
# Sessao caida: pagina de visitante.
printf '%s' "<title>Error 404: Page not found</title>" > "$_td78/p_visitante"
printf '%s' "<a href='/user/71/'><img src='/images/icon/race/1.png' alt=''/>Aliado Um, <span class='white'>Soldado</span><br/><a href='/user/72/'><img src='/images/icon/race/0.png' alt=''/>Aliado Dois, <span class='white'>General</span>" > "$_td78/c_777"
printf '%s' "<a href='/user/81/'><img src='/images/icon/race/1.png' alt=''/>Meu Chefe, <span class='white'><span class='green'>Clã líder</span></span>" > "$_td78/c_999"

# Ambiente de uma conta: $1 = pasta da conta, $2 = "pedidos" de saida.
_conta78() {
    TMP="$_td78/$1"; URL="http://jogo"; CLD=999; HOME="$_td78/home"; SLS_TAG=BR
    export TMP URL CLD HOME SLS_TAG; mkdir -p "$TMP" "$HOME/.sls"
    SLS_PACING=0; . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/allies.sh" > /dev/null 2>&1
    sleep() { :; }
    run_curl_exec() { echo "$1" >> "$_td78/pedidos"; case "$1" in
        */user/3386065/)  cat "$_td78/p_draco" ;;
        */user/99999999/) cat "$_td78/p_proprio" ;;
        */user/5555/)     cat "$_td78/p_visitante" ;;
        */clan/777)       cat "$_td78/c_777" ;;
        */clan/999)       cat "$_td78/c_999" ;;
        *) : ;; esac; }
    time_exit() { wait "$!" 2>/dev/null; }
}

# Nome pelo perfil; ID que nao existe; sessao caida nao e "nao existe".
_r=`( _conta78 a; printf '[%s]' "\`_aliado_jogador 3386065\`"; printf '[%s]' "\`_aliado_jogador 99999999\`"
      _aliado_jogador 5555 > /dev/null && printf '[viva]' || printf '[caiu]' )`
check "perfil: nome do dono do perfil, ID inexistente vazio, sessao caida falha" "[Abyssal Draco][][caiu]" "$_r"

# Lista do servidor: jogador valido, jogador inexistente e cla aliado.
printf 'j|3386065\nj|99999999\nc|777\n' > "$_td78/home/.sls/aliados_BR.conf"
: > "$_td78/pedidos"
_r=`( _conta78 a; aliados_montar 1 > /dev/null 2>&1; tr '\n' ' ' < "$TMP/allies.txt" )`
check "aliados: cla da conta + jogador da lista + membros do cla aliado" \
    "Abyssal_Draco Aliado_Dois Aliado_Um Meu_Chefe " "$_r"
check "aliados: ID inexistente anotado como nao encontrado" "j|99999999|-" \
    "`grep '^j|99999999|' "$_td78/home/.sls/aliados_BR.nomes"`"
# Segunda conta do mesmo servidor: usa os nomes ja buscados, sem pedir os perfis.
: > "$_td78/pedidos"
_r=`( _conta78 b; aliados_montar 1 > /dev/null 2>&1; tr '\n' ' ' < "$TMP/allies.txt" )`
check "aliados: a outra conta reusa os nomes (so pede o proprio cla)" \
    "Abyssal_Draco Aliado_Dois Aliado_Um Meu_Chefe |0" "$_r|`grep -c -E '/user/|/clan/777' "$_td78/pedidos"`"
# O setup tirou o jogador da lista: sai na hora, mesmo com os nomes guardados.
printf 'j|99999999\nc|777\n' > "$_td78/home/.sls/aliados_BR.conf"
_r=`( _conta78 c; aliados_montar 1 > /dev/null 2>&1; tr '\n' ' ' < "$TMP/allies.txt" )`
check "aliados: jogador tirado da lista deixa de ser aliado" "Aliado_Dois Aliado_Um Meu_Chefe " "$_r"
# Lista mudou depois da ultima busca (.conf mais novo): busca de novo.
sleep 1; printf 'j|3386065\n' > "$_td78/home/.sls/aliados_BR.conf"; : > "$_td78/pedidos"
_r=`( _conta78 d; aliados_montar 1 > /dev/null 2>&1; grep -c '/user/3386065/' "$_td78/pedidos" )`
check "aliados: lista mudou no setup, o perfil e buscado de novo" 1 "$_r"
# Quem sai do cla aliado deixa de ser aliado na volta seguinte.
printf '%s' "<a href='/user/71/'><img src='/images/icon/race/1.png' alt=''/>Aliado Um, <span class='white'>Soldado</span>" > "$_td78/c_777"
printf 'c|777\n' > "$_td78/home/.sls/aliados_BR.conf"
_r=`( _conta78 e; aliados_montar 1 > /dev/null 2>&1; tr '\n' ' ' < "$TMP/allies.txt" )`
check "aliados: quem saiu do cla aliado vira inimigo" "Aliado_Um Meu_Chefe " "$_r"
# Servidor russo usa a lista dele.
printf 'j|3386065\n' > "$_td78/home/.sls/aliados_BR.conf"; : > "$_td78/home/.sls/aliados_RU.conf"
_r=`( _conta78 f; SLS_TAG=RU; aliados_montar 1 > /dev/null 2>&1; tr '\n' ' ' < "$TMP/allies.txt" )`
check "aliados: conta RU nao usa a lista do BR" "Meu_Chefe " "$_r"
# Ao subir a conta o play.sh apaga a marca: a lista e refeita na hora.
check "play.sh: ao subir a conta, refaz os aliados" 1 \
    "`sed -n '/^launch_worker() {/,/^}/p' "$ROOT/play.sh" | grep -c 'rm -f "\$lw_dir/last_aliados3"'`"
check "crono: chave nova aliados3 (quem atualizar refaz a lista ja)" "1 0" \
    "`grep -c 'ativ_liberada aliados3 720' "$LIB/crono.sh"` `grep -c 'aliados2' "$LIB/crono.sh"`"

# ---- setup: 7 - Adicionar Aliados
{ printf '. "%s/contas.sh"\n. "%s/session_check.sh"\n' "$LIB" "$LIB"
  sed -n '/^show_menu() {/,/^# Loop principal/p' "$ROOT/setup.sh"; } > "$_td78/setup_fn.sh"
_fn78() { HOME="$_td78/sh"; mkdir -p "$HOME/.sls"; . "$_td78/setup_fn.sh"
          clear() { :; }; sleep() { :; }; stty() { echo "24 40"; }
          A1=; A2=; DIM=; WHITE=; GOLD=; RED=; GREEN=; CYAN=; RESET=; SLSDIR="$ROOT"
          SLS_EMOJI=0; carregar_icones; }
_r=`( _fn78; ACCOUNTS_FILE="$_td78/nada"; show_menu ) | grep -c '7 - Adicionar Aliados'`
check "setup: menu com 7 - Adicionar Aliados" 1 "$_r"
_r=`( _fn78; printf '\n' | aliados_listar ) 2>&1 | grep -c -i 'cannot open\|No such'`
check "setup: listar sem lista nenhuma nao mostra erro de arquivo" 0 "$_r"
_r=""
for _e78 in "473431" " 473431 " "https://furiadetitas.net/user/473431/" "https://furiadetitas.net/user/473431?show=might" \
            "47a" "" "0123" "https://furiadetitas.net/clan/2092"; do
    _r="$_r`( _fn78; aliado_ler_id j "$_e78" > /dev/null && printf '%s' "$_id" || printf 'x' )` "
done
check "setup: ID de jogador pelo numero ou pelo link; o resto recusa" \
    "473431 473431 473431 473431 x x x x " "$_r"
_r=`( _fn78; aliado_ler_id c "https://furiadetitas.net/clan/2092" > /dev/null && printf '%s ' "$_id"
      aliado_ler_id c "https://furiadetitas.net/user/1/" > /dev/null || printf 'recusa' )`
check "setup: ID de cla pelo link; link de jogador na opcao de cla recusa" "2092 recusa" "$_r"

# Adicionar: grava na lista do servidor e avisa so as contas dele.
mkdir -p "$_td78/sh/.sls/BR_Ana" "$_td78/sh/.sls/RU_Ivan"
date +%s > "$_td78/sh/.sls/BR_Ana/last_aliados3"; date +%s > "$_td78/sh/.sls/RU_Ivan/last_aliados3"
( _fn78; printf '1\n473431\n\n' | aliado_adicionar j; printf '\nhttps://x/clan/2092\n\n' | aliado_adicionar c
  printf '1\n473431\n' | aliado_adicionar j ) > /dev/null 2>&1
check "setup: adicionar grava j|ID e c|ID, sem repetir" "j|473431 c|2092 " \
    "`tr '\n' ' ' < "$_td78/sh/.sls/aliados_BR.conf"`"
_r=""; [ -f "$_td78/sh/.sls/BR_Ana/last_aliados3" ] && _r="BR_marca" || _r="BR_refaz"
[ -f "$_td78/sh/.sls/RU_Ivan/last_aliados3" ] && _r="$_r RU_marca" || _r="$_r RU_refaz"
check "setup: lista do BR mudou, so as contas BR refazem" "BR_refaz RU_marca" "$_r"

# Listar: o nome que o bot achou, ID nao encontrado e quem ainda espera.
printf 'j|473431\nc|2092\nj|99999999\nj|5\n' > "$_td78/sh/.sls/aliados_BR.conf"
printf 'j|473431|Grimlock\nc|2092|Abyssal Draco\nc|2092|Outro\nj|99999999|-\n' > "$_td78/sh/.sls/aliados_BR.nomes"
_r=`( _fn78; aliados_linhas BR ) | sed 's/  */ /g' | tr '\n' ';'`
check "setup: lista com nome, membros, nao encontrado e aguardando" \
    "1) Jogador 473431 Grimlock;2) Cla 2092 2 membro(s);3) Jogador 99999999 ID nao encontrado;4) Jogador 5 aguardando o bot;" "$_r"
# Remover o numero 2 (o cla).
( _fn78; printf '1\n2\ny\n' | aliado_remover ) > /dev/null 2>&1
check "setup: remover tira so a linha escolhida" "j|473431 j|99999999 j|5 " \
    "`tr '\n' ' ' < "$_td78/sh/.sls/aliados_BR.conf"`"
rm -rf "$_td78"; unset _td78 _r _e78; unset -f _perfil78 _conta78 _fn78

printf "\n=== RESUMO ===\n"
printf "  PASS=%s  FALHA=%s\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
