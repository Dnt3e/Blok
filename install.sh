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
    sudo apt install -y python3 python3-venv python3-pip curl

    mkdir -p "$PROJECT"
    cd "$PROJECT"

# ================= BOT CODE =================
cat <<'PYCODE' > telegram_instabot.py
#!/usr/bin/env python3
import os, json, asyncio, subprocess
from pathlib import Path
from datetime import datetime
import instaloader

from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import (
    ApplicationBuilder, CommandHandler,
    CallbackQueryHandler, MessageHandler,
    ContextTypes, filters
)

# ---------- Paths ----------
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

# ---------- Instagram (posts only) ----------
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

# ---------- Utils ----------
def save():
    USERS.write_text(json.dumps(users, indent=2))
    STATE.write_text(json.dumps(state, indent=2))

def ensure(uid):
    if uid not in users:
        users[uid] = {
            "role": "admin" if uid == ADMIN_ID else "user",
            "blocked": False,
            "accounts": []
        }
        save()

def admin(uid): return users.get(uid, {}).get("role") == "admin"

async def send_file(path, chat, ctx, caption=""):
    with open(path, "rb") as f:
        await ctx.bot.send_document(chat, f, caption=caption)
    os.remove(path)

# ---------- Story Downloader (Playwright) ----------
async def fetch_story(username, chat_id, ctx):
    out_dir = DOWNLOADS / f"story_{username}"
    out_dir.mkdir(exist_ok=True)

    script = f"""
from playwright.sync_api import sync_playwright
import requests, os, time

url = "https://insta-stories-viewer.com/{username}/"
out = "{out_dir}"

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page()
    page.goto(url, timeout=60000)
    page.wait_for_timeout(6000)

    media = page.query_selector_all("video source, img")
    urls = set()

    for m in media:
        src = m.get_attribute("src")
        if src and ("mp4" in src or "jpg" in src or "jpeg" in src):
            urls.add(src)

    for u in urls:
        name = u.split("?")[0].split("/")[-1]
        r = requests.get(u, timeout=20)
        if r.status_code == 200:
            with open(os.path.join(out, name), "wb") as f:
                f.write(r.content)

    browser.close()
"""

    proc = await asyncio.create_subprocess_shell(
        f"python3 - <<'EOF'\n{script}\nEOF",
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE
    )

    await proc.communicate()

    files = list(out_dir.glob("*"))
    if not files:
        await ctx.bot.send_message(chat_id, "⚠️ No public stories found")
        return

    for f in files:
        await send_file(f, chat_id, ctx, caption=f"Story @{username}")

# ---------- Menu ----------
def menu(uid):
    buttons = [
        [InlineKeyboardButton("➕ Add Account", callback_data="add")],
        [InlineKeyboardButton("⬇️ Fetch", callback_data="fetch")]
    ]
    if admin(uid):
        buttons.append([InlineKeyboardButton("🔐 Upload Session", callback_data="session")])
    return InlineKeyboardMarkup(buttons)

# ---------- Handlers ----------
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
        await q.edit_message_text("Send Instagram username:")
    elif q.data == "fetch":
        await q.edit_message_text("Checking...")
        for a in users[uid]["accounts"]:
            await fetch_account(a, q.message.chat_id, ctx)
        await q.edit_message_text("Done", reply_markup=menu(uid))
    elif q.data == "session" and admin(uid):
        ctx.user_data["await"] = "session"
        await q.edit_message_text("Send session file:")

async def text(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    uid = str(update.effective_user.id)
    ensure(uid)

    if ctx.user_data.get("await") == "add":
        users[uid]["accounts"].append(update.message.text.strip().replace("@",""))
        save()
        ctx.user_data.clear()
        await update.message.reply_text("Added", reply_markup=menu(uid))

async def receive_session(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    uid = str(update.effective_user.id)
    if not admin(uid): return
    if ctx.user_data.get("await") != "session": return

    doc = update.message.document
    file = await doc.get_file()
    await file.download_to_drive(SESSION)
    L.load_session_from_file(filename=str(SESSION))
    ctx.user_data.clear()
    await update.message.reply_text("✅ Session loaded")

# ---------- Fetch ----------
async def fetch_account(username, chat_id, ctx):
    # Posts
    try:
        p = instaloader.Profile.from_username(L.context, username)
    except:
        return

    last = state.get(username, {})
    for post in p.get_posts():
        if last.get("post") and post.date_utc <= datetime.fromisoformat(last["post"]):
            break
        L.download_post(post, target=username)
        for r, _, f in os.walk(DOWNLOADS / username):
            for x in f:
                await send_file(os.path.join(r, x), chat_id, ctx)
        last["post"] = post.date_utc.isoformat()
        break

    state[username] = last
    save()

    # Stories (no login)
    await fetch_story(username, chat_id, ctx)

# ---------- Main ----------
def main():
    app = ApplicationBuilder().token(BOT_TOKEN).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CallbackQueryHandler(cb))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, text))
    app.add_handler(MessageHandler(filters.Document.ALL, receive_session))
    app.run_polling()

if __name__ == "__main__":
    main()
PYCODE
# ================= END BOT =================

# ---------- config ----------
cat <<EOF > config.json
{
  "bot_token": "$BOT_TOKEN",
  "admin_id": $ADMIN_ID
}
EOF

python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install python-telegram-bot==22.3 instaloader playwright requests
playwright install chromium

sudo tee /etc/systemd/system/$SERVICE.service >/dev/null <<EOF
[Unit]
Description=Telegram Instagram Bot
After=network.target

[Service]
WorkingDirectory=$PROJECT
ExecStart=$PROJECT/venv/bin/python telegram_instabot.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable $SERVICE
sudo systemctl start $SERVICE

echo "✅ Bot Installed and Running"
fi

if [ "$C" == "2" ]; then
    sudo systemctl stop $SERVICE || true
    sudo systemctl disable $SERVICE || true
    sudo rm -f /etc/systemd/system/$SERVICE.service
    sudo systemctl daemon-reload
    rm -rf "$PROJECT"
    echo "✅ Bot removed"
fi

if [ "$C" == "3" ]; then sudo systemctl start $SERVICE; fi
if [ "$C" == "4" ]; then sudo systemctl restart $SERVICE; fi
if [ "$C" == "5" ]; then sudo systemctl status $SERVICE; fi
