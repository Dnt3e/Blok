const express = require('express');
const router = express.Router();
const User = require('../models/User');
const vpnManager = require('../services/vpnManager');
const auth = require('../middleware/auth');

// Create new client
router.post('/', auth('admin'), async (req, res) => {
  const { username, password, dataLimit, expiryDate } = req.body;
  
  try {
    const user = new User({
      username,
      password,
      role: 'client',
      dataLimit,
      expiryDate
    });
    
    await user.save();
    
    // Generate VPN config
    const config = await vpnManager.generateConfig(user);
    user.config = config;
    await user.save();
    
    res.send(user);
  } catch (err) {
    res.status(400).send(err);
  }
});

// Get all clients
router.get('/', auth('admin'), async (req, res) => {
  const users = await User.find({ role: 'client' });
  res.send(users);
});

// Other routes: update, delete, etc.

module.exports = router;
