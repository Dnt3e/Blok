#!/usr/bin/env python3
import os
import json
from pathlib import Path
from datetime import datetime

from telegram import (
    Update,
    InlineKeyboardButton,
    InlineKeyboardMarkup
)
from telegram.ext import (
    ApplicationBuilder,
    CommandHandler,
    CallbackQueryHandler,
    MessageHandler,
    ContextTypes,
    filters
)

import instaloader

# ---------------- CONFIG ----------------
BASE = Path(__file__).parent
DATA = BASE / "data"
DOWNLOADS = DATA / "downloads"
USERS_FILE = DATA / "users.json"
STATE_FILE = DATA / "state.json"
SESSION_FILE = DATA / "session"

DOWNLOADS.mkdir(parents=True, exist_ok=True)

USERS = json.load(open(USERS_FILE)) if USERS_FILE.exists() else {}
STATE = json.load(open(STATE_FILE)) if STATE_FILE.exists() else {}

# --------------- INSTALOADER --------------
L = instaloader.Instaloader(
    dirname_pattern=str(DOWNLOADS / "{target}"),
    filename_pattern="{date_utc:%Y-%m-%d_%H-%M-%S}_{shortcode}",
    save_metadata=False,
    download_comments=False
)

if SESSION_FILE.exists():
    try:
        L.load_session_from_file(filename=str(SESSION_FILE))
    except:
        pass


def save():
    json.dump(USERS, open(USERS_FILE, "w"), indent=2)
    json.dump(STATE, open(STATE_FILE, "w"), indent=2)


async def send_and_delete(path, chat_id, context):
    with open(path, "rb") as f:
        await context.bot.send_document(chat_id=chat_id, document=f)
    os.remove(path)


# ---------------- BOT UI ----------------
async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    uid = str(update.effective_user.id)
    USERS.setdefault(uid, [])
    save()

    keyboard = [
        [InlineKeyboardButton("➕ افزودن اکانت", callback_data="add")],
        [InlineKeyboardButton("📋 لیست اکانت‌ها", callback_data="list")],
        [InlineKeyboardButton("⬇️ دریافت پست و استوری جدید", callback_data="fetch")]
    ]

    await update.message.reply_text(
        "👋 خوش آمدی!\nاز دکمه‌ها استفاده کن:",
        reply_markup=InlineKeyboardMarkup(keyboard)
    )


async def menu(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    uid = str(q.from_user.id)

    if q.data == "add":
        context.user_data["awaiting"] = True
        await q.edit_message_text("نام کاربری اینستاگرام را بفرست:")

    elif q.data == "list":
        accs = USERS.get(uid, [])
        await q.edit_message_text(
            "📋 اکانت‌ها:\n" + ("\n".join(accs) if accs else "خالی")
        )

    elif q.data == "fetch":
        await q.edit_message_text("⏳ در حال بررسی...")
        for acc in USERS.get(uid, []):
            await fetch_instagram(acc, uid, context)
        await q.edit_message_text("✅ تمام شد!")


async def add_account(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not context.user_data.get("awaiting"):
        return

    uid = str(update.effective_user.id)
    username = update.message.text.strip().replace("@", "")
    USERS.setdefault(uid, []).append(username)
    save()

    context.user_data["awaiting"] = False
    await update.message.reply_text(f"✔️ {username} اضافه شد")


# ---------------- INSTAGRAM ----------------
async def fetch_instagram(username, chat_id, context):
    last = STATE.get(username, {"post": None, "story": None})

    try:
        profile = instaloader.Profile.from_username(L.context, username)
    except:
        await context.bot.send_message(chat_id, f"❌ خطا در {username}")
        return

    # POSTS
    for post in profile.get_posts():
        if last["post"] and post.date_utc <= datetime.fromisoformat(last["post"]):
            break

        L.download_post(post, target=str(DOWNLOADS / username))
        for f in (DOWNLOADS / username).glob(f"*{post.shortcode}*"):
            await send_and_delete(f, chat_id, context)

        last["post"] = post.date_utc.isoformat()

    # STORIES
    if L.context.is_logged_in:
        try:
            for story in instaloader.get_stories([profile.userid], L.context):
                for item in story.get_items():
                    if last["story"] and item.date_utc <= datetime.fromisoformat(last["story"]):
                        continue

                    story_dir = DOWNLOADS / username / "stories"
                    L.download_storyitem(item, target=str(story_dir))
                    for f in story_dir.iterdir():
                        await send_and_delete(f, chat_id, context)

                    last["story"] = item.date_utc.isoformat()
        except:
            pass

    STATE[username] = last
    save()


# ---------------- MAIN ----------------
async def main():
    TOKEN = "PUT-YOUR-TELEGRAM-BOT-TOKEN-HERE"

    app = ApplicationBuilder().token(TOKEN).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CallbackQueryHandler(menu))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, add_account))

    await app.run_polling()


if __name__ == "__main__":
    import asyncio
    asyncio.run(main())
