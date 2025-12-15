#!/bin/bash
set -e

PROJECT="$HOME/Blok"
SERVICE="insta_bot"

echo "1) Install Bot"
echo "2) Remove Bot completely"
echo "3) Start Bot"
echo "4) Restart Bot"
echo "5) Status Bot"
read -p "Choose option [1-5]: " C

if [ "$C" == "1" ]; then
    read -p "Telegram Bot Token: " BOT_TOKEN
    read -p "Telegram Admin ID: " ADMIN_ID

    sudo apt update
    sudo apt install -y python3 python3-venv python3-pip

    mkdir -p "$PROJECT"
    cd "$PROJECT"

cat <<'PYCODE' > telegram_instabot.py
#!/usr/bin/env python3
import os, json, asyncio, requests, hashlib
from pathlib import Path
from datetime import datetime
import instaloader
from bs4 import BeautifulSoup

from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import (
    ApplicationBuilder, CommandHandler, CallbackQueryHandler,
    MessageHandler, ContextTypes, filters
)

# ---------------- Paths ----------------
BASE = Path(__file__).parent
DOWNLOADS = BASE / "downloads"
CONFIG = BASE / "config.json"
USERS = BASE / "users.json"
STATE = BASE / "state.json"
SESSION = BASE / "session"

DOWNLOADS.mkdir(exist_ok=True)
for f in [USERS, STATE]:
    if not f.exists():
        f.write_text("{}")

cfg = json.loads(CONFIG.read_text())
BOT_TOKEN = cfg["bot_token"]
ADMIN_ID = str(cfg["admin_id"])

users = json.loads(USERS.read_text())
state = json.loads(STATE.read_text())

# ---------------- Instagram ----------------
L = instaloader.Instaloader(
    save_metadata=False,
    download_comments=False,
    dirname_pattern=str(DOWNLOADS / "{target}")
)

if SESSION.exists():
    try:
        L.load_session_from_file(filename=str(SESSION))
    except:
        pass

# ---------------- Utils ----------------
def save():
    USERS.write_text(json.dumps(users, indent=2))
    STATE.write_text(json.dumps(state, indent=2))

def ensure(uid):
    if uid not in users:
        users[uid] = {
            "role": "admin" if uid == ADMIN_ID else "user",
            "blocked": False,
            "accounts": [],
            "interval": 30,   # minutes
            "auto": False
        }
        save()

def admin(uid): return users.get(uid, {}).get("role") == "admin"
def blocked(uid): return users.get(uid, {}).get("blocked", False)

async def send_file(path, chat_id, ctx, caption=""):
    with open(path, "rb") as f:
        await ctx.bot.send_document(chat_id, f, caption=caption)
    os.remove(path)

# ---------------- Story Sites ----------------
STORY_SITES = [
    lambda u: f"https://insta-stories-viewer.com/{u}/",
    lambda u: f"https://storiesig.info/en/{u}",
    lambda u: f"https://instadp.com/stories/{u}"
]

async def fetch_story_sites(username, chat_id, ctx):
    headers = {"User-Agent": "Mozilla/5.0"}
    sent = False

    for site in STORY_SITES:
        try:
            r = requests.get(site(username), headers=headers, timeout=15)
            soup = BeautifulSoup(r.text, "html.parser")
            urls = set()

            for v in soup.find_all("video"):
                if v.get("src"): urls.add(v["src"])
            for i in soup.find_all("img"):
                if i.get("src") and "cdn" in i["src"]:
                    urls.add(i["src"])

            for url in urls:
                h = hashlib.md5(url.encode()).hexdigest()
                if state.get(h): continue

                ext = ".mp4" if ".mp4" in url else ".jpg"
                p = DOWNLOADS / f"{username}_{h}{ext}"

                with open(p, "wb") as f:
                    f.write(requests.get(url, headers=headers).content)

                await send_file(p, chat_id, ctx, f"📖 Story @{username}")
                state[h] = True
                sent = True

            if sent:
                save()
                return
        except:
            continue

    if not sent:
        await ctx.bot.send_message(chat_id, "⚠️ No public stories found")

# ---------------- Menu ----------------
def menu(uid):
    buttons = [
        [InlineKeyboardButton("➕ Add Account", callback_data="add")],
        [InlineKeyboardButton("⬇️ Fetch Now", callback_data="fetch")],
        [InlineKeyboardButton("⏱ Set Interval", callback_data="interval")],
        [InlineKeyboardButton("▶️ Start Auto", callback_data="auto_on"),
         InlineKeyboardButton("⏹ Stop Auto", callback_data="auto_off")]
    ]
    if admin(uid):
        buttons.append([InlineKeyboardButton("🔐 Upload Session", callback_data="session")])
        buttons.append([InlineKeyboardButton("👥 Users", callback_data="users")])
    return InlineKeyboardMarkup(buttons)

# ---------------- Handlers ----------------
async def start(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    uid = str(update.effective_user.id)
    ensure(uid)
    await update.message.reply_text("🤖 Bot Ready", reply_markup=menu(uid))

async def cb(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    uid = str(q.from_user.id)
    ensure(uid)

    if q.data == "add":
        ctx.user_data["await"] = "add"
        await q.edit_message_text("Send Instagram username")
    elif q.data == "fetch":
        for a in users[uid]["accounts"]:
            await fetch_account(a, q.message.chat_id, ctx)
        await q.edit_message_text("✅ Done", reply_markup=menu(uid))
    elif q.data == "interval":
        ctx.user_data["await"] = "interval"
        await q.edit_message_text("Send interval in minutes (e.g. 30)")
    elif q.data == "auto_on":
        users[uid]["auto"] = True
        save()
        await q.edit_message_text("▶️ Auto fetch enabled", reply_markup=menu(uid))
    elif q.data == "auto_off":
        users[uid]["auto"] = False
        save()
        await q.edit_message_text("⏹ Auto fetch disabled", reply_markup=menu(uid))
    elif q.data == "session" and admin(uid):
        ctx.user_data["await"] = "session"
        await q.edit_message_text("Send Instagram session file")

async def text(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    uid = str(update.effective_user.id)
    ensure(uid)
    txt = update.message.text.strip()

    if ctx.user_data.get("await") == "add":
        users[uid]["accounts"].append(txt.replace("@",""))
        save()
        ctx.user_data.clear()
        await update.message.reply_text("✅ Added", reply_markup=menu(uid))

    elif ctx.user_data.get("await") == "interval":
        users[uid]["interval"] = int(txt)
        save()
        ctx.user_data.clear()
        await update.message.reply_text("⏱ Interval updated", reply_markup=menu(uid))

async def receive_session(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    uid = str(update.effective_user.id)
    if not admin(uid): return
    doc = update.message.document
    file = await doc.get_file()
    await file.download_to_drive(SESSION)
    L.load_session_from_file(filename=str(SESSION))
    await update.message.reply_text("✅ Session loaded")

# ---------------- Fetch ----------------
async def fetch_account(username, chat_id, ctx):
    try:
        p = instaloader.Profile.from_username(L.context, username)
    except:
        return

    await fetch_story_sites(username, chat_id, ctx)

# ---------------- Scheduler ----------------
async def scheduler(app):
    while True:
        for uid, u in users.items():
            if not u.get("auto"): continue
            for acc in u["accounts"]:
                try:
                    await fetch_account(acc, int(uid), app.bot)
                except:
                    pass
        await asyncio.sleep(60)

# ---------------- Main ----------------
def main():
    app = ApplicationBuilder().token(BOT_TOKEN).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CallbackQueryHandler(cb))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, text))
    app.add_handler(MessageHandler(filters.Document.ALL, receive_session))
    app.create_task(scheduler(app))
    app.run_polling()

if __name__ == "__main__":
    main()
PYCODE

cat <<EOF > config.json
{
  "bot_token": "$BOT_TOKEN",
  "admin_id": $ADMIN_ID
}
EOF

python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install python-telegram-bot==22.3 instaloader requests beautifulsoup4

sudo tee /etc/systemd/system/$SERVICE.service >/dev/null <<EOF
[Unit]
Description=Instagram Bot
After=network.target

[Service]
WorkingDirectory=$PROJECT
ExecStart=$PROJECT/venv/bin/python telegram_instabot.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable $SERVICE
sudo systemctl start $SERVICE
echo "✅ Bot installed and running"
fi
