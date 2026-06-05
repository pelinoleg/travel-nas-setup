/* Travel-NAS web dashboard — клиент. SSE, мини-графики, цветовые пороги, диски,
   docker по проектам, процессы, логи, экран. */
'use strict';
const $=s=>document.querySelector(s), $$=s=>[...document.querySelectorAll(s)];
const api=(p,b)=>fetch(p,b?{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(b)}:undefined);
const toast=m=>{const t=$('#toast');t.textContent=m;t.classList.remove('hidden');
  clearTimeout(t._t);t._t=setTimeout(()=>t.classList.add('hidden'),2500);};
const fmtUp=s=>{const d=s/86400|0,h=s%86400/3600|0,m=s%3600/60|0;return d?`${d}д ${h}ч`:h?`${h}ч ${m}м`:`${m}м`;};

/* пороги окраски: [жёлтый, оранжевый, красный] */
const TH={cpu:[70,85,95],temp:[60,72,82],disk:[75,88,95],mem:[70,85,95]};
const lvl=(m,v)=>{const t=TH[m];if(!t||v==null)return'';return v>=t[2]?'lv-crit':v>=t[1]?'lv-high':v>=t[0]?'lv-warn':'';};
function colorVal(id,metric,val){const e=$('#'+id);e.classList.remove('lv-warn','lv-high','lv-crit');
  const c=lvl(metric,val);if(c)e.classList.add(c);}

let last={};            /* последний снимок — для рендера вкладок по запросу */
let activeTab='overview';

/* ---- вкладки (крупные) ---- */
$$('#tabs button').forEach(b=>b.onclick=()=>{
  $$('#tabs button').forEach(x=>x.classList.remove('active'));
  $$('.tab').forEach(x=>x.classList.remove('active'));
  b.classList.add('active');$('#tab-'+b.dataset.tab).classList.add('active');
  activeTab=b.dataset.tab;onTab(activeTab);});
function onTab(t){ if(t==='system'){loadProc();sysGraphs();}
  else if(t==='storage')renderDisks(); else if(t==='docker')renderProjects();
  else if(t==='logs')loadLogs(); }

/* ---- часы ---- */
setInterval(()=>{const d=new Date();
  $('#clock').textContent=`${('0'+d.getHours()).slice(-2)}:${('0'+d.getMinutes()).slice(-2)}`;},1000);

/* ===== главный график (uPlot) ===== */
let chart,chMetric='cpu',chRange='1h',chData=[[],[]];
const METRICS={cpu:['CPU, %','#3b82f6'],temp:['Температура, °C','#f85149'],
  mem:['RAM, GB','#a371f7'],net_rx:['Входящий, MB/s','#3fb950']};
function makeChart(){const el=$('#chart');el.innerHTML='';const[lbl,col]=METRICS[chMetric];
  chart=new uPlot({width:el.clientWidth||760,height:120,cursor:{show:false},legend:{show:false},
    scales:{x:{time:true}},
    axes:[{stroke:'#8b949e',grid:{stroke:'#222b38'},size:28},{stroke:'#8b949e',grid:{stroke:'#222b38'},size:34}],
    series:[{},{stroke:col,width:2,fill:col+'22',points:{show:false}}]},chData,el);
  $('#graph-title').textContent=lbl;}
async function loadHistory(){try{const r=await(await fetch(`/api/history?m=${chMetric}&range=${chRange}`)).json();
  chData=[r.t||[],r.v||[]];chart.setData(chData);}catch(e){}}
function pushLive(v){if(v==null)return;const now=Date.now()/1000|0;
  const win={'1h':3600,'24h':86400,'7d':604800}[chRange];
  chData[0].push(now);chData[1].push(v);
  while(chData[0].length&&chData[0][0]<now-win){chData[0].shift();chData[1].shift();}
  chart.setData(chData);}
$$('.card').forEach(c=>c.onclick=()=>{$$('.card').forEach(x=>x.classList.remove('sel'));c.classList.add('sel');
  chMetric=c.dataset.metric;makeChart();loadHistory();});
$$('.ranges button').forEach(b=>b.onclick=()=>{$$('.ranges button').forEach(x=>x.classList.remove('active'));
  b.classList.add('active');chRange=b.dataset.range;loadHistory();});

/* ===== мини-графики (sparkline на карточках) ===== */
const SPARK={cpu:[],temp:[],mem:[],net_rx:[]};
const SPARKCOL={cpu:'#3b82f6',temp:'#f85149',mem:'#a371f7',net_rx:'#3fb950'};
function drawSpark(cv,arr,color){const w=cv.width=cv.clientWidth*2,h=cv.height=cv.clientHeight*2;
  const x=cv.getContext('2d');x.clearRect(0,0,w,h);if(arr.length<2)return;
  const mn=Math.min(...arr),mx=Math.max(...arr),r=mx-mn||1;x.beginPath();
  arr.forEach((v,i)=>{const px=i/(arr.length-1)*w,py=h-((v-mn)/r)*(h-6)-3;i?x.lineTo(px,py):x.moveTo(px,py);});
  x.strokeStyle=color;x.lineWidth=2;x.lineJoin='round';x.stroke();}
function updateSparks(){$$('.spark').forEach(cv=>{const k=cv.dataset.s;drawSpark(cv,SPARK[k],SPARKCOL[k]);});}

/* ===== рендер снимка ===== */
const chip=(cls,txt)=>`<span class="chip"><span class="dot ${cls}"></span>${txt}</span>`;
function render(d){last=d;const s=d.system||{},st=d.storage||{},nw=d.network||{},sv=d.services||{};
  const memPct=s.mem_total?Math.round(s.mem_used/s.mem_total*100):null;
  $('#cpu').textContent=s.cpu??'–';colorVal('cpu','cpu',s.cpu);
  $('#temp').textContent=s.temp??'–';colorVal('temp','temp',s.temp);
  $('#mem').textContent=s.mem_total?`${s.mem_used}/${s.mem_total}`:'–';colorVal('mem','mem',memPct);
  $('#net').textContent=`↑${s.net_tx??0} ↓${s.net_rx??0}`;
  $('#cpu-sub').textContent=`${s.freq_mhz||0} МГц`;
  $('#temp-sub').textContent=s.throttled_now?'⚠ throttle':'ок';
  // sparkbuffers
  for(const k of['cpu','temp','net_rx'])if(s[k]!=null){SPARK[k].push(s[k]);if(SPARK[k].length>90)SPARK[k].shift();}
  if(s.mem_used!=null){SPARK.mem.push(s.mem_used);if(SPARK.mem.length>90)SPARK.mem.shift();}
  updateSparks();
  pushLive({cpu:s.cpu,temp:s.temp,mem:s.mem_used,net_rx:s.net_rx}[chMetric]);
  // адрес + IP вместо бренда
  $('#host').textContent=(nw.host||'nas')+'.local';
  $('#ip').textContent=nw.ip&&nw.ip!=='?'?nw.ip:'нет сети';
  // верхние плашки: wifi/comitup, tailscale, бэкап
  const wifiCls=nw.mode==='AP'?'warn':(nw.ip&&nw.ip!=='?'?'ok':'err');
  const wifiTxt=nw.mode==='AP'?`AP ${nw.ssid||''}`:`${nw.ssid||'нет WiFi'} ${nw.signal?nw.signal+'dB':''}`;
  const nb=sv.nas_backup||{},bs=nb.last_status||nb.status;
  const tc=[chip(wifiCls,wifiTxt)];
  if(nw.tailscale)tc.push(chip('ok','TS '+nw.tailscale));
  tc.push(chip(bs==='ok'?'ok':bs?'err':'',`бэкап: ${bs||'не настроен'}`));
  $('#topchips').innerHTML=tc.join('');
  // нижние плашки обзора: disk, uptime, power, throttle, отсчёт гашения
  const dpct=st.pct;
  const ov=[chip(lvl('disk',dpct)?'warn':'ok',`диск ${dpct??'–'}%`),
            chip('','uptime '+fmtUp(s.uptime||0)),
            chip('',`${s.governor||'?'} · ${s.freq_mhz||0}МГц`),
            chip(s.throttled_now?'err':'ok',s.throttled_now?'throttle!':'питание ок'),
            chip('', screenChipText())];
  $('#ovchips').innerHTML=ov.join('');}

/* ===== SSE ===== */
function connect(){const es=new EventSource('/api/stream');
  es.onmessage=e=>{try{render(JSON.parse(e.data));applyNight();}catch(_){}};
  es.onerror=()=>{es.close();setTimeout(connect,3000);};}

/* ===== System: процессы + мини-uPlot ===== */
async function loadProc(){try{const r=await(await fetch('/api/processes')).json();
  $('#proc').innerHTML=r.map(p=>`<tr><td>${p.cmd}</td><td>${p.pid}</td><td>${p.cpu}%</td><td>${p.mem}%</td></tr>`).join('');
  }catch(e){}}
let sysG={};
async function sysGraphs(){for(const[m,id]of[['cpu','g-cpu'],['temp','g-temp'],['mem','g-mem']]){
  try{const r=await(await fetch(`/api/history?m=${m}&range=1h`)).json();const el=$('#'+id);el.innerHTML='';
    sysG[m]=new uPlot({width:el.clientWidth||360,height:74,cursor:{show:false},legend:{show:false},
      scales:{x:{time:true}},axes:[{stroke:'#8b949e',size:22},{stroke:'#8b949e',size:30}],
      series:[{},{stroke:METRICS[m][1],width:2,fill:METRICS[m][1]+'22',points:{show:false}}]},
      [r.t||[],r.v||[]],el);}catch(e){}}}
setInterval(()=>{if(activeTab==='system')loadProc();},5000);

/* ===== Storage: диски визуально ===== */
const TB=b=>b==null?'?':(b>=1e12?(b/1e12).toFixed(2)+' TB':(b/1e9).toFixed(1)+' GB');
function renderDisks(){const disks=(last.storage||{}).disks||[];
  $('#disks').innerHTML=disks.map(d=>{
    const parts=d.parts.filter(p=>p.mount).map(p=>{
      const cl=lvl('disk',p.pct)?(p.pct>=95?'crit':p.pct>=88?'high':'warn'):'';
      return `<div class="part">${p.mount} · ${p.label||p.fstype||''} — ${TB(p.used)}/${TB(p.total)}</div>
        <div class="bar-fill"><i class="${cl}" style="width:${p.pct||0}%"></i></div>`;}).join('')
      ||'<div class="part">не смонтирован</div>';
    const kindCls=d.kind==='USB'?'usb':d.kind==='SD'?'sd':'';
    return `<div class="disk"><div class="top"><span class="name">${d.name} ${d.model||''}</span>
      <span class="badge ${kindCls}">${d.kind}</span></div>
      <div class="meta">${TB(d.size)}${d.temp!=null?' · '+d.temp+'°C':''}${d.health&&d.health!='?'?' · '+d.health:''}</div>
      ${parts}</div>`;}).join('')||'<div>нет дисков</div>';}

/* ===== Docker по проектам ===== */
function renderProjects(){const pr=(last.services||{}).projects||[];
  $('#projects').innerHTML=pr.map(p=>{
    const ok=p.running===p.total&&p.total>0;
    return `<div class="proj"><div class="top"><span class="name">${p.project}</span>
      <span class="st"><span class="dot ${ok?'ok':p.running?'warn':'err'}"></span> ${p.running}/${p.total}</span></div>
      <div class="btns">
        <button class="start" data-p="${p.project}" data-a="start">▶ Start</button>
        <button data-p="${p.project}" data-a="restart">⟳ Restart</button>
        <button class="stop" data-p="${p.project}" data-a="stop">■ Stop</button></div></div>`;}).join('')
    ||'<div>нет проектов</div>';
  $$('#projects button').forEach(b=>b.onclick=async()=>{toast(b.dataset.a+' '+b.dataset.p+'…');
    await api('/api/docker',{project:b.dataset.p,action:b.dataset.a});
    setTimeout(()=>{api('/api/snapshot').then(r=>r.json()).then(d=>{last=d;if(activeTab==='docker')renderProjects();}),1500;},1500);});}

/* ===== Logs ===== */
async function loadLogs(){$('#logs-body').textContent='загрузка…';
  try{$('#logs-body').textContent=await(await fetch('/api/logs')).text();
    const b=$('#logs-body');b.scrollTop=b.scrollHeight;}catch(e){$('#logs-body').textContent='ошибка';}}
$('#logs-refresh').onclick=loadLogs;

/* ===== Действия ===== */
$('#btn-power').onclick=()=>openModal('Питание',[['Перезагрузить','reboot',1],['Выключить','poweroff',1]]);
function openModal(title,btns){$('#modal-title').textContent=title;$('#modal-body').innerHTML='';
  btns.forEach(([l,a,dg])=>{const b=document.createElement('button');b.textContent=l;if(dg)b.className='danger';
    b.onclick=()=>{closeModal();doAction(a);};$('#modal-body').appendChild(b);});
  $('#modal').classList.remove('hidden');}
const closeModal=()=>$('#modal').classList.add('hidden');
$('#modal-cancel').onclick=closeModal;
async function doAction(name,body){toast('…');try{const r=await(await api('/api/action/'+name,body||{})).json();
  toast(r.ok||r.detached?'OK':('Ошибка: '+(r.err||r.error||'')));}catch(e){toast('Ошибка сети');}}
$('#btn-exit').onclick=()=>doAction('screen',{exit_kiosk:true});
$('#act-update').onclick=()=>doAction('update');
$('#act-boost').onclick=()=>doAction('cpu-boost');
$$('#powermode button').forEach(b=>b.onclick=()=>{$$('#powermode button').forEach(x=>x.classList.remove('active'));
  b.classList.add('active');doAction('power-mode',{mode:b.dataset.mode});});
$('#rotate-apply').onclick=()=>{const v=$('#rotate').value;if(v)doAction('screen',{rotate:v});};

/* ===== Экран: яркость 0-100, гашение по таймауту + отсчёт, ночь ===== */
const LS=localStorage,br=$('#brightness'),bv=$('#brightness-val');
function setBrightness(v,save){bv.textContent=v+'%';api('/api/action/screen',{brightness:v+'%'});if(save)LS.brightness=v;}
br.value=LS.brightness||80;bv.textContent=br.value+'%';
br.oninput=()=>setBrightness(br.value,true);
$('#screen-timeout').value=LS.screenTimeout||'300';$('#screen-timeout').onchange=e=>LS.screenTimeout=e.target.value;
['night-from','night-to','night-level'].forEach(id=>{const el=$('#'+id);if(LS[id])el.value=LS[id];
  el.onchange=()=>{LS[id]=el.value;nightApplied=null;};});

let lastAct=Date.now(),screenOff=false;
['pointerdown','touchstart','keydown','mousemove'].forEach(ev=>addEventListener(ev,()=>{lastAct=Date.now();
  if(screenOff){screenOff=false;api('/api/action/screen',{backlight:'on'});setBrightness(br.value);}},{passive:true}));
function screenChipText(){const to=+($('#screen-timeout').value||0);if(!to)return'экран: всегда';
  if(screenOff)return'экран спит';const rem=Math.max(0,to-(Date.now()-lastAct)/1000|0);
  return rem>0?`экран через ${rem<60?rem+'с':Math.ceil(rem/60)+'м'}`:'экран: гаснет';}
setInterval(()=>{const to=+($('#screen-timeout').value||0);
  if(to>0&&!screenOff&&Date.now()-lastAct>to*1000){screenOff=true;api('/api/action/screen',{backlight:'off'});}},1000);

let nightApplied=null;
function applyNight(){const f=$('#night-from').value,t=$('#night-to').value;if(!f||!t)return;
  const d=new Date(),cur=('0'+d.getHours()).slice(-2)+':'+('0'+d.getMinutes()).slice(-2);
  const inWin=f<t?(cur>=f&&cur<t):(cur>=f||cur<t);
  const target=inWin?+$('#night-level').value:+br.value;
  if(!screenOff&&target!==nightApplied){nightApplied=target;api('/api/action/screen',{brightness:target+'%'});}}

/* ===== старт ===== */
makeChart();loadHistory();connect();
setInterval(loadHistory,60000);
addEventListener('resize',()=>{makeChart();chart.setData(chData);});
setBrightness(br.value);
