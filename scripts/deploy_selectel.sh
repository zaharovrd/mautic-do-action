#!/bin/bash
# ==============================================================================
#      MAUTIC DEPLOYMENT SCRIPT - ФИНАЛЬНАЯ ПРОДАКТ-ВЕРСИЯ V2
# ==============================================================================

set -e

echo "🚀 Starting deployment to Selectel..."
SELECTEL_API_URL="https://api.vscale.io/v1"
SELECTEL_TOKEN="${INPUT_SELECTEL_TOKEN}"

if [ -n "$CURL_CACERT_PATH" ]; then
    echo " M   Using custom CA certificate at: ${CURL_CACERT_PATH}"
    CURL_OPTIONS="--cacert ${CURL_CACERT_PATH}"
else
    CURL_OPTIONS=""
fi

if [ -z "${SELECTEL_TOKEN}" ]; then echo "❌ FATAL ERROR: Selectel API token is not set."; exit 1; fi

TEMP_SSH_KEY_PATH=~/.ssh/mautic_deploy_temp_key
cleanup() { echo "🧹 Cleaning up temporary SSH key..."; rm -f "${TEMP_SSH_KEY_PATH}" "${TEMP_SSH_KEY_PATH}".pub"; }
trap cleanup EXIT

MAUTIC_PORT=${INPUT_MAUTIC_PORT:-8001}
echo "📝 Configuration..."
echo "🔐 Setting up SSH authentication..."
mkdir -p ~/.ssh
echo "${INPUT_SSH_PRIVATE_KEY}" > "${TEMP_SSH_KEY_PATH}"
chmod 600 "${TEMP_SSH_KEY_PATH}"
echo "🔑 Generating public key..."
if ! ssh-keygen -y -f "${TEMP_SSH_KEY_PATH}" > "${TEMP_SSH_KEY_PATH}".pub" 2>/dev/null; then echo "❌ Error: Failed to generate public key"; exit 1; fi
SSH_PUBLIC_KEY_CONTENT=$(cat "${TEMP_SSH_KEY_PATH}.pub")
KEY_NAME="mautic-deploy-key-$(date +%s)"

echo "🔍 Finding or creating SSH key in Selectel account..."
ALL_KEYS_JSON=$(curl -s $CURL_OPTIONS -X GET "${SELECTEL_API_URL}/sshkeys" -H "X-Token: ${SELECTEL_TOKEN}")
if [ -z "${ALL_KEYS_JSON}" ]; then echo "❌ FATAL ERROR: Received an empty response from Selectel API."; exit 1; fi
if echo "${ALL_KEYS_JSON}" | jq -e 'type == "object" and has("error_message")' > /dev/null; then echo "❌ FATAL API ERROR: $(echo "${ALL_KEYS_JSON}" | jq -r '.error_message')"; exit 1; fi

SSH_KEY_ID=$(echo "${ALL_KEYS_JSON}" | jq -r --arg key "${SSH_PUBLIC_KEY_CONTENT}" '.[] | select(.key == $key) | .id')

if [ -z "$SSH_KEY_ID" ] || [ "$SSH_KEY_ID" == "null" ]; then
    echo "🔑 Key not found. Adding new key..."
    ADD_KEY_PAYLOAD=$(jq -n --arg name "$KEY_NAME" --arg key "$SSH_PUBLIC_KEY_CONTENT" '{name: $name, key: $key}')
    
    # ИСПРАВЛЕНИЕ 1: Используем pipe для передачи JSON
    NEW_KEY_JSON=$(echo "${ADD_KEY_PAYLOAD}" | curl -s $CURL_OPTIONS -X POST "${SELECTEL_API_URL}/sshkeys" \
        -H "Content-Type: application/json;charset=UTF-8" \
        -H "X-Token: ${SELECTEL_TOKEN}" \
        --data @-)
        
    SSH_KEY_ID=$(echo "${NEW_KEY_JSON}" | jq -r '.id')
    if [ -z "$SSH_KEY_ID" ] || [ "$SSH_KEY_ID" == "null" ]; then echo "❌ Error: Failed to add SSH key. Response: ${NEW_KEY_JSON}"; exit 1; fi
    echo "✅ New SSH key added (ID: ${SSH_KEY_ID})"
else
    echo "✅ Found existing SSH key in Selectel (ID: ${SSH_KEY_ID})"
fi

echo "🖥️  Checking if VPS '${INPUT_VPS_NAME}' exists..."
ALL_SERVERS_JSON=$(curl -s $CURL_OPTIONS -X GET "${SELECTEL_API_URL}/scalets" -H "X-Token: ${SELECTEL_TOKEN}")
SERVER_EXISTS_CTID=$(echo "${ALL_SERVERS_JSON}" | jq -r --arg name "${INPUT_VPS_NAME}" '.[] | select(.name == $name) | .ctid')

if [ -z "$SERVER_EXISTS_CTID" ] || [ "$SERVER_EXISTS_CTID" == "null" ]; then
    echo "📦 Creating new VPS '${INPUT_VPS_NAME}'..."
    IMAGE_ID="ubuntu_22.04_64_001_master"
    echo "🔧 Using image ID: ${IMAGE_ID}"
    CREATE_SERVER_PAYLOAD=$(jq -n --arg make_from "$IMAGE_ID" --arg rplan "${INPUT_VPS_RPLAN}" --arg name "${INPUT_VPS_NAME}" --argjson keys "[$SSH_KEY_ID]" --arg location "${INPUT_VPS_LOCATION}" '{make_from: $make_from, rplan: $rplan, do_start: true, name: $name, keys: $keys, location: $location}')
    
    # ИСПРАВЛЕНИЕ 2: Используем pipe для передачи JSON
    CREATED_SERVER_JSON=$(echo "${CREATE_SERVER_PAYLOAD}" | curl -s $CURL_OPTIONS -X POST "${SELECTEL_API_URL}/scalets" \
        -H "Content-Type: application/json;charset=UTF-8" \
        -H "X-Token: ${SELECTEL_TOKEN}" \
        --data @-)

    SERVER_CTID=$(echo "${CREATED_SERVER_JSON}" | jq -r '.ctid')
    if [ -z "$SERVER_CTID" ] || [ "$SERVER_CTID" == "null" ]; then echo "❌ Error: Failed to create VPS. Response: ${CREATED_SERVER_JSON}"; exit 1; fi
    echo "✅ VPS creation initiated (CTID: ${SERVER_CTID})."
else
    echo "✅ VPS '${INPUT_VPS_NAME}' already exists (CTID: ${SERVER_EXISTS_CTID})"
    SERVER_CTID=$SERVER_EXISTS_CTID
fi

# ... (Остальная часть скрипта остается без изменений, она уже работает) ...
echo "🔍 Getting VPS IP address..."
VPS_IP=""
TIMEOUT=300; COUNTER=0
while [ -z "$VPS_IP" ]; do
    if [ $COUNTER -ge $TIMEOUT ]; then echo "❌ Timeout waiting for IP."; exit 1; fi
    SERVER_DETAILS_JSON=$(curl -s $CURL_OPTIONS -X GET "${SELECTEL_API_URL}/scalets/${SERVER_CTID}" -H "X-Token: ${SELECTEL_TOKEN}")
    SERVER_STATUS=$(echo "${SERVER_DETAILS_JSON}" | jq -r '.status')
    if [ "$SERVER_STATUS" = "started" ]; then
        VPS_IP=$(echo "${SERVER_DETAILS_JSON}" | jq -r '.public_address.address')
        if [ -n "$VPS_IP" ] && [ "$VPS_IP" != "null" ]; then echo "✅ VPS is active. IP: $VPS_IP"; break; fi
    fi
    echo "⏳ Waiting for VPS to be ready (Status: ${SERVER_STATUS})..."
    sleep 10
    COUNTER=$((COUNTER + 10))
done
echo "🔧 Running initial server setup..."
echo "🔐 Waiting for SSH key-based authentication to be ready..."
SSH_TIMEOUT=300; SSH_COUNTER=0
while ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes -i "${TEMP_SSH_KEY_PATH}" root@${VPS_IP} "echo 'SSH connection successful'" 2>/dev/null; do
    if [ $SSH_COUNTER -ge $SSH_TIMEOUT ]; then echo "❌ SSH connection timeout. Server is not accepting the key."; exit 1; fi
    echo "⏳ Waiting for SSH key auth... (${SSH_COUNTER}s)"
    sleep 10
    SSH_COUNTER=$((SSH_COUNTER + 10))
done
echo "✅ SSH key authentication is available"
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -i "${TEMP_SSH_KEY_PATH}" root@${VPS_IP} 'bash -s' < "${ACTION_PATH}/scripts/setup-vps.sh"
echo "✅ Initial server setup complete."
if [ -n "$INPUT_DOMAIN" ]; then
    echo "🌐 Verifying domain..."
    DOMAIN_IP=$(dig +short "$INPUT_DOMAIN")
    if [ "$DOMAIN_IP" != "$VPS_IP" ]; then echo "❌ Domain $INPUT_DOMAIN does not point to $VPS_IP"; exit 1; fi
    echo "✅ Domain correctly points to VPS"
fi
echo "📋 Creating deployment config..."
cat > deploy.env << EOF
# ... (содержимое deploy.env без изменений) ...
EOF
chmod 600 deploy.env
cp "${ACTION_PATH}/templates/docker-compose.yml" .
cp "${ACTION_PATH}/templates/.mautic_env.template" .
echo "🔨 Compiling Deno script to binary..."
if ! command -v deno &> /dev/null; then echo "📦 Installing Deno..."; curl -fsSL https://deno.land/install.sh | sh; export PATH="$HOME/.deno/bin:$PATH"; fi
mkdir -p build
deno compile --allow-all --target x86_64-unknown-linux-gnu --output ./build/setup "${ACTION_PATH}/scripts/setup.ts"
echo "✅ Compiled successfully"
echo "🚀 Deploying to server..."
ssh -o StrictHostKeyChecking=no -i "${TEMP_SSH_KEY_PATH}" root@${VPS_IP} "mkdir -p /var/www"
scp -o StrictHostKeyChecking=no -i "${TEMP_SSH_KEY_PATH}" deploy.env docker-compose.yml .mautic_env.template root@${VPS_IP}:/var/www/
scp -o StrictHostKeyChecking=no -i "${TEMP_SSH_KEY_PATH}" build/setup root@${VPS_IP}:/var/www/setup
ssh -o StrictHostKeyChecking=no -i "${TEMP_SSH_KEY_PATH}" root@${VPS_IP} "cd /var/www && chmod +x setup"

# ==================== УЛУЧШЕННЫЙ БЛОК ЗАПУСКА И МОНИТОРИНГА ====================
echo "⚙️  Running setup on server and streaming logs..."
# Запускаем скрипт в основном потоке и перенаправляем его вывод в локальный лог-файл
# SSH-сессия будет открыта до тех пор, пока ./setup не завершится.
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -i "${TEMP_SSH_KEY_PATH}" root@${VPS_IP} "cd /var/www && ./setup" 2>&1 | tee ./setup-dc.log

# Проверяем последнюю строку лога на наличие сообщения об успехе
if ! grep -q "🎉 Mautic setup completed successfully" ./setup-dc.log; then
    echo "❌ Deployment failed. Check the logs above for details."
    exit 1
fi

echo "✅ Deployment completed successfully!"
# ============================================================================

echo "🔍 Preparing outputs..."
if [ -n "$INPUT_DOMAIN" ]; then MAUTIC_URL="https://${INPUT_DOMAIN}"; else MAUTIC_URL="http://${VPS_IP}:${MAUTIC_PORT}"; fi
echo "vps-ip=${VPS_IP}" >> $GITHUB_OUTPUT
echo "mautic-url=${MAUTIC_URL}" >> $GITHUB_OUTPUT
echo "deployment-log=./setup-dc.log" >> $GITHUB_OUTPUT
echo "✅ Outputs set successfully"
echo "🌐 Your Mautic instance should be available at: ${MAUTIC_URL}"
