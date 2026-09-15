# solucaoshell

| Aparelho | App |
|---|---|
| Android | [Termux (F-Droid)](https://f-droid.org/packages/com.termux/) — a versão da Play Store não funciona |
| Windows | WSL — Ubuntu (os comandos rodam **dentro do Ubuntu**, não no PowerShell) |
| iPhone / iPad | iSH |

O bot fica sempre na pasta **`~/solucaoshell`**. Os dados das contas ficam em **`~/.sls`**.

---

## 1. Instalar

### Termux

```bash
pkg update && pkg upgrade -y
```

```bash
pkg install git curl util-linux coreutils procps -y
```

```bash
cd ~ && git clone https://github.com/Theoswd/solucaoshell.git
```

```bash
chmod +x ~/solucaoshell/*.sh
```

```bash
~/solucaoshell/setup.sh
```

```bash
termux-wake-lock; ~/solucaoshell/play.sh
```

### WSL

```bash
sudo apt update && sudo apt install -y git curl util-linux procps coreutils
```

```bash
cd ~ && git clone https://github.com/Theoswd/solucaoshell.git
```

```bash
chmod +x ~/solucaoshell/*.sh
```

```bash
~/solucaoshell/setup.sh
```

```bash
~/solucaoshell/play.sh
```

### iSH

```bash
apk update && apk add git curl bash coreutils procps util-linux tzdata --no-cache
```

```bash
cd ~ && git clone https://github.com/Theoswd/solucaoshell.git
```

```bash
chmod +x ~/solucaoshell/*.sh
```

```bash
~/solucaoshell/setup.sh
```

```bash
~/solucaoshell/play.sh
```

---

## 2. Uso do dia a dia

Os comandos funcionam de qualquer pasta.

| Para | Comando |
|---|---|
| Subir as contas e abrir o painel | `~/solucaoshell/play.sh` |
| Parar todas as contas | `~/solucaoshell/stop.sh` |
| Ver o painel sem mexer nas contas | `~/solucaoshell/status.sh` |
| Cadastrar, listar, testar ou remover contas | `~/solucaoshell/setup.sh` |
| Derrubar e subir tudo de novo | `~/solucaoshell/play.sh --restart` |
| Remover o bot e as contas cadastradas | `~/solucaoshell/uninstall.sh` |

### Atualizar

```bash
cd ~/solucaoshell && ./stop.sh && git pull --ff-only && ./play.sh
```

### Pausar sem deslogar

```bash
touch ~/.sls/PAUSED
```

Para retomar:

```bash
rm ~/.sls/PAUSED
```

### Rodar as atividades de uma conta agora

```bash
touch ~/.sls/BR_NomeDaConta/RUNNOW
```

### Ver o log de uma conta

```bash
tail -f ~/.sls/BR_NomeDaConta/sls.log
```

---

## 3. A pasta do bot tem outro nome?

Se `cd ~/solucaoshell` responde **No such file or directory**, o bot está em outra pasta (instalação antiga) ou não está instalado. Para achar:

```bash
find ~ -maxdepth 3 -name play.sh 2>/dev/null
```

Nenhum resultado: o bot não está instalado nesse aparelho (veja a seção 1).

Para passar a pasta antiga para `~/solucaoshell`, troque `PASTA_ANTIGA` pelo nome encontrado e rode um de cada vez:

```bash
~/PASTA_ANTIGA/stop.sh
```

Se já existir uma `~/solucaoshell`, confira se ela está sem contas antes de apagá-la. A resposta precisa ser `No such file or directory`:

```bash
ls ~/solucaoshell/accounts.conf
```

```bash
rm -rf ~/solucaoshell
```

```bash
mv ~/PASTA_ANTIGA ~/solucaoshell && ~/solucaoshell/play.sh
```

As contas cadastradas vão junto com a pasta. Nada precisa ser cadastrado de novo.

---

## 4. Problemas comuns

### Contas "sem resposta" no painel

O aparelho não está conseguindo falar com o servidor do jogo. Teste a conexão:

```bash
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' --max-time 20 "https://$(. ~/solucaoshell/lib/contas.sh; server_url 1)/"
```

| Resultado | Causa | O que fazer |
|---|---|---|
| `HTTP 200` | a conexão está boa | espere 1 minuto: as contas voltam sozinhas |
| `certificate has expired` | relógio do aparelho errado | confira com `date` (veja abaixo) |
| `unable to get local issuer certificate` | rede com filtro (VPN, antivírus, DNS privado, Wi-Fi com bloqueio) ou certificados do Termux desatualizados | troque de rede ou desligue a VPN; no Termux, `pkg upgrade -y` |
| `Network is unreachable`, `Could not resolve host` ou tempo esgotado | aparelho sem internet para o app | no Android: Apps → Termux → dados em segundo plano e uso irrestrito **ligados**, economia de dados **desligada** |

Os erros de cada conta ficam em `~/.sls/BR_NomeDaConta/ERROR_DEBUG`.

Nunca use `curl -k` nem opção de ignorar certificado: a senha passa por essa conexão.

### Relógio errado (WSL)

```bash
date
```

Se a data estiver errada, desligue o serviço de hora do Ubuntu, que atrapalha no WSL:

```bash
sudo systemctl disable --now chrony
```

E acerte pela hora do Windows:

```bash
sudo date -s "@$(powershell.exe -NoProfile -Command '[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()' < /dev/null | tr -d '\r')"
```

Se não der certo, no **PowerShell do Windows** rode `wsl --shutdown` e abra o Ubuntu de novo.

### Conta amarela que nunca sobe

```bash
tail -n 15 ~/.sls/BR_NomeDaConta/sls.log
```

| No log | O que fazer |
|---|---|
| `login falhou` | usuário ou senha errados: no `setup.sh`, remova a conta e adicione de novo com o nome exato do jogo |
| `servidor nao respondeu` | veja "sem resposta" acima |
| `sem credenciais` ou `cript_file` | refaça a conta no `setup.sh` |
| parado em `iniciando` | `~/solucaoshell/stop.sh` e depois `~/solucaoshell/play.sh` |

### O painel não cabe na tela

```bash
~/solucaoshell/status.sh -cols
```

Se a régua quebrar em duas linhas, fixe o número de colunas onde ela coube:

```bash
echo 46 > ~/.sls/cols
```

---

## 5. Notas

**Termux** — em **Configurações → Apps → Termux → Bateria**, marque **Sem restrições**, e deixe a notificação do Termux com **Release wakelock** (wake lock ligado). Sem isso o Android encerra o bot em segundo plano.

**WSL** — instale em `~`, nunca em `/mnt/c`. Confira com `pwd`: deve começar com `/home/`.

**iSH** — o iOS suspende apps em segundo plano. O bot para ao sair do iSH ou bloquear a tela.

Licença CC0 1.0
