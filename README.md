# solucaoshell


| Aparelho | App |
|---|---|
| Android | [Termux (F-Droid)](https://f-droid.org/packages/com.termux/) — a versão da Play Store não funciona |
| Windows | WSL — Ubuntu |
| iPhone / iPad | iSH |

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
termux-wake-lock
```

```bash
git clone https://github.com/Theoswd/solucaoshell.git
```

```bash
cd solucaoshell
```

```bash
chmod +x *.sh
```

```bash
./setup.sh
```

```bash
./play.sh
```

### WSL

```bash
sudo apt update && sudo apt install -y git curl util-linux procps coreutils
```

```bash
cd ~
```

```bash
git clone https://github.com/Theoswd/solucaoshell.git
```

```bash
cd solucaoshell
```

```bash
chmod +x *.sh
```

```bash
./setup.sh
```

```bash
./play.sh
```

### iSH

```bash
apk update
```

```bash
apk add git curl bash coreutils procps util-linux tzdata --no-cache
```

```bash
cd ~
```

```bash
git clone https://github.com/Theoswd/solucaoshell.git
```

```bash
cd solucaoshell
```

```bash
chmod +x *.sh
```

```bash
./setup.sh
```

```bash
./play.sh
```

---

## 2. Comandos

Todos rodam de dentro da pasta do bot.

| Comando | O que faz |
|---|---|
| `./setup.sh` | cadastra, lista e remove contas |
| `./play.sh` | sobe as contas e abre o painel |
| `./status.sh` | abre só o painel, não mexe nas contas |
| `./stop.sh` | para todas as contas |
| `./uninstall.sh` | remove o bot e as contas cadastradas |

### Reiniciar tudo

```bash
./play.sh --restart
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

### Atualizar

```bash
./stop.sh
```

```bash
git pull --ff-only
```

```bash
./play.sh
```

---

## 3. Notas

**Termux** — em **Configurações → Bateria → Termux**, marque **Sem restrições**. Sem isso o Android encerra o bot em segundo plano.

**WSL** — instale em `~`, nunca em `/mnt/c`. Confira com `pwd`: deve começar com `/home/`.

**iSH** — o iOS suspende apps em segundo plano. O bot para ao sair do iSH ou bloquear a tela.

**O painel não cabe na tela** — veja a largura detectada:

```bash
./status.sh -cols
```

Se a régua quebrar em duas linhas, fixe o número de colunas onde ela coube:

```bash
echo 46 > ~/.sls/cols
```

Licença CC0 1.0
