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

---

## 3. Conta amarela que nunca sobe

```bash
tail -n 15 ~/.sls/BR_NomeDaConta/sls.log
```

| No log | O que fazer |
|---|---|
| `login falhou` | usuário ou senha errados: no `setup.sh`, remova a conta e adicione de novo com o nome exato do jogo |
| `servidor nao respondeu` | o aparelho não está falando com o jogo: confira a internet e, no Android, deixe o Termux sem restrição de bateria e de dados em segundo plano |
| `sem credenciais` ou `cript_file` | refaça a conta no `setup.sh` |
| parado em `iniciando` | `~/solucaoshell/stop.sh` e depois `~/solucaoshell/play.sh` |

---

Licença CC0 1.0
