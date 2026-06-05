/* Travel-NAS web dashboard — client. */
'use strict';
const $=s=>document.querySelector(s), $$=s=>[...document.querySelectorAll(s)];
const api=(p,b)=>fetch(p,b?{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(b)}:undefined);
const toast=m=>{const t=$('#toast');t.textContent=m;t.classList.remove('hidden');clearTimeout(t._t);t._t=setTimeout(()=>t.classList.add('hidden'),2500);};
const fmtUp=s=>{const d=s/86400|0,h=s%86400/3600|0,m=s%3600/60|0;return d?`${d}d ${h}h`:h?`${h}h ${m}m`:`${m}m`;};
const TB=b=>b==null?'?':(b>=1e12?(b/1e12).toFixed(2)+' TB':b>=1e9?(b/1e9).toFixed(1)+' GB':(b/1e6).toFixed(0)+' MB');
const ic=n=>`<svg class="ic"><use href="#${n}"/></svg>`;

const MET={cpu:{label:'CPU %',col:'#3b82f6',max:100,th:[70,85,95]},
  temp:{label:'Temperature °C',col:'#f85149',max:100,th:[60,72,82]},
  mem:{label:'RAM GB',col:'#a371f7',max:null,th:null},
  net_rx:{label:'Download',col:'#3fb950',max:null,th:null},
  disk:{label:'Disk %',col:'#22d3ee',max:100,th:[75,88,95]},
  dtemp:{label:'Disk temp °C',col:'#fb923c',max:70,th:[45,52,58]}};
const fmtNet=k=>{k=k||0;return k>=1000?(k/1000).toFixed(1)+' MB/s':Math.round(k)+' KB/s';};
let memTotal=8, last={}, activeTab='overview';
const lvl=(m,v)=>{const t=MET[m]&&MET[m].th;if(!t||v==null)return'';return v>=t[2]?'lv-crit':v>=t[1]?'lv-high':v>=t[0]?'lv-warn':'';};
const colorVal=(id,m,v)=>{const e=$('#'+id);if(!e)return;e.classList.remove('lv-warn','lv-high','lv-crit');const c=lvl(m,v);if(c)e.classList.add(c);};

/* tabs */
function switchTab(t){$$('#tabs button').forEach(x=>x.classList.toggle('active',x.dataset.tab===t));
  $$('.tab').forEach(x=>x.classList.toggle('active',x.id==='tab-'+t));activeTab=t;
  if(t==='storage')renderDisks();else if(t==='apps')renderApps();else if(t==='settings')loadPiBackup();}
$$('#tabs button').forEach(b=>b.onclick=()=>switchTab(b.dataset.tab));
setInterval(()=>{const d=new Date();$('#clock').textContent=`${('0'+d.getHours()).slice(-2)}:${('0'+d.getMinutes()).slice(-2)}`;},1000);

/* pages */
function openPage(id){$$('.page').forEach(p=>p.classList.add('hidden'));$('#'+id).classList.remove('hidden');
  ({'page-power':renderPower,'page-photo':renderPhotoPage,'page-nas':renderNasPage,'page-logs':loadLogs,'page-network':()=>{renderNetwork();loadTsList();},
    'page-services':renderServices,'page-yt':renderYT,'page-configs':renderConfigs,'page-today':renderToday,
    'page-failed':renderFailed,'page-docker':renderProjects,'page-disk':renderDiskPage}[id]||(()=>{}))();}
const closePages=()=>$$('.page').forEach(p=>p.classList.add('hidden'));
$$('.page .back').forEach(b=>b.onclick=closePages);
$$('[data-open]').forEach(el=>el.onclick=()=>{const o=el.dataset.open;
  if(o==='detail')openDetail(el.dataset.metric);else openPage(o);});

/* sparklines */
const TBUF=[],SPARK={cpu:[],temp:[],mem:[],net_rx:[],disk:[],dtemp:[]};
const sparkMax=(m,arr)=>MET[m].max||(m==='mem'?memTotal:Math.max(1,...arr,0.1));
const sparkWin=m=>+(localStorage['spark_'+m]||300);  /* сек, настраивается в Settings */
function winStart(m){const w=sparkWin(m),now=TBUF.length?TBUF[TBUF.length-1]:0;let i=0;while(i<TBUF.length&&TBUF[i]<now-w)i++;return i;}
function drawSpark(cv,arr,color,max){const w=cv.width=cv.clientWidth*2,h=cv.height=cv.clientHeight*2;
  const x=cv.getContext('2d');x.clearRect(0,0,w,h);if(arr.length<2)return;
  x.beginPath();arr.forEach((v,i)=>{const px=i/(arr.length-1)*w,py=h-Math.min(1,v/max)*(h-6)-3;i?x.lineTo(px,py):x.moveTo(px,py);});
  x.strokeStyle=color;x.lineWidth=2;x.lineJoin='round';x.stroke();x.lineTo(w,h);x.lineTo(0,h);x.closePath();x.fillStyle=color+'33';x.fill();}
const SPARKHIST={};  /* metric -> {t,v} для длинных окон (>15м) из history-sqlite */
const histRange=w=>w<=3600?'1h':w<=86400?'24h':'7d';
async function fetchSparkHist(m){if(sparkWin(m)<=900)return;
  try{const r=await(await fetch(`/api/history?m=${m}&range=${histRange(sparkWin(m))}`)).json();SPARKHIST[m]={t:r.t||[],v:r.v||[]};updateSparks();}catch(e){}}
function heatColor(k,v){const t=MET[k].th;if(!t)return MET[k].col;return v>=t[2]?'#f85149':v>=t[1]?'#f0883e':v>=t[0]?'#d29922':'#3fb950';}
function updateSparks(){$$('.spark').forEach(cv=>{const k=cv.dataset.s;if(!SPARK[k])return;const w=sparkWin(k);let arr;
  if(w<=900)arr=SPARK[k].slice(winStart(k));
  else{const h=SPARKHIST[k];if(h&&h.t.length){const now=h.t[h.t.length-1];let i=0;while(i<h.t.length&&h.t[i]<now-w)i++;arr=h.v.slice(i).filter(x=>x!=null);}else arr=SPARK[k].slice(winStart(k));}
  const col=(k==='temp'||k==='dtemp')?heatColor(k,arr.length?arr[arr.length-1]:0):MET[k].col;
  drawSpark(cv,arr,col,sparkMax(k,arr));});}
setInterval(()=>['cpu','temp','mem','net_rx','disk','dtemp'].forEach(m=>{if(sparkWin(m)>900)fetchSparkHist(m);}),60000);

/* render */
const chip=(cls,txt)=>`<span class="chip"><span class="dot ${cls}"></span>${txt}</span>`;
function whichBackup(pr){if(!pr||!pr.active)return null;return pr.kind||'photo';}
function render(d){last=d;const s=d.system||{},st=d.storage||{},nw=d.network||{},sv=d.services||{};
  if(s.mem_total)memTotal=s.mem_total;
  const memPct=s.mem_total?Math.round(s.mem_used/s.mem_total*100):null;
  $('#cpu').textContent=s.cpu!=null?Math.round(s.cpu):'–';colorVal('cpu','cpu',s.cpu);
  $('#temp').textContent=s.temp!=null?Math.round(s.temp):'–';colorVal('temp','temp',s.temp);
  $('#mem').textContent=s.mem_total?(+s.mem_used).toFixed(1):'–';$('#mem-tot').textContent=s.mem_total?'/'+Math.round(s.mem_total):'';colorVal('mem','disk',memPct);
  {const tx=s.net_tx||0,rx=s.net_rx||0;
   $('#net').innerHTML=`<span class="dl ${rx>=1?'on':''}">${ic('i-dl')}${fmtNet(rx)}</span><span class="ul ${tx>=1?'on':''}">${ic('i-ul')}${fmtNet(tx)}</span>`;}
  $('#disk').textContent=st.pct??'–';colorVal('disk','disk',st.pct);
  const dbar=$('#disk-bar');if(dbar){dbar.style.width=(st.pct||0)+'%';dbar.className=st.pct>=95?'crit':st.pct>=88?'high':st.pct>=75?'warn':'';}
  $('#disk-sub').textContent=st.size?`${(st.used/1e12).toFixed(2)} / ${(st.size/1e12).toFixed(2)} TB`:'';
  const dtemp=$('#disk-temp'),dt=st.disk_temp;
  if(dt!=null){dtemp.textContent=dt+'°';dtemp.className='dtemp '+(dt>=58?'crit':dt>=52?'high':dt>=45?'warn':'');}else dtemp.textContent='';
  const pt=$('#power-tile');if(pt){pt.className='tile';pt.classList.add('pm-'+(s.pmode||'auto'));}
  $('#power').textContent=s.pmode||'auto';$('#power-sub').textContent=s.governor||'?';
  {const fr=$('#freq');if(fr){fr.textContent=s.freq_mhz||'–';const frac=(s.freq_mhz||0)/(s.freq_max||1800);
    fr.className=frac>=.9?'f-full':frac>=.6?'f-mid':frac>=.35?'f-low':'f-min';}}
  $('#uptime').textContent='up '+fmtUp(s.uptime||0);
  {const ap=nw.mode==='AP',sig=nw.signal,q=sig!=null?Math.max(0,Math.min(100,2*(sig+100))):null;  // dBm→~%
   $('#wifi-v').textContent=ap?'Hotspot':(nw.ssid||'—');
   $('#wifi-sub').innerHTML=ap?(nw.ap_ssid||nw.ap_name||''):`${q!=null?ic('i-net')+' '+q+'%':''} ${nw.ip&&nw.ip!=='?'?'· '+nw.ip:'(no ip)'}`+(nw.ts_up?' · TS':'');}
  // docker tile — проекты + контейнеры
  const proj=sv.projects||[],down=proj.filter(p=>p.running<p.total).length;
  const totC=proj.reduce((a,p)=>a+p.total,0),runC=proj.reduce((a,p)=>a+p.running,0);
  $('#dk').textContent=`${proj.filter(p=>p.running===p.total&&p.total).length}/${proj.length}`;
  $('#dk').className='tv2'+(down?' lv-crit':'');
  $('#dk-sub').textContent=down?down+' stopped: '+proj.filter(p=>p.running<p.total).map(p=>p.project).join(', '):`${runC}/${totC} containers up`;
  // yt tile
  const yt=sv.yt||{};
  if(Object.keys(yt).length){$('#yt-v').textContent=(yt.videos||0)+' vids';
    $('#yt-sub').textContent=`${TB(yt.total_bytes)}${yt.music?' · '+yt.music+' mus':''}${yt.paused?' · paused':(yt.downloading?' · '+yt.downloading+' dl':'')}`;}
  else{$('#yt-v').textContent='–';$('#yt-sub').textContent='offline';}
  // backups tiles (photo/nas раздельно)
  renderBackupTiles(sv);
  // buffers + sparks
  TBUF.push(Date.now()/1000|0);
  [['cpu',s.cpu],['temp',s.temp],['mem',s.mem_used],['net_rx',s.net_rx],['disk',st.pct],['dtemp',st.disk_temp]].forEach(([k,v])=>SPARK[k].push(v==null?0:v));
  if(TBUF.length>460){TBUF.shift();for(const k in SPARK)SPARK[k].shift();}
  updateSparks();
  if(!$('#detail').classList.contains('hidden'))liveDetail();
  // header + chips
  $('#host').textContent=(nw.host||'nas')+'.local';
  $('#ip').textContent=nw.ip&&nw.ip!=='?'?nw.ip:'no network';
  const wc=nw.mode==='AP'?'warn':(nw.ip&&nw.ip!=='?'?'ok':'err');
  $('#topchips').innerHTML=chip(wc,nw.mode==='AP'?`Hotspot ${nw.ssid||''}`:`${nw.ssid||'no wifi'} ${nw.signal?nw.signal+'dB':''}`);
  if($('#net-url'))$('#net-url').textContent=`http://${(nw.host||'nas')}.local:8090 · http://${nw.ip||'?'}:8090`;
  {const nf=$('#night-from').value,nt=$('#night-to').value;
   $('#screen-sub').innerHTML=`<span>${ic('i-sun')} ${br.value}%</span>${nf&&nt?`<span>${ic('i-moon')} ${nf}–${nt}</span>`:''}`;}
  renderAlerts(s,st,sv,nw);
  // live-обновление только лёгких частей открытой страницы (без полного rebuild → нет дёрганья)
  if(!$('#page-power').classList.contains('hidden'))renderPower();
  updateBackupLive();}

function renderAlerts(s,st,sv,nw){const a=[];
  if(s.throttled_now)a.push(['crit','i-zap','Throttled']);
  if(s.temp>=82)a.push(['crit','i-thermo','CPU '+s.temp+'°C']);else if(s.temp>=72)a.push(['warn','i-thermo',s.temp+'°C']);
  if(st.mounted===false)a.push(['crit','i-disk','Disk not mounted']);
  else if(st.pct>=95)a.push(['crit','i-disk','Disk '+st.pct+'%']);else if(st.pct>=88)a.push(['warn','i-disk','Disk '+st.pct+'%']);
  if((nw.ip||'?')==='?')a.push(['warn','i-net','No network']);
  const nb=sv.nas_backup||{};if((nb.last_status||'')==='failed')a.push(['crit','i-cloud','Backup failed']);
  $('#alerts').innerHTML=a.map(([c,i,t])=>`<span class="alert ${c}">${ic(i)}${t}</span>`).join('');
  $('#lastrow').style.display=a.length?'none':'';}   // alerts на всю ширину → прячем последний ряд

/* SSE */
function connect(){const es=new EventSource('/api/stream');
  es.onmessage=e=>{try{render(JSON.parse(e.data));applyNight();}catch(_){}};
  es.onerror=()=>{es.close();setTimeout(connect,3000);};}

/* detail (graph + processes for cpu/mem) */
let dchart,dMetric='cpu',dRange='1h';
$$('#detail-ranges button').forEach(b=>b.onclick=()=>{$$('#detail-ranges button').forEach(x=>x.classList.remove('active'));b.classList.add('active');dRange=b.dataset.range;loadDetail();});
function openDetail(m){dMetric=m;$('#detail-title').textContent=MET[m].label;closePages();$('#detail').classList.remove('hidden');loadDetail();
  $('#detail-proc').innerHTML='';if(m==='cpu'||m==='mem')loadDetailProc(m);}
function yrange(m){const mx=MET[m].max||(m==='mem'?memTotal:null);return mx?{range:[0,mx]}:{range:(u,_,mx2)=>[0,mx2||1]};}
function makeDChart(data){const el=$('#dchart');el.innerHTML='';
  dchart=new uPlot({width:el.clientWidth||500,height:el.clientHeight||260,cursor:{show:false},legend:{show:false},
    scales:{x:{time:true},y:yrange(dMetric)},axes:[{stroke:'#8b949e',grid:{stroke:'#222b38'}},{stroke:'#8b949e',grid:{stroke:'#222b38'},size:44}],
    series:[{},{stroke:MET[dMetric].col,width:2,fill:MET[dMetric].col+'22',points:{show:false}}]},data||[[],[]],el);}
async function loadDetail(){makeDChart();if(dRange==='5m'){liveDetail();return;}
  try{const r=await(await fetch(`/api/history?m=${dMetric}&range=${dRange}`)).json();setDetail(r.t||[],r.v||[]);}catch(e){}}
function liveDetail(){if(dRange!=='5m'||!dchart)return;setDetail(TBUF.slice(),SPARK[dMetric].slice());}
function setDetail(t,v){if(dchart)dchart.setData([t,v]);const vv=v.filter(x=>x!=null);
  const cur=vv.length?vv[vv.length-1]:'–',mn=vv.length?Math.min(...vv).toFixed(1):'–',mx=vv.length?Math.max(...vv).toFixed(1):'–',av=vv.length?(vv.reduce((a,b)=>a+b,0)/vv.length).toFixed(1):'–';
  const s=last.system||{},nw=last.network||{},st=last.storage||{},R=(k,vl)=>`<div class="row"><span class="k">${k}</span><span>${vl}</span></div>`;
  let extra='';
  if(dMetric==='cpu')extra=R('Load avg (1/5/15m)',(s.load||[]).join(' / '))+R('Frequency',(s.freq_mhz||0)+' MHz')+R('Governor',s.governor||'?');
  else if(dMetric==='temp')extra=R('Throttled',s.throttled_now?'YES':'no')+R('Disk temp',st.disk_temp!=null?st.disk_temp+'°C':'—');
  else if(dMetric==='mem')extra=R('Used',(+s.mem_used).toFixed(1)+' GB')+R('Total',Math.round(s.mem_total)+' GB');
  else if(dMetric==='net_rx')extra=R('Download',fmtNet(s.net_rx))+R('Upload',fmtNet(s.net_tx))+R('IP',nw.ip||'?');
  else if(dMetric==='disk')extra=R('Used',TB(st.used))+R('Free',TB(st.avail))+R('Temp',(st.disk_temp||'?')+'°C');
  const stat=(n,l)=>`<div class="dstat"><div class="dn">${n}</div><div class="dl">${l}</div></div>`;
  $('#detail-info').innerHTML=`<div class="dstats">${stat(cur,'now')}${stat(mn,'min')}${stat(av,'avg')}${stat(mx,'max')}</div>${extra}`;}
async function loadDetailProc(m){try{const r=await(await fetch('/api/processes')).json();const isMem=m==='mem',rows=(isMem?r.mem:r.cpu)||[];
  $('#detail-proc').innerHTML=`<tr><th>Top processes</th><th>${isMem?'RAM':'CPU'}</th></tr>`
    +rows.map(p=>`<tr><td>${p.cmd}</td><td>${isMem?p.mem:p.cpu}%</td></tr>`).join('');}catch(e){}}
setInterval(()=>{if(!$('#detail').classList.contains('hidden')&&(dMetric==='cpu'||dMetric==='mem'))loadDetailProc(dMetric);},5000);

/* Docker (page) */
function renderProjects(){const pr=(last.services||{}).projects||[];
  $('#projects').innerHTML=pr.map(p=>{const ok=p.running===p.total&&p.total>0;
    return `<div class="proj"><div class="top"><span class="name">${p.project}</span><span class="st"><span class="dot ${ok?'ok':p.running?'warn':'err'}"></span>${p.running}/${p.total}</span></div><div class="btns"><button class="start" data-p="${p.project}" data-a="start">${ic('i-play')}</button><button data-p="${p.project}" data-a="restart">${ic('i-restart')}</button><button class="stop" data-p="${p.project}" data-a="stop">${ic('i-stop')}</button></div></div>`;}).join('')||'<div>no projects</div>';
  $$('#projects button').forEach(b=>b.onclick=async()=>{toast(b.dataset.a+' '+b.dataset.p+'…');await api('/api/docker',{project:b.dataset.p,action:b.dataset.a});
    setTimeout(()=>api('/api/snapshot').then(r=>r.json()).then(d=>{last=d;renderProjects();}),1800);});}

/* Apps tab: launcher of service UIs (tap → QR) */
async function renderApps(){try{const r=await(await fetch('/api/services')).json();
  $('#apps-grid').innerHTML=r.map((s,i)=>`<div class="appcard" data-i="${i}"><img class="appico" src="/api/appicon?u=${encodeURIComponent(s.url)}" onerror="this.style.display='none';this.nextElementSibling.style.display='block'"><svg class="ic appico" style="display:none"><use href="#i-grid"/></svg><div class="an">${s.name}</div><div class="au">${s.url.replace('http://','')}</div></div>`).join('')||'<div class="note">нет сервисов (поставь docker-стеки)</div>';
  $$('#apps-grid .appcard').forEach(el=>el.onclick=()=>{const s=r[el.dataset.i];openApp(s.name,s.url);});}catch(e){$('#apps-grid').innerHTML='error';}}
function openApp(name,url){$('#appframe-title').textContent=name;$('#appframe-iframe').src=url;
  $('#appframe-qr').onclick=()=>showQR(name,url);$('#appframe').classList.remove('hidden');}
$('#appframe-back').onclick=()=>{$('#appframe-iframe').src='about:blank';$('#appframe').classList.add('hidden');};
function showQR(name,url){$('#modal-title').textContent=name;const qr=qrcode(0,'M');qr.addData(url);qr.make();
  $('#modal-body').innerHTML=`<div style="background:#fff;padding:10px;border-radius:10px;display:inline-block">${qr.createSvgTag({cellSize:5,margin:1})}</div><div style="margin-top:10px;color:var(--mut);font-size:13px">${url}</div>`;
  $('#modal').classList.remove('hidden');}
function renderServices(){renderApps();}   /* page-services не используется, но не падаем */

/* Disks */
function renderDisks(){const disks=(last.storage||{}).disks||[];
  $('#disks').innerHTML=disks.map(d=>{const parts=d.parts.filter(p=>p.mount).map(p=>{const cl=p.pct>=95?'crit':p.pct>=88?'high':p.pct>=75?'warn':'';
    return `<div class="part">${p.mount} · ${p.label||p.fstype||''} — ${TB(p.used)}/${TB(p.total)} (${p.pct??'?'}%)</div><div class="bar-fill"><i class="${cl}" style="width:${p.pct||0}%"></i></div>`;}).join('')||'<div class="part">not mounted</div>';
    const mounts=d.parts.map(p=>p.mount),role=mounts.includes('/')?'system':(mounts.includes('/mnt/storage')?'storage':'removable');
    const rl={system:'SYSTEM · microSD',storage:'STORAGE · main',removable:'REMOVABLE'}[role];
    return `<div class="disk"><div class="top"><div><div class="name">${d.name} <span style="color:var(--mut);font-weight:400;font-size:12px">${d.kind}</span></div><div class="meta">${d.model||''} ${TB(d.size)}${d.health&&d.health!='?'?' · '+d.health:''}</div></div><div style="text-align:right"><span class="badge ${role}">${rl}</span>${d.temp!=null?`<div class="temp">${d.temp}<small>°C</small></div>`:''}</div></div>${parts}</div>`;}).join('')||'<div>no disks</div>';}

/* Backups */
function bkbg(pct){return pct!=null?`background:linear-gradient(90deg,rgba(59,130,246,.28) ${pct}%,transparent ${pct}%)`:'';}
function renderBackupTiles(sv){const nb=sv.nas_backup||{},pr=sv.progress||{},ph=sv.photo||{},w=whichBackup(pr);
  const pt=$('#bk-photo'),nt=$('#bk-nas');
  $('#photo-v').textContent=w==='photo'?(pr.percent||0)+'%':(ph.files?ph.files+' files':'idle');
  $('#photo-sub').textContent=w==='photo'?`${pr.files_done||0}/${pr.files_total||'?'} files`:(ph.bytes?TB(ph.bytes)+(ph.last?' · '+ph.last:''):(ph.last?'last '+ph.last:'—'));
  pt.setAttribute('style',w==='photo'?bkbg(pr.percent):'');
  $('#nas-v').textContent=w==='nas'?(pr.percent||0)+'%':(nb.last_status||nb.status||'idle');
  const sched=sv.nas_sched&&sv.nas_sched!=='off'?sv.nas_sched:null;
  $('#nas-sub').textContent=w==='nas'?`${pr.speed||''} eta ${pr.eta||'?'}`:(sched?'auto '+sched:(nb.last_run?'last '+nb.last_run:'manual'));
  nt.setAttribute('style',w==='nas'?bkbg(pr.percent):'');}
const bkCard=(icon,title,body)=>`<div class="bkcard">${icon}<div class="bkc"><div class="bkt">${title}</div>${body}</div></div>`;
const bkProg=pr=>`<div class="bkbar"><i id="bk-bar" style="width:${pr.percent||0}%"></i></div><div class="bks"><b id="bk-pct">${pr.percent||0}%</b> · <span id="bk-files">${pr.files_done||0}/${pr.files_total||'?'}</span> files · <span id="bk-speed">${pr.speed||'…'}</span> · eta <span id="bk-eta">${pr.eta||'?'}</span></div>`;
/* Photo import — карта SD/USB → /mnt/storage/usb-imports (авто при вставке). С удалением. */
function renderPhotoPage(){const sv=last.services||{},pr=sv.progress||{},ph=sv.photo||{},active=pr.active&&pr.kind==='photo';
  const big=`<div class="bigstat"><div><div class="n">${ph.files||0}</div><div class="l">files</div></div><div><div class="n">${ph.bytes?TB(ph.bytes):'—'}</div><div class="l">size</div></div></div>`;
  const body=active?bkProg(pr)+`<div class="bks">card: ${pr.label||'?'}</div>`
    :big+`<div class="bks">${ph.last?'last import '+ph.last+(ph.name?' · '+ph.name:''):'no imports yet'} · auto on card insert</div>`;
  $('#photo-body').innerHTML=bkCard(ic('i-camera'),'Copy photos from card to disk',body)
    +'<div class="h" style="margin-top:6px">Imports on disk <span id="imp-total" class="k"></span></div><div id="bk-cleanup" class="svc-list"></div>';
  loadCleanup();}
/* NAS backup — домашний NAS → /mnt/storage/nas-backup (rsync-модули). Без удаления. */
function renderNasPage(){const sv=last.services||{},nb=sv.nas_backup||{},pr=sv.progress||{},active=pr.active&&pr.kind==='nas',sched=sv.nas_sched||'off';
  const R=(k,v)=>`<div class="row"><span class="k">${k}</span><span>${v}</span></div>`,cfg=Object.keys(nb).length>0;
  let h=bkCard(ic('i-cloud'),'Pull backup from home NAS',active?bkProg(pr):`<div class="bks">${cfg?'idle':'not configured — set NAS in Settings → Configs → nas-backup.conf'}</div>`);
  const schOn=sched&&sched!=='off';
  const schVal=`<span class="dot ${schOn?'ok':'off'}"></span> ${schOn?'ON · '+sched:'OFF (manual only)'}`;
  h+=`<div class="sideinfo">${R('Schedule',schVal)}${nb.last_run?R('Last run',nb.last_run):''}${nb.last_status?R('Last status',(nb.last_status==='failed'?'<span style="color:var(--crit)">failed</span>':'<span style="color:var(--ok)">'+nb.last_status+'</span>')):''}${nb.host?R('NAS host',nb.host):''}${nb.dest?R('Dest',nb.dest):''}</div>`;
  const sm=(sched||'').match(/^(daily|weekly) (\d\d:\d\d)/),stime=sm?sm[2]:'03:00';
  h+=`<div class="h" style="margin-top:8px">Auto-schedule</div>
    <div class="schedrow"><select id="sch-freq"><option value="daily">daily</option><option value="weekly">weekly (Sun)</option></select>
    <input type="time" id="sch-time" value="${stime}">
    <button class="minib" id="sch-set">Set</button><button class="minib" id="sch-off">Off</button>
    <button class="minib" id="nas-viewlog">View log</button></div>`;
  $('#nas-body').innerHTML=h;
  if(sm)$('#sch-freq').value=sm[1];
  $('#sch-set').onclick=()=>{doAction('nas-sched-set',{freq:$('#sch-freq').value,time:$('#sch-time').value});toast('schedule set');};
  $('#sch-off').onclick=()=>{doAction('nas-sched-off');toast('schedule off');};
  $('#nas-viewlog').onclick=()=>openLogfile('__nas__','NAS backup run log');
  $('#nas-acts').innerHTML=active?`<button class="rbtn danger" id="bk-stop">${ic('i-stop')}Stop</button>`
    :`<button class="rbtn" id="bk-run">${ic('i-cloud')}Run</button><button class="rbtn" id="bk-dry">${ic('i-list')}Dry</button><button class="rbtn" id="bk-diff">${ic('i-activity')}Diff</button>`;
  const b=(id,act,msg)=>{const e=$('#'+id);if(e)e.onclick=()=>{doAction(act);toast(msg);};};
  b('bk-run','nas-backup','backup started');b('bk-dry','nas-dry','dry-run → log');b('bk-diff','nas-diff','diff → log');b('bk-stop','nas-stop','stopping');}
function updateBackupLive(){const pr=(last.services||{}).progress||{};
  const open=!$('#page-photo').classList.contains('hidden')?'photo':(!$('#page-nas').classList.contains('hidden')?'nas':null);
  if(!open)return;const wantActive=!!(pr.active&&pr.kind===open);
  if(wantActive!==!!$('#bk-bar')){open==='photo'?renderPhotoPage():renderNasPage();return;}  // структура сменилась
  if(wantActive){const set=(id,v)=>{const e=$('#'+id);if(e)e.textContent=v;};const bar=$('#bk-bar');if(bar)bar.style.width=(pr.percent||0)+'%';
    set('bk-pct',(pr.percent||0)+'%');set('bk-files',(pr.files_done||0)+'/'+(pr.files_total||'?'));set('bk-speed',pr.speed||'…');set('bk-eta',pr.eta||'?');}}

/* Disk page — SMART + ёмкость (вместо бесполезного графика заполненности) */
async function renderDiskPage(){const st=last.storage||{},pct=st.pct||0,cl=pct>=95?'crit':pct>=88?'high':pct>=75?'warn':'';
  const pill=(n,l)=>`<div class="pill"><div class="pn">${n}</div><div class="pl">${l}</div></div>`;
  $('#disk-page').innerHTML=`<div class="bkbar big"><i class="${cl}" style="width:${pct}%"></i></div>
    <div class="bks">${(st.used/1e12).toFixed(2)} / ${(st.size/1e12).toFixed(2)} TB · ${pct}% · ${TB(st.avail)} free</div>
    <div id="smart-pills" class="pills" style="margin-top:14px"><div class="note">loading SMART…</div></div>
    <div class="sideinfo" id="smart-info"></div>`;
  try{const s=await(await fetch('/api/smart')).json();const P=[];
    const poh=s.power_on_hours?parseInt(s.power_on_hours.replace(/,/g,'')):0;
    if(s.health)P.push(pill(s.health,'status'));
    if(s.temp)P.push(pill(s.temp+'°','temp'));
    if(poh)P.push(pill(poh>=48?Math.round(poh/24)+' d':poh+' h','powered on'));
    if(s.power_cycles)P.push(pill(s.power_cycles,'cycles'));
    if(s.wear)P.push(pill(s.wear,'wear used'));if(s.spare)P.push(pill(s.spare,'spare'));if(s.realloc)P.push(pill(s.realloc,'realloc'));
    $('#smart-pills').innerHTML=P.join('')||'<div class="note">SMART n/a (microSD)</div>';
    const now=new Date(),upd=now.toLocaleDateString('en-US',{month:'long',day:'2-digit',year:'numeric'})+' · '+('0'+now.getHours()).slice(-2)+':'+('0'+now.getMinutes()).slice(-2);
    const R=(k,v)=>v?`<div class="row"><span class="k">${k}</span><span>${v}</span></div>`:'';
    $('#smart-info').innerHTML=R('Model',s.model)+R('Device',s.device)+R('Capacity',s.capacity)+R('Last updated',upd);
  }catch(e){$('#smart-pills').innerHTML='<div class="note">SMART error</div>';}}
async function loadCleanup(){try{const r=await(await fetch('/api/imports')).json();
  $('#imp-total').textContent='· '+TB(r.total);
  $('#bk-cleanup').innerHTML=r.items.map(i=>`<div class="svc-item"><span>${i.name} · ${TB(i.size)}</span><button class="del" data-n="${i.name}">${ic('i-stop')}Delete</button></div>`).join('')||'<div class="note">пусто</div>';
  $$('#bk-cleanup .del').forEach(b=>b.onclick=()=>openModal('Delete '+b.dataset.n+'?',[['Delete','__del:'+b.dataset.n,1]]));}catch(e){}}
async function delImport(name){await api('/api/imports/delete',{name});toast('deleted');loadCleanup();}

/* YT page */
function renderYT(){const yt=(last.services||{}).yt||{};
  if(!Object.keys(yt).length){$('#yt-pills').innerHTML='';$('#yt-info').innerHTML='<div class="note">YT-Archiver offline.</div>';$('#yt-toggle').style.display='none';return;}
  const pill=(n,l)=>`<div class="pill"><div class="pn">${n}</div><div class="pl">${l}</div></div>`;
  $('#yt-pills').innerHTML=pill(yt.videos||0,'videos')+pill(TB(yt.total_bytes),'size')+pill(yt.channels||0,'channels')
    +pill(yt.downloading||0,'downloading')+pill(yt.pending||0,'pending');
  const R=(k,v)=>`<div class="row"><span class="k">${k}</span><span>${v}</span></div>`;
  $('#yt-info').innerHTML=R('state',yt.paused?'paused':'running')+R('errors',yt.error||0)+R('max parallel',yt.max_concurrent||1);
  const t=$('#yt-toggle');t.style.display='';t.innerHTML=yt.paused?ic('i-play')+'Resume all':ic('i-stop')+'Pause all';
  t.onclick=async()=>{await api('/api/yt',{action:yt.paused?'resume':'pause'});toast(yt.paused?'resumed':'paused');setTimeout(()=>api('/api/snapshot').then(r=>r.json()).then(d=>{last=d;renderYT();}),800);};
  // обогащаем напрямую с YT-бэкенда (CORS=*): музыка + недавние
  fetch(`http://${location.hostname}:8081/api/videos`).then(r=>r.json()).then(v=>{
    const music=v.filter(x=>x.is_music||x.is_music_via_playlist).length;
    $('#yt-pills').insertAdjacentHTML('beforeend',pill(music,'music'));
    const rec=v.filter(x=>x.downloaded_at).sort((a,b)=>(b.downloaded_at||'').localeCompare(a.downloaded_at||'')).slice(0,8);
    $('#yt-recent').innerHTML=(rec.length?rec:v.slice(0,8)).map(x=>`<div class="svc-item"><span>${ic((x.is_music||x.is_music_via_playlist)?'i-music':'i-video')} ${(x.title||'').slice(0,44)}</span><span class="u">${x.file_size_bytes?TB(x.file_size_bytes):''}</span></div>`).join('')||'<div class="note">empty</div>';
  }).catch(()=>{$('#yt-recent').innerHTML='<div class="note">нет связи с YT-бэкендом</div>';});}

/* Power */
const MODEDESC={auto:'Auto — system picks governor by temp/throttle.',normal:'Normal — ondemand, up to max clock.',saver:'Saver — powersave, min clock.'};
function renderPower(){const s=last.system||{},pm=s.pmode||'auto';
  $$('#powermode button').forEach(b=>b.classList.toggle('active',b.dataset.mode===pm));
  $('#mode-desc').textContent=MODEDESC[pm]||'';
  const R=(k,v)=>`<div class="row"><span class="k">${k}</span><span>${v}</span></div>`;
  $('#power-info').innerHTML=R('mode',pm)+R('governor',s.governor||'?')+R('frequency',(s.freq_mhz||0)+' MHz')+R('CPU temp',(s.temp??'?')+'°C')+R('throttled',s.throttled_now?'YES':'no')+R('load',(s.load||[]).join(' '));}
$$('#powermode button').forEach(b=>b.onclick=()=>{doAction('power-mode',{mode:b.dataset.mode});setTimeout(renderPower,800);});
$$('#boost-seg button').forEach(b=>b.onclick=()=>{doAction('cpu-boost',{min:+b.dataset.min});toast('CPU boost '+b.dataset.min+'m');});

/* Network */
function renderNetwork(){const nw=last.network||{},R=(k,v)=>`<div class="row"><span class="k">${k}</span><span>${v}</span></div>`;
  const apBig=`<div style="text-align:center;margin-bottom:12px;padding:12px;background:var(--panel);border:1px solid var(--line);border-radius:12px"><div class="k">Hotspot SSID</div><div style="font-size:26px;font-weight:700">${nw.ap_ssid||'—'}</div><div class="k" style="margin-top:8px">Password</div><div style="font-size:18px;font-weight:600">${nw.ap_pass||'open'}</div></div>`;
  $('#net-info').innerHTML=apBig+R('hostname',(nw.host||'nas')+'.local')+R('IP',nw.ip||'—')+R('WiFi',nw.ssid||'—')+R('signal',nw.signal?nw.signal+' dB':'—')+R('mode',nw.mode==='AP'?'Hotspot':'Client')+R('Tailscale',nw.ts_up?`up · ${nw.ts_peers||0} peers`:'down');
  $('#ts-toggle').innerHTML=ic('i-net')+(nw.ts_up?'TS off':'TS on');}
$('#force-ap').onclick=()=>openModal('Force hotspot',[['Drop WiFi → start AP','force-ap',1]]);
$('#ts-toggle').onclick=()=>doAction((last.network||{}).ts_up?'tailscale-down':'tailscale-up');
$('#wifi-reconnect').onclick=()=>doAction('wifi-reconnect');
async function loadTsList(){try{const d=await(await fetch('/api/tailscale')).json();
  $('#ts-list').innerHTML=d.peers.map(p=>`<div class="svc-item ${p.online?'online':'offline'}" data-ip="${p.ip}"><span>${p.name} <span style="color:var(--mut);font-size:11px">${p.os}</span></span><span class="u">${p.online?'online':'offline'} · ${p.ip}</span></div>`).join('')||'<div class="note">no peers</div>';
  $$('#ts-list .svc-item').forEach(el=>el.onclick=async()=>{toast('ping '+el.dataset.ip+'…');const r=await(await api('/api/ts-ping',{ip:el.dataset.ip})).json();toast((r.out||'no reply').split('\n').pop());});}catch(e){}}
async function loadWifi(){$('#wifi-list').innerHTML='<div class="note">scanning…</div>';
  try{const n=await(await fetch('/api/wifi/scan')).json();
  $('#wifi-list').innerHTML=n.map(w=>`<div class="svc-item" data-ssid="${w.ssid}" data-sec="${w.sec}"><span>${w.active?'● ':''}${w.ssid}</span><span class="u">${w.signal}%${w.sec&&w.sec!=='--'?'':''}</span></div>`).join('')||'<div class="note">none</div>';
  $$('#wifi-list .svc-item').forEach(el=>el.onclick=()=>connectWifi(el.dataset.ssid,el.dataset.sec));}catch(e){$('#wifi-list').innerHTML='error';}}
function connectWifi(ssid,sec){if(sec&&sec!=='--'&&sec!==''){
    $('#wifi-list').innerHTML=`<div class="h">${ssid}</div><input id="wifi-pw" class="lfilter" type="password" placeholder="password" style="max-width:100%"><div style="display:flex;gap:8px;margin-top:8px"><button id="wifi-go" class="wide">Connect</button><button id="wifi-cancel" class="wide">Cancel</button></div>`;
    $('#wifi-go').onclick=()=>{doAction('wifi-connect',{ssid,password:$('#wifi-pw').value});toast('connecting '+ssid);};$('#wifi-cancel').onclick=loadWifi;
  }else{doAction('wifi-connect',{ssid});toast('connecting '+ssid);}}
$('#wifi-scan').onclick=loadWifi;

/* Today + recent */
async function renderToday(){try{const d=await(await fetch('/api/today')).json();
  const R=(k,v)=>`<div class="row"><span class="k">${k}</span><span>${v}</span></div>`;let h='';
  if(d.date)h+=R('Date',d.date);if(d.uptime)h+=R('Uptime',d.uptime);
  if(d.cpu_temp!=null)h+=R('CPU temp',d.cpu_temp+'°C');
  if(d.ip)h+=R('IP',d.ip);if(d.ssid)h+=R('WiFi',d.ssid);
  if(d.storage)h+=R('Storage',`${d.storage.used} / ${d.storage.total} (${d.storage.pct}%)`+(d.storage.temp!=null?` · ${d.storage.temp}°C`:''));
  if(d.throttle)h+=R('Throttle',d.throttle.now?'NOW':(d.throttle.past?'past':'no'));
  if(d.photo_today)h+=R('Photo today',`${d.photo_today.cards} cards · ${d.photo_today.files} files · ${d.photo_today.size}`);
  h+=R('NAS today',d.nas_today?(typeof d.nas_today==='object'?(d.nas_today.status||'done'):d.nas_today):'—');
  if(d.errors_today!=null)h+=R('Errors',d.errors_today);if(d.incomplete!=null)h+=R('Incomplete',d.incomplete);
  $('#today-body').innerHTML=h||'<div class="note">No summary yet (daily 21:00).</div>';
  const ev=Array.isArray(d.events)?d.events:[];
  $('#today-events').innerHTML=ev.length?ev.slice().reverse().map(e=>`<div class="svc-item"><span>${e}</span></div>`).join(''):'<div class="note">no events</div>';
  }catch(e){$('#today-body').innerHTML='error';}loadRecent();}
async function loadRecent(){try{const d=await(await fetch('/api/recent')).json();
  $('#recent-list').innerHTML=d.count?d.items.map(i=>`<div class="svc-item"><span>${i.path}</span><span class="u">${(i.size/1e6).toFixed(1)} MB</span></div>`).join(''):'<div class="note">nothing new in 24h</div>';}catch(e){}}

/* Failed units */
async function renderFailed(){try{const u=await(await fetch('/api/failed')).json();
  $('#failed-body').innerHTML=u.length?'<div class="svc-list">'+u.map(n=>`<div class="svc-item"><span>${n}</span><button class="minib" data-u="${n}">Restart</button></div>`).join('')+'</div>':'<div class="note">No failed units</div>';
  $$('#failed-body .minib').forEach(b=>b.onclick=()=>{doAction('restart-unit',{unit:b.dataset.u});toast('restart '+b.dataset.u);setTimeout(renderFailed,1500);});}catch(e){$('#failed-body').innerHTML='error';}}

/* Configs */
async function renderConfigs(){try{const r=await(await fetch('/api/configs')).json();
  $('#configs-body').innerHTML='<div class="svc-list">'+r.map(c=>`<div class="svc-item" data-n="${c.name}"><span>${c.name}${c.desc?' — <span style="color:var(--mut)">'+c.desc+'</span>':''}</span><span class="u">edit</span></div>`).join('')+'</div><div class="note">Tap to edit. Некоторые содержат пароли/токены.</div>';
  $$('#configs-body .svc-item').forEach(el=>el.onclick=()=>editConfig(el.dataset.n));}catch(e){$('#configs-body').innerHTML='error';}}
async function editConfig(name){try{const r=await(await fetch('/api/config?name='+encodeURIComponent(name))).json();const esc=(r.content||'').replace(/&/g,'&amp;').replace(/</g,'&lt;');
  $('#configs-body').innerHTML=`<div class="h">${name}</div><textarea id="cfg-edit" class="editor">${esc}</textarea><div style="display:flex;gap:8px;margin-top:8px"><button id="cfg-save" class="wide">Save</button><button id="cfg-back" class="wide">Back</button></div>`;
  $('#cfg-save').onclick=async()=>{const x=await(await api('/api/config',{name,content:$('#cfg-edit').value})).json();toast(x.ok?'saved':'error: '+(x.err||x.error||''));};
  $('#cfg-back').onclick=renderConfigs;}catch(e){toast('error');}}

/* Logs */
let logsRaw='';
async function loadLogs(){$('#logs-body').textContent='loading…';try{logsRaw=await(await fetch('/api/logs')).text();renderLogs();const b=$('#logs-body');b.scrollTop=b.scrollHeight;}catch(e){$('#logs-body').textContent='error';}}
function renderLogs(){const q=($('#logs-filter').value||'').toLowerCase(),esc=s=>s.replace(/&/g,'&amp;').replace(/</g,'&lt;');
  $('#logs-body').innerHTML=logsRaw.split('\n').filter(l=>!q||l.toLowerCase().includes(q)).map(l=>{const lc=l.toLowerCase(),c=/(error|fail|critical|\berr\b)/.test(lc)?'log-err':/warn/.test(lc)?'log-warn':'';return c?`<span class="${c}">${esc(l)}</span>`:esc(l);}).join('\n');}
$('#logs-refresh').onclick=loadLogs;$('#logs-filter').oninput=renderLogs;

/* update page */
let updTimer=null;
$('#update-run').onclick=async()=>{$('#update-body').textContent='Starting…';await api('/api/update/run',{});
  clearInterval(updTimer);updTimer=setInterval(async()=>{try{$('#update-body').textContent=await(await fetch('/api/update/log')).text();const b=$('#update-body');b.scrollTop=b.scrollHeight;}catch(e){}},1500);};

/* actions / modal */
$('#btn-power').onclick=()=>openModal('Power',[['Reboot','reboot',1],['Shut down','poweroff',1]]);
function openModal(title,btns){$('#modal-title').textContent=title;$('#modal-body').innerHTML='';
  btns.forEach(([l,a,dg])=>{const b=document.createElement('button');b.textContent=l;if(dg)b.className='danger';b.onclick=()=>{closeModal();doAction(a);};$('#modal-body').appendChild(b);});
  $('#modal').classList.remove('hidden');}
const closeModal=()=>$('#modal').classList.add('hidden');
$('#modal-cancel').onclick=closeModal;
async function doAction(name,body){if(name.startsWith('__del:'))return delImport(name.slice(6));
  toast('…');try{const r=await(await api('/api/action/'+name,body||{})).json();toast(r.ok||r.detached?'OK':('Error: '+(r.err||r.error||'')));}catch(e){toast('Network error');}}
$('#btn-exit').onclick=()=>doAction('screen',{exit_kiosk:true});
$('#diag-run').onclick=async()=>{toast('building diag…');try{const r=await(await api('/api/diag',{})).json();toast(r.ok?(r.sent?'sent to Telegram':'saved: '+r.path):'error: '+(r.error||''));}catch(e){toast('error');}};
/* log files viewer (#3) + nas-run log (#4) */
async function renderLogfiles(){try{const r=await(await fetch('/api/logfiles')).json();
  $('#lf-body').innerHTML='<div class="svc-list">'+r.map(f=>`<div class="svc-item" data-n="${f.name}"><span>${f.name}</span><span class="u">${(f.size/1024).toFixed(0)} KB</span></div>`).join('')+'</div>'+(r.length?'':'<div class="note">no log files</div>');
  $$('#lf-body .svc-item').forEach(el=>el.onclick=()=>openLogfile(el.dataset.n,el.dataset.n));}catch(e){$('#lf-body').innerHTML='error';}}
async function openLogfile(name,title){openPage('page-logfiles');
  $('#lf-body').innerHTML=`<button class="minib" id="lf-back">← files</button><div class="h" style="margin-top:6px">${title}</div><pre class="scrollbox" id="lf-view" style="font:11px/1.4 ui-monospace,monospace;color:var(--mut);white-space:pre-wrap;max-height:300px">loading…</pre>`;
  $('#lf-back').onclick=renderLogfiles;dragScroll($('#lf-view'));
  try{const url=name==='__nas__'?'/api/naslog':'/api/logfile?name='+encodeURIComponent(name);const t=await(await fetch(url)).text();$('#lf-view').textContent=t||'(empty)';const v=$('#lf-view');v.scrollTop=v.scrollHeight;}catch(e){$('#lf-view').textContent='error';}}
$('#logfiles-btn').onclick=()=>{openPage('page-logfiles');renderLogfiles();};
/* Pi config backup (#1) */
async function loadPiBackup(){try{const d=await(await fetch('/api/pibackup')).json();
  $('#pibk-info').textContent=d.count?`${d.count} · last ${d.when}`:'none yet';}catch(e){}}
$('#pibk-run').onclick=()=>{doAction('pi-backup');toast('pi config backup started');setTimeout(loadPiBackup,4000);};

/* screen */
const LS=localStorage,br=$('#brightness'),bv=$('#brightness-val');
function setBrightness(v,save){bv.textContent=v+'%';api('/api/action/screen',{brightness:v+'%'});if(save)LS.brightness=v;}
br.value=LS.brightness||80;bv.textContent=br.value+'%';br.oninput=()=>setBrightness(br.value,true);
$('#screen-timeout').value=LS.screenTimeout||'300';$('#screen-timeout').onchange=e=>LS.screenTimeout=e.target.value;
['night-from','night-to','night-level'].forEach(id=>{const el=$('#'+id);if(LS[id])el.value=LS[id];el.onchange=()=>{LS[id]=el.value;nightApplied=null;};});
$('#rotate-apply').onclick=()=>{const v=$('#rotate').value;if(v)doAction('screen',{rotate:v});};
let lastAct=Date.now(),screenOff=false;
['pointerdown','touchstart','keydown'].forEach(ev=>addEventListener(ev,()=>{lastAct=Date.now();if(screenOff){screenOff=false;api('/api/action/screen',{backlight:'on'});setBrightness(br.value);}},{passive:true}));
const RING=2*Math.PI*16;
setInterval(()=>{const to=+($('#screen-timeout').value||0),ring=$('#ring'),cd=$('#screen-cd');
  if(!to){cd.textContent='∞';ring.style.strokeDashoffset=0;return;}
  if(screenOff){cd.textContent='zZ';ring.style.strokeDashoffset=RING;return;}
  const rem=Math.max(0,to-(Date.now()-lastAct)/1000);cd.textContent=rem>=60?Math.ceil(rem/60)+'m':Math.ceil(rem)+'s';
  ring.style.strokeDasharray=RING;ring.style.strokeDashoffset=RING*(1-rem/to);if(rem<=0){screenOff=true;api('/api/action/screen',{backlight:'off'});}},1000);
let nightApplied=null;
function applyNight(){const f=$('#night-from').value,t=$('#night-to').value;if(!f||!t)return;
  const d=new Date(),cur=('0'+d.getHours()).slice(-2)+':'+('0'+d.getMinutes()).slice(-2);
  const inWin=f<t?(cur>=f&&cur<t):(cur>=f||cur<t),target=inWin?+$('#night-level').value:+br.value;
  if(!screenOff&&target!==nightApplied){nightApplied=target;api('/api/action/screen',{brightness:target+'%'});}}

/* mini-graph period per metric */
$$('select[data-sp]').forEach(s=>{const m=s.dataset.sp;s.value=localStorage['spark_'+m]||'300';
  s.onchange=()=>{localStorage['spark_'+m]=s.value;fetchSparkHist(m);updateSparks();};
  if(+s.value>900)fetchSparkHist(m);});

/* accent */
function applyAccent(c){document.documentElement.style.setProperty('--acc',c);}
if(localStorage.accent)applyAccent(localStorage.accent);
$$('#accent button').forEach(b=>b.onclick=()=>{applyAccent(b.dataset.c);localStorage.accent=b.dataset.c;});

/* drag-scroll */
function dragScroll(el){let down=false,sy=0,stp=0,moved=false;
  el.addEventListener('pointerdown',e=>{if(e.target.closest('input,textarea,select'))return;down=true;sy=e.clientY;stp=el.scrollTop;moved=false;});
  el.addEventListener('pointermove',e=>{if(!down)return;const dy=e.clientY-sy;if(Math.abs(dy)>6)moved=true;if(moved)el.scrollTop=stp-dy;});
  const end=()=>down=false;['pointerup','pointercancel','pointerleave'].forEach(ev=>el.addEventListener(ev,end));
  el.addEventListener('click',e=>{if(moved){e.stopPropagation();e.preventDefault();}},true);}
['.tab','.pbody','.scrollbox','.sideinfo'].forEach(sel=>$$(sel).forEach(dragScroll));

connect();setBrightness(br.value);