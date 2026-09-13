# sQuark Bot Backend - Dual-Purpose Architecture

**Serves Both**: sQuark AI Browser + Chatbot in sQuark.ai Website

---

## 🎯 Purpose

This backend provides a unified chatbot API for two distinct client applications:

### 1. **sQuark AI Browser** 
- Desktop application (Python Qt/PySide)
- Rich UI for advanced chatbot interactions
- Embedded chat interface
- Local or cloud-based deployment

### 2. **Chatbot in sQuark.ai Website**
- Web-based chatbot widget
- Embedded on sQuark.ai landing page
- Public-facing chat interface
- Real-time responses

Both applications share the same backend infrastructure but have different frontend requirements.

---

## 🏗️ Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                   sQuark Bot Backend                    │
│  (Lambda + API Gateway + DynamoDB + CloudWatch)         │
│                    on AWS                               │
└──────────────────────┬──────────────────────────────────┘
                       │
        ┌──────────────┼──────────────┐
        │              │              │
        ▼              ▼              ▼
    ┌─────────┐  ┌──────────┐  ┌─────────────┐
    │sQuark AI│  │sQuark.ai │  │   Other     │
    │ Browser │  │ Website  │  │   Clients   │
    │(Desktop)│  │  (Web)   │  │             │
    └─────────┘  └──────────┘  └─────────────┘
```

---

## 📡 API Endpoints

Both applications access the same API endpoints:

```
Base URL: https://<api-endpoint>.execute-api.aws.com/prod

Endpoints:
  POST   /chat              - Send message to chatbot
  POST   /sessions          - Create new chat session
  GET    /sessions/{id}     - Get session history
  PUT    /sessions/{id}     - Update session
  DELETE /sessions/{id}     - Delete session
  GET    /health            - Health check
```

---

## 🔌 Frontend Integration

### sQuark AI Browser (Python Desktop App)

```python
import requests

# Configuration
API_ENDPOINT = "https://<api-endpoint>.execute-api.aws.com/prod"
API_KEY = "your-api-key"

# Headers
headers = {
    "Content-Type": "application/json",
    "X-API-Key": API_KEY
}

# Send message
response = requests.post(
    f"{API_ENDPOINT}/chat",
    json={
        "message": "Hello, what can you do?",
        "session_id": "user-desktop-123",
        "client_type": "squark-browser"  # Identify as browser app
    },
    headers=headers
)

result = response.json()
print(f"Response: {result['reply']}")
```

### Chatbot on sQuark.ai Website (JavaScript)

```javascript
// Configuration
const API_ENDPOINT = "https://<api-endpoint>.execute-api.aws.com/prod";
const API_KEY = "your-api-key";

// Send message
async function sendMessage(userMessage) {
  const response = await fetch(`${API_ENDPOINT}/chat`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-API-Key": API_KEY,
      "Origin": "https://sQuark.ai"  // CORS header
    },
    body: JSON.stringify({
      message: userMessage,
      session_id: `web-${Date.now()}`,
      client_type: "squark-website"  // Identify as website
    })
  });

  const data = await response.json();
  return data.reply;
}

// Use in chat widget
document.getElementById("send-btn").onclick = async () => {
  const userMsg = document.getElementById("message-input").value;
  const reply = await sendMessage(userMsg);
  displayChatMessage(reply);
};
```

---

## 🔐 Configuration for Multiple Frontends

When deploying, configure Cognito/API Gateway for both applications:

### Option 1: Simple API Key (Cost-Optimized)

Both applications use the same API key in headers:

```hcl
# terraform.tfvars
api_auth_type = "api_key"
api_key = "your-secret-key-here"
```

### Option 2: OAuth 2.0 (Secure, Cognito)

Each application has its own Cognito app client:

```hcl
# terraform.tfvars
enable_cognito = true

# Browser app callback URLs
browser_callback_urls = [
  "squark://auth/callback",  # Desktop app URI scheme
  "squark-browser://callback"
]

# Website callback URLs
website_callback_urls = [
  "https://sQuark.ai/auth/callback",
  "https://sQuark.ai/chat/callback"
]

cognito_callback_urls = concat(browser_callback_urls, website_callback_urls)
```

---

## 📊 Usage Scenarios

### Scenario 1: Low-Cost Public API (Recommended)

- **Cost**: $8-15/month
- **Auth**: Simple API key
- **Suitable for**:
  - Public chatbot widget on sQuark.ai
  - Internal sQuark Browser usage
  - <100K calls/month

**Deploy using**: `terraform.tfvars.cost-optimized`

```bash
cp terraform.tfvars.cost-optimized terraform.tfvars
./deploy.sh
```

### Scenario 2: Secure with User Management

- **Cost**: $50-170/month
- **Auth**: Cognito OAuth 2.0
- **Suitable for**:
  - Private chatbot access
  - User-specific sessions
  - User authentication tracking
  - High-traffic scenarios

**Deploy using**: `terraform.tfvars.new-account`

```bash
cp terraform.tfvars.new-account terraform.tfvars
enable_cognito = true
./deploy.sh
```

---

## 🌐 CORS Configuration

The backend automatically handles CORS for both web and desktop clients:

```hcl
# terraform.tfvars
allowed_origins = [
  "https://sQuark.ai",
  "http://localhost:3000",
  "http://localhost:8080"
  # Desktop app makes direct HTTP calls, no CORS needed
]
```

---

## 📝 Session Management

### Browser Application
- Creates persistent sessions per user
- Stores conversation history
- Sessionf identified by `user-desktop-{id}`

### Website Application
- Creates temporary sessions
- Session lifetime: ~24 hours
- Sessions identified by timestamp

### Backend Storage
```
DynamoDB Table: squark-bot-sessions

Fields:
  session_id (primary key)
  user_id
  client_type: "squark-browser" | "squark-website"
  messages: [{role, content, timestamp}, ...]
  created_at
  updated_at
  expiration_time (TTL - 90 days)
```

---

## 🔧 Monitoring & Logging

Both clients' requests are logged together:

```bash
# View all chatbot requests
aws logs tail /aws/lambda/squark-bot-orchestrator --follow

# Filter by client type
aws logs filter-log-events \
  --log-group-name /aws/lambda/squark-bot-orchestrator \
  --filter-pattern "client_type"

# View browser app requests only
aws logs filter-log-events \
  --log-group-name /aws/lambda/squark-bot-orchestrator \
  --filter-pattern '"squark-browser"'

# View website requests only
aws logs filter-log-events \
  --log-group-name /aws/lambda/squark-bot-orchestrator \
  --filter-pattern '"squark-website"'
```

---

## 📈 Scaling Considerations

### For sQuark AI Browser
- Desktop app: Occasional, on-demand API calls
- Expected: 10-100 calls/month per user
- Scaling impact: Minimal

### For sQuark.ai Website
- Web widget: More frequent user interactions
- Expected: 1000-10K calls/month (traffic-dependent)
- Scaling impact: May drive most usage

**Combined scaling**: 
- <100K calls/month: $8-15 (cost-optimized)
- 1M calls/month: $0.35 (still within budget)
- 10M calls/month: $4.50 (scales smoothly)

---

## 🚀 Deployment Options

### Quick Start (Cost-Optimized)
```bash
cd /Users/mesonx/MY\ LAB/sQuark-bot
cp terraform.tfvars.cost-optimized terraform.tfvars
nano terraform.tfvars  # Add API key
./deploy.sh
```

### Production (Secure)
```bash
cd /Users/mesonx/MY\ LAB/sQuark-bot
cp terraform.tfvars.new-account terraform.tfvars
nano terraform.tfvars  # Configure Cognito for both apps
./deploy.sh
```

---

## 📋 Client Registration

When deploying for both clients, register each in the backend:

```bash
# Register sQuark Browser
curl -X POST https://<api-endpoint>/api/clients/register \
  -H "Content-Type: application/json" \
  -d '{
    "client_id": "squark-browser",
    "client_name": "sQuark AI Browser",
    "client_type": "desktop",
    "endpoints": ["http://localhost:3000"]
  }'

# Register sQuark Website
curl -X POST https://<api-endpoint>/api/clients/register \
  -H "Content-Type: application/json" \
  -d '{
    "client_id": "squark-website",
    "client_name": "Chatbot - sQuark.ai",
    "client_type": "web",
    "endpoints": ["https://sQuark.ai"]
  }'
```

---

## 🔐 Security Best Practices

1. **API Key Rotation**
   - Rotate API key every 90 days
   - Maintain separate keys for each client (optional)

2. **Rate Limiting**
   - Browser: 100 requests/minute per session
   - Website: 50 requests/minute per IP
   - Configurable in Lambda

3. **Data Privacy**
   - Conversations stored for 90 days (configurable TTL)
   - GDPR-compliant data retention
   - No personal data stored unnecessarily

4. **CORS Security**
   - Whitelist only known origins
   - Validate referer headers
   - Use HTTPS only in production

---

## 📞 Troubleshooting

### Website Widget Not Connecting
```bash
# Check CORS headers
curl -i -X OPTIONS https://<api-endpoint>/chat \
  -H "Origin: https://sQuark.ai" \
  -H "Access-Control-Request-Method: POST"

# Verify API key in headers
curl -X POST https://<api-endpoint>/chat \
  -H "X-API-Key: your-key" \
  -H "Content-Type: application/json" \
  -d '{"message":"test"}'
```

### Browser App Connection Issues
```bash
# Check if API endpoint is reachable
curl -I https://<api-endpoint>/health

# Verify network connectivity
python3 -c "
import requests
r = requests.post('https://<api-endpoint>/chat', 
  headers={'X-API-Key': 'your-key'},
  json={'message': 'test'})
print(f'Status: {r.status_code}')
print(f'Response: {r.json()}')
"
```

### Session Mismatch Between Clients
```bash
# Verify session isolation
# Browser sessions: user-desktop-*
# Website sessions: web-*

aws dynamodb query \
  --table-name squark-bot-sessions \
  --key-condition-expression "client_type = :ct" \
  --expression-attribute-values '{":ct": {"S": "squark-browser"}}'
```

---

## 📚 Related Documentation

- [COST_OPTIMIZATION.md](COST_OPTIMIZATION.md) - Cost breakdown for both clients
- [COST_OPTIMIZED_QUICK_START.md](COST_OPTIMIZED_QUICK_START.md) - Quick deployment
- [DEPLOYMENT.md](DEPLOYMENT.md) - Full deployment guide
- [ARCHITECTURE_WHITEPAPER.md](ARCHITECTURE_WHITEPAPER.md) - Technical details

---

## ✅ Deployment Checklist

- [ ] Update terraform.tfvars with sQuark.ai domains
- [ ] Configure callback URLs for both applications
- [ ] Deploy backend infrastructure: `./deploy.sh`
- [ ] Save API endpoint from terraform output
- [ ] Register both clients (browser & website)
- [ ] Test browser app connection
- [ ] Test website widget connection
- [ ] Set up monitoring and alerts
- [ ] Configure API key rotation schedule
- [ ] Document in sQuark.ai and browser app wikis

---

**Status**: Ready for dual-purpose deployment

**GitHub**: https://github.com/MesonX-ai/sQuark-bot  
**Branch**: main

