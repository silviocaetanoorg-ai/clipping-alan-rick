# Clipping — Senador Alan Rick

Ferramenta local que coleta e organiza automaticamente as notícias sobre o Senador Alan Rick (Acre).

## Como usar
1. Dê dois cliques em **iniciar.bat**. O navegador abre em http://localhost:8080/
2. Deixe a janela preta aberta enquanto usar o clipping. Para fechar, feche a janela ou aperte Ctrl+C.

Não precisa instalar nada: o servidor roda no PowerShell, que já vem com o Windows.

## O que faz
- Coleta a cada 20 minutos no **Google Notícias**, no **Bing Notícias** e nos portais do Acre (ac24horas, ContilNet,
  A Gazeta do Acre, O Alto Acre, AcreNews, Jornal Opinião, Agência Acre) e na Agência Senado.
- Remove duplicadas: a mesma manchete vinda de várias fontes aparece uma vez só.
- Guarda tudo em `data/noticias.json`, então o histórico só cresce.
- Classifica por tema (Pacote fiscal, Eleições, Saúde, Infraestrutura…) e marca como **citação** quando o nome não está no título.
- Filtros por período, veículo, tema e busca livre, além de favoritas ★ e notícias ocultadas.
- **Copiar clipping** gera um texto pronto para WhatsApp/e-mail com as notícias filtradas.
- **Exportar CSV** (abre no Excel) e **Imprimir / PDF**.

## Personalizar
Edite `config.json` para mudar as buscas, os portais, os temas e as palavras-chave, a porta ou o intervalo de atualização.
Depois reinicie o `iniciar.bat`.
