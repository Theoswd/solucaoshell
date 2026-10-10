# solucaoshell — regras para o Claude Code

## Assinatura em commits e PRs

- Commit: termine a mensagem só com a linha
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
  (o nome do modelo que estiver em uso no lugar de "Opus 5.5").
- Nunca inclua link ou identificador da sessão: nada de `Claude-Session:`,
  nem link `claude.ai/code/session_...` em commit, PR ou comentário.
- Descrição de PR: no máximo a linha
  `🤖 Generated with [Claude Code](https://claude.com/claude-code)`, sem
  link de sessão.

## Como o dono do bot trabalha

- Converse e escreva commits em português.
- O título do commit leva a versão entre parênteses, como os anteriores:
  `Area: o que mudou (3.9.NN)`.
- Testes: `sh tests/test_manutencao.sh` (sem rede; tem de terminar com
  0 FALHA antes de qualquer push).
- Nas batalhas, otimização não pode mudar a estratégia de nenhum evento:
  mesma ordem de prioridades, recargas e limiares. Prove com um teste que
  rode o código antigo e o novo contra o mesmo roteiro de páginas e compare
  as requisições. Mudança de estratégia só com o pedido do dono.
