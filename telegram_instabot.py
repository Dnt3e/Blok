#!/usr/bin/env python3
import os, json
from pathlib import Path
from datetime import datetime
import instaloader

from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import (
    ApplicationBuilder, CommandHandler, CallbackQueryHandler,
    MessageHandler, ContextTypes, filters
)

# ================= PATHS =================
BASE = Path(__file__).parent
DOWNLOADS = BASE / "downloads"
USERS_FILE = BASE / "users.json"
STATE_FILE = BASE / "state.json"
CONFIG_FILE = BASE / "config.json"
SESSION_FILE = BASE / "session"

DOWNLOADS.mkdir(exist_ok=True)
for f in [USERS_FILE, STATE_FILE]:
    if not f.exists():
        f.write_text("{}")

CONFIG = json.loads(CONFIG_FILE.read_text())
USERS = json.loads(USERS_FILE.read_text())
STATE = json.loads(STATE_FILE.read_text())

BOT_TOKEN = CONFIG["bot_token"]
ADMIN_ID = str(CONFIG["admin_id"])

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

def is_admin(uid):
    return USERS.get(uid, {}).get("role") == "admin"

def is_blocked(uid):
    return USERS.get(uid, {}).get("blocked", False)

def all_files(path):
    for root, _, files in os.walk(path):
        for f in files:
            yield os.path.join(root, f)

async def send_and_delete(file, chat_id, context):
    with open(file, "rb") as f:
        await context.bot.send_document(chat_id, f)
    os.remove(file)

# ================= USER INIT =================
def ensure_user(uid):
    if uid not in USERS:
        USERS[uid] = {"role": "user", "blocked": False}
        if uid == ADMIN_ID:
            USERS[uid]["role"] = "admin"
        save()

# ================= KEYBOARD =================
def main_menu(admin=False):
    buttons = [
        [InlineKeyboardButton("➕ Add Account", callback_data="add")],
        [InlineKeyboardButton("⬇️ Check New Posts", callback_data="fetch")],
        [InlineKeyboardButton("🔗 Download by Link", callback_data="link")]
    ]
    if admin:
        buttons.append([InlineKeyboardButton("👥 Users", callback_data="users")])
    return InlineKeyboardMarkup(buttons)

# ================= COMMANDS =================
async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    uid = str(update.effective_user.id)
    ensure_user(uid)

    if is_blocked(uid):
        return

    await update.message.reply_text(
        "✅ Bot is ready",
        reply_markup=main_menu(is_admin(uid))
    )

async def login_instagram(update: Update, context: ContextTypes.DEFAULT_TYPE):
    uid = str(update.effective_user.id)
    if not is_admin(uid):
        return

    try:
        user, pwd = context.args
        L.login(user, pwd)
        L.save_session_to_file(SESSION_FILE)
        await update.message.reply_text("✅ Instagram login successful")
    except:
        await update.message.reply_text("❌ Login failed")

# ================= CALLBACKS =================
async def callbacks(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    uid = str(q.from_user.id)

    if is_blocked(uid):
        return

    if q.data == "add":
        context.user_data["await"] = "add"
        await q.edit_message_text("Send Instagram username:")

    elif q.data == "fetch":
        await q.edit_message_text("⏳ Checking...")
        for acc in USERS.get(uid, {}).get("accounts", []):
            await fetch_account(acc, q.message.chat_id, context)
        await q.edit_message_text("✅ Done", reply_markup=main_menu(is_admin(uid)))

    elif q.data == "link":
        context.user_data["await"] = "link"
        await q.edit_message_text("Send Instagram link:")

    elif q.data == "users" and is_admin(uid):
        txt = "\n".join(
            f"{u} | {d['role']} | blocked={d['blocked']}"
            for u, d in USERS.items()
        )
        await q.edit_message_text(txt)

# ================= TEXT HANDLER =================
async def text_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    uid = str(update.effective_user.id)
    ensure_user(uid)

    if is_blocked(uid):
        return

    text = update.message.text.strip()

    if context.user_data.get("await") == "add":
        USERS[uid].setdefault("accounts", []).append(text.replace("@", ""))
        save()
        context.user_data["await"] = None
        await update.message.reply_text("✅ Account added", reply_markup=main_menu(is_admin(uid)))

    elif context.user_data.get("await") == "link":
        context.user_data["await"] = None
        await fetch_by_link(text, update.message.chat_id, context)
        await update.message.reply_text("✅ Done", reply_markup=main_menu(is_admin(uid)))

# ================= FETCH ACCOUNT =================
async def fetch_account(username, chat_id, context):
    last = STATE.get(username, {"post": None, "story": None})
    try:
        profile = instaloader.Profile.from_username(L.context, username)
    except:
        return

    for post in profile.get_posts():
        if last["post"] and post.date_utc <= datetime.fromisoformat(last["post"]):
            break
        L.download_post(post, target=username)
        for f in all_files(DOWNLOADS / username):
            await send_and_delete(f, chat_id, context)
        last["post"] = post.date_utc.isoformat()

    if L.context.is_logged_in:
        try:
            for story in instaloader.get_stories([profile.userid], L.context):
                for item in story.get_items():
                    if last["story"] and item.date_utc <= datetime.fromisoformat(last["story"]):
                        continue
                    L.download_storyitem(item, target=username)
                    for f in all_files(DOWNLOADS / username):
                        await send_and_delete(f, chat_id, context)
                    last["story"] = item.date_utc.isoformat()
        except:
            pass

    STATE[username] = last
    save()

# ================= FETCH LINK =================
async def fetch_by_link(url, chat_id, context):
    target = "link"
    base = DOWNLOADS / target
    base.mkdir(exist_ok=True)

    try:
        if "/p/" in url or "/reel/" in url:
            code = url.rstrip("/").split("/")[-1]
            post = instaloader.Post.from_shortcode(L.context, code)
            L.download_post(post, target=target)

        elif "/stories/" in url:
            if not L.context.is_logged_in:
                await context.bot.send_message(chat_id, "❌ Login required for stories")
                return
            username = url.split("/stories/")[1].split("/")[0]
            profile = instaloader.Profile.from_username(L.context, username)
            for story in instaloader.get_stories([profile.userid], L.context):
                for item in story.get_items():
                    L.download_storyitem(item, target=target)

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
    app.add_handler(CommandHandler("login", login_instagram))
    app.add_handler(CallbackQueryHandler(callbacks))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, text_handler))
    app.run_polling()

if __name__ == "__main__":
    main()
