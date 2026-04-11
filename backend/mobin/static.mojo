"""Static asset serving for mobin backend.

Embeds the frontend HTML so the backend can serve it standalone
(without a separate nginx container). In production Docker Compose,
nginx serves the same file from frontend/src/index.html.
"""

from flare.http import Request, Response, Status


def _to_bytes(s: String) -> List[UInt8]:
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b))
    for c in b:
        out.append(c)
    return out^


# Minimal inline HTML that loads the full UI.
# Kept small here; the full-featured page is at frontend/src/index.html.
comptime _INDEX_HTML: String = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>mobin — Mojo Pastebin</title>
<style>
:root{--bg:#0f1117;--surface:#1a1d27;--border:#2a2d3a;--text:#e2e8f0;
--muted:#64748b;--accent:#f97316;--accent2:#fb923c;--green:#22c55e;
--red:#ef4444;--font-mono:'JetBrains Mono',monospace}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font-family:system-ui,sans-serif;
min-height:100vh;display:flex;flex-direction:column}
header{padding:1rem 2rem;border-bottom:1px solid var(--border);
display:flex;align-items:center;gap:1rem}
.logo{font-size:1.5rem;font-weight:800;background:linear-gradient(135deg,var(--accent),var(--accent2));
-webkit-background-clip:text;-webkit-text-fill-color:transparent}
.tagline{color:var(--muted);font-size:.85rem}
main{flex:1;display:grid;grid-template-columns:1fr 320px;gap:0;max-width:1400px;
width:100%;margin:0 auto;padding:2rem;gap:2rem}
@media(max-width:768px){main{grid-template-columns:1fr}}
.card{background:var(--surface);border:1px solid var(--border);border-radius:12px;overflow:hidden}
.card-header{padding:.75rem 1rem;border-bottom:1px solid var(--border);
font-size:.8rem;font-weight:600;text-transform:uppercase;letter-spacing:.08em;color:var(--muted)}
.card-body{padding:1rem}
form{display:flex;flex-direction:column;gap:.75rem}
input,select,textarea{background:#111827;border:1px solid var(--border);color:var(--text);
border-radius:8px;padding:.6rem .8rem;font-size:.9rem;width:100%;outline:none;
font-family:inherit;transition:border-color .2s}
input:focus,select:focus,textarea:focus{border-color:var(--accent)}
textarea{font-family:var(--font-mono);min-height:200px;resize:vertical;font-size:.85rem;line-height:1.5}
.row{display:flex;gap:.5rem}
.row select{flex:1}
button{background:linear-gradient(135deg,var(--accent),var(--accent2));color:#fff;
border:none;border-radius:8px;padding:.7rem 1.2rem;font-size:.9rem;font-weight:600;
cursor:pointer;transition:opacity .2s;width:100%}
button:hover{opacity:.85}
button:disabled{opacity:.5;cursor:default}
.paste-card{background:var(--bg);border:1px solid var(--border);border-radius:8px;
padding:.75rem;margin-bottom:.5rem;cursor:pointer;transition:border-color .2s}
.paste-card:hover{border-color:var(--accent)}
.paste-card .meta{display:flex;justify-content:space-between;align-items:center;
margin-bottom:.4rem}
.paste-card .ptitle{font-weight:600;font-size:.9rem;overflow:hidden;
text-overflow:ellipsis;white-space:nowrap;max-width:180px}
.paste-card .lang{background:var(--border);color:var(--muted);
font-size:.7rem;padding:.2rem .5rem;border-radius:4px;font-family:var(--font-mono)}
.paste-card .snippet{color:var(--muted);font-size:.8rem;font-family:var(--font-mono);
overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.live-dot{width:8px;height:8px;border-radius:50%;background:var(--green);
animation:pulse 2s infinite;display:inline-block;margin-right:.4rem}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.4}}
.badge{font-size:.7rem;padding:.15rem .5rem;border-radius:4px;font-weight:600}
.badge-ws{background:#052e16;color:var(--green)}
.badge-poll{background:#1c1917;color:var(--muted)}
#detail{display:none}
#detail pre{background:#111827;border-radius:8px;padding:1rem;overflow:auto;
font-family:var(--font-mono);font-size:.82rem;line-height:1.6;color:#a5f3fc;max-height:400px}
.detail-meta{display:flex;gap:1rem;color:var(--muted);font-size:.8rem;flex-wrap:wrap}
.copy-btn{background:transparent;border:1px solid var(--border);color:var(--muted);
width:auto;padding:.3rem .7rem;font-size:.75rem;border-radius:6px}
.copy-btn:hover{border-color:var(--accent);color:var(--accent)}
.back-btn{background:transparent;border:1px solid var(--border);color:var(--text);
width:auto;padding:.4rem .8rem;font-size:.8rem;border-radius:6px;margin-bottom:1rem}
.toast{position:fixed;bottom:1.5rem;right:1.5rem;background:#1e293b;
border:1px solid var(--border);padding:.7rem 1.2rem;border-radius:8px;
font-size:.85rem;opacity:0;transform:translateY(8px);transition:all .3s;pointer-events:none}
.toast.show{opacity:1;transform:translateY(0)}
.feed-empty{color:var(--muted);font-size:.85rem;text-align:center;padding:1.5rem 0}
.stats{display:grid;grid-template-columns:1fr 1fr 1fr;gap:.5rem;margin-bottom:1rem}
.stat{background:var(--bg);border:1px solid var(--border);border-radius:8px;
padding:.6rem;text-align:center}
.stat-val{font-size:1.2rem;font-weight:700;color:var(--accent)}
.stat-lbl{font-size:.7rem;color:var(--muted);margin-top:.1rem}
</style>
</head>
<body>
<header>
  <span class="logo">mobin</span>
  <span class="tagline">Mojo-powered pastebin</span>
</header>
<main>
  <div>
    <!-- Create form -->
    <div class="card" id="create-section">
      <div class="card-header">New Paste</div>
      <div class="card-body">
        <form id="create-form">
          <input type="text" id="title" placeholder="Title (optional)">
          <textarea id="content" placeholder="Paste your code or text here..."></textarea>
          <div class="row">
            <select id="language">
              <option value="plain">Plain Text</option>
              <option value="python">Python</option>
              <option value="mojo">Mojo</option>
              <option value="javascript">JavaScript</option>
              <option value="typescript">TypeScript</option>
              <option value="rust">Rust</option>
              <option value="go">Go</option>
              <option value="c">C</option>
              <option value="cpp">C++</option>
              <option value="shell">Shell</option>
              <option value="json">JSON</option>
              <option value="toml">TOML</option>
              <option value="yaml">YAML</option>
              <option value="sql">SQL</option>
              <option value="markdown">Markdown</option>
            </select>
            <select id="ttl">
              <option value="60">1 minute</option>
              <option value="300">5 minutes</option>
              <option value="3600" selected>1 hour</option>
              <option value="43200">12 hours</option>
              <option value="86400">1 day</option>
              <option value="345600">4 days</option>
              <option value="604800">7 days</option>
              <option value="2592000">30 days</option>
            </select>
          </div>
          <button type="submit" id="create-btn">Create Paste</button>
        </form>
      </div>
    </div>
    <!-- Paste detail view -->
    <div class="card" id="detail">
      <div class="card-body">
        <button class="back-btn" onclick="showCreate()">← Back</button>
        <div class="detail-meta" id="detail-meta"></div>
        <div style="display:flex;justify-content:flex-end;margin:.5rem 0">
          <button class="copy-btn" onclick="copyContent()">Copy</button>
        </div>
        <pre id="detail-content"></pre>
      </div>
    </div>
  </div>
  <div>
    <!-- Stats -->
    <div class="card" style="margin-bottom:1rem">
      <div class="card-header">Stats</div>
      <div class="card-body">
        <div class="stats">
          <div class="stat"><div class="stat-val" id="s-total">—</div><div class="stat-lbl">Total</div></div>
          <div class="stat"><div class="stat-val" id="s-today">—</div><div class="stat-lbl">Today</div></div>
          <div class="stat"><div class="stat-val" id="s-views">—</div><div class="stat-lbl">Views</div></div>
        </div>
      </div>
    </div>
    <!-- Live feed -->
    <div class="card">
      <div class="card-header">
        <span class="live-dot"></span>Live Feed
        <span class="badge" id="conn-badge">connecting...</span>
      </div>
      <div class="card-body" style="max-height:500px;overflow-y:auto" id="feed-list">
        <div class="feed-empty">Waiting for pastes...</div>
      </div>
    </div>
  </div>
</main>
<div class="toast" id="toast"></div>
<script>
const API = (window.location.protocol + '//' + window.location.hostname + ':8080');
const WS_SCHEME = window.location.protocol === 'https:' ? 'wss' : 'ws';
const WS_URL = (WS_SCHEME + '://' + window.location.hostname + ':8081/feed');
let feedPastes = [];
let ws = null;
let pollTimer = null;
let lastSeenAt = Math.floor(Date.now()/1000) - 5;

// ── Toast ──
function toast(msg, ms=2000){
  const t=document.getElementById('toast');
  t.textContent=msg;t.classList.add('show');
  setTimeout(()=>t.classList.remove('show'),ms);
}

// ── Stats ──
async function loadStats(){
  try{
    const r=await fetch(API+'/stats');
    if(!r.ok) return;
    const d=await r.json();
    document.getElementById('s-total').textContent=d.total||0;
    document.getElementById('s-today').textContent=d.today||0;
    document.getElementById('s-views').textContent=d.total_views||0;
  }catch(e){}
}

// ── Feed ──
function addToFeed(paste){
  const now=Math.floor(Date.now()/1000);
  if(paste.expires_at&&paste.expires_at<=now) return;
  if(feedPastes.find(p=>p.id===paste.id)) return;
  feedPastes.unshift(paste);
  if(feedPastes.length>50) feedPastes.pop();
  renderFeed();
}

function purgeExpiredFromFeed(){
  const now=Math.floor(Date.now()/1000);
  const before=feedPastes.length;
  feedPastes=feedPastes.filter(p=>!p.expires_at||p.expires_at>now);
  if(feedPastes.length!==before) renderFeed();
}

async function initFeed(){
  try{
    const r=await fetch(API+'/pastes?limit=20');
    if(!r.ok) return;
    const d=await r.json();
    (d.pastes||[]).slice().reverse().forEach(addToFeed);
  }catch(e){}
}

function renderFeed(){
  const now=Math.floor(Date.now()/1000);
  const live=feedPastes.filter(p=>!p.expires_at||p.expires_at>now);
  const el=document.getElementById('feed-list');
  if(live.length===0){el.innerHTML='<div class="feed-empty">Waiting for pastes...</div>';return;}
  el.innerHTML=live.map(p=>`
    <div class="paste-card" onclick="viewPaste('${p.id}')">
      <div class="meta">
        <span class="ptitle">${esc(p.title||'Untitled')}</span>
        <span class="lang">${esc(p.language||'plain')}</span>
      </div>
      <div class="snippet">${esc((p.content||'').slice(0,80))}</div>
    </div>`).join('');
}

function esc(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');}

function fmtExpiry(unix){
  const diff=unix-Math.floor(Date.now()/1000);
  if(diff<=0) return 'expired';
  if(diff<3600) return 'in '+Math.ceil(diff/60)+' min';
  if(diff<86400) return 'in '+Math.ceil(diff/3600)+' hr';
  return new Date(unix*1000).toLocaleDateString();
}

// ── WebSocket ──
function connectWS(){
  try{
    ws=new WebSocket(WS_URL);
    ws.onopen=()=>{
      document.getElementById('conn-badge').textContent='live';
      document.getElementById('conn-badge').className='badge badge-ws';
      if(pollTimer){clearInterval(pollTimer);pollTimer=null;}
    };
    ws.onmessage=(e)=>{
      try{addToFeed(JSON.parse(e.data));loadStats();}catch(ex){}
    };
    ws.onclose=()=>{
      document.getElementById('conn-badge').textContent='polling';
      document.getElementById('conn-badge').className='badge badge-poll';
      startPolling();
      setTimeout(connectWS,5000);
    };
    ws.onerror=()=>{ws.close();};
  }catch(e){startPolling();}
}

// ── Polling fallback ──
async function pollFeed(){
  try{
    const r=await fetch(API+'/pastes?limit=10');
    if(!r.ok) return;
    const d=await r.json();
    (d.pastes||[]).forEach(p=>{
      if(p.created_at>lastSeenAt) addToFeed(p);
    });
    lastSeenAt=Math.floor(Date.now()/1000);
  }catch(e){}
}

function startPolling(){
  if(pollTimer) return;
  pollTimer=setInterval(pollFeed,3000);
  pollFeed();
}

// ── Create ──
document.getElementById('create-form').addEventListener('submit',async(e)=>{
  e.preventDefault();
  const btn=document.getElementById('create-btn');
  btn.disabled=true;btn.textContent='Creating...';
  const body={
    title:document.getElementById('title').value||'Untitled',
    content:document.getElementById('content').value,
    language:document.getElementById('language').value,
    ttl_secs:parseInt(document.getElementById('ttl').value,10),
  };
  try{
    const r=await fetch(API+'/paste',{
      method:'POST',
      headers:{'Content-Type':'application/json'},
      body:JSON.stringify(body),
    });
    const d=await r.json();
    if(!r.ok){toast('Error: '+(d.error||r.status));return;}
    toast('Paste created!');
    document.getElementById('create-form').reset();
    setTimeout(()=>viewPaste(d.id),300);
    loadStats();
  }catch(ex){toast('Network error');}
  finally{btn.disabled=false;btn.textContent='Create Paste';}
});

// ── View paste ──
async function viewPaste(id){
  try{
    const r=await fetch(API+'/paste/'+id);
    if(!r.ok){toast('Paste not found or expired');return;}
    const p=await r.json();
    document.getElementById('create-section').style.display='none';
    const detail=document.getElementById('detail');
    detail.style.display='block';
    document.getElementById('detail-content').textContent=p.content||'';
    document.getElementById('detail-meta').innerHTML=
      `<span><b>${esc(p.title||'Untitled')}</b></span>`+
      `<span>${esc(p.language||'plain')}</span>`+
      `<span>👁 ${p.views||0} views</span>`+
      `<span>Expires ${fmtExpiry(p.expires_at)}</span>`;
    window.history.pushState({},'','/paste/'+id);
  }catch(ex){toast('Error loading paste');}
}

function showCreate(){
  document.getElementById('detail').style.display='none';
  document.getElementById('create-section').style.display='block';
  window.history.pushState({},'','/');
}

function copyContent(){
  const text=document.getElementById('detail-content').textContent;
  navigator.clipboard.writeText(text).then(()=>toast('Copied!')).catch(()=>toast('Copy failed'));
}

// ── Init ──
loadStats();
initFeed();
setInterval(loadStats,30000);
setInterval(purgeExpiredFromFeed,30000);
connectWS();
// Handle direct URL like /paste/<id>
if(window.location.pathname.startsWith('/paste/')){
  viewPaste(window.location.pathname.replace('/paste/',''));
}
</script>
</body>
</html>"""


def serve_index() raises -> Response:
    """Serve the embedded frontend HTML for GET /.

    Returns:
        200 OK with the full frontend HTML page.
    """
    var r = Response(
        status=Status.OK,
        reason="OK",
        body=_to_bytes(_INDEX_HTML),
    )
    r.headers.set("Content-Type", "text/html; charset=utf-8")
    return r^
