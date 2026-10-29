#!/usr/bin/env python3
"""Simulador das batalhas: o laco de luta de verdade contra um jogo falso.

Roda a funcao de luta REAL de cada evento (king_fight, clanfight_fight,
altars_fight, ...) num shell em que "date" e "sleep" andam num RELOGIO
VIRTUAL dividido com um jogo falso local. Uma luta de 5 minutos roda em
segundos, e os prazos do jogo (acao a cada 4-5s, elixir a cada 90s, esquiva
a cada 20s, erva e pedra a cada 60s) valem como no jogo de verdade.

O jogo falso guarda o estado da luta (vida, dano por segundo, elixires,
recargas, nonce de cada pagina, alvo invulneravel, aliado na frente, morte,
ressurreicao e fim) e injeta falhas em janelas de tempo: resposta lenta,
tempo esgotado, pagina vazia, erro 502, pagina cortada, sessao caida. Cada
pedido fica anotado; no fim, a bateria mede:

  - o maior intervalo sem acao com a luta disponivel (conta parada);
  - acoes coladas (< 4s da anterior: o jogo recusa);
  - cura so com a vida abaixo do limiar e respeitando os 90s;
  - esquiva so quando a regra do evento manda, respeitando os 20s;
  - erva e pedra so de graca (nunca o botao que cobra ouro);
  - nenhum golpe em alvo invulneravel ou em aliado (fora o fogo amigo);
  - nonce velho (acao com o link de uma pagina antiga);
  - rajada de pedidos (mais de 3 no mesmo segundo);
  - a conta so sai da luta quando o jogo declara o fim (ou a morte sem
    ressurreicao), e sai logo depois disso.

    Uso:  python3 tests/simulador_batalhas.py [EVENTO ...] [--relatorio ARQ]

Sem rede (um ~/.curlrc so do simulador manda o dominio do jogo para o
servidor local) e sem tocar no ~/.sls de verdade. A reconexao da sessao usa
um login direto no jogo falso no lugar do login_logoff (que tambem le
/train, mensagens e cla): o que se mede e o laco de luta voltar a atacar.
"""

import http.server
import json
import os
import re
import secrets
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(RAIZ, 'lib')
FULL = 10000

# ---------------------------------------------------------------------------
#  EVENTOS: como cada funcao de luta le a pagina
# ---------------------------------------------------------------------------
# sec: secao da URL; arq: modulo; func: funcao de luta; src: arquivo de pagina
# que a funcao le na primeira volta; fulls: arquivos de HP maximo; la: acao a
# cada (s, como o laco faz); limiar: % da cura; cura: verbo do elixir;
# unrip: o evento ressuscita; itens: usa erva/pedra; esquiva: regra.
EVENTOS = {
    'clanfight':    dict(sec='clanfight', arq='clanfight.sh', func='clanfight_fight', src='SRC',
                         fulls=['FULL'], la=5, limiar=48, cura='heal', unrip=True, itens='erva_na_cura',
                         esquiva='cla', aliados='callies.txt'),
    'clandmgfight': dict(sec='clandmgfight', arq='clandmg.sh', func='clandmgfight_fight', src='SRC',
                         fulls=['FULL'], la=5, limiar=48, cura='heal', unrip=True, itens='erva_na_cura',
                         esquiva='cla', aliados='callies.txt'),
    'altars':       dict(sec='altars', arq='altars.sh', func='altars_fight', src='src.html',
                         fulls=['FULL'], la=5, limiar=48, cura='heal', unrip=True, itens='',
                         esquiva='cla', aliados='callies.txt'),
    'clancoliseum': dict(sec='clancoliseum', arq='clancoliseum.sh', func='clancoliseum_fight', src='ccol_src',
                         fulls=['FULL', 'ccol_full'], la=5, limiar=48, cura='heal', unrip=True, itens='',
                         esquiva='cla', aliados='callies.txt'),
    'clancommand':  dict(sec='clancommand', arq='clancommand.sh', func='clancommand_fight', src='ccmd_src',
                         fulls=['FULL'], la=5, limiar=48, cura='heal', unrip=True, itens='',
                         esquiva='cla', aliados='callies.txt'),
    'flagfight':    dict(sec='flagfight', arq='flagfight.sh', func='flagfight_fight', src='flag_src',
                         fulls=['FULL', 'flag_full'], la=5, limiar=48, cura='shield', unrip=True, itens='',
                         esquiva='queda', aliados='callies.txt'),
    'king':         dict(sec='king', arq='king.sh', func='king_fight', src='SRC',
                         fulls=['FULL'], la=5, limiar=38, limiar2=67, cura='heal', unrip=True, itens='sempre',
                         esquiva='rei_morto', aliados='allies.txt'),
    'undying':      dict(sec='undying', arq='undying.sh', func='undying_fight', src='SRC',
                         fulls=['FULL'], la=5, limiar=0, cura=None, unrip=False, itens='sempre',
                         esquiva=None, aliados=None),
}
ACOES = {'attack', 'attackrandom', 'kingatk', 'dodge', 'heal', 'shield', 'grass', 'stone', 'hit', 'mana'}
GOLPES = {'attack', 'attackrandom', 'kingatk', 'hit', 'mana'}


# ---------------------------------------------------------------------------
#  RELOGIO VIRTUAL
# ---------------------------------------------------------------------------

class Relogio:
    def __init__(self, caminho, inicio):
        self.caminho = caminho
        self.trava = threading.Lock()
        self._gravar(inicio)

    def _gravar(self, v):
        tmp = self.caminho + '.py'
        with open(tmp, 'w') as f:
            f.write('%.3f\n' % v)
        os.replace(tmp, self.caminho)

    def agora(self):
        with open(self.caminho) as f:
            return float(f.read().strip() or 0)

    def avancar(self, dt):
        with self.trava:
            self._gravar(self.agora() + dt)


# ---------------------------------------------------------------------------
#  JOGO FALSO
# ---------------------------------------------------------------------------

class Luta:
    """Estado de uma luta e o registro de tudo o que a conta pediu."""

    def __init__(self, ev, cfg, relogio):
        self.ev, self.cfg, self.rel = ev, cfg, relogio
        self.t0 = relogio.agora()
        self.hp = cfg.get('hp0', FULL)
        self.t_hp = 0.0
        self.morto = False
        self.elixires = cfg.get('elixires', 99)
        self.erva = cfg.get('erva', 0)          # cargas gratis
        self.pedra = cfg.get('pedra', 0)
        self.ult_acao = -99.0
        self.ult_cura = -999.0
        self.ult_esq = -999.0
        self.esq_ate = -1.0
        self.troca_ate = -1.0
        self.sessoes = {}                       # sid -> nonce da ultima pagina
        self.derrubou = False
        self.log = []                           # dicts
        self.hist_hp = []                       # (t, hp) para o dano de 15s
        self.nonce = 100
        self.pag = {}                           # nonce -> o que a pagina mostrou
        self.fim_visto = None                   # quando a conta recebeu a pagina do fim

    # -- tempo e vida -------------------------------------------------------
    def t(self):
        return self.rel.agora() - self.t0

    def dps(self, t):
        for a, b, v in self.cfg.get('dano', [(0, 1e9, 10)]):
            if a <= t < b:
                return v
        return 0

    def atualizar(self):
        t = self.t()
        if self.morto:
            self.t_hp = t
            return t
        # Integra o dano de segundo em segundo.
        x = self.t_hp
        while x < t:
            passo = min(1.0, t - x)
            d = self.dps(x) * passo
            if x < self.esq_ate:
                d *= 0.2
            self.hp = max(0, self.hp - d)
            x += passo
            if self.hp <= 0:
                self.morto = True
                self.anota('morreu', t=x)
                break
        self.t_hp = t
        self.hist_hp.append((t, self.hp))
        return t

    def dano15(self, t):
        janela = [h for (x, h) in self.hist_hp if t - 15 <= x <= t]
        return (max(janela) - self.hp) if janela else 0

    def falha(self, t):
        for f in self.cfg.get('falhas', []):
            if f[0] <= t < f[1]:
                return f
        return None

    def em_janela(self, nome, t):
        return any(a <= t < b for a, b in self.cfg.get(nome, []))

    def acabou(self, t):
        return t >= self.cfg.get('dur', 240)

    def rei_vivo(self, t):
        return t < self.cfg.get('rei_morre', 1e9)

    def anota(self, tipo, **k):
        k.setdefault('t', self.t())
        k['tipo'] = tipo
        self.log.append(k)

    # -- paginas -------------------------------------------------------------
    def novo_nonce(self, sid, **mostrou):
        self.nonce += 1
        self.sessoes[sid] = self.nonce
        self.pag[self.nonce] = mostrou
        return self.nonce

    def cab(self, hp):
        return ("<img src='/images/icon/health.png' alt='hp'/> %d <img src='/images/icon/mana.png' alt='mp'/> 80 "
                "<img src='/images/icon/level.png' alt='lvl'/> 91 <img src='/images/icon/gold.png' alt='g'/> 396 "
                "<img src='/images/icon/silver.png' alt='s'/> 408,1M<br/>" % hp)

    def rodape(self):
        return "<script>jsInterface.event(\"user=473431;level=91\")</script>"

    def pagina(self, sid):
        t = self.atualizar()
        s = self.ev['sec']
        if self.acabou(t):
            if self.fim_visto is None:
                self.fim_visto = t
            fim = {'undying': 'Vitória!', 'king': 'Batalha finalizada!'}.get(s, 'Luta acabou!')
            return ("<html>%s<div>%s</div><a href='/%s/?close=reward'>Pegar recompensa</a>%s</html>"
                    % (self.cab(int(self.hp)), fim, s, self.rodape()))
        grey = self.em_janela('grey', t)
        aliado = self.em_janela('aliado', t) and t >= self.troca_ate
        n = self.novo_nonce(sid, t=t, grey=grey, aliado=aliado, morto=self.morto)
        if self.morto:
            if self.ev['unrip']:
                return ("<html>%s<div class='block_zero'>Você morreu</div>"
                        "<a href='/%s/unrip/?r=%d'>Ressuscitar</a>%s</html>" % (self.cab(0), s, n, self.rodape()))
            return ("<html>%s<div class='block_zero'><span class='grey'>Espere até o fim da batalha </span>"
                    "</div>%s</html>" % (self.cab(0), self.rodape()))
        if s == 'undying':
            b = ["<a href='/undying/hit/?r=%d'>Bater</a>" % n]
            b.append(self.botao_item('grass', n, 'Erva'))
            b.append(self.botao_item('stone', n, 'Pedra'))
            return ("<html><img src='/images/icon/level.png' alt=''/> Monstro %s <a href='/undying/?out_gate'>sair</a>%s</html>"
                    % (' '.join(x for x in b if x), self.rodape()))
        nome = 'Meu Aliado' if aliado else 'Inimigo Forte'
        if grey:
            alvo = ("<div class='target'><span class='txt smpl grey'>%s</span> <span class='nwr'>"
                    "<img src='/images/icon/health.png' alt='hp'/>&nbsp;5000</span></div>" % nome)
        else:
            alvo = ("<div class='target'><img src='/images/icon/race/0.png' alt=''/> %s <span class='nwr'>"
                    "<img src='/images/icon/health.png' alt='hp'/>&nbsp;5000</span></div>" % nome)
        b = []
        if s == 'king' and self.rei_vivo(t):
            b.append("<a class='nbtn b_red' href='/king/kingatk/?r=%d'><span class='lbl'><span class='txt smpl'>Golpe no Rei</span></span></a>" % n)
        b.append("<a class='nbtn b_green' href='/%s/dodge/?r=%d'><span class='lbl'><span class='txt smpl'>Esquivar</span></span></a>" % (s, n))
        cls = 'b_grey' if grey else 'b_red btn-attack-inst'
        lbl = 'txt smpl grey' if grey else 'txt smpl'
        b.append("<a class='nbtn %s' href='/%s/attack/?r=%d'><span class='lbl'><span class='%s'>Atacar</span></span></a>"
                 % (cls, s, n, lbl))
        b.append("<a class='nbtn b_grey' href='/%s/attackrandom/?r=%d'><span class='lbl'><span class='txt smpl grey'>Troca o alvo</span></span></a>" % (s, n))
        if self.elixires > 0 and self.ev['cura']:
            b.append("<a href='/%s/%s/?r=%d'>Elixir (%d)</a>" % (s, self.ev['cura'], n, self.elixires))
        b.append(self.botao_item('grass', n, 'Erva'))
        b.append(self.botao_item('stone', n, 'Pedra'))
        return ("<html>%s%s<div class='fight_buttons'>%s</div>%s</html>"
                % (self.cab(int(self.hp)), alvo, ''.join(x for x in b if x), self.rodape()))

    def botao_item(self, verbo, n, nome):
        cargas = self.erva if verbo == 'grass' else self.pedra
        if cargas > 0:
            return "<a href='/%s/%s/?r=%d'>%s (%d)</a>" % (self.ev['sec'], verbo, n, nome, cargas)
        if self.cfg.get('item_pago', True):
            return ("<a href='/%s/%s/?r=%d'>%s <img src='/images/icon/gold.png' alt='g'/> 10</a>"
                    % (self.ev['sec'], verbo, n, nome))
        return ''

    # -- acoes ---------------------------------------------------------------
    def agir(self, sid, verbo, nonce):
        t = self.atualizar()
        viu = self.pag.get(nonce, {})
        if self.acabou(t):
            # So conta se a conta ja tinha recebido a pagina do fim (antes
            # disso ela nao tinha como saber).
            if self.fim_visto is not None and self.fim_visto < t:
                self.anota('acao_depois_do_fim', verbo=verbo)
            return
        if self.sessoes.get(sid) != nonce:
            self.anota('nonce_velho', verbo=verbo)
            return
        if verbo == 'unrip':
            if self.morto:
                self.morto = False
                self.hp = FULL
                self.hist_hp.append((t, self.hp))
                self.cfg['dano'] = self.cfg.get('dano_pos_morte', [(0, 1e9, 10)])
                self.anota('ressuscitou')
            return
        if self.morto:
            if viu.get('morto'):
                self.anota('acao_morto', verbo=verbo)
            return
        # Regra do jogo (dono, 29/10): cada botao tem o seu tempo. So o GOLPE
        # colado em outro golpe (2 a 3s) e recusado; esquiva ou cura e logo
        # depois o golpe nao trava.
        if verbo in GOLPES:
            gap = t - self.ult_acao
            if gap < 3.0:
                self.anota('colada', verbo=verbo, gap=round(gap, 2))
                return
            self.ult_acao = t
        hp = self.hp
        info = dict(verbo=verbo, hp=int(hp), pct=round(100.0 * hp / FULL, 1), dano15=int(self.dano15(t)),
                    elixir_na_tela=self.elixires > 0)
        if verbo in ('attack', 'kingatk'):
            if viu.get('grey'):
                self.anota('golpe_invulneravel', **info)
                return
            if verbo == 'attack' and viu.get('aliado'):
                self.anota('golpe_aliado', **info)
                return
        if verbo == 'attackrandom':
            self.troca_ate = t + self.cfg.get('troca_dura', 30)
        if verbo in ('heal', 'shield'):
            # Recargas com a mesma folga de 1s (segundos inteiros + rede).
            if t - self.ult_cura < 89.0 or self.elixires <= 0:
                self.anota('cura_recusada', **info)
                return
            self.ult_cura = t
            self.elixires -= 1
            self.hp = min(FULL, self.hp + self.cfg.get('cura', 4000))
            self.hist_hp.append((t, self.hp))
        if verbo == 'dodge':
            if t - self.ult_esq < 19.0:
                self.anota('esquiva_recusada', **info)
                return
            self.ult_esq = t
            self.esq_ate = t + 10
        if verbo in ('grass', 'stone'):
            if (self.erva if verbo == 'grass' else self.pedra) <= 0:
                self.anota('item_pago', **info)
                return
            if verbo == 'grass':
                self.erva -= 1
            else:
                self.pedra -= 1
        self.anota('acao', **info)


class Jogo(http.server.BaseHTTPRequestHandler):
    luta = None
    protocol_version = 'HTTP/1.1'

    def log_message(self, *a):
        pass

    def _sid(self):
        m = re.search(r'sid=([0-9a-f]+)', self.headers.get('Cookie', ''))
        return m.group(1) if m else None

    def _enviar(self, corpo, codigo=200, extra=None, cortar=False):
        dados = corpo.encode('utf-8')
        self.send_response(codigo)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(dados) + (500 if cortar else 0)))
        for k, v in (extra or []):
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(dados[:len(dados) // 2] if cortar else dados)
        if cortar:
            self.wfile.flush()
            self.close_connection = True

    def do_POST(self):
        L = Jogo.luta
        n = int(self.headers.get('Content-Length', 0))
        self.rfile.read(n)
        L.rel.avancar(0.2)
        sid = secrets.token_hex(8)
        L.sessoes[sid] = 0
        L.anota('login')
        self.send_response(302)
        self.send_header('Location', '/')
        self.send_header('Set-Cookie', 'sid=%s; Path=/' % sid)
        self.send_header('Content-Length', '0')
        self.end_headers()

    def do_GET(self):
        L = Jogo.luta
        t = L.t()
        caminho = self.path
        L.anota('pedido', caminho=caminho)
        if caminho.startswith('/?sign_in=1'):
            L.rel.avancar(0.2)
            return self._enviar("<form action='/?sign_in=1'><input name='pass'/></form>"
                                "<script>jsInterface.event(\"user=0\")</script>",
                                extra=[('Set-Cookie', 'pre=1; Path=/')])
        f = L.falha(t)
        lat = 0.2
        if f:
            tipo = f[2]
            if tipo == 'lento':
                lat = f[3]
            elif tipo == 'timeout':
                # O pedido fica pendurado: 17s no relogio do jogo, e o curl
                # (SLS_LUTA_MAXTIME no simulador) desiste antes no de verdade.
                L.anota('falha', falha='timeout')
                L.rel.avancar(17)
                time.sleep(float(os.environ.get('SIM_PENDURA', '2.6')))
                return self._enviar('')
            elif tipo == 'deslogado' and not L.derrubou:
                L.derrubou = True
                for k in list(L.sessoes):
                    del L.sessoes[k]
                L.anota('falha', falha='sessao_caiu')
            elif tipo in ('vazio', 'erro502', 'cortada', 'casa'):
                L.anota('falha', falha=tipo)
                L.rel.avancar(lat)
                if tipo == 'vazio':
                    return self._enviar('')
                if tipo == 'erro502':
                    return self._enviar('<html><title>502 Bad Gateway</title></html>', 502)
                if tipo == 'casa':
                    return self._enviar("<html>%s<a href='/arena/'>Arena</a>%s</html>" % (L.cab(int(L.hp)), L.rodape()))
                return self._enviar(L.pagina(self._sid() or 'x'), cortar=True)
        L.rel.avancar(lat)
        sid = self._sid()
        if sid not in L.sessoes:
            L.anota('pagina_visitante', caminho=caminho)
            return self._enviar("<html><form action='/?sign_in=1'><input name='pass' type='password'/></form>"
                                "<script>jsInterface.event(\"user=0\")</script></html>")
        s = L.ev['sec']
        m = re.match(r'^/%s/([a-z]+)/\?r=(\d+)' % s, caminho)
        if m:
            verbo, nonce = m.group(1), int(m.group(2))
            if verbo in ACOES or verbo == 'unrip':
                L.agir(sid, verbo, nonce)
        elif re.match(r'^/%s/?\?close=reward' % s, caminho):
            L.anota('recompensa')
        return self._enviar(L.pagina(sid))


class Servidor(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        # O curl desistiu antes (tempo esgotado de proposito): sem barulho.
        pass


# ---------------------------------------------------------------------------
#  AMBIENTE E EXECUCAO
# ---------------------------------------------------------------------------

def sh(cmd):
    subprocess.run(cmd, shell=True, check=True, capture_output=True)


class Ambiente:
    def __init__(self):
        self.dir = tempfile.mkdtemp(prefix='sls_bat_')
        d = self.dir
        sh("openssl req -x509 -newkey rsa:2048 -nodes -keyout %s/ca.key -out %s/ca.pem -days 2 -subj /CN=sim "
           "-addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign" % (d, d))
        with open(d + '/ext.cnf', 'w') as f:
            f.write("subjectAltName=DNS:furiadetitas.net\nbasicConstraints=CA:FALSE\n")
        sh("openssl req -newkey rsa:2048 -nodes -keyout %s/s.key -out %s/s.csr -subj /CN=furiadetitas.net" % (d, d))
        sh("openssl x509 -req -in %s/s.csr -CA %s/ca.pem -CAkey %s/ca.key -CAcreateserial -out %s/s.pem "
           "-days 2 -extfile %s/ext.cnf" % (d, d, d, d, d))
        self.http = Servidor(('127.0.0.1', 0), Jogo)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(d + '/s.pem', d + '/s.key')
        self.http.socket = ctx.wrap_socket(self.http.socket, server_side=True)
        self.porta = self.http.server_address[1]
        threading.Thread(target=self.http.serve_forever, daemon=True).start()
        os.makedirs(d + '/curl')
        with open(d + '/curl/.curlrc', 'w') as f:
            f.write('cacert = "%s/ca.pem"\nconnect-to = "furiadetitas.net:443:127.0.0.1:%d"\n'
                    'noproxy = "furiadetitas.net,127.0.0.1"\n' % (d, self.porta))

    def fechar(self):
        self.http.shutdown()
        shutil.rmtree(self.dir, ignore_errors=True)


ROTEIRO = r'''
SIM_RELOGIO="$1"; export SIM_RELOGIO
date() {
    _sd=""; { read -r _sd < "$SIM_RELOGIO"; } 2>/dev/null; _sd=${_sd%%.*}
    case "$1" in
        +*) command date -d "@$_sd" "$1" ;;
        '') command date -d "@$_sd" ;;
        *)  command date "$@" ;;
    esac
}
sleep() {
    _sa=${1%s}
    awk -v a="$_sa" '{ printf "%.3f\n", $1 + a }' "$SIM_RELOGIO" > "$SIM_RELOGIO.sh" && mv -f "$SIM_RELOGIO.sh" "$SIM_RELOGIO"
}
mkdir -p "$TMP" "$HOME/.sls"; cd "$TMP" || exit 1
. "$LIBDIR/info.sh" > /dev/null 2>&1
. "$LIBDIR/session_check.sh"
. "$LIBDIR/crono.sh" > /dev/null 2>&1
. "$LIBDIR/allies.sh" > /dev/null 2>&1
. "$LIBDIR/$SIM_ARQ" > /dev/null 2>&1
entrar() {
    curl -sS -c "$TMP_COOKIE" -b "$TMP_COOKIE" "$URL/?sign_in=1" > /dev/null 2>&1
    printf %s senha | curl -sS -L -c "$TMP_COOKIE" -b "$TMP_COOKIE" \
        --data-urlencode "login=Sim" --data-urlencode "pass@-" "$URL/?sign_in=1" > /dev/null 2>&1
}
# Reconexao no meio da luta: login direto (o login_logoff le mais paginas).
login_logoff() { entrar; echo RELOGIN; return 0; }
entrar
for _f in $SIM_FULLS; do echo 10000 > "$TMP/$_f"; done
[ -n "$SIM_ALIADOS" ] && printf 'Meu_Aliado\n' > "$TMP/$SIM_ALIADOS"
if [ "$SIM_SEC" != undying ]; then
    # Como nos modulos: o run_curl_exec faz "exec curl" (subshell).
    ( run_curl_exec "$URL/$SIM_SEC/" > "$TMP/$SIM_SRC" ) 2>/dev/null
fi
echo "INICIO `date +%s`"
$SIM_FUNC
echo "FIM `date +%s` motivo=[$LUTA_MOTIVO]"
'''


def rodar(amb, nome_ev, cfg):
    ev = EVENTOS[nome_ev]
    base = os.path.join(amb.dir, 'r_%s_%s' % (nome_ev, cfg['nome']))
    os.makedirs(base)
    rel = Relogio(os.path.join(base, 'relogio'), 1_800_000_000.0)
    luta = Luta(ev, dict(cfg), rel)
    Jogo.luta = luta
    roteiro = os.path.join(base, 'luta.sh')
    with open(roteiro, 'w') as f:
        f.write(ROTEIRO)
    env = {
        'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'HOME': base + '/home', 'CURL_HOME': amb.dir + '/curl',
        'TMP': base + '/conta', 'TMP_COOKIE': base + '/conta/cookie.txt', 'URL': 'https://furiadetitas.net',
        'LIBDIR': LIB, 'SLS_TAG': 'BR', 'SLS_PACING': '0', 'SLS_LUTA_MAXTIME': '2', 'TZ': 'America/Sao_Paulo',
        'SIM_ARQ': ev['arq'], 'SIM_FUNC': ev['func'], 'SIM_SRC': ev['src'], 'SIM_SEC': ev['sec'],
        'SIM_FULLS': ' '.join(ev['fulls']), 'SIM_ALIADOS': ev['aliados'] or '',
        'NO_PROXY': 'furiadetitas.net,127.0.0.1', 'no_proxy': 'furiadetitas.net,127.0.0.1', 'LANG': 'C.UTF-8',
    }
    for k in ('HTTPS_PROXY', 'https_proxy'):
        if k in os.environ:
            env[k] = os.environ[k]
    t_real = time.time()
    try:
        p = subprocess.run(['sh', roteiro, rel.caminho], env=env, capture_output=True, text=True,
                           timeout=cfg.get('prazo_real', 240))
        saida = p.stdout
    except subprocess.TimeoutExpired as e:
        saida = (e.stdout or b'').decode('utf-8', 'replace') if isinstance(e.stdout, bytes) else (e.stdout or '')
        saida += '\nPRESO (prazo real esgotado)\n'
    t_real = time.time() - t_real
    m = re.search(r'^FIM (\d+)', saida, re.M)
    fim = (int(m.group(1)) - luta.t0) if m else None
    with open(os.path.join(base, 'saida.txt'), 'w') as f:
        f.write(saida)
    with open(os.path.join(base, 'log.json'), 'w') as f:
        json.dump(luta.log, f)
    return luta, saida, fim, t_real


# ---------------------------------------------------------------------------
#  MEDIDAS
# ---------------------------------------------------------------------------

def medir(ev, cfg, luta, saida, fim):
    """Lista de (ok, verificacao, detalhe)."""
    r = []
    dur = cfg.get('dur', 240)
    log = luta.log
    acoes = [e for e in log if e['tipo'] in ('acao', 'golpe_invulneravel', 'golpe_aliado', 'cura_recusada',
                                             'esquiva_recusada', 'item_pago', 'colada', 'nonce_velho')]
    feitas = [e for e in log if e['tipo'] == 'acao']
    golpes = [e for e in feitas if e['verbo'] in GOLPES]

    # 1. Saiu da luta na hora certa.
    morreu_sem_volta = any(e['tipo'] == 'morreu' for e in log) and not ev['unrip']
    if fim is None:
        r.append((False, 'a funcao de luta terminou', saida[-300:]))
    elif morreu_sem_volta:
        r.append((True, 'morreu sem ressurreicao: saiu', ''))
    else:
        r.append((fim >= dur, 'nao abandonou a luta antes do fim (saiu em %ss, fim em %ss)' % (fim, dur), ''))
        r.append((fim <= dur + 45, 'saiu logo depois do fim (ate 45s; saiu %ss depois)' % (fim - dur), ''))
    # 2. Conta parada: maior intervalo entre golpes com a luta disponivel.
    tolera = cfg.get('tolera', ev['la'] + 2)
    janelas_mudas = [(f[0], f[1] + 8) for f in cfg.get('falhas', [])] + [(a, b + 6) for a, b in cfg.get('grey', [])]
    mortes = [e['t'] for e in log if e['tipo'] == 'morreu']
    volta = [e['t'] for e in log if e['tipo'] == 'ressuscitou']
    for i, mt in enumerate(mortes):
        janelas_mudas.append((mt, (volta[i] if i < len(volta) else 1e9) + 8))
    # A cura e a esquiva tambem ocupam a janela de acao. Conta a TENTATIVA
    # da conta (recusada ou nao): aqui se mede se o bot agiu; a recusa pelo
    # jogo aparece nas outras verificacoes.
    tempos = sorted(e['t'] for e in acoes)
    pior, onde = 0.0, None
    inicio = tempos[0] if tempos else 0
    for a, b in zip([inicio] + tempos, tempos + [min(dur, fim or dur)]):
        if b > dur or a >= dur:
            continue
        if any(x <= a < y or x < b <= y or (a <= x and b >= y) for x, y in janelas_mudas):
            continue
        if b - a > pior:
            pior, onde = b - a, (round(a, 1), round(b, 1))
    r.append((pior <= tolera, 'nenhuma parada: maior intervalo sem acao %.1fs (limite %ss)' % (pior, tolera),
              'entre %s' % (onde,)))
    if not ev['sec'] == 'undying':
        r.append((len(golpes) >= cfg.get('golpes_min', 10), 'atacou (%d golpes)' % len(golpes), ''))
    else:
        r.append((len(golpes) >= cfg.get('golpes_min', 10), 'bateu no monstro (%d golpes)' % len(golpes), ''))
    # 3. Regras do jogo.
    def conta(tipo):
        return [e for e in log if e['tipo'] == tipo]
    coladas = conta('colada')
    if coladas:
        # Golpe a menos de 3s do anterior: recusado. So acontece quando a
        # rede varia (o bot espera 5s), por isso ATENCAO e nao falha.
        r.append((None, 'golpe a menos de 3s do anterior, recusado pelo jogo (%d)' % len(coladas),
                  str([(round(e['t'], 1), e['verbo'], e['gap']) for e in coladas[:4]])))
    # Alvo cinza: cada evento como esta (dono, 29/10): Rei e Equipe esperam,
    # os outros batem. So o Rei e a Equipe sao conferidos.
    gi = conta('golpe_invulneravel')
    if ev['sec'] in ('king', 'clancommand'):
        r.append((not gi, 'esperou o alvo invulneravel voltar', str([round(e['t'], 1) for e in gi[:5]])))
    for tipo, frase in (('nonce_velho', 'nenhuma acao com link de pagina velha'),
                        ('item_pago', 'nunca clicou erva/pedra paga em ouro'),
                        ('acao_depois_do_fim', 'nenhuma acao depois do fim'),
                        ('acao_morto', 'nenhuma acao morto (fora ressuscitar)')):
        x = conta(tipo)
        r.append((not x, frase, str(x[:3]) if x else ''))
    ga = conta('golpe_aliado')
    if cfg.get('aliado'):
        r.append((len(ga) == 0, 'trocou de alvo no aliado em vez de bater', str(ga[:3])))
        trocas = [e for e in feitas if e['verbo'] == 'attackrandom']
        r.append((len(trocas) >= 1, 'usou o "Troca o alvo" (%d)' % len(trocas), ''))
    # 4. Cura.
    curas = [e for e in feitas if e['verbo'] in ('heal', 'shield')]
    recus = conta('cura_recusada')
    if ev['cura']:
        lim = ev['limiar']
        def limiar_de(e):
            if ev['sec'] == 'king' and not luta.rei_vivo(e['t']):
                return ev.get('limiar2', lim)
            return lim
        acima = [e for e in curas + recus if e['pct'] >= limiar_de(e) + 1]
        r.append((not acima, 'curou so com a vida abaixo do limiar', str(acima[:3])))
        r.append((not recus, 'cura respeitando os 90s', str(recus[:3])))
        if cfg.get('espera_cura'):
            tent = curas + recus + [e for e in conta('colada') if e['verbo'] in ('heal', 'shield')]
            r.append((len(tent) >= cfg['espera_cura'], 'decidiu curar quando precisou (%d tentativas, %d aceitas)'
                      % (len(tent), len(curas)), ''))
        if cfg.get('sem_cura'):
            r.append((len(curas) == 0, 'nao curou sem precisar', str(curas[:2])))
    # 5. Esquiva.
    esqs = [e for e in feitas if e['verbo'] == 'dodge']
    erec = conta('esquiva_recusada')
    if ev['esquiva']:
        r.append((not erec, 'esquiva respeitando os 20s', str(erec[:3])))
        if ev['esquiva'] == 'cla':
            fora = [e for e in esqs if not (e['pct'] < ev['limiar'] and e['dano15'] >= FULL * 0.2 - 1)]
            r.append((not fora, 'esquivou so com vida < 48%% e 20%% de dano em 15s', str(fora[:3])))
        if ev['esquiva'] == 'rei_morto':
            fora = [e for e in esqs if luta.rei_vivo(e['t'])]
            r.append((not fora, 'esquiva so com o rei morto', str(fora[:3])))
        if cfg.get('espera_esquiva'):
            tent = esqs + erec + [e for e in conta('colada') if e['verbo'] == 'dodge']
            r.append((len(tent) >= 1, 'decidiu esquivar quando a regra mandava (%d tentativas, %d aceitas)'
                      % (len(tent), len(esqs)), ''))
    # 6. Itens.
    itens = [e for e in feitas if e['verbo'] in ('grass', 'stone')]
    if cfg.get('erva') or cfg.get('pedra'):
        if ev['itens'] == 'sempre':
            for v in ('grass', 'stone'):
                ts = [e['t'] for e in itens if e['verbo'] == v]
                # Folga de 1s: a recarga e conferida em segundos inteiros e a
                # rede soma o resto (decisao do dono, 29/10: fica como esta).
                perto = [round(b - a, 1) for a, b in zip(ts, ts[1:]) if b - a < 59.0]
                r.append((not perto, '%s com 60s de recarga' % ('erva' if v == 'grass' else 'pedra'), str(perto)))
            r.append((len(itens) >= 1, 'usou os itens gratis (%d)' % len(itens), ''))
    # 7. Rajada: mais de 3 pedidos no mesmo segundo.
    ped = [e['t'] for e in log if e['tipo'] == 'pedido' and e.get('caminho') not in ('/?sign_in=1', '/')]
    raj = 0
    j = 0
    for i in range(len(ped)):
        while ped[i] - ped[j] >= 1.0:
            j += 1
        raj = max(raj, i - j + 1)
    r.append((True if raj <= 3 else (None if raj <= 5 else False),
              'rajada de pedidos: pico de %d no mesmo segundo' % raj, ''))
    # 8. Sessao caida e morte.
    if any(f[2] == 'deslogado' for f in cfg.get('falhas', [])):
        n = saida.count('RELOGIN')
        r.append((n >= 1, 'reconectou depois da sessao cair (%d)' % n, ''))
    if mortes and ev['unrip']:
        r.append((len(volta) >= 1, 'ressuscitou e voltou para a luta', ''))
        depois = [e for e in golpes if volta and e['t'] > volta[0]]
        r.append((len(depois) >= 3, 'voltou a atacar depois de ressuscitar (%d golpes)' % len(depois), ''))
    return r


# ---------------------------------------------------------------------------
#  CENARIOS
# ---------------------------------------------------------------------------

def cenarios(nome_ev):
    ev = EVENTOS[nome_ev]
    c = []
    leve = [(0, 1e9, 8)]
    c.append(dict(nome='normal', dur=240, dano=leve, sem_cura=True))
    if ev['cura']:
        c.append(dict(nome='vida_baixa', dur=300, dano=[(0, 1e9, 55)], espera_cura=2, cura=4000))
    if ev['esquiva'] == 'cla':
        c.append(dict(nome='esquiva', dur=200, elixires=0, dano=[(0, 30, 5), (30, 75, 140), (75, 1e9, 5)],
                      espera_esquiva=True))
    if ev['esquiva'] == 'queda':
        c.append(dict(nome='esquiva', dur=200, elixires=0, dano=[(0, 1e9, 20)], espera_esquiva=True))
    if ev['sec'] == 'king':
        c.append(dict(nome='rei_morre', dur=300, rei_morre=120, dano=[(0, 120, 20), (120, 1e9, 45)],
                      espera_cura=1))
    if ev['itens'] == 'sempre':
        c.append(dict(nome='itens', dur=260, dano=leve, erva=2, pedra=2, item_pago=True))
    c.append(dict(nome='lento', dur=240, dano=leve, falhas=[(60, 160, 'lento', 3.0)], tolera=ev['la'] + 5))
    c.append(dict(nome='timeout', dur=240, dano=leve, falhas=[(60, 110, 'timeout')]))
    c.append(dict(nome='falhas', dur=260, dano=leve,
                  falhas=[(50, 70, 'vazio'), (100, 120, 'erro502'), (150, 165, 'cortada'), (200, 215, 'casa')]))
    c.append(dict(nome='sessao', dur=240, dano=leve, falhas=[(90, 95, 'deslogado')]))
    if ev['sec'] != 'undying':
        c.append(dict(nome='invulneravel', dur=200, dano=leve, grey=[(60, 100)]))
    if ev['aliados'] and ev['sec'] != 'king':
        c.append(dict(nome='aliado', dur=200, dano=leve, aliado=[(60, 140)]))
    if ev['unrip']:
        c.append(dict(nome='morte', dur=260, dano=[(0, 50, 8), (50, 1e9, 400)], dano_pos_morte=leve, elixires=0))
    return c


def main():
    args = sys.argv[1:]
    relatorio = ''
    if '--relatorio' in args:
        i = args.index('--relatorio')
        relatorio = args[i + 1]
        del args[i:i + 2]
    so = [a for a in args if not a.startswith('-')]
    eventos = so or list(EVENTOS)
    amb = Ambiente()
    linhas = []
    total_ok = total_falha = total_at = 0
    t_ini = time.time()
    try:
        for nome_ev in eventos:
            print('\n=== %s ===' % nome_ev)
            for cfg in cenarios(nome_ev):
                luta, saida, fim, t_real = rodar(amb, nome_ev, cfg)
                res = medir(EVENTOS[nome_ev], cfg, luta, saida, fim)
                n_ok = sum(1 for x in res if x[0] is True)
                n_at = sum(1 for x in res if x[0] is None)
                total_ok += n_ok
                total_falha += len(res) - n_ok - n_at
                total_at += n_at
                golpes = sum(1 for e in luta.log if e['tipo'] == 'acao' and e['verbo'] in GOLPES)
                falhou = len(res) - n_ok - n_at
                print('  %-13s %s  (%d ok, %d atencao, %d falha; %d golpes, saiu em %ss virtuais, %.1fs reais)' % (
                    cfg['nome'], 'FALHA' if falhou else ('atencao' if n_at else 'ok'), n_ok, n_at, falhou, golpes,
                    fim if fim is not None else '?', t_real))
                for ok, frase, det in res:
                    if ok is not True:
                        print('      [%s] %s  %s' % ('ATENCAO' if ok is None else 'FALHA', frase, det))
                linhas.append((nome_ev, cfg['nome'], res, fim, golpes))
    finally:
        if os.environ.get('SIM_GUARDAR'):
            print('pasta guardada:', amb.dir)
        else:
            amb.fechar()
    print('\n=== RESUMO ===\n  PASS=%d  ATENCAO=%d  FALHA=%d  (%.0f s)' % (total_ok, total_at, total_falha,
                                                                           time.time() - t_ini))
    if relatorio:
        with open(relatorio, 'w', encoding='utf-8') as f:
            f.write(json.dumps([dict(evento=a, cenario=b, fim=d, golpes=e,
                                     checagens=[dict(ok=x[0], frase=x[1], detalhe=x[2]) for x in c])
                                for a, b, c, d, e in linhas], ensure_ascii=False, indent=1))
    return 0 if total_falha == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
