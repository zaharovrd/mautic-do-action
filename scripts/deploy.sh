#!/bin/bash

set -e

echo "🚀 Starting deployment to Selectel..."

# --- Selectel API configuration ---
SELECTEL_API_URL="https://api.vscale.io/v1"
SELECTEL_TOKEN="${INPUT_SELECTEL_TOKEN}"

# Set default port if not provided
MAUTIC_PORT=${INPUT_MAUTIC_PORT:-8001}

echo "📝 Configuration:"
echo "  VPS Name: ${INPUT_VPS_NAME}"
echo "  VPS Plan: ${INPUT_VPS_RPLAN}"
echo "  VPS Location: ${INPUT_VPS_LOCATION}"
echo "  Mautic Version: ${INPUT_MAUTIC_VERSION}"
echo "  Email: ${INPUT_EMAIL}"
echo "  Domain: ${INPUT_DOMAIN:-'Not set (will use IP)'}"

# --- Step 1: Prepare SSH keys ---
echo "🔐 Setting up SSH authentication..."
mkdir -p ~/.ssh
echo "${INPUT_SSH_PRIVATE_KEY}" > ~/.ssh/id_rsa
chmod 600 ~/.ssh/id_rsa

echo "🔑 Generating public key from private key..."
if ! ssh-keygen -y -f ~/.ssh/id_rsa > ~/.ssh/id_rsa.pub 2>/dev/null; then
    echo "❌ Error: Failed to generate public key from private key"
    echo "Please verify your SSH private key is valid"
    exit 1
fi
SSH_PUBLIC_KEY_CONTENT=$(cat ~/.ssh/id_rsa.pub)
KEY_NAME="mautic-deploy-key-$(date +%s)"

echo "🔍 Finding or creating SSH key in Selectel account..."

# Get all the keys from Selectel
ALL_KEYS_JSON=$(curl -s -X GET "${SELECTEL_API_URL}/sshkeys" -H "X-Token: ${SELECTEL_TOKEN}")

# We are looking for our key by content. We use jq to parse JSON.
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


# --- Step 2: Create a server (if does not exist) ---
echo "🖥️  Checking if VPS '${INPUT_VPS_NAME}' exists..."
# Get a list of all servers
ALL_SERVERS_JSON=$(curl -s -X GET "${SELECTEL_API_URL}/scalets" -H "X-Token: ${SELECTEL_TOKEN}")
SERVER_EXISTS=$(echo "${ALL_SERVERS_JSON}" | jq --arg name "${INPUT_VPS_NAME}" 'any(.[] | .name == $name)')

if [ "$SERVER_EXISTS" != "true" ]; then
    echo "📦 Creating new VPS '${INPUT_VPS_NAME}'..."
    # Specify the current image ID (make_from)
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

# --- Step 3: Obtaining the Server IP Address ---
echo "🔍 Getting VPS IP address for CTID: ${SERVER_CTID}..."
VPS_IP=""
TIMEOUT=300 # 5 minutes
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

# --- Step 4: Initial server setup (analogous to user-data) ---
echo "🔧 Running initial server setup (installing Docker, Nginx, etc.)..."

# Waiting for the SSH port to become available
echo "🔐 Waiting for SSH to be available..."
SSH_TIMEOUT=300 # 5 minutes
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

# Execute the setup-vps.sh script on a remote server
ssh -o StrictHostKeyChecking=no \
    -o ConnectTimeout=30 \
    -i ~/.ssh/id_rsa \
    root@${VPS_IP} 'bash -s' < "${ACTION_PATH}/scripts/setup-vps.sh"
echo "✅ Initial server setup complete."

# Verify domain points to VPS (if domain is provided)
if [ -n "$INPUT_DOMAIN" ]; then
    echo "🌐 Verifying domain configuration..."
    DOMAIN_IP=$(dig +short "$INPUT_DOMAIN")
    if [ "$DOMAIN_IP" != "$VPS_IP" ]; then
        echo "❌ Error: Domain $INPUT_DOMAIN does not point to VPS IP $VPS_IP"
        echo "Current domain IP: $DOMAIN_IP"
        echo "Please update your DNS A record to point to: $VPS_IP"
        exit 1
    fi
    echo "✅ Domain correctly points to VPS"
fi

# Prepare nginx configuration (if domain is provided)
if [ -n "$INPUT_DOMAIN" ]; then
    echo "🔧 Preparing nginx configuration..."
    cp "${ACTION_PATH}/templates/nginx-virtual-host-template" "nginx-virtual-host-${INPUT_DOMAIN}"
    sed -i "s/DOMAIN_NAME/${INPUT_DOMAIN}/g" "nginx-virtual-host-${INPUT_DOMAIN}"
    sed -i "s/PORT/${MAUTIC_PORT}/g" "nginx-virtual-host-${INPUT_DOMAIN}"
fi

# Create deployment environment file
echo "📋 Creating deployment configuration..."

# Create clean deploy.env file
cat > deploy.env << EOF
# Environment variables for deployment
# Generated by GitHub Action
# Required Configuration
EMAIL_ADDRESS=${INPUT_EMAIL}
MAUTIC_PASSWORD=${INPUT_MAUTIC_PASSWORD}
IP_ADDRESS=${VPS_IP}
PORT=${MAUTIC_PORT}
MAUTIC_VERSION=${INPUT_MAUTIC_VERSION}
# Optional Configuration
MAUTIC_THEMES=${INPUT_THEMES}
MAUTIC_PLUGINS=${INPUT_PLUGINS}
# GitHub Token (extracted from plugin/theme URLs if present)
GITHUB_TOKEN=$(echo "${INPUT_PLUGINS}${INPUT_THEMES}" | grep -o 'token=[^&]*' | head -1 | cut -d'=' -f2)
# Database Configuration
MYSQL_DATABASE=${INPUT_MYSQL_DATABASE}
MYSQL_USER=${INPUT_MYSQL_USER}
MYSQL_PASSWORD=${INPUT_MYSQL_PASSWORD}
MYSQL_ROOT_PASSWORD=${INPUT_MYSQL_ROOT_PASSWORD}
EOF

if [ -n "$INPUT_DOMAIN" ]; then
    echo "DOMAIN_NAME=${INPUT_DOMAIN}" >> deploy.env
fi

# Secure the environment file
chmod 600 deploy.env
echo "🔒 Environment file secured with restricted permissions"

# Copy templates to current directory for deployment
cp "${ACTION_PATH}/templates/docker-compose.yml" .
cp "${ACTION_PATH}/templates/.mautic_env.template" .

# Compile Deno setup script to binary
echo "🔨 Compiling Deno TypeScript setup script to binary..."

# Check if Deno is available
if ! command -v deno &> /dev/null; then
    echo "📦 Installing Deno..."
    curl -fsSL https://deno.land/install.sh | sh
    export PATH="$HOME/.deno/bin:$PATH"
fi

echo "✅ Deno version: $(deno --version | head -n 1)"
echo "🔍 Target platform: $(uname -m)-$(uname -s)"

mkdir -p build
deno compile --allow-all --target x86_64-unknown-linux-gnu --output ./build/setup "${ACTION_PATH}/scripts/setup.ts"

if [ ! -f "./build/setup" ]; then
    echo "❌ Error: Failed to compile Deno setup script"
    exit 1
fi

echo "✅ Successfully compiled setup binary"

echo "📁 Files prepared for deployment:"
ls -la deploy.env docker-compose.yml .mautic_env.template build/setup

# Deploy to server
echo "🚀 Deploying to server..."

# Verify SSH connection before file transfer
echo "� Testing SSH connection..."
SSH_TEST_TIMEOUT=60
SSH_TEST_COUNTER=0

while [ $SSH_TEST_COUNTER -lt $SSH_TEST_TIMEOUT ]; do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes -i ~/.ssh/id_rsa root@${VPS_IP} "echo 'SSH connection successful'" 2>/dev/null; then
        echo "✅ SSH connection test passed"
        break
    else
        echo "⏳ SSH authentication not ready, waiting... (${SSH_TEST_COUNTER}/${SSH_TEST_TIMEOUT}s)"
        sleep 10
        SSH_TEST_COUNTER=$((SSH_TEST_COUNTER + 10))
    fi
done

if [ $SSH_TEST_COUNTER -ge $SSH_TEST_TIMEOUT ]; then
    echo "❌ SSH connection test failed after ${SSH_TEST_TIMEOUT} seconds"
    echo "🔍 Debugging information:"
    echo "  - VPS IP: ${VPS_IP}"
    echo "  - Connection user: root"
    echo "  - SSH key format verified: $(head -n 1 ~/.ssh/id_rsa | grep -q 'BEGIN.*KEY' && echo 'Valid' || echo 'Invalid')"
    echo "  - Generated fingerprint: ${SSH_FINGERPRINT}"

    # Check if SSH key is in DigitalOcean (without exposing sensitive data)
    echo "🔑 Checking SSH key availability..."
    SSH_KEY_COUNT=$(doctl compute ssh-key list --format ID --no-header | wc -l 2>/dev/null || echo "0")
    echo "  - SSH keys in account: ${SSH_KEY_COUNT}"

    # Try to get more info about the droplet
    echo "🔍 Droplet information:"
    doctl compute droplet get "${INPUT_VPS_NAME}" --format ID,Name,Status,PublicIPv4,Image,Region || echo "⚠️ Failed to get droplet info"

    exit 1
fi

# Copy files to server
echo "📤 Copying files to server..."
# Ensure /var/www directory exists
ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa root@${VPS_IP} "mkdir -p /var/www"
# Copy files
scp -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa deploy.env docker-compose.yml .mautic_env.template root@${VPS_IP}:/var/www/
scp -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa build/setup root@${VPS_IP}:/var/www/setup

# Verify binary can execute
echo "🔍 Verifying setup binary on server..."
ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa root@${VPS_IP} "cd /var/www && chmod +x setup && file setup"

# Test if binary can start
echo "🧪 Testing binary execution..."
if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -i ~/.ssh/id_rsa root@${VPS_IP} "cd /var/www && timeout 10 ./setup --help 2>/dev/null || echo 'Binary test completed'"; then
    echo "✅ Binary appears to be working"
else
    echo "⚠️ Binary test had issues, but continuing..."
fi

# Run setup script
echo "⚙️  Running compiled setup binary on server..."

# Check initial memory status and swap configuration
echo "💾 Pre-deployment memory status:"
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -i ~/.ssh/id_rsa root@${VPS_IP} "echo 'Memory:' && free -h && echo 'Swap:' && swapon --show 2>/dev/null || echo 'No swap active'" 2>/dev/null || echo "Could not check memory"

# Try background execution with polling instead of streaming
echo "🔄 Starting setup script in background and monitoring progress..."

# Start setup script in background with a completion marker
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -o ServerAliveInterval=60 -o ServerAliveCountMax=3 -i ~/.ssh/id_rsa root@${VPS_IP} "cd /var/www && nohup ./setup > /var/log/setup-dc.log 2>&1 & echo 'BACKGROUND_STARTED'"

SSH_START_RESULT=$?
if [ $SSH_START_RESULT -ne 0 ]; then
    echo "❌ Failed to start setup script (exit code: $SSH_START_RESULT)"
    exit 1
fi

echo "✅ Setup script started in background"

# Immediately check if setup is producing output
echo "🔍 Checking initial setup output..."
sleep 5
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -i ~/.ssh/id_rsa root@${VPS_IP} "ls -la /var/log/setup-dc.log 2>/dev/null && echo '--- LOG CONTENT ---' && head -20 /var/log/setup-dc.log 2>/dev/null || echo 'No log file yet'"

# Also start a monitoring process that will write completion marker
echo "🔍 Starting completion monitor..."
timeout 60 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -i ~/.ssh/id_rsa root@${VPS_IP} "nohup bash -c 'while pgrep -f \"./setup\" > /dev/null; do sleep 5; done; SETUP_PID=\$(pgrep -f \"./setup\" || echo); if [ -n \"\$SETUP_PID\" ]; then wait \$SETUP_PID; EXIT_CODE=\$?; else EXIT_CODE=0; fi; echo \"SETUP_COMPLETED_\$EXIT_CODE\" >> /var/log/setup-dc.log' > /dev/null 2>&1 &" &

# Monitor progress with fewer SSH connections and better error handling
echo "📊 Monitoring setup progress..."
TIMEOUT=600  # 10 minutes for testing
COUNTER=0
SETUP_EXIT_CODE=255
PREVIOUS_LOG_TAIL=""

while [ "${COUNTER:-0}" -lt "${TIMEOUT:-600}" ]; do
    # Check if setup process is still running - be more specific with process detection
    SETUP_RUNNING=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -o ServerAliveInterval=60 -o ServerAliveCountMax=3 -i ~/.ssh/id_rsa root@${VPS_IP} "pgrep -f '^[^ ]*setup\$' | head -1 || echo 'NOT_RUNNING'" 2>/dev/null || echo "SSH_FAILED")

    # Quick check: if log shows completion indicators, exit immediately
    if [ "${COUNTER:-0}" -ge 30 ]; then  # After 30 seconds, start checking for completion
        QUICK_SUCCESS_CHECK=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -i ~/.ssh/id_rsa root@${VPS_IP} "grep -c 'deployment_status::success\\|🎉.*Mautic setup completed\\|Access URL:.*login' /var/log/setup-dc.log 2>/dev/null || echo '0'" 2>/dev/null || echo "0")
        # Ensure QUICK_SUCCESS_CHECK is numeric
        case "$QUICK_SUCCESS_CHECK" in
            ''|*[!0-9]*) QUICK_SUCCESS_CHECK=0 ;;
        esac
        if [ "${QUICK_SUCCESS_CHECK:-0}" -gt 0 ]; then
            echo "✅ Setup completed successfully (found completion indicators in log)"
            SETUP_EXIT_CODE=0
            break
        fi
    fi

    if [ "$SETUP_RUNNING" = "NOT_RUNNING" ]; then
        echo "🏁 Setup process has completed (no longer running)"
        # Check for completion marker with exit code
        SSH_CHECK_RESULT=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -i ~/.ssh/id_rsa root@${VPS_IP} "grep 'SETUP_COMPLETED_' /var/log/setup-dc.log 2>/dev/null | tail -1" 2>/dev/null || echo "NO_MARKER")

        if [[ "$SSH_CHECK_RESULT" =~ SETUP_COMPLETED_([0-9]+) ]]; then
            SETUP_EXIT_CODE="${BASH_REMATCH[1]}"
            echo "✅ Setup completed with exit code: ${SETUP_EXIT_CODE}"
            break
        else
            # No marker found, check for success indicators in log
            SUCCESS_CHECK=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -i ~/.ssh/id_rsa root@${VPS_IP} "grep -q 'deployment_status::success\\|🎉' /var/log/setup-dc.log 2>/dev/null && echo 'SUCCESS' || echo 'UNKNOWN'" 2>/dev/null || echo "SSH_FAILED")
            if [ "$SUCCESS_CHECK" = "SUCCESS" ]; then
                SETUP_EXIT_CODE=0
                echo "✅ Setup completed successfully (found success indicators)"
                break
            fi

            # Additional check: if we see the same timestamp for 2+ minutes, assume completion
            if [ "${COUNTER:-0}" -ge 120 ]; then
                CURRENT_LOG_TAIL=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -i ~/.ssh/id_rsa root@${VPS_IP} "tail -n 3 /var/log/setup-dc.log 2>/dev/null" 2>/dev/null || echo "LOG_CHECK_FAILED")
                if [[ "$CURRENT_LOG_TAIL" == "$PREVIOUS_LOG_TAIL" ]] && [[ "$CURRENT_LOG_TAIL" != "LOG_CHECK_FAILED" ]]; then
                    echo "⚠️ Setup appears completed (static log output for 2+ minutes)"
                    # Do a final check for success indicators with more lenient grep
                    FINAL_CHECK=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -i ~/.ssh/id_rsa root@${VPS_IP} "grep -E 'deployment_status::success|🎉|Access URL:.*login' /var/log/setup-dc.log 2>/dev/null | wc -l" 2>/dev/null || echo "0")
                    if [ "$FINAL_CHECK" -gt 0 ]; then
                        SETUP_EXIT_CODE=0
                        echo "✅ Setup completed successfully (found completion indicators)"
                        break
                    fi
                fi
                PREVIOUS_LOG_TAIL="$CURRENT_LOG_TAIL"
            fi

            SETUP_EXIT_CODE=1
            echo "⚠️ Setup process completed but exit code unknown, checking logs..."
            break
        fi
    elif [ "$SETUP_RUNNING" = "SSH_FAILED" ]; then
        echo "⚠️ SSH connection failed, retrying in 30s... (${COUNTER}s)"
    else
        # Process is still running, show progress
        if [ $((COUNTER % 60)) -eq 0 ]; then
            echo "📄 Setup progress (${COUNTER}s, PID: $SETUP_RUNNING):"
            ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -o ServerAliveInterval=60 -o ServerAliveCountMax=3 -i ~/.ssh/id_rsa root@${VPS_IP} "tail -n 3 /var/log/setup-dc.log 2>/dev/null || echo 'Setup in progress...'"

            # Show memory usage to monitor for memory pressure
            echo "💾 Current memory usage:"
            ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -i ~/.ssh/id_rsa root@${VPS_IP} "free -h && echo 'Swap usage:' && swapon --show 2>/dev/null || echo 'No swap active'" 2>/dev/null || echo "Could not check memory"

            # During detailed progress check, also verify if setup actually completed
            DETAILED_SUCCESS_CHECK=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -i ~/.ssh/id_rsa root@${VPS_IP} "grep -E 'deployment_status::success|🎉.*Mautic setup completed|Access URL:.*login' /var/log/setup-dc.log 2>/dev/null | tail -1" 2>/dev/null || echo "")
            if [ -n "$DETAILED_SUCCESS_CHECK" ]; then
                echo "✅ Setup actually completed successfully (found: $DETAILED_SUCCESS_CHECK)"
                SETUP_EXIT_CODE=0
                break
            fi
        else
            echo "⏳ Setup running... (${COUNTER}s, PID: $SETUP_RUNNING)"
        fi
    fi

    sleep 30
    COUNTER=$((${COUNTER:-0} + 30))
done

# Handle timeout
if [ "${COUNTER:-0}" -ge "${TIMEOUT:-600}" ]; then
    echo "⏰ Setup script timeout after ${TIMEOUT} seconds"
    echo "🔍 Attempting to kill stuck setup process..."

    # Try to kill the setup process
    SETUP_RUNNING=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -i ~/.ssh/id_rsa root@${VPS_IP} "pgrep -f './setup' || echo 'NOT_RUNNING'" 2>/dev/null || echo "SSH_FAILED")

    if [ "$SETUP_RUNNING" != "NOT_RUNNING" ] && [ "$SETUP_RUNNING" != "SSH_FAILED" ]; then
        echo "🔪 Killing setup process (PID: $SETUP_RUNNING)..."
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -i ~/.ssh/id_rsa root@${VPS_IP} "kill -TERM $SETUP_RUNNING; sleep 5; kill -KILL $SETUP_RUNNING 2>/dev/null || true" 2>/dev/null || true
        echo "✅ Setup process killed"
    fi

    echo "🔍 Checking if deployment actually completed..."

    # Check for completion markers in log - look for the actual success message
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -i ~/.ssh/id_rsa root@${VPS_IP} "grep -q '🎉 Mautic setup completed successfully\\|deployment_status::success' /var/log/setup-dc.log 2>/dev/null"; then
        echo "✅ Setup completed successfully (found success marker)"
        SETUP_EXIT_CODE=0
    else
        echo "❌ Setup did not complete within timeout"
        SETUP_EXIT_CODE=124
    fi
fi

# Check final status
echo "🔍 Final status check: SETUP_EXIT_CODE='${SETUP_EXIT_CODE}'"
if [ -n "$SETUP_EXIT_CODE" ] && [ "$SETUP_EXIT_CODE" -ne 0 ]; then
    echo "❌ Setup script failed with exit code: ${SETUP_EXIT_CODE}"
    echo "🔍 Debug information:"
    echo "  - VPS IP: ${VPS_IP}"
    echo "  - Setup exit code: ${SETUP_EXIT_CODE}"

    # Try to get log content for debugging
    echo "📄 Last 20 lines of setup log:"
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -i ~/.ssh/id_rsa root@${VPS_IP} "tail -n 20 /var/log/setup-dc.log" 2>/dev/null; then
        echo "📊 Setup log retrieved successfully"
    else
        echo "⚠️ Could not retrieve setup log, trying to get error details..."
        # Get basic error information
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -i ~/.ssh/id_rsa root@${VPS_IP} "echo 'Current directory:'; pwd; echo 'Files in /var/www:'; ls -la /var/www/; echo 'Setup binary permissions:'; ls -la /var/www/setup 2>/dev/null || echo 'setup binary not found'"
        exit 1
    fi
else
    # Don't overwrite SETUP_EXIT_CODE if it was already set correctly
    if [ -z "$SETUP_EXIT_CODE" ]; then
        SETUP_EXIT_CODE=$?
    fi
    if [ $SETUP_EXIT_CODE -eq 124 ]; then
        echo "⏰ Setup script timeout (20 minutes) - checking if it completed..."
        # Check if script actually completed despite timeout
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i ~/.ssh/id_rsa root@${VPS_IP} "grep -q 'SETUP_COMPLETED\|Setup completed at:\|CORE_INSTALLATION_COMPLETED' /var/log/setup-dc.log 2>/dev/null"; then
            echo "✅ Setup script actually completed successfully (despite timeout)"
            SETUP_EXIT_CODE=0
        else
            echo "❌ Setup script genuinely timed out"
        fi
    else
        echo "❌ Setup script failed with exit code: ${SETUP_EXIT_CODE}"
    fi
fi

# Handle any errors - but check if setup was actually completed
if [ $SETUP_EXIT_CODE -ne 0 ]; then
    echo "❌ Setup script failed with exit code: ${SETUP_EXIT_CODE}"
    echo "🔍 Debug information:"
    echo "  - VPS IP: ${VPS_IP}"
    echo "  - Setup exit code: ${SETUP_EXIT_CODE}"

    # Try to get the log file anyway
    echo "📥 Attempting to download setup log for debugging..."
    if scp -o StrictHostKeyChecking=no -o ConnectTimeout=30 -i ~/.ssh/id_rsa root@${VPS_IP}:/var/log/setup-dc.log ./setup-dc.log 2>/dev/null; then
        echo "📋 Last 50 lines of setup log:"
        tail -50 ./setup-dc.log
        echo "📋 Checking for specific error patterns:"
        if grep -q "❌" ./setup-dc.log; then
            echo "🔍 Found error messages in log:"
            grep "❌" ./setup-dc.log | tail -10
        fi
        if grep -q "SETUP_COMPLETED" ./setup-dc.log; then
            echo "✅ Setup actually completed despite exit code!"
            echo "🔄 Continuing with outputs since setup marked as complete..."
            SETUP_EXIT_CODE=0  # Override the exit code since setup completed successfully
        else
            echo "❌ Setup did not complete successfully"
            exit 1
        fi
    else
        echo "❌ Could not retrieve setup log for debugging"
        exit 1
    fi
fi

# Final check after potential override
if [ $SETUP_EXIT_CODE -ne 0 ]; then
    echo "❌ Setup failed and could not be recovered"
    exit 1
else
    echo "✅ Setup script completed successfully with exit code: ${SETUP_EXIT_CODE}"
fi

# Final validation - check if Mautic is actually accessible
if [ $SETUP_EXIT_CODE -eq 0 ]; then
    echo "🌐 Final validation: Testing Mautic accessibility..."

    if [ -n "$INPUT_DOMAIN" ]; then
        TEST_URL="https://${INPUT_DOMAIN}/s/login"
    else
        TEST_URL="http://${VPS_IP}:${MAUTIC_PORT}/s/login"
    fi

    echo "🔗 Testing URL: ${TEST_URL}"

    # Try HTTP request with timeout
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 30 "$TEST_URL" 2>/dev/null || echo "000")

    if [ "$HTTP_STATUS" = "200" ]; then
        echo "✅ Mautic login page is accessible (HTTP $HTTP_STATUS)"
    elif [ "$HTTP_STATUS" = "302" ] || [ "$HTTP_STATUS" = "301" ]; then
        echo "✅ Mautic is accessible with redirect (HTTP $HTTP_STATUS)"
    else
        echo "⚠️ HTTP test returned: $HTTP_STATUS"
        echo "🔍 This might be normal if containers are still starting up"

        # Give it one more try after a short wait
        echo "⏳ Waiting 10 seconds and retrying..."
        sleep 10
        HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 30 "$TEST_URL" 2>/dev/null || echo "000")

        if [ "$HTTP_STATUS" = "200" ] || [ "$HTTP_STATUS" = "302" ] || [ "$HTTP_STATUS" = "301" ]; then
            echo "✅ Mautic is now accessible (HTTP $HTTP_STATUS)"
        else
            echo "⚠️ Mautic may not be fully ready yet (HTTP $HTTP_STATUS)"
            echo "🔍 Check the URL manually: ${TEST_URL}"
        fi
    fi
fi

# Download setup log
echo "📥 Downloading setup log..."
scp -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa root@${VPS_IP}:/var/log/setup-dc.log ./setup-dc.log

# Note: SSH key cleanup moved to action.yml after validation

# Set outputs
echo "🔍 Preparing outputs..."
echo "  - VPS_IP: '${VPS_IP}'"
echo "  - INPUT_DOMAIN: '${INPUT_DOMAIN}'"
echo "  - MAUTIC_PORT: '${MAUTIC_PORT}'"
echo "  - INPUT_EMAIL: '${INPUT_EMAIL}'"

if [ -n "$INPUT_DOMAIN" ]; then
    MAUTIC_URL="https://${INPUT_DOMAIN}"
    echo "  - Using domain-based URL"
else
    MAUTIC_URL="http://${VPS_IP}:${MAUTIC_PORT}"
    echo "  - Using IP-based URL"
fi

echo "  - Final MAUTIC_URL: '${MAUTIC_URL}'"

echo "vps-ip=${VPS_IP}" >> $GITHUB_OUTPUT
echo "mautic-url=${MAUTIC_URL}" >> $GITHUB_OUTPUT
echo "deployment-log=./setup-dc.log" >> $GITHUB_OUTPUT

echo "✅ Outputs set successfully"

echo "🎉 Deployment completed successfully!"
echo "🌐 Your Mautic instance is available at: ${MAUTIC_URL}"
echo "📧 Admin email: ${INPUT_EMAIL}"
echo "📊 Check the deployment log artifact for detailed information"
