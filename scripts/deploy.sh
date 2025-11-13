#!/bin/bash

set -e

echo "🚀 Starting deployment to Selectel..."

# --- Конфигурация Selectel API ---
SELECTEL_API_URL="https://api.vscale.io/v1"
SELECTEL_TOKEN="${INPUT_SELECTEL_TOKEN}" # Используем новый input для токена

# Set default port if not provided
MAUTIC_PORT=${INPUT_MAUTIC_PORT:-8001}

echo "📝 Configuration:"
echo "  VPS Name: ${INPUT_VPS_NAME}"
echo "  VPS Plan: ${INPUT_VPS_RPLAN}" # Новый input
echo "  VPS Location: ${INPUT_VPS_LOCATION}" # Новый input
echo "  Mautic Version: ${INPUT_MAUTIC_VERSION}"
echo "  Email: ${INPUT_EMAIL}"
echo "  Domain: ${INPUT_DOMAIN:-'Not set (will use IP)'}"

# --- Шаг 1: Подготовка SSH ключей ---
echo "🔐 Setting up SSH authentication..."
mkdir -p ~/.ssh
echo "${INPUT_SSH_PRIVATE_KEY}" > ~/.ssh/id_rsa
chmod 600 ~/.ssh/id_rsa

echo "🔑 Generating public key from private key..."
if ! ssh-keygen -y -f ~/.ssh/id_rsa > ~/.ssh/id_rsa.pub 2>/dev/null; then
    echo "❌ Error: Failed to generate public key from private key"
    exit 1
fi
SSH_PUBLIC_KEY_CONTENT=$(cat ~/.ssh/id_rsa.pub)
KEY_NAME="mautic-deploy-key-$(date +%s)"

echo "🔍 Finding or creating SSH key in Selectel account..."

# Получаем все ключи из Selectel
ALL_KEYS_JSON=$(curl -s -X GET "${SELECTEL_API_URL}/sshkeys" -H "X-Token: ${SELECTEL_TOKEN}")

# Ищем наш ключ по содержимому. Используем jq для парсинга JSON.
SSH_KEY_ID=$(echo "${ALL_KEYS_JSON}" | jq -r --arg key "${SSH_PUBLIC_KEY_CONTENT}" '.[] | select(.key == $key) | .id')

if [ -z "$SSH_KEY_ID" ]; then
    echo "🔑 Key not found. Adding a new key to Selectel..."
    ADD_KEY_PAYLOAD=$(jq -n --arg name "$KEY_NAME" --arg key "$SSH_PUBLIC_KEY_CONTENT" '{name: $name, key: $key}')
    
    NEW_KEY_JSON=$(curl -s -X POST "${SELECTEL_API_URL}/sshkeys" \
        -H "Content-Type: application/json;charset=UTF-8" \
        -H "X-Token: ${SELECTEL_TOKEN}" \
        -d "${ADD_KEY_PAYLOAD}")
    
    SSH_KEY_ID=$(echo "${NEW_KEY_JSON}" | jq -r '.id')
    
    if [ -z "$SSH_KEY_ID" ] || [ "$SSH_KEY_ID" == "null" ]; then
        echo "❌ Error: Failed to add SSH key to Selectel account."
        echo "Response: ${NEW_KEY_JSON}"
        exit 1
    fi
    echo "✅ New SSH key added to Selectel (ID: ${SSH_KEY_ID}, Name: ${KEY_NAME})"
else
    echo "✅ Found existing SSH key in Selectel (ID: ${SSH_KEY_ID})"
fi


# --- Шаг 2: Создание сервера (если не существует) ---
echo "🖥️  Checking if VPS '${INPUT_VPS_NAME}' exists..."
# Получаем список всех серверов
ALL_SERVERS_JSON=$(curl -s -X GET "${SELECTEL_API_URL}/scalets" -H "X-Token: ${SELECTEL_TOKEN}")
SERVER_EXISTS=$(echo "${ALL_SERVERS_JSON}" | jq --arg name "${INPUT_VPS_NAME}" 'any(.[] | .name == $name)')

if [ "$SERVER_EXISTS" != "true" ]; then
    echo "📦 Creating new VPS '${INPUT_VPS_NAME}'..."
    # ЗАМЕТКА: Укажите актуальный ID образа (make_from). Например, с Ubuntu 22.04 + Docker.
    # Этот ID нужно найти в документации или панели управления Selectel.
    IMAGE_ID="ubuntu_22.04_64_docker_latest" 
    echo "🔧 Using image ID: ${IMAGE_ID}"

    CREATE_SERVER_PAYLOAD=$(jq -n \
        --arg make_from "$IMAGE_ID" \
        --arg rplan "${INPUT_VPS_RPLAN}" \
        --arg name "${INPUT_VPS_NAME}" \
        --argjson keys "[$SSH_KEY_ID]" \
        --arg location "${INPUT_VPS_LOCATION}" \
        '{make_from: $make_from, rplan: $rplan, do_start: true, name: $name, keys: $keys, location: $location}')

    CREATED_SERVER_JSON=$(curl -s -X POST "${SELECTEL_API_URL}/scalets" \
        -H "Content-Type: application/json;charset=UTF-8" \
        -H "X-Token: ${SELECTEL_TOKEN}" \
        -d "${CREATE_SERVER_PAYLOAD}")

    SERVER_CTID=$(echo "${CREATED_SERVER_JSON}" | jq -r '.ctid')

    if [ -z "$SERVER_CTID" ] || [ "$SERVER_CTID" == "null" ]; then
        echo "❌ Error: Failed to create VPS in Selectel."
        echo "Response: ${CREATED_SERVER_JSON}"
        exit 1
    fi
     echo "✅ VPS creation initiated (CTID: ${SERVER_CTID}). Waiting for it to become active..."
else
    echo "✅ VPS '${INPUT_VPS_NAME}' already exists. Getting its CTID..."
    SERVER_CTID=$(echo "${ALL_SERVERS_JSON}" | jq -r --arg name "${INPUT_VPS_NAME}" '.[] | select(.name == $name) | .ctid')
fi

# --- Шаг 3: Получение IP-адреса сервера ---
echo "🔍 Getting VPS IP address for CTID: ${SERVER_CTID}..."
VPS_IP=""
TIMEOUT=300 # 5 минут
COUNTER=0
while [ -z "$VPS_IP" ]; do
    if [ $COUNTER -ge $TIMEOUT ]; then
        echo "❌ Timeout: Could not get VPS IP address after ${TIMEOUT} seconds."
        exit 1
    fi

    SERVER_DETAILS_JSON=$(curl -s -X GET "${SELECTEL_API_URL}/scalets/${SERVER_CTID}" -H "X-Token: ${SELECTEL_TOKEN}")
    SERVER_STATUS=$(echo "${SERVER_DETAILS_JSON}" | jq -r '.status')
    
    if [ "$SERVER_STATUS" = "started" ]; then
        VPS_IP=$(echo "${SERVER_DETAILS_JSON}" | jq -r '.public_address.address')
        if [ -n "$VPS_IP" ] && [ "$VPS_IP" != "null" ]; then
             echo "✅ VPS is active. IP address: $VPS_IP"
             break
        fi
    fi
    echo "⏳ Waiting for VPS to be ready... (Status: ${SERVER_STATUS}, ${COUNTER}/${TIMEOUT}s)"
    sleep 10
    COUNTER=$((COUNTER + 10))
done

# --- Шаг 4: Первичная настройка сервера (аналог user-data) ---
echo "🔧 Running initial server setup (installing Docker, Nginx, etc.)..."

# Ждем доступности SSH порта
echo "🔐 Waiting for SSH to be available..."
SSH_TIMEOUT=300
SSH_COUNTER=0
while ! nc -z "$VPS_IP" 22; do
    if [ $SSH_COUNTER -ge $SSH_TIMEOUT ]; then
        echo "❌ SSH connection timeout after ${SSH_TIMEOUT} seconds"
        exit 1
    fi
    echo "⏳ Waiting for SSH... (${SSH_COUNTER}/${SSH_TIMEOUT}s)"
    sleep 10
    SSH_COUNTER=$((SSH_COUNTER + 10))
done
echo "✅ SSH is available"

# Выполняем скрипт setup-vps.sh на удаленном сервере
ssh -o StrictHostKeyChecking=no \
    -o ConnectTimeout=30 \
    -i ~/.ssh/id_rsa \
    root@${VPS_IP} 'bash -s' < "${ACTION_PATH}/scripts/setup-vps.sh"
echo "✅ Initial server setup complete."

# ... (Оставшаяся часть скрипта остается почти без изменений) ...

# Verify domain points to VPS (if domain is provided)
if [ -n "$INPUT_DOMAIN" ]; then
    # ... (эта часть остается без изменений) ...
fi

# Prepare nginx configuration (if domain is provided)
if [ -n "$INPUT_DOMAIN" ]; then
    # ... (эта часть остается без изменений) ...
fi

# Create deployment environment file
echo "📋 Creating deployment configuration..."
# ... (эта часть остается без изменений) ...
cat > deploy.env << EOF
# ... (содержимое deploy.env без изменений) ...
EOF

# Compile Deno setup script to binary
echo "🔨 Compiling Deno TypeScript setup script to binary..."
# ... (эта часть остается без изменений) ...

# Deploy to server
echo "🚀 Deploying to server..."
# ... (копирование файлов и запуск setup binary остаются без изменений) ...
echo "📤 Copying files to server..."
ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa root@${VPS_IP} "mkdir -p /var/www"
scp -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa deploy.env docker-compose.yml .mautic_env.template root@${VPS_IP}:/var/www/
scp -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa build/setup root@${VPS_IP}:/var/www/setup

echo "⚙️  Running compiled setup binary on server..."
# Весь блок мониторинга и запуска скрипта setup остается тем же

# ... (весь код, начиная с ssh ... "nohup ./setup ...") ...

# ... (код для установки outputs и финальные сообщения) ...
# Set outputs
echo "🔍 Preparing outputs..."
# ... (эта часть остается без изменений) ...
echo "🎉 Deployment completed successfully!"
