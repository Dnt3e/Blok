const express = require('express');
const router = express.Router();
const fs = require('fs');
const path = require('path');
const auth = require('../middleware/auth');
const { exec } = require('child_process');

const backupDir = path.join(__dirname, '../../backups');

// Create backup
router.post('/', auth('admin'), async (req, res) => {
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
  const backupFile = path.join(backupDir, `backup-${timestamp}.sql`);
  
  try {
    // MySQL dump command
    const cmd = `mysqldump -u ${process.env.DB_USER} -p${process.env.DB_PASS} ${process.env.DB_NAME} > ${backupFile}`;
    
    exec(cmd, (error, stdout, stderr) => {
      if (error) {
        console.error(`exec error: ${error}`);
        return res.status(500).send('Backup failed');
      }
      res.send({ message: 'Backup created', file: backupFile });
    });
  } catch (err) {
    res.status(500).send(err);
  }
});

// Restore backup
router.post('/restore', auth('admin'), async (req, res) => {
  const { file } = req.body;
  
  if (!fs.existsSync(file)) {
    return res.status(400).send('Backup file not found');
  }
  
  try {
    // MySQL restore command
    const cmd = `mysql -u ${process.env.DB_USER} -p${process.env.DB_PASS} ${process.env.DB_NAME} < ${file}`;
    
    exec(cmd, (error, stdout, stderr) => {
      if (error) {
        console.error(`exec error: ${error}`);
        return res.status(500).send('Restore failed');
      }
      res.send({ message: 'Database restored' });
    });
  } catch (err) {
    res.status(500).send(err);
  }
});

module.exports = router;
