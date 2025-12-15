#!/bin/bash

# =============================================
# Telegram Instagram Bot Installer - Full Version
# =============================================

set -e

PROJECT="$HOME/Blok"
SERVICE="insta_bot"

# Installer prompts (English)
echo "=== Telegram Instagram Bot Installer ==="
read -p "Telegram Bot Token: " BOT_TOKEN
read -p "Telegram Admin ID: " ADMIN_ID
read -p "Bot default language (fa/en): " BOT_LANG

# Install dependencies
sudo apt update
sudo apt install -y python3 python3-venv python3-pip

# Create project folder
mkdir -p "$PROJECT"
cd "$PROJECT"

# Create virtual environment
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install python-telegram-bot==22.3 instaloader apscheduler requests

# Config file
cat <<EOF > config.json
{
  "bot_token": "$BOT_TOKEN",
  "admin_id": $ADMIN_ID,
  "default_lang": "$BOT_LANG"
}
EOF

# Messages
dir_messages="$PROJECT/messages"
mkdir -p "$dir_messages"
cat <<EOL > $dir_messages/fa.json
{
"welcome": "سلام {name}! به ربات خوش آمدید.",
"add":"➕ افزودن اکانت",
"fetch":"⬇️ بررسی جدیدها",
"link":"🔗 دانلود با لینک",
"login_required":"❌ برای استوری باید session آپلود شود"
}
EOL

cat <<EOL > $dir_messages/en.json
{
"welcome": "Hello {name}! Welcome to the bot.",
"add":"➕ Add Account",
"fetch":"⬇️ Check New",
"link":"🔗 Download by Link",
"login_required":"❌ Instagram session required for stories"
}
EOL

# Bot file (bot.py)
cat <<'EOL' > $PROJECT/bot.py
import os, json, asyncio, instaloader
from pathlib import Path
from datetime import datetime
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup, InputFile
from telegram.ext import ApplicationBuilder, CommandHandler, CallbackQueryHandler, MessageHandler, ContextTypes, filters

BASE=Path(__file__).parent
DOWNLOADS=BASE/"downloads"
CONFIG=BASE/"config.json"
USERS=BASE/"users.json"
STATE=BASE/"state.json"
SESSION=BASE/"session"
DOWNLOADS.mkdir(exist_ok=True)
for f,d in [(USERS,{}),(STATE,{})]:
 if not f.exists(): f.write_text(json.dumps(d))
if not CONFIG.exists(): print("config.json not found"); exit(1)
cfg=json.loads(CONFIG.read_text())
BOT_TOKEN=cfg['bot_token']
ADMIN_ID=str(cfg['admin_id'])
users=json.loads(USERS.read_text())
state=json.loads(STATE.read_text())
L=instaloader.Instaloader(save_metadata=False, download_comments=False, dirname_pattern=str(DOWNLOADS/"{target}"))
if SESSION.exists():
 try: L.load_session_from_file(filename=str(SESSION))
 except: pass

def save():
 USERS.write_text(json.dumps(users, indent=2))
 STATE.write_text(json.dumps(state, indent=2))
def ensure(uid):
 if uid not in users:
  users[uid]={'role':'admin' if uid==ADMIN_ID else 'user','blocked':False,'accounts':[],'language':'en','interval':1}
  save()
def admin(uid): return users.get(uid,{}).get('role')=='admin'
def blocked(uid): return users.get(uid,{}).get('blocked',False)
async def send_file(p,chat,ctx):
 with open(p,'rb') as f: await ctx.bot.send_document(chat,f)
 os.remove(p)

# Load messages
dir_messages=BASE/"messages"
with open(dir_messages/(users.get('1',{}).get('language','en')+'.json'),'r',encoding='utf-8') as f: LANG=json.load(f)

def menu(is_admin=False, lang='en'):
 buttons=[[InlineKeyboardButton(LANG[lang]['add'],callback_data='add')],[InlineKeyboardButton(LANG[lang]['fetch'],callback_data='fetch')],[InlineKeyboardButton(LANG[lang]['link'],callback_data='link')]]
 if is_admin: buttons.append([InlineKeyboardButton('🔐 Upload IG Session',callback_data='upload_session')]); buttons.append([InlineKeyboardButton('👥 Users',callback_data='users')])
 return InlineKeyboardMarkup(buttons)

async def start(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
 uid=str(update.effective_user.id); ensure(uid)
 if blocked(uid): return
 lang=users[uid]['language']
 await update.message.reply_text(LANG[lang]['welcome'].replace('{name}',update.effective_user.full_name),reply_markup=menu(admin(uid),lang))

async def cb(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
 q=update.callback_query; await q.answer()
 uid=str(q.from_user.id); ensure(uid)
 if blocked(uid): return
 lang=users[uid]['language']
 if q.data=='add': ctx.user_data['await']='add'; await q.edit_message_text('Send Instagram username')
 elif q.data=='fetch': await q.edit_message_text('Checking...'); await fetch_all(uid,q.message.chat_id,ctx); await q.edit_message_text('Done',reply_markup=menu(admin(uid),lang))
 elif q.data=='link': ctx.user_data['await']='link'; await q.edit_message_text('Send link')
 elif q.data=='upload_session' and admin(uid): ctx.user_data['await']='session'; await q.edit_message_text('📤 Please send Instagram session file')
 elif q.data=='users' and admin(uid): txt='\n'.join(f'{u} | {d["role"]} | blocked={d["blocked"]}' for u,d in users.items()); await q.edit_message_text(txt)

async def text(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
 uid=str(update.effective_user.id); ensure(uid)
 if blocked(uid): return
 if ctx.user_data.get('await')=='add': users[uid]['accounts'].append(update.message.text.strip().replace('@','')); ctx.user_data['await']=None; save(); await update.message.reply_text('Added',reply_markup=menu(admin(uid),users[uid]['language']))
 elif ctx.user_data.get('await')=='link': ctx.user_data['await']=None; await fetch_link(update.message.text.strip(),update.message.chat_id,ctx); await update.message.reply_text('Done',reply_markup=menu(admin(uid),users[uid]['language']))

async def receive_session(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
 uid=str(update.effective_user.id)
 if not admin(uid): return
 if ctx.user_data.get('await')!='session': return
 doc=update.message.document
 if not doc: await update.message.reply_text('❌ Please send a file'); return
 file=await doc.get_file(); await file.download_to_drive(custom_path=str(SESSION))
 try: L.load_session_from_file(filename=str(SESSION)); ctx.user_data['await']=None; await update.message.reply_text('✅ Instagram session loaded')
 except Exception as e: await update.message.reply_text(f'❌ Failed: {e}')

async def fetch_all(uid,chat_id,ctx):
 for a in users[uid]['accounts']: await fetch_account(a,chat_id,ctx)

async def fetch_account(username,chat_id,ctx):
 try: p=instaloader.Profile.from_username(L.context,username)
 except: return
 last=state.get(username,{})
 for post in p.get_posts():
  if last.get('post') and post.date_utc<=datetime.fromisoformat(last['post']): break
  L.download_post(post,target=username)
  for r,_,f in os.walk(DOWNLOADS/username):
   for x in f: await send_file(os.path.join(r,x),chat_id,ctx)
  last['post']=post.date_utc.isoformat()
 if L.context.is_logged_in:
  try:
   for story in instaloader.get_stories([p.userid],L.context):
    for item in story.get_items():
     if last.get('story') and item.date_utc<=datetime.fromisoformat(last['story']): continue
     L.download_storyitem(item,target=username)
     for r,_,f in os.walk(DOWNLOADS/username):
      for x in f: await send_file(os.path.join(r,x),chat_id,ctx)
     last['story']=item.date_utc.isoformat()
  except: pass
 else: await ctx.bot.send_message(chat_id,LANG[users[str(chat_id)]['language']]['login_required'])
 state[username]=last; save()

async def fetch_link(url,chat_id,ctx):
 d=DOWNLOADS/'link'; d.mkdir(exist_ok=True)
 try:
  if '/p/' in url or '/reel/' in url: c=url.rstrip('/').split('/')[-1]; L.download_post(instaloader.Post.from_shortcode(L.context,c),target='link')
  sent=False
  for r,_,f in os.walk(d):
   for x in f: await send_file(os.path.join(r,x),chat_id,ctx); sent=True
  if not sent: await ctx.bot.send_message(chat_id,'Nothing downloaded')
 except Exception as e: await ctx.bot.send_message(chat_id,f'Error: {e}')

def main():
 app=ApplicationBuilder().token(BOT_TOKEN).build()
 app.add_handler(CommandHandler('start',start))
 app.add_handler(CallbackQueryHandler(cb))
 app.add_handler(MessageHandler(filters.TEXT&~filters.COMMAND,text))
 app.add_handler(MessageHandler(filters.Document.ALL,receive_session))
 app.run_polling()

if __name__=='__main__': main()
EOL

# systemd service
sudo tee /etc/systemd/system/$SERVICE.service > /dev/null <<EOF
[Unit]
Description=Telegram Instagram Bot
After=network.target
[Service]
WorkingDirectory=$PROJECT
ExecStart=$PROJECT/venv/bin/python $PROJECT/bot.py
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable $SERVICE
sudo systemctl start $SERVICE

echo "✅ Bot installed and running. Use: sudo systemctl status $SERVICE"
