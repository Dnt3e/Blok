#!/bin/bash
set -e

PROJECT="$HOME/Blok"
SERVICE="insta_bot"

echo "1) Install Bot"
echo "2) Remove Bot"
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

    cat <<EOF > config.json
{
  "bot_token": "$BOT_TOKEN",
  "admin_id": "$ADMIN_ID"
}
EOF

    cat <<'PYCODE' > telegram_instabot.py
# ==============================
# Telegram Instagram Bot (FINAL)
# ==============================

import os, json, asyncio
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
SESSION_FILE = BASE / "session"
USERS_FILE = BASE / "users.json"
STATE_FILE = BASE / "state.json"
CONFIG_FILE = BASE / "config.json"

DOWNLOADS.mkdir(exist_ok=True)
for f, default in [(USERS_FILE, {}), (STATE_FILE, {})]:
    if not f.exists():
        f.write_text(json.dumps(default))

cfg = json.loads(CONFIG_FILE.read_text())
BOT_TOKEN = cfg["bot_token"]
ADMIN_ID = str(cfg["admin_id"])

users = json.loads(USERS_FILE.read_text())
state = json.loads(STATE_FILE.read_text())

# ---------- Instagram ----------
L = instaloader.Instaloader(
    save_metadata=False,
    download_comments=False,
    dirname_pattern=str(DOWNLOADS / "{target}")
)

if SESSION_FILE.exists():
    try:
        L.load_session_from_file(filename=str(SESSION_FILE))
    except:
        pass

# ---------- Helpers ----------
def save():
    USERS_FILE.write_text(json.dumps(users, indent=2))
    STATE_FILE.write_text(json.dumps(state, indent=2))

def ensure(uid):
    if uid not in users:
        users[uid] = {
            "role": "admin" if uid == ADMIN_ID else "user",
            "blocked": False,
            "accounts": [],
            "lang": "en"
        }
        save()

def is_admin(uid): return users[uid]["role"] == "admin"
def is_blocked(uid): return users[uid]["blocked"]

async def send_and_clean(path, chat_id, ctx):
    with open(path, "rb") as f:
        await ctx.bot.send_document(chat_id, f)
    os.remove(path)

# ---------- Language ----------
TXT = {
 "en":{
  "start":"🤖 Bot ready",
  "need_session":"❌ Instagram session required for stories",
  "session_ok":"✅ Session is valid",
  "session_bad":"❌ Session expired or invalid"
 },
 "fa":{
  "start":"🤖 ربات آماده است",
  "need_session":"❌ برای استوری نیاز به session است",
  "session_ok":"✅ session معتبر است",
  "session_bad":"❌ session منقضی شده"
 }
}

def menu(uid):
    lang = users[uid]["lang"]
    kb = [
        [InlineKeyboardButton("➕ Add Account", callback_data="add")],
        [InlineKeyboardButton("⬇️ Check New", callback_data="check")],
        [InlineKeyboardButton("🔗 Download Link", callback_data="link")],
        [InlineKeyboardButton("🌐 Language", callback_data="lang")]
    ]
    if is_admin(uid):
        kb.append([InlineKeyboardButton("🔐 Upload IG Session", callback_data="session")])
        kb.append([InlineKeyboardButton("🩺 Session Health", callback_data="health")])
    return InlineKeyboardMarkup(kb)

# ---------- Session Health ----------
def session_health():
    try:
        if not SESSION_FILE.exists():
            return False
        L.load_session_from_file(filename=str(SESSION_FILE))
        return L.context.is_logged_in
    except:
        return False

# ---------- Handlers ----------
async def start(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    uid = str(update.effective_user.id)
    ensure(uid)
    if is_blocked(uid): return
    await update.message.reply_text(
        TXT[users[uid]["lang"]]["start"],
        reply_markup=menu(uid)
    )

async def callbacks(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    uid = str(q.from_user.id)
    ensure(uid)
    await q.answer()

    if q.data == "add":
        ctx.user_data["wait"] = "add"
        await q.edit_message_text("Send Instagram username")

    elif q.data == "link":
        ctx.user_data["wait"] = "link"
        await q.edit_message_text("Send Instagram link")

    elif q.data == "check":
        await q.edit_message_text("Checking...")
        for u in users[uid]["accounts"]:
            await fetch_account(u, q.message.chat_id, ctx)
        await q.edit_message_text("Done", reply_markup=menu(uid))

    elif q.data == "session" and is_admin(uid):
        ctx.user_data["wait"] = "session"
        await q.edit_message_text("Send session-USERNAME file")

    elif q.data == "health" and is_admin(uid):
        ok = session_health()
        await q.edit_message_text(
            TXT[users[uid]["lang"]]["session_ok" if ok else "session_bad"]
        )

    elif q.data == "lang":
        users[uid]["lang"] = "fa" if users[uid]["lang"]=="en" else "en"
        save()
        await q.edit_message_text("Language changed", reply_markup=menu(uid))

async def text_handler(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    uid = str(update.effective_user.id)
    ensure(uid)
    txt = update.message.text.strip()

    if ctx.user_data.get("wait") == "add":
        users[uid]["accounts"].append(txt.replace("@",""))
        save()
        ctx.user_data["wait"] = None
        await update.message.reply_text("Added", reply_markup=menu(uid))

    elif ctx.user_data.get("wait") == "link":
        ctx.user_data["wait"] = None
        await fetch_link(txt, update.message.chat_id, ctx)

async def session_upload(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    uid = str(update.effective_user.id)
    if not is_admin(uid): return
    if ctx.user_data.get("wait") != "session": return

    doc = update.message.document
    file = await doc.get_file()
    await file.download_to_drive(custom_path=str(SESSION_FILE))

    try:
        L.load_session_from_file(filename=str(SESSION_FILE))
        await update.message.reply_text("✅ Session loaded")
    except:
        await update.message.reply_text("❌ Invalid session")

    ctx.user_data["wait"] = None

# ---------- Instagram Fetch ----------
async def fetch_account(username, chat_id, ctx):
    try:
        profile = instaloader.Profile.from_username(L.context, username)
    except:
        return

    last = state.get(username, {})

    for post in profile.get_posts():
        if last.get("post") and post.date_utc <= datetime.fromisoformat(last["post"]):
            break
        L.download_post(post, target=username)
        for r,_,f in os.walk(DOWNLOADS/username):
            for x in f:
                await send_and_clean(os.path.join(r,x), chat_id, ctx)
        last["post"] = post.date_utc.isoformat()

    if L.context.is_logged_in:
        try:
            for story in instaloader.get_stories([profile.userid], L.context):
                for item in story.get_items():
                    if last.get("story") and item.date_utc <= datetime.fromisoformat(last["story"]):
                        continue
                    L.download_storyitem(item, target=username)
                    for r,_,f in os.walk(DOWNLOADS/username):
                        for x in f:
                            await send_and_clean(os.path.join(r,x), chat_id, ctx)
                    last["story"] = item.date_utc.isoformat()
        except:
            pass
    else:
        await ctx.bot.send_message(chat_id, TXT[users[str(chat_id)]["lang"]]["need_session"])

    state[username] = last
    save()

async def fetch_link(url, chat_id, ctx):
    try:
        if "/p/" in url or "/reel/" in url:
            code = url.rstrip("/").split("/")[-1]
            L.download_post(instaloader.Post.from_shortcode(L.context, code), target="link")
        elif "/stories/" in url:
            if not L.context.is_logged_in:
                await ctx.bot.send_message(chat_id, "Login required")
                return
            u = url.split("/stories/")[1].split("/")[0]
            p = instaloader.Profile.from_username(L.context, u)
            for s in instaloader.get_stories([p.userid], L.context):
                for i in s.get_items():
                    L.download_storyitem(i, target="link")
        else:
            return

        for r,_,f in os.walk(DOWNLOADS/"link"):
            for x in f:
                await send_and_clean(os.path.join(r,x), chat_id, ctx)
    except Exception as e:
        await ctx.bot.send_message(chat_id, f"Error: {e}")

# ---------- Watchdog ----------
async def session_watchdog(app):
    while True:
        await asyncio.sleep(21600)
        if not session_health():
            await app.bot.send_message(
                ADMIN_ID,
                "⚠️ Instagram session expired, please upload new session"
            )

# ---------- Main ----------
def main():
    app = ApplicationBuilder().token(BOT_TOKEN).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CallbackQueryHandler(callbacks))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, text_handler))
    app.add_handler(MessageHandler(filters.Document.ALL, session_upload))
    app.create_task(session_watchdog(app))
    app.run_polling()

if __name__ == "__main__":
    main()
PYCODE

    python3 -m venv venv
    source venv/bin/activate
    pip install python-telegram-bot==22.3 instaloader

    sudo tee /etc/systemd/system/$SERVICE.service > /dev/null <<EOF
[Unit]
Description=Telegram Instagram Bot
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

if [ "$C" == "2" ]; then
    sudo systemctl stop $SERVICE
    sudo rm -rf "$PROJECT"
    sudo rm /etc/systemd/system/$SERVICE.service
    sudo systemctl daemon-reload
    echo "Removed"
fi

if [ "$C" == "3" ]; then sudo systemctl start $SERVICE; fi
if [ "$C" == "4" ]; then sudo systemctl restart $SERVICE; fi
if [ "$C" == "5" ]; then sudo systemctl status $SERVICE; fi
