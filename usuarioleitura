#!/usr/bin/env bashAdd commentMore actions

set -euo pipefail

LOG_FILE="usuario_leitura.log"
echo "########################################################" | tee -a "$LOG_FILE"
echo "      Criação de Usuário de Leitura no PostgreSQL       " | tee -a "$LOG_FILE"
echo "########################################################" | tee -a "$LOG_FILE"

read -s -p "Senha do usuário postgres: " PGPASSWORD
echo
export PGPASSWORD

read -p "Digite o nome do usuário a ser criado: " usuario
read -s -p "Digite a senha para o usuário $usuario: " senha
echo

# Carrega variáveis do sistema
source /etc/wildfly.conf

# Validação
if [[ -z "${END_SERVIDOR:-}" || -z "${CHINCHILA_DS_DATABASENAME:-}" ]]; then
  echo "Erro: END_SERVIDOR ou CHINCHILA_DS_DATABASENAME não definidos." | tee -a "$LOG_FILE"
  exit 1
fi

echo "[INFO] Criando usuário no banco de dados..." | tee -a "$LOG_FILE"

# Bloco PL/pgSQL
psql -X -h "$END_SERVIDOR" -U postgres -d "$CHINCHILA_DS_DATABASENAME" <<EOF
DO \$\$
DECLARE
  usuario varchar := '$usuario';
  senha varchar := '$senha';
BEGIN
  IF (usuario = 'definir' OR senha = 'definir') THEN
    RAISE EXCEPTION 'As variáveis usuario e senha precisam ser definidas!';
  END IF;

  IF (length(usuario) < 5 OR length(senha) < 4) THEN
    RAISE EXCEPTION 'O usuário deve ter no mínimo 5 caracteres e a senha 4';
  END IF;

  IF (usuario !~ '^[0-9_a-zA-Z]+\$') THEN
    RAISE EXCEPTION 'Usar apenas números, letras sem acentuação e _ para o nome do usuário';
  END IF;

  EXECUTE format('DROP ROLE IF EXISTS %I', usuario);
  EXECUTE format('CREATE ROLE %I LOGIN PASSWORD ''%s'' NOSUPERUSER INHERIT NOCREATEDB NOCREATEROLE CONNECTION LIMIT 5', usuario, senha);
  EXECUTE format('REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM %I', usuario);
  EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA public TO %I', usuario);
  EXECUTE format('ALTER DEFAULT PRIVILEGES FOR USER chinchila IN SCHEMA public GRANT SELECT ON TABLES TO %I', usuario);
END
\$\$;
EOF

# Detecta versão PostgreSQL
PG_DATA=$(ps aux | grep -oP '^postgres .*postmaster.*-D *\K.*')
PG_VERSION=$(cat $PG_DATA/PG_VERSION)
cd "$PG_DATA"

# Remove entradas antigas
sed -i "/$usuario/d" pg_hba.conf

# Adiciona nova entrada
if [[ "$PG_VERSION" == "14" || "$PG_VERSION" < "14" ]]; then
  echo "host    all     $usuario    samenet    scram-sha-256" >> pg_hba.conf
else
  echo "host    all     $usuario    samenet    md5" >> pg_hba.conf
fi

# Recarrega PostgreSQL
echo "[INFO] Recarregando PostgreSQL..." | tee -a "$LOG_FILE"
service postgresql-$PG_VERSION reload

# Teste de conexão SELECT na tabela UNIDADENEGOCIO
echo "[INFO] Testando acesso com SELECT * FROM UNIDADENEGOCIO" | tee -a "$LOG_FILE"
if PGPASSWORD="$senha" psql -X -h "$END_SERVIDOR" -U "$usuario" -d "$CHINCHILA_DS_DATABASENAME" -c "SELECT * FROM UNIDADENEGOCIO LIMIT 1;" > /dev/null 2> erro.log; then
  echo "" | tee -a "$LOG_FILE"
  echo "✅ Usuário criado e acesso validado com sucesso!" | tee -a "$LOG_FILE"
  echo "Usuário: $usuario" | tee -a "$LOG_FILE"
  echo "Senha: $senha" | tee -a "$LOG_FILE"
  echo "Servidor: $END_SERVIDOR" | tee -a "$LOG_FILE"
  echo "Base: $CHINCHILA_DS_DATABASENAME" | tee -a "$LOG_FILE"
  echo "Versão PostgreSQL: $PG_VERSION" | tee -a "$LOG_FILE"
  echo "Porta: 5432" | tee -a "$LOG_FILE"
  echo "" | tee -a "$LOG_FILE"
  read -p "Pressione ENTER para encerrar..."

else
  echo "" | tee -a "$LOG_FILE"
  echo "❌ Falha na execução do SELECT com o novo usuário!" | tee -a "$LOG_FILE"
  cat erro.log | tee -a "$LOG_FILE"
  echo ""
  read -p "Deseja desfazer o processo? [s/N]: " resposta

  if [[ "$resposta" =~ ^[sS]$ ]]; then
    echo "[INFO] Revertendo criação do usuário..." | tee -a "$LOG_FILE"
    psql -X -h "$END_SERVIDOR" -U postgres -d "$CHINCHILA_DS_DATABASENAME" -c "DROP ROLE IF EXISTS \"$usuario\";"
    sed -i "/$usuario/d" pg_hba.conf
    service postgresql-$PG_VERSION reload
    echo "Rollback concluído." | tee -a "$LOG_FILE"
  else
    echo ""
    echo "⚠️  ATENÇÃO, PROCESSO FINALIZADO COM FALHAS" | tee -a "$LOG_FILE"
    echo "Erro encontrado:" | tee -a "$LOG_FILE"
    cat erro.log | tee -a "$LOG_FILE"
  fi
fi
