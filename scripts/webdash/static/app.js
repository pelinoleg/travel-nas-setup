/* Travel-NAS web dashboard — client. SSE, fixed-scale sparklines, per-card
   detail graph, disks, docker by project, backups, circular screen timer. */
'use strict';
const $=s=>document.querySelector(s), $$=s=>[...document.querySelectorAll(s)];
const api=(p,b)=>fetch(p,b?{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(b)}:undefined);
const toast=m=>{const t=$('#toast');t.textContent=m;t.classList.remove('hidden');clearTimeout(t._t);t._t=setTimeout(()=>t.classList.add('hidden'),2500);};
const fmtUp=s=>{const d=s/86400|0,h=s%86400/3600|0,m=s%3600/60|0;return d?`${d}d ${h}h`:h?`${h}h ${m}m`:`${m}m`;};
const TB=b=>b==null?'?':(b>=1e12?(b/1e12).toFixed(2)+' TB':(b/1e9).toFixed(1)+' GB');

/* metric meta + thresholds */
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
$$('#tabs button').forEach(b=>b.onclick=()=>{$$('#tabs button').forEach(x=>x.classList.remove('active'));
  $$('.tab').forEach(x=>x.classList.remove('active'));b.classList.add('active');
  $('#tab-'+b.dataset.tab).classList.add('active');activeTab=b.dataset.tab;onTab(activeTab);});
function onTab(t){if(t==='system'){loadProc();sysGraphs();}else if(t==='storage')renderDisks();
  else if(t==='docker')renderProjects();else if(t==='logs')loadLogs();}

/* clock */
setInterval(()=>{const d=new Date();$('#clock').textContent=`${('0'+d.getHours()).slice(-2)}:${('0'+d.getMinutes()).slice(-2)}`;},1000);

/* live ring buffers (5 min @2s = 150) */
const TBUF=[],SPARK={cpu:[],temp:[],mem:[],net_rx:[],disk:[]};
const sparkMax=m=>MET[m].max||(m==='mem'?memTotal:Math.max(1,...SPARK[m],0.1));
function drawSpark(cv,arr,color,max){const w=cv.width=cv.clientWidth*2,h=cv.height=cv.clientHeight*2;
  const x=cv.getContext('2d');x.clearRect(0,0,w,h);if(arr.length<2)return;
  x.beginPath();arr.forEach((v,i)=>{const px=i/(arr.length-1)*w,py=h-Math.min(1,v/max)*(h-6)-3;i?x.lineTo(px,py):x.moveTo(px,py);});
  x.strokeStyle=color;x.lineWidth=2;x.lineJoin='round';x.stroke();
  x.lineTo(w,h);x.lineTo(0,h);x.closePath();x.fillStyle=color+'1f';x.fill();}
function updateSparks(){$$('.spark').forEach(cv=>{const k=cv.dataset.s;drawSpark(cv,SPARK[k],MET[k].col,sparkMax(k));});}

/* render snapshot */
const chip=(cls,txt)=>`<span class="chip"><span class="dot ${cls}"></span>${txt}</span>`;
function render(d){last=d;const s=d.system||{},st=d.storage||{},nw=d.network||{},sv=d.services||{};
  if(s.mem_total)memTotal=s.mem_total;
  const memPct=s.mem_total?Math.round(s.mem_used/s.mem_total*100):null;
  $('#cpu').textContent=s.cpu??'–';colorVal('cpu','cpu',s.cpu);
  $('#temp').textContent=s.temp??'–';colorVal('temp','temp',s.temp);
  $('#mem').textContent=s.mem_total?`${s.mem_used}`:'–';colorVal('mem','disk',memPct);
  $('#net').textContent=`↑${s.net_tx??0}  ↓${s.net_rx??0}`;
  $('#disk').textContent=st.pct??'–';colorVal('disk','disk',st.pct);
  $('#uptime').textContent=fmtUp(s.uptime||0);
  $('#power').textContent=(s.governor||'?');$('#power-sub').textContent=(s.freq_mhz||0)+' MHz';
  // ring (screen timer)
  // live buffers
  const now=Date.now()/1000|0;TBUF.push(now);
  const push=(k,v)=>{SPARK[k].push(v==null?0:v);};
  push('cpu',s.cpu);push('temp',s.temp);push('mem',s.mem_used);push('net_rx',s.net_rx);push('disk',st.pct);
  if(TBUF.length>150){TBUF.shift();for(const k in SPARK)SPARK[k].shift();}
  updateSparks();
  if(!$('#detail').classList.contains('hidden'))liveDetail();
  // header addr + comitup chip (no tailscale)
  $('#host').textContent=(nw.host||'nas')+'.local';
  $('#ip').textContent=nw.ip&&nw.ip!=='?'?nw.ip:'no network';
  const wifiCls=nw.mode==='AP'?'warn':(nw.ip&&nw.ip!=='?'?'ok':'err');
  const wifiTxt=nw.mode==='AP'?`Hotspot ${nw.ssid||''}`:`${nw.ssid||'no wifi'} ${nw.signal?nw.signal+'dB':''}`;
  $('#topchips').innerHTML=chip(wifiCls,wifiTxt);
  renderBackups();}

/* SSE */
function connect(){const es=new EventSource('/api/stream');
  es.onmessage=e=>{try{render(JSON.parse(e.data));applyNight();}catch(_){}};
  es.onerror=()=>{es.close();setTimeout(connect,3000);};}

/* detail overlay (graph on tile tap) */
let dchart,dMetric='cpu',dRange='1h';
$$('.tile[data-metric]').forEach(t=>t.onclick=()=>openDetail(t.dataset.metric));
$('#detail-back').onclick=()=>$('#detail').classList.add('hidden');
$$('#detail-ranges button').forEach(b=>b.onclick=()=>{$$('#detail-ranges button').forEach(x=>x.classList.remove('active'));
  b.classList.add('active');dRange=b.dataset.range;loadDetail();});
function openDetail(m){dMetric=m;$('#detail-title').textContent=MET[m].label;
  $('#detail').classList.remove('hidden');makeDChart();loadDetail();}
function yrange(m){const mx=MET[m].max||(m==='mem'?memTotal:null);
  return mx?{range:[0,mx]}:{range:(u,_,max)=>[0,max||1]};}
function makeDChart(data){const el=$('#dchart');el.innerHTML='';
  dchart=new uPlot({width:el.clientWidth||780,height:el.clientHeight||230,cursor:{show:false},legend:{show:false},
    scales:{x:{time:true},y:yrange(dMetric)},
    axes:[{stroke:'#8b949e',grid:{stroke:'#222b38'}},{stroke:'#8b949e',grid:{stroke:'#222b38'},size:42}],
    series:[{},{stroke:MET[dMetric].col,width:2,fill:MET[dMetric].col+'22',points:{show:false}}]},
    data||[[],[]],el);}
async function loadDetail(){makeDChart();
  if(dRange==='5m'){liveDetail();return;}
  try{const r=await(await fetch(`/api/history?m=${dMetric}&range=${dRange}`)).json();
    setDetail(r.t||[],r.v||[]);}catch(e){}}
function liveDetail(){if(dRange!=='5m')return;setDetail(TBUF.slice(),SPARK[dMetric].slice());}
function setDetail(t,v){dchart.setData([t,v]);
  const vv=v.filter(x=>x!=null);const cur=vv.length?vv[vv.length-1]:'–';
  const mn=vv.length?Math.min(...vv).toFixed(1):'–',mx=vv.length?Math.max(...vv).toFixed(1):'–';
  const av=vv.length?(vv.reduce((a,b)=>a+b,0)/vv.length).toFixed(1):'–';
  $('#detail-stats').innerHTML=`now <b>${cur}</b>  ·  min ${mn}  ·  avg ${av}  ·  max ${mx}`;}

/* System */
async function loadProc(){try{const r=await(await fetch('/api/processes')).json();
  $('#proc').innerHTML=r.map(p=>`<tr><td>${p.cmd}</td><td>${p.pid}</td><td>${p.cpu}%</td><td>${p.mem}%</td></tr>`).join('');}catch(e){}}
let sysG={};
async function sysGraphs(){for(const[m,id]of[['cpu','g-cpu'],['temp','g-temp'],['mem','g-mem']]){
  try{const r=await(await fetch(`/api/history?m=${m}&range=1h`)).json();const el=$('#'+id);el.innerHTML='';
    sysG[m]=new uPlot({width:el.clientWidth||360,height:78,cursor:{show:false},legend:{show:false},
      scales:{x:{time:true},y:yrange(m)},axes:[{stroke:'#8b949e',size:20},{stroke:'#8b949e',size:34}],
      series:[{},{stroke:MET[m].col,width:2,fill:MET[m].col+'22',points:{show:false}}]},[r.t||[],r.v||[]],el);}catch(e){}}}
setInterval(()=>{if(activeTab==='system')loadProc();},5000);

/* Disks (temp big) */
function renderDisks(){const disks=(last.storage||{}).disks||[];
  $('#disks').innerHTML=disks.map(d=>{
    const parts=d.parts.filter(p=>p.mount).map(p=>{const cl=p.pct>=95?'crit':p.pct>=88?'high':p.pct>=75?'warn':'';
      return `<div class="part">${p.mount} · ${p.label||p.fstype||''} — ${TB(p.used)}/${TB(p.total)} (${p.pct??'?'}%)</div>
        <div class="bar-fill"><i class="${cl}" style="width:${p.pct||0}%"></i></div>`;}).join('')||'<div class="part">not mounted</div>';
    const kc=d.kind==='USB'?'usb':d.kind==='SD'?'sd':'';
    return `<div class="disk"><div class="top"><div><div class="name">${d.name}</div>
      <div class="meta">${d.model||d.kind} · ${TB(d.size)}${d.health&&d.health!='?'?' · '+d.health:''}</div></div>
      <div style="text-align:right"><span class="badge ${kc}">${d.kind}</span>
      ${d.temp!=null?`<div class="temp">${d.temp}<small>°C</small></div>`:''}</div></div>
      ${parts}</div>`;}).join('')||'<div>no disks</div>';}

/* Docker by project */
function renderProjects(){const pr=(last.services||{}).projects||[];
  const ic=n=>`<svg class="ic"><use href="#${n}"/></svg>`;
  $('#projects').innerHTML=pr.map(p=>{const ok=p.running===p.total&&p.total>0;
    return `<div class="proj"><div class="top"><span class="name">${p.project}</span>
      <span class="st"><span class="dot ${ok?'ok':p.running?'warn':'err'}"></span>${p.running}/${p.total}</span></div>
      <div class="btns"><button class="start" data-p="${p.project}" data-a="start">${ic('i-play')}</button>
      <button data-p="${p.project}" data-a="restart">${ic('i-restart')}</button>
      <button class="stop" data-p="${p.project}" data-a="stop">${ic('i-stop')}</button></div></div>`;}).join('')||'<div>no projects</div>';
  $$('#projects button').forEach(b=>b.onclick=async()=>{toast(b.dataset.a+' '+b.dataset.p+'…');
    await api('/api/docker',{project:b.dataset.p,action:b.dataset.a});
    setTimeout(()=>api('/api/snapshot').then(r=>r.json()).then(d=>{last=d;if(activeTab==='docker')renderProjects();}),1800);});}

/* Backups on overview */
function renderBackups(){const sv=last.services||{},nb=sv.nas_backup||{},pr=sv.progress||{},ph=sv.photo||{};
  const ic=n=>`<svg class="ic"><use href="#${n}"/></svg>`;
  const nasS=pr.active?`running ${pr.percent||0}%`:(nb.last_status||nb.status||'not set up');
  const items=[['photo',ic('i-camera'),'Photo import',ph.last?('last '+ph.last):'idle'],
               ['nas',ic('i-cloud'),'NAS backup',nasS]];
  $('#backups').innerHTML=items.map(([id,i,t,s])=>`<div class="bk" data-bk="${id}">${i}<div><div class="t">${t}</div><div class="s">${s}</div></div></div>`).join('');
  $$('.bk').forEach(b=>b.onclick=()=>{if(b.dataset.bk==='nas')
    openModal('NAS backup',[['Run backup','nas-backup'],['Stop','nas-stop']]);
    else openModal('Photo import',[]);});}

/* Logs */
async function loadLogs(){$('#logs-body').textContent='loading…';
  try{$('#logs-body').textContent=await(await fetch('/api/logs')).text();const b=$('#logs-body');b.scrollTop=b.scrollHeight;}
  catch(e){$('#logs-body').textContent='error';}}
$('#logs-refresh').onclick=loadLogs;

/* actions / modal */
$('#btn-power').onclick=()=>openModal('Power',[['Reboot','reboot',1],['Shut down','poweroff',1]]);
function openModal(title,btns){$('#modal-title').textContent=title;$('#modal-body').innerHTML='';
  if(!btns.length)$('#modal-body').innerHTML='<div style="color:var(--mut)">Automatic on card insert</div>';
  btns.forEach(([l,a,dg])=>{const b=document.createElement('button');b.textContent=l;if(dg)b.className='danger';
    b.onclick=()=>{closeModal();doAction(a);};$('#modal-body').appendChild(b);});
  $('#modal').classList.remove('hidden');}
const closeModal=()=>$('#modal').classList.add('hidden');
$('#modal-cancel').onclick=closeModal;
async function doAction(name,body){toast('…');try{const r=await(await api('/api/action/'+name,body||{})).json();
  toast(r.ok||r.detached?'OK':('Error: '+(r.err||r.error||'')));}catch(e){toast('Network error');}}
$('#btn-exit').onclick=()=>doAction('screen',{exit_kiosk:true});
$('#act-update').onclick=()=>doAction('update');
$('#act-boost').onclick=()=>doAction('cpu-boost');
$$('#powermode button').forEach(b=>b.onclick=()=>{$$('#powermode button').forEach(x=>x.classList.remove('active'));
  b.classList.add('active');doAction('power-mode',{mode:b.dataset.mode});});
$('#rotate-apply').onclick=()=>{const v=$('#rotate').value;if(v)doAction('screen',{rotate:v});};

/* screen: brightness 0-100, off timer + circular ring, night dim */
const LS=localStorage,br=$('#brightness'),bv=$('#brightness-val');
function setBrightness(v,save){bv.textContent=v+'%';api('/api/action/screen',{brightness:v+'%'});if(save)LS.brightness=v;}
br.value=LS.brightness||80;bv.textContent=br.value+'%';br.oninput=()=>setBrightness(br.value,true);
$('#screen-timeout').value=LS.screenTimeout||'300';$('#screen-timeout').onchange=e=>LS.screenTimeout=e.target.value;
['night-from','night-to','night-level'].forEach(id=>{const el=$('#'+id);if(LS[id])el.value=LS[id];el.onchange=()=>{LS[id]=el.value;nightApplied=null;};});
let lastAct=Date.now(),screenOff=false;
['pointerdown','touchstart','keydown'].forEach(ev=>addEventListener(ev,()=>{lastAct=Date.now();
  if(screenOff){screenOff=false;api('/api/action/screen',{backlight:'on'});setBrightness(br.value);}},{passive:true}));
const RING=2*Math.PI*16;
setInterval(()=>{const to=+($('#screen-timeout').value||0);const ring=$('#ring'),cd=$('#screen-cd');
  if(!to){cd.textContent='∞';ring.style.strokeDashoffset=0;return;}
  if(screenOff){cd.textContent='zZ';ring.style.strokeDashoffset=RING;return;}
  const rem=Math.max(0,to-(Date.now()-lastAct)/1000);
  cd.textContent=rem>=60?Math.ceil(rem/60)+'m':Math.ceil(rem)+'s';
  ring.style.strokeDasharray=RING;ring.style.strokeDashoffset=RING*(1-rem/to);
  if(rem<=0&&!screenOff){screenOff=true;api('/api/action/screen',{backlight:'off'});}},1000);
let nightApplied=null;
function applyNight(){const f=$('#night-from').value,t=$('#night-to').value;if(!f||!t)return;
  const d=new Date(),cur=('0'+d.getHours()).slice(-2)+':'+('0'+d.getMinutes()).slice(-2);
  const inWin=f<t?(cur>=f&&cur<t):(cur>=f||cur<t);const target=inWin?+$('#night-level').value:+br.value;
  if(!screenOff&&target!==nightApplied){nightApplied=target;api('/api/action/screen',{brightness:target+'%'});}}

/* start */
connect();setBrightness(br.value);
