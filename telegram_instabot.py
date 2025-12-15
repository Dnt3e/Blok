#!/usr/bin/env python3
import os, json
from pathlib import Path
from datetime import datetime

import instaloader
from telegram import (
    Update, InlineKeyboardButton, InlineKeyboardMarkup
)
from telegram.ext import (
    ApplicationBuilder, CommandHandler,
    CallbackQueryHandler, MessageHandler,
    ContextTypes, filters
)

# ---------- PATHS ----------
BASE = Path(__file__).parent
DOWNLOADS = BASE / "downloads"
CONFIG_FILE = BASE / "config.json"
USERS_FILE = BASE / "users.json"
STATE_FILE = BASE / "state.json"
SESSION_FILE = BASE / "session"

DOWNLOADS.mkdir(exist_ok=True)

for f in [USERS_FILE, STATE_FILE]:
    if not f.exists():
        f.write_text("{}")

CONFIG = json.loads(CONFIG_FILE.read_text())
USERS = json.loads(USERS_FILE.read_text())
STATE = json.loads(STATE_FILE.read_text())

TOKEN = CONFIG["bot_token"]
ADMIN = CONFIG["admin_username"]

# ---------- INSTALOADER ----------
L = instaloader.Instaloader(
    dirname_pattern=str(DOWNLOADS / "{target}"),
    save_metadata=False,
    download_comments=False
)

if SESSION_FILE.exists():
    try:
        L.load_session_from_file(filename=str(SESSION_FILE))
    except:
        pass

def save():
    USERS_FILE.write_text(json.dumps(USERS, indent=2))
    STATE_FILE.write_text(json.dumps(STATE, indent=2))

async def send_and_delete(file, chat_id, context):
    with open(file, "rb") as f:
        await context.bot.send_document(chat_id, f)
    os.remove(file)

# ---------- UI ----------
def keyboard():
    return InlineKeyboardMarkup([
        [InlineKeyboardButton("➕ افزودن اکانت", callback_data="add")],
        [InlineKeyboardButton("📋 لیست اکانت‌ها", callback_data="list")],
        [InlineKeyboardButton("⬇️ دانلود دستی", callback_data="fetch")]
    ])

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.effective_user.username != ADMIN:
        return
    uid = str(update.effective_user.id)
    USERS.setdefault(uid, [])
    save()
    await update.message.reply_text("👋 مدیریت بات", reply_markup=keyboard())

async def menu(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    uid = str(q.from_user.id)

    if q.data == "add":
        context.user_data["await"] = True
        await q.edit_message_text("یوزرنیم اینستاگرام را بفرست:")

    elif q.data == "list":
        accs = USERS.get(uid, [])
        await q.edit_message_text(
            "📋 اکانت‌ها:\n" + ("\n".join(accs) if accs else "خالی"),
            reply_markup=keyboard()
        )

    elif q.data == "fetch":
        await q.edit_message_text("⏳ در حال بررسی...")
        for acc in USERS.get(uid, []):
            await fetch(acc, uid, context)
        await q.edit_message_text("✅ انجام شد", reply_markup=keyboard())

async def add_account(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not context.user_data.get("await"):
        return
    uid = str(update.effective_user.id)
    acc = update.message.text.replace("@", "").strip()
    USERS.setdefault(uid, []).append(acc)
    save()
    context.user_data["await"] = False
    await update.message.reply_text(f"✔️ {acc} اضافه شد", reply_markup=keyboard())

# ---------- FETCH ----------
async def fetch(username, chat_id, context):
    last = STATE.get(username, {"post": None, "story": None})
    try:
        profile = instaloader.Profile.from_username(L.context, username)
    except:
        return

    for post in profile.get_posts():
        if last["post"] and post.date_utc <= datetime.fromisoformat(last["post"]):
            break
        L.download_post(post, target=username)
        for f in (DOWNLOADS / username).iterdir():
            await send_and_delete(f, chat_id, context)
        last["post"] = post.date_utc.isoformat()

    if L.context.is_logged_in:
        try:
            for story in instaloader.get_stories([profile.userid], L.context):
                for item in story.get_items():
                    if last["story"] and item.date_utc <= datetime.fromisoformat(last["story"]):
                        continue
                    L.download_storyitem(item, target=username)
                    for f in (DOWNLOADS / username).iterdir():
                        await send_and_delete(f, chat_id, context)
                    last["story"] = item.date_utc.isoformat()
        except:
            pass

    STATE[username] = last
    save()

# ---------- MAIN ----------
async def main():
    app = ApplicationBuilder().token(TOKEN).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CallbackQueryHandler(menu))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, add_account))
    await app.run_polling()

if __name__ == "__main__":
    import asyncio
    asyncio.run(main())
