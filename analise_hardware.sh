
# Verifica se o usuário é root
if [ "$EUID" -ne 0 ]; then
    echo -e "\e[31m[ERRO] Este script deve ser executado como root.\e[0m"
    exit 1
fi

#Cores para o terminal
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
CYAN="\e[36m"
RESET="\e[0m"

# Caminho do relatório
RELATORIO="${1:-./relatorio_hardware.txt}"

# Timer
SECONDS=0

# Cabeçalho
clear
echo -e "${CYAN}==============================================================${RESET}"
echo -e "${CYAN} RELATÓRIO DE HARDWARE - \"$(hostname)\"${RESET}"
echo -e "${CYAN} Data: $(date)${RESET}"
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

executar_etapa() {
    local nome="$1"
    shift

    if perguntar_execucao "$nome"; then
        echo -e "${CYAN}===> Iniciando: $nome${RESET}"
        local linhas_antes linhas_depois
        linhas_antes=$(wc -l < "$RELATORIO")

        adicionar_secao "$nome"
        "$@" >> "$RELATORIO" 2>&1
        echo >> "$RELATORIO"

        linhas_depois=$(wc -l < "$RELATORIO")
        echo -e "\n${GREEN}[✔] Etapa \"$nome\" executada.${RESET}\n"
        sed -n "$((linhas_antes+1)),$linhas_depois p" "$RELATORIO"
        echo -e "${CYAN}------------------------------------------------------${RESET}"
        pausar
    else
        echo -e "${YELLOW}[!] Etapa \"$nome\" pulada pelo usuário.${RESET}"
        pausar
    fi
}

# Início do relatório
cat << EOF > "$RELATORIO"
==============================================================
 RELATÓRIO DE HARDWARE - "$(hostname)"
 Data: $(date)
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

# Particionamento com fdisk
if [ "$EUID" -ne 0 ]; then
    echo -e "${YELLOW}[!] fdisk -l requer privilégios de root. Etapa pulada.${RESET}"
else
    executar_etapa "DISCOS - PARTICIONAMENTO (fdisk -l)" fdisk -l
fi

# S.M.A.R.T.
if perguntar_execucao "S.M.A.R.T. DISCO"; then
    if type smartctl >/dev/null 2>&1; then
        DISCO=$(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}' | head -n1)
        if [ -n "$DISCO" ]; then
            executar_etapa "S.M.A.R.T. DISCO ($DISCO)" smartctl -a "$DISCO"
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
    elif type nmcli >/dev/null 2>&1; then
        echo "[INFO] NetworkManager detectado" >> "$RELATORIO"
        echo ">>> Conexões:" >> "$RELATORIO"
        nmcli connection show >> "$RELATORIO"
        IFS=$'\n'
        for conn in $(nmcli -t -f NAME connection show); do
            echo "------ $conn ------" >> "$RELATORIO"
            nmcli connection show "$conn" >> "$RELATORIO"
            echo >> "$RELATORIO"
        done
        unset IFS
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

    linhas_depois=$(wc -l < "$RELATORIO")
    echo -e "${GREEN}[✔] Etapa \"CONFIGURAÇÕES DE REDE\" executada.${RESET}\n"
    sed -n "$((linhas_antes+1)),$linhas_depois p" "$RELATORIO"
    echo -e "${CYAN}------------------------------------------------------${RESET}"
    pausar
fi

# Temperatura
executar_etapa "SENSORES DE TEMPERATURA" bash -c 'type sensors && sensors || echo "Execute sensors-detect como root."'

# Memtester
if perguntar_execucao "TESTE PARCIAL DE MEMÓRIA (memtester)"; then
    if ! type memtester >/dev/null 2>&1; then
        echo -e "${YELLOW}[!] memtester não encontrado. Instalando...${RESET}"
        yum install -y https://rpmfind.net/linux/dag/redhat/el7/en/x86_64/dag/RPMS/memtester-4.2.0-1.el7.rf.x86_64.rpm
    fi

    if ! type memtester >/dev/null 2>&1; then
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

# Velocidade do disco
if perguntar_execucao "TESTE DE VELOCIDADE DO DISCO (/tmp)"; then
    adicionar_secao "TESTE DE VELOCIDADE DO DISCO (/tmp)"
    dd if=/dev/zero of=/tmp/teste_dd bs=1M count=100 oflag=direct 2>&1 | tee -a "$RELATORIO"
    rm -f /tmp/teste_dd
    echo >> "$RELATORIO"
    echo -e "${GREEN}[✔] Teste de velocidade executado.${RESET}"
    pausar
fi

executar_etapa "LOGS DE DESLIGAMENTO E REBOOT" bash -c 'last -F -n20 -x shutdown reboot || echo "Nenhum evento encontrado."'

# Verificação de arquivos hs_err no Wildfly
executar_etapa "VERIFICAÇÃO DE ARQUIVOS hs_err NO WILDFLY" bash -c '
if [ -d /usr/wildfly/bin ]; then
    echo "[INFO] Acessando diretório /usr/wildfly/bin..."
    cd /usr/wildfly/bin || exit 1
    echo "[INFO] Listando arquivos contendo hs_err:"
    ls -lsth | grep "hs_err" || echo "Nenhum arquivo hs_err encontrado."
else
    echo "[ERRO] Diretório /usr/wildfly/bin não encontrado."
fi
'

# Hash e tempo final
echo -e "${GREEN}=== Relatório final salvo em: $RELATORIO ===${RESET}"

# Explicação do hash
echo -e "${CYAN}[INFO] Abaixo está o md5 do relatório.${RESET}"
echo -e "${CYAN}[INFO] Ele serve para verificar a integridade e autenticidade do conteúdo.${RESET}"
echo -e "${CYAN}[INFO] Se o relatório for alterado, esse código mudará completamente.${RESET}"

# Geração e exibição do hash
md5sum "$RELATORIO" | tee -a "$RELATORIO"