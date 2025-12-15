#!/bin/bash
set -e

echo "🚀 Installing Instagram Telegram Bot"

sudo apt update
sudo apt install -y python3 python3-venv python3-pip

BASE="$HOME/insta-telegram-bot"
cd "$BASE"

python3 -m venv venv
source venv/bin/activate

pip install --upgrade pip
pip install python-telegram-bot==22.3 instaloader

mkdir -p data/downloads

echo "🔑 Instagram login (برای استوری لازم است)"
read -p "Instagram username (Enter برای رد شدن): " IGUSER
if [ ! -z "$IGUSER" ]; then
  instaloader -l "$IGUSER" --sessionfile data/session
fi

read -p "🤖 Telegram Bot Token: " TOKEN
sed -i "s/PUT-YOUR-TELEGRAM-BOT-TOKEN-HERE/$TOKEN/g" telegram_instabot.py

mkdir -p ~/.config/systemd/user

cat <<EOF > ~/.config/systemd/user/insta_bot.service
[Unit]
Description=Instagram Telegram Bot
After=network.target

[Service]
WorkingDirectory=$BASE
ExecStart=$BASE/venv/bin/python telegram_instabot.py
Restart=always

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable insta_bot
systemctl --user start insta_bot

echo "✅ Bot installed and running"
