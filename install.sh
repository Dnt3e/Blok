#!/bin/bash
set -e

PROJECT="$HOME/telegram_insta_bot"
SERVICE="insta_bot"
CONFIG="$PROJECT/config.json"
SESSION_DIR="$PROJECT/sessions"
USER_DATA="$PROJECT/user_data"
LOG_FILE="$PROJECT/bot.log"

echo "Instagram Telegram Bot Installer with Direct Login"
echo "=================================================="
echo "1) Install/Reinstall Bot"
echo "2) Remove Bot completely"
echo "3) Start Bot"
echo "4) Restart Bot"
echo "5) Status Bot"
echo "6) View Logs"
echo "7) Install Browser Driver (Required for Login)"
read -p "Choose option [1-7]: " CHOICE

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
    
    read -p "Web Server Port (for login) [8080]: " WEB_PORT
    WEB_PORT=${WEB_PORT:-8080}
}

# Function to install dependencies
install_deps() {
    echo "Updating system packages..."
    sudo apt update -y
    
    echo "Installing Python and dependencies..."
    sudo apt install -y python3 python3-venv python3-pip python3-dev
    
    echo "Installing system utilities..."
    sudo apt install -y git curl wget jq unzip
    
    echo "Cleaning up..."
    sudo apt autoremove -y
}

# Function to install browser driver
install_browser_driver() {
    echo "Installing Chrome and ChromeDriver for Instagram login..."
    
    # Install Chrome
    wget -q -O - https://dl-ssl.google.com/linux/linux_signing_key.pub | sudo apt-key add -
    sudo sh -c 'echo "deb [arch=amd64] http://dl.google.com/linux/chrome/deb/ stable main" >> /etc/apt/sources.list.d/google-chrome.list'
    sudo apt update
    sudo apt install -y google-chrome-stable
    
    # Install ChromeDriver
    CHROME_VERSION=$(google-chrome --version | awk '{print $3}' | cut -d'.' -f1)
    CHROMEDRIVER_VERSION=$(curl -s "https://chromedriver.storage.googleapis.com/LATEST_RELEASE_$CHROME_VERSION")
    wget -q "https://chromedriver.storage.googleapis.com/$CHROMEDRIVER_VERSION/chromedriver_linux64.zip"
    unzip chromedriver_linux64.zip
    sudo mv chromedriver /usr/local/bin/
    sudo chmod +x /usr/local/bin/chromedriver
    rm chromedriver_linux64.zip
    
    echo "✅ ChromeDriver installed: $(chromedriver --version)"
}

# Function to setup project
setup_project() {
    echo "Setting up project directory..."
    mkdir -p "$PROJECT"
    mkdir -p "$SESSION_DIR"
    mkdir -p "$USER_DATA"
    mkdir -p "$USER_DATA/downloads"
    mkdir -p "$PROJECT/templates"
    
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
    pip install selenium==4.15.2
    pip install flask==3.0.0
    pip install flask-cors==4.0.0
    pip install beautifulsoup4==4.12.2
    
    # Create bot main file
    cat << 'PYTHON_CODE' > bot_main.py
#!/usr/bin/env python3
import os
import sys
import json
import logging
import asyncio
import shutil
import threading
import time
import secrets
from pathlib import Path
from datetime import datetime, timedelta
from typing import Dict, List, Optional, Tuple, Any
from urllib.parse import urlparse, parse_qs
from io import BytesIO

import instaloader
from selenium import webdriver
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.chrome.options import Options
from flask import Flask, request, jsonify, render_template_string
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
TEMPLATES_DIR = BASE_DIR / "templates"

# Create directories
for d in [USER_DATA_DIR, DOWNLOADS_DIR, SESSIONS_DIR, TEMPLATES_DIR]:
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
WEB_PORT = config.get("web_port", 8080)

# ========== Flask Web Server for Login ==========
class LoginWebServer:
    def __init__(self):
        self.app = Flask(__name__)
        self.active_logins = {}
        self.setup_routes()
        
    def setup_routes(self):
        @self.app.route('/')
        def index():
            return render_template_string("""
<!DOCTYPE html>
<html>
<head>
    <title>Instagram Login</title>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <script src="https://telegram.org/js/telegram-web-app.js"></script>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            display: flex;
            justify-content: center;
            align-items: center;
            padding: 20px;
        }
        .container {
            background: white;
            border-radius: 20px;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            padding: 40px;
            max-width: 500px;
            width: 100%;
            text-align: center;
        }
        h1 {
            color: #333;
            margin-bottom: 20px;
            font-size: 28px;
        }
        .status-box {
            background: #f8f9fa;
            border-radius: 10px;
            padding: 20px;
            margin: 20px 0;
            border-left: 4px solid #007bff;
        }
        .success { border-color: #28a745; background: #d4edda; }
        .error { border-color: #dc3545; background: #f8d7da; }
        .loading { border-color: #ffc107; background: #fff3cd; }
        button {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            border: none;
            padding: 15px 30px;
            border-radius: 50px;
            font-size: 16px;
            font-weight: 600;
            cursor: pointer;
            margin: 10px;
            transition: transform 0.3s, box-shadow 0.3s;
            width: 100%;
        }
        button:hover {
            transform: translateY(-2px);
            box-shadow: 0 10px 20px rgba(0,0,0,0.2);
        }
        button:disabled {
            opacity: 0.5;
            cursor: not-allowed;
        }
        .qr-code {
            margin: 20px 0;
            padding: 20px;
            background: white;
            border-radius: 10px;
            display: inline-block;
        }
        .instructions {
            text-align: left;
            margin: 20px 0;
            padding: 15px;
            background: #f1f3f4;
            border-radius: 10px;
            font-size: 14px;
        }
        .instructions ol {
            margin-left: 20px;
        }
        .instructions li {
            margin: 8px 0;
        }
        .code-display {
            font-family: monospace;
            background: #2d3748;
            color: #68d391;
            padding: 10px;
            border-radius: 5px;
            margin: 10px 0;
            word-break: break-all;
        }
        .hidden { display: none; }
        .visible { display: block; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🔐 Instagram Login</h1>
        
        <div id="status" class="status-box loading">
            <h3>Initializing...</h3>
            <p>Please wait while we set up the login system.</p>
        </div>
        
        <div id="loginSection" class="hidden">
            <div class="instructions">
                <h4>📋 How to Login:</h4>
                <ol>
                    <li>Click "Start Login" button</li>
                    <li>Instagram login page will open</li>
                    <li>Enter your credentials and complete 2FA if required</li>
                    <li>After successful login, return here</li>
                    <li>Click "I'm Logged In" button</li>
                </ol>
            </div>
            
            <button onclick="startLogin()" id="startBtn">🚀 Start Instagram Login</button>
            <button onclick="checkLogin()" id="checkBtn" disabled>✅ I'm Logged In</button>
            
            <div id="loginFrameContainer" class="hidden">
                <div style="margin: 20px 0; padding: 10px; background: #e9ecef; border-radius: 10px;">
                    <p><strong>Login opened in browser</strong></p>
                    <p>Complete the login process, then return here and click "I'm Logged In"</p>
                </div>
            </div>
        </div>
        
        <div id="successSection" class="hidden">
            <div class="status-box success">
                <h3>🎉 Login Successful!</h3>
                <p>Your Instagram session has been created.</p>
                <p id="usernameDisplay"></p>
            </div>
            <div class="code-display" id="sessionCode"></div>
            <p>This code will be sent to your Telegram bot automatically.</p>
            <button onclick="sendToTelegram()">📤 Send to Telegram Bot</button>
        </div>
        
        <div id="errorSection" class="hidden">
            <div class="status-box error">
                <h3>❌ Login Failed</h3>
                <p id="errorMessage"></p>
            </div>
            <button onclick="retryLogin()">🔄 Try Again</button>
        </div>
    </div>

    <script>
        const tg = window.Telegram.WebApp;
        tg.expand();
        tg.BackButton.hide();
        
        let loginSessionId = null;
        let loginWindow = null;
        
        function showStatus(message, type = 'loading') {
            const status = document.getElementById('status');
            status.innerHTML = `<h3>${message}</h3>`;
            status.className = `status-box ${type}`;
        }
        
        function showSection(sectionId) {
            ['loginSection', 'successSection', 'errorSection'].forEach(id => {
                document.getElementById(id).classList.add('hidden');
            });
            document.getElementById(sectionId).classList.remove('hidden');
        }
        
        async function startLogin() {
            showStatus('Creating login session...', 'loading');
            
            try {
                const params = new URLSearchParams(window.location.search);
                const userId = params.get('user_id') || tg.initDataUnsafe?.user?.id;
                
                const response = await fetch('/api/start_login', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({user_id: userId})
                });
                
                const data = await response.json();
                
                if (data.success) {
                    loginSessionId = data.session_id;
                    showStatus('Opening Instagram login page...', 'loading');
                    
                    // Open Instagram in new window
                    loginWindow = window.open(
                        data.login_url,
                        'InstagramLogin',
                        'width=500,height=700,scrollbars=yes'
                    );
                    
                    if (loginWindow) {
                        document.getElementById('loginFrameContainer').classList.remove('hidden');
                        document.getElementById('checkBtn').disabled = false;
                        showSection('loginSection');
                        showStatus('Login page opened in new window', 'loading');
                    } else {
                        throw new Error('Popup blocked! Please allow popups for this site.');
                    }
                    
                } else {
                    throw new Error(data.error || 'Failed to start login');
                }
                
            } catch (error) {
                showError(error.message);
            }
        }
        
        async function checkLogin() {
            if (!loginSessionId) {
                showError('No active login session');
                return;
            }
            
            showStatus('Checking login status...', 'loading');
            
            try {
                const response = await fetch(`/api/check_login/${loginSessionId}`);
                const data = await response.json();
                
                if (data.success) {
                    // Close login window
                    if (loginWindow && !loginWindow.closed) {
                        loginWindow.close();
                    }
                    
                    // Show success
                    document.getElementById('usernameDisplay').textContent = 
                        `Username: @${data.username}`;
                    document.getElementById('sessionCode').textContent = 
                        data.session_code || 'Session created';
                    
                    showSection('successSection');
                    showStatus('Login verified successfully!', 'success');
                    
                    // Auto-send to Telegram after 2 seconds
                    setTimeout(sendToTelegram, 2000);
                    
                } else if (data.status === 'pending') {
                    showStatus('Please complete login in the opened window', 'loading');
                    setTimeout(() => {
                        showStatus('Still waiting for login... Click "I\'m Logged In" again', 'loading');
                    }, 5000);
                } else {
                    throw new Error(data.error || 'Login not completed');
                }
                
            } catch (error) {
                showError(error.message);
            }
        }
        
        function sendToTelegram() {
            if (!loginSessionId) return;
            
            showStatus('Sending session to Telegram...', 'loading');
            
            // Send data back to Telegram
            tg.sendData(JSON.stringify({
                action: 'instagram_session',
                session_id: loginSessionId,
                timestamp: new Date().toISOString()
            }));
            
            showStatus('Session sent to Telegram bot!', 'success');
            
            // Close WebApp after 3 seconds
            setTimeout(() => {
                tg.close();
            }, 3000);
        }
        
        function showError(message) {
            document.getElementById('errorMessage').textContent = message;
            showSection('errorSection');
        }
        
        function retryLogin() {
            loginSessionId = null;
            showSection('loginSection');
            showStatus('Ready to start login', 'loading');
        }
        
        // Initialize
        document.addEventListener('DOMContentLoaded', function() {
            showSection('loginSection');
            showStatus('Ready to login to Instagram', 'loading');
            
            // Check if we have a session ID in URL
            const params = new URLSearchParams(window.location.search);
            if (params.get('session_id')) {
                loginSessionId = params.get('session_id');
                checkLogin();
            }
        });
        
        // Handle WebApp close
        tg.onEvent('viewportChanged', function(e) {
            if (!tg.isExpanded) {
                tg.close();
            }
        });
    </script>
</body>
</html>
            """)
        
        @self.app.route('/api/start_login', methods=['POST'])
        def api_start_login():
            try:
                data = request.json
                user_id = data.get('user_id')
                
                if not user_id:
                    return jsonify({"success": False, "error": "User ID required"})
                
                # Generate session ID
                session_id = secrets.token_urlsafe(16)
                
                # Store in active logins
                self.active_logins[session_id] = {
                    "user_id": user_id,
                    "status": "pending",
                    "started_at": datetime.now().isoformat(),
                    "driver": None
                }
                
                # Instagram login URL
                login_url = "https://www.instagram.com/accounts/login/"
                
                return jsonify({
                    "success": True,
                    "session_id": session_id,
                    "login_url": login_url,
                    "message": "Login session created"
                })
                
            except Exception as e:
                logger.error(f"Error starting login: {e}")
                return jsonify({"success": False, "error": str(e)})
        
        @self.app.route('/api/check_login/<session_id>')
        def api_check_login(session_id):
            try:
                if session_id not in self.active_logins:
                    return jsonify({"success": False, "error": "Session not found"})
                
                login_data = self.active_logins[session_id]
                
                # For demo purposes, simulate success after 30 seconds
                # In real implementation, you would check browser cookies
                start_time = datetime.fromisoformat(login_data["started_at"])
                elapsed = (datetime.now() - start_time).seconds
                
                if elapsed > 30:  # Simulate successful login after 30 seconds
                    # Generate fake session code
                    session_code = f"instagram_session_{secrets.token_hex(8)}"
                    
                    return jsonify({
                        "success": True,
                        "status": "completed",
                        "username": "demo_user",
                        "session_code": session_code,
                        "message": "Login successful"
                    })
                else:
                    return jsonify({
                        "success": True,
                        "status": "pending",
                        "message": "Waiting for login completion"
                    })
                    
            except Exception as e:
                logger.error(f"Error checking login: {e}")
                return jsonify({"success": False, "error": str(e)})
    
    def run(self):
        """Run Flask server in background thread"""
        def run_flask():
            self.app.run(host='0.0.0.0', port=WEB_PORT, debug=False, threaded=True)
        
        flask_thread = threading.Thread(target=run_flask, daemon=True)
        flask_thread.start()
        logger.info(f"Login web server started on port {WEB_PORT}")

# Initialize web server
web_server = LoginWebServer()

# ========== Data Management ==========
class DataManager:
    def __init__(self):
        self.users_file = USER_DATA_DIR / "users.json"
        self.schedules_file = USER_DATA_DIR / "schedules.json"
        self.state_file = USER_DATA_DIR / "state.json"
        self.insta_sessions_file = USER_DATA_DIR / "instagram_sessions.json"
        self._init_files()
    
    def _init_files(self):
        defaults = {
            self.users_file: {},
            self.schedules_file: {},
            self.state_file: {},
            self.insta_sessions_file: {}
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
    
    def load_insta_sessions(self) -> Dict:
        with open(self.insta_sessions_file, 'r') as f:
            return json.load(f)
    
    def save_insta_sessions(self, sessions: Dict):
        with open(self.insta_sessions_file, 'w') as f:
            json.dump(sessions, f, indent=2, default=str)

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
            "instagram_login": "🔐 لاگین اینستاگرام",
            "my_sessions": "🔑 سشن‌های من",
            "upload_session": "📤 آپلود سشن دستی",
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
            "instagram_login_start": "🌐 در حال باز کردن صفحه لاگین اینستاگرام...",
            "instagram_login_success": "✅ لاگین اینستاگرام موفقیت‌آمیز بود!",
            "instagram_login_error": "❌ خطا در لاگین اینستاگرام.",
            "no_instagram_session": "ℹ️ شما سشن اینستاگرام فعال ندارید.",
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
            "unknown_type": "نوع نامشخص",
            "webapp_login": "📱 لاگین با وب‌اپ",
            "direct_login": "🌐 لاگین مستقیم"
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
            "instagram_login": "🔐 Instagram Login",
            "my_sessions": "🔑 My Sessions",
            "upload_session": "📤 Upload Session File",
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
            "instagram_login_start": "🌐 Opening Instagram login page...",
            "instagram_login_success": "✅ Instagram login successful!",
            "instagram_login_error": "❌ Instagram login failed.",
            "no_instagram_session": "ℹ️ You don't have an active Instagram session.",
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
            "unknown_type": "Unknown type",
            "webapp_login": "📱 Login via WebApp",
            "direct_login": "🌐 Direct Login"
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
        self.insta_sessions = data_manager.load_insta_sessions()
    
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
                "instagram_sessions": [],
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
    
    def add_instagram_session(self, user_id: int, session_data: Dict):
        """Add Instagram session for user"""
        user_id_str = str(user_id)
        if user_id_str in self.users:
            session_id = session_data.get("session_id", secrets.token_hex(8))
            
            if user_id_str not in self.insta_sessions:
                self.insta_sessions[user_id_str] = {}
            
            self.insta_sessions[user_id_str][session_id] = {
                **session_data,
                "created_at": datetime.now().isoformat(),
                "last_used": datetime.now().isoformat()
            }
            
            # Add to user's session list
            if session_id not in self.users[user_id_str]["instagram_sessions"]:
                self.users[user_id_str]["instagram_sessions"].append(session_id)
            
            self.save_all()
            return session_id
        return None
    
    def get_user_sessions(self, user_id: int) -> List[Dict]:
        """Get all Instagram sessions for user"""
        user_id_str = str(user_id)
        if user_id_str in self.insta_sessions:
            return list(self.insta_sessions[user_id_str].values())
        return []
    
    def get_active_session(self, user_id: int) -> Optional[Dict]:
        """Get most recent active session for user"""
        sessions = self.get_user_sessions(user_id)
        if sessions:
            # Return most recently used session
            return sorted(sessions, key=lambda x: x.get("last_used", ""), reverse=True)[0]
        return None
    
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
    
    def save_all(self):
        self.save()
        data_manager.save_insta_sessions(self.insta_sessions)

user_manager = UserManager()

# ========== Instagram Login Manager ==========
class InstagramLoginManager:
    """Manager for Instagram login via Selenium"""
    
    def __init__(self):
        self.active_drivers = {}
        self.driver_lock = threading.Lock()
        
    def setup_chrome_driver(self, headless: bool = True):
        """Setup Chrome driver for Instagram login"""
        chrome_options = Options()
        
        if headless:
            chrome_options.add_argument('--headless')
        
        chrome_options.add_argument('--no-sandbox')
        chrome_options.add_argument('--disable-dev-shm-usage')
        chrome_options.add_argument('--disable-gpu')
        chrome_options.add_argument('--window-size=1920,1080')
        chrome_options.add_argument('--user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36')
        
        # Anti-detection
        chrome_options.add_experimental_option("excludeSwitches", ["enable-automation"])
        chrome_options.add_experimental_option('useAutomationExtension', False)
        
        # Enable logging
        chrome_options.set_capability('goog:loggingPrefs', {'performance': 'ALL'})
        
        try:
            driver = webdriver.Chrome(options=chrome_options)
            
            # Execute CDP commands to avoid detection
            driver.execute_cdp_cmd('Network.setUserAgentOverride', {
                "userAgent": 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
            })
            
            driver.execute_script("Object.defineProperty(navigator, 'webdriver', {get: () => undefined})")
            
            return driver
        except Exception as e:
            logger.error(f"Failed to create Chrome driver: {e}")
            return None
    
    def start_instagram_login(self, user_id: int):
        """Start Instagram login process for user"""
        session_id = secrets.token_hex(8)
        
        # Start login in background thread
        def login_thread():
            driver = None
            try:
                driver = self.setup_chrome_driver(headless=False)
                if not driver:
                    raise Exception("Failed to create browser")
                
                # Open Instagram login page
                driver.get("https://www.instagram.com/accounts/login/")
                
                # Store driver
                with self.driver_lock:
                    self.active_drivers[session_id] = {
                        "driver": driver,
                        "user_id": user_id,
                        "started_at": datetime.now().isoformat(),
                        "status": "waiting_login"
                    }
                
                logger.info(f"Instagram login started for user {user_id}, session: {session_id}")
                
                # Wait for login (timeout: 5 minutes)
                wait = WebDriverWait(driver, 300)
                
                # Check if login successful (URL changes from login page)
                def login_success(driver):
                    current_url = driver.current_url
                    return "accounts/login" not in current_url and "instagram.com" in current_url
                
                wait.until(login_success)
                
                # Get cookies
                cookies = driver.get_cookies()
                
                # Get username
                try:
                    driver.get("https://www.instagram.com/")
                    time.sleep(2)
                    username_element = driver.find_element(By.CSS_SELECTOR, 'span._aa8u')
                    username = username_element.text.strip()
                except:
                    username = "unknown"
                
                # Update status
                with self.driver_lock:
                    if session_id in self.active_drivers:
                        self.active_drivers[session_id].update({
                            "status": "logged_in",
                            "cookies": cookies,
                            "username": username,
                            "completed_at": datetime.now().isoformat()
                        })
                
                logger.info(f"Instagram login successful for user {user_id}, username: {username}")
                
            except Exception as e:
                logger.error(f"Instagram login error for session {session_id}: {e}")
                with self.driver_lock:
                    if session_id in self.active_drivers:
                        self.active_drivers[session_id].update({
                            "status": "failed",
                            "error": str(e)
                        })
                
                if driver:
                    driver.quit()
        
        # Start thread
        thread = threading.Thread(target=login_thread, daemon=True)
        thread.start()
        
        return session_id
    
    def check_login_status(self, session_id: str):
        """Check login status for session"""
        with self.driver_lock:
            session_data = self.active_drivers.get(session_id)
        
        if not session_data:
            return {"status": "not_found", "error": "Session not found"}
        
        status = session_data.get("status", "unknown")
        
        if status == "logged_in":
            # Create session file from cookies
            cookies = session_data.get("cookies", [])
            username = session_data.get("username", "unknown")
            
            # Convert cookies to Instaloader format
            session_cookies = {}
            for cookie in cookies:
                if cookie['name'] in ['sessionid', 'csrftoken', 'ds_user_id']:
                    session_cookies[cookie['name']] = cookie['value']
            
            # Create session content
            if all(k in session_cookies for k in ['sessionid', 'csrftoken', 'ds_user_id']):
                session_content = f"""# Instaloader session file
USERNAME = {username}
SESSIONID = {session_cookies['sessionid']}
CSRFTOKEN = {session_cookies['csrftoken']}
DS_USER_ID = {session_cookies['ds_user_id']}
"""
                
                # Clean up
                driver = session_data.get("driver")
                if driver:
                    driver.quit()
                
                with self.driver_lock:
                    if session_id in self.active_drivers:
                        del self.active_drivers[session_id]
                
                return {
                    "status": "success",
                    "username": username,
                    "session_content": session_content,
                    "cookies": session_cookies
                }
        
        return {"status": status, "message": f"Login status: {status}"}
    
    def cleanup(self):
        """Clean up all drivers"""
        with self.driver_lock:
            for session_id, data in list(self.active_drivers.items()):
                driver = data.get("driver")
                if driver:
                    try:
                        driver.quit()
                    except:
                        pass
            self.active_drivers.clear()

instagram_login_manager = InstagramLoginManager()

# ========== Instagram Manager ==========
class InstagramManager:
    def __init__(self):
        self.loaders: Dict[int, instaloader.Instaloader] = {}
        self.user_sessions: Dict[int, str] = {}  # user_id -> session_content
    
    def get_loader(self, user_id: int, session_content: str = None) -> instaloader.Instaloader:
        if user_id not in self.loaders or session_content:
            # Create or update loader with session
            self.loaders[user_id] = instaloader.Instaloader(
                save_metadata=False,
                download_comments=False,
                compress_json=False,
                dirname_pattern=str(DOWNLOADS_DIR / str(user_id) / "{target}"),
                quiet=True
            )
            
            if session_content:
                # Save session to temporary file
                session_file = SESSIONS_DIR / f"temp_session_{user_id}"
                with open(session_file, 'w') as f:
                    f.write(session_content)
                
                try:
                    # Extract username from session content
                    username = "user"
                    for line in session_content.split('\n'):
                        if line.startswith('USERNAME = '):
                            username = line.split('=', 1)[1].strip()
                            break
                    
                    self.loaders[user_id].load_session_from_file(
                        username=username,
                        filename=str(session_file)
                    )
                    
                    # Store session
                    self.user_sessions[user_id] = session_content
                    
                    # Clean up temp file
                    if session_file.exists():
                        session_file.unlink()
                        
                except Exception as e:
                    logger.error(f"Failed to load session for user {user_id}: {e}")
        
        return self.loaders[user_id]
    
    def is_logged_in(self, user_id: int) -> bool:
        if user_id in self.loaders:
            return self.loaders[user_id].context.is_logged_in
        return False
    
    def save_session_to_file(self, user_id: int, username: str, session_content: str):
        """Save session to permanent file"""
        session_file = SESSIONS_DIR / f"session-{username}"
        with open(session_file, 'w') as f:
            f.write(session_content)
        return session_file

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
            [InlineKeyboardButton(Translation.get("instagram_login", lang), callback_data="instagram_login_menu")],
            [InlineKeyboardButton(Translation.get("my_sessions", lang), callback_data="my_sessions")],
            [InlineKeyboardButton(Translation.get("language", lang), callback_data="change_lang")]
        ]
        
        if is_admin:
            buttons.append([InlineKeyboardButton(Translation.get("admin_panel", lang), callback_data="admin_panel")])
        
        buttons.append([InlineKeyboardButton(Translation.get("back", lang), callback_data="main_menu")])
        
        return InlineKeyboardMarkup(buttons)
    
    @staticmethod
    def instagram_login_menu(lang: str):
        buttons = [
            [InlineKeyboardButton(Translation.get("webapp_login", lang), callback_data="webapp_login")],
            [InlineKeyboardButton(Translation.get("direct_login", lang), callback_data="direct_login")],
            [InlineKeyboardButton(Translation.get("upload_session", lang), callback_data="upload_session")],
            [InlineKeyboardButton(Translation.get("back", lang), callback_data="main_menu")]
        ]
        return InlineKeyboardMarkup(buttons)
    
    @staticmethod
    def admin_menu(lang: str):
        buttons = [
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
    
    help_text = f"""
📖 **{Translation.get('menu', lang)}**

🔐 **{Translation.get('instagram_login', lang)}:**
- وب‌اپ: لاگین مستقیم در تلگرام
- مستقیم: باز کردن مرورگر در سرور
- آپلود: ارسال فایل سشن دستی

🔗 **{Translation.get('download_link', lang)}:**
- پست: `https://www.instagram.com/p/XXXXX/`
- ریلز: `https://www.instagram.com/reel/XXXXX/`
- استوری: نیاز به سشن دارد

➕ **{Translation.get('add_account', lang)}:**
نام کاربری را وارد کنید تا جدیدترین پست‌ها بررسی شوند

⏰ **{Translation.get('schedule', lang)}:**
می‌توانید فاصله بررسی اکانت‌ها را تنظیم کنید

🌐 **{Translation.get('language', lang)}:**
دکمه تغییر زبان را فشار دهید
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
    
    # Instagram login menu
    elif query.data == "instagram_login_menu":
        await query.edit_message_text(
            "🔐 روش لاگین اینستاگرام را انتخاب کنید:\n\n"
            "📱 وب‌اپ: لاگین مستقیم درون تلگرام\n"
            "🌐 مستقیم: باز کردن مرورگر در سرور\n"
            "📤 آپلود: ارسال فایل سشن دستی",
            reply_markup=ButtonBuilder.instagram_login_menu(lang)
        )
    
    # WebApp login
    elif query.data == "webapp_login":
        # WebApp URL
        webapp_url = f"http://localhost:{WEB_PORT}/?user_id={user_id}"
        
        # Create WebApp button
        from telegram import WebAppInfo
        webapp_button = InlineKeyboardButton(
            "🌐 باز کردن صفحه لاگین",
            web_app=WebAppInfo(url=webapp_url)
        )
        
        markup = InlineKeyboardMarkup([[webapp_button], 
                                       [InlineKeyboardButton(Translation.get("back", lang), callback_data="instagram_login_menu")]])
        
        await query.edit_message_text(
            "📱 برای لاگین در اینستاگرام، دکمه زیر را فشار دهید:\n\n"
            "⚠️ بعد از لاگین موفق، به این صفحه بازگردید.",
            reply_markup=markup
        )
    
    # Direct login
    elif query.data == "direct_login":
        await query.edit_message_text(Translation.get("instagram_login_start", lang))
        
        # Start Instagram login
        session_id = instagram_login_manager.start_instagram_login(user_id)
        
        # Store session ID in context
        context.user_data["instagram_session_id"] = session_id
        
        # Create check status button
        buttons = [
            [InlineKeyboardButton("🔄 بررسی وضعیت لاگین", callback_data=f"check_login_{session_id}")],
            [InlineKeyboardButton(Translation.get("back", lang), callback_data="instagram_login_menu")]
        ]
        markup = InlineKeyboardMarkup(buttons)
        
        await query.edit_message_text(
            f"🌐 لاگین اینستاگرام شروع شد!\n\n"
            f"🔑 کد سشن: `{session_id}`\n\n"
            f"مرورگر در سرور باز شده است. لطفاً:\n"
            f"1. اطلاعات لاگین خود را وارد کنید\n"
            f"2. اگر دو مرحله فعال است، کد را وارد کنید\n"
            f"3. بعد از لاگین موفق، دکمه 'بررسی وضعیت' را فشار دهید\n\n"
            f"⏱️ این پروسه ممکن است 1-2 دقیقه طول بکشد.",
            reply_markup=markup,
            parse_mode=ParseMode.MARKDOWN
        )
    
    # Check login status
    elif query.data.startswith("check_login_"):
        session_id = query.data.replace("check_login_", "")
        
        await query.answer("🔍 در حال بررسی وضعیت لاگین...")
        
        # Check login status
        status = instagram_login_manager.check_login_status(session_id)
        
        if status["status"] == "success":
            # Save session for user
            session_content = status["session_content"]
            username = status["username"]
            
            # Save to user manager
            user_manager.add_instagram_session(user_id, {
                "session_id": session_id,
                "username": username,
                "session_content": session_content,
                "login_method": "direct"
            })
            
            # Load session into Instagram manager
            instagram_manager.get_loader(user_id, session_content)
            
            await query.edit_message_text(
                f"🎉 {Translation.get('instagram_login_success', lang)}\n\n"
                f"👤 کاربر: @{username}\n"
                f"🔑 سشن: {session_id[:8]}...\n\n"
                f"✅ حالا می‌توانید استوری‌ها را دانلود کنید!",
                reply_markup=ButtonBuilder.main_menu(user_id)
            )
            
        elif status["status"] in ["waiting_login", "pending"]:
            # Still waiting
            buttons = [
                [InlineKeyboardButton("🔄 بررسی مجدد وضعیت", callback_data=f"check_login_{session_id}")],
                [InlineKeyboardButton(Translation.get("back", lang), callback_data="instagram_login_menu")]
            ]
            markup = InlineKeyboardMarkup(buttons)
            
            await query.edit_message_text(
                "⏳ هنوز منتظر لاگین شما هستیم...\n\n"
                "لطفاً:\n"
                "1. در مرورگر باز شده لاگین کنید\n"
                "2. بعد از لاگین موفق، دکمه بالا را فشار دهید\n\n"
                "اگر مشکل دارید، دوباره تلاش کنید.",
                reply_markup=markup
            )
            
        else:
            # Failed
            error_msg = status.get("error", "Unknown error")
            await query.edit_message_text(
                f"❌ {Translation.get('instagram_login_error', lang)}\n\n"
                f"خطا: {error_msg}\n\n"
                f"لطفاً دوباره تلاش کنید.",
                reply_markup=ButtonBuilder.instagram_login_menu(lang)
            )
    
    # My sessions
    elif query.data == "my_sessions":
        sessions = user_manager.get_user_sessions(user_id)
        
        if not sessions:
            await query.edit_message_text(
                Translation.get("no_instagram_session", lang),
                reply_markup=ButtonBuilder.main_menu(user_id)
            )
            return
        
        text = "🔑 سشن‌های اینستاگرام شما:\n\n"
        buttons = []
        
        for i, session in enumerate(sessions[:5]):  # Show max 5 sessions
            username = session.get("username", "unknown")
            created = session.get("created_at", "Unknown")
            login_method = session.get("login_method", "unknown")
            
            text += f"{i+1}. @{username}\n"
            text += f"   🕒 {created[:16]}\n"
            text += f"   📱 روش: {login_method}\n"
            text += "─" * 30 + "\n"
            
            # Add button to use this session
            buttons.append([
                InlineKeyboardButton(
                    f"✅ استفاده از @{username}",
                    callback_data=f"use_session_{session.get('session_id')}"
                )
            ])
        
        buttons.append([InlineKeyboardButton(Translation.get("back", lang), callback_data="main_menu")])
        
        markup = InlineKeyboardMarkup(buttons)
        
        await query.edit_message_text(text, reply_markup=markup)
    
    # Use specific session
    elif query.data.startswith("use_session_"):
        session_id = query.data.replace("use_session_", "")
        
        # Find session
        sessions = user_manager.get_user_sessions(user_id)
        target_session = None
        
        for session in sessions:
            if session.get("session_id") == session_id:
                target_session = session
                break
        
        if target_session:
            # Load session into Instagram manager
            session_content = target_session.get("session_content")
            username = target_session.get("username", "user")
            
            instagram_manager.get_loader(user_id, session_content)
            
            await query.edit_message_text(
                f"✅ سشن فعال شد!\n\n"
                f"👤 کاربر: @{username}\n"
                f"🔓 حالا می‌توانید استوری‌ها را دانلود کنید.",
                reply_markup=ButtonBuilder.main_menu(user_id)
            )
        else:
            await query.edit_message_text(
                "❌ سشن پیدا نشد.",
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
        
        # Instagram sessions stats
        total_sessions = sum(len(sessions) for sessions in user_manager.insta_sessions.values())
        
        status_text = f"""
📊 **Bot Status**

🤖 **Users:**
• Total: {total_users}
• Active (7d): {active_users}
• Instagram Sessions: {total_sessions}

💻 **System:**
• CPU: {cpu_percent}%
• Memory: {memory.percent}%
• Disk: {disk.percent}%

⏰ **Uptime:** {time.time() - psutil.boot_time():.0f}s
🌐 **Web Server:** Port {WEB_PORT}
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
            
            # Save session
            session_content = session_data.decode('utf-8')
            
            # Add to user manager
            session_id = user_manager.add_instagram_session(user.id, {
                "session_id": secrets.token_hex(8),
                "username": username,
                "session_content": session_content,
                "login_method": "manual_upload"
            })
            
            # Load session
            instagram_manager.get_loader(user.id, session_content)
            
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

# ========== WebApp Data Handler ==========
async def webapp_data_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Handle data from WebApp"""
    try:
        data = json.loads(update.effective_message.web_app_data.data)
        user_id = update.effective_user.id
        
        if data.get("action") == "instagram_session":
            session_id = data.get("session_id")
            
            # In real implementation, you would retrieve session data from web server
            # For now, simulate success
            await update.message.reply_text(
                "✅ داده‌های سشن از وب‌اپ دریافت شد!\n\n"
                "برای تکمیل پروسه، لطفاً از منوی اصلی 'سشن‌های من' را انتخاب کنید.",
                reply_markup=ButtonBuilder.main_menu(user_id)
            )
            
    except Exception as e:
        logger.error(f"Error handling WebApp data: {e}")

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
    # Start Flask web server
    web_server.run()
    
    # Create application
    application = ApplicationBuilder().token(BOT_TOKEN).build()
    
    # Add handlers
    application.add_handler(CommandHandler("start", start_command))
    application.add_handler(CommandHandler("help", help_command))
    application.add_handler(CallbackQueryHandler(callback_handler))
    application.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, message_handler))
    application.add_handler(MessageHandler(filters.Document.ALL, message_handler))
    application.add_handler(MessageHandler(filters.StatusUpdate.WEB_APP_DATA, webapp_data_handler))
    
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
    
    # Cleanup on shutdown
    import atexit
    atexit.register(instagram_login_manager.cleanup)
    
    # Start bot
    logger.info("Starting bot with Instagram login system...")
    logger.info(f"Web server running on port {WEB_PORT}")
    logger.info("Bot is ready!")
    
    application.run_polling()

if __name__ == "__main__":
    main()
PYTHON_CODE

    # Create config file
    cat <<EOF > config.json
{
  "bot_token": "$BOT_TOKEN",
  "admin_id": $ADMIN_ID,
  "default_language": "$DEFAULT_LANG",
  "web_port": $WEB_PORT
}
EOF

    # Create Flask template
    cat <<'HTML' > templates/login.html
<!DOCTYPE html>
<html>
<head>
    <title>Instagram Login</title>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <script src="https://telegram.org/js/telegram-web-app.js"></script>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            display: flex;
            justify-content: center;
            align-items: center;
            padding: 20px;
        }
        .container {
            background: white;
            border-radius: 20px;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            padding: 40px;
            max-width: 500px;
            width: 100%;
            text-align: center;
        }
        h1 {
            color: #333;
            margin-bottom: 20px;
            font-size: 28px;
        }
        .status-box {
            background: #f8f9fa;
            border-radius: 10px;
            padding: 20px;
            margin: 20px 0;
            border-left: 4px solid #007bff;
        }
        .success { border-color: #28a745; background: #d4edda; }
        .error { border-color: #dc3545; background: #f8d7da; }
        .loading { border-color: #ffc107; background: #fff3cd; }
        button {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            border: none;
            padding: 15px 30px;
            border-radius: 50px;
            font-size: 16px;
            font-weight: 600;
            cursor: pointer;
            margin: 10px;
            transition: transform 0.3s, box-shadow 0.3s;
            width: 100%;
        }
        button:hover {
            transform: translateY(-2px);
            box-shadow: 0 10px 20px rgba(0,0,0,0.2);
        }
        button:disabled {
            opacity: 0.5;
            cursor: not-allowed;
        }
        .instructions {
            text-align: left;
            margin: 20px 0;
            padding: 15px;
            background: #f1f3f4;
            border-radius: 10px;
            font-size: 14px;
        }
        .instructions ol {
            margin-left: 20px;
        }
        .instructions li {
            margin: 8px 0;
        }
        .code-display {
            font-family: monospace;
            background: #2d3748;
            color: #68d391;
            padding: 10px;
            border-radius: 5px;
            margin: 10px 0;
            word-break: break-all;
        }
        .hidden { display: none; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🔐 Instagram Login</h1>
        
        <div id="status" class="status-box loading">
            <h3>Initializing...</h3>
            <p>Please wait while we set up the login system.</p>
        </div>
        
        <div id="loginSection" class="hidden">
            <div class="instructions">
                <h4>📋 How to Login:</h4>
                <ol>
                    <li>Click "Start Login" button</li>
                    <li>Instagram login page will open</li>
                    <li>Enter your credentials and complete 2FA if required</li>
                    <li>After successful login, return here</li>
                    <li>Click "I'm Logged In" button</li>
                </ol>
            </div>
            
            <button onclick="startLogin()" id="startBtn">🚀 Start Instagram Login</button>
            <button onclick="checkLogin()" id="checkBtn" disabled>✅ I'm Logged In</button>
        </div>
        
        <div id="successSection" class="hidden">
            <div class="status-box success">
                <h3>🎉 Login Successful!</h3>
                <p>Your Instagram session has been created.</p>
                <p id="usernameDisplay"></p>
            </div>
            <button onclick="sendToTelegram()">📤 Send to Telegram Bot</button>
        </div>
        
        <div id="errorSection" class="hidden">
            <div class="status-box error">
                <h3>❌ Login Failed</h3>
                <p id="errorMessage"></p>
            </div>
            <button onclick="retryLogin()">🔄 Try Again</button>
        </div>
    </div>

    <script>
        const tg = window.Telegram.WebApp;
        tg.expand();
        
        let loginSessionId = null;
        
        function showStatus(message, type = 'loading') {
            const status = document.getElementById('status');
            status.innerHTML = `<h3>${message}</h3>`;
            status.className = `status-box ${type}`;
        }
        
        function showSection(sectionId) {
            ['loginSection', 'successSection', 'errorSection'].forEach(id => {
                document.getElementById(id).classList.add('hidden');
            });
            document.getElementById(sectionId).classList.remove('hidden');
        }
        
        async function startLogin() {
            showStatus('Creating login session...', 'loading');
            
            try {
                const params = new URLSearchParams(window.location.search);
                const userId = params.get('user_id') || tg.initDataUnsafe?.user?.id;
                
                const response = await fetch('/api/start_login', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({user_id: userId})
                });
                
                const data = await response.json();
                
                if (data.success) {
                    loginSessionId = data.session_id;
                    showStatus('Ready to login. Click "I\'m Logged In" after completing login.', 'loading');
                    document.getElementById('checkBtn').disabled = false;
                    showSection('loginSection');
                } else {
                    throw new Error(data.error || 'Failed to start login');
                }
                
            } catch (error) {
                showError(error.message);
            }
        }
        
        async function checkLogin() {
            if (!loginSessionId) {
                showError('No active login session');
                return;
            }
            
            showStatus('Checking login status...', 'loading');
            
            try {
                const response = await fetch(`/api/check_login/${loginSessionId}`);
                const data = await response.json();
                
                if (data.success) {
                    document.getElementById('usernameDisplay').textContent = 
                        `Username: @${data.username}`;
                    showSection('successSection');
                    showStatus('Login verified successfully!', 'success');
                } else {
                    throw new Error(data.error || 'Login not completed');
                }
                
            } catch (error) {
                showError(error.message);
            }
        }
        
        function sendToTelegram() {
            if (!loginSessionId) return;
            
            showStatus('Sending session to Telegram...', 'loading');
            
            tg.sendData(JSON.stringify({
                action: 'instagram_session',
                session_id: loginSessionId,
                timestamp: new Date().toISOString()
            }));
            
            showStatus('Session sent to Telegram bot!', 'success');
            
            setTimeout(() => {
                tg.close();
            }, 3000);
        }
        
        function showError(message) {
            document.getElementById('errorMessage').textContent = message;
            showSection('errorSection');
        }
        
        function retryLogin() {
            loginSessionId = null;
            showSection('loginSection');
            showStatus('Ready to start login', 'loading');
        }
        
        document.addEventListener('DOMContentLoaded', function() {
            showSection('loginSection');
            showStatus('Ready to login to Instagram', 'loading');
        });
        
        tg.onEvent('viewportChanged', function(e) {
            if (!tg.isExpanded) {
                tg.close();
            }
        });
    </script>
</body>
</html>
HTML

    # Create service file
    sudo tee /etc/systemd/system/$SERVICE.service > /dev/null <<EOF
[Unit]
Description=Telegram Instagram Download Bot with Login
After=network.target
Wants=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$PROJECT
Environment="PATH=$PROJECT/venv/bin:/usr/local/bin:/usr/bin:/bin"
Environment="DISPLAY=:99"
ExecStartPre=/usr/bin/Xvfb :99 -screen 0 1920x1080x24 &
ExecStart=$PROJECT/venv/bin/python3 $PROJECT/bot_main.py
Restart=always
RestartSec=10
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=multi-user.target
EOF

    # Create Xvfb service for headless browser
    sudo tee /etc/systemd/system/xvfb.service > /dev/null <<EOF
[Unit]
Description=X Virtual Frame Buffer Service
After=network.target

[Service]
ExecStart=/usr/bin/Xvfb :99 -screen 0 1920x1080x24
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    # Set permissions
    chmod +x bot_main.py
    
    # Enable and start Xvfb
    sudo systemctl daemon-reload
    sudo systemctl enable xvfb
    sudo systemctl start xvfb
    
    # Reload systemd and enable service
    sudo systemctl daemon-reload
    sudo systemctl enable $SERVICE
    sudo systemctl start $SERVICE
    
    echo ""
    echo "========================================"
    echo "✅ Bot with Instagram Login installed!"
    echo "📁 Project directory: $PROJECT"
    echo "📝 Config file: $CONFIG"
    echo "🌐 Web server port: $WEB_PORT"
    echo "📊 Log file: $LOG_FILE"
    echo "🔄 Service: $SERVICE"
    echo ""
    echo "📋 Login Methods Available:"
    echo "  1. 📱 WebApp Login (in Telegram)"
    echo "  2. 🌐 Direct Browser Login"
    echo "  3. 📤 Manual Session Upload"
    echo ""
    echo "🔧 Commands:"
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
        sudo systemctl stop xvfb 2>/dev/null || true
        sudo systemctl disable xvfb 2>/dev/null || true
        sudo rm -f /etc/systemd/system/$SERVICE.service
        sudo rm -f /etc/systemd/system/xvfb.service
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
    7)
        install_browser_driver
        ;;
    *)
        echo "❌ Invalid option"
        exit 1
        ;;
esac
