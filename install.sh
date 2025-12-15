#!/bin/bash
set -e

echo "===================================="
echo " Telegram Instagram Bot Installer"
echo "===================================="

# --- دریافت اطلاعات اولیه ---
read -p "Enter Telegram Bot Token: " BOT_TOKEN
read -p "Enter Admin Telegram User ID: " ADMIN_ID
read -p "Enter Auto-Check Interval (hours, e.g., 1): " AUTO_INTERVAL

APP_DIR="$HOME/Blok"
PYTHON_BIN="/usr/bin/python3"

echo "[1/10] Creating project directory..."
mkdir -p "$APP_DIR"
cd "$APP_DIR"

echo "[2/10] Creating virtual environment..."
$PYTHON_BIN -m venv venv
source venv/bin/activate

echo "[3/10] Installing Python packages..."
pip install --upgrade pip
pip install python-telegram-bot==22.3 instaloader nest_asyncio apscheduler

echo "[4/10] Creating downloads folder..."
mkdir -p downloads

echo "[5/10] Writing bot source code..."
cat > telegram_instabot.py <<EOF
import asyncio, os, logging, nest_asyncio, instaloader
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import *
from apscheduler.schedulers.asyncio import AsyncIOScheduler

nest_asyncio.apply()

BOT_TOKEN = "${BOT_TOKEN}"
ADMIN_ID = int("${ADMIN_ID}")
AUTO_INTERVAL = ${AUTO_INTERVAL}

SESSION_FILE = "ig.session"
DOWNLOAD_DIR = "downloads"
USERS_FILE = "users.db"

os.makedirs(DOWNLOAD_DIR, exist_ok=True)

logging.basicConfig(level=logging.INFO)
L = instaloader.Instaloader(dirname_pattern=DOWNLOAD_DIR)
scheduler = AsyncIOScheduler()
scheduler.start()

# ---------- USERS ----------
def load_users():
    if not os.path.exists(USERS_FILE):
        return {}
    return eval(open(USERS_FILE).read())

def save_users(u): open(USERS_FILE,"w").write(str(u))

users = load_users()

def is_admin(uid): return uid == ADMIN_ID

def ensure_user(uid):
    if uid not in users:
        users[uid] = {"lang":"EN","limit":20,"followed":[],"interval":AUTO_INTERVAL}
        save_users(users)

# ---------- SESSION ----------
def session_ok():
    try:
        L.load_session_from_file(SESSION_FILE)
        return True
    except: return False

# ---------- UI ----------
def main_menu(lang):
    if lang=="FA":
        return InlineKeyboardMarkup([
            [InlineKeyboardButton("📥 دانلود لینک",callback_data="dl")],
            [InlineKeyboardButton("📖 استوری",callback_data="story")],
            [InlineKeyboardButton("⚙ تنظیمات",callback_data="settings")]
        ])
    return InlineKeyboardMarkup([
        [InlineKeyboardButton("📥 Download Link",callback_data="dl")],
        [InlineKeyboardButton("📖 Stories",callback_data="story")],
        [InlineKeyboardButton("⚙ Settings",callback_data="settings")]
    ])

# ---------- COMMANDS ----------
async def start(update:Update,ctx:ContextTypes.DEFAULT_TYPE):
    uid=update.effective_user.id
    ensure_user(uid)
    await update.message.reply_text(
        "✅ Bot Ready",
        reply_markup=main_menu(users[uid]["lang"])
    )

# ---------- BUTTONS ----------
async def buttons(update:Update,ctx):
    q=update.callback_query
    uid=q.from_user.id
    ensure_user(uid)
    await q.answer()

    if q.data=="dl":
        await q.message.reply_text("Send Instagram link")
    elif q.data=="story":
        if not session_ok():
            await q.message.reply_text("❌ Instagram session required for stories")
            return
        await q.message.reply_text("Send Instagram username")
    elif q.data=="settings":
        kb=[[InlineKeyboardButton("🌐 Language",callback_data="lang")]]
        if is_admin(uid):
            kb.append([InlineKeyboardButton("🔐 Upload Session",callback_data="upload")])
            kb.append([InlineKeyboardButton("🩺 Session Health",callback_data="health")])
            kb.append([InlineKeyboardButton("🗂 Manage Followed Accounts",callback_data="followed")])
            kb.append([InlineKeyboardButton("⏱ Set Auto-Check Interval",callback_data="interval")])
        kb.append([InlineKeyboardButton("◀ Back", callback_data="back")])
        await q.message.reply_text("Settings",reply_markup=InlineKeyboardMarkup(kb))
    elif q.data=="lang":
        users[uid]["lang"]="FA" if users[uid]["lang"]=="EN" else "EN"
        save_users(users)
        await q.message.reply_text("Language changed")
    elif q.data=="health":
        await q.message.reply_text("✅ Session OK" if session_ok() else "❌ Invalid session")
    elif q.data=="upload":
        await q.message.reply_text("Send session file")
    elif q.data=="followed":
        await q.message.reply_text(
            "Commands:\n/add username\n/remove username\n/list",
        )
    elif q.data=="interval":
        await q.message.reply_text("Send new interval in hours")
    elif q.data=="back":
        await q.message.reply_text("Main Menu",reply_markup=main_menu(users[uid]["lang"]))

# ---------- HANDLERS ----------
async def handle_doc(update:Update,ctx):
    if not is_admin(update.effective_user.id): return
    doc=update.message.document
    if "session" in doc.file_name:
        await doc.get_file().download_to_drive(SESSION_FILE)
        await update.message.reply_text("✅ Session uploaded")

async def handle_text(update:Update,ctx):
    uid=update.effective_user.id
    ensure_user(uid)
    txt=update.message.text.strip()

    # Followed accounts management
    if is_admin(uid):
        if txt.startswith("/add "):
            usern=txt.split(" ",1)[1]
            if usern not in users[uid]["followed"]:
                users[uid]["followed"].append(usern)
                save_users(users)
                await update.message.reply_text(f"✅ Added {usern}")
            return
        if txt.startswith("/remove "):
            usern=txt.split(" ",1)[1]
            if usern in users[uid]["followed"]:
                users[uid]["followed"].remove(usern)
                save_users(users)
                await update.message.reply_text(f"✅ Removed {usern}")
            return
        if txt=="/list":
            await update.message.reply_text("Followed: "+", ".join(users[uid]["followed"]))
            return
        if txt.isdigit():
            users[uid]["interval"]=int(txt)
            scheduler.remove_all_jobs()
            scheduler.add_job(auto_check,'interval',hours=int(txt))
            save_users(users)
            await update.message.reply_text(f"✅ Interval set to {txt} hours")
            return

    # Instagram link
    if "instagram.com" in txt:
        try:
            sc=txt.rstrip("/").split("/")[-1]
            post=instaloader.Post.from_shortcode(L.context,sc)
            L.download_post(post,post.owner_username)
            await update.message.reply_text("✅ Downloaded")
        except Exception as e:
            await update.message.reply_text(f"❌ {e}")
    else:
        if not session_ok(): return
        try:
            prof=instaloader.Profile.from_username(L.context,txt)
            for s in L.get_stories([prof.userid]):
                for item in s.get_items():
                    L.download_storyitem(item,DOWNLOAD_DIR)
            await update.message.reply_text("✅ Stories downloaded")
        except Exception as e:
            await update.message.reply_text(f"❌ {e}")

# ---------- AUTO CHECK ----------
async def auto_check():
    if not session_ok(): return
    for uid in users:
        for username in users[uid].get("followed", []):
            try:
                prof=instaloader.Profile.from_username(L.context,username)
                for s in L.get_stories([prof.userid]):
                    for item in s.get_items():
                        L.download_storyitem(item,DOWNLOAD_DIR)
            except: pass

scheduler.add_job(auto_check,'interval',hours=AUTO_INTERVAL)

# ---------- MAIN ----------
async def main():
    app=ApplicationBuilder().token(BOT_TOKEN).build()
    app.add_handler(CommandHandler("start",start))
    app.add_handler(CallbackQueryHandler(buttons))
    app.add_handler(MessageHandler(filters.Document.ALL,handle_doc))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND,handle_text))
    await app.run_polling()

if __name__=="__main__":
    asyncio.run(main())
EOF

# --- ایجاد systemd service ---
echo "[6/10] Creating systemd service..."
sudo tee /etc/systemd/system/insta_bot.service >/dev/null <<EOF
[Unit]
Description=Telegram Instagram Bot
After=network.target

[Service]
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/venv/bin/python telegram_instabot.py
Restart=always
User=root
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

echo "[7/10] Enabling and starting service..."
sudo systemctl daemon-reload
sudo systemctl enable insta_bot
sudo systemctl restart insta_bot

echo "[8/10] Installation completed!"
echo "[9/10] Bot is running. Check status: sudo systemctl status insta_bot"
echo "[10/10] You can now use the bot in Telegram. Admin can upload session and manage followed accounts."
