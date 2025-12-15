#!/bin/bash
set -e
echo "🚀 Telegram Instagram Bot Installer"

sudo apt update
sudo apt install -y python3 python3-venv python3-pip

cd "$(dirname "$0")"

# MENU
echo "------- MENU -------"
echo "1) Install"
echo "2) Remove"
echo "3) Start"
echo "4) Restart"
echo "5) Status"
read -p "Choose an option (1-5): " CHOICE

if [ "$CHOICE" == "1" ]; then
    read -p "🤖 Telegram Bot Token: " BOT_TOKEN
    read -p "🆔 Telegram Admin ID: " ADMIN_ID
    read -p "⏱ Auto check interval in hours [default 3]: " INTERVAL
    INTERVAL=${INTERVAL:-3}

    # Create config.json
    cat <<EOF > config.json
{
  "bot_token": "$BOT_TOKEN",
  "admin_id": $ADMIN_ID,
  "check_interval_hours": $INTERVAL
}
EOF

    # Create venv and install packages
    python3 -m venv venv
    source venv/bin/activate
    pip install --upgrade pip
    pip install python-telegram-bot==22.3 instaloader

    # SYSTEMD
    sudo tee /etc/systemd/system/insta_bot.service > /dev/null <<EOF
[Unit]
Description=Telegram Instagram Bot
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$(pwd)
ExecStart=$(pwd)/venv/bin/python telegram_instabot.py
Restart=always
RestartSec=5
EOF

    sudo tee /etc/systemd/system/insta_bot.timer > /dev/null <<EOF
[Unit]
Description=Instagram Auto Fetch Timer

[Timer]
OnBootSec=1min
OnUnitActiveSec=${INTERVAL}h
Persistent=true

[Install]
WantedBy=timers.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable insta_bot insta_bot.timer
    sudo systemctl start insta_bot insta_bot.timer
    echo "✅ Bot installed and running"

elif [ "$CHOICE" == "2" ]; then
    sudo systemctl stop insta_bot insta_bot.timer || true
    sudo systemctl disable insta_bot insta_bot.timer || true
    sudo rm -f /etc/systemd/system/insta_bot.service /etc/systemd/system/insta_bot.timer
    sudo systemctl daemon-reload
    rm -rf venv downloads config.json users.json state.json session
    echo "🗑 Bot completely removed"

elif [ "$CHOICE" == "3" ]; then
    sudo systemctl start insta_bot
    sudo systemctl start insta_bot.timer
    echo "▶ Bot started"

elif [ "$CHOICE" == "4" ]; then
    sudo systemctl restart insta_bot
    sudo systemctl restart insta_bot.timer
    echo "🔄 Bot restarted"

elif [ "$CHOICE" == "5" ]; then
    sudo systemctl status insta_bot

else
    echo "❌ Invalid choice"
fi
