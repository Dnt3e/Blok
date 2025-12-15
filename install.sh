#!/bin/bash
set -e

PROJECT_NAME="Blok"
SERVICE_NAME="insta_bot"
BASE_DIR="$HOME/$PROJECT_NAME"

echo "🚀 Telegram Instagram Bot Installer"
echo "Project directory: $BASE_DIR"
echo "-----------------------------------"

echo "1) Install"
echo "2) Remove"
echo "3) Start"
echo "4) Restart"
echo "5) Status"
read -p "Choose option [1-5]: " OPTION

# ================= INSTALL =================
if [ "$OPTION" == "1" ]; then
    read -p "Telegram Bot Token: " BOT_TOKEN
    read -p "Telegram Admin ID: " ADMIN_ID

    sudo apt update
    sudo apt install -y python3 python3-venv python3-pip

    mkdir -p "$BASE_DIR"
    cd "$BASE_DIR"

    # ---------- create python files ----------
    cat <<'EOF' > telegram_instabot.py
<<PUT_TELEGRAM_INSTABOT_CODE_HERE>>
EOF

    # ---------- config ----------
    cat <<EOF > config.json
{
  "bot_token": "$BOT_TOKEN",
  "admin_id": $ADMIN_ID
}
EOF

    echo "{}" > users.json
    echo "{}" > state.json
    mkdir -p downloads

    # ---------- virtualenv ----------
    python3 -m venv venv
    source venv/bin/activate
    pip install --upgrade pip
    pip install python-telegram-bot==22.3 instaloader

    # ---------- systemd ----------
    sudo tee /etc/systemd/system/$SERVICE_NAME.service > /dev/null <<EOF
[Unit]
Description=Telegram Instagram Bot
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$BASE_DIR
ExecStart=$BASE_DIR/venv/bin/python telegram_instabot.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable $SERVICE_NAME
    sudo systemctl start $SERVICE_NAME

    echo "✅ Installed and started successfully"
    exit 0
fi

# ================= REMOVE =================
if [ "$OPTION" == "2" ]; then
    sudo systemctl stop $SERVICE_NAME || true
    sudo systemctl disable $SERVICE_NAME || true
    sudo rm -f /etc/systemd/system/$SERVICE_NAME.service
    sudo systemctl daemon-reload
    rm -rf "$BASE_DIR"
    echo "🗑 Bot completely removed"
    exit 0
fi

# ================= START =================
if [ "$OPTION" == "3" ]; then
    sudo systemctl start $SERVICE_NAME
    echo "▶ Bot started"
    exit 0
fi

# ================= RESTART =================
if [ "$OPTION" == "4" ]; then
    sudo systemctl restart $SERVICE_NAME
    echo "🔄 Bot restarted"
    exit 0
fi

# ================= STATUS =================
if [ "$OPTION" == "5" ]; then
    sudo systemctl status $SERVICE_NAME
    exit 0
fi

echo "❌ Invalid option"
