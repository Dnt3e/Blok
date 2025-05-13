const express = require('express');
const jwt = require('jsonwebtoken');
const bcrypt = require('bcryptjs');
const User = require('../models/User');
const router = express.Router();

router.post('/login', async (req, res) => {
  const { username, password } = req.body;
  
  const user = await User.findOne({ username });
  if (!user) return res.status(400).send('User not found');
  
  const validPass = await bcrypt.compare(password, user.password);
  if (!validPass) return res.status(400).send('Invalid password');
  
  if (user.role !== 'admin') return res.status(403).send('Access denied');
  
  const token = jwt.sign(
    { _id: user._id, role: user.role }, 
    process.env.JWT_SECRET, 
    { expiresIn: '1h' }
  );
  
  res.header('Authorization', token).send(token);
});

module.exports = router;
