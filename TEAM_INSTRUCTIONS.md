# 👥 Team-Specific Instructions

**sQuark Bot Backend serves both teams:**
1. sQuark AI Browser team (Desktop)
2. sQuark.ai Website team (Web chatbot widget)

---

## 🖥️ sQuark AI Browser Team

### What You Need to Know

- **Backend Purpose**: Provides chatbot API for your desktop application
- **API Type**: REST HTTP API (HTTPS)
- **Authentication**: API key via `X-API-Key` header
- **Session Type**: Desktop sessions identified as `squark-browser-*`
- **Cost**: Shared infrastructure, minimal per-user cost

### Integration Steps

#### 1. Get the API Endpoint

From DevOps team:
```
API_ENDPOINT = "https://xxx.execute-api.us-east-2.amazonaws.com/prod"
API_KEY = "your-secret-key"
```

#### 2. Add to Your Project

**Option A: Copy-Paste Python Code**

```python
# File: squark/chatbot/client.py

import requests
import json
import os

class SQuarkBotClient:
    def __init__(self, api_endpoint, api_key):
        self.api_endpoint = api_endpoint
        self.api_key = api_key
        self.session_id = f"squark-browser-{os.getenv('USER', 'default')}"
        self.headers = {
            "Content-Type": "application/json",
            "X-API-Key": self.api_key
        }
    
    def send_message(self, message):
        """Send message to chatbot"""
        url = f"{self.api_endpoint}/chat"
        payload = {
            "message": message,
            "session_id": self.session_id,
            "client_type": "squark-browser"
        }
        response = requests.post(url, json=payload, headers=self.headers)
        
        if response.status_code == 200:
            return response.json().get("reply", "No response")
        else:
            return f"Error: {response.status_code}"
```

**Option B: Follow Full Implementation**

See [INTEGRATION_GUIDE.md](INTEGRATION_GUIDE.md) → "sQuark AI Browser Integration"

#### 3. Use in Your UI

```python
# In your Qt/PySide component

from squark.chatbot.client import SQuarkBotClient

class ChatPanel(QWidget):
    def __init__(self):
        super().__init__()
        self.bot = SQuarkBotClient(API_ENDPOINT, API_KEY)
    
    def on_send_click(self):
        user_message = self.message_input.text()
        bot_reply = self.bot.send_message(user_message)
        self.display_message(f"Bot: {bot_reply}")
```

#### 4. Test Locally

```python
# test_bot.py
from squark.chatbot.client import SQuarkBotClient

client = SQuarkBotClient("your-endpoint", "your-key")
response = client.send_message("Hello, bot!")
print(response)
```

### Troubleshooting

**"Connection refused"**
```bash
# Check endpoint is correct
curl https://your-endpoint/health
# Should return 200 OK
```

**"Unauthorized" (401)**
```bash
# Check API key is correct
curl -H "X-API-Key: your-key" \
  https://your-endpoint/chat
```

**"Timeout"**
```bash
# Check internet connectivity
ping -c 5 8.8.8.8
# Check endpoint is reachable
curl -i https://your-endpoint/health
```

### Configuration

```yaml
# .squark/config.yaml

chatbot:
  enabled: true
  api_endpoint: "https://your-endpoint"
  api_key: "your-api-key"
  timeout: 30
  retry_count: 3
  client_type: "squark-browser"
```

### Questions?

- See [INTEGRATION_GUIDE.md](INTEGRATION_GUIDE.md#-squark-ai-browser-integration)
- Ask DevOps team about API_ENDPOINT
- Check [DUAL_PURPOSE_ARCHITECTURE.md](DUAL_PURPOSE_ARCHITECTURE.md) for how backend works

---

## 🌐 sQuark.ai Website Team

### What You Need to Know

- **Backend Purpose**: Provides chatbot API for website chat widget
- **API Type**: REST HTTP API (HTTPS) with CORS
- **Authentication**: API key via `X-API-Key` header
- **Session Type**: Web sessions identified as `web-*`
- **Embedding**: Can be embedded as React component or vanilla JS
- **Cost**: Shared infrastructure, minimal per-visitor cost

### Integration Steps

#### 1. Get the API Endpoint

From DevOps team:
```javascript
const API_ENDPOINT = "https://xxx.execute-api.us-east-2.amazonaws.com/prod";
const API_KEY = "your-secret-key";
```

#### 2. Add to Your Website

**Option A: React Component (Recommended)**

```jsx
// components/ChatBot.jsx
import ChatBot from '../path/to/ChatBot';

export default function Page() {
  return (
    <div>
      {/* Your page content */}
      <ChatBot 
        apiEndpoint="https://your-endpoint"
        apiKey="your-api-key"
      />
    </div>
  );
}
```

Copy component from [INTEGRATION_GUIDE.md](INTEGRATION_GUIDE.md#2-react-component-example)

**Option B: Vanilla JavaScript Widget**

```html
<!-- Add to your HTML -->
<div id="squark-chatbot-widget"></div>
<script src="/squark-chatbot-widget.js"></script>
```

Copy code from [INTEGRATION_GUIDE.md](INTEGRATION_GUIDE.md#1-html-widget-code)

#### 3. Customize Styling

```css
/* Match your brand */
#squark-chatbot-widget {
  /* Your colors */
  --primary-color: #667eea;
  --secondary-color: #764ba2;
}
```

#### 4. Position on Page

```jsx
// Bottom-right corner (default)
<ChatBot position="bottom-right" />

// Bottom-left
<ChatBot position="bottom-left" />

// Inline (full width)
<ChatBot position="inline" />
```

#### 5. Test on Staging

```bash
# Add to staging domain
# Update API_ENDPOINT to point to test backend
# Test chatbot functionality
```

### Environment Setup

```javascript
// .env
REACT_APP_CHATBOT_API_ENDPOINT=https://your-endpoint
REACT_APP_CHATBOT_API_KEY=your-api-key

// Or for Next.js
NEXT_PUBLIC_CHATBOT_API_ENDPOINT=https://your-endpoint
NEXT_PUBLIC_CHATBOT_API_KEY=your-api-key
```

### Analytics

Track chatbot usage:

```javascript
// Log chat events
function trackChatMessage(message, isUser) {
  analytics.track('chatbot_message', {
    message_length: message.length,
    is_user: isUser,
    session_id: sessionId,
    timestamp: new Date().toISOString()
  });
}
```

### Troubleshooting

**"CORS error"**
```javascript
// Error: No 'Access-Control-Allow-Origin' header
// Solution: Ensure backend has your domain whitelisted
// Contact DevOps to add to allowed_origins in terraform.tfvars
```

**"Bot not responding"**
```javascript
// Check endpoint is correct
fetch(`${API_ENDPOINT}/health`, {
  headers: { "X-API-Key": API_KEY }
})
.then(r => console.log(r.status)) // Should be 200
```

**"Messages not persisting"**
```javascript
// Each browser session is temporary (24 hours)
// Sessions are identified by web-{timestamp}-{random}
// To persist beyond 24h, save to your DB separately
```

### Production Checklist

- [ ] Update API_ENDPOINT to production URL
- [ ] Use production API_KEY
- [ ] Add sQuark.ai domain to CORS allowed_origins
- [ ] Test chat functionality on staging
- [ ] Test on mobile devices
- [ ] Monitor ChatBot performance
- [ ] Set up error logging
- [ ] Plan for scale (alert if 10M+ calls/month)

### Questions?

- See [INTEGRATION_GUIDE.md](INTEGRATION_GUIDE.md#-squarkweb-website-integration)
- Ask DevOps team about API_ENDPOINT
- Check [DUAL_PURPOSE_ARCHITECTURE.md](DUAL_PURPOSE_ARCHITECTURE.md#-cors-configuration) for CORS setup

---

## 🛠️ DevOps Team

### Deployment

```bash
# 1. Deploy backend
cd /Users/mesonx/MY\ LAB/sQuark-bot
cp terraform.tfvars.cost-optimized terraform.tfvars
nano terraform.tfvars  # Add gemini_api_key + update domains

# 2. Run deployment
./deploy.sh

# 3. Save outputs
terraform output > deployment_outputs.txt
```

### Extract Values

```bash
# Get API endpoint
API_ENDPOINT=$(terraform output -raw api_endpoint)

# Share with both teams
echo "API Endpoint: $API_ENDPOINT"
echo "API Key: your-api-key" (from .env or Secrets Manager)
```

### Update Terraform for Both Clients

```hcl
# terraform.tfvars

# Browser callback URLs
browser_callback_urls = [
  "squark://auth/callback",
  "squark-browser://callback"
]

# Website callback URLs  
website_callback_urls = [
  "https://sQuark.ai/auth/callback",
  "https://sQuark.ai/chat/callback"
]

cognito_callback_urls = concat(browser_callback_urls, website_callback_urls)
```

### Monitoring

```bash
# Monitor both client usage
aws logs tail /aws/lambda/squark-bot-orchestrator --follow

# Filter by client type
aws logs filter-log-events \
  --log-group-name /aws/lambda/squark-bot-orchestrator \
  --filter-pattern '"squark-browser"' OR '"squark-website"'
```

### Cost Monitoring

```bash
# Check daily cost
aws ce get-cost-and-usage \
  --time-period Start=2026-09-13,End=2026-09-14 \
  --granularity DAILY \
  --metrics BlendedCost \
  --group-by Type=DIMENSION,Key=SERVICE
```

### Scaling Plan

| Traffic | Action | Timeline |
|---------|--------|----------|
| <1M/mo | No change | Ongoing |
| 1-10M/mo | Monitor logs | Weekly |
| 10-50M/mo | Add caching | Monthly |
| 50M+/mo | Evaluate alternatives | Quarterly |

See [COST_OPTIMIZATION.md](COST_OPTIMIZATION.md) for pricing at each tier.

### Documentation

- [DUAL_PURPOSE_ARCHITECTURE.md](DUAL_PURPOSE_ARCHITECTURE.md) - System design
- [DEPLOYMENT.md](DEPLOYMENT.md) - Deployment procedures
- [COST_OPTIMIZATION.md](COST_OPTIMIZATION.md) - Cost breakdown
- [INTEGRATION_GUIDE.md](INTEGRATION_GUIDE.md) - Client code examples

---

## 📞 Communication

### Browser Team → DevOps

**Need**: API endpoint, API key, deployment status

**Frequency**: Once at deployment, then quarterly updates

### Website Team → DevOps

**Need**: API endpoint, API key, CORS setup, scaling notification

**Frequency**: Once at deployment, then quarterly updates

### Browser Team ↔ Website Team

**Coordination**: Share API endpoint (it's the same for both!)

**Session Isolation**: Browser sessions (`squark-browser-*`) and website sessions (`web-*`) are automatically isolated

---

## 🚀 Timeline

**Week 1**: Deploy backend
- DevOps runs `./deploy.sh`
- Share endpoint with both teams

**Week 2**: Browser team integration
- Integrate Python client code
- Test locally
- Merge to main branch

**Week 3**: Website team integration
- Integrate React component
- Style for sQuark.ai
- Deploy to staging

**Week 4**: Production launch
- Browser app releases with integration
- Website goes live with chat widget
- Monitor for issues

---

## ✅ Success Criteria

**Browser Team**
- ✓ Chat works in desktop app
- ✓ Sessions persist correctly
- ✓ Error handling works
- ✓ Performance acceptable (<2s response time)

**Website Team**
- ✓ Widget displays correctly
- ✓ Chat works on desktop and mobile
- ✓ CORS errors resolved
- ✓ Performance acceptable (<1s response time)

**DevOps**
- ✓ Backend runs reliably
- ✓ Costs stay under budget ($15/month)
- ✓ Monitoring alerts configured
- ✓ Logs available for debugging

---

**Status**: All teams ready to integrate!

**Repository**: https://github.com/MesonX-ai/sQuark-bot

**Start Date**: Now!

