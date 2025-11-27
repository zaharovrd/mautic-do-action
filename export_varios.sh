# export_varios.sh
# Подставьте свои реальные значения!
export INPUT_SELECTEL_TOKEN="8d4450a0250296b942552205ec95bf67fe3e7ad5a4a49d72e8b2522d4f94f54c"
export INPUT_SSH_PRIVATE_KEY="$(cat ~/.ssh/mautic_test_key)"
export INPUT_EMAIL="test@example.com"
export INPUT_MAUTIC_PASSWORD="SuperSecretPassword123"
export INPUT_MYSQL_PASSWORD="MySqlSecretPassword123"
export INPUT_MYSQL_ROOT_PASSWORD="MySqlRootSecretPassword123"

# Параметры для Selectel
export INPUT_VPS_NAME="mautic-local-test"
export INPUT_VPS_RPLAN="small" # Используйте самый дешевый тариф для теста
export INPUT_VPS_LOCATION="spb0"

# Остальные параметры
export INPUT_MAUTIC_VERSION="6.0.5-apache"
export INPUT_MAUTIC_PORT="8001"
export INPUT_DOMAIN="" # Оставьте пустым для теста по IP
export INPUT_THEMES=""
export INPUT_PLUGINS=""
export INPUT_MYSQL_DATABASE="mautic_db"
export INPUT_MYSQL_USER="mautic_user"

# Очень важная переменная, указывающая на корень проекта
export ACTION_PATH=$(pwd)
