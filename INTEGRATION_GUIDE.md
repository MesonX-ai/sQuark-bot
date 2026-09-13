# 🔗 Integration Guide - Dual Applications

**sQuark Bot Backend serves both**:
1. sQuark AI Browser (Desktop)
2. Chatbot in sQuark.ai Website (Web)

---

## 🚀 Quick Setup

### Backend Deployment

```bash
cd /Users/mesonx/MY\ LAB/sQuark-bot
cp terraform.tfvars.cost-optimized terraform.tfvars
nano terraform.tfvars  # Add gemini_api_key
./deploy.sh
```

**Save the API endpoint** from output: `terraform output -raw api_endpoint`

---

## 💻 sQuark AI Browser Integration

### 1. Python Client Code

```python
#!/usr/bin/env python3
import requests
import json
import os

class SQuarkBotClient:
    def __init__(self, api_endpoint, api_key):
        self.api_endpoint = api_endpoint
        self.api_key = api_key
        self.session_id = f"squark-browser-{os.getenv('USER')}"
        self.headers = {
            "Content-Type": "application/json",
            "X-API-Key": self.api_key
        }
    
    def send_message(self, message):
        """Send message to chatbot and get response"""
        url = f"{self.api_endpoint}/chat"
        
        payload = {
            "message": message,
            "session_id": self.session_id,
            "client_type": "squark-browser"
        }
        
        response = requests.post(url, json=payload, headers=self.headers)
        
        if response.status_code == 200:
            result = response.json()
            return result.get("reply", "No response")
        else:
            return f"Error: {response.status_code} - {response.text}"
    
    def get_session_history(self):
        """Retrieve chat history"""
        url = f"{self.api_endpoint}/sessions/{self.session_id}"
        response = requests.get(url, headers=self.headers)
        
        if response.status_code == 200:
            return response.json()
        else:
            return None


# Usage in sQuark AI Browser
if __name__ == "__main__":
    API_ENDPOINT = "https://your-api-endpoint.execute-api.aws.com/prod"
    API_KEY = "your-api-key"
    
    client = SQuarkBotClient(API_ENDPOINT, API_KEY)
    
    # Send message
    response = client.send_message("What can you do?")
    print(f"Bot: {response}")
    
    # Get history
    history = client.get_session_history()
    print(f"Session history: {history}")
```

### 2. Configuration in sQuark Browser

Add to your config file:

```yaml
# .squark/config.yaml

chatbot:
  enabled: true
  api_endpoint: "https://your-api-endpoint.execute-api.aws.com/prod"
  api_key: "your-api-key"
  client_type: "squark-browser"
  timeout: 30  # seconds
  retry_count: 3
```

### 3. UI Component (Qt/PySide Example)

```python
from PySide6.QtWidgets import QWidget, QVBoxLayout, QLineEdit, QPushButton, QTextEdit
from PySide6.QtCore import Qt, QThread, Signal
import requests

class ChatBotWidget(QWidget):
    response_received = Signal(str)
    
    def __init__(self, api_endpoint, api_key):
        super().__init__()
        self.api_endpoint = api_endpoint
        self.api_key = api_key
        self.session_id = f"squark-browser-session-{id(self)}"
        
        # UI Setup
        self.init_ui()
    
    def init_ui(self):
        layout = QVBoxLayout()
        
        self.chat_display = QTextEdit()
        self.chat_display.setReadOnly(True)
        layout.addWidget(self.chat_display)
        
        self.input_field = QLineEdit()
        self.input_field.setPlaceholderText("Type your message...")
        layout.addWidget(self.input_field)
        
        self.send_button = QPushButton("Send")
        self.send_button.clicked.connect(self.send_message)
        layout.addWidget(self.send_button)
        
        self.setLayout(layout)
    
    def send_message(self):
        user_message = self.input_field.text()
        if not user_message:
            return
        
        # Display user message
        self.chat_display.append(f"You: {user_message}")
        self.input_field.clear()
        
        # Send to backend
        headers = {
            "Content-Type": "application/json",
            "X-API-Key": self.api_key
        }
        
        data = {
            "message": user_message,
            "session_id": self.session_id,
            "client_type": "squark-browser"
        }
        
        try:
            response = requests.post(
                f"{self.api_endpoint}/chat",
                json=data,
                headers=headers,
                timeout=30
            )
            
            if response.status_code == 200:
                result = response.json()
                bot_reply = result.get("reply", "No response")
                self.chat_display.append(f"Bot: {bot_reply}")
            else:
                self.chat_display.append(f"Error: {response.status_code}")
        
        except requests.Timeout:
            self.chat_display.append("Error: Request timeout")
        except Exception as e:
            self.chat_display.append(f"Error: {str(e)}")
```

---

## 🌐 sQuark.ai Website Integration

### 1. HTML Widget Code

```html
<!-- Add to sQuark.ai website -->
<div id="squark-chatbot-widget" style="
  position: fixed;
  bottom: 20px;
  right: 20px;
  width: 400px;
  height: 500px;
  border-radius: 10px;
  box-shadow: 0 4px 12px rgba(0,0,0,0.15);
  background: white;
  display: flex;
  flex-direction: column;
  z-index: 9999;
">
  <div style="
    background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
    color: white;
    padding: 15px;
    border-radius: 10px 10px 0 0;
    font-weight: bold;
  ">
    sQuark AI Assistant
    <button id="close-chat" style="
      float: right;
      background: none;
      border: none;
      color: white;
      cursor: pointer;
      font-size: 18px;
    ">×</button>
  </div>
  
  <div id="chat-messages" style="
    flex: 1;
    overflow-y: auto;
    padding: 15px;
    background: #f5f5f5;
  "></div>
  
  <div style="
    display: flex;
    gap: 10px;
    padding: 15px;
    border-top: 1px solid #ddd;
  ">
    <input type="text" id="chat-input" 
      placeholder="Type your message..."
      style="
        flex: 1;
        padding: 10px;
        border: 1px solid #ddd;
        border-radius: 5px;
      "
    />
    <button id="send-btn" style="
      padding: 10px 20px;
      background: #667eea;
      color: white;
      border: none;
      border-radius: 5px;
      cursor: pointer;
    ">Send</button>
  </div>
</div>

<script>
const API_ENDPOINT = "https://your-api-endpoint.execute-api.aws.com/prod";
const API_KEY = "your-api-key";
const SESSION_ID = `web-${Date.now()}-${Math.random().toString(36).substr(2,9)}`;

const chatMessages = document.getElementById("chat-messages");
const chatInput = document.getElementById("chat-input");
const sendBtn = document.getElementById("send-btn");
const closeBtn = document.getElementById("close-chat");
const widget = document.getElementById("squark-chatbot-widget");

// Send message
async function sendMessage() {
  const message = chatInput.value.trim();
  if (!message) return;
  
  // Display user message
  const userDiv = document.createElement("div");
  userDiv.style.cssText = "margin: 10px 0; text-align: right;";
  userDiv.innerHTML = `<p style="background: #667eea; color: white; padding: 10px; border-radius: 5px; display: inline-block;">${escapeHtml(message)}</p>`;
  chatMessages.appendChild(userDiv);
  chatInput.value = "";
  
  // Show loading
  const loadingDiv = document.createElement("div");
  loadingDiv.textContent = "Bot is typing...";
  loadingDiv.style.cssText = "color: #999; font-style: italic;";
  chatMessages.appendChild(loadingDiv);
  chatMessages.scrollTop = chatMessages.scrollHeight;
  
  try {
    const response = await fetch(`${API_ENDPOINT}/chat`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-API-Key": API_KEY,
        "Origin": window.location.origin
      },
      body: JSON.stringify({
        message: message,
        session_id: SESSION_ID,
        client_type: "squark-website"
      })
    });
    
    if (response.ok) {
      const data = await response.json();
      const botReply = data.reply || "No response";
      
      // Remove loading
      loadingDiv.remove();
      
      // Display bot message
      const botDiv = document.createElement("div");
      botDiv.style.cssText = "margin: 10px 0; text-align: left;";
      botDiv.innerHTML = `<p style="background: #e0e0e0; color: #333; padding: 10px; border-radius: 5px; display: inline-block;">${escapeHtml(botReply)}</p>`;
      chatMessages.appendChild(botDiv);
    } else {
      loadingDiv.textContent = `Error: ${response.status}`;
    }
  } catch (error) {
    loadingDiv.textContent = `Error: ${error.message}`;
  }
  
  chatMessages.scrollTop = chatMessages.scrollHeight;
}

// Event listeners
sendBtn.addEventListener("click", sendMessage);
chatInput.addEventListener("keypress", (e) => {
  if (e.key === "Enter") sendMessage();
});

closeBtn.addEventListener("click", () => {
  widget.style.display = "none";
});

// Helper function
function escapeHtml(text) {
  const div = document.createElement("div");
  div.textContent = text;
  return div.innerHTML;
}

// Auto-scroll to bottom
chatMessages.addEventListener("DOMNodeInserted", () => {
  chatMessages.scrollTop = chatMessages.scrollHeight;
});
</script>
```

### 2. React Component Example

```jsx
// components/ChatBot.jsx
import React, { useState, useRef, useEffect } from 'react';

const ChatBot = ({ apiEndpoint, apiKey }) => {
  const [messages, setMessages] = useState([]);
  const [input, setInput] = useState('');
  const [isLoading, setIsLoading] = useState(false);
  const [sessionId] = useState(() => `web-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`);
  const messagesEndRef = useRef(null);

  const scrollToBottom = () => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  };

  useEffect(() => {
    scrollToBottom();
  }, [messages]);

  const sendMessage = async (e) => {
    e.preventDefault();
    if (!input.trim()) return;

    // Add user message
    setMessages(prev => [...prev, { role: 'user', content: input }]);
    setInput('');
    setIsLoading(true);

    try {
      const response = await fetch(`${apiEndpoint}/chat`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-API-Key': apiKey,
        },
        body: JSON.stringify({
          message: input,
          session_id: sessionId,
          client_type: 'squark-website',
        }),
      });

      if (response.ok) {
        const data = await response.json();
        setMessages(prev => [...prev, { role: 'bot', content: data.reply }]);
      } else {
        setMessages(prev => [...prev, { role: 'bot', content: `Error: ${response.status}` }]);
      }
    } catch (error) {
      setMessages(prev => [...prev, { role: 'bot', content: `Error: ${error.message}` }]);
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <div className="chatbot-container" style={{
      position: 'fixed',
      bottom: 20,
      right: 20,
      width: 400,
      height: 500,
      display: 'flex',
      flexDirection: 'column',
      backgroundColor: 'white',
      borderRadius: 10,
      boxShadow: '0 4px 12px rgba(0,0,0,0.15)',
    }}>
      <div style={{
        background: 'linear-gradient(135deg, #667eea 0%, #764ba2 100%)',
        color: 'white',
        padding: 15,
        borderRadius: '10px 10px 0 0',
        fontWeight: 'bold',
      }}>
        sQuark AI Assistant
      </div>

      <div style={{
        flex: 1,
        overflowY: 'auto',
        padding: 15,
        backgroundColor: '#f5f5f5',
      }}>
        {messages.map((msg, idx) => (
          <div key={idx} style={{
            marginBottom: 10,
            textAlign: msg.role === 'user' ? 'right' : 'left',
          }}>
            <p style={{
              background: msg.role === 'user' ? '#667eea' : '#e0e0e0',
              color: msg.role === 'user' ? 'white' : '#333',
              padding: 10,
              borderRadius: 5,
              display: 'inline-block',
              maxWidth: '80%',
              wordWrap: 'break-word',
            }}>
              {msg.content}
            </p>
          </div>
        ))}
        {isLoading && <p style={{ color: '#999', fontStyle: 'italic' }}>Bot is typing...</p>}
        <div ref={messagesEndRef} />
      </div>

      <form onSubmit={sendMessage} style={{
        display: 'flex',
        gap: 10,
        padding: 15,
        borderTop: '1px solid #ddd',
      }}>
        <input
          type="text"
          value={input}
          onChange={(e) => setInput(e.target.value)}
          placeholder="Type your message..."
          disabled={isLoading}
          style={{
            flex: 1,
            padding: 10,
            border: '1px solid #ddd',
            borderRadius: 5,
          }}
        />
        <button
          type="submit"
          disabled={isLoading}
          style={{
            padding: '10px 20px',
            background: '#667eea',
            color: 'white',
            border: 'none',
            borderRadius: 5,
            cursor: 'pointer',
          }}
        >
          Send
        </button>
      </form>
    </div>
  );
};

export default ChatBot;

// Usage in sQuark.ai website
// <ChatBot apiEndpoint="https://your-api-endpoint" apiKey="your-api-key" />
```

### 3. Installation

```bash
# Copy ChatBot.jsx to your React project
cp ChatBot.jsx src/components/

# Add to your main page
# pages/index.jsx
import ChatBot from '../components/ChatBot';

export default function Home() {
  return (
    <div>
      {/* Your page content */}
      <ChatBot 
        apiEndpoint="https://your-api-endpoint.execute-api.aws.com/prod"
        apiKey="your-api-key"
      />
    </div>
  );
}
```

---

## 🔑 API Key Management

### For Development
```bash
# Generate test key
API_KEY="test-key-$(date +%s)"
echo $API_KEY > .env.local
```

### For Production
```bash
# Store in AWS Secrets Manager
aws secretsmanager create-secret \
  --name squark-bot-api-key \
  --secret-string "prod-api-key-xyz"

# Retrieve in Lambda
import boto3
sm = boto3.client('secretsmanager')
secret = sm.get_secret_value(SecretId='squark-bot-api-key')
API_KEY = secret['SecretString']
```

---

## 📊 Session Isolation

Conversations are isolated by client type:

```
Browser Sessions:  squark-browser-username
Website Sessions:  web-1694620800123-abc123def456
```

Each session maintains its own conversation history in DynamoDB.

---

## ✅ Testing Both Clients

### Test Browser Client
```python
python3 <<'EOF'
import requests

api_endpoint = "https://your-endpoint/prod"
api_key = "your-key"

response = requests.post(
    f"{api_endpoint}/chat",
    headers={"X-API-Key": api_key},
    json={
        "message": "Hello from sQuark Browser",
        "session_id": "squark-browser-test",
        "client_type": "squark-browser"
    }
)

print(f"Status: {response.status_code}")
print(f"Response: {response.json()}")
EOF
```

### Test Website Client
```bash
curl -X POST https://your-endpoint/prod/chat \
  -H "Content-Type: application/json" \
  -H "X-API-Key: your-key" \
  -d '{
    "message": "Hello from sQuark.ai website",
    "session_id": "web-test-123",
    "client_type": "squark-website"
  }'
```

---

## 📚 Related Documentation

- [DUAL_PURPOSE_ARCHITECTURE.md](DUAL_PURPOSE_ARCHITECTURE.md) - Architecture overview
- [COST_OPTIMIZATION.md](COST_OPTIMIZATION.md) - Cost breakdown
- [COST_OPTIMIZED_QUICK_START.md](COST_OPTIMIZED_QUICK_START.md) - Quick deploy

---

**Status**: Ready for both client integrations

**GitHub**: https://github.com/MesonX-ai/sQuark-bot

