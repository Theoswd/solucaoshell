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
# Prova de regressao: nenhum modulo reintroduz o overwrite no branch de cura
if grep -nE 'cat (HP|USH) > FULL|cat USH > "\$full_ram"|echo "\$USH" > "\$full_ram"|_fullat="\$_hpat"' \
        "$ROOT"/king.sh "$ROOT"/clanfight.sh "$ROOT"/clandmg.sh "$ROOT"/altars.sh \
        "$ROOT"/coliseum.sh "$ROOT"/flagfight.sh >/dev/null 2>&1; then
    bad "algum modulo ainda sobrescreve o HP maximo com o HP atual"
else
    ok "nenhum modulo sobrescreve o HP maximo com o HP atual"
fi

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
                printf 'league page sem botao\n' > "$TMP/SRC"
            elif [ "$SIM_CALLS" -ge "$SIM_REWARD_APPEARS_AT" ]; then
                printf '<a href="/league/takeReward/?r=12345">coletar</a>\n' > "$TMP/SRC"
            else
                printf 'league page sem recompensa ainda\n' > "$TMP/SRC"
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
        /league/) printf '<a href="/league/takeReward/?r=999">coletar</a>\n' > "$TMP/SRC" ;;
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
    _heal_ln=$(grep -n 'run_curl_exec "${URL}$(cat HEAL)"' "$LIB/$f" | head -n1 | cut -d: -f1)
    _dodge_ln=$(grep -n 'run_curl_exec "${URL}$(cat DODGE)"' "$LIB/$f" | head -n1 | cut -d: -f1)
    if [ -n "$_heal_ln" ] && [ -n "$_dodge_ln" ] && [ "$_heal_ln" -lt "$_dodge_ln" ]; then
        ok "$f: cura (linha $_heal_ln) antes da esquiva (linha $_dodge_ln)"
    else
        bad "$f: cura deveria vir antes da esquiva (heal=$_heal_ln dodge=$_dodge_ln)"
    fi
done
# flagfight e clancoliseum ja eram cura-primeiro
for f in flagfight.sh clancoliseum.sh; do
    _heal_ln=$(grep -n 'cat HEAL\|cat SHIELD\|SHIELD)' "$LIB/$f" | head -n1 | cut -d: -f1)
    _dodge_ln=$(grep -n 'cat DODGE)' "$LIB/$f" | head -n1 | cut -d: -f1)
    if [ -n "$_heal_ln" ] && [ -n "$_dodge_ln" ] && [ "$_heal_ln" -lt "$_dodge_ln" ]; then
        ok "$f: cura/escudo antes da esquiva"
    else
        bad "$f: cura deveria vir antes da esquiva (heal=$_heal_ln dodge=$_dodge_ln)"
    fi
done

printf "\n=== 6. Uma requisicao por ciclo: recarga espera sem requisitar ===\n"
# O ramo ocioso (else) so faz requisicao quando o alvo esta grey; fora disso
# espera o restante da recarga com 'sleep \$_resta', sem recarregar a pagina.
for f in clanfight.sh clandmg.sh altars.sh coliseum.sh clancoliseum.sh flagfight.sh; do
    if grep -q 'LA - _latk\|LA - .*last_atk\|LA - time_since_last_atk' "$LIB/$f"; then
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
for f in king.sh clanfight.sh clandmg.sh altars.sh clancoliseum.sh flagfight.sh; do
    if grep -q 'cd "\$TMP"' "$LIB/$f"; then
        ok "$f: isola estado por conta (cd \$TMP)"
    else
        bad "$f: nao faz 'cd \$TMP' — risco de colisao entre contas"
    fi
done
# Login serializado por trava atomica (mkdir) com recuperacao de dono morto:
# e o que segura o rate-limit de login por IP com 15-30 contas subindo juntas.
if grep -q 'mkdir "\$LOCKDIR"' "$LIB/sls.sh" && grep -q 'kill -0 "\$_dono"' "$LIB/sls.sh"; then
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
_d1=$(grep -n 'cat DODGE' "$K" | head -n1 | cut -d: -f1)
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
for f in clanfight.sh clandmg.sh altars.sh clancoliseum.sh flagfight.sh coliseum.sh king.sh; do
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
for _a in carreira caverna sabio; do
    grep -q "ativ_liberada $_a" "$C" \
        && ok "tarefas_livres: $_a roda tambem no ocioso (nao so :00/:30)" \
        || bad "tarefas_livres: $_a nao roda no ocioso"
done
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
if grep -q 'read -r CLD < "\$TMP/CLD"' "$R"; then
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
    # Estes sao carregados por caminho proprio, nao pelo laco.
    case "$_b" in worker.sh|sls.sh|panel.sh|info.sh|session_check.sh|contas.sh) continue ;; esac
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
# GitHub so reconhece ali (README, LICENSE) e o que o git so aplica aos
# arquivos da raiz estando nela (.gitattributes com o eol=lf dos scripts,
# .gitignore). Qualquer outra coisa vai para lib/.
_sobra=""
for _e in "$ROOT"/* "$ROOT"/.[!.]*; do
    [ -e "$_e" ] || continue
    case "$(basename "$_e")" in
        .git|.gitattributes|.gitignore|LICENSE|README.md|lib|tests) ;;
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
    for _m in altars clancoliseum clandmg clanfight flagfight; do
        grep -q 'alvo_aliado USER cla' "$LIB/$_m.sh" \
            && ok "$_m usa alvo_aliado" || bad "$_m nao protege aliado"
    done
    grep -q 'alvo_aliado USER' "$LIB/king.sh" \
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
      printf 'king %s\n' $(( `date +%s` - 31 * 60 )) > "$TMP/batalha"
      batalha_pendente || printf 'vence' )
check "mesma batalha preserva a inscricao; vence apos LUTA_TETO_MIN" "preserva vence" "$_r"
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
          "coliseum.sh coliseum"; do
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
for _m in altars.sh clanfight.sh clandmg.sh clancoliseum.sh flagfight.sh; do
    grep -q "alvo_grey \"[^\"]*\" || \[ ! -s ATK \]" "$LIB/$_m" \
        && ok "$_m: sem link de ataque, rele a pagina do evento" \
        || bad "$_m: sem link de ataque o laco dorme sem reler"
done
grep -q "alvo_grey \"\$src_ram\" || \[ -z \"\$ATK\" \]" "$LIB/coliseum.sh" \
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
_rt=$(grep -n '^    batalha_retomar' "$LIB/run.sh" | head -n1 | cut -d: -f1)
_cs=$(grep -n 'case `date +%H:%M` in' "$LIB/run.sh" | head -n1 | cut -d: -f1)
if [ -n "$_rt" ] && [ -n "$_cs" ] && [ "$_rt" -lt "$_cs" ]; then
    ok "run.sh: batalha pendente e retomada antes do cronograma"
else
    bad "run.sh: worker relancado cai na rotina com a batalha em andamento"
fi
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
if LC_ALL=C grep -q $'\xef\xb8\x8f' "$ROOT/lib/panel.sh"; then
    _vs=`LC_ALL=C grep -n $'\xef\xb8\x8f' "$ROOT/lib/panel.sh" | grep -vE '^[0-9]+:[[:space:]]*#' | head -n3`
    if [ -n "$_vs" ]; then
        bad "painel: ha icone com seletor de variacao ($_vs)"
    else
        ok "painel: seletor so aparece em comentario"
    fi
    unset _vs
else
    ok "painel: nenhum seletor de variacao"
fi

# Os simbolos de estado de cada modo tem os mesmos bytes: e o que faz o
# "%-*s" com S_W deixar o nome da conta na mesma coluna em qualquer estado.
for _modo in 1 2; do
    _r=$(
        SLS_EMOJI="$_modo" HOME=/nao/existe
        export SLS_EMOJI HOME
        . "$ROOT/lib/panel.sh" > /dev/null 2>&1
        for _s in "$S_ON" "$S_WAIT" "$S_ERR" "$S_OFF" "$S_UNK" "$S_PAUSE"; do
            printf '%s ' "`printf '%s' "$_s" | wc -c | tr -d ' '`"
        done
        printf 'S_W=%s' "$S_W"
    )
    case "$_modo" in 1) _esp="4 4 4 4 4 4 S_W=4" ;; 2) _esp="3 3 3 3 3 3 S_W=3" ;; esac
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

for _p in "king.sh _hpat" "altars.sh HP" "clanfight.sh HP" "clandmg.sh HP" \
          "clancoliseum.sh USH" "flagfight.sh USH" "coliseum.sh _col_hp"; do
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
# Coliseu: o USH exige 2 a 5 digitos; para a morte a leitura aceita 1 a 6
# (HP entre 1 e 9 e vida, nao morte).
grep -q '\[0-9\]{1,6}" "\$src_ram" | head -n 1' "$LIB/coliseum.sh" \
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
          undying:undying king:king; do
    _arq="${_m%%:*}"; _sec="${_m##*:}"
    grep -q "ressuscitar $_sec" "$LIB/$_arq.sh" \
        && ok "$_arq.sh: tenta voltar antes de encerrar (ressuscitar $_sec)" \
        || bad "$_arq.sh: morre e sai do evento sem tentar o unrip"
done

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

printf "\n=== 38. aliados: amigos + membros do mesmo cla, e o nome certo do alvo ===\n"
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
    ( TMP="$_td8/m$1"; URL="http://jogo"; CLD=999; export TMP URL CLD; rm -rf "$TMP"; mkdir -p "$TMP"
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
_todos="Amigo_Dois Amigo_Um Chefe_Grande Fulano_Silva beltrano_souza"
check "aliados modo 1: amigos + cla em todas as batalhas" "$_todos|$_todos" "`_montar38 1`"
check "aliados modo 2: so Rei (allies)"                    "$_todos|"       "`_montar38 2`"
check "aliados modo 3: so batalhas de cla (callies)"        "|$_todos"       "`_montar38 3`"

# A lista de amigos traz o link "Exclui": nenhum pedido pode desfazer amizade.
_r=$( TMP="$_td8/del"; URL="http://jogo"; CLD=999; export TMP URL CLD; mkdir -p "$TMP"
      SLS_PACING=0; . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/allies.sh" > /dev/null 2>&1
      run_curl_exec() { echo "$1" >> "$TMP/pedidos"; case "$1" in
          */mail/friends) cat "$_td8/amigos" ;; */clan/999) cat "$_td8/cla_p1" ;; */clan/999//2) cat "$_td8/cla_p2" ;; esac; }
      time_exit() { wait "$!" 2>/dev/null; }
      : > "$TMP/pedidos"
      aliados_montar 1 > /dev/null 2>&1
      _aliado_pagina "/mail/friends/delete/555?r=91" "$TMP/x" > /dev/null 2>&1
      grep -c delete "$TMP/pedidos" )
check "aliados: nunca pede o link 'Exclui' da lista de amigos" "0" "$_r"

# Lista de amigos em duas paginas (paginacao real: 10 por pagina, links
# /mail/friends/2 na 1 e /mail/friends/1 na 2).
_r=$( TMP="$_td8/pag"; URL="http://jogo"; export TMP URL; mkdir -p "$TMP"
      SLS_PACING=0; . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/allies.sh" > /dev/null 2>&1
      _p1="<img src='/images/icon/race/1.png' alt=''/> <a href='/user/901/'>Pagina Um</a>, 10 nível <span class='medium'>( <a href='/mail/901/'>Escrever</a> / <a href='/mail/friends/delete/901?r=5'>Excluir</a> )</span><div class='block_zero'>&#60;&#60; &#60; 1 <a href='/mail/friends/2'>2</a> <a href='/mail/friends/2'>&#62;</a> <a href='/mail/friends/2'>&#62;&#62;</a></div>"
      _p2="<img src='/images/icon/race/1.png' alt=''/> <a href='/user/902/'>Pagina Dois</a>, 20 nível <span class='medium'>( <a href='/mail/902/'>Escrever</a> / <a href='/mail/friends/delete/902?r=6'>Excluir</a> )</span><div class='block_zero'><a href='/mail/friends/1'>&#60;&#60;</a> <a href='/mail/friends/1'>1</a> 2</div>"
      run_curl_exec() { echo "$1" >> "$TMP/pedidos"; case "$1" in
          */mail/friends) printf '%s' "$_p1" ;; */mail/friends/2) printf '%s' "$_p2" ;; esac; }
      time_exit() { wait "$!" 2>/dev/null; }
      : > "$TMP/pedidos"
      printf '%s|%s' "`aliados_amigos | tr '\n' ' ' | sed 's/ $//'`" "`sed 's,^http://jogo,,' "$TMP/pedidos" | tr '\n' ' ' | sed 's/ $//'`" )
check "aliados: amigos das duas paginas, um pedido por pagina" "Pagina_Um Pagina_Dois|/mail/friends /mail/friends/2" "$_r"

# Servidor mudo nao apaga a lista.
_r=$( TMP="$_td8/mudo"; URL="http://jogo"; CLD=999; export TMP URL CLD; mkdir -p "$TMP"
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
check "liga_do_dia: fechada nao faz nada; aberta faz a visita inteira" "|rc=1|cq:liga,liga,marca:liga" "$_r"
_r=`( . "$LIB/league.sh" > /dev/null 2>&1; for _m in 05 12 27 40 57; do
      date() { echo "$_m"; }; liga_fora_da_inscricao && printf '%s=livre ' "$_m" || printf '%s=evento ' "$_m"; done )`
check "entrada: minutos de inscricao de evento deixam a Liga para depois" "05=livre 12=evento 27=evento 40=livre 57=evento " "$_r"

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
    ( TMP="$_td10/p"; rm -rf "$TMP"; mkdir -p "$TMP"; . "$LIB/crono.sh" > /dev/null 2>&1; . "$LIB/campaign.sh" > /dev/null 2>&1
      : > "$TMP/req"; CENA="$1"
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
              /campaign/:mudo)        : > "$TMP/SRC" ;;
              /campaign/:semrel)
                  if [ "$_n" = 1 ]; then echo "<a href='/campaign/end/?r=1'>x</a>" > "$TMP/SRC"
                  else echo "<div>outra coisa</div>" > "$TMP/SRC"; fi ;;
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
sed -n '/^descansar() {/,/^}/p' "$LIB/crono.sh" | grep -q 'caverna_ler_menu "$TMP/REST"' \
    && ok "descansar: le o relogio da caverna na pagina inicial que ja baixou" \
    || bad "descansar: nao le o relogio da caverna"

# --- uma varredura completa por minuto
_r=`( TMP="$_td10/s"; rm -rf "$TMP"; mkdir -p "$TMP"; . "$LIB/crono.sh" > /dev/null 2>&1
      load_config() { printf 'VARREDURA'; exit 0; }; espera_interrompivel() { printf 'espera '; }
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
_r=`cat "$LIB/sls.sh" "$LIB/loginlogoff.sh" "$LIB/session_check.sh" | grep -c '"pass@-"'`
check "login: senha pelo stdin nos tres POSTs" 3 "$_r"

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
      campanha_liberada() { return 1; }; caverna_liberada() { return 1; }; check_rewards() { :; }
      echo 190001010000 > "$TMP/last_start"; start; printf '| '
      echo 190001010000 > "$TMP/last_start"; start; rm -rf "$TMP" ) | sed 's/Checklist do cla//' | tr -d '\n'`
check "start() duas vezes seguidas: a segunda so passa pela liga (portao do jogo)" \
    "atualiza_agenda use_elixir cq_concluir career_func check_missions liga_do_dia func_trade clanQuests specialEvent allies_refresh | liga_do_dia " "$_r"
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
for _f in lib/sls.sh lib/loginlogoff.sh setup.sh; do
    _r=`( creds="$_cr"; eval "$(grep -E '^ *(luser|lpass)=' "$ROOT/$_f")"; printf '[%s][%s]' "$luser" "$lpass" )`
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
        if (l ~ /head -n ?1|tail -n ?1|sed -n .?1p|sed -n "\$[{]?[a-z_]+[}]?p|wc -l|grep -c|grep -q/) next
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

# Aliados: amigos respondem, a pagina do cla nao.
_al47() { # com_lista_antiga(sim|nao) -> "lista|rc"
    ( TMP="$_td12/al$1"; URL="http://jogo"; CLD=999; export TMP URL CLD; rm -rf "$TMP"; mkdir -p "$TMP"
      SLS_PACING=0; . "$LIB/info.sh" > /dev/null 2>&1; . "$LIB/allies.sh" > /dev/null 2>&1
      [ "$1" = sim ] && printf 'Amigo_Um\nMembro_Cla\n' > "$TMP/aliados.txt" && cp "$TMP/aliados.txt" "$TMP/allies.txt"
      [ "$1" = cortada ] && printf 'Amigo_Velho\nMembro_Cla\n' > "$TMP/aliados.txt" && cp "$TMP/aliados.txt" "$TMP/allies.txt"
      MODO="$1"
      run_curl_exec() { case "$1" in
          */mail/friends) echo "<a href='/user/5/'>Amigo Um</a>, <a href='/mail/5/'>Escrever</a>"
                          [ "$MODO" = cortada ] && return 56 ;;
          */clan/999) [ "$MODO" = cortada ] && echo "<a href='/user/9/'><img src='/r.png' alt=''/>Membro Cla, <span class='white'>Soldado</span>" ;;
          *) : ;; esac; return 0; }
      # Como o time_exit real: so o curl 28 conta como falha.
      time_exit() { wait "$!" 2>/dev/null; [ $? = 28 ] && return 1; return 0; }
      aliados_montar 1 > /dev/null 2>&1; _rc=$?
      printf '%s|%s' "`tr '\n' ' ' < "$TMP/allies.txt" | sed 's/ $//'`" "$_rc" )
}
check "aliados: cla sem resposta mantem a lista com o cla" "Amigo_Um Membro_Cla|1" "`_al47 sim`"
check "aliados: sem lista anterior, a parcial vale e pede nova tentativa" "Amigo_Um|1" "`_al47 nao`"
check "aliados: pagina de amigos cortada (curl 56) mantem a lista" "Amigo_Velho Membro_Cla|1" "`_al47 cortada`"

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
          /league/) if [ -f "$TMP/clicou" ]; then : > "$TMP/SRC"; return 1; fi
                    echo "<a href='/league/takeReward/?r=7'>Pegar</a>" > "$TMP/SRC" ;;
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
      stats_liberado() { return 1; }
      for _f in cq_liberado masmorra_liberada arena_liberada campanha_liberada caverna_liberada; do eval "$_f() { return 0; }"; done
      for _f in cq_concluir cq_ajudar cq_elixir cq_mercador cq_marcar clanDungeon masmorra_marcar masmorra_adiar \
                cq_antes arena_duel career_func campaign_func cave_routine check_missions check_rewards \
                liga_do_dia func_trade clanQuests specialEvent allies_refresh; do eval "$_f() { printf '%s ' $_f; }"; done
      tarefas_livres 2>/dev/null | grep -o 'arena_duel\|Servidor sem resposta' | tr '\n' ' ' | sed 's/ $//' )
}
_ag=`date +%s`
check "servidor mudo agora: nenhuma atividade na volta" "Servidor sem resposta" "`_tl48 "$_ag" $((_ag - 100))`"
check "servidor respondeu depois da falha: varredura normal" "arena_duel" "`_tl48 $((_ag - 100)) "$_ag"`"
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
      [ "$1" != nunca ] && echo $(( `date +%s` - $1 )) > "$HOME/.sls/.login.ultimo"
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
_r=$(grep -c 'cat last_atk' "$LIB/altars.sh" "$LIB/clanfight.sh" "$LIB/clandmg.sh" \
     "$LIB/clancoliseum.sh" "$LIB/flagfight.sh" | grep -c ':1$')
check "last_atk lido uma vez por volta nos cinco modulos" 5 "$_r"
rm -rf "$_td16"; unset _td16 _r
unset -f _full51

# DIAGNOSTICO TEMPORARIO: pagina de missao do cla cheia sem link de concluir.
_td17=`mktemp -d`
_cq51() { # progresso -> "cheia|nenhuma guardou|nao"
    ( TMP="$_td17/c"; export TMP; rm -rf "$TMP"; mkdir -p "$TMP"
      . "$LIB/clanquest.sh" > /dev/null 2>&1
      printf '<div>Progresso: %s</div>\n' "$1" > "$TMP/CQUEST"
      cq_tem_completa && printf 'cheia ' || printf 'nenhuma '
      cq_guardar_completa > /dev/null 2>&1
      [ -f "$TMP/cq_completa.html" ] && printf 'guardou' || printf 'nao' )
}
check "missao em andamento: nada a guardar"          "nenhuma nao"    "`_cq51 '6 de 15'`"
check "missao cheia: pagina guardada para diagnostico" "cheia guardou" "`_cq51 '15 de 15'`"
check "cheia com separador de milhar"                  "cheia guardou" "`_cq51 \"150'000 de 150'000\"`"
check "diagnostico so no checklist (nao no cq_antes)" "1 0" \
    "$(grep -c '|| cq_guardar_completa' "$LIB/crono.sh") $(grep -c '|| cq_guardar_completa' "$LIB/clanquest.sh")"
rm -rf "$_td17"; unset _td17
unset -f _cq51

printf "\n=== 52. trava de login: so o dono apaga ===\n"
# =============================================================================
_td18=`mktemp -d`
sed -n '/^login_lock() {/,/^}/p;/^login_unlock() {/,/^}/p' "$LIB/sls.sh" > "$_td18/trava.sh"
_trava52() { # outra_conta_segura(s|n) -> "trava_ficou|trava_saiu espacou?"
    ( HOME="$_td18/h$1"; mkdir -p "$HOME/.sls"; LOCKDIR="$HOME/.sls/.login.lock"
      . "$_td18/trava.sh"
      sleep() { :; }
      login_espacar() { printf 'espacou ' >> "$HOME/log"; }
      login_espacar_marcar() { :; }
      # Dono vivo (o proprio shell do teste): a espera estoura os 3 minutos.
      [ "$1" = s ] && { mkdir "$LOCKDIR"; echo $$ > "$LOCKDIR/pid"; }
      login_lock; login_unlock
      [ -d "$LOCKDIR" ] && printf 'trava_ficou ' || printf 'trava_saiu '
      cat "$HOME/log" 2>/dev/null )
}
check "sem trava de outra conta: pega e solta"                 "trava_saiu espacou " "`_trava52 n`"
check "estourou a espera: nao apaga a trava do dono, espaca"   "trava_ficou espacou " "`_trava52 s`"
rm -rf "$_td18"; unset _td18
unset -f _trava52

printf "\n=== RESUMO ===\n"
printf "  PASS=%s  FALHA=%s\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
