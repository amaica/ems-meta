# EMS Meta

Monorepo dos microserviços do **EMS** (Energy Management System), baseado no projeto AlgaSensors do curso de microsserviços da AlgaWorks.

Repositório: **https://github.com/amaica/ems-meta**

---

## O que tem aqui

Três serviços Spring Boot que trabalham juntos:

| Serviço | O que faz | Porta |
|---------|-----------|-------|
| **device-management** | Cadastro e gestão de sensores | `8080` |
| **temperatura-processing** | Recebe e processa leituras de temperatura | `8081` |
| **temperatura-monitoring** | Monitora sensores, grava logs e dispara alertas | `8082` |

O **RabbitMQ** entra no meio para a comunicação assíncrona entre os serviços de temperatura.

---

## Antes de começar

Você vai precisar de:

- **Java 21**
- **Git**
- **Podman** (ou Docker) — para subir o RabbitMQ

O Gradle já vem no projeto (`./gradlew`), não precisa instalar.

---

## Rodar tudo de uma vez

A forma mais simples é usar o script `ems.sh` na raiz do projeto:

```bash
git clone https://github.com/amaica/ems-meta.git
cd ems-meta

./ems.sh start    # sobe RabbitMQ + os 3 serviços
./ems.sh status   # vê o que está rodando
./ems.sh logs     # acompanha os logs
./ems.sh stop     # para tudo
```

O script cuida do RabbitMQ e dos três microserviços. Os logs ficam em `.run/logs/`.

**Dica:** use `./ems.sh` (com o `./` na frente). Se rodar com `sh ems.sh`, pode dar problema.

### Portas usadas

| Componente | Porta |
|------------|-------|
| device-management | 8080 |
| temperatura-processing | 8081 |
| temperatura-monitoring | 8082 |
| RabbitMQ (AMQP) | 5673 |
| RabbitMQ (painel web) | 15673 |

O RabbitMQ usa a porta **5673** de propósito — assim não briga com outro RabbitMQ que você já tenha na 5672.

Credenciais do RabbitMQ: `rabbitmq` / `rabbitmq`

Painel: http://localhost:15673

### Testar se funcionou

```bash
curl http://localhost:8080/api/sensors
```

Se voltar JSON (mesmo que vazio), está no ar.

---

## Demonstração do fluxo completo

Com o ambiente rodando, execute o fluxo completo de ponta a ponta:

```bash
./ems.sh start    # sobe tudo (se ainda não estiver no ar)
./ems.sh demo     # ou: ./demo.sh
```

O script percorre automaticamente:

```
device-management          temperatura-processing         temperatura-monitoring
      │                            │                              │
      │  1. cadastra sensor        │                              │
      │  2. habilita monitoramento ──────────────────────────────►│
      │                            │                              │ 3. configura alertas
      │                            │  4. recebe temperatura       │
      │                            │──────── RabbitMQ ───────────►│ 5. grava logs
      │                            │                              │ 6. registra alertas
      │  7. consulta detalhe ◄────────────────────────────────────│
```

**O que foi implementado:** quando a temperatura ultrapassa os limites configurados, o `temperatura-monitoring` **persiste um evento de alerta** consultável via API:

```bash
GET /api/sensors/{sensorId}/alert/events
```

Exemplo de resposta:

```json
{
  "content": [
    {
      "id": "...",
      "sensorId": "...",
      "value": 35.0,
      "type": "MAX_EXCEEDED",
      "registeredAt": "2026-06-17T10:30:00Z"
    }
  ],
  "totalElements": 1
}
```

---

## Rodar manualmente (sem o script)

Se preferir subir cada coisa separado:

**1. RabbitMQ**
```bash
podman start ems-rabbitmq
# ou, na primeira vez, deixe o ./ems.sh start criar o container
```

**2. Um terminal para cada serviço**
```bash
cd services/device-management && ./gradlew bootRun
cd services/temperatura-processing && SPRING_RABBITMQ_PORT=5673 ./gradlew bootRun
cd services/temperatura-monitoring && SPRING_RABBITMQ_PORT=5673 ./gradlew bootRun
```

Os dois últimos precisam saber que o RabbitMQ está na porta **5673**.

---

## Build e testes

Dentro de qualquer pasta em `services/`:

```bash
./gradlew build
./gradlew test
```

---

## Abrir no IntelliJ

1. **File → Open**
2. Selecione a pasta `ems-meta` (a raiz do projeto)
3. O IntelliJ deve importar os três módulos Gradle em `services/`

Se o IntelliJ reclamar de "dubious ownership", a pasta provavelmente está com dono errado. Corrija com:

```bash
sudo chown -R $USER:$USER /caminho/para/ems-meta
```

---

## Estrutura do projeto

```
ems-meta/
├── ems.sh                 # script para subir/parar tudo
├── demo.sh                # demonstração E2E do fluxo completo
├── docker-compose.yml     # referência do RabbitMQ (o script usa Podman)
├── configs/rabbitmq/      # plugins do RabbitMQ
└── services/
    ├── device-management/
    ├── temperatura-processing/
    └── temperatura-monitoring/
```

---

## Stack

| Tecnologia | Versão |
|------------|--------|
| Java | 21 |
| Spring Boot | 3.4.3 |
| Spring Data JPA | — |
| Spring AMQP (RabbitMQ) | — |
| H2 (banco local) | — |
| Gradle (wrapper) | incluído |

---

## Problemas comuns

**"Podman não encontrado" no terminal do IntelliJ**

O terminal do IDE às vezes vem com PATH enxuto. Tente:

```bash
CONTAINER_CMD_OVERRIDE=/usr/bin/podman ./ems.sh start
```

Ou rode o script num terminal normal do sistema.

**Erro de autenticação no RabbitMQ**

Provavelmente tem outro RabbitMQ rodando na porta 5672 com credenciais diferentes. O `ems.sh` já usa a 5673 para evitar isso.

---

## Licença

Projeto educacional — uso livre para aprendizado.
