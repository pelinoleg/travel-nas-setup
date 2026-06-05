/* Travel-NAS web dashboard — client. SSE; tiles open detail/power/screen/backup
   pages; fixed-scale sparklines & graphs; docker by project; circular timer. */
'use strict';
const $=s=>document.querySelector(s), $$=s=>[...document.querySelectorAll(s)];
const api=(p,b)=>fetch(p,b?{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(b)}:undefined);
const toast=m=>{const t=$('#toast');t.textContent=m;t.classList.remove('hidden');clearTimeout(t._t);t._t=setTimeout(()=>t.classList.add('hidden'),2500);};
const fmtUp=s=>{const d=s/86400|0,h=s%86400/3600|0,m=s%3600/60|0;return d?`${d}d ${h}h`:h?`${h}h ${m}m`:`${m}m`;};
const TB=b=>b==null?'?':(b>=1e12?(b/1e12).toFixed(2)+' TB':(b/1e9).toFixed(1)+' GB');

const MET={cpu:{label:'CPU %',col:'#3b82f6',max:100,th:[70,85,95]},
  temp:{label:'Temperature °C',col:'#f85149',max:100,th:[60,72,82]},
  mem:{label:'RAM GB',col:'#a371f7',max:null,th:null},
  net_rx:{label:'Download MB/s',col:'#3fb950',max:null,th:null},
  disk:{label:'Disk %',col:'#22d3ee',max:100,th:[75,88,95]}};
let memTotal=8;
const lvl=(m,v)=>{const t=MET[m]&&MET[m].th;if(!t||v==null)return'';return v>=t[2]?'lv-crit':v>=t[1]?'lv-high':v>=t[0]?'lv-warn':'';};
const colorVal=(id,m,v)=>{const e=$('#'+id);if(!e)return;e.classList.remove('lv-warn','lv-high','lv-crit');const c=lvl(m,v);if(c)e.classList.add(c);};
let last={}, activeTab='overview';

/* tabs */
function switchTab(t){$$('#tabs button').forEach(x=>x.classList.toggle('active',x.dataset.tab===t));
  $$('.tab').forEach(x=>x.classList.toggle('active',x.id==='tab-'+t));activeTab=t;onTab(t);}
$$('#tabs button').forEach(b=>b.onclick=()=>switchTab(b.dataset.tab));
function onTab(t){if(t==='system'){loadProc();sysGraphs();}else if(t==='storage'){renderDisks();renderCleanup();}else if(t==='docker')renderProjects();}
setInterval(()=>{const d=new Date();$('#clock').textContent=`${('0'+d.getHours()).slice(-2)}:${('0'+d.getMinutes()).slice(-2)}`;},1000);

/* pages (overlays) */
function openPage(id){$$('.page').forEach(p=>p.classList.add('hidden'));$('#'+id).classList.remove('hidden');
  if(id==='page-power')renderPower();else if(id==='page-backup')renderBackupPage();else if(id==='page-logs')loadLogs();
  else if(id==='page-network')renderNetwork();else if(id==='page-services')renderServices();
  else if(id==='page-thermal')renderThermal();else if(id==='page-yt')renderYT();
  else if(id==='page-configs')renderConfigs();}

/* Configs page (имена/размер, без содержимого — там секреты) */
async function renderConfigs(){try{const r=await(await fetch('/api/configs')).json();
  $('#configs-body').innerHTML='<div class="svc-list">'+r.map(c=>`<div class="svc-item"><span>${c.name}${c.desc?' — <span style="color:var(--mut)">'+c.desc+'</span>':''}</span><span class="u">${(c.size/1024).toFixed(1)} KB</span></div>`).join('')+'</div><div class="note">Edit configs via Filebrowser / SSH (not shown here — they contain secrets).</div>';
  }catch(e){$('#configs-body').innerHTML='error';}}

/* YT-Archiver page */
function renderYT(){const yt=(last.services||{}).yt||{};const R=(k,v)=>`<div class="row"><span class="k">${k}</span><span>${v}</span></div>`;
  $('#yt-info').innerHTML=Object.keys(yt).length?
    R('state',yt.paused?'paused':'running')+R('downloading',yt.downloading||0)+R('pending',yt.pending||0)+R('errors',yt.error||0)+R('max parallel',yt.max_concurrent||1)
    :'<div class="note">YT-Archiver offline (start the stack in Docker).</div>';}
$('#yt-pause').onclick=async()=>{await api('/api/yt',{action:'pause'});toast('paused');setTimeout(renderYT,800);};
$('#yt-resume').onclick=async()=>{await api('/api/yt',{action:'resume'});toast('resumed');setTimeout(renderYT,800);};

/* Network page */
function renderNetwork(){const nw=last.network||{};const R=(k,v)=>`<div class="row"><span class="k">${k}</span><span>${v}</span></div>`;
  const apBig=`<div style="text-align:center;margin-bottom:14px;padding:12px;background:var(--panel);border:1px solid var(--line);border-radius:12px">
    <div class="k">Hotspot SSID</div><div style="font-size:26px;font-weight:700">${nw.ap_ssid||'—'}</div>
    <div class="k" style="margin-top:8px">Password</div><div style="font-size:18px;font-weight:600">${nw.ap_pass||'open'}</div></div>`;
  $('#net-info').innerHTML=apBig+R('hostname',(nw.host||'nas')+'.local')+R('IP',nw.ip||'—')+R('WiFi SSID',nw.ssid||'—')
    +R('signal',nw.signal?nw.signal+' dB':'—')+R('mode',nw.mode==='AP'?'Hotspot (AP)':'Client')
    +R('comitup',nw.comitup||'—')+R('Tailscale',nw.tailscale||'—');}
$('#force-ap').onclick=()=>openModal('Force hotspot',[['Drop WiFi → start AP','force-ap',1]]);

/* Services page */
async function renderServices(){$('#services-body').innerHTML='<div class="h">loading…</div>';
  try{const r=await(await fetch('/api/services')).json();
    $('#services-body').innerHTML='<div class="svc-list">'+r.map((s,i)=>`<div class="svc-item" data-i="${i}"><span>${s.name}</span><span class="u">${s.url.replace('http://','')} ⮕ QR</span></div>`).join('')+'</div>'
      +'<div class="note">Tap a service → QR code to open it on your phone (same network).</div>';
    $$('#services-body .svc-item').forEach(el=>el.onclick=()=>{const s=r[el.dataset.i];showQR(s.name,s.url);});
    $('#svc-v').textContent=r.length;}catch(e){$('#services-body').innerHTML='error';}}

/* Thermal page */
function renderThermal(){const th=(last.services||{}).thermal||{};const R=(k,v)=>`<div class="row"><span class="k">${k}</span><span>${v}</span></div>`;
  $('#thermal-info').innerHTML=R('mode',th.MODE||th.mode||'warn')+R('last temp',(th.last_temp||th.temp||'?')+'°C')
    +R('throttle stage',th.stage||th.level||'none')+R('actions',(th.actions&&th.actions.length)?th.actions.join(', '):'none');}

/* Update page (with live output) */
let updTimer=null;
$('#update-run').onclick=async()=>{$('#update-body').textContent='Starting…';await api('/api/update/run');
  clearInterval(updTimer);updTimer=setInterval(async()=>{try{$('#update-body').textContent=await(await fetch('/api/update/log')).text();
    const b=$('#update-body');b.scrollTop=b.scrollHeight;}catch(e){}},1500);};
const closePages=()=>$$('.page').forEach(p=>p.classList.add('hidden'));
$$('.page .back').forEach(b=>b.onclick=closePages);
$$('[data-open]').forEach(el=>el.onclick=()=>{const o=el.dataset.open;
  if(o==='detail')openDetail(el.dataset.metric);else if(o==='docker-tab')switchTab('docker');else openPage(o);});

/* live ring buffers (5 min @2s) */
const TBUF=[],SPARK={cpu:[],temp:[],mem:[],net_rx:[],disk:[]};
const sparkMax=m=>MET[m].max||(m==='mem'?memTotal:Math.max(1,...SPARK[m],0.1));
function drawSpark(cv,arr,color,max){const w=cv.width=cv.clientWidth*2,h=cv.height=cv.clientHeight*2;
  const x=cv.getContext('2d');x.clearRect(0,0,w,h);if(arr.length<2)return;
  x.beginPath();arr.forEach((v,i)=>{const px=i/(arr.length-1)*w,py=h-Math.min(1,v/max)*(h-6)-3;i?x.lineTo(px,py):x.moveTo(px,py);});
  x.strokeStyle=color;x.lineWidth=2;x.lineJoin='round';x.stroke();x.lineTo(w,h);x.lineTo(0,h);x.closePath();x.fillStyle=color+'1f';x.fill();}
function updateSparks(){$$('.spark').forEach(cv=>{const k=cv.dataset.s;if(SPARK[k])drawSpark(cv,SPARK[k],MET[k].col,sparkMax(k));});}

/* render snapshot */
const chip=(cls,txt)=>`<span class="chip"><span class="dot ${cls}"></span>${txt}</span>`;
function render(d){last=d;const s=d.system||{},st=d.storage||{},nw=d.network||{},sv=d.services||{};
  if(s.mem_total)memTotal=s.mem_total;
  const memPct=s.mem_total?Math.round(s.mem_used/s.mem_total*100):null;
  $('#cpu').textContent=s.cpu??'–';colorVal('cpu','cpu',s.cpu);
  $('#temp').textContent=s.temp??'–';colorVal('temp','temp',s.temp);
  $('#mem').textContent=s.mem_total?s.mem_used:'–';$('#mem-tot').textContent=s.mem_total?'/'+s.mem_total:'';colorVal('mem','disk',memPct);
  $('#net').textContent=`↑${s.net_tx??0}  ↓${s.net_rx??0}`;
  $('#disk').textContent=st.pct??'–';colorVal('disk','disk',st.pct);
  $('#dk').textContent=(sv.projects||[]).filter(p=>p.running===p.total&&p.total).length+'/'+(sv.projects||[]).length;
  $('#power').textContent=s.pmode||'auto';$('#power-sub').textContent=`${s.governor||'?'} · ${s.freq_mhz||0}MHz`;
  $('#uptime').textContent='up '+fmtUp(s.uptime||0);
  // buffers
  TBUF.push(Date.now()/1000|0);
  [['cpu',s.cpu],['temp',s.temp],['mem',s.mem_used],['net_rx',s.net_rx],['disk',st.pct]].forEach(([k,v])=>SPARK[k].push(v==null?0:v));
  if(TBUF.length>150){TBUF.shift();for(const k in SPARK)SPARK[k].shift();}
  updateSparks();
  if(!$('#detail').classList.contains('hidden'))liveDetail();
  // header
  $('#host').textContent=(nw.host||'nas')+'.local';
  $('#ip').textContent=nw.ip&&nw.ip!=='?'?nw.ip:'no network';
  const wc=nw.mode==='AP'?'warn':(nw.ip&&nw.ip!=='?'?'ok':'err');
  const wt=nw.mode==='AP'?`Hotspot ${nw.ssid||''}`:`${nw.ssid||'no wifi'} ${nw.signal?nw.signal+'dB':''}`;
  $('#topchips').innerHTML=chip(wc,wt);
  // disk tile bar + free
  const dbar=$('#disk-bar');if(dbar){dbar.style.width=(st.pct||0)+'%';
    dbar.className=st.pct>=95?'crit':st.pct>=88?'high':st.pct>=75?'warn':'';}
  $('#disk-sub').textContent=st.size?`${(st.used/1e12).toFixed(2)}/${(st.size/1e12).toFixed(2)} TB${st.disk_temp!=null?' · '+st.disk_temp+'°C':''}`:'';
  // power tile color by mode
  const pt=$('#power-tile');if(pt){pt.className='tile';pt.classList.add('pm-'+(s.pmode||'auto'));}
  // wifi tile
  $('#wifi-v').textContent=nw.mode==='AP'?'Hotspot':(nw.ssid||'—');
  $('#wifi-sub').textContent=nw.mode==='AP'?(nw.ap_name||''):`${nw.signal?nw.signal+'dB':''}`;
  // docker tile color
  const proj=sv.projects||[],down=proj.filter(p=>p.running<p.total).length;
  const dke=$('#dk');dke.textContent=`${proj.filter(p=>p.running===p.total&&p.total).length}/${proj.length}`;
  dke.className='tv2';if(down){dke.classList.add('lv-crit');$('#dk-sub').textContent=down+' stopped';}
  else $('#dk-sub').textContent='all up';
  // thermal tile
  const th=sv.thermal||{};$('#thermal-v').textContent=(th.MODE||th.mode||'warn');
  $('#thermal-sub').textContent=th.last_temp?th.last_temp+'°C':(th.temp?th.temp+'°C':'');
  // YT tile
  const yt=sv.yt||{};const ytv=$('#yt-v');
  if(Object.keys(yt).length){ytv.textContent=yt.paused?'paused':`${yt.downloading||0}↓ ${yt.pending||0}⏳`;
    ytv.className='tv2'+(yt.paused?' lv-warn':'');
    $('#yt-sub').textContent=yt.error?yt.error+' errors':(yt.paused?'paused':'queue');}
  else{ytv.textContent='–';$('#yt-sub').textContent='offline';}
  renderAlerts(s,st,sv,nw);
  renderBackups();
  if(!$('#page-power').classList.contains('hidden'))renderPower();
  if(!$('#page-thermal').classList.contains('hidden'))renderThermal();
  if(!$('#page-network').classList.contains('hidden'))renderNetwork();
  if(!$('#page-yt').classList.contains('hidden'))renderYT();}

/* alerts banner */
function renderAlerts(s,st,sv,nw){const a=[];
  if(s.throttled_now)a.push(['crit','⚡ Throttled']);
  if(s.temp>=82)a.push(['crit','🌡 CPU '+s.temp+'°C']);else if(s.temp>=72)a.push(['warn','🌡 '+s.temp+'°C']);
  if(st.mounted===false)a.push(['crit','💾 Disk not mounted']);
  else if(st.pct>=95)a.push(['crit','💾 Disk '+st.pct+'%']);else if(st.pct>=88)a.push(['warn','💾 Disk '+st.pct+'%']);
  if((nw.ip||'?')==='?')a.push(['warn','📡 No network']);
  const nb=sv.nas_backup||{};if((nb.last_status||'')==='failed')a.push(['crit','☁ Backup failed']);
  $('#alerts').innerHTML=a.map(([c,t])=>`<span class="alert ${c}">${t}</span>`).join('');}

function connect(){const es=new EventSource('/api/stream');
  es.onmessage=e=>{try{render(JSON.parse(e.data));applyNight();}catch(_){}};
  es.onerror=()=>{es.close();setTimeout(connect,3000);};}

/* detail overlay */
let dchart,dMetric='cpu',dRange='1h';
$$('#detail-ranges button').forEach(b=>b.onclick=()=>{$$('#detail-ranges button').forEach(x=>x.classList.remove('active'));
  b.classList.add('active');dRange=b.dataset.range;loadDetail();});
function openDetail(m){dMetric=m;$('#detail-title').textContent=MET[m].label;
  $$('.page').forEach(p=>p.classList.add('hidden'));$('#detail').classList.remove('hidden');loadDetail();}
function yrange(m){const mx=MET[m].max||(m==='mem'?memTotal:null);return mx?{range:[0,mx]}:{range:(u,_,max)=>[0,max||1]};}
function makeDChart(data){const el=$('#dchart');el.innerHTML='';
  dchart=new uPlot({width:el.clientWidth||520,height:el.clientHeight||300,cursor:{show:false},legend:{show:false},
    scales:{x:{time:true},y:yrange(dMetric)},
    axes:[{stroke:'#8b949e',grid:{stroke:'#222b38'}},{stroke:'#8b949e',grid:{stroke:'#222b38'},size:44}],
    series:[{},{stroke:MET[dMetric].col,width:2,fill:MET[dMetric].col+'22',points:{show:false}}]},data||[[],[]],el);}
async function loadDetail(){makeDChart();if(dRange==='5m'){liveDetail();return;}
  try{const r=await(await fetch(`/api/history?m=${dMetric}&range=${dRange}`)).json();setDetail(r.t||[],r.v||[]);}catch(e){}}
function liveDetail(){if(dRange!=='5m'||!dchart)return;setDetail(TBUF.slice(),SPARK[dMetric].slice());}
function setDetail(t,v){if(dchart)dchart.setData([t,v]);
  const vv=v.filter(x=>x!=null),cur=vv.length?vv[vv.length-1]:'–';
  const mn=vv.length?Math.min(...vv).toFixed(1):'–',mx=vv.length?Math.max(...vv).toFixed(1):'–',av=vv.length?(vv.reduce((a,b)=>a+b,0)/vv.length).toFixed(1):'–';
  const s=last.system||{},st=last.storage||{},nw=last.network||{};
  const R=(k,val)=>`<div class="row"><span class="k">${k}</span><span>${val}</span></div>`;
  let extra='';
  if(dMetric==='cpu')extra=R('load',(s.load||[]).join(' '))+R('freq',(s.freq_mhz||0)+' MHz')+R('governor',s.governor||'?')+R('mode',s.pmode||'auto');
  else if(dMetric==='temp')extra=R('throttle',s.throttled_now?'YES':'no')+R('disk',st.disk_temp!=null?st.disk_temp+'°C':'—');
  else if(dMetric==='mem')extra=R('used',s.mem_used+' GB')+R('total',s.mem_total+' GB');
  else if(dMetric==='disk')extra=((st.disks||[]).flatMap(d=>d.parts).filter(p=>p.mount).map(p=>R(p.mount,(p.pct??'?')+'%'))).join('');
  else if(dMetric==='net_rx')extra=R('down',s.net_rx+' MB/s')+R('up',s.net_tx+' MB/s')+R('ip',nw.ip||'?')+R('wifi',nw.ssid||'—');
  $('#detail-info').innerHTML=`<div class="dstats">now <b>${cur}</b> · min ${mn} · avg ${av} · max ${mx}</div>${extra}`;}

/* System */
async function loadProc(){try{const r=await(await fetch('/api/processes')).json();
  const tbl=rows=>rows.map(p=>`<tr><td>${p.cmd}</td><td>${p.cpu}%</td><td>${p.mem}%</td></tr>`).join('');
  $('#proc-cpu').innerHTML=tbl(r.cpu||[]);$('#proc-mem').innerHTML=tbl(r.mem||[]);}catch(e){}}
let sysG={};
async function sysGraphs(){for(const[m,id]of[['cpu','g-cpu'],['temp','g-temp'],['mem','g-mem']]){
  try{const r=await(await fetch(`/api/history?m=${m}&range=1h`)).json();const el=$('#'+id);el.innerHTML='';
    sysG[m]=new uPlot({width:el.clientWidth||360,height:el.clientHeight||90,cursor:{show:false},legend:{show:false},
      scales:{x:{time:true},y:yrange(m)},axes:[{stroke:'#8b949e',size:26},{stroke:'#8b949e',size:34}],
      series:[{},{stroke:MET[m].col,width:2,fill:MET[m].col+'22',points:{show:false}}]},[r.t||[],r.v||[]],el);}catch(e){}}}
setInterval(()=>{if(activeTab==='system')loadProc();},5000);

/* Disks */
function renderDisks(){const disks=(last.storage||{}).disks||[];
  $('#disks').innerHTML=disks.map(d=>{const parts=d.parts.filter(p=>p.mount).map(p=>{
    const cl=p.pct>=95?'crit':p.pct>=88?'high':p.pct>=75?'warn':'';
    return `<div class="part">${p.mount} · ${p.label||p.fstype||''} — ${TB(p.used)}/${TB(p.total)} (${p.pct??'?'}%)</div><div class="bar-fill"><i class="${cl}" style="width:${p.pct||0}%"></i></div>`;}).join('')||'<div class="part">not mounted</div>';
    const kc=d.kind==='USB'?'usb':d.kind==='SD'?'sd':'';
    return `<div class="disk"><div class="top"><div><div class="name">${d.name}</div><div class="meta">${d.model||d.kind} · ${TB(d.size)}${d.health&&d.health!='?'?' · '+d.health:''}</div></div><div style="text-align:right"><span class="badge ${kc}">${d.kind}</span>${d.temp!=null?`<div class="temp">${d.temp}<small>°C</small></div>`:''}</div></div>${parts}</div>`;}).join('')||'<div>no disks</div>';}

/* Docker */
function renderProjects(){const pr=(last.services||{}).projects||[];const ic=n=>`<svg class="ic"><use href="#${n}"/></svg>`;
  $('#projects').innerHTML=pr.map(p=>{const ok=p.running===p.total&&p.total>0;
    return `<div class="proj"><div class="top"><span class="name">${p.project}</span><span class="st"><span class="dot ${ok?'ok':p.running?'warn':'err'}"></span>${p.running}/${p.total}</span></div><div class="btns"><button class="start" data-p="${p.project}" data-a="start">${ic('i-play')}</button><button data-p="${p.project}" data-a="restart">${ic('i-restart')}</button><button class="stop" data-p="${p.project}" data-a="stop">${ic('i-stop')}</button></div></div>`;}).join('')||'<div>no projects</div>';
  $$('#projects button').forEach(b=>b.onclick=async()=>{toast(b.dataset.a+' '+b.dataset.p+'…');await api('/api/docker',{project:b.dataset.p,action:b.dataset.a});
    setTimeout(()=>api('/api/snapshot').then(r=>r.json()).then(d=>{last=d;if(activeTab==='docker')renderProjects();}),1800);});}

/* Backups: progress routed photo↔nas, shown as tile background; auto-open page */
const ic=n=>`<svg class="ic"><use href="#${n}"/></svg>`;
function whichBackup(pr){if(!pr||!pr.active)return null;
  return ((pr.target||'')+(pr.source||'')).includes('usb-imports')||pr.device?'photo':'nas';}
let lastBkActive=null;
function bkTile(icon,title,sub,pct){const bg=pct!=null?`style="background:linear-gradient(90deg,rgba(59,130,246,.28) ${pct}%,transparent ${pct}%)"`:'';
  return `<div class="bk" data-open="page-backup" ${bg}>${icon}<div style="flex:1"><div class="t">${title}</div><div class="s">${sub}</div></div></div>`;}
function renderBackups(){const sv=last.services||{},nb=sv.nas_backup||{},pr=sv.progress||{},ph=sv.photo||{};
  const w=whichBackup(pr);
  const pSub=w==='photo'?`${pr.label||'card'} · ${pr.percent||0}% · ${pr.files_done||0}/${pr.files_total||'?'} files`:(ph.last?'last '+ph.last:'idle');
  const nSub=w==='nas'?`${pr.percent||0}% · ${pr.speed||''} · eta ${pr.eta||'?'}`:(nb.last_status||nb.status||'not configured');
  $('#backups').innerHTML=bkTile(ic('i-camera'),'Photo import',pSub,w==='photo'?pr.percent||0:null)
    +bkTile(ic('i-cloud'),'NAS backup',nSub,w==='nas'?pr.percent||0:null);
  $$('#backups .bk').forEach(b=>b.onclick=()=>openPage('page-backup'));
  if(w&&lastBkActive!==w){lastBkActive=w;openPage('page-backup');}   // авто-переход при старте
  if(!w)lastBkActive=null;
  if(!$('#page-backup').classList.contains('hidden'))renderBackupPage();}
function renderBackupPage(){const sv=last.services||{},nb=sv.nas_backup||{},pr=sv.progress||{},ph=sv.photo||{};
  const w=whichBackup(pr);const R=(k,v)=>`<div class="row"><span class="k">${k}</span><span>${v}</span></div>`;
  const bar=p=>`<div class="bar-fill"><i style="width:${p||0}%"></i></div>`;
  const big=(pct,done,total)=>`<div class="bigstat"><div><div class="n">${pct||0}%</div><div class="l">progress</div></div>`
    +`<div><div class="n">${done||0}<span style="font-size:22px;color:var(--mut)"> / ${total||'?'}</span></div><div class="l">files</div></div></div>`;
  let html='';
  if(w==='photo')html+=`<div class="h">Photo import — running</div>${big(pr.percent,pr.files_done,pr.files_total)}${bar(pr.percent)}<div class="sideinfo">${R('card',pr.label||'?')}${R('speed',pr.speed||'?')}${R('eta',pr.eta||'?')}${R('to',(pr.target||'usb-imports').split('/').pop())}</div>`;
  else html+=`<div class="h">Photo import (SD/USB)</div><div class="sideinfo">${R('last import',ph.last||'—')}${R('mode','auto on card insert')}</div>`;
  html+='<div class="h" style="margin-top:16px">NAS backup</div>';
  if(w==='nas')html+=`${big(pr.percent,pr.files_done,pr.files_total)}${bar(pr.percent)}<div class="sideinfo">${R('speed',pr.speed||'?')}${R('eta',pr.eta||'?')}</div><button id="bk-stop" class="wide" style="color:var(--crit)">${ic('i-stop')}Stop backup</button>`;
  else html+=`<div class="sideinfo">${R('status',nb.last_status||nb.status||'not configured')}${R('last run',nb.last_run||'—')}</div><button id="bk-run" class="wide">${ic('i-cloud')}Run NAS backup</button>`;
  $('#backup-body').innerHTML=html;
  const run=$('#bk-run'),stop=$('#bk-stop');
  if(run)run.onclick=()=>{doAction('nas-backup');toast('backup started');};
  if(stop)stop.onclick=()=>{doAction('nas-stop');toast('stopping');};}
/* Storage cleanup (usb-imports) */
async function renderCleanup(){try{const r=await(await fetch('/api/imports')).json();
  $('#cleanup').innerHTML=`<div class="h" style="margin-top:12px">Photo imports — ${TB(r.total)} total</div><div class="svc-list">`
    +r.items.map(i=>`<div class="svc-item"><span>${i.name} · ${TB(i.size)}</span><button class="del" data-n="${i.name}">${ic('i-stop')}Delete</button></div>`).join('')+'</div>';
  $$('#cleanup .del').forEach(b=>b.onclick=()=>openModal('Delete import?',[['Delete '+b.dataset.n,'__del:'+b.dataset.n,1]]));}catch(e){}}
async function delImport(name){await api('/api/imports/delete',{name});toast('deleted');renderCleanup();}

/* Logs */
async function loadLogs(){$('#logs-body').textContent='loading…';
  try{$('#logs-body').textContent=await(await fetch('/api/logs')).text();const b=$('#logs-body');b.scrollTop=b.scrollHeight;}catch(e){$('#logs-body').textContent='error';}}
$('#logs-refresh').onclick=loadLogs;

/* Power page */
const MODEDESC={auto:'Auto — system picks governor by temp/throttle (saver when hot).',
  normal:'Normal — ondemand governor, up to max clock.',saver:'Saver — powersave, clock pinned to minimum.'};
function renderPower(){const s=last.system||{},pm=s.pmode||'auto';
  $$('#powermode button').forEach(b=>b.classList.toggle('active',b.dataset.mode===pm));
  $('#mode-desc').textContent=MODEDESC[pm]||'';
  const R=(k,v)=>`<div class="row"><span class="k">${k}</span><span>${v}</span></div>`;
  $('#power-info').innerHTML=R('mode',pm)+R('governor',s.governor||'?')+R('frequency',(s.freq_mhz||0)+' MHz')
    +R('CPU temp',(s.temp??'?')+'°C')+R('throttled',s.throttled_now?'YES ⚠':'no')+R('load',(s.load||[]).join(' '));}
$$('#powermode button').forEach(b=>b.onclick=()=>{doAction('power-mode',{mode:b.dataset.mode});setTimeout(renderPower,800);});
$$('#boost-seg button').forEach(b=>b.onclick=()=>{doAction('cpu-boost',{min:+b.dataset.min});toast('CPU boost '+b.dataset.min+'m');});

/* actions / modal */
$('#btn-power').onclick=()=>openModal('Power',[['Reboot','reboot',1],['Shut down','poweroff',1]]);
function openModal(title,btns){$('#modal-title').textContent=title;$('#modal-body').innerHTML='';
  btns.forEach(([l,a,dg])=>{const b=document.createElement('button');b.textContent=l;if(dg)b.className='danger';b.onclick=()=>{closeModal();doAction(a);};$('#modal-body').appendChild(b);});
  $('#modal').classList.remove('hidden');}
const closeModal=()=>$('#modal').classList.add('hidden');
$('#modal-cancel').onclick=closeModal;
async function doAction(name,body){if(name.startsWith('__del:'))return delImport(name.slice(6));
  toast('…');try{const r=await(await api('/api/action/'+name,body||{})).json();toast(r.ok||r.detached?'OK':('Error: '+(r.err||r.error||'')));}catch(e){toast('Network error');}}
function showQR(name,url){$('#modal-title').textContent=name;
  const qr=qrcode(0,'M');qr.addData(url);qr.make();
  $('#modal-body').innerHTML=`<div style="background:#fff;padding:10px;border-radius:10px;display:inline-block">${qr.createSvgTag({cellSize:5,margin:1})}</div><div style="margin-top:10px;color:var(--mut);font-size:13px">${url}</div>`;
  $('#modal').classList.remove('hidden');}
$('#btn-exit').onclick=()=>doAction('screen',{exit_kiosk:true});

/* screen page controls */
const LS=localStorage,br=$('#brightness'),bv=$('#brightness-val');
function setBrightness(v,save){bv.textContent=v+'%';api('/api/action/screen',{brightness:v+'%'});if(save)LS.brightness=v;}
br.value=LS.brightness||80;bv.textContent=br.value+'%';br.oninput=()=>setBrightness(br.value,true);
$('#screen-timeout').value=LS.screenTimeout||'300';$('#screen-timeout').onchange=e=>LS.screenTimeout=e.target.value;
['night-from','night-to','night-level'].forEach(id=>{const el=$('#'+id);if(LS[id])el.value=LS[id];el.onchange=()=>{LS[id]=el.value;nightApplied=null;};});
$('#rotate-apply').onclick=()=>{const v=$('#rotate').value;if(v)doAction('screen',{rotate:v});};

let lastAct=Date.now(),screenOff=false;
['pointerdown','touchstart','keydown'].forEach(ev=>addEventListener(ev,()=>{lastAct=Date.now();
  if(screenOff){screenOff=false;api('/api/action/screen',{backlight:'on'});setBrightness(br.value);}},{passive:true}));
const RING=2*Math.PI*16;
setInterval(()=>{const to=+($('#screen-timeout').value||0),ring=$('#ring'),cd=$('#screen-cd');
  if(!to){cd.textContent='∞';ring.style.strokeDashoffset=0;return;}
  if(screenOff){cd.textContent='zZ';ring.style.strokeDashoffset=RING;return;}
  const rem=Math.max(0,to-(Date.now()-lastAct)/1000);
  cd.textContent=rem>=60?Math.ceil(rem/60)+'m':Math.ceil(rem)+'s';
  ring.style.strokeDasharray=RING;ring.style.strokeDashoffset=RING*(1-rem/to);
  if(rem<=0){screenOff=true;api('/api/action/screen',{backlight:'off'});}},1000);
let nightApplied=null;
function applyNight(){const f=$('#night-from').value,t=$('#night-to').value;if(!f||!t)return;
  const d=new Date(),cur=('0'+d.getHours()).slice(-2)+':'+('0'+d.getMinutes()).slice(-2);
  const inWin=f<t?(cur>=f&&cur<t):(cur>=f||cur<t),target=inWin?+$('#night-level').value:+br.value;
  if(!screenOff&&target!==nightApplied){nightApplied=target;api('/api/action/screen',{brightness:target+'%'});}}

/* drag-to-scroll пальцем/мышью (нативный тач-скролл в kiosk ненадёжен) */
function dragScroll(el){let down=false,sy=0,stp=0,moved=false;
  el.addEventListener('pointerdown',e=>{down=true;sy=e.clientY;stp=el.scrollTop;moved=false;});
  el.addEventListener('pointermove',e=>{if(!down)return;const dy=e.clientY-sy;
    if(Math.abs(dy)>6)moved=true;if(moved)el.scrollTop=stp-dy;});
  const end=()=>down=false;
  ['pointerup','pointercancel','pointerleave'].forEach(ev=>el.addEventListener(ev,end));
  el.addEventListener('click',e=>{if(moved){e.stopPropagation();e.preventDefault();}},true);}
['.tab','.pbody','#logs-body','#update-body','.sideinfo'].forEach(sel=>$$(sel).forEach(dragScroll));

connect();setBrightness(br.value);
fetch('/api/services').then(r=>r.json()).then(s=>{$('#svc-v').textContent=s.length;}).catch(()=>{});
