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

    # ---------- telegram_instabot.py ----------
    cat <<'PYCODE' > telegram_instabot.py
#!/usr/bin/env python3
import os, json, asyncio
from pathlib import Path
from datetime import datetime
import instaloader
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import ApplicationBuilder, CommandHandler, CallbackQueryHandler, MessageHandler, ContextTypes, filters

# ---------- Paths ----------
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
    exit(1)

cfg = json.loads(CONFIG.read_text())
BOT_TOKEN = cfg["bot_token"]
ADMIN_ID = str(cfg["admin_id"])

users = json.loads(USERS.read_text())
state = json.loads(STATE.read_text())

# ---------- Instagram Loader ----------
L = instaloader.Instaloader(save_metadata=False, download_comments=False, dirname_pattern=str(DOWNLOADS / "{target}"))
if SESSION.exists():
    try: L.load_session_from_file(filename=str(SESSION))
    except: pass

# ---------- Utility ----------
def save():
    USERS.write_text(json.dumps(users, indent=2))
    STATE.write_text(json.dumps(state, indent=2))

def ensure(uid):
    if uid not in users:
        users[uid] = {"role": "admin" if uid == ADMIN_ID else "user", "blocked": False, "accounts": [], "language":"en","interval":1}
        save()

def admin(uid): return users.get(uid, {}).get("role") == "admin"
def blocked(uid): return users.get(uid, {}).get("blocked", False)

async def send_file(p, chat, ctx):
    with open(p, "rb") as f:
        await ctx.bot.send_document(chat, f)
    os.remove(p)

# ---------- Language ----------
LANG = {
    "fa":{"start":"🤖 ربات آماده است","add":"➕ افزودن اکانت","fetch":"⬇️ بررسی جدیدها","link":"🔗 دانلود با لینک","login_required":"❌ برای استوری باید session آپلود شود"},
    "en":{"start":"🤖 Bot is ready","add":"➕ Add Account","fetch":"⬇️ Check New","link":"🔗 Download by Link","login_required":"❌ Instagram session required for stories"}
}

def menu(is_admin=False, lang="en"):
    buttons = [
        [InlineKeyboardButton(LANG[lang]["add"], callback_data="add")],
        [InlineKeyboardButton(LANG[lang]["fetch"], callback_data="fetch")],
        [InlineKeyboardButton(LANG[lang]["link"], callback_data="link")]
    ]
    if is_admin:
        buttons.append([InlineKeyboardButton("🔐 Upload IG Session", callback_data="upload_session")])
        buttons.append([InlineKeyboardButton("👥 Users", callback_data="users")])
    return InlineKeyboardMarkup(buttons)

# ---------- Bot Handlers ----------
async def start(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    uid = str(update.effective_user.id)
    ensure(uid)
    if blocked(uid): return
    lang = users[uid]["language"]
    await update.message.reply_text(LANG[lang]["start"], reply_markup=menu(admin(uid), lang))

async def cb(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    uid = str(q.from_user.id)
    ensure(uid)
    if blocked(uid): return
    lang = users[uid]["language"]

    if q.data == "add":
        ctx.user_data["await"] = "add"
        await q.edit_message_text("Send Instagram username")
    elif q.data == "fetch":
        await q.edit_message_text("Checking...")
        for a in users[uid]["accounts"]:
            await fetch_account(a, q.message.chat_id, ctx)
        await q.edit_message_text("Done", reply_markup=menu(admin(uid), lang))
    elif q.data == "link":
        ctx.user_data["await"] = "link"
        await q.edit_message_text("Send link")
    elif q.data == "upload_session" and admin(uid):
        ctx.user_data["await"] = "session"
        await q.edit_message_text("📤 Please send Instagram session file (session-USERNAME)")
    elif q.data == "users" and admin(uid):
        txt = "\n".join(f"{u} | {d['role']} | blocked={d['blocked']}" for u,d in users.items())
        await q.edit_message_text(txt)

async def text(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    uid = str(update.effective_user.id)
    ensure(uid)
    if blocked(uid): return
    t = update.message.text.strip()

    if ctx.user_data.get("await") == "add":
        users[uid]["accounts"].append(t.replace("@",""))
        save()
        ctx.user_data["await"] = None
        await update.message.reply_text("Added", reply_markup=menu(admin(uid), users[uid]["language"]))

    elif ctx.user_data.get("await") == "link":
        ctx.user_data["await"] = None
        await fetch_link(t, update.message.chat_id, ctx)
        await update.message.reply_text("Done", reply_markup=menu(admin(uid), users[uid]["language"]))

async def receive_session(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    uid = str(update.effective_user.id)
    if not admin(uid): return
    if ctx.user_data.get("await") != "session": return

    doc = update.message.document
    if not doc:
        await update.message.reply_text("❌ Please send a file")
        return
    if not doc.file_name.startswith("session-"):
        await update.message.reply_text("❌ Invalid session file name")
        return

    file = await doc.get_file()
    await file.download_to_drive(custom_path=str(SESSION))
    try:
        L.load_session_from_file(filename=str(SESSION))
        ctx.user_data["await"] = None
        await update.message.reply_text("✅ Instagram session loaded successfully")
    except Exception as e:
        await update.message.reply_text(f"❌ Failed to load session\n{e}")

# ---------- Fetch functions ----------
async def fetch_account(username, chat_id, ctx):
    try: p = instaloader.Profile.from_username(L.context, username)
    except: return

    last = state.get(username, {})
    # Posts
    for post in p.get_posts():
        if last.get("post") and post.date_utc <= datetime.fromisoformat(last["post"]): break
        L.download_post(post, target=username)
        for r, _, f in os.walk(DOWNLOADS/username):
            for x in f: await send_file(os.path.join(r,x), chat_id, ctx)
        last["post"] = post.date_utc.isoformat()
    # Stories
    if L.context.is_logged_in:
        found=False
        try:
            for story in instaloader.get_stories([p.userid], L.context):
                for item in story.get_items():
                    if last.get("story") and item.date_utc <= datetime.fromisoformat(last["story"]): continue
                    L.download_storyitem(item, target=username)
                    found=True
                    for r,_,f in os.walk(DOWNLOADS/username):
                        for x in f: await send_file(os.path.join(r,x), chat_id, ctx)
                    last["story"]=item.date_utc.isoformat()
        except: pass
        if not found:
            await ctx.bot.send_message(chat_id,"⚠️ No active stories found")
    else:
        await ctx.bot.send_message(chat_id, LANG[users[str(chat_id)]["language"]]["login_required"])
    state[username]=last
    save()

async def fetch_link(url, chat_id, ctx):
    d = DOWNLOADS / "link"; d.mkdir(exist_ok=True)
    try:
        if "/p/" in url or "/reel/" in url:
            c = url.rstrip("/").split("/")[-1]
            L.download_post(instaloader.Post.from_shortcode(L.context, c), target="link")
        elif "/stories/" in url:
            if not L.context.is_logged_in:
                await ctx.bot.send_message(chat_id, "Login required")
                return
            u = url.split("/stories/")[1].split("/")[0]
            p = instaloader.Profile.from_username(L.context,u)
            for s in instaloader.get_stories([p.userid], L.context):
                for i in s.get_items(): L.download_storyitem(i,target="link")
        else:
            await ctx.bot.send_message(chat_id, "Unsupported link")
            return

        sent=False
        for r,_,f in os.walk(d):
            for x in f: await send_file(os.path.join(r,x), chat_id, ctx); sent=True
        if not sent: await ctx.bot.send_message(chat_id,"Nothing downloaded")
    except Exception as e:
        await ctx.bot.send_message(chat_id,f"Error: {e}")

# ---------- Main ----------
def main():
    app = ApplicationBuilder().token(BOT_TOKEN).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CallbackQueryHandler(cb))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, text))
    app.add_handler(MessageHandler(filters.Document.ALL, receive_session))
    app.run_polling()

if __name__=="__main__":
    main()
PYCODE

    # ---------- config.json ----------
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

    # ---------- systemd service ----------
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

    echo "✅ Bot installed and running"
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
