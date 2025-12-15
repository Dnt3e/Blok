#!/bin/bash
set -e

PROJECT="$HOME/Blok"
SERVICE="insta_bot"

echo "1) Install"
echo "2) Remove"
echo "3) Start"
echo "4) Restart"
echo "5) Status"
read -p "Choose option: " C

if [ "$C" == "1" ]; then
  read -p "Telegram Bot Token: " BOT_TOKEN
  read -p "Telegram Admin ID: " ADMIN_ID

  sudo apt update
  sudo apt install -y python3 python3-venv python3-pip

  mkdir -p "$PROJECT"
  cd "$PROJECT"

  # ---------- create bot code automatically ----------
  cat <<'PYCODE' > telegram_instabot.py
#!/usr/bin/env python3
import os, json, sys
from pathlib import Path
from datetime import datetime
import instaloader
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import ApplicationBuilder, CommandHandler, CallbackQueryHandler, MessageHandler, ContextTypes, filters

BASE = Path(__file__).parent
DOWNLOADS = BASE / "downloads"
CONFIG = BASE / "config.json"
USERS = BASE / "users.json"
STATE = BASE / "state.json"
SESSION = BASE / "session"

DOWNLOADS.mkdir(exist_ok=True)
for f, d in [(USERS, {}), (STATE, {})]:
    if not f.exists():
        f.write_text(json.dumps(d))

if not CONFIG.exists():
    print("config.json not found")
    sys.exit(1)

cfg = json.loads(CONFIG.read_text())
BOT_TOKEN = cfg["bot_token"]
ADMIN_ID = str(cfg["admin_id"])

users = json.loads(USERS.read_text())
state = json.loads(STATE.read_text())

L = instaloader.Instaloader(save_metadata=False, download_comments=False, dirname_pattern=str(DOWNLOADS / "{target}"))
if SESSION.exists():
    try: L.load_session_from_file(filename=str(SESSION))
    except: pass

def save():
    USERS.write_text(json.dumps(users, indent=2))
    STATE.write_text(json.dumps(state, indent=2))

def ensure(uid):
    if uid not in users:
        users[uid] = {"role": "admin" if uid == ADMIN_ID else "user", "blocked": False, "accounts": []}
        save()

def admin(uid): return users.get(uid, {}).get("role") == "admin"
def blocked(uid): return users.get(uid, {}).get("blocked")

async def send_file(p, chat, ctx):
    with open(p, "rb") as f:
        await ctx.bot.send_document(chat, f)
    os.remove(p)

def menu(a=False):
    b = [
        [InlineKeyboardButton("➕ Add Account", callback_data="add")],
        [InlineKeyboardButton("⬇️ Check New", callback_data="fetch")],
        [InlineKeyboardButton("🔗 Download Link", callback_data="link")]
    ]
    if a: b.append([InlineKeyboardButton("👥 Users", callback_data="users")])
    return InlineKeyboardMarkup(b)

async def start(update: Update, ctx):
    uid = str(update.effective_user.id)
    ensure(uid)
    if blocked(uid): return
    await update.message.reply_text("Bot ready", reply_markup=menu(admin(uid)))

async def login(update: Update, ctx):
    if not admin(str(update.effective_user.id)): return
    try:
        u, p = ctx.args
        L.login(u, p)
        L.save_session_to_file(SESSION)
        await update.message.reply_text("Instagram logged in")
    except:
        await update.message.reply_text("Login failed")

async def cb(update: Update, ctx):
    q = update.callback_query
    await q.answer()
    uid = str(q.from_user.id)
    if blocked(uid): return

    if q.data == "add":
        ctx.user_data["w"] = "add"
        await q.edit_message_text("Send Instagram username")

    elif q.data == "fetch":
        await q.edit_message_text("Checking...")
        for a in users[uid]["accounts"]:
            await fetch_account(a, q.message.chat_id, ctx)
        await q.edit_message_text("Done", reply_markup=menu(admin(uid)))

    elif q.data == "link":
        ctx.user_data["w"] = "link"
        await q.edit_message_text("Send link")

    elif q.data == "users" and admin(uid):
        txt = "\n".join(f"{u} | {d['role']} | blocked={d['blocked']}" for u,d in users.items())
        await q.edit_message_text(txt)

async def text(update: Update, ctx):
    uid = str(update.effective_user.id)
    ensure(uid)
    if blocked(uid): return
    t = update.message.text.strip()

    if ctx.user_data.get("w") == "add":
        users[uid]["accounts"].append(t.replace("@",""))
        save()
        ctx.user_data["w"] = None
        await update.message.reply_text("Added", reply_markup=menu(admin(uid)))

    elif ctx.user_data.get("w") == "link":
        ctx.user_data["w"] = None
        await fetch_link(t, update.message.chat_id, ctx)
        await update.message.reply_text("Done", reply_markup=menu(admin(uid)))

async def fetch_account(u, chat, ctx):
    try: p = instaloader.Profile.from_username(L.context, u)
    except: return

    last = state.get(u, {})
    for post in p.get_posts():
        if last.get("post") and post.date_utc <= datetime.fromisoformat(last["post"]): break
        L.download_post(post, target=u)
        for r,_,f in os.walk(DOWNLOADS/u):
            for x in f: await send_file(os.path.join(r,x), chat, ctx)
        last["post"] = post.date_utc.isoformat()

    if L.context.is_logged_in:
        try:
            for s in instaloader.get_stories([p.userid], L.context):
                for i in s.get_items():
                    if last.get("story") and i.date_utc <= datetime.fromisoformat(last["story"]): continue
                    L.download_storyitem(i, target=u)
                    for r,_,f in os.walk(DOWNLOADS/u):
                        for x in f: await send_file(os.path.join(r,x), chat, ctx)
                    last["story"] = i.date_utc.isoformat()
        except: pass

    state[u] = last
    save()

async def fetch_link(url, chat, ctx):
    d = DOWNLOADS / "link"
    d.mkdir(exist_ok=True)
    try:
        if "/p/" in url or "/reel/" in url:
            c = url.rstrip("/").split("/")[-1]
            L.download_post(instaloader.Post.from_shortcode(L.context, c), target="link")
        elif "/stories/" in url:
            if not L.context.is_logged_in:
                await ctx.bot.send_message(chat, "Login required")
                return
            u = url.split("/stories/")[1].split("/")[0]
            p = instaloader.Profile.from_username(L.context, u)
            for s in instaloader.get_stories([p.userid], L.context):
                for i in s.get_items():
                    L.download_storyitem(i, target="link")
        else:
            await ctx.bot.send_message(chat, "Unsupported link")
            return

        sent = False
        for r,_,f in os.walk(d):
            for x in f:
                await send_file(os.path.join(r,x), chat, ctx)
                sent = True
        if not sent:
            await ctx.bot.send_message(chat, "Nothing downloaded")
    except Exception as e:
        await ctx.bot.send_message(chat, f"Error: {e}")

def main():
    app = ApplicationBuilder().token(BOT_TOKEN).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("login", login))
    app.add_handler(CallbackQueryHandler(cb))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, text))
    app.run_polling()

if __name__ == "__main__":
    main()
PYCODE

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
  pip install python-telegram-bot==22.3 instaloader

  sudo tee /etc/systemd/system/$SERVICE.service > /dev/null <<EOF
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

  echo "Installed and started"
fi

if [ "$C" == "2" ]; then
  sudo systemctl stop $SERVICE || true
  sudo systemctl disable $SERVICE || true
  sudo rm -f /etc/systemd/system/$SERVICE.service
  sudo systemctl daemon-reload
  rm -rf "$PROJECT"
  echo "Removed"
fi

if [ "$C" == "3" ]; then sudo systemctl start $SERVICE; fi
if [ "$C" == "4" ]; then sudo systemctl restart $SERVICE; fi
if [ "$C" == "5" ]; then sudo systemctl status $SERVICE; fi
