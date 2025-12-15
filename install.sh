#!/bin/bash
set -e

PROJECT="$HOME/Blok"
SERVICE="insta_bot"

echo "Instagram Telegram Bot Manager"
echo "=============================="
echo "1) Install/Update Bot"
echo "2) Remove Bot completely"
echo "3) Start Bot"
echo "4) Restart Bot"
echo "5) Status Bot"
echo "6) View Logs"
read -p "Choose option [1-6]: " C

if [ "$C" == "1" ]; then
    read -p "Telegram Bot Token: " BOT_TOKEN
    read -p "Telegram Admin ID: " ADMIN_ID
    
    echo "Installing dependencies..."
    sudo apt update
    sudo apt install -y python3 python3-venv python3-pip git curl
    
    mkdir -p "$PROJECT"
    cd "$PROJECT"
    
    # ساخت فایل‌های پروژه
    echo "Creating project files..."
    
    # ---------- config.json ----------
    cat > config.json << EOF
{
  "bot_token": "$BOT_TOKEN",
  "admin_id": $ADMIN_ID,
  "download_path": "downloads",
  "max_file_size": 50,
  "default_check_interval": 6,
  "max_accounts_per_user": 10,
  "cleanup_interval": 86400,
  "languages": ["fa", "en"]
}
EOF
    
    # ---------- telegram_instabot.py ----------
    cat > telegram_instabot.py << 'PYCODE'
#!/usr/bin/env python3
import os, json, asyncio, re, shutil, hashlib, time, threading, logging
from pathlib import Path
from datetime import datetime, timedelta
from typing import Dict, List, Optional, Tuple
import instaloader
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup, InputFile
from telegram.ext import (
    ApplicationBuilder, CommandHandler, CallbackQueryHandler,
    MessageHandler, ContextTypes, filters, ConversationHandler
)
from telegram.constants import ParseMode
from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.interval import IntervalTrigger
from concurrent.futures import ThreadPoolExecutor

# ========== تنظیمات لاگ ==========
logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    level=logging.INFO,
    handlers=[
        logging.FileHandler('bot.log', encoding='utf-8'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

# ========== مسیرها ==========
BASE = Path(__file__).parent
DOWNLOADS = BASE / "downloads"
CONFIG = BASE / "config.json"
USERS = BASE / "users.json"
ACCOUNTS = BASE / "accounts.json"
STATE = BASE / "state.json"
LOG_PATH = BASE / "logs"
SESSION = BASE / "session"

# ایجاد دایرکتوری‌ها
DOWNLOADS.mkdir(exist_ok=True)
LOG_PATH.mkdir(exist_ok=True)

# ========== لود کانفیگ ==========
if not CONFIG.exists():
    logger.error("config.json not found")
    exit(1)

cfg = json.loads(CONFIG.read_text())
BOT_TOKEN = cfg["bot_token"]
ADMIN_ID = str(cfg["admin_id"])
MAX_FILE_SIZE = cfg.get("max_file_size", 50)  # MB
DEFAULT_CHECK_INTERVAL = cfg.get("default_check_interval", 6)  # hours
MAX_ACCOUNTS_PER_USER = cfg.get("max_accounts_per_user", 10)
CLEANUP_INTERVAL = cfg.get("cleanup_interval", 86400)  # seconds

# ========== لود داده‌ها ==========
def load_json_file(file_path: Path, default: dict = {}) -> dict:
    """لود فایل JSON"""
    try:
        if file_path.exists():
            return json.loads(file_path.read_text(encoding='utf-8'))
    except Exception as e:
        logger.error(f"Error loading {file_path}: {e}")
    return default

def save_json_file(file_path: Path, data: dict):
    """ذخیره فایل JSON"""
    try:
        file_path.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding='utf-8')
    except Exception as e:
        logger.error(f"Error saving {file_path}: {e}")

users = load_json_file(USERS, {})
accounts = load_json_file(ACCOUNTS, {})
state = load_json_file(STATE, {})

def save_all():
    """ذخیره تمام داده‌ها"""
    save_json_file(USERS, users)
    save_json_file(ACCOUNTS, accounts)
    save_json_file(STATE, state)

# ========== سیستم دو زبانه ==========
MESSAGES = {
    "fa": {
        "welcome": "👋 سلام {name}! خوش آمدید به ربات دانلودر اینستاگرام.",
        "start_menu": "🎯 لطفا یک گزینه را انتخاب کنید:",
        "add_account": "➕ افزودن حساب اینستاگرام",
        "manual_download": "🔗 دانلود دستی با لینک",
        "scheduled_download": "⏰ دانلود زمان‌بندی شده",
        "my_accounts": "👤 حساب‌های من",
        "settings": "⚙️ تنظیمات",
        "admin_panel": "🛠️ پنل ادمین",
        "back": "🔙 برگشت",
        "help": "❓ راهنما",
        "account_added": "✅ حساب @{username} با موفقیت اضافه شد.\n\n📊 تنظیمات:\n⏰ بازه بررسی: هر {interval} ساعت",
        "enter_username": "لطفا یوزرنیم اینستاگرام را ارسال کنید (بدون @):",
        "enter_interval": "بازه بررسی را به ساعت وارد کنید (مثال: 6):",
        "invalid_interval": "⚠️ بازه وارد شده نامعتبر است. لطفا عدد وارد کنید (حداقل 1 ساعت):",
        "max_accounts": "⚠️ شما به حداکثر تعداد حساب ({max}) رسیده‌اید.",
        "enter_link": "🔗 لطفا لینک پست، استوری یا ریلز اینستاگرام را ارسال کنید:",
        "downloading": "⏳ در حال دانلود...",
        "download_success": "✅ دانلود با موفقیت انجام شد!",
        "download_error": "❌ خطا در دانلود: {error}",
        "no_new_content": "🔄 محتوای جدیدی یافت نشد.",
        "checking_accounts": "🔍 در حال بررسی حساب‌ها...",
        "new_post_found": "📸 پست جدید از @{username}\n📅 تاریخ: {date}\n📝 {caption}",
        "new_story_found": "📱 استوری جدید از @{username}\n📅 تاریخ: {date}",
        "new_reel_found": "🎬 ریلز جدید از @{username}\n📅 تاریخ: {date}\n📝 {caption}",
        "schedule_set": "⏰ زمان‌بندی برای حساب @{username} تنظیم شد.\n🔄 بررسی هر {interval} ساعت",
        "user_blocked": "🚫 کاربر مسدود شد.",
        "user_unblocked": "✅ کاربر از مسدودیت خارج شد.",
        "admin_only": "❌ این دستور فقط برای ادمین‌ها قابل استفاده است.",
        "upload_session": "📤 لطفا فایل session اینستاگرام را ارسال کنید:",
        "session_loaded": "✅ session اینستاگرام با موفقیت بارگذاری شد.",
        "session_error": "❌ خطا در بارگذاری session.",
        "cleanup_started": "🧹 در حال پاک‌سازی فایل‌های قدیمی...",
        "cleanup_completed": "✅ پاک‌سازی کامل شد. {count} فایل حذف شد.",
        "stats": "📊 آمار ربات:\n👥 کاربران: {users}\n📱 حساب‌های فعال: {accounts}\n🗄️ فایل‌ها: {files}",
        "restarting": "🔄 در حال ری‌استارت ربات...",
        "language_set": "✅ زبان به فارسی تغییر کرد.",
        "interval_set": "✅ بازه بررسی به {interval} ساعت تغییر کرد."
    },
    "en": {
        "welcome": "👋 Hello {name}! Welcome to Instagram Downloader Bot.",
        "start_menu": "🎯 Please choose an option:",
        "add_account": "➕ Add Instagram Account",
        "manual_download": "🔗 Manual Download by Link",
        "scheduled_download": "⏰ Scheduled Download",
        "my_accounts": "👤 My Accounts",
        "settings": "⚙️ Settings",
        "admin_panel": "🛠️ Admin Panel",
        "back": "🔙 Back",
        "help": "❓ Help",
        "account_added": "✅ Account @{username} added successfully.\n\n📊 Settings:\n⏰ Check interval: every {interval} hours",
        "enter_username": "Please send Instagram username (without @):",
        "enter_interval": "Enter check interval in hours (example: 6):",
        "invalid_interval": "⚠️ Invalid interval. Please enter a number (minimum 1 hour):",
        "max_accounts": "⚠️ You have reached maximum accounts limit ({max}).",
        "enter_link": "🔗 Please send Instagram post, story or reel link:",
        "downloading": "⏳ Downloading...",
        "download_success": "✅ Download completed successfully!",
        "download_error": "❌ Download error: {error}",
        "no_new_content": "🔄 No new content found.",
        "checking_accounts": "🔍 Checking accounts...",
        "new_post_found": "📸 New post from @{username}\n📅 Date: {date}\n📝 {caption}",
        "new_story_found": "📱 New story from @{username}\n📅 Date: {date}",
        "new_reel_found": "🎬 New reel from @{username}\n📅 Date: {date}\n📝 {caption}",
        "schedule_set": "⏰ Schedule set for account @{username}.\n🔄 Checking every {interval} hours",
        "user_blocked": "🚫 User blocked.",
        "user_unblocked": "✅ User unblocked.",
        "admin_only": "❌ This command is for admins only.",
        "upload_session": "📤 Please send Instagram session file:",
        "session_loaded": "✅ Instagram session loaded successfully.",
        "session_error": "❌ Error loading session.",
        "cleanup_started": "🧹 Cleaning up old files...",
        "cleanup_completed": "✅ Cleanup completed. {count} files removed.",
        "stats": "📊 Bot statistics:\n👥 Users: {users}\n📱 Active accounts: {accounts}\n🗄️ Files: {files}",
        "restarting": "🔄 Restarting bot...",
        "language_set": "✅ Language changed to English.",
        "interval_set": "✅ Check interval changed to {interval} hours."
    }
}

def get_message(key: str, lang: str = "fa", **kwargs) -> str:
    """دریافت پیام بر اساس زبان"""
    lang = lang if lang in ["fa", "en"] else "fa"
    msg = MESSAGES[lang].get(key, key)
    return msg.format(**kwargs) if kwargs else msg

# ========== Instagram Loader ==========
class InstagramDownloader:
    def __init__(self):
        self.L = instaloader.Instaloader(
            save_metadata=False,
            download_comments=False,
            download_videos=True,
            download_pictures=True,
            download_video_thumbnails=False,
            download_geotags=False,
            post_metadata_txt_pattern="",
            dirname_pattern=str(DOWNLOADS / "{target}"),
            quiet=True,
            user_agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        )
        self.load_session()
    
    def load_session(self):
        """لود session اینستاگرام"""
        if SESSION.exists():
            try:
                self.L.load_session_from_file(filename=str(SESSION))
                logger.info("Instagram session loaded")
            except Exception as e:
                logger.error(f"Error loading session: {e}")
    
    def save_session(self, session_file_path: str):
        """ذخیره session اینستاگرام"""
        try:
            shutil.copy(session_file_path, str(SESSION))
            self.load_session()
            return True
        except Exception as e:
            logger.error(f"Error saving session: {e}")
            return False
    
    def download_post(self, shortcode: str, target: str = "temp") -> List[str]:
        """دانلود پست"""
        try:
            post = instaloader.Post.from_shortcode(self.L.context, shortcode)
            self.L.download_post(post, target=target)
            return self.get_downloaded_files(target)
        except Exception as e:
            logger.error(f"Error downloading post: {e}")
            return []
    
    def download_story(self, username: str, target: str = "temp") -> List[str]:
        """دانلود استوری"""
        try:
            if not self.L.context.is_logged_in:
                return []
            
            profile = instaloader.Profile.from_username(self.L.context, username)
            stories = instaloader.get_stories([profile.userid], self.L.context)
            
            downloaded_files = []
            for story in stories:
                for item in story.get_items():
                    self.L.download_storyitem(item, target=target)
                    downloaded_files.extend(self.get_downloaded_files(target))
            return downloaded_files
        except Exception as e:
            logger.error(f"Error downloading story: {e}")
            return []
    
    def download_profile_posts(self, username: str, target: str = "temp", limit: int = 5) -> List[str]:
        """دانلود پست‌های پروفایل"""
        try:
            profile = instaloader.Profile.from_username(self.L.context, username)
            downloaded_files = []
            
            for i, post in enumerate(profile.get_posts()):
                if i >= limit:
                    break
                self.L.download_post(post, target=target)
                downloaded_files.extend(self.get_downloaded_files(target))
            
            return downloaded_files
        except Exception as e:
            logger.error(f"Error downloading profile posts: {e}")
            return []
    
    def get_downloaded_files(self, target: str) -> List[str]:
        """دریافت لیست فایل‌های دانلود شده"""
        files = []
        target_dir = DOWNLOADS / target
        
        if target_dir.exists():
            for file_path in target_dir.rglob("*"):
                if file_path.is_file() and not file_path.name.endswith('.json'):
                    files.append(str(file_path))
        
        return files
    
    def cleanup_target(self, target: str):
        """پاک‌سازی فایل‌های دانلود شده"""
        target_dir = DOWNLOADS / target
        if target_dir.exists():
            shutil.rmtree(target_dir)

downloader = InstagramDownloader()

# ========== مدیریت کاربران ==========
def ensure_user(uid: str):
    """اطمینان از وجود کاربر"""
    if uid not in users:
        users[uid] = {
            "id": uid,
            "username": "",
            "first_name": "",
            "last_name": "",
            "language": "fa",
            "role": "admin" if uid == ADMIN_ID else "user",
            "blocked": False,
            "created_at": datetime.now().isoformat(),
            "last_activity": datetime.now().isoformat(),
            "accounts": [],
            "check_interval": DEFAULT_CHECK_INTERVAL
        }
        save_all()

def update_user_activity(uid: str):
    """بروزرسانی زمان فعالیت کاربر"""
    if uid in users:
        users[uid]["last_activity"] = datetime.now().isoformat()
        save_all()

def is_admin(uid: str) -> bool:
    """بررسی ادمین بودن"""
    return users.get(uid, {}).get("role") == "admin"

def is_blocked(uid: str) -> bool:
    """بررسی مسدود بودن"""
    return users.get(uid, {}).get("blocked", False)

def add_account_to_user(uid: str, username: str, interval: int = None) -> bool:
    """افزودن حساب به کاربر"""
    ensure_user(uid)
    
    # بررسی حداکثر تعداد حساب
    if len(users[uid]["accounts"]) >= MAX_ACCOUNTS_PER_USER:
        return False
    
    if interval is None:
        interval = users[uid].get("check_interval", DEFAULT_CHECK_INTERVAL)
    
    account_id = f"{uid}_{username}"
    
    accounts[account_id] = {
        "id": account_id,
        "user_id": uid,
        "username": username.lower(),
        "interval": interval,
        "last_check": None,
        "last_post_id": None,
        "last_story_id": None,
        "last_reel_id": None,
        "active": True,
        "created_at": datetime.now().isoformat()
    }
    
    if username.lower() not in users[uid]["accounts"]:
        users[uid]["accounts"].append(username.lower())
    
    save_all()
    return True

# ========== زمان‌بندی ==========
class SchedulerManager:
    def __init__(self, app):
        self.app = app
        self.scheduler = BackgroundScheduler()
        self.executor = ThreadPoolExecutor(max_workers=5)
        self.setup_scheduler()
    
    def setup_scheduler(self):
        """تنظیم زمان‌بندی"""
        # زمان‌بندی بررسی حساب‌ها
        self.scheduler.add_job(
            self.check_all_accounts,
            'interval',
            hours=1,
            id='check_accounts'
        )
        
        # زمان‌بندی پاک‌سازی
        self.scheduler.add_job(
            self.cleanup_old_files,
            'interval',
            seconds=CLEANUP_INTERVAL,
            id='cleanup_files'
        )
        
        self.scheduler.start()
        logger.info("Scheduler started")
    
    def check_all_accounts(self):
        """بررسی تمام حساب‌ها"""
        logger.info("Checking all accounts...")
        
        for account_id, account_data in list(accounts.items()):
            if not account_data.get("active", True):
                continue
            
            last_check = account_data.get("last_check")
            if last_check:
                last_check_dt = datetime.fromisoformat(last_check)
                interval_hours = account_data.get("interval", DEFAULT_CHECK_INTERVAL)
                if (datetime.now() - last_check_dt) < timedelta(hours=interval_hours):
                    continue
            
            # بررسی در thread جداگانه
            self.executor.submit(self.check_single_account, account_id, account_data)
    
    def check_single_account(self, account_id: str, account_data: dict):
        """بررسی یک حساب"""
        try:
            uid = account_data["user_id"]
            username = account_data["username"]
            
            # بروزرسانی زمان آخرین بررسی
            accounts[account_id]["last_check"] = datetime.now().isoformat()
            
            # بررسی پست‌های جدید
            self.check_new_posts(uid, username, account_data)
            
            # بررسی استوری‌های جدید (اگر session وجود دارد)
            if downloader.L.context.is_logged_in:
                self.check_new_stories(uid, username, account_data)
            
            save_all()
            
        except Exception as e:
            logger.error(f"Error checking account {account_id}: {e}")
    
    def check_new_posts(self, uid: str, username: str, account_data: dict):
        """بررسی پست‌های جدید"""
        try:
            profile = instaloader.Profile.from_username(downloader.L.context, username)
            last_post_id = account_data.get("last_post_id")
            new_posts = []
            
            for post in profile.get_posts():
                if last_post_id and post.shortcode == last_post_id:
                    break
                new_posts.append(post)
            
            if new_posts:
                # ذخیره آخرین پست
                accounts[f"{uid}_{username}"]["last_post_id"] = new_posts[0].shortcode
                
                # ارسال پست‌های جدید (از قدیمی به جدید)
                for post in reversed(new_posts):
                    asyncio.run_coroutine_threadsafe(
                        self.send_new_content(uid, username, "post", post),
                        self.app.loop
                    )
            
        except Exception as e:
            logger.error(f"Error checking posts for {username}: {e}")
    
    def check_new_stories(self, uid: str, username: str, account_data: dict):
        """بررسی استوری‌های جدید"""
        try:
            profile = instaloader.Profile.from_username(downloader.L.context, username)
            last_story_id = account_data.get("last_story_id")
            
            stories = instaloader.get_stories([profile.userid], downloader.L.context)
            
            for story in stories:
                for item in story.get_items():
                    if last_story_id and item.mediaid == last_story_id:
                        continue
                    
                    # ذخیره آخرین استوری
                    accounts[f"{uid}_{username}"]["last_story_id"] = item.mediaid
                    
                    # ارسال استوری جدید
                    asyncio.run_coroutine_threadsafe(
                        self.send_new_content(uid, username, "story", item),
                        self.app.loop
                    )
                    break  # فقط اولین استوری جدید
                break
            
        except Exception as e:
            logger.error(f"Error checking stories for {username}: {e}")
    
    async def send_new_content(self, uid: str, username: str, content_type: str, content):
        """ارسال محتوای جدید به کاربر"""
        try:
            user_lang = users.get(uid, {}).get("language", "fa")
            
            if content_type == "post":
                caption = get_message("new_post_found", user_lang,
                    username=username,
                    date=content.date_local.strftime("%Y-%m-%d %H:%M"),
                    caption=content.caption[:100] + "..." if content.caption and len(content.caption) > 100 else (content.caption or "")
                )
                
                # دانلود و ارسال
                files = downloader.download_post(content.shortcode, f"{uid}_{username}")
                await self.send_files(uid, files, caption)
                
                # پاک‌سازی
                downloader.cleanup_target(f"{uid}_{username}")
            
            elif content_type == "story" and downloader.L.context.is_logged_in:
                caption = get_message("new_story_found", user_lang,
                    username=username,
                    date=content.date_local.strftime("%Y-%m-%d %H:%M")
                )
                
                # دانلود و ارسال
                files = downloader.download_story(username, f"{uid}_{username}_story")
                await self.send_files(uid, files, caption)
                
                # پاک‌سازی
                downloader.cleanup_target(f"{uid}_{username}_story")
        
        except Exception as e:
            logger.error(f"Error sending new content: {e}")
    
    async def send_files(self, uid: str, files: List[str], caption: str):
        """ارسال فایل‌ها به کاربر"""
        try:
            for file_path in files:
                if os.path.getsize(file_path) > MAX_FILE_SIZE * 1024 * 1024:
                    logger.warning(f"File too large: {file_path}")
                    continue
                
                with open(file_path, 'rb') as f:
                    if file_path.endswith(('.mp4', '.avi', '.mov', '.mkv')):
                        await self.app.bot.send_video(
                            chat_id=uid,
                            video=InputFile(f),
                            caption=caption[:1024] if caption else None
                        )
                    elif file_path.endswith(('.jpg', '.jpeg', '.png', '.gif')):
                        await self.app.bot.send_photo(
                            chat_id=uid,
                            photo=InputFile(f),
                            caption=caption[:1024] if caption else None
                        )
                    
                # حذف فایل از سرور
                os.remove(file_path)
        
        except Exception as e:
            logger.error(f"Error sending files: {e}")
    
    def cleanup_old_files(self):
        """پاک‌سازی فایل‌های قدیمی"""
        try:
            count = 0
            cutoff_time = datetime.now() - timedelta(hours=24)
            
            for item in DOWNLOADS.iterdir():
                if item.is_dir():
                    # حذف دایرکتوری‌های قدیمی
                    try:
                        if datetime.fromtimestamp(item.stat().st_mtime) < cutoff_time:
                            shutil.rmtree(item)
                            count += 1
                    except:
                        pass
            
            logger.info(f"Cleanup completed: {count} directories removed")
            
        except Exception as e:
            logger.error(f"Error in cleanup: {e}")
    
    def stop(self):
        """توقف زمان‌بندی"""
        self.scheduler.shutdown()
        self.executor.shutdown()
        logger.info("Scheduler stopped")

# ========== دستورات بات ==========
async def start_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """دستور /start"""
    uid = str(update.effective_user.id)
    ensure_user(uid)
    
    if is_blocked(uid):
        return
    
    # ذخیره اطلاعات کاربر
    user = update.effective_user
    users[uid]["username"] = user.username or ""
    users[uid]["first_name"] = user.first_name or ""
    users[uid]["last_name"] = user.last_name or ""
    update_user_activity(uid)
    
    user_lang = users[uid]["language"]
    
    # پیام خوش‌آمدگویی
    welcome_msg = get_message("welcome", user_lang, name=user.first_name or user.username or "کاربر")
    menu_msg = get_message("start_menu", user_lang)
    
    # ایجاد منو
    keyboard = [
        [InlineKeyboardButton(get_message("add_account", user_lang), callback_data="add_account")],
        [InlineKeyboardButton(get_message("manual_download", user_lang), callback_data="manual_download")],
        [InlineKeyboardButton(get_message("scheduled_download", user_lang), callback_data="scheduled_download")],
        [InlineKeyboardButton(get_message("my_accounts", user_lang), callback_data="my_accounts")],
        [InlineKeyboardButton(get_message("settings", user_lang), callback_data="settings")]
    ]
    
    if is_admin(uid):
        keyboard.append([InlineKeyboardButton(get_message("admin_panel", user_lang), callback_data="admin_panel")])
    
    keyboard.append([InlineKeyboardButton(get_message("help", user_lang), callback_data="help")])
    
    reply_markup = InlineKeyboardMarkup(keyboard)
    
    await update.message.reply_text(
        f"{welcome_msg}\n\n{menu_msg}",
        reply_markup=reply_markup,
        parse_mode=ParseMode.HTML
    )

async def help_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """دستور /help"""
    uid = str(update.effective_user.id)
    user_lang = users.get(uid, {}).get("language", "fa")
    
    help_text = """
📚 **راهنمای ربات** 📚

🔗 **دانلود دستی:**
ارسال لینک پست، استوری یا ریلز اینستاگرام

➕ **افزودن حساب:**
برای دانلود خودکار محتوای جدید

⏰ **زمان‌بندی:**
ربات به طور خودکار محتوای جدید را بررسی و دانلود می‌کند

⚙️ **تنظیمات:**
تغییر زبان و بازه زمانی بررسی

🛠️ **پنل ادمین:**
مدیریت کاربران و session اینستاگرام

📤 **ارسال session:**
برای دانلود استوری‌ها نیاز به session دارید

⚠️ **نکات:**
- حداکثر {max_accounts} حساب برای هر کاربر
- حداکثر حجم فایل: {max_size}MB
- فایل‌ها پس از ارسال از سرور حذف می‌شوند
""".format(
        max_accounts=MAX_ACCOUNTS_PER_USER,
        max_size=MAX_FILE_SIZE
    )
    
    if user_lang == "en":
        help_text = """
📚 **Bot Guide** 📚

🔗 **Manual Download:**
Send Instagram post, story, or reel link

➕ **Add Account:**
For automatic download of new content

⏰ **Scheduling:**
Bot automatically checks and downloads new content

⚙️ **Settings:**
Change language and check interval

🛠️ **Admin Panel:**
Manage users and Instagram session

📤 **Send Session:**
Need session for downloading stories

⚠️ **Notes:**
- Maximum {max_accounts} accounts per user
- Maximum file size: {max_size}MB
- Files are deleted from server after sending
""".format(
            max_accounts=MAX_ACCOUNTS_PER_USER,
            max_size=MAX_FILE_SIZE
        )
    
    await update.message.reply_text(help_text, parse_mode=ParseMode.MARKDOWN)

async def status_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """دستور /status - فقط برای ادمین"""
    uid = str(update.effective_user.id)
    
    if not is_admin(uid):
        await update.message.reply_text(get_message("admin_only", users.get(uid, {}).get("language", "fa")))
        return
    
    stats_msg = get_message("stats", "fa",
        users=len(users),
        accounts=len(accounts),
        files=sum(len(list((DOWNLOADS / d).rglob("*"))) for d in DOWNLOADS.iterdir() if (DOWNLOADS / d).is_dir())
    )
    
    await update.message.reply_text(stats_msg)

async def restart_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """دستور /restart - فقط برای ادمین"""
    uid = str(update.effective_user.id)
    
    if not is_admin(uid):
        await update.message.reply_text(get_message("admin_only", users.get(uid, {}).get("language", "fa")))
        return
    
    await update.message.reply_text(get_message("restarting", users.get(uid, {}).get("language", "fa")))
    
    # ری‌استارت
    os.execl(sys.executable, sys.executable, *sys.argv)

async def callback_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """مدیریت callback queries"""
    query = update.callback_query
    await query.answer()
    
    uid = str(query.from_user.id)
    ensure_user(uid)
    
    if is_blocked(uid):
        return
    
    update_user_activity(uid)
    user_lang = users[uid]["language"]
    data = query.data
    
    # دکمه برگشت
    if data == "back":
        await start_from_callback(query, context)
        return
    
    # منوهای اصلی
    if data == "add_account":
        context.user_data[f"{uid}_action"] = "waiting_username"
        await query.edit_message_text(get_message("enter_username", user_lang))
    
    elif data == "manual_download":
        context.user_data[f"{uid}_action"] = "waiting_link"
        await query.edit_message_text(get_message("enter_link", user_lang),
            reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton(get_message("back", user_lang), callback_data="back")]]))
    
    elif data == "scheduled_download":
        await show_scheduled_menu(query, context)
    
    elif data == "my_accounts":
        await show_my_accounts(query, context)
    
    elif data == "settings":
        await show_settings(query, context)
    
    elif data == "admin_panel" and is_admin(uid):
        await show_admin_panel(query, context)
    
    elif data == "help":
        await help_callback(query, context)

async def start_from_callback(query, context):
    """شروع از callback"""
    uid = str(query.from_user.id)
    user = query.from_user
    user_lang = users.get(uid, {}).get("language", "fa")
    
    welcome_msg = get_message("welcome", user_lang, name=user.first_name or user.username or "کاربر")
    menu_msg = get_message("start_menu", user_lang)
    
    keyboard = [
        [InlineKeyboardButton(get_message("add_account", user_lang), callback_data="add_account")],
        [InlineKeyboardButton(get_message("manual_download", user_lang), callback_data="manual_download")],
        [InlineKeyboardButton(get_message("scheduled_download", user_lang), callback_data="scheduled_download")],
        [InlineKeyboardButton(get_message("my_accounts", user_lang), callback_data="my_accounts")],
        [InlineKeyboardButton(get_message("settings", user_lang), callback_data="settings")]
    ]
    
    if is_admin(uid):
        keyboard.append([InlineKeyboardButton(get_message("admin_panel", user_lang), callback_data="admin_panel")])
    
    keyboard.append([InlineKeyboardButton(get_message("help", user_lang), callback_data="help")])
    
    reply_markup = InlineKeyboardMarkup(keyboard)
    
    await query.edit_message_text(
        f"{welcome_msg}\n\n{menu_msg}",
        reply_markup=reply_markup
    )

async def show_scheduled_menu(query, context):
    """نمایش منوی زمان‌بندی"""
    uid = str(query.from_user.id)
    user_lang = users[uid]["language"]
    
    keyboard = [
        [InlineKeyboardButton("➕ افزودن حساب جدید", callback_data="add_account")],
        [InlineKeyboardButton("📋 لیست حساب‌های من", callback_data="list_accounts")],
        [InlineKeyboardButton("⚙️ تغییر بازه بررسی", callback_data="change_interval")],
        [InlineKeyboardButton("🔄 بررسی دستی حساب‌ها", callback_data="manual_check")],
        [InlineKeyboardButton(get_message("back", user_lang), callback_data="back")]
    ]
    
    reply_markup = InlineKeyboardMarkup(keyboard)
    
    await query.edit_message_text(
        "⏰ **مدیریت دانلود زمان‌بندی شده**\n\n"
        "در این بخش می‌توانید حساب‌های اینستاگرام را برای دانلود خودکار اضافه کنید.",
        reply_markup=reply_markup,
        parse_mode=ParseMode.MARKDOWN
    )

async def show_my_accounts(query, context):
    """نمایش حساب‌های کاربر"""
    uid = str(query.from_user.id)
    user_lang = users[uid]["language"]
    
    user_accounts = [acc for acc_id, acc in accounts.items() if acc["user_id"] == uid and acc["active"]]
    
    if not user_accounts:
        text = "📭 هیچ حسابی اضافه نکرده‌اید."
    else:
        text = "📋 **حساب‌های شما:**\n\n"
        for i, acc in enumerate(user_accounts, 1):
            last_check = acc.get("last_check")
            last_check_str = datetime.fromisoformat(last_check).strftime("%Y-%m-%d %H:%M") if last_check else "هرگز"
            
            text += f"{i}. @{acc['username']}\n"
            text += f"   ⏰ بازه: هر {acc['interval']} ساعت\n"
            text += f"   🔍 آخرین بررسی: {last_check_str}\n"
            text += f"   📤 آخرین پست: {acc.get('last_post_id', 'ندارد')}\n\n"
    
    keyboard = [[InlineKeyboardButton(get_message("back", user_lang), callback_data="back")]]
    reply_markup = InlineKeyboardMarkup(keyboard)
    
    await query.edit_message_text(text, reply_markup=reply_markup, parse_mode=ParseMode.MARKDOWN)

async def show_settings(query, context):
    """نمایش تنظیمات"""
    uid = str(query.from_user.id)
    user_lang = users[uid]["language"]
    
    settings_text = f"""
⚙️ **تنظیمات کاربری**

🌐 زبان: {'فارسی' if user_lang == 'fa' else 'انگلیسی'}
⏰ بازه پیش‌فرض بررسی: {users[uid].get('check_interval', DEFAULT_CHECK_INTERVAL)} ساعت
📊 تعداد حساب‌ها: {len(users[uid].get('accounts', []))}/{MAX_ACCOUNTS_PER_USER}
📅 تاریخ عضویت: {datetime.fromisoformat(users[uid]['created_at']).strftime('%Y-%m-%d')}
    """
    
    keyboard = [
        [InlineKeyboardButton("🌐 تغییر زبان", callback_data="change_language")],
        [InlineKeyboardButton("⏰ تغییر بازه بررسی", callback_data="change_interval")],
        [InlineKeyboardButton(get_message("back", user_lang), callback_data="back")]
    ]
    
    reply_markup = InlineKeyboardMarkup(keyboard)
    
    await query.edit_message_text(settings_text, reply_markup=reply_markup, parse_mode=ParseMode.MARKDOWN)

async def show_admin_panel(query, context):
    """نمایش پنل ادمین"""
    uid = str(query.from_user.id)
    
    if not is_admin(uid):
        return
    
    stats_text = get_message("stats", "fa",
        users=len(users),
        accounts=len([a for a in accounts.values() if a["active"]]),
        files=sum(len(list((DOWNLOADS / d).rglob("*"))) for d in DOWNLOADS.iterdir() if (DOWNLOADS / d).is_dir())
    )
    
    keyboard = [
        [InlineKeyboardButton("👥 مدیریت کاربران", callback_data="manage_users")],
        [InlineKeyboardButton("📤 آپلود Session", callback_data="upload_session_admin")],
        [InlineKeyboardButton("🧹 پاک‌سازی فایل‌ها", callback_data="cleanup_files")],
        [InlineKeyboardButton("📊 آمار کامل", callback_data="full_stats")],
        [InlineKeyboardButton(get_message("back", "fa"), callback_data="back")]
    ]
    
    reply_markup = InlineKeyboardMarkup(keyboard)
    
    await query.edit_message_text(
        f"🛠️ **پنل مدیریت ادمین**\n\n{stats_text}",
        reply_markup=reply_markup,
        parse_mode=ParseMode.MARKDOWN
    )

async def help_callback(query, context):
    """کمک در callback"""
    uid = str(query.from_user.id)
    user_lang = users[uid]["language"]
    
    help_text = get_message("help", user_lang)
    
    keyboard = [[InlineKeyboardButton(get_message("back", user_lang), callback_data="back")]]
    reply_markup = InlineKeyboardMarkup(keyboard)
    
    await query.edit_message_text(help_text, reply_markup=reply_markup, parse_mode=ParseMode.MARKDOWN)

async def message_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """مدیریت پیام‌های متنی"""
    uid = str(update.effective_user.id)
    ensure_user(uid)
    
    if is_blocked(uid):
        return
    
    update_user_activity(uid)
    user_lang = users[uid]["language"]
    text = update.message.text.strip()
    
    action = context.user_data.get(f"{uid}_action")
    
    if action == "waiting_username":
        # افزودن حساب جدید
        username = text.replace("@", "").strip().lower()
        
        if len(users[uid]["accounts"]) >= MAX_ACCOUNTS_PER_USER:
            await update.message.reply_text(
                get_message("max_accounts", user_lang, max=MAX_ACCOUNTS_PER_USER),
                reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton(get_message("back", user_lang), callback_data="back")]])
            )
            return
        
        context.user_data[f"{uid}_action"] = "waiting_interval"
        context.user_data[f"{uid}_username"] = username
        
        await update.message.reply_text(
            get_message("enter_interval", user_lang),
            reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("6 ساعت", callback_data="interval_6"),
                                               InlineKeyboardButton("12 ساعت", callback_data="interval_12"),
                                               InlineKeyboardButton("24 ساعت", callback_data="interval_24")]])
        )
    
    elif action == "waiting_interval":
        # تنظیم بازه زمانی
        try:
            interval = int(text)
            if interval < 1:
                raise ValueError
        except:
            await update.message.reply_text(get_message("invalid_interval", user_lang))
            return
        
        username = context.user_data.get(f"{uid}_username")
        if username and add_account_to_user(uid, username, interval):
            context.user_data[f"{uid}_action"] = None
            context.user_data[f"{uid}_username"] = None
            
            await update.message.reply_text(
                get_message("account_added", user_lang, username=username, interval=interval),
                reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton(get_message("back", user_lang), callback_data="back")]])
            )
        else:
            await update.message.reply_text("❌ خطا در افزودن حساب")
    
    elif action == "waiting_link":
        # دانلود دستی با لینک
        context.user_data[f"{uid}_action"] = None
        
        processing_msg = await update.message.reply_text(get_message("downloading", user_lang))
        
        try:
            # استخراج shortcode از لینک
            if "/p/" in text or "/reel/" in text:
                shortcode = text.rstrip("/").split("/")[-1]
                files = downloader.download_post(shortcode, f"manual_{uid}")
                
                if files:
                    for file_path in files:
                        with open(file_path, 'rb') as f:
                            if file_path.endswith(('.mp4', '.avi', '.mov', '.mkv')):
                                await update.message.reply_video(
                                    video=InputFile(f),
                                    caption=f"📥 دانلود دستی\n🔗 {text}"
                                )
                            elif file_path.endswith(('.jpg', '.jpeg', '.png', '.gif')):
                                await update.message.reply_photo(
                                    photo=InputFile(f),
                                    caption=f"📥 دانلود دستی\n🔗 {text}"
                                )
                        
                        # حذف فایل از سرور
                        os.remove(file_path)
                    
                    await processing_msg.edit_text(get_message("download_success", user_lang))
                else:
                    await processing_msg.edit_text(get_message("no_new_content", user_lang))
            
            elif "/stories/" in text:
                if not downloader.L.context.is_logged_in:
                    await processing_msg.edit_text("❌ برای دانلود استوری نیاز به session دارید.")
                    return
                
                username = text.split("/stories/")[1].split("/")[0]
                files = downloader.download_story(username, f"manual_{uid}_story")
                
                if files:
                    for file_path in files:
                        with open(file_path, 'rb') as f:
                            if file_path.endswith(('.mp4', '.avi', '.mov', '.mkv')):
                                await update.message.reply_video(video=InputFile(f))
                            elif file_path.endswith(('.jpg', '.jpeg', '.png', '.gif')):
                                await update.message.reply_photo(photo=InputFile(f))
                        
                        os.remove(file_path)
                    
                    await processing_msg.edit_text(get_message("download_success", user_lang))
                else:
                    await processing_msg.edit_text("❌ استوری فعالی یافت نشد.")
            
            else:
                await processing_msg.edit_text("❌ لینک نامعتبر است.")
        
        except Exception as e:
            logger.error(f"Download error: {e}")
            await processing_msg.edit_text(get_message("download_error", user_lang, error=str(e)))
    
    else:
        # پاسخ به پیام‌های معمولی
        await update.message.reply_text(
            "لطفا از منوی بات استفاده کنید:",
            reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("📋 منو", callback_data="back")]])
        )

async def document_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """مدیریت فایل‌های ارسالی (session)"""
    uid = str(update.effective_user.id)
    
    if not is_admin(uid):
        return
    
    document = update.message.document
    if not document:
        return
    
    file_name = document.file_name
    if not file_name or not file_name.startswith("session-"):
        await update.message.reply_text("❌ نام فایل session نامعتبر است.")
        return
    
    # دانلود فایل
    file = await document.get_file()
    temp_path = f"/tmp/{file_name}"
    await file.download_to_drive(temp_path)
    
    # ذخیره session
    if downloader.save_session(temp_path):
        await update.message.reply_text(get_message("session_loaded", users.get(uid, {}).get("language", "fa")))
    else:
        await update.message.reply_text(get_message("session_error", users.get(uid, {}).get("language", "fa")))
    
    # حذف فایل موقت
    os.remove(temp_path)

async def error_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """مدیریت خطاها"""
    logger.error(f"Update {update} caused error {context.error}")
    
    if update and update.effective_user:
        uid = str(update.effective_user.id)
        user_lang = users.get(uid, {}).get("language", "fa")
        
        try:
            await context.bot.send_message(
                chat_id=uid,
                text="❌ خطایی در پردازش درخواست شما رخ داد. لطفا دوباره تلاش کنید."
            )
        except:
            pass

# ========== main ==========
def main():
    """تابع اصلی"""
    logger.info("Starting Instagram Telegram Bot...")
    
    # ساخت اپلیکیشن
    app = ApplicationBuilder().token(BOT_TOKEN).build()
    
    # اضافه کردن handlers
    app.add_handler(CommandHandler("start", start_command))
    app.add_handler(CommandHandler("help", help_command))
    app.add_handler(CommandHandler("status", status_command))
    app.add_handler(CommandHandler("restart", restart_command))
    
    app.add_handler(CallbackQueryHandler(callback_handler))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, message_handler))
    app.add_handler(MessageHandler(filters.Document.ALL, document_handler))
    
    app.add_error_handler(error_handler)
    
    # شروع زمان‌بندی
    scheduler = SchedulerManager(app)
    
    try:
        logger.info("Bot is running...")
        app.run_polling(allowed_updates=Update.ALL_TYPES)
    except KeyboardInterrupt:
        logger.info("Bot stopped by user")
    except Exception as e:
        logger.error(f"Fatal error: {e}")
    finally:
        scheduler.stop()
        logger.info("Bot shutdown complete")

if __name__ == "__main__":
    import sys
    main()
PYCODE

    # ---------- requirements.txt ----------
    cat > requirements.txt << EOF
python-telegram-bot==20.3
instaloader==4.11
apscheduler==3.10.1
requests==2.31.0
pillow==10.0.0
EOF

    echo "Installing Python packages..."
    python3 -m venv venv
    source venv/bin/activate
    pip install --upgrade pip
    pip install -r requirements.txt

    # ---------- systemd service ----------
    sudo tee /etc/systemd/system/$SERVICE.service > /dev/null <<EOF
[Unit]
Description=Telegram Instagram Bot
Description=ربات دانلودر اینستاگرام تلگرام
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$PROJECT
Environment="PATH=$PROJECT/venv/bin"
ExecStart=$PROJECT/venv/bin/python telegram_instabot.py
Restart=always
RestartSec=10
StandardOutput=append:$PROJECT/bot.log
StandardError=append:$PROJECT/bot.log

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable $SERVICE
    sudo systemctl start $SERVICE

    echo ""
    echo "✅ Bot installed and running successfully!"
    echo ""
    echo "📝 دستورات مدیریت:"
    echo "   sudo systemctl start $SERVICE      # شروع بات"
    echo "   sudo systemctl stop $SERVICE       # توقف بات"
    echo "   sudo systemctl restart $SERVICE    # ری‌استارت بات"
    echo "   sudo systemctl status $SERVICE     # وضعیت بات"
    echo "   sudo journalctl -u $SERVICE -f    # مشاهده لاگ‌ها"
    echo ""
    echo "🔧 تنظیمات اضافه:"
    echo "1. برای دانلود استوری‌ها، session اینستاگرام را از پنل ادمین آپلود کنید"
    echo "2. تنظیمات پیشرفته در فایل config.json قابل تغییر است"
    echo ""

elif [ "$C" == "2" ]; then
    echo "Removing bot completely..."
    sudo systemctl stop $SERVICE || true
    sudo systemctl disable $SERVICE || true
    sudo rm -f /etc/systemd/system/$SERVICE.service
    sudo systemctl daemon-reload
    sudo systemctl reset-failed
    rm -rf "$PROJECT"
    echo "✅ Bot removed completely!"

elif [ "$C" == "3" ]; then
    sudo systemctl start $SERVICE
    echo "✅ Bot started!"

elif [ "$C" == "4" ]; then
    sudo systemctl restart $SERVICE
    echo "✅ Bot restarted!"

elif [ "$C" == "5" ]; then
    sudo systemctl status $SERVICE

elif [ "$C" == "6" ]; then
    if [ -f "$PROJECT/bot.log" ]; then
        tail -50 "$PROJECT/bot.log"
    else
        echo "Log file not found!"
    fi

else
    echo "❌ Invalid option!"
fi
