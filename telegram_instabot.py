#!/usr/bin/env python3
import os, json
from pathlib import Path
from datetime import datetime
import asyncio
import instaloader
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import ApplicationBuilder, CommandHandler, CallbackQueryHandler, MessageHandler, ContextTypes, filters

# ---------- PATHS ----------
BASE = Path(__file__).parent
DOWNLOADS = BASE / "downloads"
USERS_FILE = BASE / "users.json"
STATE_FILE = BASE / "state.json"
CONFIG_FILE = BASE / "config.json"
SESSION_FILE = BASE / "session"

DOWNLOADS.mkdir(exist_ok=True)
for f in [USERS_FILE, STATE_FILE]:
    if not f.exists(): f.write_text("{}")

CONFIG = json.loads(CONFIG_FILE.read_text())
USERS = json.loads(USERS_FILE.read_text())
STATE = json.loads(STATE_FILE.read_text())

TOKEN = CONFIG["bot_token"]
ADMIN_ID = CONFIG["admin_id"]

# ---------- INSTALOADER ----------
L = instaloader.Instaloader(dirname_pattern=str(DOWNLOADS / "{target}"),
                            save_metadata=False, download_comments=False)
if SESSION_FILE.exists():
    try: L.load_session_from_file(filename=str(SESSION_FILE))
    except: pass

# ---------- HELPERS ----------
def save():
    USERS_FILE.write_text(json.dumps(USERS, indent=2))
    STATE_FILE.write_text(json.dumps(STATE, indent=2))

async def send_and_delete(file, chat_id, context):
    with open(file, "rb") as f: await context.bot.send_document(chat_id, f)
    os.remove(file)

# ---------- LANGUAGE ----------
TEXT = {
    "lang_select": "🌐 Choose language / انتخاب زبان:",
    "welcome_en": "👋 Welcome! Use the buttons below:",
    "welcome_fa": "👋 خوش آمدی! از دکمه‌ها استفاده کن:",
    "add_prompt_en": "Please send Instagram username to add:",
    "add_prompt_fa": "لطفاً یوزرنیم اینستاگرام را بفرست:",
    "added_en": "✔️ {} added successfully",
    "added_fa": "✔️ {} اضافه شد",
    "list_empty_en": "📋 Account list is empty",
    "list_empty_fa": "📋 لیست اکانت‌ها خالی است",
    "checking_en": "⏳ Checking Instagram...",
    "checking_fa": "⏳ در حال بررسی...",
    "done_en": "✅ Done!",
    "done_fa": "✅ انجام شد!",
    "login_prompt_en": "Please login to Instagram using /login username password",
    "login_prompt_fa": "لطفاً برای ورود به اینستاگرام از دستور /login username password استفاده کنید",
    "login_success_en": "🔑 Logged in successfully!",
    "login_success_fa": "🔑 ورود با موفقیت انجام شد!"
}

LANGUAGE = {}  # user_id -> 'en' or 'fa'
LOGGED_IN = False

# ---------- KEYBOARD ----------
def get_keyboard(lang):
    if lang == "fa":
        return InlineKeyboardMarkup([
            [InlineKeyboardButton("➕ افزودن اکانت", callback_data="add")],
            [InlineKeyboardButton("📋 لیست اکانت‌ها", callback_data="list")],
            [InlineKeyboardButton("⬇️ دانلود دستی", callback_data="fetch")]
        ])
    else:
        return InlineKeyboardMarkup([
            [InlineKeyboardButton("➕ Add Account", callback_data="add")],
            [InlineKeyboardButton("📋 Account List", callback_data="list")],
            [InlineKeyboardButton("⬇️ Manual Download", callback_data="fetch")]
        ])

# ---------- BOT HANDLERS ----------
async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    uid = update.effective_user.id
    if uid != ADMIN_ID: return
    USERS.setdefault(str(uid), [])
    save()
    if uid not in LANGUAGE:
        keyboard = InlineKeyboardMarkup([
            [InlineKeyboardButton("🇮🇷 فارسی", callback_data="lang_fa")],
            [InlineKeyboardButton("🇬🇧 English", callback_data="lang_en")]
        ])
        await update.message.reply_text(TEXT["lang_select"], reply_markup=keyboard)
    else:
        lang = LANGUAGE[uid]
        await update.message.reply_text(TEXT[f"welcome_{lang}"], reply_markup=get_keyboard(lang))

async def help_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    uid = update.effective_user.id
    if uid != ADMIN_ID: return
    lang = LANGUAGE.get(uid, "en")
    text = "/start - start bot\n/login username password - login Instagram"
    if lang=="fa":
        text = "/start - شروع بات\n/login username password - ورود به اینستاگرام"
    await update.message.reply_text(text)

async def login_instagram(update: Update, context: ContextTypes.DEFAULT_TYPE):
    global LOGGED_IN
    uid = update.effective_user.id
    if uid != ADMIN_ID: return
    try:
        username = context.args[0]
        password = context.args[1]
    except:
        lang = LANGUAGE.get(uid, "en")
        await update.message.reply_text(TEXT[f"login_prompt_{lang}"])
        return
    try:
        L.context.log("Logging in...")
        L.load_session_from_file(username)  # Try existing session first
    except: pass
    instaloader.Instaloader().context.log("Logging in...")
    L.context.log("Logging in...")
    L.login(username, password)
    L.save_session_to_file(SESSION_FILE)
    LOGGED_IN = True
    lang = LANGUAGE.get(uid, "en")
    await update.message.reply_text(TEXT[f"login_success_{lang}"])

async def menu(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    uid = q.from_user.id
    if uid != ADMIN_ID: return
    if q.data.startswith("lang_"):
        lang = q.data.split("_")[1]
        LANGUAGE[uid] = lang
        await q.edit_message_text(TEXT[f"welcome_{lang}"], reply_markup=get_keyboard(lang))
        return
    lang = LANGUAGE.get(uid, "en")
    if q.data == "add":
        context.user_data["await"] = True
        await q.edit_message_text(TEXT[f"add_prompt_{lang}"])
    elif q.data == "list":
        accs = USERS.get(str(uid), [])
        text = "\n".join(accs) if accs else TEXT[f"list_empty_{lang}"]
        await q.edit_message_text(text, reply_markup=get_keyboard(lang))
    elif q.data == "fetch":
        if not LOGGED_IN:
            await q.edit_message_text(TEXT[f"login_prompt_{lang}"])
            return
        await q.edit_message_text(TEXT[f"checking_{lang}"])
        for acc in USERS.get(str(uid), []):
            await fetch_instagram(acc, uid, context)
        await q.edit_message_text(TEXT[f"done_{lang}"], reply_markup=get_keyboard(lang))

async def add_account(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not context.user_data.get("await"): return
    uid = str(update.effective_user.id)
    acc = update.message.text.replace("@", "").strip()
    USERS.setdefault(uid, []).append(acc)
    save()
    context.user_data["await"] = False
    lang = LANGUAGE.get(int(uid), "en")
    await update.message.reply_text(TEXT[f"added_{lang}"].format(acc), reply_markup=get_keyboard(lang))

# ---------- FETCH ----------
async def fetch_instagram(username, chat_id, context):
    last = STATE.get(username, {"post": None, "story": None})
    try:
        profile = instaloader.Profile.from_username(L.context, username)
    except: return
    # Posts
    for post in profile.get_posts():
        if last["post"] and post.date_utc <= datetime.fromisoformat(last["post"]): break
        L.download_post(post, target=username)
        for f in (DOWNLOADS / username).iterdir(): await send_and_delete(f, chat_id, context)
        last["post"] = post.date_utc.isoformat()
    # Stories
    if L.context.is_logged_in:
        try:
            for story in instaloader.get_stories([profile.userid], L.context):
                for item in story.get_items():
                    if last["story"] and item.date_utc <= datetime.fromisoformat(last["story"]): continue
                    L.download_storyitem(item, target=username)
                    for f in (DOWNLOADS / username).iterdir(): await send_and_delete(f, chat_id, context)
                    last["story"] = item.date_utc.isoformat()
        except: pass
    STATE[username] = last
    save()

# ---------- MAIN ----------
async def main():
    app = ApplicationBuilder().token(TOKEN).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("help", help_cmd))
    app.add_handler(CommandHandler("login", login_instagram))
    app.add_handler(CallbackQueryHandler(menu))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, add_account))
    await app.run_polling()

if __name__ == "__main__":
    asyncio.run(main())
