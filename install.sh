#!/bin/bash

# =============================================
# Telegram Instagram Bot Installer - Full Version
# =============================================

# English Installer Prompts
read -p "Enter your Telegram bot token: " BOT_TOKEN
read -p "Enter your admin user ID: " ADMIN_ID
read -p "Choose bot default language (fa/en): " DEFAULT_LANG

# Create Python virtual environment
python3 -m venv bot_env
source bot_env/bin/activate

# Upgrade pip and install required packages
pip install --upgrade pip
pip install python-telegram-bot==20.3 apscheduler requests instaloader

# Create project directories
mkdir -p telegram_bot_instagram/messages

# Create config.json
cat <<EOL > telegram_bot_instagram/config.json
{
  "bot_token": "$BOT_TOKEN",
  "admin_id": "$ADMIN_ID",
  "default_lang": "$DEFAULT_LANG"
}
EOL

# Messages in Farsi
cat <<EOL > telegram_bot_instagram/messages/fa.json
{
  "welcome": "سلام {name}! به ربات خوش آمدید.",
  "download_manual": "دانلود دستی",
  "schedule_download": "زمان‌بندی دانلود",
  "back": "بازگشت",
  "main_menu": "منوی اصلی:",
  "feature_placeholder": "این ویژگی هنوز فعال نشده است."
}
EOL

# Messages in English
cat <<EOL > telegram_bot_instagram/messages/en.json
{
  "welcome": "Hello {name}! Welcome to the bot.",
  "download_manual": "Manual Download",
  "schedule_download": "Schedule Download",
  "back": "Back",
  "main_menu": "Main menu:",
  "feature_placeholder": "This feature is not active yet."
}
EOL

# bot.py
cat <<'EOL' > telegram_bot_instagram/bot.py
import json, logging, asyncio, os
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import ApplicationBuilder, CommandHandler, CallbackQueryHandler, ContextTypes
import instagram_downloader
import scheduler
import user_manager

with open('config.json', 'r', encoding='utf-8') as f:
    config = json.load(f)
BOT_TOKEN = config['bot_token']
ADMIN_ID = int(config['admin_id'])
DEFAULT_LANG = config['default_lang']

with open(f'messages/{DEFAULT_LANG}.json', 'r', encoding='utf-8') as f:
    messages = json.load(f)

logging.basicConfig(format='%(asctime)s - %(name)s - %(levelname)s - %(message)s', level=logging.INFO)
users = {}

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.effective_user
    user_manager.add_user(user.id, user.full_name)
    welcome_text = messages['welcome'].replace('{name}', user.full_name)
    await update.message.reply_text(welcome_text, reply_markup=main_menu_keyboard())

def main_menu_keyboard():
    keyboard = [
        [InlineKeyboardButton(messages['download_manual'], callback_data='download_manual')],
        [InlineKeyboardButton(messages['schedule_download'], callback_data='schedule_download')],
        [InlineKeyboardButton(messages['back'], callback_data='back')]
    ]
    return InlineKeyboardMarkup(keyboard)

async def button_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    if query.data == 'back':
        await query.edit_message_text(messages['main_menu'], reply_markup=main_menu_keyboard())
    elif query.data == 'download_manual':
        await instagram_downloader.manual_download(update, context)
    elif query.data == 'schedule_download':
        await scheduler.schedule_download(update, context)
    else:
        await query.edit_message_text(messages['feature_placeholder'])

if __name__ == '__main__':
    app = ApplicationBuilder().token(BOT_TOKEN).build()
    app.add_handler(CommandHandler('start', start))
    app.add_handler(CallbackQueryHandler(button_handler))
    print('Bot is running...')
    app.run_polling()
EOL

# scheduler.py
cat <<'EOL' > telegram_bot_instagram/scheduler.py
from apscheduler.schedulers.background import BackgroundScheduler
import instagram_downloader
import asyncio

scheduler = BackgroundScheduler()
scheduler.start()

async def schedule_download(update, context):
    await update.callback_query.edit_message_text('Scheduled download feature is in demo mode.')
EOL

# instagram_downloader.py
cat <<'EOL' > telegram_bot_instagram/instagram_downloader.py
import instaloader, tempfile, os, asyncio
from telegram import InputFile
import user_manager

async def manual_download(update, context):
    await update.callback_query.edit_message_text('Please send Instagram profile URL or post URL.')

    def check(msg):
        return msg.chat_id == update.effective_chat.id

    msg = await context.bot.wait_for('message', check=check)
    url = msg.text.strip()

    await update.callback_query.message.reply_text('Downloading...')

    L = instaloader.Instaloader(download_videos=True, save_metadata=False, download_comments=False)
    temp_dir = tempfile.mkdtemp()

    try:
        if '/p/' in url or '/reel/' in url:
            post = instaloader.Post.from_shortcode(L.context, url.split('/')[-2])
            file_path = os.path.join(temp_dir, post.shortcode + '.jpg')
            L.download_post(post, temp_dir)
            await context.bot.send_document(chat_id=update.effective_chat.id, document=InputFile(file_path))
        else:
            profile_name = url.split('/')[-2] if url.endswith('/') else url.split('/')[-1]
            profile = instaloader.Profile.from_username(L.context, profile_name)
            for post in profile.get_posts():
                L.download_post(post, temp_dir)
            # Send latest post as demo
            latest_file = os.path.join(temp_dir, os.listdir(temp_dir)[0])
            await context.bot.send_document(chat_id=update.effective_chat.id, document=InputFile(latest_file))
    except Exception as e:
        await update.callback_query.message.reply_text(f'Error: {str(e)}')
    finally:
        for f in os.listdir(temp_dir):
            os.remove(os.path.join(temp_dir, f))
        os.rmdir(temp_dir)
EOL

# user_manager.py
cat <<'EOL' > telegram_bot_instagram/user_manager.py
users = {}

def add_user(user_id, name):
    users[user_id] = {'name': name, 'active': True}

def is_active(user_id):
    return users.get(user_id, {}).get('active', False)
EOL

echo "\nInstallation complete! Run the bot using:\nsource bot_env/bin/activate\npython telegram_bot_instagram/bot.py"
