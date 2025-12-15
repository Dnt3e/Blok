#!/bin/bash
set -e

PROJECT="$HOME/telegram_insta_bot"
SERVICE="insta_bot"
CONFIG="$PROJECT/config.json"
SESSION_DIR="$PROJECT/sessions"
USER_DATA="$PROJECT/user_data"
LOG_FILE="$PROJECT/bot.log"

echo "Instagram Telegram Bot Installer"
echo "================================"
echo "1) Install/Reinstall Bot"
echo "2) Remove Bot completely"
echo "3) Start Bot"
echo "4) Restart Bot"
echo "5) Status Bot"
echo "6) View Logs"
read -p "Choose option [1-6]: " CHOICE

# Function to ask for config
ask_config() {
    read -p "Telegram Bot Token: " BOT_TOKEN
    while [[ -z "$BOT_TOKEN" ]]; do
        read -p "Bot Token cannot be empty: " BOT_TOKEN
    done
    
    read -p "Telegram Admin ID (numeric): " ADMIN_ID
    while ! [[ "$ADMIN_ID" =~ ^[0-9]+$ ]]; do
        read -p "Please enter valid numeric ID: " ADMIN_ID
    done
    
    read -p "Default language (fa/en) [en]: " DEFAULT_LANG
    DEFAULT_LANG=${DEFAULT_LANG:-en}
}

# Function to install dependencies
install_deps() {
    echo "Updating system packages..."
    sudo apt update -y
    
    echo "Installing Python and dependencies..."
    sudo apt install -y python3 python3-venv python3-pip python3-dev
    
    echo "Installing system utilities..."
    sudo apt install -y git curl wget jq
    
    echo "Cleaning up..."
    sudo apt autoremove -y
}

# Function to setup project
setup_project() {
    echo "Setting up project directory..."
    mkdir -p "$PROJECT"
    mkdir -p "$SESSION_DIR"
    mkdir -p "$USER_DATA"
    mkdir -p "$USER_DATA/downloads"
    
    cd "$PROJECT"
    
    # Create virtual environment
    if [ ! -d "venv" ]; then
        python3 -m venv venv
    fi
    
    source venv/bin/activate
    
    echo "Installing Python packages..."
    pip install --upgrade pip
    pip install python-telegram-bot==22.3
    pip install instaloader==4.14.2
    pip install pillow==10.3.0
    pip install requests==2.31.0
    
    # Create bot main file
    cat << 'PYTHON_CODE' > bot_main.py
#!/usr/bin/env python3
import os
import sys
import json
import logging
import asyncio
import shutil
from pathlib import Path
from datetime import datetime, timedelta
from typing import Dict, List, Optional, Tuple
import instaloader
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup, BotCommand
from telegram.ext import (
    Application,
    ApplicationBuilder,
    CommandHandler,
    CallbackQueryHandler,
    MessageHandler,
    ContextTypes,
    filters
)
from telegram.constants import ParseMode

# ========== Configuration ==========
BASE_DIR = Path(__file__).parent
CONFIG_FILE = BASE_DIR / "config.json"
USER_DATA_DIR = BASE_DIR / "user_data"
DOWNLOADS_DIR = USER_DATA_DIR / "downloads"
SESSIONS_DIR = BASE_DIR / "sessions"
LOG_FILE = BASE_DIR / "bot.log"

# Create directories
for d in [USER_DATA_DIR, DOWNLOADS_DIR, SESSIONS_DIR]:
    d.mkdir(exist_ok=True)

# Setup logging
logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    level=logging.INFO,
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

# Load config
if not CONFIG_FILE.exists():
    logger.error("Config file not found! Please run setup script.")
    sys.exit(1)

with open(CONFIG_FILE, 'r') as f:
    config = json.load(f)

BOT_TOKEN = config["bot_token"]
ADMIN_ID = int(config["admin_id"])
DEFAULT_LANG = config.get("default_language", "en")

# ========== Data Management ==========
class DataManager:
    def __init__(self):
        self.users_file = USER_DATA_DIR / "users.json"
        self.schedules_file = USER_DATA_DIR / "schedules.json"
        self.state_file = USER_DATA_DIR / "state.json"
        self.requests_file = USER_DATA_DIR / "join_requests.json"
        self._init_files()
    
    def _init_files(self):
        defaults = {
            self.users_file: {},
            self.schedules_file: {},
            self.state_file: {},
            self.requests_file: {}
        }
        for file, default in defaults.items():
            if not file.exists():
                with open(file, 'w') as f:
                    json.dump(default, f, indent=2)
    
    def load_users(self) -> Dict:
        with open(self.users_file, 'r') as f:
            return json.load(f)
    
    def save_users(self, users: Dict):
        with open(self.users_file, 'w') as f:
            json.dump(users, f, indent=2, default=str)
    
    def load_schedules(self) -> Dict:
        with open(self.schedules_file, 'r') as f:
            return json.load(f)
    
    def save_schedules(self, schedules: Dict):
        with open(self.schedules_file, 'w') as f:
            json.dump(schedules, f, indent=2, default=str)
    
    def load_state(self) -> Dict:
        with open(self.state_file, 'r') as f:
            return json.load(f)
    
    def save_state(self, state: Dict):
        with open(self.state_file, 'w') as f:
            json.dump(state, f, indent=2, default=str)
    
    def load_requests(self) -> Dict:
        with open(self.requests_file, 'r') as f:
            return json.load(f)
    
    def save_requests(self, requests: Dict):
        with open(self.requests_file, 'w') as f:
            json.dump(requests, f, indent=2, default=str)

data_manager = DataManager()

# ========== Language System ==========
class Translation:
    LANGUAGES = {
        "fa": {
            "start": "🤖 ربات دانلود اینستاگرام\nبه ربات خوش آمدید {name}!\n\nانتخاب کنید:",
            "welcome": "👋 سلام {name}! به ربات دانلود اینستاگرام خوش آمدید.",
            "menu": "📱 منوی اصلی",
            "add_account": "➕ افزودن اکانت",
            "remove_account": "🗑 حذف اکانت",
            "list_accounts": "📋 لیست اکانت‌ها",
            "check_now": "🔄 بررسی جدیدها",
            "download_link": "🔗 دانلود با لینک",
            "schedule": "⏰ زمان‌بندی",
            "upload_session": "🔐 آپلود سشن",
            "manage_users": "👥 مدیریت کاربران",
            "language": "🌐 تغییر زبان",
            "back": "🔙 بازگشت",
            "admin_panel": "🔧 پنل ادمین",
            "status": "📊 وضعیت",
            "cancel": "❌ لغو",
            "confirm": "✅ تأیید",
            "username_prompt": "نام کاربری اینستاگرام را وارد کنید:",
            "added_account": "✅ اکانت {username} اضافه شد.",
            "removed_account": "✅ اکانت {username} حذف شد.",
            "no_accounts": "ℹ️ هیچ اکانتی اضافه نشده است.",
            "accounts_list": "📋 اکانت‌های شما:\n{list}",
            "link_prompt": "لینک پست، استوری یا ریلز را ارسال کنید:",
            "downloading": "📥 در حال دانلود...",
            "download_complete": "✅ دانلود کامل شد.",
            "download_error": "❌ خطا در دانلود.",
            "invalid_link": "❌ لینک نامعتبر.",
            "login_required": "🔒 برای دانلود استوری نیاز به ورود است.",
            "schedule_prompt": "⏰ فاصله بررسی (ساعت):",
            "schedule_set": "✅ زمان‌بندی تنظیم شد: هر {hours} ساعت.",
            "schedule_remove": "✅ زمان‌بندی حذف شد.",
            "session_prompt": "📤 فایل سشن اینستاگرام را ارسال کنید (session-username):",
            "session_success": "✅ سشن با موفقیت آپلود شد.",
            "session_error": "❌ خطا در بارگذاری سشن.",
            "user_blocked": "✅ کاربر مسدود شد.",
            "user_unblocked": "✅ کاربر آزاد شد.",
            "user_list": "👥 لیست کاربران:\n{list}",
            "join_request_sent": "📨 درخواست عضویت ارسال شد.",
            "no_permission": "⛔ دسترسی غیرمجاز.",
            "processing": "⏳ در حال پردازش...",
            "file_too_large": "❌ فایل بسیار بزرگ است.",
            "cleaning": "🧹 در حال پاک‌سازی فایل‌های موقت...",
            "cleaned": "✅ پاک‌سازی کامل شد.",
            "post_info": "📅 تاریخ: {date}\n👤 کاربر: {username}\n📝 کپشن: {caption}\n❤️ لایک: {likes}",
            "story_info": "📅 تاریخ: {date}\n👤 کاربر: {username}",
            "reels_info": "📅 تاریخ: {date}\n👤 کاربر: {username}\n🎵 موسیقی: {music}",
            "unknown_type": "نوع نامشخص"
        },
        "en": {
            "start": "🤖 Instagram Download Bot\nWelcome {name}!\n\nPlease select:",
            "welcome": "👋 Hello {name}! Welcome to Instagram Download Bot.",
            "menu": "📱 Main Menu",
            "add_account": "➕ Add Account",
            "remove_account": "🗑 Remove Account",
            "list_accounts": "📋 List Accounts",
            "check_now": "🔄 Check New",
            "download_link": "🔗 Download by Link",
            "schedule": "⏰ Schedule",
            "upload_session": "🔐 Upload Session",
            "manage_users": "👥 Manage Users",
            "language": "🌐 Change Language",
            "back": "🔙 Back",
            "admin_panel": "🔧 Admin Panel",
            "status": "📊 Status",
            "cancel": "❌ Cancel",
            "confirm": "✅ Confirm",
            "username_prompt": "Enter Instagram username:",
            "added_account": "✅ Account {username} added.",
            "removed_account": "✅ Account {username} removed.",
            "no_accounts": "ℹ️ No accounts added.",
            "accounts_list": "📋 Your accounts:\n{list}",
            "link_prompt": "Send post, story or reels link:",
            "downloading": "📥 Downloading...",
            "download_complete": "✅ Download completed.",
            "download_error": "❌ Download error.",
            "invalid_link": "❌ Invalid link.",
            "login_required": "🔒 Login required for stories.",
            "schedule_prompt": "⏰ Check interval (hours):",
            "schedule_set": "✅ Schedule set: every {hours} hours.",
            "schedule_remove": "✅ Schedule removed.",
            "session_prompt": "📤 Send Instagram session file (session-username):",
            "session_success": "✅ Session uploaded successfully.",
            "session_error": "❌ Error loading session.",
            "user_blocked": "✅ User blocked.",
            "user_unblocked": "✅ User unblocked.",
            "user_list": "👥 User list:\n{list}",
            "join_request_sent": "📨 Join request sent.",
            "no_permission": "⛔ No permission.",
            "processing": "⏳ Processing...",
            "file_too_large": "❌ File too large.",
            "cleaning": "🧹 Cleaning temporary files...",
            "cleaned": "✅ Cleaning completed.",
            "post_info": "📅 Date: {date}\n👤 User: {username}\n📝 Caption: {caption}\n❤️ Likes: {likes}",
            "story_info": "📅 Date: {date}\n👤 User: {username}",
            "reels_info": "📅 Date: {date}\n👤 User: {username}\n🎵 Music: {music}",
            "unknown_type": "Unknown type"
        }
    }
    
    @classmethod
    def get(cls, key: str, lang: str = "en", **kwargs) -> str:
        text = cls.LANGUAGES.get(lang, cls.LANGUAGES["en"]).get(key, key)
        return text.format(**kwargs) if kwargs else text

# ========== User Management ==========
class UserManager:
    def __init__(self):
        self.users = data_manager.load_users()
    
    def ensure_user(self, user_id: int, username: str = "", first_name: str = "") -> Dict:
        user_id_str = str(user_id)
        if user_id_str not in self.users:
            self.users[user_id_str] = {
                "id": user_id,
                "username": username,
                "first_name": first_name,
                "role": "admin" if user_id == ADMIN_ID else "user",
                "language": DEFAULT_LANG,
                "blocked": False,
                "accounts": [],
                "schedule": None,
                "join_request_sent": False,
                "created_at": datetime.now().isoformat(),
                "last_active": datetime.now().isoformat()
            }
            self.save()
        else:
            self.users[user_id_str]["last_active"] = datetime.now().isoformat()
            if username:
                self.users[user_id_str]["username"] = username
            if first_name:
                self.users[user_id_str]["first_name"] = first_name
            self.save()
        return self.users[user_id_str]
    
    def get_user(self, user_id: int) -> Optional[Dict]:
        return self.users.get(str(user_id))
    
    def is_admin(self, user_id: int) -> bool:
        user = self.get_user(user_id)
        return user and user.get("role") == "admin"
    
    def is_blocked(self, user_id: int) -> bool:
        user = self.get_user(user_id)
        return user and user.get("blocked", False)
    
    def change_language(self, user_id: int, language: str):
        user_id_str = str(user_id)
        if user_id_str in self.users:
            self.users[user_id_str]["language"] = language
            self.save()
    
    def add_account(self, user_id: int, username: str):
        user_id_str = str(user_id)
        if user_id_str in self.users:
            if username not in self.users[user_id_str]["accounts"]:
                self.users[user_id_str]["accounts"].append(username)
                self.save()
    
    def remove_account(self, user_id: int, username: str):
        user_id_str = str(user_id)
        if user_id_str in self.users and username in self.users[user_id_str]["accounts"]:
            self.users[user_id_str]["accounts"].remove(username)
            self.save()
    
    def set_schedule(self, user_id: int, interval_hours: int):
        user_id_str = str(user_id)
        if user_id_str in self.users:
            self.users[user_id_str]["schedule"] = {
                "interval": interval_hours,
                "next_check": (datetime.now() + timedelta(hours=interval_hours)).isoformat()
            }
            self.save()
    
    def remove_schedule(self, user_id: int):
        user_id_str = str(user_id)
        if user_id_str in self.users:
            self.users[user_id_str]["schedule"] = None
            self.save()
    
    def block_user(self, user_id: int):
        user_id_str = str(user_id)
        if user_id_str in self.users:
            self.users[user_id_str]["blocked"] = True
            self.save()
    
    def unblock_user(self, user_id: int):
        user_id_str = str(user_id)
        if user_id_str in self.users:
            self.users[user_id_str]["blocked"] = False
            self.save()
    
    def save(self):
        data_manager.save_users(self.users)

user_manager = UserManager()

# ========== Instagram Manager ==========
class InstagramManager:
    def __init__(self):
        self.loaders: Dict[int, instaloader.Instaloader] = {}
        self.session_file = SESSIONS_DIR / "session"
    
    def get_loader(self, user_id: int) -> instaloader.Instaloader:
        if user_id not in self.loaders:
            self.loaders[user_id] = instaloader.Instaloader(
                save_metadata=False,
                download_comments=False,
                compress_json=False,
                dirname_pattern=str(DOWNLOADS_DIR / str(user_id) / "{target}"),
                quiet=True
            )
            # Try to load session
            if self.session_file.exists():
                try:
                    self.loaders[user_id].load_session_from_file(
                        filename=str(self.session_file),
                        username=self.session_file.name.replace("session-", "")
                    )
                except Exception as e:
                    logger.error(f"Failed to load session: {e}")
        return self.loaders[user_id]
    
    def save_session(self, session_data: bytes, username: str):
        session_path = SESSIONS_DIR / f"session-{username}"
        with open(session_path, 'wb') as f:
            f.write(session_data)
        # Update main session file
        if self.session_file.exists():
            self.session_file.unlink()
        session_path.rename(self.session_file)
    
    def is_logged_in(self, user_id: int) -> bool:
        loader = self.get_loader(user_id)
        return loader.context.is_logged_in

instagram_manager = InstagramManager()

# ========== Download Manager ==========
class DownloadManager:
    @staticmethod
    async def download_post(shortcode: str, user_id: int) -> Tuple[List[Path], Dict]:
        loader = instagram_manager.get_loader(user_id)
        target_dir = DOWNLOADS_DIR / str(user_id) / shortcode
        
        try:
            post = instaloader.Post.from_shortcode(loader.context, shortcode)
            loader.download_post(post, target=shortcode)
            
            # Collect downloaded files
            files = []
            for item in target_dir.iterdir():
                if item.is_file():
                    files.append(item)
            
            # Get post info
            info = {
                "type": "post",
                "date": post.date_utc.isoformat(),
                "username": post.owner_username,
                "caption": post.caption or "",
                "likes": post.likes,
                "comments": post.comments,
                "shortcode": shortcode
            }
            
            return files, info
        except Exception as e:
            logger.error(f"Error downloading post {shortcode}: {e}")
            return [], {}
    
    @staticmethod
    async def download_story(username: str, user_id: int) -> Tuple[List[Path], Dict]:
        loader = instagram_manager.get_loader(user_id)
        target_dir = DOWNLOADS_DIR / str(user_id) / f"story_{username}"
        
        if not loader.context.is_logged_in:
            return [], {}
        
        try:
            profile = instaloader.Profile.from_username(loader.context, username)
            stories = instaloader.get_stories([profile.userid], loader.context)
            
            files = []
            story_info = {}
            
            for story in stories:
                for item in story.get_items():
                    loader.download_storyitem(item, target=f"story_{username}")
                    
                    # Get latest file
                    for item_file in target_dir.iterdir():
                        if item_file.is_file():
                            files.append(item_file)
                    
                    story_info = {
                        "type": "story",
                        "date": item.date_utc.isoformat(),
                        "username": username,
                        "duration": item.video_duration if hasattr(item, 'video_duration') else 0
                    }
                    break  # Only get first story item
            
            return files, story_info
        except Exception as e:
            logger.error(f"Error downloading story {username}: {e}")
            return [], {}
    
    @staticmethod
    async def download_reel(shortcode: str, user_id: int) -> Tuple[List[Path], Dict]:
        # Reels are treated as posts
        return await DownloadManager.download_post(shortcode, user_id)
    
    @staticmethod
    async def download_profile(username: str, user_id: int) -> Tuple[List[Path], List[Dict]]:
        loader = instagram_manager.get_loader(user_id)
        target_dir = DOWNLOADS_DIR / str(user_id) / username
        
        try:
            profile = instaloader.Profile.from_username(loader.context, username)
            
            # Get latest posts
            files = []
            infos = []
            count = 0
            
            for post in profile.get_posts():
                if count >= 10:  # Limit to 10 latest posts
                    break
                
                post_dir = target_dir / post.shortcode
                if not post_dir.exists():
                    loader.download_post(post, target=username)
                
                # Collect files
                for item in post_dir.iterdir():
                    if item.is_file():
                        files.append(item)
                
                infos.append({
                    "type": "post",
                    "date": post.date_utc.isoformat(),
                    "username": username,
                    "caption": post.caption or "",
                    "likes": post.likes,
                    "shortcode": post.shortcode
                })
                
                count += 1
            
            return files, infos
        except Exception as e:
            logger.error(f"Error downloading profile {username}: {e}")
            return [], []
    
    @staticmethod
    def cleanup(user_id: int):
        user_dir = DOWNLOADS_DIR / str(user_id)
        if user_dir.exists():
            shutil.rmtree(user_dir)
            user_dir.mkdir(parents=True)

download_manager = DownloadManager()

# ========== Button Builders ==========
class ButtonBuilder:
    @staticmethod
    def main_menu(user_id: int):
        user = user_manager.get_user(user_id)
        lang = user["language"] if user else DEFAULT_LANG
        is_admin = user_manager.is_admin(user_id)
        
        buttons = [
            [InlineKeyboardButton(Translation.get("add_account", lang), callback_data="add_account")],
            [InlineKeyboardButton(Translation.get("list_accounts", lang), callback_data="list_accounts")],
            [InlineKeyboardButton(Translation.get("remove_account", lang), callback_data="remove_account")],
            [InlineKeyboardButton(Translation.get("check_now", lang), callback_data="check_now")],
            [InlineKeyboardButton(Translation.get("download_link", lang), callback_data="download_link")],
            [InlineKeyboardButton(Translation.get("schedule", lang), callback_data="schedule")],
            [InlineKeyboardButton(Translation.get("language", lang), callback_data="change_lang")]
        ]
        
        if is_admin:
            buttons.append([InlineKeyboardButton(Translation.get("admin_panel", lang), callback_data="admin_panel")])
        
        buttons.append([InlineKeyboardButton(Translation.get("back", lang), callback_data="main_menu")])
        
        return InlineKeyboardMarkup(buttons)
    
    @staticmethod
    def admin_menu(lang: str):
        buttons = [
            [InlineKeyboardButton(Translation.get("upload_session", lang), callback_data="upload_session")],
            [InlineKeyboardButton(Translation.get("manage_users", lang), callback_data="manage_users")],
            [InlineKeyboardButton(Translation.get("status", lang), callback_data="bot_status")],
            [InlineKeyboardButton(Translation.get("back", lang), callback_data="main_menu")]
        ]
        return InlineKeyboardMarkup(buttons)
    
    @staticmethod
    def language_menu(lang: str):
        buttons = [
            [InlineKeyboardButton("🇺🇸 English", callback_data="set_lang_en")],
            [InlineKeyboardButton("🇮🇷 فارسی", callback_data="set_lang_fa")],
            [InlineKeyboardButton(Translation.get("back", lang), callback_data="main_menu")]
        ]
        return InlineKeyboardMarkup(buttons)
    
    @staticmethod
    def back_button(lang: str):
        return InlineKeyboardMarkup([[InlineKeyboardButton(Translation.get("back", lang), callback_data="main_menu")]])

# ========== Message Senders ==========
async def send_message_with_menu(update: Update, text: str, user_id: int):
    user = user_manager.get_user(user_id)
    lang = user["language"] if user else DEFAULT_LANG
    
    if update.callback_query:
        await update.callback_query.edit_message_text(
            text=text,
            reply_markup=ButtonBuilder.main_menu(user_id),
            parse_mode=ParseMode.HTML
        )
    else:
        await update.message.reply_text(
            text=text,
            reply_markup=ButtonBuilder.main_menu(user_id),
            parse_mode=ParseMode.HTML
        )

async def send_files_with_info(update: Update, files: List[Path], info: Dict, user_id: int):
    user = user_manager.get_user(user_id)
    lang = user["language"] if user else DEFAULT_LANG
    
    if not files:
        await update.message.reply_text(Translation.get("download_error", lang))
        return
    
    # Send info first
    info_text = ""
    if info.get("type") == "post":
        caption = info.get("caption", "")[:500] + "..." if len(info.get("caption", "")) > 500 else info.get("caption", "")
        info_text = Translation.get("post_info", lang,
            date=datetime.fromisoformat(info["date"]).strftime("%Y-%m-%d %H:%M:%S"),
            username=info["username"],
            caption=caption,
            likes=info.get("likes", 0)
        )
    elif info.get("type") == "story":
        info_text = Translation.get("story_info", lang,
            date=datetime.fromisoformat(info["date"]).strftime("%Y-%m-%d %H:%M:%S"),
            username=info["username"]
        )
    elif info.get("type") == "reels":
        info_text = Translation.get("reels_info", lang,
            date=datetime.fromisoformat(info["date"]).strftime("%Y-%m-%d %H:%M:%S"),
            username=info["username"],
            music=info.get("music", "N/A")
        )
    
    if info_text:
        await update.message.reply_text(info_text)
    
    # Send files
    for file in files:
        try:
            with open(file, 'rb') as f:
                if file.suffix.lower() in ['.jpg', '.jpeg', '.png', '.gif']:
                    await update.message.reply_photo(f)
                elif file.suffix.lower() in ['.mp4', '.mov', '.avi']:
                    await update.message.reply_video(f)
                else:
                    await update.message.reply_document(f)
        except Exception as e:
            logger.error(f"Error sending file {file}: {e}")
    
    # Cleanup
    download_manager.cleanup(user_id)

# ========== Command Handlers ==========
async def start_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.effective_user
    user_manager.ensure_user(user.id, user.username, user.first_name)
    
    if user_manager.is_blocked(user.id):
        await update.message.reply_text("⛔ شما مسدود شده‌اید / You are blocked.")
        return
    
    welcome_text = Translation.get("welcome", 
        user_manager.get_user(user.id)["language"],
        name=user.first_name or user.username
    )
    
    await update.message.reply_text(
        welcome_text,
        reply_markup=ButtonBuilder.main_menu(user.id),
        parse_mode=ParseMode.HTML
    )

async def help_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.effective_user
    user_data = user_manager.ensure_user(user.id)
    lang = user_data["language"]
    
    help_text = """
📖 **راهنما / Help**

🔗 **دانلود با لینک / Download by link:**
- پست: `https://www.instagram.com/p/XXXXX/`
- ریلز: `https://www.instagram.com/reel/XXXXX/`
- استوری: نیاز به ورود دارد

➕ **افزودن اکانت / Add account:**
نام کاربری را وارد کنید تا جدیدترین پست‌ها بررسی شوند

⏰ **زمان‌بندی / Scheduling:**
می‌توانید فاصله بررسی اکانت‌ها را تنظیم کنید

🌐 **تغییر زبان / Change language:**
دکمه تغییر زبان را فشار دهید

🔧 **پنل ادمین / Admin panel:**
فقط برای ادمین‌ها
    """
    
    await update.message.reply_text(
        help_text,
        reply_markup=ButtonBuilder.main_menu(user.id),
        parse_mode=ParseMode.HTML
    )

# ========== Callback Handlers ==========
async def callback_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    
    user_id = query.from_user.id
    user_data = user_manager.ensure_user(user_id)
    
    if user_manager.is_blocked(user_id):
        return
    
    lang = user_data["language"]
    
    # Main menu
    if query.data == "main_menu":
        await send_message_with_menu(update, Translation.get("menu", lang), user_id)
        return
    
    # Add account
    elif query.data == "add_account":
        context.user_data["awaiting"] = "add_account"
        await query.edit_message_text(
            Translation.get("username_prompt", lang),
            reply_markup=ButtonBuilder.back_button(lang)
        )
    
    # Remove account
    elif query.data == "remove_account":
        accounts = user_data["accounts"]
        if not accounts:
            await query.edit_message_text(
                Translation.get("no_accounts", lang),
                reply_markup=ButtonBuilder.main_menu(user_id)
            )
            return
        
        buttons = []
        for acc in accounts:
            buttons.append([InlineKeyboardButton(f"🗑 {acc}", callback_data=f"remove_{acc}")])
        buttons.append([InlineKeyboardButton(Translation.get("back", lang), callback_data="main_menu")])
        
        await query.edit_message_text(
            "اکانت برای حذف انتخاب کنید / Select account to remove:",
            reply_markup=InlineKeyboardMarkup(buttons)
        )
    
    # Remove specific account
    elif query.data.startswith("remove_"):
        username = query.data.replace("remove_", "")
        user_manager.remove_account(user_id, username)
        await query.edit_message_text(
            Translation.get("removed_account", lang, username=username),
            reply_markup=ButtonBuilder.main_menu(user_id)
        )
    
    # List accounts
    elif query.data == "list_accounts":
        accounts = user_data["accounts"]
        if not accounts:
            await query.edit_message_text(
                Translation.get("no_accounts", lang),
                reply_markup=ButtonBuilder.main_menu(user_id)
            )
            return
        
        accounts_list = "\n".join([f"• @{acc}" for acc in accounts])
        await query.edit_message_text(
            Translation.get("accounts_list", lang, list=accounts_list),
            reply_markup=ButtonBuilder.main_menu(user_id)
        )
    
    # Check now
    elif query.data == "check_now":
        await query.edit_message_text(Translation.get("processing", lang))
        
        accounts = user_data["accounts"]
        if not accounts:
            await query.edit_message_text(
                Translation.get("no_accounts", lang),
                reply_markup=ButtonBuilder.main_menu(user_id)
            )
            return
        
        for account in accounts:
            try:
                files, infos = await download_manager.download_profile(account, user_id)
                for info in infos:
                    # Create simple message for each post
                    post_text = f"📱 @{account}\n📅 {datetime.fromisoformat(info['date']).strftime('%Y-%m-%d %H:%M')}"
                    await context.bot.send_message(user_id, post_text)
                
                # Send files if any
                if files:
                    await send_files_with_info(update, files, infos[0] if infos else {}, user_id)
                
            except Exception as e:
                logger.error(f"Error checking {account}: {e}")
        
        await query.edit_message_text(
            Translation.get("download_complete", lang),
            reply_markup=ButtonBuilder.main_menu(user_id)
        )
    
    # Download by link
    elif query.data == "download_link":
        context.user_data["awaiting"] = "download_link"
        await query.edit_message_text(
            Translation.get("link_prompt", lang),
            reply_markup=ButtonBuilder.back_button(lang)
        )
    
    # Schedule
    elif query.data == "schedule":
        if user_data["schedule"]:
            buttons = [
                [InlineKeyboardButton("⏰ مشاهده زمان‌بندی / View Schedule", callback_data="view_schedule")],
                [InlineKeyboardButton("🗑 حذف زمان‌بندی / Remove Schedule", callback_data="remove_schedule")],
                [InlineKeyboardButton(Translation.get("back", lang), callback_data="main_menu")]
            ]
            text = "⏰ زمان‌بندی فعال است / Schedule is active"
        else:
            context.user_data["awaiting"] = "set_schedule"
            text = Translation.get("schedule_prompt", lang)
            buttons = ButtonBuilder.back_button(lang)
        
        await query.edit_message_text(text, reply_markup=buttons)
    
    # Remove schedule
    elif query.data == "remove_schedule":
        user_manager.remove_schedule(user_id)
        await query.edit_message_text(
            Translation.get("schedule_remove", lang),
            reply_markup=ButtonBuilder.main_menu(user_id)
        )
    
    # View schedule
    elif query.data == "view_schedule":
        schedule = user_data["schedule"]
        if schedule:
            text = f"⏰ زمان‌بندی / Schedule:\n📅 هر {schedule['interval']} ساعت / Every {schedule['interval']} hours"
        else:
            text = "ℹ️ زمان‌بندی تنظیم نشده / No schedule set"
        await query.edit_message_text(text, reply_markup=ButtonBuilder.main_menu(user_id))
    
    # Change language
    elif query.data == "change_lang":
        await query.edit_message_text(
            "🌐 زبان / Language:",
            reply_markup=ButtonBuilder.language_menu(lang)
        )
    
    # Set language
    elif query.data.startswith("set_lang_"):
        new_lang = query.data.replace("set_lang_", "")
        user_manager.change_language(user_id, new_lang)
        await query.edit_message_text(
            f"✅ زبان تغییر کرد به / Language changed to: {new_lang}",
            reply_markup=ButtonBuilder.main_menu(user_id)
        )
    
    # Admin panel
    elif query.data == "admin_panel":
        if not user_manager.is_admin(user_id):
            await query.edit_message_text(
                Translation.get("no_permission", lang),
                reply_markup=ButtonBuilder.main_menu(user_id)
            )
            return
        
        await query.edit_message_text(
            "🔧 پنل ادمین / Admin Panel",
            reply_markup=ButtonBuilder.admin_menu(lang)
        )
    
    # Upload session (admin only)
    elif query.data == "upload_session":
        if not user_manager.is_admin(user_id):
            return
        
        context.user_data["awaiting"] = "upload_session"
        await query.edit_message_text(
            Translation.get("session_prompt", lang),
            reply_markup=ButtonBuilder.back_button(lang)
        )
    
    # Manage users (admin only)
    elif query.data == "manage_users":
        if not user_manager.is_admin(user_id):
            return
        
        users = user_manager.users
        user_list = []
        for uid, data in users.items():
            status = "🚫" if data.get("blocked") else "✅"
            role = "👑" if data.get("role") == "admin" else "👤"
            user_list.append(f"{status} {role} {data.get('first_name', 'N/A')} (@{data.get('username', 'N/A')})")
        
        text = Translation.get("user_list", lang, list="\n".join(user_list))
        
        # Add action buttons
        buttons = [
            [InlineKeyboardButton("📊 آمار / Stats", callback_data="user_stats")],
            [InlineKeyboardButton(Translation.get("back", lang), callback_data="admin_panel")]
        ]
        
        await query.edit_message_text(text, reply_markup=InlineKeyboardMarkup(buttons))
    
    # Bot status
    elif query.data == "bot_status":
        if not user_manager.is_admin(user_id):
            return
        
        import psutil
        import time
        
        # System stats
        cpu_percent = psutil.cpu_percent()
        memory = psutil.virtual_memory()
        disk = psutil.disk_usage('/')
        
        # Bot stats
        total_users = len(user_manager.users)
        active_users = sum(1 for u in user_manager.users.values() 
                          if datetime.now() - datetime.fromisoformat(u["last_active"]) < timedelta(days=7))
        
        status_text = f"""
📊 **Bot Status**

🤖 **Users:**
• Total: {total_users}
• Active (7d): {active_users}

💻 **System:**
• CPU: {cpu_percent}%
• Memory: {memory.percent}%
• Disk: {disk.percent}%

⏰ **Uptime:** {time.time() - psutil.boot_time():.0f}s
        """
        
        await query.edit_message_text(
            status_text,
            reply_markup=ButtonBuilder.admin_menu(lang),
            parse_mode=ParseMode.HTML
        )

# ========== Message Handlers ==========
async def message_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.effective_user
    user_data = user_manager.ensure_user(user.id)
    
    if user_manager.is_blocked(user.id):
        return
    
    lang = user_data["language"]
    awaiting = context.user_data.get("awaiting")
    
    # Handle text messages
    if update.message.text:
        text = update.message.text.strip()
        
        # Add account
        if awaiting == "add_account":
            username = text.replace("@", "").strip()
            if username:
                user_manager.add_account(user.id, username)
                await update.message.reply_text(
                    Translation.get("added_account", lang, username=username),
                    reply_markup=ButtonBuilder.main_menu(user.id)
                )
                context.user_data["awaiting"] = None
        
        # Download by link
        elif awaiting == "download_link":
            await update.message.reply_text(Translation.get("downloading", lang))
            
            try:
                # Parse link
                if "/p/" in text:  # Post
                    shortcode = text.split("/p/")[1].split("/")[0].split("?")[0]
                    files, info = await download_manager.download_post(shortcode, user.id)
                elif "/reel/" in text:  # Reels
                    shortcode = text.split("/reel/")[1].split("/")[0].split("?")[0]
                    files, info = await download_manager.download_post(shortcode, user.id)
                    info["type"] = "reels"
                elif "/stories/" in text:  # Story
                    if not instagram_manager.is_logged_in(user.id):
                        await update.message.reply_text(Translation.get("login_required", lang))
                        return
                    username = text.split("/stories/")[1].split("/")[0]
                    files, info = await download_manager.download_story(username, user.id)
                else:
                    await update.message.reply_text(Translation.get("invalid_link", lang))
                    return
                
                if files:
                    await send_files_with_info(update, files, info, user.id)
                    await update.message.reply_text(
                        Translation.get("download_complete", lang),
                        reply_markup=ButtonBuilder.main_menu(user.id)
                    )
                else:
                    await update.message.reply_text(
                        Translation.get("download_error", lang),
                        reply_markup=ButtonBuilder.main_menu(user.id)
                    )
                
            except Exception as e:
                logger.error(f"Error downloading from link: {e}")
                await update.message.reply_text(
                    Translation.get("download_error", lang),
                    reply_markup=ButtonBuilder.main_menu(user.id)
                )
            
            context.user_data["awaiting"] = None
        
        # Set schedule
        elif awaiting == "set_schedule":
            try:
                hours = int(text)
                if 1 <= hours <= 24:
                    user_manager.set_schedule(user.id, hours)
                    await update.message.reply_text(
                        Translation.get("schedule_set", lang, hours=hours),
                        reply_markup=ButtonBuilder.main_menu(user.id)
                    )
                else:
                    await update.message.reply_text(
                        "❌ محدوده معتبر: 1 تا 24 ساعت / Valid range: 1-24 hours",
                        reply_markup=ButtonBuilder.back_button(lang)
                    )
            except ValueError:
                await update.message.reply_text(
                    "❌ لطفاً عدد وارد کنید / Please enter a number",
                    reply_markup=ButtonBuilder.back_button(lang)
                )
    
    # Handle document (session file)
    elif update.message.document and awaiting == "upload_session":
        if not user_manager.is_admin(user.id):
            return
        
        doc = update.message.document
        if doc.file_size > 10 * 1024 * 1024:  # 10MB limit
            await update.message.reply_text(Translation.get("file_too_large", lang))
            return
        
        # Download session file
        file = await doc.get_file()
        session_data = await file.download_as_bytearray()
        
        # Extract username from filename
        filename = doc.file_name
        if filename.startswith("session-"):
            username = filename.replace("session-", "")
            instagram_manager.save_session(session_data, username)
            
            await update.message.reply_text(
                Translation.get("session_success", lang),
                reply_markup=ButtonBuilder.admin_menu(lang)
            )
        else:
            await update.message.reply_text(
                "❌ نام فایل باید با session- شروع شود / Filename must start with session-",
                reply_markup=ButtonBuilder.back_button(lang)
            )
        
        context.user_data["awaiting"] = None

# ========== Scheduler ==========
async def check_scheduled_tasks(context: ContextTypes.DEFAULT_TYPE):
    """Check scheduled tasks for all users"""
    users = user_manager.users
    
    for user_id_str, user_data in users.items():
        user_id = int(user_id_str)
        
        # Skip if blocked or no schedule
        if user_data.get("blocked") or not user_data.get("schedule"):
            continue
        
        schedule = user_data["schedule"]
        next_check = datetime.fromisoformat(schedule["next_check"])
        
        if datetime.now() >= next_check:
            # Update next check time
            user_manager.set_schedule(user_id, schedule["interval"])
            
            # Check accounts
            accounts = user_data.get("accounts", [])
            for account in accounts:
                try:
                    files, infos = await download_manager.download_profile(account, user_id)
                    
                    # Send notification
                    if files:
                        await context.bot.send_message(
                            user_id,
                            f"📱 یافتن محتوای جدید برای @{account} / Found new content for @{account}"
                        )
                        
                        # Send first post
                        if infos:
                            await send_files_with_info(
                                Update(update_id=0, message=None),  # Dummy update
                                files[:10],  # Limit to 10 files
                                infos[0],
                                user_id
                            )
                    
                except Exception as e:
                    logger.error(f"Scheduled check error for {account}: {e}")

# ========== Main ==========
def main():
    """Start the bot"""
    # Create application
    application = ApplicationBuilder().token(BOT_TOKEN).build()
    
    # Add handlers
    application.add_handler(CommandHandler("start", start_command))
    application.add_handler(CommandHandler("help", help_command))
    application.add_handler(CallbackQueryHandler(callback_handler))
    application.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, message_handler))
    application.add_handler(MessageHandler(filters.Document.ALL, message_handler))
    
    # Add job queue for scheduled tasks
    job_queue = application.job_queue
    if job_queue:
        job_queue.run_repeating(
            check_scheduled_tasks,
            interval=300,  # Check every 5 minutes
            first=10
        )
    
    # Set bot commands
    async def post_init(application: Application):
        await application.bot.set_my_commands([
            BotCommand("start", "شروع ربات / Start bot"),
            BotCommand("help", "راهنما / Help")
        ])
    
    application.post_init = post_init
    
    # Start bot
    logger.info("Starting bot...")
    application.run_polling()

if __name__ == "__main__":
    main()
PYTHON_CODE

    # Create config file
    cat <<EOF > config.json
{
  "bot_token": "$BOT_TOKEN",
  "admin_id": $ADMIN_ID,
  "default_language": "$DEFAULT_LANG"
}
EOF

    # Create service file
    sudo tee /etc/systemd/system/$SERVICE.service > /dev/null <<EOF
[Unit]
Description=Telegram Instagram Download Bot
After=network.target
Wants=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$PROJECT
Environment="PATH=$PROJECT/venv/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=$PROJECT/venv/bin/python3 $PROJECT/bot_main.py
Restart=always
RestartSec=10
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=multi-user.target
EOF

    # Set permissions
    chmod +x bot_main.py
    
    # Reload systemd and enable service
    sudo systemctl daemon-reload
    sudo systemctl enable $SERVICE
    sudo systemctl start $SERVICE
    
    echo ""
    echo "========================================"
    echo "✅ Bot installation completed!"
    echo "📁 Project directory: $PROJECT"
    echo "📝 Config file: $CONFIG"
    echo "📊 Log file: $LOG_FILE"
    echo "🔄 Service: $SERVICE"
    echo ""
    echo "📋 Commands:"
    echo "  sudo systemctl start $SERVICE"
    echo "  sudo systemctl stop $SERVICE"
    echo "  sudo systemctl restart $SERVICE"
    echo "  sudo systemctl status $SERVICE"
    echo "  tail -f $LOG_FILE"
    echo "========================================"
}

# ========== Main script logic ==========
case "$CHOICE" in
    1)
        ask_config
        install_deps
        setup_project
        ;;
    2)
        echo "Removing bot completely..."
        sudo systemctl stop $SERVICE 2>/dev/null || true
        sudo systemctl disable $SERVICE 2>/dev/null || true
        sudo rm -f /etc/systemd/system/$SERVICE.service
        sudo systemctl daemon-reload
        rm -rf "$PROJECT"
        echo "✅ Bot removed completely."
        ;;
    3)
        sudo systemctl start $SERVICE
        echo "✅ Bot started."
        ;;
    4)
        sudo systemctl restart $SERVICE
        echo "✅ Bot restarted."
        ;;
    5)
        sudo systemctl status $SERVICE
        ;;
    6)
        if [ -f "$LOG_FILE" ]; then
            tail -f "$LOG_FILE"
        else
            echo "Log file not found: $LOG_FILE"
        fi
        ;;
    *)
        echo "❌ Invalid option"
        exit 1
        ;;
esac
