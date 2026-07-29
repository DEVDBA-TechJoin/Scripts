#!/usr/bin/env bash
#
# Cria um usuário (role) de somente leitura no PostgreSQL, restrito ao
# schema public, e libera o acesso em pg_hba.conf.

set -Eeuo pipefail  # -e: para no primeiro erro; -u: variável não definida é erro; pipefail: erro em qualquer parte de um pipe conta
umask 077           # arquivos criados (logs, etc.) ficam legíveis só pelo dono, pois o log guarda a senha gerada

export PGCONNECT_TIMEOUT=10  # evita que o script trave indefinidamente se o PostgreSQL estiver inacessível

LOG_FILE="usuario_leitura.log"
ERROR_LOG="erro.log"

log() {
  local mensagem="$1"
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$mensagem" | tee -a "$LOG_FILE"
}

log_error() {
  log "ERRO: $1"
}

reset_error_log() {
  : > "$ERROR_LOG"
}

log_error_file() {
  if [[ -s "$ERROR_LOG" ]]; then
    while IFS= read -r linha; do
      log_error "$linha"
    done < "$ERROR_LOG"
  fi
}

cleanup() {
  rm -f "$ERROR_LOG"
  unset PGPASSWORD
}

handle_unexpected_error() {
  local exit_code=$?
  log_error "Falha inesperada na linha ${BASH_LINENO[0]} ao executar: ${BASH_COMMAND} (código ${exit_code})"
  exit "$exit_code"
}

fail() {
  local mensagem="$1"
  log_error "$mensagem"
  exit 1
}

require_command() {
  local comando="$1"
  if ! command -v "$comando" >/dev/null 2>&1; then
    fail "Comando obrigatório não encontrado: $comando"
  fi
}

# Escapa aspas simples para uso seguro dentro de literais de string SQL
# (camada extra de defesa; os valores já são validados antes de chegar aqui).
sql_escape() {
  printf '%s' "${1//\'/\'\'}"
}

validar_nome_usuario() {
  local nome="$1"

  if [[ -z "$nome" ]]; then
    log_error "O nome do usuário não pode estar vazio."
    return 1
  fi

  if [[ ${#nome} -lt 5 ]]; then
    log_error "O nome do usuário deve ter no mínimo 5 caracteres."
    return 1
  fi

  if [[ ! "$nome" =~ ^[0-9_a-zA-Z]+$ ]]; then
    log_error "Use apenas números, letras sem acentuação e _ para o nome do usuário."
    return 1
  fi

  return 0
}

reload_postgresql() {
  reset_error_log

  if service "postgresql-${PG_MAJOR}" reload > /dev/null 2> "$ERROR_LOG"; then
    log "PostgreSQL recarregado com sucesso."
    return 0
  fi

  if service postgresql reload > /dev/null 2> "$ERROR_LOG"; then
    log "PostgreSQL recarregado com sucesso."
    return 0
  fi

  log_error "Não foi possível recarregar o PostgreSQL."
  log_error_file
  return 1
}

# Usado quando o usuário/role já foi criado no banco mas uma validação
# posterior falhou (autenticação, checagem de permissão, etc).
avisar_intervencao_manual() {
  local mensagem="$1"
  local orientacao="$2"

  echo
  log_error "$mensagem"
  log_error_file
  log "[AVISO] Processo finalizado de forma incompleta."
  log "[AVISO] Nenhuma ação automática de correção ou rollback será executada."
  log "[AVISO] $orientacao"
  echo
  exit 1
}

trap cleanup EXIT
trap handle_unexpected_error ERR

if [[ "$EUID" -ne 0 ]]; then
  fail "Este script deve ser executado como root."
fi

echo "########################################################" | tee -a "$LOG_FILE"
echo "      Criação de Usuário de Leitura no PostgreSQL       " | tee -a "$LOG_FILE"
echo "########################################################" | tee -a "$LOG_FILE"

if [[ ! -t 0 ]]; then
  fail "Este script requer execução interativa (terminal)."
fi

require_command psql
require_command openssl
require_command sed
require_command curl
require_command service
require_command stat

log "Iniciando processo de criação de usuário de leitura no PostgreSQL."

# ---- Coleta de dados do operador ----

while true; do
  echo
  read -r -p "Digite o termo de liberação: " termo_liberacao

  if [[ -n "$termo_liberacao" ]]; then
    log "Termo de liberação recebido."
    break
  fi

  log_error "O termo de liberação não pode estar vazio."
done

while true; do
  echo
  read -r -s -p "Senha do usuário postgres: " PGPASSWORD
  echo

  if [[ -n "$PGPASSWORD" ]]; then
    export PGPASSWORD
    log "Senha do usuário postgres recebida."
    break
  fi

  log_error "A senha do usuário postgres não pode estar vazia."
done

while true; do
  echo
  read -r -p "Digite o nome do usuário a ser criado: " usuario

  if validar_nome_usuario "$usuario"; then
    log "Nome do usuário validado: $usuario"
    break
  fi
done

# ---- Carrega /etc/wildfly.conf ----
# O arquivo é executado (source) como root logo abaixo; se ele pudesse ser
# escrito por outro usuário, seria uma forma de rodar código arbitrário como
# root. Por isso o dono e as permissões são checados antes do source.

if [[ ! -f /etc/wildfly.conf ]]; then
  fail "Arquivo /etc/wildfly.conf não encontrado."
fi

wildfly_conf_owner="$(stat -c '%U' /etc/wildfly.conf)"
if [[ "$wildfly_conf_owner" != "root" ]]; then
  fail "Arquivo /etc/wildfly.conf não pertence ao usuário root (dono atual: $wildfly_conf_owner). Abortando por segurança."
fi

wildfly_conf_perms="$(stat -c '%A' /etc/wildfly.conf)"
if [[ "${wildfly_conf_perms:4:6}" == *w* ]]; then
  fail "Arquivo /etc/wildfly.conf possui permissão de escrita para grupo/outros ($wildfly_conf_perms). Abortando por segurança."
fi

if ! source /etc/wildfly.conf; then
  fail "Falha ao carregar o arquivo /etc/wildfly.conf."
fi

log "Arquivo /etc/wildfly.conf carregado com sucesso."

if [[ -z "${END_SERVIDOR:-}" ]]; then
  fail "Variável END_SERVIDOR não definida em /etc/wildfly.conf."
fi

if [[ -z "${CHINCHILA_DS_DATABASENAME:-}" ]]; then
  fail "Variável CHINCHILA_DS_DATABASENAME não definida em /etc/wildfly.conf."
fi

SCHEMA_OWNER="${CHINCHILA_DS_SCHEMA_OWNER:-chinchila}"

log "Variáveis obrigatórias validadas."

reset_error_log
if IP_PUBLICO="$(curl -fsS --max-time 10 https://api.ipify.org 2> "$ERROR_LOG")"; then
  log "IP público obtido com sucesso."
else
  IP_PUBLICO="não identificado"
  log "Aviso: não foi possível obter o IP público."
  log_error_file
fi

# ---- Conexão administrativa e detecção do ambiente PostgreSQL ----

echo "[INFO] Testando conexão administrativa com PostgreSQL..." | tee -a "$LOG_FILE"
reset_error_log
if ! psql -X -v ON_ERROR_STOP=1 -h "$END_SERVIDOR" -U postgres -d "$CHINCHILA_DS_DATABASENAME" \
  -c "SELECT 1;" > /dev/null 2> "$ERROR_LOG"; then
  log_error "Não foi possível conectar ao PostgreSQL com o usuário postgres."
  log_error_file
  exit 1
fi
log "Conexão administrativa validada."

reset_error_log
PG_DATA="$(psql -X -At -v ON_ERROR_STOP=1 -h "$END_SERVIDOR" -U postgres -d "$CHINCHILA_DS_DATABASENAME" \
  -c "SHOW data_directory;" 2> "$ERROR_LOG")"
if [[ -z "$PG_DATA" ]]; then
  log_error "Não foi possível identificar o diretório de dados do PostgreSQL."
  log_error_file
  exit 1
fi

reset_error_log
PG_VERSION="$(psql -X -At -v ON_ERROR_STOP=1 -h "$END_SERVIDOR" -U postgres -d "$CHINCHILA_DS_DATABASENAME" \
  -c "SHOW server_version;" 2> "$ERROR_LOG")"
if [[ -z "$PG_VERSION" ]]; then
  log_error "Não foi possível identificar a versão do PostgreSQL."
  log_error_file
  exit 1
fi

PG_MAJOR="${PG_VERSION%%.*}"
PG_HBA_FILE="${PG_DATA}/pg_hba.conf"

if [[ ! -d "$PG_DATA" ]]; then
  fail "Diretório de dados do PostgreSQL não encontrado: $PG_DATA"
fi

if [[ ! -f "$PG_HBA_FILE" ]]; then
  fail "Arquivo pg_hba.conf não encontrado em: $PG_HBA_FILE"
fi

if [[ ! "$PG_MAJOR" =~ ^[0-9]+$ ]]; then
  fail "Versão principal do PostgreSQL inválida: $PG_VERSION"
fi

log "Diretório de dados PostgreSQL detectado: $PG_DATA"
log "Versão PostgreSQL detectada: $PG_VERSION"

# ---- Garante que o nome de usuário está livre ----
# Se a role já existir e tiver privilégios concedidos em outras tabelas, o
# "DROP ROLE IF EXISTS" mais adiante falha (Postgres não permite dropar uma
# role com ACLs pendentes em outros objetos, mesmo sem ser dona deles). Por
# isso a existência é checada aqui, antes de qualquer tentativa de criação.

while true; do
  reset_error_log
  if ! usuario_existe="$(psql -X -At -v ON_ERROR_STOP=1 -h "$END_SERVIDOR" -U postgres -d "$CHINCHILA_DS_DATABASENAME" \
    -c "SELECT 1 FROM pg_roles WHERE rolname = '$(sql_escape "$usuario")';" 2> "$ERROR_LOG")"; then
    log_error "Não foi possível verificar se o usuário já existe no banco de dados."
    log_error_file
    exit 1
  fi

  if [[ -z "$usuario_existe" ]]; then
    break
  fi

  echo
  log "[AVISO] O usuário \"$usuario\" já existe no banco de dados."
  echo
  read -r -p "Deseja remover o usuário manualmente e executar o script novamente depois? [s/N] (N = informar outro nome agora): " remover_manual
  log "Resposta para remoção manual do usuário existente: ${remover_manual:-N}"

  if [[ "$remover_manual" =~ ^[sS]$ ]]; then
    fail "Nenhuma alteração foi realizada. Remova o usuário \"$usuario\" manualmente e execute o script novamente."
  fi

  while true; do
    echo
    read -r -p "Digite o novo nome do usuário a ser criado: " usuario

    if validar_nome_usuario "$usuario"; then
      log "Nome do usuário validado: $usuario"
      break
    fi
  done
done

# tr -d remove caracteres de fora do alfabeto alfanumérico do base64; o laço
# repete a geração até sobrar pelo menos 12 caracteres, para não gerar uma
# senha mais curta (e mais fraca) do que o esperado.
senha=""
while [[ ${#senha} -lt 12 ]]; do
  senha="${senha}$(openssl rand -base64 12 | tr -d '/=+')"
done
senha="${senha:0:12}"
log "Senha do novo usuário gerada automaticamente."
echo "Senha gerada automaticamente para o usuário $usuario: $senha"

# ---- Confirmação final antes de alterar o banco ----

echo | tee -a "$LOG_FILE"
echo "Resumo da operação a ser executada:" | tee -a "$LOG_FILE"
echo "  Usuário a criar: $usuario" | tee -a "$LOG_FILE"
echo "  Servidor: $END_SERVIDOR" | tee -a "$LOG_FILE"
echo "  Banco de dados: $CHINCHILA_DS_DATABASENAME" | tee -a "$LOG_FILE"
echo "  Versão PostgreSQL: $PG_VERSION" | tee -a "$LOG_FILE"
echo | tee -a "$LOG_FILE"

read -r -p "Confirma a criação do usuário acima? [s/N]: " confirma_criacao
log "Resposta para confirmação de criação: ${confirma_criacao:-N}"
if [[ ! "$confirma_criacao" =~ ^[sS]$ ]]; then
  fail "Operação cancelada pelo usuário antes da criação."
fi

usuario_sql="$(sql_escape "$usuario")"
senha_sql="$(sql_escape "$senha")"
schema_owner_sql="$(sql_escape "$SCHEMA_OWNER")"

# ---- Criação do usuário no PostgreSQL ----

echo "[INFO] Criando usuário no banco de dados..." | tee -a "$LOG_FILE"
reset_error_log
if ! psql -X -v ON_ERROR_STOP=1 -h "$END_SERVIDOR" -U postgres -d "$CHINCHILA_DS_DATABASENAME" > /dev/null 2> "$ERROR_LOG" <<EOF
DO \$\$
DECLARE
  usuario varchar := '$usuario_sql';
  senha varchar := '$senha_sql';
  schema_owner varchar := '$schema_owner_sql';
BEGIN
  -- As três checagens abaixo repetem, dentro do SQL, validações que o bash
  -- já fez antes de chegar aqui (nome/senha vazios ou "definir", tamanho
  -- mínimo, caracteres permitidos). É uma segunda camada de defesa: se este
  -- bloco algum dia for reaproveitado fora do fluxo normal do script, ele
  -- não cria um usuário com dados inválidos silenciosamente.
  IF (usuario = 'definir' OR senha = 'definir') THEN
    RAISE EXCEPTION 'As variáveis usuario e senha precisam ser definidas!';
  END IF;

  IF (length(usuario) < 5 OR length(senha) < 4) THEN
    RAISE EXCEPTION 'O usuário deve ter no mínimo 5 caracteres e a senha 4';
  END IF;

  IF (usuario !~ '^[0-9_a-zA-Z]+$') THEN
    RAISE EXCEPTION 'Usar apenas números, letras sem acentuação e _ para o nome do usuário';
  END IF;

  EXECUTE format('DROP ROLE IF EXISTS %I', usuario);
  EXECUTE format(
    'CREATE ROLE %I LOGIN PASSWORD %L NOSUPERUSER INHERIT NOCREATEDB NOCREATEROLE CONNECTION LIMIT 5',
    usuario,
    senha
  );
  EXECUTE format('REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM %I', usuario);
  EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA public TO %I', usuario);
  EXECUTE format(
    'ALTER DEFAULT PRIVILEGES FOR USER %I IN SCHEMA public GRANT SELECT ON TABLES TO %I',
    schema_owner,
    usuario
  );
END
\$\$;
EOF
then
  log_error "Falha ao criar o usuário de leitura no banco de dados."
  log_error_file
  exit 1
fi

log "Usuário de leitura criado no banco de dados."

# ---- Libera acesso no pg_hba.conf ----
# scram-sha-256 só existe a partir do PostgreSQL 10; em versões mais antigas
# cai para md5, o método suportado disponível.
if (( PG_MAJOR >= 10 )); then
  METODO_AUTH="scram-sha-256"
else
  METODO_AUTH="md5"
fi

# O padrão abaixo (usuário cercado por espaços) só identifica corretamente
# entradas já escritas pelo próprio script (formato fixo "host all USUARIO
# samenet METODO"); uma entrada de pg_hba.conf escrita manualmente em outro
# formato pode não ser reconhecida como já existente.
if grep -Eq "[[:space:]]$usuario[[:space:]]" "$PG_HBA_FILE"; then
  log "Já existe uma entrada para o usuário \"$usuario\" em $PG_HBA_FILE."
  echo
  read -r -p "Deseja inserir uma nova entrada mesmo assim? [s/N]: " confirma_pg_hba
  log "Resposta para nova entrada em pg_hba.conf: ${confirma_pg_hba:-N}"

  if [[ "$confirma_pg_hba" =~ ^[sS]$ ]]; then
    echo "host    all     $usuario    samenet    $METODO_AUTH" >> "$PG_HBA_FILE"
    log "Nova entrada adicionada em pg_hba.conf com autenticação $METODO_AUTH."
  else
    log "Entrada existente mantida; nenhuma nova linha adicionada em pg_hba.conf."
  fi
else
  echo "host    all     $usuario    samenet    $METODO_AUTH" >> "$PG_HBA_FILE"
  log "Nova entrada adicionada em pg_hba.conf com autenticação $METODO_AUTH."
fi

echo "[INFO] Recarregando PostgreSQL..." | tee -a "$LOG_FILE"
if ! reload_postgresql; then
  exit 1
fi

# ---- Validação pós-criação ----
# Falhas a partir daqui não desfazem o que já foi feito (ver
# avisar_intervencao_manual) — o usuário já existe no banco nesse ponto.

echo "[INFO] Validando autenticação do novo usuário..." | tee -a "$LOG_FILE"
reset_error_log
if ! PGPASSWORD="$senha" psql -X -v ON_ERROR_STOP=1 -h "$END_SERVIDOR" -U "$usuario" -d "$CHINCHILA_DS_DATABASENAME" \
  -c "SELECT 1;" > /dev/null 2> "$ERROR_LOG"; then
  avisar_intervencao_manual \
    "Falha na autenticação do novo usuário." \
    "Verifique manualmente a senha, a entrada em $PG_HBA_FILE (usuário \"$usuario\") e o método de autenticação ($METODO_AUTH), ou remova o usuário (DROP ROLE \"$usuario\";) e a entrada correspondente em $PG_HBA_FILE, e execute o script novamente."
fi
log "Autenticação validada com SELECT 1."

echo "[INFO] Validando permissões de leitura no schema public..." | tee -a "$LOG_FILE"
reset_error_log
if ! permissao_ok="$(PGPASSWORD="$senha" psql -X -At -v ON_ERROR_STOP=1 -h "$END_SERVIDOR" -U "$usuario" -d "$CHINCHILA_DS_DATABASENAME" \
  -c "SELECT CASE
        WHEN EXISTS (
          SELECT 1
          FROM pg_tables
          WHERE schemaname = 'public'
        ) THEN NOT EXISTS (
          SELECT 1
          FROM pg_tables
          WHERE schemaname = 'public'
            AND NOT has_table_privilege(
              current_user,
              format('%I.%I', schemaname, tablename),
              'SELECT'
            )
        )
        ELSE true
      END;" 2> "$ERROR_LOG")"; then
  avisar_intervencao_manual \
    "Falha ao validar as permissões de leitura do novo usuário." \
    "Verifique manualmente a conectividade e as permissões do usuário \"$usuario\" no banco $CHINCHILA_DS_DATABASENAME, ou remova o usuário (DROP ROLE \"$usuario\";) e a entrada correspondente em $PG_HBA_FILE, e execute o script novamente."
fi

if [[ "$permissao_ok" != "t" ]]; then
  avisar_intervencao_manual \
    "O usuário autenticou, mas não possui permissão de leitura em todas as tabelas do schema public." \
    "Atribua manualmente as permissões faltantes ao usuário \"$usuario\", ou remova-o (DROP ROLE \"$usuario\";) junto com a entrada correspondente em $PG_HBA_FILE, e execute o script novamente."
fi
log "Permissões de leitura validadas com sucesso."

echo | tee -a "$LOG_FILE"
echo "Usuário criado e acesso validado com sucesso." | tee -a "$LOG_FILE"
echo | tee -a "$LOG_FILE"
echo "Dados do usuário criado:" | tee -a "$LOG_FILE"
echo "Usuário: $usuario" | tee -a "$LOG_FILE"
echo "Senha: $senha" | tee -a "$LOG_FILE"
echo "IP Servidor Local: $END_SERVIDOR (Para conexões na mesma rede)" | tee -a "$LOG_FILE"
echo "IP Servidor Público: $IP_PUBLICO (Para conexões externas)" | tee -a "$LOG_FILE"
echo "Banco de Dados: $CHINCHILA_DS_DATABASENAME" | tee -a "$LOG_FILE"
echo "Versão PostgreSQL: $PG_VERSION" | tee -a "$LOG_FILE"
echo "Porta: 5432" | tee -a "$LOG_FILE"
echo "Termo de Liberação: $termo_liberacao" | tee -a "$LOG_FILE"
echo | tee -a "$LOG_FILE"
echo "Observações sobre a porta 5432:" | tee -a "$LOG_FILE"
echo "1. A porta 5432 deve chegar pelo link de internet e ser roteada para o IP servidor local. Essa configuração é responsabilidade da TI Local." | tee -a "$LOG_FILE"
echo "2. Para acessos externos, use o IP Público (ou DDNS) na conexão remota." | tee -a "$LOG_FILE"
echo "3. Não nos responsabilizamos por roteamentos NAT onde a porta de origem seja diferente de 5432. (Ex: 5444 externo -> 5432 interno)" | tee -a "$LOG_FILE"
echo | tee -a "$LOG_FILE"

log "Processo concluído com sucesso."
echo
read -r -p "Pressione ENTER para encerrar..." || true
