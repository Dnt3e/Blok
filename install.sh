#!/bin/bash
set -e

echo "🚀 Telegram Instagram Bot Installer"

sudo apt update
sudo apt install -y python3 python3-venv python3-pip

# --------- INPUTS ----------
read -p "🤖 Telegram Bot Token: " BOT_TOKEN
read -p "👤 Telegram Admin Username (without @): " ADMIN_USER

read -p "⏱ Auto check interval in hours (default 3): " INTERVAL
INTERVAL=${INTERVAL:-3}

echo "🔑 Instagram Login (required for stories)"
read -p "Instagram Username: " IG_USER
read -s -p "Instagram Password: " IG_PASS
echo ""

# --------- FILES ----------
cat <<EOF > config.json
{
  "bot_token": "$BOT_TOKEN",
  "admin_username": "$ADMIN_USER",
  "check_interval_hours": $INTERVAL
}
EOF

python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install python-telegram-bot==22.3 instaloader

# --------- INSTAGRAM SESSION ----------
echo "🔐 Logging into Instagram..."
instaloader --login "$IG_USER" --password "$IG_PASS" --sessionfile session || true

# --------- SYSTEMD ----------
mkdir -p ~/.config/systemd/user

cat <<EOF > ~/.config/systemd/user/insta_bot.service
[Unit]
Description=Telegram Instagram Bot

[Service]
WorkingDirectory=$(pwd)
ExecStart=$(pwd)/venv/bin/python telegram_instabot.py
Restart=always

[Install]
WantedBy=default.target
EOF

cat <<EOF > ~/.config/systemd/user/insta_bot.timer
[Timer]
OnBootSec=1min
OnUnitActiveSec=${INTERVAL}h

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable insta_bot insta_bot.timer
systemctl --user start insta_bot insta_bot.timer

echo "✅ Bot installed and running"
