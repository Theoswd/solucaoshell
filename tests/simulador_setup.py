#!/usr/bin/env python3
"""Simulador do setup.sh: bateria de funcionamento de ponta a ponta.

Roda o setup.sh de verdade, num terminal de verdade (pty), contra um JOGO
FALSO local que imita o login, o /user, o perfil /user/ID/ e as paginas de
cla com a marcacao real do jogo (paginas capturadas em 29/10). Nada vai a
rede: um ~/.curlrc so do simulador manda furiadetitas.net e tiwar.ru para o
servidor local (connect-to), com um certificado proprio (cacert). O bot e o
mesmo do repositorio: so o lib/worker.sh da COPIA vira um duble que anota
com que modo subiu e fica parado como um sls.sh.

    Uso:  python3 tests/simulador_setup.py [ARQUIVO_DO_RELATORIO]

Precisa de python3, openssl, curl e git. Nao mexe no ~/.sls de verdade:
tudo acontece numa pasta temporaria, apagada no fim.

Cobre: menu, emoji no Termux, adicionar conta (senha com *, backspace,
espaco e simbolos; login errado; nomes recusados; servidor russo), listar,
testar login, modo de batalha (escolher contas, todas, normal; com o bot no
ar, reiniciar so a conta escolhida e o painel relancar no modo novo), o
play.sh subindo cada conta no modo salvo, aliados (adicionar por ID e por
link, listar, o worker resolver os nomes logado, sair do cla, remover),
remover conta com o bot no ar, atualizar repositorio e Ctrl+C na senha.
"""

import base64
import html
import http.server
import os
import pty
import re
import secrets
import select
import shutil
import signal
import ssl
import struct
import subprocess
import sys
import tempfile
import termios
import fcntl
import threading
import time
import urllib.parse

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ANSI = re.compile(r'\x1b\[[0-9;?]*[A-Za-z]')

# ---------------------------------------------------------------------------
#  JOGO FALSO
# ---------------------------------------------------------------------------

# Contas do jogo: (servidor, nome) -> senha, id, cla
CONTAS = {
    ('BR', 'Grimlock'):      {'senha': 's3nha forte&%', 'id': 473431,  'cla': 2092},
    ('BR', 'Abyssal Draco'): {'senha': 'draco123',      'id': 3386065, 'cla': 2092},
    ('RU', 'Ivan'):          {'senha': 'privet',        'id': 9001,    'cla': 5},
}
# Jogadores (com e sem conta no bot) por servidor: id -> [nome, cla]
JOGADORES = {
    'BR': {473431: ['Grimlock', 2092], 3386065: ['Abyssal Draco', 2092],
           555: ['Fulano Silva', 777], 556: ['Ciclano', 777], 600: ['Sem Cla', None]},
    'RU': {9001: ['Ivan', 5], 9002: ['Boris', 5]},
}
CLAS = {'BR': {2092: 'Abyssal Millennium', 777: 'Outro Cla'}, 'RU': {5: 'Medvedi'}}

SESSOES = {}          # sid -> (servidor, id)
PEDIDOS = []          # (servidor, metodo, caminho)
LOGINS = []           # (servidor, login, senha) recebidos no POST
TRAVA = threading.Lock()


def servidor_do_host(host):
    return 'RU' if 'tiwar' in (host or '') else 'BR'


def rodape(uid):
    return ("<div class='foot'><img src='/images/icon/level.png' alt=''/></div>"
            "<script>jsInterface.event(\"user=%d\");</script>" % uid) if uid else \
           "<script>jsInterface.event(\"user=0\");</script>"


def pagina_perfil(srv, pid, dono):
    nome, cla = JOGADORES[srv][pid]
    c = ("<img src='/images/icon/clan/1.png' alt=''/> <a href='/clan/%d'>%s</a>" %
         (cla, CLAS[srv][cla])) if cla else ''
    return ("<html><head><title>%s</title></head><body>"
            "<img src='/images/icon/race/1.png' alt=''/> <b>%s</b> "
            "<img src='/images/icon/level.png' alt=''/> 91 nível, Bóreas %s"
            "<a href='/user/%d?show=might'>Poder: 100</a>"
            "<img src='/user/%d/?show=avatar&h=x'/><a href='/user/%d/?show=faith'>fe</a>"
            "<b>Classificação no Coliseu</b> <b>40</b>%s</body></html>" %
            (html.escape(nome), html.escape(nome), c, pid, pid, pid, rodape(dono)))


def pagina_cla(srv, cid, dono):
    linhas = []
    for pid, (nome, cla) in sorted(JOGADORES[srv].items()):
        if cla == cid:
            linhas.append("<a href='/user/%d/'><img src='/images/icon/race/1.png' alt=''/>%s, "
                          "<span class='white'>Soldado</span><br/>" % (pid, html.escape(nome)))
    return ("<html><head><title>%s</title></head><body>%s%s</body></html>" %
            (html.escape(CLAS[srv].get(cid, 'Cla')), ''.join(linhas), rodape(dono)))


class Jogo(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _sessao(self):
        ck = self.headers.get('Cookie', '')
        m = re.search(r'sid=([0-9a-f]+)', ck)
        return SESSOES.get(m.group(1)) if m else None, ('pre=1' in ck)

    def _enviar(self, corpo, codigo=200, extra=None):
        dados = corpo.encode('utf-8')
        self.send_response(codigo)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(dados)))
        for k, v in (extra or []):
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(dados)

    def _login_pagina(self, extra=None):
        self._enviar("<html><title>Fúria de Titãs</title><form action='/?sign_in=1' method='post'>"
                     "<input name='login'/><input type='password' name='pass'/></form>%s</html>"
                     % rodape(0), extra=extra)

    def do_POST(self):
        srv = servidor_do_host(self.headers.get('Host'))
        with TRAVA:
            PEDIDOS.append((srv, 'POST', self.path))
        n = int(self.headers.get('Content-Length', 0))
        campos = urllib.parse.parse_qs(self.rfile.read(n).decode('utf-8'), keep_blank_values=True)
        login = campos.get('login', [''])[0]
        senha = campos.get('pass', [''])[0]
        with TRAVA:
            LOGINS.append((srv, login, senha))
        _, pre = self._sessao()
        conta = CONTAS.get((srv, login))
        # Como o jogo: vindo direto, sem passar pela pagina de login, recusa.
        if pre and conta and conta['senha'] == senha:
            sid = secrets.token_hex(8)
            SESSOES[sid] = (srv, conta['id'])
            self.send_response(302)
            self.send_header('Location', '/')
            self.send_header('Set-Cookie', 'sid=%s; Path=/' % sid)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        self._login_pagina()

    def do_GET(self):
        srv = servidor_do_host(self.headers.get('Host'))
        with TRAVA:
            PEDIDOS.append((srv, 'GET', self.path))
        sess, _ = self._sessao()
        dono = sess[1] if sess and sess[0] == srv else 0
        caminho = self.path.split('?')[0]
        if self.path.startswith('/?sign_in=1'):
            return self._login_pagina(extra=[('Set-Cookie', 'pre=1; Path=/')])
        if not dono:
            # Visitante: qualquer perfil e um 404 (como no jogo).
            return self._enviar("<html><title>Error 404: Page not found</title>%s</html>" % rodape(0), 404)
        m = re.match(r'^/user/?$', caminho)
        if m:
            return self._enviar(pagina_perfil(srv, dono, dono))
        m = re.match(r'^/user/(\d+)/?$', caminho)
        if m:
            pid = int(m.group(1))
            # ID que nao existe: o jogo mostra o perfil da PROPRIA conta.
            return self._enviar(pagina_perfil(srv, pid if pid in JOGADORES[srv] else dono, dono))
        if caminho in ('/clan', '/clan/'):
            cla = JOGADORES[srv][dono][1]
            return self._enviar("<html><a href='/clan/%d/'>Meu cla</a>%s</html>" % (cla, rodape(dono))
                                if cla else "<html>Sem cla%s</html>" % rodape(dono))
        m = re.match(r'^/clan/(\d+)(//\d+)?/?$', caminho)
        if m:
            return self._enviar(pagina_cla(srv, int(m.group(1)), dono))
        return self._enviar("<html><title>Inicio</title>%s</html>" % rodape(dono))


class JogoTLS(http.server.ThreadingHTTPServer):
    daemon_threads = True


# ---------------------------------------------------------------------------
#  AMBIENTE
# ---------------------------------------------------------------------------

def sh(cmd, **kw):
    return subprocess.run(cmd, shell=True, check=True, capture_output=True, text=True, **kw).stdout


class Ambiente:
    def __init__(self):
        self.dir = tempfile.mkdtemp(prefix='sls_sim_')
        self.home = os.path.join(self.dir, 'home')
        self.curl = os.path.join(self.dir, 'curl')
        self.bot = os.path.join(self.home, 'solucaoshell')
        self.origem = os.path.join(self.dir, 'origem.git')
        os.makedirs(self.home)
        os.makedirs(self.curl)
        self._certificados()
        self._servidor()
        self._bot()

    def _certificados(self):
        d = self.dir
        sh("openssl req -x509 -newkey rsa:2048 -nodes -keyout %s/ca.key -out %s/ca.pem -days 2 "
           "-subj /CN=sls-simulador -addext basicConstraints=critical,CA:TRUE "
           "-addext keyUsage=critical,keyCertSign,cRLSign" % (d, d))
        with open(d + '/ext.cnf', 'w') as f:
            f.write("subjectAltName=DNS:furiadetitas.net,DNS:tiwar.ru\nbasicConstraints=CA:FALSE\n")
        sh("openssl req -newkey rsa:2048 -nodes -keyout %s/srv.key -out %s/srv.csr -subj /CN=furiadetitas.net"
           % (d, d))
        sh("openssl x509 -req -in %s/srv.csr -CA %s/ca.pem -CAkey %s/ca.key -CAcreateserial "
           "-out %s/srv.pem -days 2 -extfile %s/ext.cnf" % (d, d, d, d, d))

    def _servidor(self):
        self.http = JogoTLS(('127.0.0.1', 0), Jogo)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(self.dir + '/srv.pem', self.dir + '/srv.key')
        self.http.socket = ctx.wrap_socket(self.http.socket, server_side=True)
        porta = self.http.server_address[1]
        threading.Thread(target=self.http.serve_forever, daemon=True).start()
        with open(self.curl + '/.curlrc', 'w') as f:
            f.write('cacert = "%s/ca.pem"\n' % self.dir)
            for host in ('furiadetitas.net', 'tiwar.ru'):
                f.write('connect-to = "%s:443:127.0.0.1:%d"\n' % (host, porta))
            f.write('noproxy = "furiadetitas.net,tiwar.ru,127.0.0.1"\n')

    def _bot(self):
        # Copia o repositorio como esta agora (inclusive mudancas nao
        # commitadas) para um "GitHub" local, e clona dele o bot.
        # (O clone do repositorio pode ser raso: um repositorio novo com os
        # arquivos de agora, e nao um clone, vai para o "GitHub".)
        sh("git init -q --bare %s" % self.origem)
        tmp = os.path.join(self.dir, 'semente')
        shutil.copytree(RAIZ, tmp, ignore=shutil.ignore_patterns('.git', 'accounts.conf'))
        sh("cd %s && git init -q && git add -A && "
           "git -c user.email=s@s -c user.name=sim commit -qm semente && "
           "git push -q %s HEAD:refs/heads/main" % (tmp, self.origem))
        sh("git -C %s symbolic-ref HEAD refs/heads/main" % self.origem)
        sh("git clone -q %s %s" % (self.origem, self.bot))
        shutil.rmtree(tmp)
        duble = os.path.join(self.bot, 'lib', 'worker.sh')
        with open(duble, 'w') as f:
            f.write('''#!/bin/sh
# DUBLE do simulador: anota com que modo subiu e fica parado como um sls.sh.
SLS_ACC_DIR="$5"; SLS_STATUS_FILE="$6"; RUN="${7:--boot}"
LIBDIR=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$SLS_ACC_DIR"
echo "$$" > "${SLS_STATUS_FILE%.status}.pid"
echo running > "$SLS_STATUS_FILE"
printf '%s %s\\n' "$$" "$RUN" >> "$SLS_ACC_DIR/simulador_subidas"
exec sh -c 'trap "exit 0" TERM INT; while :; do sleep 1; done' "$LIBDIR/sls.sh" "$RUN" "$SLS_ACC_DIR"
''')
        os.chmod(duble, 0o755)

    def env(self, **extra):
        e = {
            'HOME': self.home, 'CURL_HOME': self.curl, 'TERM': 'xterm-256color',
            'LANG': 'C.UTF-8', 'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
            'NO_PROXY': 'furiadetitas.net,tiwar.ru,127.0.0.1',
            'no_proxy': 'furiadetitas.net,tiwar.ru,127.0.0.1',
        }
        for k in ('HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy'):
            if k in os.environ:
                e[k] = os.environ[k]
        e.update(extra)
        return {k: v for k, v in e.items() if v is not None}

    def fechar(self):
        try:
            subprocess.run(['sh', self.bot + '/stop.sh'], env=self.env(), capture_output=True, timeout=30)
        except Exception:
            pass
        self.http.shutdown()
        shutil.rmtree(self.dir, ignore_errors=True)


# ---------------------------------------------------------------------------
#  TERMINAL
# ---------------------------------------------------------------------------

class Terminal:
    """Um processo num pty, com espera por texto (como o 'expect')."""

    def __init__(self, amb, cmd, env, cols=44):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(amb.bot)
            os.execvpe('sh', ['sh', '-c', cmd], env)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack('HHHH', 40, cols, 0, 0))
        self.bruto = b''
        self.marca = 0

    def _ler(self, prazo):
        fim = time.time() + prazo
        while time.time() < fim:
            r, _, _ = select.select([self.fd], [], [], 0.05)
            if r:
                try:
                    d = os.read(self.fd, 65536)
                except OSError:
                    return False
                if not d:
                    return False
                self.bruto += d
                return True
        return True

    @property
    def texto(self):
        return ANSI.sub('', self.bruto.decode('utf-8', 'replace'))

    def esperar(self, alvo, prazo=20):
        """Espera 'alvo' (texto ou regex compilada) depois da ultima marca."""
        fim = time.time() + prazo
        while True:
            t = self.texto[self.marca:]
            m = alvo.search(t) if hasattr(alvo, 'search') else (t.find(alvo) >= 0 and alvo)
            if m:
                fim_m = (self.marca + m.end()) if hasattr(m, 'end') else (self.marca + t.find(alvo) + len(alvo))
                trecho = t[:fim_m - self.marca]
                self.marca = fim_m
                return trecho
            if time.time() > fim or not self._ler(min(0.3, max(0.01, fim - time.time()))):
                if time.time() > fim:
                    raise TimeoutError('nao apareceu: %r\n--- tela ---\n%s' % (alvo, t[-1500:]))

    def mandar(self, s):
        os.write(self.fd, s.encode('utf-8') if isinstance(s, str) else s)

    def linha(self, s=''):
        self.mandar(s + '\n')

    def fechar(self):
        try:
            os.kill(self.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(self.pid, 0)
        except ChildProcessError:
            pass
        try:
            os.close(self.fd)
        except OSError:
            pass


# ---------------------------------------------------------------------------
#  BATERIA
# ---------------------------------------------------------------------------

RESULTADOS = []


def checar(nome, cond, detalhe=''):
    RESULTADOS.append((bool(cond), nome, detalhe))
    print('  [%s] %s%s' % ('PASS' if cond else 'FALHA', nome, ('  -- ' + detalhe) if (detalhe and not cond) else ''))


def secao(t):
    print('\n=== %s ===' % t)


def ler(p, padrao=''):
    try:
        with open(p, encoding='utf-8') as f:
            return f.read()
    except OSError:
        return padrao


def subidas(amb, conta):
    """[(pid, modo), ...] que o duble do worker anotou para a conta."""
    t = ler(os.path.join(amb.home, '.sls', conta, 'simulador_subidas'))
    return [tuple(l.split()) for l in t.splitlines() if l.strip()]


def vivo(pid):
    try:
        with open('/proc/%s/stat' % pid) as f:
            return f.read().split(') ')[-1].split()[0] != 'Z'
    except OSError:
        return False


def esperar_ate(cond, prazo):
    fim = time.time() + prazo
    while time.time() < fim:
        if cond():
            return True
        time.sleep(0.5)
    return cond()


def setup(amb, **env):
    return Terminal(amb, './setup.sh', amb.env(**env))


def bateria(amb):
    sls = os.path.join(amb.home, '.sls')
    conf = os.path.join(amb.bot, 'accounts.conf')

    # ---------------------------------------------------------------- emoji
    secao('1. Primeira abertura no Termux: pergunta do emoji')
    t = setup(amb, PREFIX='/data/data/com.termux/files/usr')
    tela = t.esperar('(s/n): ')
    checar('mostra os emoji de teste e pergunta s/n', 'Teste de emoji:  🔱  💀  🔥  ✅' in tela)
    t.linha('s')
    tela = t.esperar('Opcao:')
    checar("'s' liga o emoji: titulo com 🔱", '🔱 SLS - Gerenciador de Contas' in tela)
    checar('grava 1 em ~/.sls/emoji', ler(sls + '/emoji').strip() == '1')
    t.linha('0'); t.esperar('Saindo'); t.fechar()
    t = setup(amb, PREFIX='/data/data/com.termux/files/usr')
    tela = t.esperar('Opcao:')
    checar('segunda abertura nao pergunta de novo', 'Teste de emoji' not in tela)
    t.linha('0'); t.fechar()
    with open(sls + '/emoji', 'w') as f:
        f.write('2\n')
    t = setup(amb, PREFIX='/data/data/com.termux/files/usr')
    tela = t.esperar('Opcao:')
    checar('com simbolos (2): menu sem emoji', '🔱' not in tela and 'SLS - Gerenciador de Contas' in tela)
    t.linha('0'); t.fechar()
    os.remove(sls + '/emoji')

    # ---------------------------------------------------------------- menu
    secao('2. Menu principal')
    t = setup(amb)
    tela = t.esperar('Opcao:')
    for l in ('SLS - Gerenciador de Contas', '1 - Listar Contas', '2 - Adicionar Conta',
              '3 - Remover Contas', '4 - Testar Login', '5 - Atualizar Repositorio',
              '6 - Modo de Batalha', '7 - Adicionar Aliados', '0 - Sair'):
        checar('menu: ' + l, l in tela)
    # Titulo centralizado: 44 colunas.
    lt = [l for l in tela.splitlines() if 'Gerenciador' in l][0]
    esq = len(lt) - len(lt.lstrip(' '))
    checar('titulo centralizado (sobra igual dos dois lados, +-1)', abs(esq - (44 - len(lt.strip()) - esq)) <= 1,
           repr(lt))

    # ---------------------------------------------------------------- adicionar
    secao('3. Adicionar conta')
    t.linha('2')
    tela = t.esperar('Servidor [1]: ')
    checar('tela Adicionar Conta com servidores por extenso',
           'Adicionar Conta' in tela and '1 - Servidor Brasileiro' in tela and '2 - Servidor Russo' in tela)
    t.linha('')
    t.esperar('Usuario (furiadetitas.net): ')
    t.linha('Grimlock')
    t.esperar('Senha: ')
    # Digita com um erro e apaga: "s3nha fortX" <backspace> "e&%"
    t.mandar('s3nha fortX'); time.sleep(0.4)
    t.mandar('\x7f'); time.sleep(0.2)
    t.mandar('e&%'); time.sleep(0.3)
    for _ in range(5):
        t._ler(0.2)
    # (O setup desliga o eco ANTES do "Senha: ": nem digitando ou colando
    # na hora a senha aparece.)
    eco = t.bruto.decode('utf-8', 'replace').split('Senha: ')[-1]
    checar('senha aparece como * (11 + backspace + 3)', eco.startswith('*' * 11 + '\b \b' + '***'), repr(eco[:30]))
    checar('a senha em si nao aparece na tela', 'fort' not in eco)
    t.linha('')
    tela = t.esperar('Opcao:', 30)
    checar('login confirmado e conta adicionada', 'Conta [BR] Grimlock adicionada!' in tela, tela[-400:])
    checar('mostra o nome com que o jogo recebeu a conta', 'Logado no jogo como: Grimlock' in tela)
    checar('bot parado: diz para rodar o ./play.sh', 'Para comecar a jogar: ./play.sh' in tela)
    checar('o jogo recebeu a senha exata (espaco, & e %)', ('BR', 'Grimlock', 's3nha forte&%') in LOGINS)
    linha = [l for l in ler(conf).splitlines() if l.startswith('1|Grimlock|')]
    dec = base64.b64decode(linha[0].split('|', 2)[2]).decode() if linha else ''
    checar('accounts.conf guarda login e senha certos', dec == 'login=Grimlock&pass=s3nha forte&%', dec)
    checar('accounts.conf com permissao 600', oct(os.stat(conf).st_mode & 0o777) == '0o600')

    # Senha errada: nao salva com "n".
    t.linha('2'); t.esperar('Servidor [1]: '); t.linha('1')
    t.esperar('Usuario'); t.linha('Abyssal Draco')
    t.esperar('Senha: '); t.linha('errada')
    tela = t.esperar('(y/n): ', 30)
    checar('senha errada: login nao confirmado, pergunta se salva', 'Login nao confirmado' in tela)
    t.linha('n')
    tela = t.esperar('Opcao:')
    checar("'n': conta nao salva", 'Conta nao salva' in tela and 'Abyssal Draco' not in ler(conf))
    # Agora certa (nome com espaco).
    t.linha('2'); t.esperar('Servidor [1]: '); t.linha('1')
    t.esperar('Usuario'); t.linha('Abyssal Draco')
    t.esperar('Senha: '); t.linha('draco123')
    tela = t.esperar('Opcao:', 30)
    checar('nome com espaco adicionado', 'Conta [BR] Abyssal Draco adicionada!' in tela and
           'Logado no jogo como: Abyssal Draco' in tela)
    # Recusas.
    for nome, msg in (('a|b', 'Nome nao pode conter |'), ('a/b', 'Nome nao pode conter /'),
                      ('', 'Usuario vazio'), ('Grimlock', 'Conta [BR] Grimlock ja existe')):
        t.linha('2'); t.esperar('Servidor [1]: '); t.linha('1')
        t.esperar('Usuario'); t.linha(nome)
        tela = t.esperar('Opcao:')
        checar('recusa nome %r' % nome, msg in tela)
    t.linha('2'); t.esperar('Servidor [1]: '); t.linha('9')
    tela = t.esperar('Opcao:')
    checar('recusa servidor 9', 'Servidor invalido: 9' in tela)
    # Servidor russo.
    t.linha('2'); t.esperar('Servidor [1]: '); t.linha('2')
    t.esperar('Usuario (tiwar.ru): '); t.linha('Ivan')
    t.esperar('Senha: '); t.linha('privet')
    tela = t.esperar('Opcao:', 30)
    checar('conta do servidor russo adicionada', 'Conta [RU] Ivan adicionada!' in tela and
           'Logado no jogo como: Ivan' in tela)
    checar('o login russo foi para o servidor russo', ('RU', 'Ivan', 'privet') in LOGINS)

    # ---------------------------------------------------------------- listar / testar
    secao('4. Listar contas e testar login')
    t.linha('1')
    tela = t.esperar('ENTER para voltar...')
    checar('lista as 3 contas com servidor', all(x in tela for x in
           ('[BR] Grimlock', '[BR] Abyssal Draco', '[RU] Ivan')))
    t.linha(); t.esperar('Opcao:')
    t.linha('4')
    tela = t.esperar('Numero (0 = cancelar): ')
    checar('testar login lista as contas numeradas', '2) [BR] Abyssal Draco' in tela)
    t.linha('2')
    tela = t.esperar('ENTER para voltar...', 30)
    checar('testar login: confirmado e com o nome do jogo',
           'Login confirmado' in tela and 'Logado no jogo como: Abyssal Draco' in tela)
    t.linha(); t.esperar('Opcao:')
    t.linha('4'); t.esperar('Numero'); t.linha('0')
    t.esperar('Opcao:')
    checar('testar login: 0 cancela', True)

    # ---------------------------------------------------------------- modo (bot parado)
    secao('5. Modo de batalha com o bot parado')
    t.linha('6')
    tela = t.esperar('Opcao:')
    checar('submenu: Caverna, Coliseu, Normal', all(x in tela for x in
           ('Modo de Batalha', '1 - Caverna', '2 - Coliseu', '3 - Normal')))
    t.linha('1')
    tela = t.esperar('Opcao:')
    checar('Caverna: escolher contas ou todas', '1 - Escolher contas' in tela and '2 - Definir para todas' in tela)
    t.linha('1')
    tela = t.esperar('(0 = cancelar): ')
    checar('lista as contas com o modo atual', '1) [BR] Grimlock' in tela and 'Normal' in tela)
    t.linha('1 3')
    tela = t.esperar('ENTER para voltar...')
    checar('Caverna nas contas 1 e 3', '[BR] Grimlock: Normal -> Caverna' in tela and
           '[RU] Ivan: Normal -> Caverna' in tela and 'Abyssal Draco:' not in tela)
    checar('bot parado: vale quando o bot subir', 'Vale quando o bot subir' in tela)
    t.linha(); t.esperar('Opcao:')
    t.linha('2'); t.esperar('Opcao:'); t.linha('2')
    tela = t.esperar('ENTER para voltar...')
    checar('Coliseu para todas', tela.count('-> Coliseu') == 3)
    t.linha(); t.esperar('Opcao:')
    t.linha('3'); t.esperar('Opcao:'); t.linha('1'); t.esperar('(0 = cancelar): '); t.linha('3')
    tela = t.esperar('ENTER para voltar...')
    checar('Normal na conta 3', '[RU] Ivan: Coliseu -> Normal' in tela)
    t.linha(); t.esperar('Opcao:')
    t.linha('1'); t.esperar('Opcao:'); t.linha('1'); t.esperar('(0 = cancelar): '); t.linha('9')
    tela = t.esperar('Opcao:')
    checar('numero que nao existe e recusado', 'Numero invalido' in tela)
    t.linha('0'); t.esperar('Opcao:')
    t.linha('0'); t.esperar('Opcao:')
    checar('arquivos: Grimlock e Draco em -cl, Ivan sem modo',
           ler(sls + '/BR_Grimlock/modo_batalha').strip() == '-cl' and
           ler(sls + '/BR_Abyssal Draco/modo_batalha').strip() == '-cl' and
           not os.path.exists(sls + '/RU_Ivan/modo_batalha'))
    t.linha('1')
    tela = t.esperar('ENTER para voltar...')
    checar('lista de contas mostra o modo', '(Coliseu)' in tela and 'tiwar.ru (' not in tela)
    t.linha(); t.esperar('Opcao:')
    t.linha('0'); t.fechar()

    # ---------------------------------------------------------------- play.sh
    secao('6. play.sh sobe cada conta no modo salvo')
    bot = Terminal(amb, './play.sh', amb.env(), cols=100)
    ok = esperar_ate(lambda: all(subidas(amb, c) for c in ('BR_Grimlock', 'BR_Abyssal Draco', 'RU_Ivan')), 90)
    checar('as 3 contas subiram', ok)
    checar('Grimlock e Draco em -cl, Ivan no normal (-boot)',
           [s[1] for s in subidas(amb, 'BR_Grimlock')] == ['-cl'] and
           [s[1] for s in subidas(amb, 'BR_Abyssal Draco')] == ['-cl'] and
           [s[1] for s in subidas(amb, 'RU_Ivan')] == ['-boot'],
           str([subidas(amb, c) for c in ('BR_Grimlock', 'BR_Abyssal Draco', 'RU_Ivan')]))

    # ---------------------------------------------------------------- modo com o bot no ar
    secao('7. Modo de batalha com o bot no ar')
    pid_draco = subidas(amb, 'BR_Abyssal Draco')[-1][0]
    pid_grim = subidas(amb, 'BR_Grimlock')[-1][0]
    t = setup(amb)
    t.esperar('Opcao:')
    t.linha('6'); t.esperar('Opcao:'); t.linha('1'); t.esperar('Opcao:'); t.linha('1')
    t.esperar('(0 = cancelar): '); t.linha('2')
    tela = t.esperar('(y/n): ')
    checar('bot no ar: oferece reiniciar so a conta que mudou', 'Reiniciar 1 conta(s) agora' in tela)
    t.linha('y')
    tela = t.esperar('ENTER para voltar...')
    checar('avisa que reinicia', 'Reiniciando' in tela)
    ok = esperar_ate(lambda: len(subidas(amb, 'BR_Abyssal Draco')) >= 2, 90)
    checar('o painel relancou a conta', ok)
    checar('a conta voltou no modo novo (-cv)', subidas(amb, 'BR_Abyssal Draco')[-1][1] == '-cv',
           str(subidas(amb, 'BR_Abyssal Draco')))
    checar('o worker antigo morreu', not vivo(pid_draco))
    checar('a outra conta nao foi mexida', vivo(pid_grim) and len(subidas(amb, 'BR_Grimlock')) == 1)
    t.linha(); t.esperar('Opcao:'); t.linha('0'); t.esperar('Opcao:')

    # ---------------------------------------------------------------- aliados
    secao('8. Aliados: menu do setup')
    n_pedidos = len(PEDIDOS)
    t.linha('7')
    tela = t.esperar('Opcao:')
    checar('submenu de aliados', all(x in tela for x in
           ('Adicionar Aliados', '1 - Adicionar jogador (ID)', '2 - Adicionar cla (ID)',
            '3 - Listar aliados', '4 - Remover aliado')))
    for entrada, ok_esp in (('https://furiadetitas.net/user/600/', 'jogador 600 adicionado'),
                            ('99999999', 'jogador 99999999 adicionado'),
                            ('https://furiadetitas.net/clan/777', 'Esse e o link de um cla'),
                            ('600', 'ja esta na lista'),
                            ('12ab', 'ID invalido')):
        t.linha('1'); t.esperar('Servidor [1]: '); t.linha('1'); t.esperar('(ex.: ')
        t.linha(entrada)
        tela = t.esperar('Opcao:', 20) if 'adicionado' not in ok_esp else t.esperar('ENTER para voltar...')
        checar('jogador %r -> %s' % (entrada, ok_esp), ok_esp in tela, tela[-300:])
        if 'adicionado' in ok_esp:
            t.linha(); t.esperar('Opcao:')
    t.linha('2'); t.esperar('Servidor [1]: '); t.linha(''); t.esperar('(ex.: '); t.linha('777')
    tela = t.esperar('ENTER para voltar...')
    checar('cla 777 adicionado', 'cla 777 adicionado ao servidor Brasileiro' in tela)
    t.linha(); t.esperar('Opcao:')
    t.linha('2'); t.esperar('Servidor [1]: '); t.linha('2'); t.esperar('(ex.: '); t.linha('5')
    t.esperar('ENTER para voltar...'); t.linha(); t.esperar('Opcao:')
    checar('lista do BR: j|600, j|99999999, c|777',
           ler(sls + '/aliados_BR.conf').split() == ['j|600', 'j|99999999', 'c|777'])
    checar('lista do RU separada: c|5', ler(sls + '/aliados_RU.conf').split() == ['c|5'])
    checar('o setup nao fez login nem pediu pagina ao cadastrar', len(PEDIDOS) == n_pedidos)
    t.linha('3')
    tela = t.esperar('ENTER para voltar...')
    checar('listar antes do bot: aguardando o bot', tela.count('aguardando o bot') == 4, tela[-500:])
    t.linha(); t.esperar('Opcao:')

    # ---------------------------------------------------------------- aliados no worker
    secao('9. Aliados: o worker resolve os IDs logado (curl de verdade)')
    def montar(conta, tag, usuario, senha):
        # Como o worker: login com o cookie da conta e o aliados_montar com
        # o fetch_page de verdade (curl), o clan_id e o crono.sh.
        cmd = (
            'TMP="$HOME/.sls/%s"; mkdir -p "$TMP"; URL="https://%s"; SLS_TAG=%s; '
            'SLS_PACING=0; TMP_COOKIE="$TMP/cookie.sim"; export TMP URL SLS_TAG SLS_PACING TMP_COOKIE; '
            'LIBDIR="$PWD/lib"; . lib/info.sh >/dev/null 2>&1; . lib/session_check.sh; '
            '. lib/crono.sh >/dev/null 2>&1; . lib/clanid.sh >/dev/null 2>&1; . lib/allies.sh; '
            # Login como o do bot, guardando o cookie (o test_login apaga o dele).
            'curl -sS -c "$TMP_COOKIE" -b "$TMP_COOKIE" "$URL/?sign_in=1" >/dev/null; '
            'printf %%s "%s" | curl -sS -L -c "$TMP_COOKIE" -b "$TMP_COOKIE" '
            '--data-urlencode "login=%s" --data-urlencode "pass@-" "$URL/?sign_in=1" >/dev/null; '
            'rm -f "$TMP/CLD" "$TMP/last_clan_id"; CLD=; '
            'aliados_montar 1 >/dev/null; echo @@; cat "$TMP/allies.txt"'
        ) % (conta, 'tiwar.ru' if tag == 'RU' else 'furiadetitas.net', tag, senha, usuario)
        r = subprocess.run(['sh', '-c', cmd], cwd=amb.bot, env=amb.env(), capture_output=True, text=True,
                           timeout=120)
        montar.saida = (r.stdout + r.stderr)[-600:]
        return r.stdout.split('@@', 1)[-1].split()
    nomes = montar('BR_Grimlock', 'BR', 'Grimlock', 's3nha forte&%')
    checar('cla da conta + jogador 600 + membros do cla 777',
           nomes == ['Abyssal_Draco', 'Ciclano', 'Fulano_Silva', 'Grimlock', 'Sem_Cla'],
           str(nomes) + ' | ' + montar.saida + ' | ' + str(PEDIDOS[n_pedidos:][-12:]))
    checar('ID 99999999 (nao existe) anotado como nao encontrado',
           'j|99999999|-' in ler(sls + '/aliados_BR.nomes'))
    n = len(PEDIDOS)
    nomes2 = montar('BR_Abyssal Draco', 'BR', 'Abyssal Draco', 'draco123')
    perfis = [p for p in PEDIDOS[n:] if re.match(r'^/user/\d+/', p[2])]
    checar('a outra conta BR reusa os nomes (nao pede os perfis de novo)', nomes2 == nomes and not perfis,
           str(perfis))
    nomes_ru = montar('RU_Ivan', 'RU', 'Ivan', 'privet')
    checar('conta RU: so a lista russa (cla 5)', nomes_ru == ['Boris', 'Ivan'], str(nomes_ru))
    t.linha('3')
    tela = t.esperar('ENTER para voltar...')
    checar('listar: nome do jogador', re.search(r'Jogador 600 +Sem Cla', tela) is not None)
    checar('listar: ID nao encontrado', re.search(r'Jogador 99999999 +ID nao encontrado', tela) is not None)
    checar('listar: membros do cla', re.search(r'Cla +777 +2 membro\(s\)', tela) is not None)
    t.linha(); t.esperar('Opcao:')
    # Draco sai do cla 2092 e nao esta na lista: vira inimigo.
    JOGADORES['BR'][3386065][1] = None
    nomes3 = montar('BR_Grimlock', 'BR', 'Grimlock', 's3nha forte&%')
    checar('quem saiu do cla (e nao esta na lista) deixa de ser aliado, o resto fica',
           'Abyssal_Draco' not in nomes3 and 'Grimlock' in nomes3 and 'Sem_Cla' in nomes3,
           str(nomes3))
    JOGADORES['BR'][3386065][1] = 2092
    # Remover o jogador 600.
    t.linha('4'); t.esperar('Servidor [1]: '); t.linha('1')
    tela = t.esperar('(0 = cancelar): ')
    t.linha('1'); t.esperar('(y/n): '); t.linha('y')
    tela = t.esperar('Opcao:')
    checar('remover aliado', 'Removido' in tela and ler(sls + '/aliados_BR.conf').split() == ['j|99999999', 'c|777'])
    nomes4 = montar('BR_Grimlock', 'BR', 'Grimlock', 's3nha forte&%')
    checar('removido sai da lista do worker, o resto fica',
           'Sem_Cla' not in nomes4 and 'Fulano_Silva' in nomes4 and 'Grimlock' in nomes4, str(nomes4))
    t.linha('0'); t.esperar('Opcao:')

    # ---------------------------------------------------------------- remover conta
    secao('10. Remover conta com o bot no ar')
    pid_ivan = subidas(amb, 'RU_Ivan')[-1][0]
    t.linha('3')
    t.esperar('(0 = cancelar): '); t.linha('3')
    t.esperar('Remover [RU] Ivan? (y/n): '); t.linha('y')
    tela = t.esperar('(y/n): '); t.linha('y')
    tela += t.esperar('Opcao:')
    checar('conta removida e dados apagados', 'Removida' in tela and 'Ivan' not in ler(conf) and
           not os.path.exists(sls + '/RU_Ivan'),
           'removida=%s conf=%s pasta=%s %s' % ('Removida' in tela, 'Ivan' in ler(conf),
                                               os.path.exists(sls + '/RU_Ivan'),
                                               os.listdir(sls + '/RU_Ivan') if os.path.exists(sls + '/RU_Ivan') else ''))
    checar('o worker dela parou', esperar_ate(lambda: not vivo(pid_ivan), 15))
    time.sleep(12)
    checar('o painel nao relancou a conta removida', not os.path.exists(sls + '/RU_Ivan/simulador_subidas'))

    # ---------------------------------------------------------------- atualizar
    secao('11. Atualizar repositorio')
    pid_grim = subidas(amb, 'BR_Grimlock')[-1][0]
    t.linha('5')
    tela = t.esperar('Opcao:')
    checar('submenu Atualizar com git pull pelo setup', 'Atualizar Repositorio' in tela and
           '1 - git pull pelo setup' in tela)
    t.linha('1')
    tela = t.esperar('Opcao:', 30)
    checar('sem nada novo: avisa e nao para o bot', 'Ja esta na versao mais nova' in tela and vivo(pid_grim))
    # Uma atualizacao nova no "GitHub".
    outro = os.path.join(amb.dir, 'dev')
    sh("git clone -q %s %s && cd %s && echo '<!-- simulador -->' >> README.md && "
       "git -c user.email=s@s -c user.name=sim commit -qam 'Simulador: atualizacao de teste (9.9.9)' && "
       "git push -q origin HEAD:main" % (amb.origem, outro, outro))
    t.linha('1')
    tela = t.esperar('Subindo o bot...', 60)
    checar('mostra a atualizacao nova', '1 atualizacao(oes)' in tela and 'Simulador: atualizacao de teste' in tela)
    checar('para o bot e atualiza', 'Parando o bot' in tela and 'Repositorio atualizado' in tela)
    checar('o git pull trouxe a mudanca', '<!-- simulador -->' in ler(amb.bot + '/README.md'))
    checar('o bot antigo parou', esperar_ate(lambda: not vivo(pid_grim), 15))
    ok = esperar_ate(lambda: len(subidas(amb, 'BR_Grimlock')) >= 2 and len(subidas(amb, 'BR_Abyssal Draco')) >= 3, 90)
    checar('o play.sh subiu de novo as contas', ok, str([subidas(amb, c) for c in ('BR_Grimlock', 'BR_Abyssal Draco')]))
    checar('cada conta voltou no modo salvo (Grimlock -cl, Draco -cv)',
           subidas(amb, 'BR_Grimlock')[-1][1] == '-cl' and subidas(amb, 'BR_Abyssal Draco')[-1][1] == '-cv')
    t.fechar()
    bot.fechar()
    subprocess.run(['sh', amb.bot + '/stop.sh'], env=amb.env(), capture_output=True, timeout=30)

    # ---------------------------------------------------------------- ctrl+c
    secao('12. Ctrl+C na senha devolve o terminal')
    # O shell de fora so desvia o SIGINT (um "trap ''" seria herdado e o
    # setup nao poderia tratar o Ctrl+C); o stty -a roda depois do setup.
    t = Terminal(amb, "trap ':' INT; ./setup.sh; stty -a", amb.env())
    t.esperar('Opcao:'); t.linha('2'); t.esperar('Servidor [1]: '); t.linha('1')
    t.esperar('Usuario'); t.linha('Teste'); t.esperar('Senha: ')
    t.mandar('abc'); time.sleep(0.3); t.mandar('\x03')
    t.esperar('speed', 15); t._ler(1); t._ler(1)
    estado = t.texto[t.texto.rfind('speed'):]
    checar('depois do Ctrl+C: eco ligado', re.search(r'(^|\s)echo(\s|$)', estado) is not None, estado[:300])
    checar('depois do Ctrl+C: icanon ligado', re.search(r'(^|\s)icanon(\s|$)', estado) is not None)
    checar('a conta nao foi salva', 'Teste' not in ler(conf))
    t.fechar()


def main():
    relatorio = sys.argv[1] if len(sys.argv) > 1 else ''
    for prog in ('openssl', 'curl', 'git'):
        if not shutil.which(prog):
            print('falta o %s' % prog)
            return 2
    amb = Ambiente()
    inicio = time.time()
    erro = ''
    try:
        bateria(amb)
    except Exception as e:  # noqa: BLE001 - o relatorio mostra onde parou
        erro = '%s: %s' % (type(e).__name__, e)
        checar('a bateria chegou ao fim', False, erro)
    finally:
        amb.fechar()
    ok = sum(1 for r in RESULTADOS if r[0])
    falha = len(RESULTADOS) - ok
    print('\n=== RESUMO ===\n  PASS=%d  FALHA=%d  (%.0f s)' % (ok, falha, time.time() - inicio))
    if relatorio:
        with open(relatorio, 'w', encoding='utf-8') as f:
            f.write('# Simulador do setup.sh\n\nPASS=%d  FALHA=%d\n\n' % (ok, falha))
            for r in RESULTADOS:
                f.write('- [%s] %s%s\n' % ('PASS' if r[0] else 'FALHA', r[1], (' — ' + r[2]) if (r[2] and not r[0]) else ''))
    return 0 if falha == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
