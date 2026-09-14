#!/bin/sh
# uninstall.sh - Remove COMPLETAMENTE o solucaoshell do sistema
#
# Apaga: processos, os dados das contas (~/.sls) e o proprio diretorio do bot.
#
# ATENCAO: isto apaga o accounts.conf. As contas cadastradas serao perdidas
# e voce tera de cadastra-las de novo. As contas no JOGO nao sao afetadas.

_dir=$(dirname "$0")
SLSDIR=$(cd "$_dir" && pwd)

# O motor mora em lib/. Os comandos do usuario ficam na raiz; tudo que e
# biblioteca (worker, painel, modulos de batalha) e carregado daqui.
LIBDIR="$SLSDIR/lib"
export LIBDIR


R='\033[0;31m'; G='\033[32m'; Y='\033[1;33m'; C='\033[01;36m'; N='\033[00m'

printf "${C}=== Desinstalacao do solucaoshell ===${N}\n\n"
printf "Sera removido:\n"

_ach=0
for p in "$SLSDIR" "$HOME/.sls"; do
    if [ -e "$p" ]; then
        printf "  %-38s %s\n" "$p" "$(du -sh "$p" 2>/dev/null | cut -f1)"
        _ach=1
    fi
done
[ "$_ach" = 0 ] && printf "  (nada encontrado)\n"

_n=0
[ -s "$SLSDIR/accounts.conf" ] && _n=$(grep -cE '^[0-9]+\|' "$SLSDIR/accounts.conf" 2>/dev/null)
if [ "${_n:-0}" -gt 0 ]; then
    printf "\n${Y}Voce tem %s conta(s) cadastrada(s). As credenciais serao apagadas.${N}\n" "$_n"
    printf "${Y}Suas contas no jogo NAO sao afetadas — so o cadastro local.${N}\n"
fi

printf "\n${R}Esta acao nao pode ser desfeita.${N}\n"
printf "Digite ${C}REMOVER${N} para confirmar: "
read -r _ok
[ "$_ok" = "REMOVER" ] || { printf "\nCancelado. Nada foi alterado.\n"; exit 1; }

printf "\n"

# 1. processos
printf "Encerrando processos...\n"
[ -x "$SLSDIR/stop.sh" ] && sh "$SLSDIR/stop.sh" > /dev/null 2>&1
for pat in "$SLSDIR/play.sh" "$LIBDIR/worker.sh" "$LIBDIR/sls.sh"; do
    pkill -TERM -f "$pat" 2>/dev/null
done
sleep 2
for pat in "$SLSDIR/play.sh" "$LIBDIR/worker.sh" "$LIBDIR/sls.sh"; do
    pkill -KILL -f "$pat" 2>/dev/null
done
printf "  ${G}processos encerrados${N}\n"

# 2. wake lock (Termux)
termux-wake-unlock 2>/dev/null

# 3. dados
printf "Removendo arquivos...\n"
rm -rf "$HOME/.sls"
rm -f /tmp/play_out.log /tmp/sls_* /tmp/diag_* 2>/dev/null
printf "  ${G}dados removidos${N}\n"

# 4. o proprio diretorio, por ultimo
printf "Removendo %s...\n" "$SLSDIR"
cd "$HOME" || cd /
rm -rf "$SLSDIR"

printf "\n${G}solucaoshell removido por completo.${N}\n"
printf "O sistema esta como antes da instalacao.\n\n"
printf "Os pacotes instalados (git, curl, jq) foram mantidos —\n"
printf "sao utilitarios comuns. Para remover tambem:\n"
printf "  ${C}sudo apt remove --purge jq${N}          (Debian/Ubuntu)\n"
printf "  ${C}pkg uninstall jq${N}                    (Termux)\n"
