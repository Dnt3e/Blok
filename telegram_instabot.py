#!/usr/bin/env python3
import os, json, sys
from pathlib import Path
from datetime import datetime
import instaloader

from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import ApplicationBuilder, CommandHandler, CallbackQueryHandler, MessageHandler, ContextTypes, filters

# ================= PATHS =================
BASE = Path(__file__).parent
DOWNLOADS = BASE / "downloads"
USERS_FILE = BASE / "users.json"
STATE_FILE = BASE / "state.json"
CONFIG_FILE = BASE / "config.json"
SESSION_FILE = BASE / "session"

DOWNLOADS.mkdir(exist_ok=True)

for f, default in [
    (USERS_FILE, {}),
    (STATE_FILE, {})
]:
    if not f.exists():
        f.write_text(json.dumps(default))

# ================= CONFIG SAFE LOAD =================
if not CONFIG_FILE.exists():
    print("❌ config.json not found")
    sys.exit(1)

try:
    CONFIG = json.loads(CONFIG_FILE.read_text())
    BOT_TOKEN = CONFIG["bot_token"]
    ADMIN_ID = str(CONFIG["admin_id"])
except Exception as e:
    print(f"❌ Invalid config.json: {e}")
    sys.exit(1)

USERS = json.loads(USERS_FILE.read_text())
STATE = json.loads(STATE_FILE.read_text())

# ================= INSTALOADER =================
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

# ================= HELPERS =================
def save():
    USERS_FILE.write_text(json.dumps(USERS, indent=2))
    STATE_FILE.write_text(json.dumps(STATE, indent=2))

def ensure_user(uid):
    if uid not in USERS:
        USERS[uid] = {"role": "admin" if uid == ADMIN_ID else "user", "blocked": False, "accounts": []}
        save()

def is_admin(uid): return USERS.get(uid, {}).get("role") == "admin"
def is_blocked(uid): return USERS.get(uid, {}).get("blocked", False)

def all_files(path):
    for r, _, f in os.walk(path):
        for x in f:
            yield os.path.join(r, x)

async def send_and_delete(file, chat_id, context):
    with open(file, "rb") as f:
        await context.bot.send_document(chat_id, f)
    os.remove(file)

# ================= UI =================
def menu(admin=False):
    btns = [
        [InlineKeyboardButton("➕ Add Account", callback_data="add")],
        [InlineKeyboardButton("⬇️ Check New Posts", callback_data="fetch")],
        [InlineKeyboardButton("🔗 Download by Link", callback_data="link")]
    ]
    if admin:
        btns.append([InlineKeyboardButton("👥 Users", callback_data="users")])
    return InlineKeyboardMarkup(btns)

# ================= COMMANDS =================
async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    uid = str(update.effective_user.id)
    ensure_user(uid)
    if is_blocked(uid): return
    await update.message.reply_text("✅ Bot Ready", reply_markup=menu(is_admin(uid)))

async def login(update: Update, context: ContextTypes.DEFAULT_TYPE):
    uid = str(update.effective_user.id)
    if not is_admin(uid): return
    try:
        u, p = context.args
        L.login(u, p)
        L.save_session_to_file(SESSION_FILE)
        await update.message.reply_text("✅ Instagram logged in")
    except:
        await update.message.reply_text("❌ Login failed")

# ================= CALLBACK =================
async def cb(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    uid = str(q.from_user.id)
    if is_blocked(uid): return

    if q.data == "add":
        context.user_data["await"] = "add"
        await q.edit_message_text("Send Instagram username:")

    elif q.data == "fetch":
        await q.edit_message_text("⏳ Checking...")
        for a in USERS[uid]["accounts"]:
            await fetch_account(a, q.message.chat_id, context)
        await q.edit_message_text("✅ Done", reply_markup=menu(is_admin(uid)))

    elif q.data == "link":
        context.user_data["await"] = "link"
        await q.edit_message_text("Send Instagram link:")

    elif q.data == "users" and is_admin(uid):
        txt = "\n".join(f"{u} | {d['role']} | blocked={d['blocked']}" for u,d in USERS.items())
        await q.edit_message_text(txt)

# ================= TEXT =================
async def text(update: Update, context: ContextTypes.DEFAULT_TYPE):
    uid = str(update.effective_user.id)
    ensure_user(uid)
    if is_blocked(uid): return
    msg = update.message.text.strip()

    if context.user_data.get("await") == "add":
        USERS[uid]["accounts"].append(msg.replace("@",""))
        save()
        context.user_data["await"] = None
        await update.message.reply_text("✅ Added", reply_markup=menu(is_admin(uid)))

    elif context.user_data.get("await") == "link":
        context.user_data["await"] = None
        await fetch_link(msg, update.message.chat_id, context)
        await update.message.reply_text("✅ Done", reply_markup=menu(is_admin(uid)))

# ================= FETCH =================
async def fetch_account(username, chat_id, context):
    last = STATE.get(username, {})
    try:
        p = instaloader.Profile.from_username(L.context, username)
    except: return

    for post in p.get_posts():
        if last.get("post") and post.date_utc <= datetime.fromisoformat(last["post"]): break
        L.download_post(post, target=username)
        for f in all_files(DOWNLOADS/username):
            await send_and_delete(f, chat_id, context)
        last["post"] = post.date_utc.isoformat()

    if L.context.is_logged_in:
        try:
            for s in instaloader.get_stories([p.userid], L.context):
                for i in s.get_items():
                    if last.get("story") and i.date_utc <= datetime.fromisoformat(last["story"]): continue
                    L.download_storyitem(i, target=username)
                    for f in all_files(DOWNLOADS/username):
                        await send_and_delete(f, chat_id, context)
                    last["story"] = i.date_utc.isoformat()
        except: pass

    STATE[username] = last
    save()

async def fetch_link(url, chat_id, context):
    base = DOWNLOADS / "link"
    base.mkdir(exist_ok=True)

    try:
        if "/p/" in url or "/reel/" in url:
            code = url.rstrip("/").split("/")[-1]
            L.download_post(instaloader.Post.from_shortcode(L.context, code), target="link")
        elif "/stories/" in url:
            if not L.context.is_logged_in:
                await context.bot.send_message(chat_id, "❌ Login required for stories")
                return
            user = url.split("/stories/")[1].split("/")[0]
            p = instaloader.Profile.from_username(L.context, user)
            for s in instaloader.get_stories([p.userid], L.context):
                for i in s.get_items():
                    L.download_storyitem(i, target="link")
        else:
            await context.bot.send_message(chat_id, "❌ Unsupported link")
            return

        sent = False
        for f in all_files(base):
            await send_and_delete(f, chat_id, context)
            sent = True
        if not sent:
            await context.bot.send_message(chat_id, "⚠️ Nothing downloaded")
    except Exception as e:
        await context.bot.send_message(chat_id, f"❌ Error: {e}")

# ================= MAIN =================
def main():
    app = ApplicationBuilder().token(BOT_TOKEN).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("login", login))
    app.add_handler(CallbackQueryHandler(cb))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, text))
    app.run_polling()

if __name__ == "__main__":
    main()
