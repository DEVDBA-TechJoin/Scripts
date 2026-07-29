#!/usr/bin/env bash
set -o pipefail

# Verifica se o usuário é root
if [ "$EUID" -ne 0 ]; then
    echo -e "\e[31m[ERRO] Este script deve ser executado como root.\e[0m"
    exit 1
fi

#Cores para o terminal (desativadas se a saída não for um terminal)
if [ -t 1 ]; then
    RED="\e[31m"
    GREEN="\e[32m"
    YELLOW="\e[33m"
    CYAN="\e[36m"
    RESET="\e[0m"
else
    RED=""; GREEN=""; YELLOW=""; CYAN=""; RESET=""
fi

# Limpeza de arquivos temporários em caso de interrupção
TEMP_DD_FILE=""
trap 'rm -f "$TEMP_DD_FILE"' EXIT INT TERM

# Caminho do relatório
RELATORIO="${1:-./relatorio_hardware.txt}"

RELATORIO_DIR=$(dirname -- "$RELATORIO")
if [ ! -d "$RELATORIO_DIR" ]; then
    echo -e "${RED}[ERRO] Diretório \"$RELATORIO_DIR\" não existe.${RESET}"
    exit 1
fi
if [ ! -w "$RELATORIO_DIR" ]; then
    echo -e "${RED}[ERRO] Sem permissão de escrita em \"$RELATORIO_DIR\".${RESET}"
    exit 1
fi
if [ -e "$RELATORIO" ]; then
    if [ ! -f "$RELATORIO" ]; then
        echo -e "${RED}[ERRO] \"$RELATORIO\" existe e não é um arquivo regular. Abortando.${RESET}"
        exit 1
    fi
    echo -ne "${YELLOW}[!] O arquivo \"$RELATORIO\" já existe e será sobrescrito. Confirma? (s/n): ${RESET}"
    read -r confirma_sobrescrita
    case "$confirma_sobrescrita" in
        s|S) ;;
        *) echo -e "${RED}Operação cancelada pelo usuário.${RESET}"; exit 1 ;;
    esac
fi

# Timer
SECONDS=0

# Dados capturados uma única vez (evita divergência entre tela e arquivo)
HOSTNAME_ATUAL=$(hostname)
DATA_ATUAL=$(date)

# Cabeçalho
clear
echo -e "${CYAN}==============================================================${RESET}"
echo -e "${CYAN} RELATÓRIO DE HARDWARE - \"$HOSTNAME_ATUAL\"${RESET}"
echo -e "${CYAN} Data: $DATA_ATUAL${RESET}"
echo -e "${CYAN}==============================================================${RESET}"
echo

# Pergunta inicial sobre modo de execução
while true; do
    echo -ne "${YELLOW}Deseja executar todos os testes de uma vez (1) ou confirmar um por um (2)? [1/2]: ${RESET}"
    read -r modo
    case "$modo" in
        1) MODO_AUTO=true; break ;;
        2) MODO_AUTO=false; break ;;
        *) echo -e "${RED}Resposta inválida. Digite '1' para todos ou '2' para confirmar cada.${RESET}" ;;
    esac
done

pausar() {
    if ! $MODO_AUTO; then
        read -rp "Pressione Enter para continuar..." dummy
    fi
}

adicionar_secao() {
    echo "====================================================" >> "$RELATORIO"
    echo ">>> $1" >> "$RELATORIO"
    echo "====================================================" >> "$RELATORIO"
}

# Alguns comandos (ex: memtester) desenham barras de progresso/spinners usando
# bytes de retrocesso (backspace/^H) em vez de checar se a saída é um terminal.
# Ao redirecionar para arquivo esses bytes não apagam nada, só se acumulam.
# Este filtro simula o efeito do backspace (apaga o caractere anterior) e
# descarta o texto sobrescrito por retorno de carro (\r), preservando apenas
# o conteúdo final que seria exibido na tela.
limpar_saida() {
    local BS
    BS=$(printf '\010')
    sed -E ":a; s/[^$BS]$BS//; ta" | sed 's/^.*\r//'
}

perguntar_execucao() {
    local etapa="$1"
    if $MODO_AUTO; then
        echo -e "${GREEN}[AUTO] Executando etapa: $etapa${RESET}"
        return 0
    else
        while true; do
            echo -ne "${YELLOW}Deseja executar a etapa \"$etapa\"? (s/n): ${RESET}"
            read -r resposta
            case "$resposta" in
                s|S) return 0 ;;
                n|N) return 1 ;;
                *) echo -e "${RED}Resposta inválida. Digite 's' ou 'n'.${RESET}" ;;
            esac
        done
    fi
}

# Exibe o trecho recém-gravado no relatório e pausa (compartilhado entre etapas e a seção de rede)
finalizar_etapa() {
    local nome="$1"
    local linhas_antes="$2"
    local linhas_depois
    linhas_depois=$(wc -l < "$RELATORIO")
    echo -e "\n${GREEN}[✔] Etapa \"$nome\" executada.${RESET}\n"
    sed -n "$((linhas_antes+1)),$linhas_depois p" "$RELATORIO"
    echo -e "${CYAN}------------------------------------------------------${RESET}"
    pausar
}

executar_etapa() {
    local nome="$1"
    shift

    if perguntar_execucao "$nome"; then
        echo -e "${CYAN}===> Iniciando: $nome${RESET}"
        local linhas_antes
        linhas_antes=$(wc -l < "$RELATORIO")

        adicionar_secao "$nome"
        "$@" 2>&1 | limpar_saida >> "$RELATORIO"
        echo >> "$RELATORIO"

        finalizar_etapa "$nome" "$linhas_antes"
    else
        echo -e "${YELLOW}[!] Etapa \"$nome\" pulada pelo usuário.${RESET}"
        pausar
    fi
}

verificar_dependencias() {
    local faltando=()
    local dep
    for dep in lscpu free lsblk df fdisk dd last; do
        command -v "$dep" >/dev/null 2>&1 || faltando+=("$dep")
    done
    if [ "${#faltando[@]}" -gt 0 ]; then
        echo -e "${YELLOW}[!] Aviso: comandos não encontrados (etapas relacionadas podem falhar): ${faltando[*]}${RESET}"
    fi
}
verificar_dependencias

# Início do relatório
cat << EOF > "$RELATORIO"
==============================================================
 RELATÓRIO DE HARDWARE - "$HOSTNAME_ATUAL"
 Data: $DATA_ATUAL
==============================================================

EOF

# Etapas principais
executar_etapa "INFORMAÇÕES DA CPU (lscpu)" lscpu

if free -h &>/dev/null; then
    executar_etapa "MEMÓRIA - USO ATUAL (free -h)" free -h
else
    executar_etapa "MEMÓRIA - USO ATUAL (free -m)" free -m
fi

executar_etapa "DISCOS - LISTAGEM (lsblk)" lsblk
executar_etapa "DISCOS - USO DE ESPAÇO (df -h)" df -h
executar_etapa "DISCOS - PARTICIONAMENTO (fdisk -l)" fdisk -l

# S.M.A.R.T. (percorre todos os discos, não apenas o primeiro)
if perguntar_execucao "S.M.A.R.T. DISCO"; then
    if command -v smartctl >/dev/null 2>&1; then
        DISCOS=$(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}')
        if [ -n "$DISCOS" ]; then
            while read -r disco; do
                executar_etapa "S.M.A.R.T. DISCO ($disco)" smartctl -a "$disco"
            done <<< "$DISCOS"
        else
            echo -e "${YELLOW}[!] Nenhum disco encontrado para executar smartctl.${RESET}"
        fi
    else
        adicionar_secao "S.M.A.R.T. NÃO DISPONÍVEL"
        echo "O utilitário 'smartctl' não está instalado." >> "$RELATORIO"
        echo >> "$RELATORIO"
        echo -e "${YELLOW}[!] smartctl não está instalado.${RESET}"
    fi
    pausar
fi

# Configuração de rede
if perguntar_execucao "CONFIGURAÇÕES DE REDE (detecção automática)"; then
    linhas_antes=$(wc -l < "$RELATORIO")
    adicionar_secao "CONFIGURAÇÕES DE REDE (detecção automática)"
    echo "[INFO] Detectando gerenciador de rede..." >> "$RELATORIO"

    if [ -d "/etc/sysconfig/network-scripts" ] && compgen -G "/etc/sysconfig/network-scripts/ifcfg-*" > /dev/null; then
        echo "[INFO] ifcfg detectado" >> "$RELATORIO"
        for cfg in /etc/sysconfig/network-scripts/ifcfg-*; do
            [ -f "$cfg" ] && {
                echo ">>> Arquivo: $cfg" >> "$RELATORIO"
                cat "$cfg" >> "$RELATORIO"
                echo >> "$RELATORIO"
            }
        done
    elif command -v nmcli >/dev/null 2>&1; then
        echo "[INFO] NetworkManager detectado" >> "$RELATORIO"
        echo ">>> Conexões:" >> "$RELATORIO"
        nmcli connection show >> "$RELATORIO"
        while read -r conn; do
            [ -z "$conn" ] && continue
            echo "------ $conn ------" >> "$RELATORIO"
            nmcli connection show "$conn" >> "$RELATORIO"
            echo >> "$RELATORIO"
        done < <(nmcli -t -f NAME connection show)
    elif systemctl is-active systemd-networkd >/dev/null 2>&1; then
        echo "[INFO] systemd-networkd detectado" >> "$RELATORIO"
        for netfile in /etc/systemd/network/*.network; do
            [ -f "$netfile" ] && {
                echo ">>> Arquivo: $netfile" >> "$RELATORIO"
                cat "$netfile" >> "$RELATORIO"
                echo >> "$RELATORIO"
            }
        done
    else
        echo "[ALERTA] Nenhum gerenciador de rede conhecido detectado." >> "$RELATORIO"
    fi

    finalizar_etapa "CONFIGURAÇÕES DE REDE" "$linhas_antes"
fi

# Temperatura
executar_etapa "SENSORES DE TEMPERATURA" bash -c 'command -v sensors >/dev/null 2>&1 && sensors || echo "Execute sensors-detect como root."'

# Memtester
if perguntar_execucao "TESTE PARCIAL DE MEMÓRIA (memtester)"; then
    if ! command -v memtester >/dev/null 2>&1; then
        echo -e "${YELLOW}[!] memtester não encontrado. Instalando via gerenciador de pacotes da distro...${RESET}"
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq && apt-get install -y memtester
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y memtester
        elif command -v yum >/dev/null 2>&1; then
            yum install -y memtester
        elif command -v zypper >/dev/null 2>&1; then
            zypper install -y memtester
        else
            echo -e "${RED}[!] Gerenciador de pacotes não identificado. Instale o memtester manualmente.${RESET}"
        fi
    fi

    if ! command -v memtester >/dev/null 2>&1; then
        echo -e "${RED}[!] Falha ao instalar memtester. Etapa cancelada.${RESET}"
        pausar
    else
        while true; do
            echo -ne "${YELLOW}Informe a quantidade de memória em MB para o teste (ex: 512): ${RESET}"
            read -r mem_mb
            if [[ "$mem_mb" =~ ^[0-9]+$ ]] && [ "$mem_mb" -gt 0 ]; then
                break
            else
                echo -e "${RED}Entrada inválida.${RESET}"
            fi
        done
        executar_etapa "TESTE PARCIAL DE MEMÓRIA (${mem_mb} MB)" memtester "${mem_mb}M" 1
    fi
fi

# Velocidade do disco (diretório configurável via TESTE_DISCO_DIR, padrão /tmp)
TESTE_DISCO_DIR="${TESTE_DISCO_DIR:-/tmp}"

if perguntar_execucao "TESTE DE VELOCIDADE DO DISCO ($TESTE_DISCO_DIR)"; then
    adicionar_secao "TESTE DE VELOCIDADE DO DISCO ($TESTE_DISCO_DIR)"

    fs_tipo=$(df -T "$TESTE_DISCO_DIR" 2>/dev/null | awk 'NR==2{print $2}')
    if [ "$fs_tipo" = "tmpfs" ]; then
        echo -e "${YELLOW}[!] Aviso: \"$TESTE_DISCO_DIR\" é tmpfs (RAM); o resultado não reflete a velocidade real do disco.${RESET}"
        echo "[AVISO] $TESTE_DISCO_DIR é tmpfs (RAM); resultado não reflete o disco físico." >> "$RELATORIO"
    fi

    espaco_livre=$(df -Pm "$TESTE_DISCO_DIR" | awk 'NR==2{print $4}')
    if [ -z "$espaco_livre" ] || [ "$espaco_livre" -lt 120 ]; then
        echo -e "${RED}[!] Espaço livre insuficiente em \"$TESTE_DISCO_DIR\" (necessário ~100MB). Etapa cancelada.${RESET}"
        echo "[ERRO] Espaço livre insuficiente em $TESTE_DISCO_DIR." >> "$RELATORIO"
    else
        TEMP_DD_FILE=$(mktemp "${TESTE_DISCO_DIR}/teste_dd.XXXXXX")
        dd if=/dev/zero of="$TEMP_DD_FILE" bs=1M count=100 oflag=direct 2>&1 | limpar_saida | tee -a "$RELATORIO"
        rm -f "$TEMP_DD_FILE"
        TEMP_DD_FILE=""
    fi
    echo >> "$RELATORIO"
    echo -e "${GREEN}[✔] Teste de velocidade executado.${RESET}"
    pausar
fi

executar_etapa "LOGS DE DESLIGAMENTO E REBOOT" bash -c 'last -F -n20 -x shutdown reboot || echo "Nenhum evento encontrado."'

# Verificação de arquivos hs_err no Wildfly (caminho configurável via WILDFLY_BIN)
WILDFLY_BIN="${WILDFLY_BIN:-/usr/wildfly/bin}"
executar_etapa "VERIFICAÇÃO DE ARQUIVOS hs_err NO WILDFLY" bash -c '
wildfly_dir="$1"
if [ -d "$wildfly_dir" ]; then
    echo "[INFO] Acessando diretório $wildfly_dir..."
    cd "$wildfly_dir" || exit 1
    echo "[INFO] Listando arquivos contendo hs_err:"
    ls -lsth | grep "hs_err" || echo "Nenhum arquivo hs_err encontrado."
else
    echo "[ERRO] Diretório $wildfly_dir não encontrado."
fi
' _ "$WILDFLY_BIN"

echo -e "${GREEN}=== Relatório final salvo em: $RELATORIO ===${RESET}"

echo -e "${CYAN}[INFO] Tempo total de execução: ${SECONDS}s${RESET}"
